import Dispatch
import Foundation

public actor ClaudeAgentProvider: AgentProviding {
    public nonisolated let id = AgentProviderID.claude

    private struct SessionConfiguration {
        let name: String
        let cwd: String
        let developerInstructions: String
        var hasStarted: Bool
    }

    private struct ControlInteraction {
        let requestID: String
        let subtype: String
        let toolName: String?
        let toolUseID: String?
        let input: JSONValue
        let questions: [InputQuestion]
    }

    private struct ActiveRun {
        let sessionID: String
        let process: Process
        let input: Pipe
        let output: Pipe
        let error: Pipe
        let continuation: AsyncStream<AgentEvent>.Continuation
        let startedAt: ContinuousClock.Instant
        var outputReaderTask: Task<Void, Never>?
        var errorReaderTask: Task<Void, Never>?
        var outputBuffer: Data
        var stderrTail: String
        var interactions: [String: ControlInteraction]
        var latestUsage: RunTokenUsage?
        var latestAssistantText: String?
        var emittedTextHeading: Bool
        var emittedThinkingHeading: Bool
        var terminalDelivered: Bool
        var interruptRequested: Bool
        var terminationStatus: Int32?
        var outputReachedEOF: Bool
    }

    private let executableURL: URL
    private let environment: [String: String]
    private var sessions: [String: SessionConfiguration] = [:]
    private var activeRuns: [UUID: ActiveRun] = [:]

    public init(
        executableURL: URL,
        environment: [String: String] = CodexExecutableLocator.processEnvironment()
    ) {
        self.executableURL = executableURL
        var environment = environment
        // Claude disables Fast mode when CLAUDE_CODE_ENTRYPOINT identifies an
        // Agent SDK wrapper. Codeness launches the Claude CLI directly and uses
        // its supported streaming JSON flags, so preserve the CLI execution path.
        environment["CLAUDE_CODE_ENTRYPOINT"] = "cli"
        self.environment = environment
    }

    public func prepareSession(_ request: AgentSessionRequest) throws -> AgentSession {
        guard request.target.providerID == id else {
            throw AgentProviderError.unsupportedProvider(request.target.providerID)
        }
        let sessionID = request.existingSessionID ?? UUID().uuidString.lowercased()
        sessions[sessionID] = SessionConfiguration(
            name: request.name,
            cwd: request.cwd,
            developerInstructions: request.developerInstructions,
            hasStarted: request.existingSessionID != nil
        )
        return AgentSession(providerID: id, id: sessionID, target: request.target)
    }

    public func startRun(_ request: AgentRunRequest) throws -> AgentRunHandle {
        guard request.target.providerID == id, request.session.providerID == id else {
            throw AgentProviderError.unsupportedProvider(request.target.providerID)
        }
        guard var session = sessions[request.session.id] else {
            throw AgentProviderError.invalidSession(
                "Claude session \(request.session.id) was not prepared"
            )
        }
        let handle = try launch(
            runID: request.runID,
            sessionID: request.session.id,
            session: session,
            cwd: request.cwd,
            prompt: request.prompt,
            target: request.target,
            outputSchema: request.outputSchema,
            utility: false
        )
        session.hasStarted = true
        sessions[request.session.id] = session
        return handle
    }

    public func steer(runID: UUID, message: String) throws {
        guard let run = activeRuns[runID] else {
            throw AgentProviderError.missingRun(runID)
        }
        try write(
            .object([
                "type": .string("user"),
                "session_id": .string(run.sessionID),
                "message": .object([
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(message)])
                    ])
                ]),
                "parent_tool_use_id": .null
            ]),
            runID: runID
        )
    }

    public func interrupt(runID: UUID) throws {
        guard var run = activeRuns[runID] else {
            throw AgentProviderError.missingRun(runID)
        }
        run.interruptRequested = true
        activeRuns[runID] = run
        try write(
            .object([
                "type": .string("control_request"),
                "request_id": .string("codeness-interrupt-\(UUID().uuidString.lowercased())"),
                "request": .object([
                    "subtype": .string("interrupt"),
                    "cancel_queued": .bool(true)
                ])
            ]),
            runID: runID
        )
    }

    public func resolveInteraction(
        runID: UUID,
        interactionID: String,
        resolution: AgentInteractionResolution
    ) throws {
        guard let run = activeRuns[runID],
              let interaction = run.interactions[interactionID] else {
            throw AgentProviderError.missingRun(runID)
        }

        var response: JSONValue
        switch resolution {
        case .decision(let value), .raw(let value):
            response = value
        case .answers(let answers):
            response = questionResponse(interaction: interaction, answers: answers)
        case .cancel:
            if interaction.subtype == "request_user_dialog" {
                response = .object(["behavior": .string("cancelled")])
            } else {
                response = .object([
                    "behavior": .string("deny"),
                    "message": .string("The user cancelled this request."),
                    "interrupt": .bool(true)
                ])
            }
        }
        response = addingToolUseID(
            interaction.toolUseID,
            to: response,
            for: interaction.subtype
        )

        try write(
            .object([
                "type": .string("control_response"),
                "response": .object([
                    "subtype": .string("success"),
                    "request_id": .string(interaction.requestID),
                    "response": response
                ])
            ]),
            runID: runID
        )
        if var updatedRun = activeRuns[runID] {
            updatedRun.interactions.removeValue(forKey: interactionID)
            activeRuns[runID] = updatedRun
        }
    }

    public func runUtility(_ request: AgentUtilityRequest) async throws -> AgentUtilityResult {
        guard request.target.providerID == id else {
            throw AgentProviderError.unsupportedProvider(request.target.providerID)
        }
        let runID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let session = SessionConfiguration(
            name: "Codeness coordinator",
            cwd: request.cwd,
            developerInstructions: request.developerInstructions,
            hasStarted: false
        )
        let handle = try launch(
            runID: runID,
            sessionID: sessionID,
            session: session,
            cwd: request.cwd,
            prompt: request.prompt,
            target: request.target,
            outputSchema: request.outputSchema,
            utility: true
        )
        for await event in handle.events {
            switch event {
            case .completed(let output, _, let usage):
                return AgentUtilityResult(output: output, tokenUsage: usage)
            case .failed(let detail):
                throw AgentProviderError.invalidResponse(detail)
            case .interrupted(let detail):
                throw AgentProviderError.invalidResponse(
                    detail ?? "The Claude coordinator run was interrupted."
                )
            case .started, .transcript, .diagnostic, .tokenUsage, .interaction,
                 .interactionResolved:
                continue
            }
        }
        throw AgentProviderError.invalidResponse("the Claude coordinator run ended without a result")
    }

    public func shutdown() {
        for runID in Array(activeRuns.keys) {
            guard let run = activeRuns[runID] else { continue }
            if run.process.isRunning {
                run.process.terminate()
            }
            if !run.terminalDelivered {
                run.continuation.yield(.failed("Claude stopped."))
            }
            cleanup(runID: runID)
        }
    }

    private func launch(
        runID: UUID,
        sessionID: String,
        session: SessionConfiguration,
        cwd: String,
        prompt: String,
        target: AgentTarget,
        outputSchema: JSONValue?,
        utility: Bool
    ) throws -> AgentRunHandle {
        guard activeRuns[runID] == nil else {
            throw AgentProviderError.invalidSession("run \(runID.uuidString) is already active")
        }
        guard !target.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentProviderError.invalidResponse("the Claude model is empty")
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executableURL
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        process.arguments = arguments(
            sessionID: sessionID,
            session: session,
            target: target,
            outputSchema: outputSchema,
            utility: utility
        )

        let pair = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
        activeRuns[runID] = ActiveRun(
            sessionID: sessionID,
            process: process,
            input: input,
            output: output,
            error: error,
            continuation: pair.continuation,
            startedAt: ContinuousClock().now,
            outputReaderTask: nil,
            errorReaderTask: nil,
            outputBuffer: Data(),
            stderrTail: "",
            interactions: [:],
            latestUsage: nil,
            latestAssistantText: nil,
            emittedTextHeading: false,
            emittedThinkingHeading: false,
            terminalDelivered: false,
            interruptRequested: false,
            terminationStatus: nil,
            outputReachedEOF: false
        )
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { await self?.processTerminated(runID: runID, status: status) }
        }

        do {
            try process.run()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? error.fileHandleForWriting.close()

            let outputTask = Self.makeOutputReader(
                handle: output.fileHandleForReading,
                runID: runID,
                provider: self
            )
            let errorTask = Self.makeErrorReader(
                handle: error.fileHandleForReading,
                runID: runID,
                provider: self
            )
            if var run = activeRuns[runID] {
                run.outputReaderTask = outputTask
                run.errorReaderTask = errorTask
                activeRuns[runID] = run
            }

            try write(
                .object([
                    "type": .string("control_request"),
                    "request_id": .string("codeness-initialize-\(UUID().uuidString.lowercased())"),
                    "request": .object([
                        "subtype": .string("initialize"),
                        "supportedDialogKinds": .array([
                            .string("refusal_fallback_prompt")
                        ])
                    ])
                ]),
                runID: runID
            )
            try write(
                .object([
                    "type": .string("user"),
                    "session_id": .string(sessionID),
                    "message": .object([
                        "role": .string("user"),
                        "content": .array([
                            .object(["type": .string("text"), "text": .string(prompt)])
                        ])
                    ]),
                    "parent_tool_use_id": .null
                ]),
                runID: runID
            )
        } catch {
            if process.isRunning {
                process.terminate()
            }
            cleanup(runID: runID)
            throw error
        }

        return AgentRunHandle(
            runID: runID,
            providerID: id,
            sessionID: sessionID,
            executionID: nil,
            events: pair.stream
        )
    }

    private func arguments(
        sessionID: String,
        session: SessionConfiguration,
        target: AgentTarget,
        outputSchema: JSONValue?,
        utility: Bool
    ) -> [String] {
        let permissionMode: String
        if utility {
            permissionMode = "dontAsk"
        } else if target.options.mode == .plan {
            permissionMode = "plan"
        } else {
            permissionMode = "bypassPermissions"
        }
        var result = [
            "--print",
            "--output-format", "stream-json",
            "--verbose",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--replay-user-messages",
            "--model", target.model,
            "--permission-mode", permissionMode,
            "--settings", JSONValue.object([
                "fastMode": .bool(target.options.speed == .fast)
            ]).encodedString(),
            "--append-system-prompt", session.developerInstructions,
            "--name", session.name
        ]
        if let effort = target.options.effort?.trimmingCharacters(in: .whitespacesAndNewlines),
           !effort.isEmpty {
            result += ["--effort", effort]
        }
        if session.hasStarted {
            result.append("--resume=\(sessionID)")
        } else {
            result.append("--session-id=\(sessionID)")
        }
        if utility {
            result += ["--tools", "", "--no-session-persistence"]
        } else {
            // Keep Claude in Plan mode when requested while making bypass
            // available so no Codeness run pauses for tool approval.
            result.append("--allow-dangerously-skip-permissions")
            result += ["--permission-prompt-tool", "stdio"]
        }
        if let outputSchema {
            result += ["--json-schema", outputSchema.encodedString()]
        }
        return result
    }

    private func write(_ message: JSONValue, runID: UUID) throws {
        guard let run = activeRuns[runID], run.process.isRunning else {
            throw AgentProviderError.missingRun(runID)
        }
        var data = try message.encodedData()
        data.append(0x0A)
        try run.input.fileHandleForWriting.write(contentsOf: data)
    }

    private func consumeOutput(_ data: Data, runID: UUID) {
        guard var run = activeRuns[runID] else { return }
        run.outputBuffer.append(data)
        while let newline = run.outputBuffer.firstIndex(of: 0x0A) {
            let line = Data(run.outputBuffer[..<newline])
            run.outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            activeRuns[runID] = run
            handleLine(line, runID: runID)
            guard let updatedRun = activeRuns[runID] else { return }
            run = updatedRun
        }
        activeRuns[runID] = run
    }

    private func handleLine(_ data: Data, runID: UUID) {
        guard var run = activeRuns[runID] else { return }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            let line = String(decoding: data, as: UTF8.self)
            run.continuation.yield(.diagnostic("Invalid Claude JSON: \(line)"))
            return
        }

        switch message["type"]?.stringValue {
        case "system":
            if message["subtype"]?.stringValue == "init" {
                let executionID = message["session_id"]?.stringValue ?? run.sessionID
                run.continuation.yield(.started(executionID: executionID))
            } else if message["subtype"]?.stringValue == "status",
                      let status = message["status"]?.stringValue {
                run.continuation.yield(.diagnostic("Claude status: \(status)"))
            }
        case "stream_event":
            consumeStreamEvent(message["event"] ?? .null, run: &run)
        case "assistant":
            if let text = Self.assistantText(message["message"] ?? .null), !text.isEmpty {
                run.latestAssistantText = text
            }
            if let usage = Self.usage(message["message"]?["usage"]) {
                run.latestUsage = usage
                run.continuation.yield(.tokenUsage(usage))
            }
        case "control_request":
            if let interaction = Self.controlInteraction(message) {
                run.interactions[interaction.control.requestID] = interaction.control
                run.continuation.yield(.interaction(interaction.presentation))
            }
        case "control_cancel_request":
            if let requestID = message["request_id"]?.stringValue {
                run.interactions.removeValue(forKey: requestID)
                run.continuation.yield(.interactionResolved(requestID))
            }
        case "result":
            consumeResult(message, runID: runID, run: &run)
        case "user", "control_response", "keep_alive":
            break
        default:
            break
        }
        activeRuns[runID] = run
    }

    private func consumeStreamEvent(_ event: JSONValue, run: inout ActiveRun) {
        switch event["type"]?.stringValue {
        case "content_block_start":
            let block = event["content_block"] ?? .null
            if block["type"]?.stringValue == "tool_use" {
                let name = block["name"]?.stringValue ?? "tool"
                let text = RunTranscriptPresentation.storedText(
                    "\n› \(name)\n",
                    section: .action
                )
                run.continuation.yield(.transcript(text))
            }
        case "content_block_delta":
            let delta = event["delta"] ?? .null
            switch delta["type"]?.stringValue {
            case "text_delta":
                guard let text = delta["text"]?.stringValue, !text.isEmpty else { return }
                if !run.emittedTextHeading {
                    run.emittedTextHeading = true
                    run.continuation.yield(
                        .transcript(RunTranscriptPresentation.storedText(
                            "\n\nClaude\n",
                            section: .reasoning
                        ))
                    )
                }
                run.continuation.yield(.transcript(text))
            case "thinking_delta":
                guard let text = delta["thinking"]?.stringValue, !text.isEmpty else { return }
                if !run.emittedThinkingHeading {
                    run.emittedThinkingHeading = true
                    run.continuation.yield(
                        .transcript(RunTranscriptPresentation.storedText(
                            "\n\nReasoning\n",
                            section: .reasoning
                        ))
                    )
                }
                run.continuation.yield(.transcript(text))
            default:
                break
            }
        case "message_delta":
            if let usage = Self.usage(event["usage"]) {
                run.latestUsage = usage
                run.continuation.yield(.tokenUsage(usage))
            }
        default:
            break
        }
    }

    private func consumeResult(_ message: JSONValue, runID: UUID, run: inout ActiveRun) {
        guard !run.terminalDelivered else { return }
        run.terminalDelivered = true
        let usage = Self.usage(message["usage"]) ?? run.latestUsage
        let duration = message["duration_ms"]?.integerValue
        if message["is_error"]?.boolValue == true {
            let errors = message["errors"]?.arrayValue?.compactMap(\.stringValue)
                .joined(separator: "\n")
            let detail = errors?.isEmpty == false
                ? errors
                : message["result"]?.stringValue
            if run.interruptRequested {
                run.continuation.yield(.interrupted(detail))
            } else {
                run.continuation.yield(.failed(detail ?? "Claude returned an error result."))
            }
        } else {
            let output = message["result"]?.stringValue
                ?? message["structured_output"]?.encodedString(prettyPrinted: true)
                ?? run.latestAssistantText
                ?? ""
            if output.isEmpty {
                run.continuation.yield(.failed("Claude completed without a final result."))
            } else {
                run.continuation.yield(
                    .completed(
                        output: output,
                        durationMilliseconds: duration,
                        tokenUsage: usage
                    )
                )
            }
        }
        run.continuation.finish()
        try? run.input.fileHandleForWriting.close()
    }

    private func emitStandardError(_ text: String, runID: UUID) {
        guard var run = activeRuns[runID] else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        run.stderrTail = String((run.stderrTail + clean + "\n").suffix(4_000))
        run.continuation.yield(
            .diagnostic(RunTranscriptPresentation.storedText(
                "\n\(clean)\n",
                section: .diagnostic
            ))
        )
        activeRuns[runID] = run
    }

    private func outputEOF(runID: UUID) {
        guard var run = activeRuns[runID] else { return }
        if !run.outputBuffer.isEmpty {
            let finalLine = run.outputBuffer
            run.outputBuffer.removeAll(keepingCapacity: true)
            activeRuns[runID] = run
            handleLine(finalLine, runID: runID)
            guard let updated = activeRuns[runID] else { return }
            run = updated
        }
        run.outputReachedEOF = true
        activeRuns[runID] = run
        finishIfProcessDrained(runID: runID)
    }

    private func processTerminated(runID: UUID, status: Int32) {
        guard var run = activeRuns[runID] else { return }
        run.terminationStatus = status
        activeRuns[runID] = run
        finishIfProcessDrained(runID: runID)
    }

    private func finishIfProcessDrained(runID: UUID) {
        guard let run = activeRuns[runID],
              run.outputReachedEOF,
              let status = run.terminationStatus else { return }
        if !run.terminalDelivered {
            let detail = run.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            if run.interruptRequested {
                run.continuation.yield(.interrupted(detail.isEmpty ? nil : detail))
            } else {
                run.continuation.yield(
                    .failed(
                        AgentProviderError.processExited(
                            provider: id,
                            status: status,
                            detail: detail
                        ).localizedDescription
                    )
                )
            }
            run.continuation.finish()
        }
        cleanup(runID: runID)
    }

    private func cleanup(runID: UUID) {
        guard let run = activeRuns.removeValue(forKey: runID) else { return }
        run.outputReaderTask?.cancel()
        run.errorReaderTask?.cancel()
        try? run.input.fileHandleForWriting.close()
        try? run.output.fileHandleForReading.close()
        try? run.error.fileHandleForReading.close()
        run.continuation.finish()
    }

    private func questionResponse(
        interaction: ControlInteraction,
        answers: [String: [String]]
    ) -> JSONValue {
        guard interaction.subtype == "can_use_tool" else {
            return .object([
                "behavior": .string("completed"),
                "result": .object(
                    answers.mapValues { .array($0.map(JSONValue.string)) }
                )
            ])
        }
        var updatedInput = interaction.input.objectValue ?? [:]
        var answersByQuestion: [String: JSONValue] = [:]
        for question in interaction.questions {
            let values = answers[question.id] ?? []
            answersByQuestion[question.question] = .string(values.joined(separator: ", "))
        }
        updatedInput["answers"] = .object(answersByQuestion)
        return .object([
            "behavior": .string("allow"),
            "updatedInput": .object(updatedInput)
        ])
    }

    private func addingToolUseID(
        _ toolUseID: String?,
        to response: JSONValue,
        for subtype: String
    ) -> JSONValue {
        guard subtype == "can_use_tool",
              let toolUseID,
              var object = response.objectValue else {
            return response
        }
        object["toolUseID"] = .string(toolUseID)
        return .object(object)
    }

    private nonisolated static func usage(_ value: JSONValue?) -> RunTokenUsage? {
        guard let value else { return nil }
        let input = value["input_tokens"]?.integerValue ?? 0
        let cached = value["cache_read_input_tokens"]?.integerValue ?? 0
        let cacheWrite = value["cache_creation_input_tokens"]?.integerValue ?? 0
        let output = value["output_tokens"]?.integerValue ?? 0
        guard input > 0 || cached > 0 || cacheWrite > 0 || output > 0 else { return nil }
        return RunTokenUsage(
            totalTokens: input + cached + cacheWrite + output,
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteInputTokens: cacheWrite,
            outputTokens: output
        )
    }

    private nonisolated static func assistantText(_ message: JSONValue) -> String? {
        let text = message["content"]?.arrayValue?.compactMap { block -> String? in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }.joined(separator: "\n")
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func controlInteraction(
        _ message: JSONValue
    ) -> (control: ControlInteraction, presentation: AgentInteraction)? {
        guard let requestID = message["request_id"]?.stringValue,
              let request = message["request"],
              let subtype = request["subtype"]?.stringValue else { return nil }
        switch subtype {
        case "can_use_tool":
            let toolName = request["tool_name"]?.stringValue ?? "Tool"
            let toolUseID = request["tool_use_id"]?.stringValue
                ?? request["toolUseID"]?.stringValue
            let input = request["input"] ?? .object([:])
            let questions = toolName == "AskUserQuestion"
                ? decodeQuestions(input["questions"]?.arrayValue ?? [])
                : []
            let control = ControlInteraction(
                requestID: requestID,
                subtype: subtype,
                toolName: toolName,
                toolUseID: toolUseID,
                input: input,
                questions: questions
            )
            if !questions.isEmpty {
                return (
                    control,
                    AgentInteraction(
                        id: requestID,
                        kind: .questions,
                        title: "Claude Needs Input",
                        detail: "Answer the questions to continue the active turn.",
                        questions: questions,
                        rawParameters: request
                    )
                )
            }
            let detail = [
                request["title"]?.stringValue ?? "Claude wants to use \(toolName).",
                request["description"]?.stringValue,
                request["decision_reason"]?.stringValue,
                input.encodedString(prettyPrinted: true)
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
            let decisions = [
                AgentInteractionDecision(
                    id: "allow",
                    label: "Approve Once",
                    explanation: "Allow this tool call with its current input.",
                    payload: .object(["behavior": .string("allow")])
                ),
                AgentInteractionDecision(
                    id: "deny",
                    label: "Deny",
                    explanation: "Deny this tool call and let Claude continue.",
                    payload: .object([
                        "behavior": .string("deny"),
                        "message": .string("The user denied this request.")
                    ])
                ),
                AgentInteractionDecision(
                    id: "cancel",
                    label: "Cancel Turn",
                    explanation: "Deny this tool call and interrupt the turn.",
                    payload: .object([
                        "behavior": .string("deny"),
                        "message": .string("The user cancelled this turn."),
                        "interrupt": .bool(true)
                    ]),
                    isDestructive: true
                )
            ]
            return (
                control,
                AgentInteraction(
                    id: requestID,
                    kind: .approval,
                    title: "Approve \(toolName)",
                    detail: detail,
                    decisions: decisions,
                    rawParameters: request
                )
            )
        case "request_user_dialog":
            let control = ControlInteraction(
                requestID: requestID,
                subtype: subtype,
                toolName: nil,
                toolUseID: nil,
                input: request["payload"] ?? .object([:]),
                questions: []
            )
            return (
                control,
                AgentInteraction(
                    id: requestID,
                    kind: .dialog,
                    title: "Claude Needs Input",
                    detail: "Respond to Claude's \(request["dialog_kind"]?.stringValue ?? "dialog") request.",
                    rawParameters: request
                )
            )
        default:
            let control = ControlInteraction(
                requestID: requestID,
                subtype: subtype,
                toolName: nil,
                toolUseID: nil,
                input: request,
                questions: []
            )
            return (
                control,
                AgentInteraction(
                    id: requestID,
                    kind: .dialog,
                    title: "Claude Request",
                    detail: "Claude sent an unsupported \(subtype) control request. Supply its JSON response or cancel it.",
                    rawParameters: request
                )
            )
        }
    }

    private nonisolated static func decodeQuestions(_ values: [JSONValue]) -> [InputQuestion] {
        values.enumerated().compactMap { index, value in
            guard let question = value["question"]?.stringValue else { return nil }
            let options = value["options"]?.arrayValue?.compactMap { option -> InputOption? in
                guard let label = option["label"]?.stringValue else { return nil }
                return InputOption(
                    label: label,
                    description: option["description"]?.stringValue ?? ""
                )
            } ?? []
            return InputQuestion(
                id: "question-\(index + 1)",
                header: value["header"]?.stringValue ?? "Question",
                question: question,
                options: options,
                isSecret: false
            )
        }
    }

    private nonisolated static func makeOutputReader(
        handle: FileHandle,
        runID: UUID,
        provider: ClaudeAgentProvider
    ) -> Task<Void, Never> {
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        DispatchQueue(
            label: "ap.codeness.claude.stdout.\(runID.uuidString)",
            qos: .userInitiated
        ).async {
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                pair.continuation.yield(data)
            }
            pair.continuation.finish()
        }
        return Task { [weak provider] in
            for await data in pair.stream {
                guard !Task.isCancelled else { return }
                await provider?.consumeOutput(data, runID: runID)
            }
            guard !Task.isCancelled else { return }
            await provider?.outputEOF(runID: runID)
        }
    }

    private nonisolated static func makeErrorReader(
        handle: FileHandle,
        runID: UUID,
        provider: ClaudeAgentProvider
    ) -> Task<Void, Never> {
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        DispatchQueue(
            label: "ap.codeness.claude.stderr.\(runID.uuidString)",
            qos: .utility
        ).async {
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                pair.continuation.yield(data)
            }
            pair.continuation.finish()
        }
        return Task { [weak provider] in
            for await data in pair.stream {
                guard !Task.isCancelled else { return }
                await provider?.emitStandardError(
                    String(decoding: data, as: UTF8.self),
                    runID: runID
                )
            }
        }
    }
}
