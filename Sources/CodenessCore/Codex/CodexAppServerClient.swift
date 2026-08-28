import Dispatch
import Darwin
import Foundation

public actor CodexAppServerClient {
    private enum DirectWriteRaceResult: Sendable {
        case completed
        case deadline
    }

    private enum RequestWriteState {
        case queued
        case completed
    }

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONValue, any Error>
        let timeoutTask: Task<Void, Never>
        let writeToken: UUID
        var writeState: RequestWriteState
    }

    private var process: AppServerProcess?
    private var inputWriter: OrderedPipeWriter?
    private var outputReader: BoundedPipeReader?
    private var errorReader: BoundedPipeReader?
    private var outputBuffer = Data()
    private var outputScanOffset = 0
    private var requestIdentifier: Int64 = 0
    private var pendingRequests: [Int64: PendingRequest] = [:]
    private var retiredRequestIDs: Set<Int64> = []
    private var retiredRequestOrder: [Int64] = []
    private var processGeneration: Int64 = 0
    private var activeProcessGeneration: Int64?
    private var terminatedProcess: (
        generation: Int64,
        termination: SubprocessTermination
    )?
    private var outputEOFGeneration: Int64?
    private var processGroupCleanupGeneration: Int64?
    private var clearingProcessGeneration: Int64?
    private var eventRoutingPauses: Set<UUID> = []
    private var suppressedExitGenerations: Set<Int64> = []
    private var exitDiagnostics: [Int64: String] = [:]
    private var terminalDeliveryOverflow: String?
    private var terminationTask: Task<Void, Never>?
    private var terminationTaskGeneration: Int64?
    private var terminationTaskToken: UUID?
    private var terminationEscalationAttempt = 0
    private var outputDrainTask: Task<Void, Never>?
    private var processWaitTask: Task<Void, Never>?
    private let eventChannel: BoundedAsyncChannel<AppServerTransportEvent>
    private let eventStream: AsyncStream<AppServerTransportEvent>
    private let requestTimeout: Duration
    private let controlRequestTimeout: Duration
    private let directWriteTimeout: Duration
    private let terminationGrace: Duration
    private let outputDrainGrace: Duration
    private let requestRegistrationHook: (@Sendable (String) async -> Void)?
    private let writeProgressHook: (@Sendable (Int, Int) -> Void)?
    private let beforeOutputReadHook: (@Sendable () -> Void)?
    private let terminationSignalPermission: (@Sendable (Int) -> Bool)?
    private let beforeProcessClearCompletionHook: (@Sendable (Int64) async -> Void)?
    private static let maximumPendingRequestCount = 64
    private static let maximumModelCount = 4_096
    private static let maximumLoadedThreadIdentifierCount = 4_096
    private static let maximumPaginationPageCount = 1_024
    private static let maximumPaginationCursorUTF8ByteCount = 16 * 1_024
    private static let maximumSeenCursorRetainedBytes = 1 * 1_024 * 1_024
    private static let maximumModelRetainedBytes = 16 * 1_024 * 1_024
    private static let maximumLoadedThreadIdentifierRetainedBytes = 4 * 1_024 * 1_024
    private static let maximumJSONLineByteCount = 32 * 1_024 * 1_024
    private static let maximumDiagnosticJSONPreviewByteCount = 4 * 1_024
    private static let maximumRetainedEventByteCost = 128 * 1_024 * 1_024

    public init(
        requestTimeout: Duration = .seconds(30),
        controlRequestTimeout: Duration = .seconds(5)
    ) {
        let channel = BoundedAsyncChannel<AppServerTransportEvent>(
            capacity: 64,
            maximumRetainedCost: Self.maximumRetainedEventByteCost,
            retainedCost: Self.retainedEventByteCost
        )
        eventChannel = channel
        eventStream = channel.stream()
        self.requestTimeout = requestTimeout
        self.controlRequestTimeout = controlRequestTimeout
        directWriteTimeout = controlRequestTimeout
        terminationGrace = .milliseconds(250)
        outputDrainGrace = .milliseconds(400)
        requestRegistrationHook = nil
        writeProgressHook = nil
        beforeOutputReadHook = nil
        terminationSignalPermission = nil
        beforeProcessClearCompletionHook = nil
    }

    init(
        testingRequestRegistrationHook: @escaping @Sendable (String) async -> Void,
        requestTimeout: Duration = .seconds(30),
        controlRequestTimeout: Duration = .seconds(5),
        terminationGrace: Duration = .milliseconds(250),
        outputDrainGrace: Duration = .milliseconds(400),
        eventCapacity: Int = 64,
        testingWriteProgressHook: (@Sendable (Int, Int) -> Void)? = nil,
        testingBeforeOutputReadHook: (@Sendable () -> Void)? = nil,
        testingTerminationSignalPermission: (@Sendable (Int) -> Bool)? = nil,
        testingBeforeProcessClearCompletionHook: (@Sendable (Int64) async -> Void)? = nil,
        directWriteTimeout: Duration? = nil
    ) {
        let channel = BoundedAsyncChannel<AppServerTransportEvent>(
            capacity: eventCapacity,
            maximumRetainedCost: Self.maximumRetainedEventByteCost,
            retainedCost: Self.retainedEventByteCost
        )
        eventChannel = channel
        eventStream = channel.stream()
        self.requestTimeout = requestTimeout
        self.controlRequestTimeout = controlRequestTimeout
        self.directWriteTimeout = directWriteTimeout ?? controlRequestTimeout
        self.terminationGrace = terminationGrace
        self.outputDrainGrace = outputDrainGrace
        requestRegistrationHook = testingRequestRegistrationHook
        writeProgressHook = testingWriteProgressHook
        beforeOutputReadHook = testingBeforeOutputReadHook
        terminationSignalPermission = testingTerminationSignalPermission
        beforeProcessClearCompletionHook = testingBeforeProcessClearCompletionHook
    }

    public func events() -> AsyncStream<AppServerTransportEvent> {
        eventStream
    }

    public func isLatestGeneration(_ generation: Int64) -> Bool {
        processGeneration == generation
    }

    public func pauseEventRouting() async -> AppServerEventRoutingPause {
        let pause = AppServerEventRoutingPause(identifier: UUID())
        eventRoutingPauses.insert(pause.identifier)
        // A sender that began under normal backpressure before this token was
        // installed must not remain suspended while AppModel holds its
        // lifecycle lease and deliberately stops pulling events.
        await eventChannel.rejectPendingSends()
        return pause
    }

    public func resumeEventRouting(_ pause: AppServerEventRoutingPause) {
        eventRoutingPauses.remove(pause.identifier)
    }

    public var isRunning: Bool {
        // A terminated leader remains owned until stdout drain, descendant
        // cleanup, terminal-event admission, and waitpid reaping all complete.
        // Treat that bounded teardown window as running so callers never race a
        // restart into an `alreadyRunning` generation.
        activeProcessGeneration != nil
    }

    func testingProcessIdentifiers() -> (process: pid_t, group: pid_t)? {
        process.map { ($0.processIdentifier, $0.processGroupIdentifier) }
    }

    func testingCancellationTombstoneCount() -> Int {
        inputWriter?.testingCancellationTombstoneCount ?? 0
    }

    func testingHasObservedProcessTermination() -> Bool {
        terminatedProcess != nil
    }

    func testingBufferedEventCount() async -> Int {
        await eventChannel.testingBufferedCount()
    }

    func testingEventRoutingIsPaused() -> Bool {
        !eventRoutingPauses.isEmpty
    }

    public func start(configuration: CodexLaunchConfiguration) async throws {
        guard process == nil, activeProcessGeneration == nil else {
            throw AppServerClientError.alreadyRunning
        }
        if let terminalDeliveryOverflow {
            throw AppServerClientError.invalidResponse(terminalDeliveryOverflow)
        }

        let launchedProcess = try AppServerProcess.launch(configuration: configuration)
        processGeneration += 1
        let generation = processGeneration
        activeProcessGeneration = generation
        process = launchedProcess
        terminatedProcess = nil
        outputEOFGeneration = nil
        processGroupCleanupGeneration = nil
        clearingProcessGeneration = nil
        terminationEscalationAttempt = 0
        // A replacement generation never needs events that were still queued
        // from an older process. Purge them before starting the new readers so
        // stale terminal reserves cannot backpressure replacement stdout.
        await eventChannel.discard { $0.generation < generation }
        let writer = OrderedPipeWriter(
            fileDescriptor: launchedProcess.inputFileDescriptor,
            generation: generation,
            writeProgressHook: writeProgressHook
        )
        inputWriter = writer
        let stdout = BoundedPipeReader(
            fileDescriptor: launchedProcess.outputFileDescriptor,
            label: "ap.codeness.app-server.stdout.\(generation)",
            qos: .userInitiated,
            beforeReadHook: beforeOutputReadHook
        )
        let stderr = BoundedPipeReader(
            fileDescriptor: launchedProcess.errorFileDescriptor,
            label: "ap.codeness.app-server.stderr.\(generation)",
            qos: .utility
        )
        outputReader = stdout
        errorReader = stderr
        stdout.start(
            consume: { [weak self] data in
                await self?.consumeOutput(data, generation: generation)
            },
            reachedEOF: { [weak self] in
                await self?.outputReachedEOF(generation: generation)
            }
        )
        stderr.start(
            consume: { [weak self] data in
                await self?.emitStandardError(
                    String(decoding: data, as: UTF8.self),
                    generation: generation
                )
            },
            reachedEOF: {}
        )
        processWaitTask = Self.makeProcessWaiter(
            process: launchedProcess,
            generation: generation,
            client: self
        )

        do {
            _ = try await sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": .object([
                        "name": .string("codeness"),
                        "title": .string("Codeness"),
                        "version": .string("0.9.6")
                    ]),
                    "capabilities": .object([
                        "experimentalApi": .bool(true),
                        "mcpServerOpenaiFormElicitation": .bool(true)
                    ])
                ]
            )
            try await sendNotification(method: "initialized", params: nil)
        } catch {
            await stopProcess(suppressExitEvent: true)
            let cleaned = await waitForGenerationCleanup(generation: generation)
            guard cleaned else {
                throw AppServerClientError.invalidResponse(
                    "initialization failed and Codeness could not verify that the isolated App Server process group was gone: \(error.localizedDescription)"
                )
            }
            throw error
        }
    }

    @discardableResult
    public func shutdown() async -> Bool {
        guard let generation = activeProcessGeneration else { return true }
        await stopProcess(suppressExitEvent: true)
        return await waitForGenerationCleanup(generation: generation)
    }

    @discardableResult
    public func terminateGenerationForProtocolViolation(_ detail: String) async -> Bool {
        guard let generation = activeProcessGeneration else { return true }
        exitDiagnostics[generation] =
            "Codex App Server violated its protocol; Codeness terminated the isolated process scope: \(detail)"
        beginTermination(generation: generation, suppressExitEvent: false)
        return await waitForGenerationCleanup(generation: generation)
    }

    private func waitForGenerationCleanup(generation: Int64) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while activeProcessGeneration == generation, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard activeProcessGeneration != generation else {
            let message =
                "Codeness could not verify that Codex App Server process group \(process?.processGroupIdentifier ?? -1) exited; restart is blocked to prevent overlapping orphan processes."
            exitDiagnostics[generation] = message
            _ = await eventChannel.sendForTeardown(AppServerTransportEvent(
                generation: generation,
                event: .standardError(message)
            ))
            return false
        }
        return true
    }

    public func listModels() async throws -> [CodexModel] {
        var models: [CodexModel] = []
        var modelIDs: Set<String> = []
        var cursor: String?
        var seenCursors: Set<String> = []
        var seenCursorRetainedByteCount = 0
        var modelRetainedByteCount = 0

        for _ in 0..<Self.maximumPaginationPageCount {
            var params: [String: JSONValue] = ["includeHidden": .bool(false)]
            if let cursor {
                params["cursor"] = .string(cursor)
            }
            let response = try await sendRequest(method: "model/list", params: params)
            guard let data = response["data"]?.arrayValue else {
                throw AppServerClientError.invalidResponse(
                    "model/list did not return a data array"
                )
            }
            let page = data.compactMap(Self.decodeModel)
            guard page.count == data.count else {
                throw AppServerClientError.invalidResponse(
                    "model/list returned an invalid model"
                )
            }

            let countBeforePage = models.count
            for model in page where modelIDs.insert(model.id).inserted {
                let retainedByteCount = Self.retainedByteCount(of: model)
                guard retainedByteCount <= Self.maximumModelRetainedBytes,
                      modelRetainedByteCount
                        <= Self.maximumModelRetainedBytes - retainedByteCount else {
                    throw AppServerClientError.invalidResponse(
                        "model/list exceeded the retained-byte safety limit"
                    )
                }
                models.append(model)
                modelRetainedByteCount += retainedByteCount
            }
            guard models.count <= Self.maximumModelCount else {
                throw AppServerClientError.invalidResponse(
                    "model/list exceeded the \(Self.maximumModelCount)-model safety limit"
                )
            }

            let nextCursor: String?
            switch response["nextCursor"] {
            case nil, .some(.null):
                nextCursor = nil
            case .some(.string(let value)) where !value.isEmpty:
                nextCursor = value
            default:
                throw AppServerClientError.invalidResponse(
                    "model/list returned an invalid nextCursor"
                )
            }

            guard let nextCursor else { return models }
            guard models.count > countBeforePage else {
                throw AppServerClientError.invalidResponse(
                    "model/list returned a continuation cursor without adding any models"
                )
            }
            let cursorRetainedByteCount = nextCursor.utf8.count
            guard cursorRetainedByteCount <= Self.maximumPaginationCursorUTF8ByteCount,
                  seenCursorRetainedByteCount
                    <= Self.maximumSeenCursorRetainedBytes - cursorRetainedByteCount else {
                throw AppServerClientError.invalidResponse(
                    "model/list exceeded the pagination-cursor byte safety limit"
                )
            }
            guard nextCursor != cursor, seenCursors.insert(nextCursor).inserted else {
                throw AppServerClientError.invalidResponse(
                    "model/list repeated a pagination cursor"
                )
            }
            seenCursorRetainedByteCount += cursorRetainedByteCount
            cursor = nextCursor
        }

        throw AppServerClientError.invalidResponse(
            "model/list exceeded the \(Self.maximumPaginationPageCount)-page safety limit"
        )
    }

    public func startThread(
        cwd: String,
        model: String,
        developerInstructions: String,
        ephemeral: Bool = false,
        readOnly: Bool = false,
        approvalPolicy: String? = nil,
        configuration: JSONValue? = nil
    ) async throws -> String {
        var params: [String: JSONValue] = [
            "cwd": .string(cwd),
            "model": .string(model),
            "developerInstructions": .string(developerInstructions),
            "ephemeral": .bool(ephemeral),
            "serviceName": .string("Codeness")
        ]
        if readOnly {
            params["sandbox"] = .string("read-only")
        }
        if let approvalPolicy {
            params["approvalPolicy"] = .string(approvalPolicy)
        }
        if let configuration {
            params["config"] = configuration
        }
        let response = try await sendRequest(
            method: "thread/start",
            params: params
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
        developerInstructions: String,
        approvalPolicy: String? = nil
    ) async throws {
        var params: [String: JSONValue] = [
            "threadId": .string(id),
            "cwd": .string(cwd),
            "model": .string(model),
            "developerInstructions": .string(developerInstructions)
        ]
        if let approvalPolicy {
            params["approvalPolicy"] = .string(approvalPolicy)
        }
        _ = try await sendRequest(
            method: "thread/resume",
            params: params
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

    public func loadedThreadIDs() async throws -> Set<String> {
        var identifiers: Set<String> = []
        var cursor: String?
        var seenCursors: Set<String> = []
        var seenCursorRetainedByteCount = 0
        var identifierRetainedByteCount = 0
        for _ in 0..<Self.maximumPaginationPageCount {
            var params: [String: JSONValue] = [:]
            if let cursor {
                params["cursor"] = .string(cursor)
            }
            let response = try await sendRequest(
                method: "thread/loaded/list",
                params: params
            )
            guard let data = response["data"]?.arrayValue,
                  data.allSatisfy({ $0.stringValue != nil }) else {
                throw AppServerClientError.invalidResponse(
                    "thread/loaded/list did not return a string data array"
                )
            }

            let countBeforePage = identifiers.count
            for identifier in data.compactMap(\.stringValue)
                where !identifiers.contains(identifier) {
                let retainedByteCount = identifier.utf8.count
                guard retainedByteCount <= Self.maximumLoadedThreadIdentifierRetainedBytes,
                      identifierRetainedByteCount
                        <= Self.maximumLoadedThreadIdentifierRetainedBytes
                            - retainedByteCount else {
                    throw AppServerClientError.invalidResponse(
                        "thread/loaded/list exceeded the identifier byte safety limit"
                    )
                }
                identifiers.insert(identifier)
                identifierRetainedByteCount += retainedByteCount
            }
            guard identifiers.count <= Self.maximumLoadedThreadIdentifierCount else {
                throw AppServerClientError.invalidResponse(
                    "thread/loaded/list exceeded the \(Self.maximumLoadedThreadIdentifierCount)-identifier safety limit"
                )
            }
            let nextCursor: String?
            switch response["nextCursor"] {
            case nil, .some(.null):
                nextCursor = nil
            case .some(.string(let value)) where !value.isEmpty:
                nextCursor = value
            default:
                throw AppServerClientError.invalidResponse(
                    "thread/loaded/list returned an invalid nextCursor"
                )
            }

            guard let nextCursor else { return identifiers }
            guard identifiers.count > countBeforePage else {
                throw AppServerClientError.invalidResponse(
                    "thread/loaded/list returned a continuation cursor without adding any thread IDs"
                )
            }
            let cursorRetainedByteCount = nextCursor.utf8.count
            guard cursorRetainedByteCount <= Self.maximumPaginationCursorUTF8ByteCount,
                  seenCursorRetainedByteCount
                    <= Self.maximumSeenCursorRetainedBytes - cursorRetainedByteCount else {
                throw AppServerClientError.invalidResponse(
                    "thread/loaded/list exceeded the pagination-cursor byte safety limit"
                )
            }
            guard nextCursor != cursor, seenCursors.insert(nextCursor).inserted else {
                throw AppServerClientError.invalidResponse(
                    "thread/loaded/list repeated a pagination cursor"
                )
            }
            seenCursorRetainedByteCount += cursorRetainedByteCount
            cursor = nextCursor
        }

        throw AppServerClientError.invalidResponse(
            "thread/loaded/list exceeded the \(Self.maximumPaginationPageCount)-page safety limit"
        )
    }

    /// Requests cancellation and removal of every background terminal owned by
    /// a thread. Codex currently acknowledges this mutation with an empty
    /// object; accepting another shape would make a protocol drift look like a
    /// successful cleanup.
    public func cleanBackgroundTerminals(threadID: String) async throws {
        let response = try await sendRequest(
            method: "thread/backgroundTerminals/clean",
            params: ["threadId": .string(threadID)]
        )
        guard response.objectValue?.isEmpty == true else {
            throw AppServerClientError.invalidResponse(
                "thread/backgroundTerminals/clean did not return an empty object"
            )
        }
    }

    /// Returns the app-server process identifiers for terminals that remain
    /// attached to a thread after cleanup. Retention is bounded independently
    /// of the transport's JSON-line limit so a valid but hostile response cannot
    /// grow application memory without bound.
    public func backgroundTerminalIDs(threadID: String) async throws -> Set<String> {
        var identifiers: Set<String> = []
        var retainedByteCount = 0
        var cursor: String?
        var seenCursors: Set<String> = []
        var seenCursorRetainedByteCount = 0

        for _ in 0..<Self.maximumPaginationPageCount {
            var params: [String: JSONValue] = [
                "threadId": .string(threadID),
                "limit": .integer(256)
            ]
            if let cursor { params["cursor"] = .string(cursor) }
            let response = try await sendRequest(
                method: "thread/backgroundTerminals/list",
                params: params
            )
            guard let data = response["data"]?.arrayValue else {
                throw AppServerClientError.invalidResponse(
                    "thread/backgroundTerminals/list did not return a data array"
                )
            }

            let countBeforePage = identifiers.count
            for value in data {
                guard let terminal = value.objectValue,
                      let processID = terminal["processId"]?.stringValue,
                      terminal["itemId"]?.stringValue != nil,
                      terminal["command"]?.stringValue != nil,
                      terminal["cwd"]?.stringValue != nil,
                      Self.isOptionalUnsignedInteger(
                        terminal["osPid"],
                        maximum: Double(UInt32.max)
                      ),
                      Self.isOptionalUnsignedInteger(
                        terminal["rssKb"],
                        maximum: Double(UInt64.max)
                      ),
                      Self.isOptionalFiniteNumber(terminal["cpuPercent"]) else {
                    throw AppServerClientError.invalidResponse(
                        "thread/backgroundTerminals/list returned an invalid terminal"
                    )
                }
                guard identifiers.insert(processID).inserted else { continue }
                let byteCount = terminal.values.reduce(0) { partial, value in
                    partial + (value.stringValue?.utf8.count ?? 0)
                }
                guard byteCount <= Self.maximumLoadedThreadIdentifierRetainedBytes,
                      retainedByteCount
                        <= Self.maximumLoadedThreadIdentifierRetainedBytes - byteCount else {
                    throw AppServerClientError.invalidResponse(
                        "thread/backgroundTerminals/list exceeded the retained-byte safety limit"
                    )
                }
                retainedByteCount += byteCount
            }
            guard identifiers.count <= Self.maximumLoadedThreadIdentifierCount else {
                throw AppServerClientError.invalidResponse(
                    "thread/backgroundTerminals/list exceeded the \(Self.maximumLoadedThreadIdentifierCount)-identifier safety limit"
                )
            }

            let nextCursor: String?
            switch response["nextCursor"] {
            case nil, .some(.null):
                nextCursor = nil
            case .some(.string(let value)) where !value.isEmpty:
                nextCursor = value
            default:
                throw AppServerClientError.invalidResponse(
                    "thread/backgroundTerminals/list returned an invalid nextCursor"
                )
            }
            guard let nextCursor else { return identifiers }
            guard identifiers.count > countBeforePage else {
                throw AppServerClientError.invalidResponse(
                    "thread/backgroundTerminals/list returned a continuation cursor without adding any terminals"
                )
            }
            let cursorByteCount = nextCursor.utf8.count
            guard cursorByteCount <= Self.maximumPaginationCursorUTF8ByteCount,
                  seenCursorRetainedByteCount
                    <= Self.maximumSeenCursorRetainedBytes - cursorByteCount else {
                throw AppServerClientError.invalidResponse(
                    "thread/backgroundTerminals/list exceeded the pagination-cursor byte safety limit"
                )
            }
            guard nextCursor != cursor,
                  seenCursors.insert(nextCursor).inserted else {
                throw AppServerClientError.invalidResponse(
                    "thread/backgroundTerminals/list repeated a pagination cursor"
                )
            }
            seenCursorRetainedByteCount += cursorByteCount
            cursor = nextCursor
        }

        throw AppServerClientError.invalidResponse(
            "thread/backgroundTerminals/list exceeded the \(Self.maximumPaginationPageCount)-page safety limit"
        )
    }

    @discardableResult
    public func unsubscribeThread(id: String) async throws -> String {
        let response = try await sendRequest(
            method: "thread/unsubscribe",
            params: ["threadId": .string(id)]
        )
        guard let status = response["status"]?.stringValue else {
            throw AppServerClientError.invalidResponse(
                "thread/unsubscribe did not return a status"
            )
        }
        return status
    }

    public func deleteThread(id: String) async throws {
        let response = try await sendRequest(
            method: "thread/delete",
            params: ["threadId": .string(id)]
        )
        guard response.objectValue?.isEmpty == true else {
            throw AppServerClientError.invalidResponse(
                "thread/delete did not return an empty object"
            )
        }
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
        effort: String,
        mode: AgentMode = .standard,
        serviceTier: String? = nil,
        outputSchema: JSONValue? = nil,
        approvalPolicy: String? = nil
    ) async throws -> String {
        var params: [String: JSONValue] = [
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
        if let approvalPolicy {
            params["approvalPolicy"] = .string(approvalPolicy)
        }
        if mode == .plan {
            params["collaborationMode"] = .object([
                "mode": .string("plan"),
                "settings": .object([
                    "model": .string(model),
                    "reasoning_effort": .string(effort),
                    "developer_instructions": .null
                ])
            ])
            params["sandboxPolicy"] = .object([
                "type": .string("readOnly"),
                "networkAccess": .bool(false)
            ])
        }
        // serviceTier is sticky for subsequent turns. Send an explicit null for
        // Standard so changing Fast on an existing step session is reversible.
        params["serviceTier"] = serviceTier.map(JSONValue.string) ?? .null
        if let outputSchema {
            params["outputSchema"] = outputSchema
        }
        let response = try await sendRequest(
            method: "turn/start",
            params: params
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

    public func respond(to id: JSONValue, result: JSONValue) async throws {
        try await writeMessage(.object(["id": id, "result": result]))
    }

    public func respondWithError(
        to id: JSONValue,
        code: Int64 = -32_000,
        message: String
    ) async throws {
        try await writeMessage(.object([
            "id": id,
            "error": .object(["code": .integer(code), "message": .string(message)])
        ]))
    }

    private func sendRequest(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        guard let generation = activeProcessGeneration,
              process != nil,
              let writer = inputWriter else { throw AppServerClientError.notRunning }
        guard pendingRequests.count < Self.maximumPendingRequestCount else {
            throw AppServerClientError.invalidResponse(
                "too many App Server requests are already awaiting transport"
            )
        }
        try Task.checkCancellation()
        if let requestRegistrationHook {
            await requestRegistrationHook(method)
        }
        try Task.checkCancellation()
        guard activeProcessGeneration == generation,
              inputWriter === writer else { throw AppServerClientError.notRunning }
        requestIdentifier += 1
        let identifier = requestIdentifier
        let writeToken = UUID()
        let message = JSONValue.object([
            "id": .integer(identifier),
            "method": .string(method),
            "params": .object(params)
        ])
        var data = try message.encodedData()
        data.append(0x0A)

        let timeout = Self.isControlRequest(method) ? controlRequestTimeout : requestTimeout
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.timeoutRequest(identifier: identifier)
                }
                pendingRequests[identifier] = PendingRequest(
                    method: method,
                    continuation: continuation,
                    timeoutTask: timeoutTask,
                    writeToken: writeToken,
                    writeState: .queued
                )
                if Task.isCancelled {
                    guard let pending = pendingRequests.removeValue(forKey: identifier) else {
                        return
                    }
                    pending.timeoutTask.cancel()
                    pending.continuation.resume(throwing: CancellationError())
                    return
                }
                Self.scheduleRequestWrite(
                    data: data,
                    writer: writer,
                    identifier: identifier,
                    token: writeToken,
                    generation: generation,
                    client: self
                )
            }
        } onCancel: {
            Task { await self.cancelRequest(identifier: identifier) }
        }
        if !Self.requiresMutationOutcome(method) {
            try Task.checkCancellation()
        }
        return result
    }

    private nonisolated static func scheduleRequestWrite(
        data: sending Data,
        writer: OrderedPipeWriter,
        identifier: Int64,
        token: UUID,
        generation: Int64,
        client: CodexAppServerClient
    ) {
        Task {
            do {
                try await writer.write(data, token: token)
                await client.requestWriteFinished(
                    identifier: identifier,
                    token: token,
                    generation: generation,
                    result: .success(())
                )
            } catch {
                await client.requestWriteFinished(
                    identifier: identifier,
                    token: token,
                    generation: generation,
                    result: .failure(error)
                )
            }
        }
    }

    private func cancelRequest(identifier: Int64) {
        guard let pending = pendingRequests[identifier] else { return }
        let disposition: OrderedPipeWriter.CancellationDisposition =
            pending.writeState == .completed
                ? .completed
                : inputWriter?.cancel(token: pending.writeToken) ?? .unknown
        let definitelyWritten = disposition == .completed
        if Self.requiresMutationOutcome(pending.method), definitelyWritten {
            // Preserve the definitive server response after a complete write so
            // the provider can reconcile and release the accepted resource.
            return
        }
        pendingRequests.removeValue(forKey: identifier)
        pending.timeoutTask.cancel()
        retireRequestID(identifier)
        pending.continuation.resume(throwing: CancellationError())
        if disposition == .writing || disposition == .failedAfterPartialWrite,
           let generation = activeProcessGeneration {
            // A partial JSON write is unrecoverable and its acceptance is
            // ambiguous. Tear down the entire isolated generation.
            beginTermination(generation: generation, suppressExitEvent: false)
        }
    }

    private func timeoutRequest(identifier: Int64) {
        guard let pending = pendingRequests.removeValue(forKey: identifier) else { return }
        let disposition: OrderedPipeWriter.CancellationDisposition =
            pending.writeState == .completed
                ? .completed
                : inputWriter?.cancel(token: pending.writeToken) ?? .unknown
        retireRequestID(identifier)
        pending.continuation.resume(
            throwing: AppServerClientError.requestTimedOut(method: pending.method)
        )
        let definitelyWritten = disposition == .completed
        if disposition == .writing
            || disposition == .failedAfterPartialWrite
            || Self.requiresMutationOutcome(pending.method) && definitelyWritten {
            // A deadline cannot prove whether a mutating request was accepted.
            // Terminate this generation so no untracked thread or turn can keep
            // running. The ordinary EOF/termination path publishes `.exited`
            // and clears the process, allowing the application to restart it.
            if let generation = activeProcessGeneration {
                beginTermination(generation: generation, suppressExitEvent: false)
            }
        }
    }

    private func requestWriteFinished(
        identifier: Int64,
        token: UUID,
        generation: Int64,
        result: Result<Void, any Error>
    ) async {
        defer { inputWriter?.forget(token: token) }
        guard activeProcessGeneration == generation,
              var pending = pendingRequests[identifier],
              pending.writeToken == token else { return }
        switch result {
        case .success:
            pending.writeState = .completed
            pendingRequests[identifier] = pending
        case .failure(let error):
            pendingRequests.removeValue(forKey: identifier)
            pending.timeoutTask.cancel()
            retireRequestID(identifier)
            pending.continuation.resume(throwing: error)
            if !(error is CancellationError), !Self.isLocalWriteAdmissionError(error) {
                exitDiagnostics[generation] =
                    "Codex App Server stdin failed; terminating this transport generation: \(error.localizedDescription)"
                beginTermination(generation: generation, suppressExitEvent: false)
            }
        }
    }

    private func retireRequestID(_ identifier: Int64) {
        guard retiredRequestIDs.insert(identifier).inserted else { return }
        retiredRequestOrder.append(identifier)
        let maximumRetiredRequestCount = 256
        if retiredRequestOrder.count > maximumRetiredRequestCount {
            let expiredCount = retiredRequestOrder.count - maximumRetiredRequestCount
            let expired = Array(retiredRequestOrder.prefix(expiredCount))
            retiredRequestOrder.removeFirst(expiredCount)
            retiredRequestIDs.subtract(expired)
        }
    }

    private nonisolated static func isControlRequest(_ method: String) -> Bool {
        switch method {
        case "initialize", "turn/interrupt", "thread/delete", "thread/unsubscribe",
             "thread/loaded/list", "thread/backgroundTerminals/clean",
             "thread/backgroundTerminals/list": true
        default: false
        }
    }

    private nonisolated static func requiresMutationOutcome(_ method: String) -> Bool {
        switch method {
        case "thread/delete", "thread/start", "thread/resume", "thread/unsubscribe",
             "thread/backgroundTerminals/clean", "turn/start", "turn/steer": true
        default: false
        }
    }

    private nonisolated static func isLocalWriteAdmissionError(_ error: any Error) -> Bool {
        guard let error = error as? AppServerClientError else { return false }
        if case .invalidResponse(let detail) = error {
            return detail.contains("write queue reached its")
        }
        return false
    }

    private func sendNotification(method: String, params: JSONValue?) async throws {
        var message: [String: JSONValue] = ["method": .string(method)]
        if let params {
            message["params"] = params
        }
        try await writeMessage(.object(message))
    }

    private func writeMessage(_ message: JSONValue) async throws {
        guard let generation = activeProcessGeneration,
              let writer = inputWriter else { throw AppServerClientError.notRunning }
        var data = try message.encodedData()
        data.append(0x0A)
        let token = UUID()
        defer { writer.forget(token: token) }
        do {
            let result = try await Self.raceDirectWrite(
                data: data,
                writer: writer,
                token: token,
                timeout: directWriteTimeout
            )
            switch result {
            case .completed:
                break
            case .deadline:
                let disposition = writer.cancel(token: token)
                switch disposition {
                case .writing, .completed, .failedAfterPartialWrite, .unknown:
                    // Once a direct protocol response may have reached the
                    // pipe, the peer's acceptance is ambiguous. Tear down the
                    // generation rather than leaving the sole event pump
                    // indefinitely wedged behind a full stdin pipe.
                    beginTermination(generation: generation, suppressExitEvent: false)
                case .cancelledBeforeWrite:
                    break
                }
                throw AppServerClientError.requestTimedOut(method: "direct message write")
            }
        } catch {
            let disposition = writer.cancel(token: token)
            if disposition == .writing || disposition == .failedAfterPartialWrite {
                beginTermination(generation: generation, suppressExitEvent: false)
            }
            throw error
        }
        guard activeProcessGeneration == generation else {
            throw AppServerClientError.notRunning
        }
    }

    private nonisolated static func raceDirectWrite(
        data: sending Data,
        writer: OrderedPipeWriter,
        token: UUID,
        timeout: Duration
    ) async throws -> DirectWriteRaceResult {
        let writeData = data
        return try await withThrowingTaskGroup(of: DirectWriteRaceResult.self) { group in
            group.addTask {
                try await writer.write(writeData, token: token)
                return .completed
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return directWriteCompletedAtDeadline(writer.cancel(token: token))
                    ? .completed
                    : .deadline
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw AppServerClientError.notRunning
            }
            return first
        }
    }

    nonisolated static func directWriteCompletedAtDeadline(
        _ disposition: OrderedPipeWriter.CancellationDisposition
    ) -> Bool {
        if case .completed = disposition { return true }
        return false
    }

    private func consumeOutput(_ data: Data, generation: Int64) async {
        guard activeProcessGeneration == generation else { return }
        outputBuffer.append(data)
        while outputScanOffset < outputBuffer.count {
            let searchStart = outputBuffer.index(
                outputBuffer.startIndex,
                offsetBy: outputScanOffset
            )
            guard let newline = outputBuffer[searchStart...].firstIndex(of: 0x0A) else {
                outputScanOffset = outputBuffer.count
                break
            }
            let lineData = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            outputScanOffset = 0
            guard !lineData.isEmpty else { continue }
            guard lineData.count <= Self.maximumJSONLineByteCount else {
                await failOversizedOutput(generation: generation, byteCount: lineData.count)
                return
            }
            guard await handleLine(Data(lineData), generation: generation) else {
                outputBuffer.removeAll(keepingCapacity: true)
                outputScanOffset = 0
                return
            }
        }
        if outputBuffer.count > Self.maximumJSONLineByteCount {
            await failOversizedOutput(generation: generation, byteCount: outputBuffer.count)
        }
    }

    private func handleLine(_ data: Data, generation: Int64) async -> Bool {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return await admitOrdinaryEvent(AppServerTransportEvent(
                generation: generation,
                event: .standardError(
                    "Invalid App Server JSON: \(Self.diagnosticPreview(for: data))"
                )
            ))
        }

        if let identifier = message["id"]?.integerValue,
           message["method"] == nil {
            if let pending = pendingRequests.removeValue(forKey: identifier) {
                pending.timeoutTask.cancel()
                if let error = message["error"] {
                    pending.continuation.resume(throwing: AppServerClientError.requestFailed(
                        code: error["code"]?.integerValue,
                        message: error["message"]?.stringValue ?? error.encodedString()
                    ))
                } else {
                    pending.continuation.resume(returning: message["result"] ?? .null)
                }
                return true
            }
            if retiredRequestIDs.contains(identifier) { return true }
        }

        guard let method = message["method"]?.stringValue else {
            return await admitOrdinaryEvent(AppServerTransportEvent(
                generation: generation,
                event: .standardError(
                    "Unrecognized App Server message: \(Self.diagnosticPreview(for: data))"
                )
            ))
        }
        let rawLine = String(decoding: data, as: UTF8.self)
        let params = message["params"] ?? .object([:])
        if let id = message["id"] {
            return await admitOrdinaryEvent(AppServerTransportEvent(
                generation: generation,
                event: .request(
                    id: id,
                    method: method,
                    params: params,
                    rawLine: rawLine
                )
            ))
        } else {
            return await admitOrdinaryEvent(AppServerTransportEvent(
                generation: generation,
                event: .notification(
                    method: method,
                    params: params,
                    rawLine: rawLine
                )
            ))
        }
    }

    private func emitStandardError(_ text: String, generation: Int64) async {
        guard activeProcessGeneration == generation else { return }
        _ = await admitOrdinaryEvent(AppServerTransportEvent(
            generation: generation,
            event: .standardError(text)
        ))
    }

    /// Normal routing applies bounded backpressure so transient bursts do not
    /// kill a healthy generation. AppModel explicitly pauses routing while it
    /// owns the lifecycle lease during bootstrap/restart; only in that mode must
    /// protocol parsing remain nonblocking, because an initialize/model-list
    /// response can sit behind notifications in the same stdout chunk.
    private func admitOrdinaryEvent(
        _ transportEvent: AppServerTransportEvent
    ) async -> Bool {
        let generation = transportEvent.generation
        guard activeProcessGeneration == generation else { return false }
        if eventRoutingPauses.isEmpty {
            let accepted = await eventChannel.send(transportEvent)
            guard !accepted else { return true }
            guard activeProcessGeneration == generation,
                  clearingProcessGeneration == nil else { return false }
            let detail =
                "The bounded Codex App Server event channel could not accept a backpressured event. Codeness terminated generation \(generation) because its protocol events could not be delivered safely."
            failPendingRequests(with: AppServerClientError.invalidResponse(detail))
            exitDiagnostics[generation] = detail
            beginTermination(generation: generation, suppressExitEvent: false)
            return false
        }

        switch await eventChannel.trySend(transportEvent) {
        case .accepted:
            return true
        case .full:
            guard activeProcessGeneration == generation else { return false }
            let detail =
                "Codex App Server produced events faster than Codeness could route the bounded event backlog. Codeness terminated generation \(generation) instead of blocking protocol responses or retaining unbounded memory."
            failPendingRequests(with: AppServerClientError.invalidResponse(detail))
            exitDiagnostics[generation] = detail
            beginTermination(generation: generation, suppressExitEvent: false)
            return false
        case .terminated:
            guard activeProcessGeneration == generation else { return false }
            let detail =
                "The bounded Codex App Server event channel was unavailable. Codeness terminated generation \(generation) because its protocol events could not be delivered safely."
            failPendingRequests(with: AppServerClientError.invalidResponse(detail))
            exitDiagnostics[generation] = detail
            beginTermination(generation: generation, suppressExitEvent: false)
            return false
        }
    }

    private func outputReachedEOF(generation: Int64) async {
        guard activeProcessGeneration == generation else { return }
        if !outputBuffer.isEmpty {
            let finalLine = outputBuffer
            outputBuffer.removeAll(keepingCapacity: true)
            outputScanOffset = 0
            if finalLine.count <= Self.maximumJSONLineByteCount {
                _ = await handleLine(finalLine, generation: generation)
            } else {
                await failOversizedOutput(generation: generation, byteCount: finalLine.count)
            }
        }
        outputEOFGeneration = generation
        if terminatedProcess?.generation != generation, terminationTask == nil {
            exitDiagnostics[generation] =
                "Codex App Server closed stdout while its process was still running; Codeness stopped the isolated process group to avoid a permanently unresponsive transport."
            beginTermination(generation: generation, suppressExitEvent: false)
        }
        await finishProcessExitIfReady(generation: generation)
    }

    private func processTerminated(
        _ termination: SubprocessTermination,
        generation: Int64
    ) async {
        guard activeProcessGeneration == generation else { return }
        terminatedProcess = (generation, termination)
        inputWriter?.close()

        if process?.ownedProcessesExist == true {
            _ = process?.signalOwnedProcesses(SIGTERM)
            scheduleTerminationEscalation(generation: generation)
        } else {
            processGroupCleanupGeneration = generation
        }
        if outputEOFGeneration != generation {
            scheduleOutputDrainDeadline(generation: generation)
        }
        await finishProcessExitIfReady(generation: generation)
    }

    private func finishProcessExitIfReady(generation: Int64) async {
        guard activeProcessGeneration == generation,
              clearingProcessGeneration == nil,
              outputEOFGeneration == generation,
              processGroupCleanupGeneration == generation,
              let terminatedProcess,
              terminatedProcess.generation == generation else { return }
        clearingProcessGeneration = generation
        let termination = terminatedProcess.termination
        failPendingRequests(with: AppServerClientError.processExited(termination))
        let publishExit = suppressedExitGenerations.remove(generation) == nil
        let diagnostic = exitDiagnostics.removeValue(forKey: generation)
        // Reject any stdout/stderr send still suspended behind event
        // backpressure before admitting this generation's final events.
        await outputReader?.stop(cancelConsumer: true)
        await errorReader?.stop(cancelConsumer: true)
        // Relinquish OS resources first, but retain the generation ownership
        // token through terminal admission. `start` must not admit N+1 until
        // diagnostic/exit overflow is known and no late teardown operation can
        // affect the replacement channel.
        await clearProcessResources(generation: generation)
        if let diagnostic {
            if !(await eventChannel.sendForTeardown(AppServerTransportEvent(
                generation: generation,
                event: .standardError(diagnostic)
            ))) {
                recordTerminalDeliveryOverflow(generation: generation)
            }
        }
        if publishExit {
            if !(await eventChannel.sendForTeardown(AppServerTransportEvent(
                generation: generation,
                event: .exited(termination)
            ))) {
                recordTerminalDeliveryOverflow(generation: generation)
            }
        }
        await completeProcessClear(generation: generation)
    }

    private func stopProcess(suppressExitEvent: Bool) async {
        guard let generation = activeProcessGeneration else { return }
        failPendingRequests(with: AppServerClientError.notRunning)
        beginTermination(
            generation: generation,
            suppressExitEvent: suppressExitEvent
        )
    }

    private func beginTermination(generation: Int64, suppressExitEvent: Bool) {
        guard activeProcessGeneration == generation, let process else { return }
        if suppressExitEvent {
            suppressedExitGenerations.insert(generation)
        }
        inputWriter?.close()
        _ = process.signalOwnedProcesses(SIGTERM)
        scheduleTerminationEscalation(generation: generation)
    }

    private func scheduleTerminationEscalation(generation: Int64) {
        guard terminationTask == nil else { return }
        let token = UUID()
        terminationTaskGeneration = generation
        terminationTaskToken = token
        terminationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.terminationGrace)
            } catch {
                await self.terminationEscalationTaskEnded(
                    generation: generation,
                    token: token
                )
                return
            }
            await self.escalateTermination(generation: generation, token: token)
        }
    }

    private func escalateTermination(generation: Int64, token: UUID) async {
        defer {
            clearTerminationEscalationTask(generation: generation, token: token)
        }
        guard activeProcessGeneration == generation, let process else { return }
        terminationEscalationAttempt &+= 1
        let maySignal = terminationSignalPermission?(terminationEscalationAttempt) ?? true
        if process.ownedProcessesExist {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .milliseconds(750))
            repeat {
                if maySignal {
                    _ = process.signalOwnedProcesses(SIGKILL)
                }
                let sweepDeadline = min(
                    deadline,
                    clock.now.advanced(by: .milliseconds(100))
                )
                while process.trackedProcessesExist, clock.now < sweepDeadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            } while process.ownedProcessesExist && clock.now < deadline
        }
        guard !process.ownedProcessesExist else {
            let scopeDetail = process.scopeFailureDescription.map { " (\($0))" } ?? ""
            exitDiagnostics[generation] =
                "SIGKILL did not remove every process owned by Codex App Server scope \(process.processGroupIdentifier)\(scopeDetail); restart remains blocked."
            return
        }
        processGroupCleanupGeneration = generation
        await finishProcessExitIfReady(generation: generation)
    }

    private func terminationEscalationTaskEnded(generation: Int64, token: UUID) async {
        clearTerminationEscalationTask(generation: generation, token: token)
        guard activeProcessGeneration == generation,
              processGroupCleanupGeneration != generation,
              let process,
              !process.ownedProcessesExist else { return }
        processGroupCleanupGeneration = generation
        await finishProcessExitIfReady(generation: generation)
    }

    private func clearTerminationEscalationTask(generation: Int64, token: UUID) {
        guard terminationTaskGeneration == generation,
              terminationTaskToken == token else { return }
        terminationTask = nil
        terminationTaskGeneration = nil
        terminationTaskToken = nil
    }

    private func scheduleOutputDrainDeadline(generation: Int64) {
        guard outputDrainTask == nil else { return }
        outputDrainTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.outputDrainGrace)
            } catch {
                return
            }
            await self.forceOutputDrainCompletion(generation: generation)
        }
    }

    private func forceOutputDrainCompletion(generation: Int64) async {
        guard activeProcessGeneration == generation,
              outputEOFGeneration != generation else { return }
        await outputReader?.stop(cancelConsumer: true)
        await errorReader?.stop(cancelConsumer: true)
        let pendingByteCount = outputBuffer.count
        outputBuffer.removeAll(keepingCapacity: true)
        outputScanOffset = 0
        exitDiagnostics[generation] = pendingByteCount == 0
            ? "Codex App Server stdout did not close after its parent exited; stopped its inherited pipe after the bounded drain window."
            : "Codex App Server stdout did not close after its parent exited; discarded an incomplete \(pendingByteCount)-byte JSONL fragment after the bounded drain window."
        outputEOFGeneration = generation
        await finishProcessExitIfReady(generation: generation)
    }

    private func failOversizedOutput(generation: Int64, byteCount: Int) async {
        guard activeProcessGeneration == generation else { return }
        beginTermination(generation: generation, suppressExitEvent: false)
        outputBuffer.removeAll(keepingCapacity: true)
        outputScanOffset = 0
        exitDiagnostics[generation] =
            "Codex App Server emitted a JSONL message larger than the \(Self.maximumJSONLineByteCount)-byte transport limit (at least \(byteCount) bytes); terminated the generation without truncating it."
    }

    private func recordTerminalDeliveryOverflow(generation: Int64) {
        terminalDeliveryOverflow =
            "the bounded App Server event channel could not retain generation \(generation)'s terminal event; restart is blocked until Codeness is relaunched so the loss cannot be hidden"
    }

    private nonisolated static func diagnosticPreview(for data: Data) -> String {
        guard data.count > maximumDiagnosticJSONPreviewByteCount else {
            return String(decoding: data, as: UTF8.self)
        }
        let prefix = data.prefix(maximumDiagnosticJSONPreviewByteCount)
        return "\(String(decoding: prefix, as: UTF8.self))… [\(data.count) bytes total]"
    }

    private nonisolated static func retainedEventByteCost(
        _ transportEvent: AppServerTransportEvent
    ) -> Int {
        switch transportEvent.event {
        case .notification(_, _, let rawLine), .request(_, _, _, let rawLine):
            // The decoded JSON tree and authoritative raw line coexist in an
            // AppServerEvent. Charge three times the wire size as a conservative
            // retention estimate while keeping tiny-delta count capacity useful.
            let byteCount = rawLine.utf8.count
            guard byteCount <= Int.max / 3 else { return Int.max }
            return max(1, byteCount * 3)
        case .standardError(let detail):
            return max(1, detail.utf8.count)
        case .exited:
            return 1
        }
    }

    private func clearProcessResources(generation: Int64) async {
        guard activeProcessGeneration == generation,
              clearingProcessGeneration == generation else { return }
        let writer = inputWriter
        writer?.close()
        await outputReader?.stop(cancelConsumer: true)
        await errorReader?.stop(cancelConsumer: true)
        await writer?.closeAndWait()
        outputReader = nil
        errorReader = nil
        inputWriter = nil
        await process?.stopMonitoringOwnedProcesses()
        process = nil
        processWaitTask?.cancel()
        processWaitTask = nil
        terminationTask?.cancel()
        terminationTask = nil
        terminationTaskGeneration = nil
        terminationTaskToken = nil
        terminationEscalationAttempt = 0
        outputDrainTask?.cancel()
        outputDrainTask = nil
        terminatedProcess = nil
        outputEOFGeneration = nil
        processGroupCleanupGeneration = nil
        outputBuffer.removeAll(keepingCapacity: true)
        outputScanOffset = 0
    }

    private func completeProcessClear(generation: Int64) async {
        guard activeProcessGeneration == generation,
              clearingProcessGeneration == generation else { return }
        await beforeProcessClearCompletionHook?(generation)
        guard activeProcessGeneration == generation,
              clearingProcessGeneration == generation else { return }
        clearingProcessGeneration = nil
        // This is deliberately the final cleanup mutation. `isRunning`,
        // `start`, and generation-cleanup waiters must continue to regard the
        // generation as owned while any awaited teardown step (including the
        // deterministic test hook above) is incomplete.
        activeProcessGeneration = nil
    }

    private func failPendingRequests(with error: any Error) {
        for pending in pendingRequests.values {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
    }

    private nonisolated static func makeProcessWaiter(
        process: AppServerProcess,
        generation: Int64,
        client: CodexAppServerClient
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak client] in
            var waitStatus: Int32 = 0
            var result: pid_t
            while true {
                result = unsafe waitpid(process.processIdentifier, &waitStatus, 0)
                if result == -1, errno == EINTR { continue }
                break
            }
            let termination: SubprocessTermination
            if result == process.processIdentifier {
                let signal = waitStatus & 0x7F
                termination = signal == 0
                    ? SubprocessTermination(reason: .exit, status: (waitStatus >> 8) & 0xFF)
                    : SubprocessTermination(reason: .uncaughtSignal, status: signal)
            } else {
                termination = SubprocessTermination(reason: .exit, status: -1)
            }
            await client?.processTerminated(termination, generation: generation)
        }
    }

    private static func decodeModel(_ value: JSONValue) -> CodexModel? {
        guard let id = value["id"]?.stringValue,
              let model = value["model"]?.stringValue,
              let displayName = value["displayName"]?.stringValue,
              let defaultEffort = value["defaultReasoningEffort"]?.stringValue else { return nil }
        let efforts = value["supportedReasoningEfforts"]?.arrayValue?
            .compactMap { $0["reasoningEffort"]?.stringValue } ?? []
        let serviceTiers = value["serviceTiers"]?.arrayValue?.compactMap { tier -> CodexServiceTier? in
            guard let id = tier["id"]?.stringValue,
                  let name = tier["name"]?.stringValue else { return nil }
            return CodexServiceTier(
                id: id,
                name: name,
                description: tier["description"]?.stringValue ?? ""
            )
        } ?? []
        return CodexModel(
            id: id,
            model: model,
            displayName: displayName,
            description: value["description"]?.stringValue ?? "",
            defaultEffort: defaultEffort,
            efforts: efforts,
            hidden: value["hidden"]?.boolValue ?? false,
            serviceTiers: serviceTiers,
            defaultServiceTier: value["defaultServiceTier"]?.stringValue
        )
    }

    private static func isOptionalUnsignedInteger(
        _ value: JSONValue?,
        maximum: Double
    ) -> Bool {
        switch value {
        case nil, .some(.null):
            true
        case .some(.integer(let value)):
            value >= 0 && Double(value) <= maximum
        case .some(.number(let value)):
            value.isFinite
                && value >= 0
                && value <= maximum
                && value.rounded(.towardZero) == value
        default:
            false
        }
    }

    private static func isOptionalFiniteNumber(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .some(.null): true
        case .some(.integer): true
        case .some(.number(let value)): value.isFinite
        default: false
        }
    }

    private static func retainedByteCount(of model: CodexModel) -> Int {
        var count = 128
        for value in [
            model.id,
            model.model,
            model.displayName,
            model.description,
            model.defaultEffort,
            model.defaultServiceTier ?? ""
        ] + model.efforts {
            count = saturatingByteSum(count, value.utf8.count)
        }
        for tier in model.serviceTiers {
            count = saturatingByteSum(count, tier.id.utf8.count)
            count = saturatingByteSum(count, tier.name.utf8.count)
            count = saturatingByteSum(count, tier.description.utf8.count)
        }
        return count
    }

    private static func saturatingByteSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
