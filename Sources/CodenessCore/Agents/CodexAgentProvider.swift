import Foundation

public actor CodexAgentProvider: AgentProviding {
    public nonisolated let id = AgentProviderID.codex

    private struct ActiveRun {
        let sessionID: String
        var executionID: String?
        let continuation: AsyncStream<AgentEvent>.Continuation
        var itemsWithDeltas: Set<String>
        var tokenUsageBaseline: RunTokenUsage?
        var latestUsage: RunTokenUsage?
        var finalOutput: String?
        var interactionRequestIDs: [String: JSONValue]
    }

    private let appServer: CodexAppServerClient
    private var models: [CodexModel]
    private var activeRuns: [UUID: ActiveRun] = [:]
    private var sessionRuns: [String: UUID] = [:]
    private var executionRuns: [String: UUID] = [:]
    private var requestRuns: [String: UUID] = [:]

    public init(appServer: CodexAppServerClient, models: [CodexModel] = []) {
        self.appServer = appServer
        self.models = models
    }

    public func updateModels(_ models: [CodexModel]) {
        self.models = models
    }

    public func prepareSession(_ request: AgentSessionRequest) async throws -> AgentSession {
        guard request.target.providerID == id else {
            throw AgentProviderError.unsupportedProvider(request.target.providerID)
        }
        if let existingSessionID = request.existingSessionID {
            do {
                try await appServer.resumeThread(
                    id: existingSessionID,
                    cwd: request.cwd,
                    model: request.target.model,
                    developerInstructions: request.developerInstructions,
                    approvalPolicy: "never"
                )
            } catch {
                if Self.confirmsMissingSession(error) {
                    throw AgentProviderError.sessionUnavailable(
                        provider: id,
                        sessionID: existingSessionID,
                        detail: error.localizedDescription
                    )
                }
                throw error
            }
            return AgentSession(providerID: id, id: existingSessionID, target: request.target)
        }

        let sessionID = try await appServer.startThread(
            cwd: request.cwd,
            model: request.target.model,
            developerInstructions: request.developerInstructions,
            readOnly: request.target.options.mode == .plan,
            approvalPolicy: "never"
        )
        try await appServer.setThreadName(id: sessionID, name: request.name)
        return AgentSession(providerID: id, id: sessionID, target: request.target)
    }

    public func startRun(_ request: AgentRunRequest) async throws -> AgentRunHandle {
        guard request.target.providerID == id, request.session.providerID == id else {
            throw AgentProviderError.unsupportedProvider(request.target.providerID)
        }
        guard activeRuns[request.runID] == nil else {
            throw AgentProviderError.invalidSession("run \(request.runID.uuidString) is already active")
        }

        let pair = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
        activeRuns[request.runID] = ActiveRun(
            sessionID: request.session.id,
            executionID: nil,
            continuation: pair.continuation,
            itemsWithDeltas: [],
            tokenUsageBaseline: nil,
            latestUsage: nil,
            finalOutput: nil,
            interactionRequestIDs: [:]
        )
        sessionRuns[request.session.id] = request.runID

        do {
            let effort = try reasoningEffort(for: request.target)
            let serviceTier = try serviceTier(for: request.target)
            let executionID = try await appServer.startTurn(
                threadID: request.session.id,
                prompt: request.prompt,
                cwd: request.cwd,
                model: request.target.model,
                effort: effort,
                mode: request.target.options.mode,
                serviceTier: serviceTier,
                outputSchema: request.outputSchema,
                approvalPolicy: "never"
            )
            if var activeRun = activeRuns[request.runID] {
                activeRun.executionID = activeRun.executionID ?? executionID
                activeRuns[request.runID] = activeRun
                executionRuns[executionID] = request.runID
            }
            return AgentRunHandle(
                runID: request.runID,
                providerID: id,
                sessionID: request.session.id,
                executionID: executionID,
                events: pair.stream
            )
        } catch {
            finish(runID: request.runID)
            if Self.confirmsMissingSession(error) {
                throw AgentProviderError.sessionUnavailable(
                    provider: id,
                    sessionID: request.session.id,
                    detail: error.localizedDescription
                )
            }
            throw error
        }
    }

    public func steer(runID: UUID, message: String) async throws {
        guard let run = activeRuns[runID], let executionID = run.executionID else {
            throw AgentProviderError.missingRun(runID)
        }
        try await appServer.steer(
            threadID: run.sessionID,
            turnID: executionID,
            message: message
        )
    }

    public func interrupt(runID: UUID) async throws {
        guard let run = activeRuns[runID], let executionID = run.executionID else {
            throw AgentProviderError.missingRun(runID)
        }
        try await appServer.interrupt(threadID: run.sessionID, turnID: executionID)
    }

    public func resolveInteraction(
        runID: UUID,
        interactionID: String,
        resolution: AgentInteractionResolution
    ) async throws {
        guard let run = activeRuns[runID],
              let requestID = run.interactionRequestIDs[interactionID] else {
            throw AgentProviderError.missingRun(runID)
        }
        let result: JSONValue
        switch resolution {
        case .decision(let value), .raw(let value):
            result = value
        case .answers(let answers):
            result = .object([
                "answers": .object(answers.mapValues { .array($0.map(JSONValue.string)) })
            ])
        case .cancel:
            try await appServer.respondWithError(
                to: requestID,
                message: "The user cancelled this request."
            )
            return
        }
        try await appServer.respond(to: requestID, result: result)
    }

    public func runUtility(_ request: AgentUtilityRequest) async throws -> AgentUtilityResult {
        guard request.target.providerID == id else {
            throw AgentProviderError.unsupportedProvider(request.target.providerID)
        }
        let sessionID = try await appServer.startThread(
            cwd: request.cwd,
            model: request.target.model,
            developerInstructions: request.developerInstructions,
            ephemeral: true,
            readOnly: true,
            approvalPolicy: "never"
        )
        let session = AgentSession(providerID: id, id: sessionID, target: request.target)
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
        for await event in handle.events {
            switch event {
            case .completed(let output, _, let usage):
                return AgentUtilityResult(output: output, tokenUsage: usage)
            case .failed(let detail):
                throw AgentProviderError.invalidResponse(detail)
            case .sessionUnavailable(let detail):
                throw AgentProviderError.invalidResponse(detail)
            case .interrupted(let detail):
                throw AgentProviderError.invalidResponse(detail ?? "The coordinator run was interrupted.")
            case .started, .transcript, .diagnostic, .tokenUsage, .interaction,
                 .interactionResolved:
                continue
            }
        }
        throw AgentProviderError.invalidResponse("the coordinator run ended without a result")
    }

    private static func confirmsMissingSession(_ error: any Error) -> Bool {
        guard let error = error as? AppServerClientError,
              case .requestFailed(let code, let message) = error,
              code == -32600 else {
            return false
        }
        return message.localizedCaseInsensitiveContains(
            "no rollout found for thread id"
        )
    }

    public func shutdown() {
        for runID in Array(activeRuns.keys) {
            activeRuns[runID]?.continuation.yield(.failed("Codex stopped."))
            finish(runID: runID)
        }
    }

    public func receive(_ event: AppServerEvent) async {
        switch event {
        case .standardError:
            return
        case .exited(let termination):
            let runIDs = Array(activeRuns.keys)
            for runID in runIDs {
                activeRuns[runID]?.continuation.yield(
                    .failed(
                        termination.userFacingDescription(
                            subject: "Codex App Server"
                        )
                    )
                )
                finish(runID: runID)
            }
        case .request(let requestID, let method, let params, _):
            guard let runID = runID(for: event), var run = activeRuns[runID] else { return }
            if let response = Self.automaticResponse(method: method, params: params) {
                do {
                    try await appServer.respond(to: requestID, result: response)
                } catch {
                    run.continuation.yield(
                        .failed("Could not automatically approve the Codex MCP tool call: \(error.localizedDescription)")
                    )
                    finish(runID: runID)
                }
                return
            }
            let interactionID = requestID.encodedString()
            run.interactionRequestIDs[interactionID] = requestID
            activeRuns[runID] = run
            requestRuns[interactionID] = runID
            run.continuation.yield(
                .interaction(Self.interaction(
                    id: interactionID,
                    method: method,
                    params: params
                ))
            )
        case .notification(let method, let params, _):
            if method == "serverRequest/resolved",
               let requestID = params["requestId"] {
                let interactionID = requestID.encodedString()
                if let runID = requestRuns.removeValue(forKey: interactionID),
                   var run = activeRuns[runID] {
                    run.interactionRequestIDs.removeValue(forKey: interactionID)
                    activeRuns[runID] = run
                    run.continuation.yield(.interactionResolved(interactionID))
                }
                return
            }
            guard let runID = runID(for: event), var run = activeRuns[runID] else { return }
            if method == "turn/started", let executionID = params["turn"]?["id"]?.stringValue {
                run.executionID = executionID
                executionRuns[executionID] = runID
                activeRuns[runID] = run
                run.continuation.yield(.started(executionID: executionID))
            }

            if method == "thread/tokenUsage/updated",
               let usage = params["tokenUsage"],
               let total = RunTokenUsage(appServerValue: usage["total"]),
               let last = RunTokenUsage(appServerValue: usage["last"]) {
                let baseline = run.tokenUsageBaseline ?? total.subtracting(last)
                let current = total.subtracting(baseline)
                run.tokenUsageBaseline = baseline
                run.latestUsage = current
                activeRuns[runID] = run
                run.continuation.yield(.tokenUsage(current))
            }

            let update = TranscriptFormatter.update(
                method: method,
                params: params,
                itemsWithDeltas: run.itemsWithDeltas
            )
            if let itemID = update.itemID,
               method.hasSuffix("/delta") || method.hasSuffix("Delta") {
                run.itemsWithDeltas.insert(itemID)
            }
            if !update.text.isEmpty {
                run.continuation.yield(.transcript(RunTranscriptPresentation.storedText(for: update)))
            }
            if let finalOutput = update.finalOutput, !finalOutput.isEmpty {
                run.finalOutput = finalOutput
            }
            activeRuns[runID] = run

            if method == "turn/completed" {
                let turn = params["turn"] ?? .null
                let output = TranscriptFormatter.finalOutput(from: turn) ?? run.finalOutput
                let status = turn["status"]?.stringValue ?? "failed"
                let duration = turn["durationMs"]?.integerValue
                if status == "completed", let output, !output.isEmpty {
                    run.continuation.yield(
                        .completed(
                            output: output,
                            durationMilliseconds: duration,
                            tokenUsage: run.latestUsage
                        )
                    )
                } else if status == "interrupted" {
                    run.continuation.yield(.interrupted(nil))
                } else {
                    run.continuation.yield(.failed("Codex turn ended with status \(status)."))
                }
                finish(runID: runID)
            }
        }
    }

    private func runID(for event: AppServerEvent) -> UUID? {
        if let executionID = event.turnID, let runID = executionRuns[executionID] {
            return runID
        }
        if let sessionID = event.threadID {
            return sessionRuns[sessionID]
        }
        return nil
    }

    private func reasoningEffort(for target: AgentTarget) throws -> String {
        if let effort = target.options.effort?.trimmingCharacters(in: .whitespacesAndNewlines),
           !effort.isEmpty {
            return effort
        }
        if let effort = models.first(where: { $0.model == target.model })?.defaultEffort {
            return effort
        }
        throw AgentProviderError.invalidResponse(
            "Codex model \(target.model) did not advertise a default reasoning effort"
        )
    }

    private func serviceTier(for target: AgentTarget) throws -> String? {
        guard target.options.speed == .fast else { return nil }
        guard let model = models.first(where: { $0.model == target.model }),
              let tier = model.serviceTiers.first(where: {
                  $0.name.localizedCaseInsensitiveCompare("Fast") == .orderedSame
              }) else {
            throw AgentProviderError.invalidResponse(
                "Codex model \(target.model) does not advertise Fast mode"
            )
        }
        return tier.id
    }

    private func finish(runID: UUID) {
        guard let run = activeRuns.removeValue(forKey: runID) else { return }
        run.continuation.finish()
        if sessionRuns[run.sessionID] == runID {
            sessionRuns.removeValue(forKey: run.sessionID)
        }
        if let executionID = run.executionID, executionRuns[executionID] == runID {
            executionRuns.removeValue(forKey: executionID)
        }
        for interactionID in run.interactionRequestIDs.keys {
            requestRuns.removeValue(forKey: interactionID)
        }
    }

    private nonisolated static func interaction(
        id: String,
        method: String,
        params: JSONValue
    ) -> AgentInteraction {
        switch method {
        case "item/commandExecution/requestApproval":
            let command = params["command"]?.stringValue ?? "Unknown command"
            let cwd = params["cwd"]?.stringValue ?? "Unknown working directory"
            let reason = params["reason"]?.stringValue ?? "Codex requested approval."
            return AgentInteraction(
                id: id,
                kind: .approval,
                title: "Approve Command",
                detail: "\(command)\n\nWorking directory: \(cwd)\n\n\(reason)",
                decisions: approvalDecisions(params["availableDecisions"]),
                rawParameters: params
            )
        case "item/fileChange/requestApproval":
            return AgentInteraction(
                id: id,
                kind: .approval,
                title: "Approve File Changes",
                detail: params["reason"]?.stringValue
                    ?? "Codex requested approval to change files.",
                decisions: approvalDecisions(params["availableDecisions"]),
                rawParameters: params
            )
        case "item/tool/requestUserInput":
            return AgentInteraction(
                id: id,
                kind: .questions,
                title: "Codex Needs Input",
                detail: "Answer the questions to continue the active turn.",
                questions: decodeQuestions(params["questions"]?.arrayValue ?? []),
                rawParameters: params
            )
        default:
            return AgentInteraction(
                id: id,
                kind: .dialog,
                title: "Codex Request",
                detail: "Supply the JSON result for \(method), or cancel the request.",
                rawParameters: params
            )
        }
    }

    private nonisolated static func automaticResponse(
        method: String,
        params: JSONValue
    ) -> JSONValue? {
        guard method == "mcpServer/elicitation/request",
              params["_meta"]?["codex_approval_kind"]?.stringValue == "mcp_tool_call" else {
            return nil
        }
        return .object([
            "action": .string("accept"),
            "content": .object([:])
        ])
    }

    private nonisolated static func approvalDecisions(
        _ offeredValue: JSONValue?
    ) -> [AgentInteractionDecision] {
        let values: [JSONValue]
        if let offeredValue {
            guard case .array(let offered) = offeredValue else { return [] }
            values = offered
        } else {
            values = ["accept", "acceptForSession", "decline", "cancel"].map(JSONValue.string)
        }
        return values.map { value in
            let legacy = ApprovalDecision(value: value)
            return AgentInteractionDecision(
                id: legacy.id,
                label: legacy.label,
                explanation: legacy.explanation,
                payload: value,
                isDestructive: legacy.isDestructive
            )
        }
    }

    private nonisolated static func decodeQuestions(_ values: [JSONValue]) -> [InputQuestion] {
        values.compactMap { value in
            guard let id = value["id"]?.stringValue,
                  let question = value["question"]?.stringValue else { return nil }
            let options = value["options"]?.arrayValue?.compactMap { option -> InputOption? in
                guard let label = option["label"]?.stringValue else { return nil }
                return InputOption(
                    label: label,
                    description: option["description"]?.stringValue ?? ""
                )
            } ?? []
            return InputQuestion(
                id: id,
                header: value["header"]?.stringValue ?? "Question",
                question: question,
                options: options,
                isSecret: value["isSecret"]?.boolValue ?? false
            )
        }
    }
}
