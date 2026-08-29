import CryptoKit
import Foundation

/// An agent provider for servers exposing the widely implemented
/// `/chat/completions` API shape. The provider keeps the conversation locally
/// and supplies a small repository-tool bridge, which means compatible models
/// can participate in both workflow steps and coordinator calls.
public actor OpenAICompatibleAgentProvider: AgentProviding {
    public nonisolated let id = AgentProviderID.openAICompatible
    public nonisolated let displayName: String

    private struct SessionConfiguration {
        let id: String
        var messages: [JSONValue]
        var companyToolPolicy: CompanyToolPolicy?
    }

    private struct ActiveRun {
        let sessionID: String
        let cwd: String
        let target: AgentTarget
        let outputSchema: JSONValue?
        let startedAt: Date
        let events: BoundedAsyncChannel<AgentEvent>
        var steeringMessages: [String]
        var interruptRequested: Bool
    }

    private struct ToolCall {
        let id: String
        let name: String
        let arguments: JSONValue
    }

    private struct CompletionResponse {
        let content: String
        let reasoning: String
        let reasoningPayload: ReasoningPayload?
        let toolCalls: [ToolCall]
        let usage: RunTokenUsage?
        let finishReason: String?
    }

    private struct ReasoningPayload {
        let field: String
        let value: JSONValue
    }

    private struct ToolLoopDetector {
        private static let historyLimit = 16
        private var recentActivityHashes: [Data] = []
        private var repeatedActivityCount = 0

        mutating func record(_ activityHash: Data) -> Bool {
            if recentActivityHashes.contains(activityHash) {
                repeatedActivityCount += 1
            } else {
                repeatedActivityCount = 0
            }
            recentActivityHashes.append(activityHash)
            if recentActivityHashes.count > Self.historyLimit {
                recentActivityHashes.removeFirst()
            }
            return repeatedActivityCount >= Self.historyLimit
        }

        mutating func reset() {
            repeatedActivityCount = 0
        }
    }

    private let configuration: OpenAICompatibleProviderConfiguration
    private let transport: any HTTPTransport
    private let keyLoader: any APIKeyLoading
    private let eventBufferCapacity: Int
    private let maximumEventBufferRetainedBytes: Int
    private let maximumRequestByteCount: Int
    private let maximumResponseByteCount: Int
    private var sessions: [String: SessionConfiguration] = [:]
    private var activeRuns: [UUID: ActiveRun] = [:]
    private var runTasks: [UUID: Task<Void, Never>] = [:]
    private var isShuttingDown = false

    public init(
        configuration: OpenAICompatibleProviderConfiguration,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        keyLoader: any APIKeyLoading = JSONAPIKeyLoader(),
        eventBufferCapacity: Int = 64,
        maximumEventBufferRetainedBytes: Int = 4 * 1_024 * 1_024,
        maximumRequestByteCount: Int = 32 * 1_024 * 1_024,
        maximumResponseByteCount: Int = 4 * 1_024 * 1_024
    ) {
        self.configuration = configuration
        displayName = configuration.displayName
        self.transport = transport
        self.keyLoader = keyLoader
        self.eventBufferCapacity = max(1, eventBufferCapacity)
        let retainedByteLimit = max(1_024, maximumEventBufferRetainedBytes)
        self.maximumEventBufferRetainedBytes = retainedByteLimit
        self.maximumRequestByteCount = max(1_024, maximumRequestByteCount)
        self.maximumResponseByteCount = max(
            256,
            min(maximumResponseByteCount, retainedByteLimit - 256)
        )
    }

    public func prepareSession(_ request: AgentSessionRequest) throws -> AgentSession {
        guard request.target.providerID == id else {
            throw AgentProviderError.unsupportedProvider(request.target.providerID)
        }
        try validateConfiguration()
        let sessionID = request.existingSessionID ?? UUID().uuidString.lowercased()
        if var existing = sessions[sessionID] {
            let systemMessage = Self.systemMessage(
                instructions: request.developerInstructions,
                outputSchema: nil,
                mode: request.target.options.mode,
                companyToolPolicy: request.companyToolPolicy
            )
            if existing.messages.isEmpty {
                existing.messages = [systemMessage]
            } else {
                existing.messages[0] = systemMessage
            }
            existing.companyToolPolicy = request.companyToolPolicy
            sessions[sessionID] = existing
        } else {
            sessions[sessionID] = SessionConfiguration(
                id: sessionID,
                messages: [
                    Self.systemMessage(
                        instructions: request.developerInstructions,
                        outputSchema: nil,
                        mode: request.target.options.mode,
                        companyToolPolicy: request.companyToolPolicy
                    )
                ],
                companyToolPolicy: request.companyToolPolicy
            )
        }
        return AgentSession(providerID: id, id: sessionID, target: request.target)
    }

    public func startRun(_ request: AgentRunRequest) async throws -> AgentRunHandle {
        guard request.target.providerID == id, request.session.providerID == id else {
            throw AgentProviderError.unsupportedProvider(request.target.providerID)
        }
        guard !isShuttingDown else {
            throw AgentProviderError.resourceLimit(
                "The \(configuration.displayName) provider is shutting down."
            )
        }
        guard var session = sessions[request.session.id] else {
            throw AgentProviderError.invalidSession(
                "\(configuration.displayName) session \(request.session.id) was not prepared"
            )
        }
        guard activeRuns.values.allSatisfy({ $0.sessionID != session.id }) else {
            throw AgentProviderError.invalidSession(
                "\(configuration.displayName) session \(session.id) already has an active run."
            )
        }
        guard !request.target.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentProviderError.invalidResponse("the \(configuration.displayName) model is empty")
        }
        session.messages.append(.object([
            "role": .string("user"),
            "content": .string(request.prompt)
        ]))
        sessions[session.id] = session

        let events = BoundedAsyncChannel<AgentEvent>(
            capacity: eventBufferCapacity,
            maximumRetainedCost: maximumEventBufferRetainedBytes,
            retainedCost: Self.retainedCost(of:)
        )
        activeRuns[request.runID] = ActiveRun(
            sessionID: session.id,
            cwd: request.cwd,
            target: request.target,
            outputSchema: request.outputSchema,
            startedAt: Date(),
            events: events,
            steeringMessages: [],
            interruptRequested: false
        )
        runTasks[request.runID] = Task { [weak self] in
            await self?.execute(runID: request.runID)
        }
        return AgentRunHandle(
            runID: request.runID,
            providerID: id,
            sessionID: session.id,
            executionID: request.runID.uuidString,
            events: events.stream(
                cancelChannelOnConsumerCancellation: true,
                onConsumerCancellation: { [weak self] in
                    await self?.cancelRunAfterConsumerTermination(runID: request.runID)
                }
            )
        )
    }

    public func steer(runID: UUID, message: String) async throws {
        guard var run = activeRuns[runID] else {
            throw AgentProviderError.missingRun(runID)
        }
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMessage.isEmpty else { return }
        run.steeringMessages.append(cleanMessage)
        activeRuns[runID] = run
    }

    public func interrupt(runID: UUID) async throws {
        guard var run = activeRuns[runID] else {
            throw AgentProviderError.missingRun(runID)
        }
        run.interruptRequested = true
        activeRuns[runID] = run
        runTasks[runID]?.cancel()
    }

    public func resolveInteraction(
        runID: UUID,
        interactionID: String,
        resolution: AgentInteractionResolution
    ) async throws {
        _ = interactionID
        _ = resolution
        guard activeRuns[runID] != nil else {
            throw AgentProviderError.missingRun(runID)
        }
        throw AgentProviderError.invalidResponse(
            "the \(configuration.displayName) provider does not expose interactive approval requests"
        )
    }

    public func runUtility(_ request: AgentUtilityRequest) async throws -> AgentUtilityResult {
        let session = try prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Codeness coordinator",
                cwd: request.cwd,
                target: request.target,
                developerInstructions: request.developerInstructions
            )
        )
        let runID = UUID()
        let handle = try await startRun(
            AgentRunRequest(
                runID: runID,
                session: session,
                cwd: request.cwd,
                prompt: request.prompt,
                target: request.target,
                outputSchema: request.outputSchema
            )
        )
        do {
            for await event in handle.events {
                switch event {
                case .completed(let output, _, let tokenUsage):
                    _ = await releaseSession(id: session.id)
                    return AgentUtilityResult(output: output, tokenUsage: tokenUsage)
                case .failed(let detail):
                    _ = await releaseSession(id: session.id)
                    throw AgentProviderError.invalidResponse(detail)
                case .interrupted(let detail):
                    _ = await releaseSession(id: session.id)
                    throw AgentProviderError.invalidResponse(
                        detail ?? "The \(configuration.displayName) coordinator run was interrupted."
                    )
                case .sessionUnavailable(let detail):
                    _ = await releaseSession(id: session.id)
                    throw AgentProviderError.invalidResponse(detail)
                case .started, .transcript, .diagnostic, .tokenUsage, .interaction,
                     .interactionResolved:
                    continue
                }
            }
            _ = await releaseSession(id: session.id)
            throw AgentProviderError.invalidResponse(
                "the \(configuration.displayName) coordinator run ended without a result"
            )
        } catch is CancellationError {
            try? await interrupt(runID: runID)
            _ = await releaseSession(id: session.id)
            throw CancellationError()
        } catch {
            _ = await releaseSession(id: session.id)
            throw error
        }
    }

    @discardableResult
    public func releaseSession(id sessionID: String) async -> Bool {
        guard !activeRuns.values.contains(where: { $0.sessionID == sessionID }) else {
            return false
        }
        sessions.removeValue(forKey: sessionID)
        return true
    }

    public func shutdown() async {
        _ = await shutdownAndVerify()
    }

    @discardableResult
    public func shutdownAndVerify() async -> Bool {
        isShuttingDown = true
        let tasks = Array(runTasks.values)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
        return activeRuns.isEmpty
    }

    private func validateConfiguration() throws {
        guard configuration.validationMessage == nil,
              configuration.endpointURL != nil else {
            throw AgentProviderError.namedUnavailable(
                displayName: configuration.displayName,
                detail: configuration.validationMessage ?? "The endpoint is invalid."
            )
        }
    }

    private func execute(runID: UUID) async {
        guard let initialRun = activeRuns[runID] else { return }
        guard await emit(.started(executionID: runID.uuidString), runID: runID) else {
            await finish(
                runID: runID,
                terminalEvent: .failed("The event consumer stopped before the run began.")
            )
            return
        }
        var loopDetector = ToolLoopDetector()
        var accumulatedUsage: RunTokenUsage?

        do {
            while true {
                try Task.checkCancellation()
                if await applyPendingSteeringMessages(runID: runID) {
                    loopDetector.reset()
                }
                guard let run = activeRuns[runID],
                      let session = sessions[initialRun.sessionID] else {
                    throw AgentProviderError.missingRun(runID)
                }
                let response = try await complete(
                    messages: session.messages,
                    target: run.target,
                    mode: run.target.options.mode,
                    outputSchema: run.outputSchema,
                    companyToolPolicy: session.companyToolPolicy
                )
                try Task.checkCancellation()

                if let usage = response.usage {
                    let cumulativeUsage = accumulatedUsage?.adding(usage) ?? usage
                    accumulatedUsage = cumulativeUsage
                    guard await emit(.tokenUsage(cumulativeUsage), runID: runID) else {
                        throw CancellationError()
                    }
                }

                if !response.reasoning.isEmpty {
                    guard await emit(
                        .transcript(
                            RunTranscriptPresentation.storedText(
                                "\n\nReasoning\n\(response.reasoning)\n",
                                section: .reasoning
                            )
                        ),
                        runID: runID
                    ) else { throw CancellationError() }
                }

                if response.finishReason == "length" {
                    throw AgentProviderError.resourceLimit(
                        "The \(configuration.displayName) endpoint stopped because the model reached its output or context limit."
                    )
                }
                if response.finishReason == "content_filter" {
                    throw AgentProviderError.invalidResponse(
                        "the \(configuration.displayName) endpoint stopped the response with its content filter"
                    )
                }

                if !response.toolCalls.isEmpty {
                    appendAssistantResponse(response, to: initialRun.sessionID)
                    if !response.content.isEmpty {
                        guard await emit(
                            .transcript(
                                RunTranscriptPresentation.storedText(
                                    response.content,
                                    section: .reasoning
                                )
                            ),
                            runID: runID
                        ) else { throw CancellationError() }
                    }
                    for call in response.toolCalls {
                        guard await emit(
                            .transcript(
                                RunTranscriptPresentation.storedText(
                                    "Using \(call.name)…\n",
                                    section: .action
                                )
                            ),
                            runID: runID
                        ) else { throw CancellationError() }
                        let result = await executeTool(
                            name: call.name,
                            arguments: call.arguments,
                            run: run
                        )
                        appendToolResponse(
                            result,
                            call: call,
                            to: initialRun.sessionID
                        )
                        guard !loopDetector.record(
                            Self.toolActivityHash(call: call, result: result)
                        ) else {
                            throw AgentProviderError.resourceLimit(
                                "The \(configuration.displayName) model repeated the same tool command and output 16 times without new activity."
                            )
                        }
                    }
                    continue
                }

                appendAssistantResponse(response, to: initialRun.sessionID)
                if await applyPendingSteeringMessages(runID: runID) {
                    loopDetector.reset()
                    if !response.content.isEmpty {
                        guard await emit(
                            .transcript(
                                RunTranscriptPresentation.storedText(
                                    response.content,
                                    section: .reasoning
                                )
                            ),
                            runID: runID
                        ) else { throw CancellationError() }
                    }
                    continue
                }
                guard !response.content.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty else {
                    throw AgentProviderError.invalidResponse(
                        "the \(configuration.displayName) response ended without final answer text"
                    )
                }
                guard await emit(
                    .transcript(
                        RunTranscriptPresentation.storedText(
                            response.content,
                            section: .result
                        )
                    ),
                    runID: runID
                ) else { throw CancellationError() }
                let duration = Int64(max(0, Date().timeIntervalSince(initialRun.startedAt) * 1_000))
                await finish(
                    runID: runID,
                    terminalEvent: .completed(
                        output: response.content,
                        durationMilliseconds: duration,
                        tokenUsage: accumulatedUsage
                    )
                )
                return
            }
        } catch is CancellationError {
            let detail = activeRuns[runID]?.interruptRequested == true
                ? "The \(configuration.displayName) run was interrupted."
                : "The \(configuration.displayName) run was cancelled."
            await finish(runID: runID, terminalEvent: .interrupted(detail))
        } catch {
            await finish(runID: runID, terminalEvent: .failed(error.localizedDescription))
        }
    }

    private func complete(
        messages: [JSONValue],
        target: AgentTarget,
        mode: AgentMode,
        outputSchema: JSONValue?,
        companyToolPolicy: CompanyToolPolicy?
    ) async throws -> CompletionResponse {
        let key = try await loadAPIKey()
        guard let endpoint = configuration.endpointURL else {
            throw AgentProviderError.namedUnavailable(
                displayName: configuration.displayName,
                detail: "The endpoint is invalid."
            )
        }
        let tools = Self.tools(for: mode, companyToolPolicy: companyToolPolicy)
        var body: [String: JSONValue] = [
            "model": .string(target.model),
            "messages": .array(messages),
            "stream": .bool(false)
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            body["tool_choice"] = .string("auto")
        }
        if let effort = target.options.effort?.trimmingCharacters(in: .whitespacesAndNewlines),
           !effort.isEmpty {
            body["reasoning_effort"] = .string(effort)
        }
        if let outputSchema {
            body["messages"] = .array(
                Self.messagesWithOutputInstructions(
                    messages,
                    schema: outputSchema
                )
            )
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Codeness", forHTTPHeaderField: "User-Agent")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let requestBody = try JSONValue.object(body).encodedData()
        guard requestBody.count <= maximumRequestByteCount else {
            throw AgentProviderError.resourceLimit(
                "The \(configuration.displayName) conversation exceeded Codeness's \(maximumRequestByteCount / 1_024 / 1_024) MB request-memory limit. Start a fresh provider session to continue safely."
            )
        }
        request.httpBody = requestBody
        request.timeoutInterval = 180
        let result = try await transport.send(request)
        try Task.checkCancellation()
        guard result.data.count <= maximumResponseByteCount else {
            throw AgentProviderError.resourceLimit(
                "The \(configuration.displayName) endpoint response exceeded Codeness's \(maximumResponseByteCount / 1_024) KB response-memory limit."
            )
        }
        guard (200..<300).contains(result.statusCode) else {
            let response = try? JSONDecoder().decode(JSONValue.self, from: result.data)
            let preview = result.data.prefix(64 * 1_024)
            let rawDetail = String(decoding: preview, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = Self.truncatedUTF8(
                response?["error"]?["message"]?.stringValue
                    ?? (rawDetail.isEmpty ? "No response body" : rawDetail),
                maximumByteCount: 64 * 1_024
            )
            let suffix = result.data.count > preview.count ? " [response truncated]" : ""
            throw AgentProviderError.invalidResponse(
                "\(configuration.displayName) endpoint returned HTTP \(result.statusCode): \(detail)\(suffix)"
            )
        }
        guard let payload = try? JSONDecoder().decode(JSONValue.self, from: result.data),
              let choice = payload["choices"]?.arrayValue?.first,
              let message = choice["message"] else {
            throw AgentProviderError.invalidResponse(
                "the \(configuration.displayName) response did not contain a chat choice"
            )
        }
        let content = Self.textContent(message["content"])
        let reasoning = Self.reasoningContent(from: message)
        let calls = try Self.toolCalls(from: message["tool_calls"])
        guard !content.isEmpty || !reasoning.text.isEmpty || !calls.isEmpty else {
            throw AgentProviderError.invalidResponse(
                "the \(configuration.displayName) response contained no text or tool call"
            )
        }
        return CompletionResponse(
            content: content,
            reasoning: reasoning.text,
            reasoningPayload: reasoning.payload,
            toolCalls: calls,
            usage: Self.tokenUsage(from: payload["usage"]),
            finishReason: choice["finish_reason"]?.stringValue
        )
    }

    private func loadAPIKey() async throws -> String {
        let file = configuration.apiKeyFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = configuration.apiKeyName.trimmingCharacters(in: .whitespacesAndNewlines)
        if file.isEmpty && name.isEmpty { return "" }
        guard !file.isEmpty else {
            throw AgentProviderError.namedUnavailable(
                displayName: configuration.displayName,
                detail: "The API-key file is empty."
            )
        }
        guard !name.isEmpty else {
            throw AgentProviderError.namedUnavailable(
                displayName: configuration.displayName,
                detail: "The API-key name is empty."
            )
        }
        return try await keyLoader.apiKey(file: file, name: name)
    }

    private func executeTool(
        name: String,
        arguments: JSONValue,
        run: ActiveRun
    ) async -> String {
        do {
            switch name {
            case "glob":
                return try globFiles(arguments: arguments, cwd: run.cwd)
            case "list_files":
                return try listFiles(arguments: arguments, cwd: run.cwd)
            case "read", "read_file":
                return try readFile(arguments: arguments, cwd: run.cwd)
            case "grep", "search_files":
                return try searchFiles(arguments: arguments, cwd: run.cwd)
            case "edit":
                guard run.target.options.mode == .standard else {
                    throw ToolError.denied("edit is unavailable in Plan mode")
                }
                return try editFile(arguments: arguments, cwd: run.cwd)
            case "write", "write_file":
                guard run.target.options.mode == .standard else {
                    throw ToolError.denied("write is unavailable in Plan mode")
                }
                return try writeFile(arguments: arguments, cwd: run.cwd)
            case "bash", "run_shell":
                guard run.target.options.mode == .standard else {
                    throw ToolError.denied("bash is unavailable in Plan mode")
                }
                return try await runShell(arguments: arguments, cwd: run.cwd)
            default:
                throw ToolError.invalid("Unknown tool \(name)")
            }
        } catch {
            return "Tool error: \(error.localizedDescription)"
        }
    }

    private enum ToolError: LocalizedError {
        case invalid(String)
        case denied(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let detail), .denied(let detail): detail
            }
        }
    }

    private func toolURL(_ path: String?, cwd: String) -> URL {
        let root = URL(fileURLWithPath: cwd, isDirectory: true)
            .standardizedFileURL
        let rawPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        return expandedPath.isEmpty
            ? root
            : (expandedPath.hasPrefix("/")
                ? URL(fileURLWithPath: expandedPath)
                : root.appendingPathComponent(expandedPath))
            .standardizedFileURL
    }

    private func globFiles(arguments: JSONValue, cwd: String) throws -> String {
        let pattern = arguments["pattern"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pattern.isEmpty else { throw ToolError.invalid("glob requires a pattern") }
        let root = toolURL(arguments["path"]?.stringValue, cwd: cwd)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        var matches: [(url: URL, modifiedAt: Date)] = []
        var matchCount = 0

        func consider(_ url: URL, relativePath: String) {
            guard Self.matchesGlob(relativePath, pattern: pattern),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return }
            matchCount += 1
            matches.append((url, values.contentModificationDate ?? .distantPast))
            matches.sort { $0.modifiedAt > $1.modifiedAt }
            if matches.count > 100 {
                matches.removeLast()
            }
        }

        guard let rootValues = try? root.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey]
        ), rootValues.isDirectory == true || rootValues.isRegularFile == true else {
            throw ToolError.invalid("Path \(root.path) does not exist.")
        }
        if rootValues.isDirectory == true {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { return "No files found" }
            for case let url as URL in enumerator {
                consider(url, relativePath: Self.relativePath(url, from: root.path))
            }
        } else {
            consider(root, relativePath: root.lastPathComponent)
        }

        guard !matches.isEmpty else { return "No files found" }
        var output = matches.map { $0.url.path }
        if matchCount > matches.count {
            output += [
                "",
                "(Results are truncated: showing 100 of \(matchCount) matches. Use a more specific path or pattern.)"
            ]
        }
        return output.joined(separator: "\n")
    }

    private func listFiles(arguments: JSONValue, cwd: String) throws -> String {
        let root = toolURL(arguments["path"]?.stringValue, cwd: cwd)
        let limit = max(1, min(500, Int(arguments["max_entries"]?.integerValue ?? 200)))
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return "No files found." }
        var paths: [String] = []
        for case let url as URL in enumerator {
            paths.append(Self.relativePath(url, from: cwd))
            if paths.count >= limit { break }
        }
        return paths.isEmpty ? "No files found." : paths.joined(separator: "\n")
    }

    private func readFile(arguments: JSONValue, cwd: String) throws -> String {
        let path = arguments["filePath"]?.stringValue
            ?? arguments["path"]?.stringValue
        let url = toolURL(path, cwd: cwd)
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey]
        ), values.isDirectory == true || values.isRegularFile == true else {
            throw ToolError.invalid("File \(url.path) does not exist.")
        }
        let offset = max(1, Int(arguments["offset"]?.integerValue ?? 1))
        let lineLimit = max(1, min(2_000, Int(arguments["limit"]?.integerValue ?? 2_000)))
        if values.isDirectory == true {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { throw ToolError.invalid("Could not read directory: \(url.path)") }
            var encounteredCount = 0
            var shown: [String] = []
            var retainedByteCount = 0
            var hasMore = false
            let maximumOutputByteCount = 50 * 1_024
            for case let entryURL as URL in enumerator {
                encounteredCount += 1
                guard encounteredCount >= offset else { continue }
                let entry = entryURL.lastPathComponent
                let entryByteCount = entry.utf8.count + (shown.isEmpty ? 0 : 1)
                guard shown.count < lineLimit,
                      retainedByteCount + entryByteCount <= maximumOutputByteCount else {
                    hasMore = true
                    break
                }
                shown.append(entry)
                retainedByteCount += entryByteCount
            }
            guard !shown.isEmpty || offset == 1 else {
                throw ToolError.invalid("Offset \(offset) is out of range for \(url.path).")
            }
            let nextOffsetResult = offset.addingReportingOverflow(shown.count)
            let nextOffset = nextOffsetResult.overflow
                ? Int.max
                : nextOffsetResult.partialValue
            let suffix = hasMore
                ? "\n(Output truncated. Use offset=\(nextOffset) to continue.)"
                : "\n(End of directory)"
            return "<path>\(url.path)</path>\n<type>directory</type>\n<entries>\n\(shown.joined(separator: "\n"))\(suffix)\n</entries>"
        }
        let maximumBytes = max(
            1,
            min(
                8 * 1_024 * 1_024,
                Int(arguments["max_bytes"]?.integerValue ?? 8 * 1_024 * 1_024)
            )
        )
        let (data, truncated) = try Self.readPrefix(
            at: url,
            maximumByteCount: maximumBytes
        )
        guard !data.prefix(4_096).contains(0) else {
            throw ToolError.invalid("Cannot read binary file: \(url.path)")
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = min(lines.count, offset - 1)
        var outputLines: [String] = []
        var outputByteCount = 0
        let maximumOutputByteCount = 50 * 1_024
        var reachedOutputLimit = false
        for index in start..<min(lines.count, start + lineLimit) {
            let rawLine = String(lines[index])
            let line = rawLine.count > 2_000
                ? String(rawLine.prefix(2_000)) + "... (line truncated)"
                : rawLine
            let rendered = "\(index + 1): \(line)"
            let byteCount = rendered.utf8.count + (outputLines.isEmpty ? 0 : 1)
            if outputByteCount + byteCount > maximumOutputByteCount {
                reachedOutputLimit = true
                break
            }
            outputLines.append(rendered)
            outputByteCount += byteCount
        }
        guard !outputLines.isEmpty || (lines.isEmpty && offset == 1) else {
            throw ToolError.invalid(
                "Offset \(offset) is out of range for the portion of \(url.path) Codeness could read."
            )
        }
        let nextOffset = start + outputLines.count + 1
        let hasMoreInReadWindow = reachedOutputLimit
            || start + outputLines.count < lines.count
        let status: String
        if hasMoreInReadWindow {
            status = "(Output truncated. Use offset=\(nextOffset) to continue.)"
        } else if truncated {
            status = "(File exceeds the bounded read window. Use bash to inspect content beyond this point.)"
        } else {
            status = "(End of file - total \(lines.count) lines)"
        }
        return "<path>\(url.path)</path>\n<type>file</type>\n<content>\n\(outputLines.joined(separator: "\n"))\n\n\(status)\n</content>"
    }

    private func searchFiles(arguments: JSONValue, cwd: String) throws -> String {
        let requestedPattern = arguments["pattern"]?.stringValue
        let legacyQuery = arguments["query"]?.stringValue
        let pattern = (requestedPattern ?? legacyQuery)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pattern.isEmpty else { throw ToolError.invalid("grep requires a pattern") }
        let regularExpression: NSRegularExpression
        do {
            regularExpression = try NSRegularExpression(
                pattern: requestedPattern == nil
                    ? NSRegularExpression.escapedPattern(for: pattern)
                    : pattern,
                options: requestedPattern == nil ? [.caseInsensitive] : []
            )
        } catch {
            throw ToolError.invalid("Invalid grep regular expression: \(error.localizedDescription)")
        }
        let root = toolURL(arguments["path"]?.stringValue, cwd: cwd)
        let include = arguments["include"]?.stringValue
        guard let rootValues = try? root.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey]
        ), rootValues.isDirectory == true || rootValues.isRegularFile == true else {
            throw ToolError.invalid("Path \(root.path) does not exist.")
        }
        var matches: [String] = []
        var retainedByteCount = 0
        let maximumResultByteCount = 512 * 1_024

        func inspect(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ),
                  values.isRegularFile == true,
                  include.map({ pattern in
                      Self.matchesGlob(
                          Self.relativePath(url, from: root.path),
                          pattern: pattern
                      ) || Self.matchesGlob(url.lastPathComponent, pattern: pattern)
                  }) ?? true,
                  (values.fileSize ?? .max) <= 1 * 1_024 * 1_024,
                  let (data, _) = try? Self.readPrefix(
                    at: url,
                    maximumByteCount: 1 * 1_024 * 1_024
                  ),
                  let text = String(data: data, encoding: .utf8) else { return false }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineText = String(line)
                let range = NSRange(lineText.startIndex..<lineText.endIndex, in: lineText)
                guard regularExpression.firstMatch(
                    in: lineText,
                    options: [],
                    range: range
                ) != nil else { continue }
                let renderedLine = lineText.count > 2_000
                    ? String(lineText.prefix(2_000)) + "..."
                    : lineText
                let match = "\(url.path):\(index + 1): \(renderedLine)"
                let matchByteCount = match.utf8.count + (matches.isEmpty ? 0 : 1)
                if retainedByteCount + matchByteCount > maximumResultByteCount {
                    matches.append("[results truncated]")
                    return true
                }
                matches.append(match)
                retainedByteCount += matchByteCount
                if matches.count >= 100 { return true }
            }
            return false
        }

        if rootValues.isDirectory == true {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return "No files found" }
            for case let url as URL in enumerator where inspect(url) {
                break
            }
        } else {
            _ = inspect(root)
        }
        return matches.isEmpty ? "No files found" : matches.joined(separator: "\n")
    }

    private func editFile(arguments: JSONValue, cwd: String) throws -> String {
        let path = arguments["filePath"]?.stringValue
            ?? arguments["path"]?.stringValue
            ?? ""
        let oldString = arguments["oldString"]?.stringValue ?? ""
        let newString = arguments["newString"]?.stringValue ?? ""
        let replaceAll = arguments["replaceAll"]?.boolValue ?? false
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalid("edit requires filePath")
        }
        guard oldString != newString else {
            throw ToolError.invalid("No changes to apply: oldString and newString are identical.")
        }
        let url = toolURL(path, cwd: cwd)
        if oldString.isEmpty {
            return try writeText(newString, to: url, cwd: cwd)
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ToolError.invalid("File \(url.path) does not exist or is not a regular file.")
        }
        guard (values.fileSize ?? .max) <= 16 * 1_024 * 1_024 else {
            throw ToolError.invalid(
                "File \(url.path) is too large for exact-string edit; use bash for this operation."
            )
        }
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ToolError.invalid("Cannot edit non-UTF-8 file: \(url.path)")
        }
        let matchCount = content.components(separatedBy: oldString).count - 1
        guard matchCount > 0 else {
            throw ToolError.invalid(
                "Could not find oldString in the file. It must match exactly, including whitespace and line endings."
            )
        }
        guard replaceAll || matchCount == 1 else {
            throw ToolError.invalid(
                "Found multiple matches for oldString. Provide more context or set replaceAll."
            )
        }
        let updated: String
        if replaceAll {
            updated = content.replacingOccurrences(of: oldString, with: newString)
        } else if let range = content.range(of: oldString) {
            updated = content.replacingCharacters(in: range, with: newString)
        } else {
            throw ToolError.invalid("Could not find oldString in the file.")
        }
        _ = try writeText(updated, to: url, cwd: cwd)
        return "Edit applied successfully."
    }

    private func writeFile(arguments: JSONValue, cwd: String) throws -> String {
        let path = arguments["filePath"]?.stringValue
            ?? arguments["path"]?.stringValue
            ?? ""
        let content = arguments["content"]?.stringValue ?? ""
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalid("write requires filePath")
        }
        let url = toolURL(path, cwd: cwd)
        return try writeText(content, to: url, cwd: cwd)
    }

    private func writeText(_ content: String, to url: URL, cwd: String) throws -> String {
        guard content.utf8.count <= 16 * 1_024 * 1_024 else {
            throw ToolError.invalid(
                "Write content exceeds the 16 MB in-memory limit; use bash for this operation."
            )
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url, options: .atomic)
        return "Wrote file successfully: \(url.path)"
    }

    private func runShell(arguments: JSONValue, cwd: String) async throws -> String {
        let command = arguments["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else { throw ToolError.invalid("bash requires a command") }
        let legacyTimeoutMilliseconds = arguments["timeout_seconds"]?.integerValue.map {
            max(1, min(3_600, $0)) * 1_000
        }
        let requestedTimeoutMilliseconds = arguments["timeout"]?.integerValue
            ?? legacyTimeoutMilliseconds
            ?? 600_000
        let timeoutMilliseconds = max(1_000, min(3_600_000, requestedTimeoutMilliseconds))
        let result = try await BoundedOwnedProcessRunner.run(
            configuration: SupervisedProcessLaunchConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", command],
                environment: CodexExecutableLocator.processEnvironment(),
                currentDirectoryURL: URL(fileURLWithPath: cwd, isDirectory: true)
            ),
            timeout: .milliseconds(timeoutMilliseconds),
            maximumStandardOutputByteCount: 512 * 1_024,
            maximumStandardErrorByteCount: 512 * 1_024
        )
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        let error = String(decoding: result.standardError, as: UTF8.self)
        let combined = [output, error].filter { !$0.isEmpty }.joined(separator: "\n")
        return "exit \(result.termination.status)\n\(combined)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendAssistantResponse(_ response: CompletionResponse, to sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        var message: [String: JSONValue] = [
            "role": .string("assistant"),
            "content": response.content.isEmpty ? .null : .string(response.content)
        ]
        if !response.toolCalls.isEmpty {
            message["tool_calls"] = .array(response.toolCalls.map { call in
                .object([
                    "id": .string(call.id),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(call.name),
                        "arguments": .string(call.arguments.encodedString())
                    ])
                ])
            })
        }
        if let reasoningPayload = response.reasoningPayload {
            // Some compatible servers require their exact reasoning payload,
            // including signatures, on the assistant message preceding tools.
            message[reasoningPayload.field] = reasoningPayload.value
        }
        session.messages.append(.object(message))
        sessions[sessionID] = session
    }

    private func appendToolResponse(_ result: String, call: ToolCall, to sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        session.messages.append(.object([
            "role": .string("tool"),
            "tool_call_id": .string(call.id),
            "name": .string(call.name),
            "content": .string(result)
        ]))
        sessions[sessionID] = session
    }

    private func appendUserMessage(_ message: String, to sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        session.messages.append(.object([
            "role": .string("user"),
            "content": .string(message)
        ]))
        sessions[sessionID] = session
    }

    private func consumeSteeringMessages(runID: UUID) -> [String] {
        guard var run = activeRuns[runID], !run.steeringMessages.isEmpty else { return [] }
        let messages = run.steeringMessages
        run.steeringMessages.removeAll(keepingCapacity: true)
        activeRuns[runID] = run
        return messages
    }

    private func applyPendingSteeringMessages(runID: UUID) async -> Bool {
        let messages = consumeSteeringMessages(runID: runID)
        guard !messages.isEmpty,
              let sessionID = activeRuns[runID]?.sessionID else { return false }
        for message in messages {
            appendUserMessage(message, to: sessionID)
        }
        let description = messages.count == 1
            ? "Continuing with the steering message."
            : "Continuing with \(messages.count) steering messages."
        _ = await emit(
            .diagnostic(
                RunTranscriptPresentation.storedText(
                    "\n\(description)\n",
                    section: .diagnostic
                )
            ),
            runID: runID
        )
        return true
    }

    private func emit(_ event: AgentEvent, runID: UUID) async -> Bool {
        guard let events = activeRuns[runID]?.events else { return false }
        return await events.send(event)
    }

    private func finish(runID: UUID, terminalEvent: AgentEvent) async {
        guard let run = activeRuns.removeValue(forKey: runID) else { return }
        runTasks.removeValue(forKey: runID)
        guard await run.events.finish(with: terminalEvent) else {
            _ = await run.events.finish(
                with: .failed("The provider result exceeded the bounded event-delivery limit.")
            )
            return
        }
    }

    private func cancelRunAfterConsumerTermination(runID: UUID) {
        guard var run = activeRuns[runID] else { return }
        run.interruptRequested = true
        activeRuns[runID] = run
        runTasks[runID]?.cancel()
    }

    private static func systemMessage(
        instructions: String,
        outputSchema: JSONValue?,
        mode: AgentMode,
        companyToolPolicy: CompanyToolPolicy? = nil
    ) -> JSONValue {
        var content = instructions
        content += "\n\nYou are working in the selected Codeness workspace."
        if let companyToolPolicy {
            let tools = tools(for: mode, companyToolPolicy: companyToolPolicy)
                .compactMap { $0["function"]?["name"]?.stringValue }
                .sorted()
                .joined(separator: ", ")
            content += " The profession tool boundary is enforced. Available tools: \(tools.isEmpty ? "none" : tools). Do not claim or attempt unavailable effects. Report a capability block when the assignment needs one."
            if mode == .plan {
                content += " Plan mode is read-only: inspect and explain; do not change files or run mutating commands."
            }
        } else if mode == .plan {
            content += " Plan mode is read-only: inspect and explain; do not change files or run mutating commands."
        } else {
            content += " Use the provided OpenCode-style tools to inspect, edit, build, and test as needed. Tool paths and shell commands are not sandboxed; the selected workspace is only the initial working directory."
        }
        if let outputSchema {
            content += "\n\nReturn only JSON matching this schema:\n\(outputSchema.encodedString(prettyPrinted: true))"
        }
        return .object([
            "role": .string("system"),
            "content": .string(content)
        ])
    }

    private static func messagesWithOutputInstructions(
        _ messages: [JSONValue],
        schema: JSONValue
    ) -> [JSONValue] {
        guard !messages.isEmpty else { return messages }
        var result = messages
        guard let first = result[0].objectValue,
              let content = first["content"]?.stringValue else { return result }
        var updated = first
        updated["content"] = .string(
            content + "\n\nReturn only JSON matching this schema:\n" + schema.encodedString(prettyPrinted: true)
        )
        result[0] = .object(updated)
        return result
    }

    private static func tools(
        for mode: AgentMode,
        companyToolPolicy: CompanyToolPolicy? = nil
    ) -> [JSONValue] {
        let readOnlyTools = [
            tool(
                name: "read",
                description: "Read a file or list a directory. Paths may be absolute or relative to the current working directory.",
                parameters: .object([
                    "type": .string("object"),
                    "required": .array([.string("filePath")]),
                    "properties": .object([
                        "filePath": .object([
                            "type": .string("string"),
                            "description": .string("The path to the file or directory to read")
                        ]),
                        "offset": .object([
                            "type": .string("integer"),
                            "description": .string("The 1-indexed line or entry at which to start")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of lines or entries to return")
                        ])
                    ])
                ])
            ),
            tool(
                name: "glob",
                description: "Find files whose paths match a glob pattern, sorted by modification time.",
                parameters: .object([
                    "type": .string("object"),
                    "required": .array([.string("pattern")]),
                    "properties": .object([
                        "pattern": .object([
                            "type": .string("string"),
                            "description": .string("The glob pattern to match files against")
                        ]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Directory to search; defaults to the current working directory")
                        ])
                    ])
                ])
            ),
            tool(
                name: "grep",
                description: "Search file contents using a regular expression.",
                parameters: .object([
                    "type": .string("object"),
                    "required": .array([.string("pattern")]),
                    "properties": .object([
                        "pattern": .object([
                            "type": .string("string"),
                            "description": .string("The regular expression to search for")
                        ]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("File or directory to search; defaults to the current working directory")
                        ]),
                        "include": .object([
                            "type": .string("string"),
                            "description": .string("Optional glob pattern for files to include")
                        ])
                    ])
                ])
            )
        ]
        let standardTools = [
            tool(
                name: "bash",
                description: "Execute a non-interactive shell command. Use this for builds, tests, Git, linters, package managers, and project scripts. The current working directory starts at the selected workspace and is not sandboxed.",
                parameters: .object([
                    "type": .string("object"),
                    "required": .array([.string("command")]),
                    "properties": .object([
                        "command": .object([
                            "type": .string("string"),
                            "description": .string("The shell command to execute")
                        ]),
                        "timeout": .object([
                            "type": .string("integer"),
                            "description": .string("Optional timeout in milliseconds; defaults to 600000")
                        ]),
                        "description": .object([
                            "type": .string("string"),
                            "description": .string("A short description of what the command does")
                        ])
                    ])
                ])
            )
        ] + readOnlyTools + [
            tool(
                name: "edit",
                description: "Modify an existing UTF-8 file by replacing an exact string.",
                parameters: .object([
                    "type": .string("object"),
                    "required": .array([
                        .string("filePath"),
                        .string("oldString"),
                        .string("newString")
                    ]),
                    "properties": .object([
                        "filePath": .object(["type": .string("string")]),
                        "oldString": .object(["type": .string("string")]),
                        "newString": .object(["type": .string("string")]),
                        "replaceAll": .object([
                            "type": .string("boolean"),
                            "description": .string("Replace every occurrence; defaults to false")
                        ])
                    ])
                ])
            ),
            tool(
                name: "write",
                description: "Create a new UTF-8 file or overwrite an existing one.",
                parameters: .object([
                    "type": .string("object"),
                    "required": .array([.string("filePath"), .string("content")]),
                    "properties": .object([
                        "filePath": .object(["type": .string("string")]),
                        "content": .object(["type": .string("string")])
                    ])
                ])
            )
        ]
        let available = mode == .standard ? standardTools : readOnlyTools
        guard let companyToolPolicy else { return available }
        let allowed = companyToolPolicy.openAICompatibleToolNames
        return available.filter {
            guard let name = $0["function"]?["name"]?.stringValue else { return false }
            return allowed.contains(name)
        }
    }

    private static func tool(
        name: String,
        description: String,
        parameters: JSONValue
    ) -> JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(name),
                "description": .string(description),
                "parameters": parameters
            ])
        ])
    }

    private static func textContent(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let text = value.stringValue { return text }
        if let values = value.arrayValue {
            return values.map(textContent).joined()
        }
        for key in ["text", "content", "reasoning", "thinking", "analysis", "summary"] {
            let text = textContent(value[key])
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return ""
    }

    private static func reasoningContent(
        from message: JSONValue
    ) -> (text: String, payload: ReasoningPayload?) {
        for field in [
            "reasoning_content",
            "reasoning",
            "thinking",
            "analysis",
            "reasoning_details"
        ] {
            guard let value = message[field] else { continue }
            let text = textContent(value)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            return (text, ReasoningPayload(field: field, value: value))
        }
        return ("", nil)
    }

    private static func toolActivityHash(call: ToolCall, result: String) -> Data {
        let activity = call.name + "\n" + call.arguments.encodedString() + "\n" + result
        return Data(SHA256.hash(data: Data(activity.utf8)))
    }

    private static func toolCalls(from value: JSONValue?) throws -> [ToolCall] {
        guard let value else { return [] }
        guard let entries = value.arrayValue else {
            throw AgentProviderError.invalidResponse("tool_calls was not an array")
        }
        return try entries.enumerated().map { index, entry in
            guard let function = entry["function"],
                  let name = function["name"]?.stringValue,
                  let rawArguments = function["arguments"] else {
                throw AgentProviderError.invalidResponse(
                    "tool call \(index + 1) did not contain valid function arguments"
                )
            }
            let arguments: JSONValue
            if let encodedArguments = rawArguments.stringValue,
               let data = encodedArguments.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
                arguments = decoded
            } else if rawArguments.objectValue != nil {
                arguments = rawArguments
            } else {
                throw AgentProviderError.invalidResponse(
                    "tool call \(index + 1) did not contain valid function arguments"
                )
            }
            return ToolCall(
                id: entry["id"]?.stringValue ?? "codeness-tool-\(index + 1)-\(UUID().uuidString)",
                name: name,
                arguments: arguments
            )
        }
    }

    private static func tokenUsage(from value: JSONValue?) -> RunTokenUsage? {
        guard let value else { return nil }
        let input = value["prompt_tokens"]?.integerValue
            ?? value["input_tokens"]?.integerValue
            ?? 0
        let output = value["completion_tokens"]?.integerValue
            ?? value["output_tokens"]?.integerValue
            ?? 0
        let reportedTotal = value["total_tokens"]?.integerValue ?? 0
        let total = reportedTotal > 0 ? reportedTotal : input + output
        guard input > 0 || output > 0 || total > 0 else { return nil }
        return RunTokenUsage(
            totalTokens: total,
            inputTokens: input,
            cachedInputTokens: value["prompt_tokens_details"]?["cached_tokens"]?.integerValue
                ?? value["input_tokens_details"]?["cached_tokens"]?.integerValue
                ?? 0,
            outputTokens: output,
            reasoningOutputTokens: value["completion_tokens_details"]?["reasoning_tokens"]?.integerValue ?? 0
        )
    }

    private static func readPrefix(
        at url: URL,
        maximumByteCount: Int
    ) throws -> (data: Data, truncated: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumByteCount + 1) ?? Data()
        return (
            Data(data.prefix(maximumByteCount)),
            data.count > maximumByteCount
        )
    }

    private nonisolated static func retainedCost(of event: AgentEvent) -> Int {
        let overhead = 64
        switch event {
        case .started(let executionID), .interactionResolved(let executionID):
            return overhead + executionID.utf8.count
        case .transcript(let text), .diagnostic(let text), .sessionUnavailable(let text),
             .failed(let text):
            return overhead + text.utf8.count
        case .interrupted(let detail):
            return overhead + (detail?.utf8.count ?? 0)
        case .completed(let output, _, _):
            return overhead + output.utf8.count
        case .interaction(let interaction):
            return overhead
                + interaction.title.utf8.count
                + interaction.detail.utf8.count
                + interaction.rawParameters.encodedString().utf8.count
        case .tokenUsage:
            return overhead
        }
    }

    private static func relativePath(_ url: URL, from cwd: String) -> String {
        let root = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return url.standardizedFileURL.path.hasPrefix(prefix)
            ? String(url.standardizedFileURL.path.dropFirst(prefix.count))
            : url.lastPathComponent
    }

    private static func matchesGlob(_ path: String, pattern: String) -> Bool {
        var patterns = expandedGlobPatterns(pattern)
        var index = 0
        while index < patterns.count {
            if let range = patterns[index].range(of: "**/") {
                patterns.append(patterns[index].replacingCharacters(in: range, with: ""))
            }
            index += 1
        }
        return patterns.contains { candidate in
            guard let expression = try? NSRegularExpression(
                pattern: globRegularExpression(candidate)
            ) else { return false }
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            return expression.firstMatch(in: path, options: [], range: range) != nil
        }
    }

    private static func globRegularExpression(_ pattern: String) -> String {
        var expression = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            switch character {
            case "*":
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    expression += ".*"
                    index = pattern.index(after: next)
                    continue
                }
                expression += "[^/]*"
            case "?": expression += "[^/]"
            default:
                expression += NSRegularExpression.escapedPattern(
                    for: String(character)
                )
            }
            index = pattern.index(after: index)
        }
        return expression + "$"
    }

    private static func truncatedUTF8(
        _ value: String,
        maximumByteCount: Int
    ) -> String {
        let data = Data(value.utf8)
        guard data.count > maximumByteCount else { return value }
        return String(decoding: data.prefix(maximumByteCount), as: UTF8.self)
            + " [truncated]"
    }

    private static func expandedGlobPatterns(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "{"),
              let close = pattern[open...].firstIndex(of: "}") else {
            return [pattern]
        }
        let prefix = String(pattern[..<open])
        let suffix = String(pattern[pattern.index(after: close)...])
        let choices = pattern[pattern.index(after: open)..<close].split(separator: ",")
        guard !choices.isEmpty else { return [pattern] }
        return choices.flatMap { choice in
            expandedGlobPatterns(prefix + String(choice) + suffix)
        }
    }
}
