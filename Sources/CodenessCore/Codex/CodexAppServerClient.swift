import Dispatch
import Foundation

public actor CodexAppServerClient {
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputReaderTask: Task<Void, Never>?
    private var errorReaderTask: Task<Void, Never>?
    private var outputBuffer = Data()
    private var requestIdentifier: Int64 = 0
    private var pendingRequests: [Int64: CheckedContinuation<JSONValue, any Error>] = [:]
    private var processGeneration: Int64 = 0
    private var activeProcessGeneration: Int64?
    private var terminatedProcess: (generation: Int64, status: Int32)?
    private var outputEOFGeneration: Int64?
    private let eventStream: AsyncStream<AppServerEvent>
    private let eventContinuation: AsyncStream<AppServerEvent>.Continuation

    public init() {
        let pair = AsyncStream<AppServerEvent>.makeStream(bufferingPolicy: .unbounded)
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    public func events() -> AsyncStream<AppServerEvent> {
        eventStream
    }

    public var isRunning: Bool {
        process?.isRunning == true
    }

    public func start(configuration: CodexLaunchConfiguration) async throws {
        guard process == nil else { throw AppServerClientError.alreadyRunning }

        let launchedProcess = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        launchedProcess.executableURL = configuration.executableURL
        launchedProcess.arguments = configuration.arguments
        launchedProcess.environment = configuration.environment
        launchedProcess.standardInput = stdin
        launchedProcess.standardOutput = stdout
        launchedProcess.standardError = stderr
        processGeneration += 1
        let generation = processGeneration
        activeProcessGeneration = generation
        terminatedProcess = nil
        outputEOFGeneration = nil

        launchedProcess.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { await self?.processTerminated(status, generation: generation) }
        }

        process = launchedProcess
        inputPipe = stdin
        outputPipe = stdout
        errorPipe = stderr
        outputReaderTask = Self.makeOutputReader(
            handle: stdout.fileHandleForReading,
            generation: generation,
            client: self
        )
        errorReaderTask = Self.makeErrorReader(
            handle: stderr.fileHandleForReading,
            generation: generation,
            client: self
        )

        do {
            try launchedProcess.run()
            // The child inherited these ends during launch. Retaining duplicate write
            // ends in Codeness would prevent stdout/stderr readers from ever observing
            // EOF after the child exits.
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            _ = try await sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": .object([
                        "name": .string("codeness"),
                        "title": .string("Codeness"),
                        "version": .string("0.1.0")
                    ]),
                    "capabilities": .object([
                        "experimentalApi": .bool(false)
                    ])
                ]
            )
            try sendNotification(method: "initialized", params: nil)
        } catch {
            stopProcess()
            throw error
        }
    }

    public func shutdown() {
        guard let process else { return }
        activeProcessGeneration = nil
        try? inputPipe?.fileHandleForWriting.close()
        failPendingRequests(with: AppServerClientError.notRunning)
        if process.isRunning {
            process.terminate()
        }
        clearProcess()
    }

    public func listModels() async throws -> [CodexModel] {
        var models: [CodexModel] = []
        var cursor: String?

        repeat {
            var params: [String: JSONValue] = ["includeHidden": .bool(false)]
            if let cursor {
                params["cursor"] = .string(cursor)
            }
            let response = try await sendRequest(method: "model/list", params: params)
            let page = response["data"]?.arrayValue ?? []
            models.append(contentsOf: page.compactMap(Self.decodeModel))
            cursor = response["nextCursor"]?.stringValue
        } while cursor != nil

        return models
    }

    public func startThread(
        cwd: String,
        model: String,
        developerInstructions: String
    ) async throws -> String {
        let response = try await sendRequest(
            method: "thread/start",
            params: [
                "cwd": .string(cwd),
                "model": .string(model),
                "developerInstructions": .string(developerInstructions),
                "ephemeral": .bool(false),
                "serviceName": .string("Codeness")
            ]
        )
        guard let identifier = response["thread"]?["id"]?.stringValue else {
            throw AppServerClientError.invalidResponse("thread/start did not return thread.id")
        }
        return identifier
    }

    public func resumeThread(
        id: String,
        cwd: String,
        model: String,
        developerInstructions: String
    ) async throws {
        _ = try await sendRequest(
            method: "thread/resume",
            params: [
                "threadId": .string(id),
                "cwd": .string(cwd),
                "model": .string(model),
                "developerInstructions": .string(developerInstructions)
            ]
        )
    }

    public func readThread(id: String, includeTurns: Bool = true) async throws -> JSONValue {
        try await sendRequest(
            method: "thread/read",
            params: [
                "threadId": .string(id),
                "includeTurns": .bool(includeTurns)
            ]
        )
    }

    public func setThreadName(id: String, name: String) async throws {
        _ = try await sendRequest(
            method: "thread/name/set",
            params: ["threadId": .string(id), "name": .string(name)]
        )
    }

    public func startTurn(
        threadID: String,
        prompt: String,
        cwd: String,
        model: String,
        effort: String
    ) async throws -> String {
        let response = try await sendRequest(
            method: "turn/start",
            params: [
                "threadId": .string(threadID),
                "input": .array([.object([
                    "type": .string("text"),
                    "text": .string(prompt),
                    "text_elements": .array([])
                ])]),
                "cwd": .string(cwd),
                "model": .string(model),
                "effort": .string(effort)
            ]
        )
        guard let identifier = response["turn"]?["id"]?.stringValue else {
            throw AppServerClientError.invalidResponse("turn/start did not return turn.id")
        }
        return identifier
    }

    public func steer(threadID: String, turnID: String, message: String) async throws {
        _ = try await sendRequest(
            method: "turn/steer",
            params: [
                "threadId": .string(threadID),
                "expectedTurnId": .string(turnID),
                "input": .array([.object([
                    "type": .string("text"),
                    "text": .string(message),
                    "text_elements": .array([])
                ])])
            ]
        )
    }

    public func interrupt(threadID: String, turnID: String) async throws {
        _ = try await sendRequest(
            method: "turn/interrupt",
            params: ["threadId": .string(threadID), "turnId": .string(turnID)]
        )
    }

    public func respond(to id: JSONValue, result: JSONValue) throws {
        try writeMessage(.object(["id": id, "result": result]))
    }

    public func respondWithError(to id: JSONValue, code: Int64 = -32_000, message: String) throws {
        try writeMessage(.object([
            "id": id,
            "error": .object(["code": .integer(code), "message": .string(message)])
        ]))
    }

    private func sendRequest(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        guard process?.isRunning == true else { throw AppServerClientError.notRunning }
        requestIdentifier += 1
        let identifier = requestIdentifier
        let message = JSONValue.object([
            "id": .integer(identifier),
            "method": .string(method),
            "params": .object(params)
        ])

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[identifier] = continuation
            do {
                try writeMessage(message)
            } catch {
                pendingRequests.removeValue(forKey: identifier)?.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: JSONValue?) throws {
        var message: [String: JSONValue] = ["method": .string(method)]
        if let params {
            message["params"] = params
        }
        try writeMessage(.object(message))
    }

    private func writeMessage(_ message: JSONValue) throws {
        guard let inputPipe else { throw AppServerClientError.notRunning }
        var data = try message.encodedData()
        data.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func consumeOutput(_ data: Data, generation: Int64) {
        guard activeProcessGeneration == generation else { return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !lineData.isEmpty else { continue }
            handleLine(Data(lineData))
        }
    }

    private func handleLine(_ data: Data) {
        let rawLine = String(decoding: data, as: UTF8.self)
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            eventContinuation.yield(.standardError("Invalid App Server JSON: \(rawLine)"))
            return
        }

        if let identifier = message["id"]?.integerValue,
           message["method"] == nil,
           let continuation = pendingRequests.removeValue(forKey: identifier) {
            if let error = message["error"] {
                continuation.resume(throwing: AppServerClientError.requestFailed(
                    code: error["code"]?.integerValue,
                    message: error["message"]?.stringValue ?? error.encodedString()
                ))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }

        guard let method = message["method"]?.stringValue else {
            eventContinuation.yield(.standardError("Unrecognized App Server message: \(rawLine)"))
            return
        }
        let params = message["params"] ?? .object([:])
        if let id = message["id"] {
            eventContinuation.yield(.request(id: id, method: method, params: params, rawLine: rawLine))
        } else {
            eventContinuation.yield(.notification(method: method, params: params, rawLine: rawLine))
        }
    }

    private func emitStandardError(_ text: String, generation: Int64) {
        guard activeProcessGeneration == generation else { return }
        eventContinuation.yield(.standardError(text))
    }

    private func outputReachedEOF(generation: Int64) {
        guard activeProcessGeneration == generation else { return }
        if !outputBuffer.isEmpty {
            let finalLine = outputBuffer
            outputBuffer.removeAll(keepingCapacity: true)
            handleLine(finalLine)
        }
        outputEOFGeneration = generation
        finishProcessExitIfReady(generation: generation)
    }

    private func processTerminated(_ status: Int32, generation: Int64) {
        guard activeProcessGeneration == generation else { return }
        terminatedProcess = (generation, status)
        finishProcessExitIfReady(generation: generation)
    }

    private func finishProcessExitIfReady(generation: Int64) {
        guard activeProcessGeneration == generation,
              outputEOFGeneration == generation,
              let terminatedProcess,
              terminatedProcess.generation == generation else { return }
        let status = terminatedProcess.status
        failPendingRequests(with: AppServerClientError.processExited(status))
        eventContinuation.yield(.exited(status))
        clearProcess()
    }

    private func stopProcess() {
        activeProcessGeneration = nil
        failPendingRequests(with: AppServerClientError.notRunning)
        if process?.isRunning == true {
            process?.terminate()
        }
        clearProcess()
    }

    private func clearProcess() {
        activeProcessGeneration = nil
        outputReaderTask?.cancel()
        errorReaderTask?.cancel()
        outputReaderTask = nil
        errorReaderTask = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        terminatedProcess = nil
        outputEOFGeneration = nil
        outputBuffer.removeAll(keepingCapacity: true)
    }

    private func failPendingRequests(with error: any Error) {
        for continuation in pendingRequests.values {
            continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
    }

    private nonisolated static func makeOutputReader(
        handle: FileHandle,
        generation: Int64,
        client: CodexAppServerClient
    ) -> Task<Void, Never> {
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        DispatchQueue(label: "ap.codeness.app-server.stdout.\(generation)", qos: .userInitiated).async {
            // FileHandle.read(upToCount:) may wait for the requested byte count on
            // a pipe. availableData returns as soon as any bytes arrive, preserving
            // interactive JSONL behavior while this one queue preserves ordering.
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                pair.continuation.yield(data)
            }
            pair.continuation.finish()
        }
        return Task { [weak client] in
            for await data in pair.stream {
                guard !Task.isCancelled else { return }
                await client?.consumeOutput(data, generation: generation)
            }
            guard !Task.isCancelled else { return }
            await client?.outputReachedEOF(generation: generation)
        }
    }

    private nonisolated static func makeErrorReader(
        handle: FileHandle,
        generation: Int64,
        client: CodexAppServerClient
    ) -> Task<Void, Never> {
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        DispatchQueue(label: "ap.codeness.app-server.stderr.\(generation)", qos: .utility).async {
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                pair.continuation.yield(data)
            }
            pair.continuation.finish()
        }
        return Task { [weak client] in
            for await data in pair.stream {
                guard !Task.isCancelled else { return }
                await client?.emitStandardError(
                    String(decoding: data, as: UTF8.self),
                    generation: generation
                )
            }
        }
    }

    private static func decodeModel(_ value: JSONValue) -> CodexModel? {
        guard let id = value["id"]?.stringValue,
              let model = value["model"]?.stringValue,
              let displayName = value["displayName"]?.stringValue,
              let defaultEffort = value["defaultReasoningEffort"]?.stringValue else { return nil }
        let efforts = value["supportedReasoningEfforts"]?.arrayValue?
            .compactMap { $0["reasoningEffort"]?.stringValue } ?? []
        return CodexModel(
            id: id,
            model: model,
            displayName: displayName,
            description: value["description"]?.stringValue ?? "",
            defaultEffort: defaultEffort,
            efforts: efforts,
            hidden: value["hidden"]?.boolValue ?? false
        )
    }
}
