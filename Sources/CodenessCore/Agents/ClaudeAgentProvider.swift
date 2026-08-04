import Darwin
import Dispatch
import Foundation
import OSLog

private struct ClaudeStdinWriteTimeoutError: LocalizedError {
    let timeout: Duration

    var errorDescription: String? {
        "Claude did not drain its stdin within \(timeout); Codeness stopped the isolated process group."
    }
}

struct ClaudeSessionConfigurationSnapshot: Sendable, Equatable {
    let generation: Int64
    let name: String
    let developerInstructions: String
    let hasStarted: Bool
}

public actor ClaudeAgentProvider: AgentProviding {
    private enum StdinWriteRaceResult: Sendable, Equatable {
        case completed
        case deadline
    }

    public nonisolated let id = AgentProviderID.claude
    private static let processLogger = Logger(
        subsystem: "ap.codeness",
        category: "ClaudeProcess"
    )

    private struct SessionConfiguration {
        let generation: Int64
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
        let retainedByteCount: Int
    }

    private struct ActiveRun {
        let sessionID: String
        let process: AppServerProcess
        let inputWriter: OrderedPipeWriter
        let outputReader: BoundedPipeReader
        let errorReader: BoundedPipeReader
        let events: BoundedAsyncChannel<AgentEvent>
        let startedAt: ContinuousClock.Instant
        let generation: Int64
        let sessionGeneration: Int64
        let resumedSession: Bool
        let utility: Bool
        var didStart: Bool
        var outputBuffer: Data
        var outputScanOffset: Int
        var stderrTail: Data
        var interactions: [String: ControlInteraction]
        var claimedInteractionRetainedByteCounts: [String: Int]
        var interactionRetainedByteCount: Int
        var latestUsage: RunTokenUsage?
        var latestAssistantText: String?
        var emittedTextHeading: Bool
        var emittedThinkingHeading: Bool
        var transcriptSection: TranscriptSectionKind?
        var terminalDelivered: Bool
        var interruptRequested: Bool
        var termination: SubprocessTermination?
        var outputReachedEOF: Bool
        var errorReachedEOF: Bool
        var teardownRequested: Bool
        var teardownFailure: String?
    }

    private struct InterruptWatchdog {
        let generation: Int64
        let token: UUID
        let task: Task<Void, Never>
    }

    private let executableURL: URL
    private let environment: [String: String]
    private let maximumActiveProcessCount: Int
    private let eventBufferCapacity: Int
    private let maximumEventBufferRetainedBytes: Int
    private let terminalExitGrace: Duration
    private let outputDrainGrace: Duration
    private let terminationGrace: Duration
    private let killVerificationGrace: Duration
    private let stdinWriteTimeout: Duration
    private let interruptGrace: Duration
    private var sessions: [String: SessionConfiguration] = [:]
    private var pendingSessionReleases: [String: Int64] = [:]
    private var activeRuns: [UUID: ActiveRun] = [:]
    private var sessionRuns: [String: UUID] = [:]
    private var processWaitTasks: [UUID: Task<Void, Never>] = [:]
    private var teardownTasks: [UUID: Task<Bool, Never>] = [:]
    private var interruptWatchdogTasks: [UUID: InterruptWatchdog] = [:]
    private var cleanupWaiters: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
    private var nextProcessGeneration: Int64 = 0
    private var nextSessionGeneration: Int64 = 0
    private var isShuttingDown = false
    private var testingTeardownFailure: String?

    private static let maximumOutputBufferByteCount = 32 * 1_024 * 1_024
    private static let maximumOutputReadLookaheadByteCount = 64 * 1_024
    private static let maximumMalformedJSONPreviewByteCount = 4 * 1_024
    private static let maximumPendingInteractionCount = 64
    private static let maximumPendingInteractionRetainedBytes = 4 * 1_024 * 1_024

    public init(
        executableURL: URL,
        environment: [String: String] = CodexExecutableLocator.processEnvironment(),
        maximumActiveProcessCount: Int = 24,
        eventBufferCapacity: Int = 256,
        maximumEventBufferRetainedBytes: Int = 4 * 1_024 * 1_024,
        terminalExitGrace: Duration = .milliseconds(250),
        outputDrainGrace: Duration = .seconds(5),
        terminationGrace: Duration = .milliseconds(250),
        killVerificationGrace: Duration = .milliseconds(500),
        stdinWriteTimeout: Duration = .seconds(5),
        interruptGrace: Duration = .seconds(5)
    ) {
        self.executableURL = executableURL
        self.maximumActiveProcessCount = max(1, maximumActiveProcessCount)
        self.eventBufferCapacity = max(1, eventBufferCapacity)
        self.maximumEventBufferRetainedBytes = max(1_024, maximumEventBufferRetainedBytes)
        self.terminalExitGrace = terminalExitGrace
        self.outputDrainGrace = outputDrainGrace
        self.terminationGrace = terminationGrace
        self.killVerificationGrace = killVerificationGrace
        self.stdinWriteTimeout = stdinWriteTimeout
        self.interruptGrace = interruptGrace
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
        nextSessionGeneration &+= 1
        let generation = nextSessionGeneration
        pendingSessionReleases.removeValue(forKey: sessionID)
        sessions[sessionID] = SessionConfiguration(
            generation: generation,
            name: request.name,
            cwd: request.cwd,
            developerInstructions: request.developerInstructions,
            hasStarted: request.existingSessionID != nil
        )
        return AgentSession(providerID: id, id: sessionID, target: request.target)
    }

    public func startRun(_ request: AgentRunRequest) async throws -> AgentRunHandle {
        guard request.target.providerID == id, request.session.providerID == id else {
            throw AgentProviderError.unsupportedProvider(request.target.providerID)
        }
        guard var session = sessions[request.session.id] else {
            throw AgentProviderError.invalidSession(
                "Claude session \(request.session.id) was not prepared"
            )
        }
        let handle = try await launch(
            runID: request.runID,
            sessionID: request.session.id,
            session: session,
            cwd: request.cwd,
            prompt: request.prompt,
            target: request.target,
            outputSchema: request.outputSchema,
            utility: false
        )
        if sessions[request.session.id]?.generation == session.generation {
            session.hasStarted = true
            sessions[request.session.id] = session
        }
        return handle
    }

    public func steer(runID: UUID, message: String) async throws {
        guard let run = activeRuns[runID] else {
            throw AgentProviderError.missingRun(runID)
        }
        try await write(
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

    public func interrupt(runID: UUID) async throws {
        guard var run = activeRuns[runID] else {
            throw AgentProviderError.missingRun(runID)
        }
        run.interruptRequested = true
        activeRuns[runID] = run
        try await write(
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
        if let currentRun = activeRuns[runID],
           currentRun.generation == run.generation,
           !currentRun.terminalDelivered,
           !currentRun.teardownRequested {
            armInterruptWatchdog(runID: runID, generation: run.generation)
        }
    }

    public func resolveInteraction(
        runID: UUID,
        interactionID: String,
        resolution: AgentInteractionResolution
    ) async throws {
        guard var run = activeRuns[runID],
              let interaction = run.interactions.removeValue(forKey: interactionID) else {
            throw AgentProviderError.missingRun(runID)
        }
        run.claimedInteractionRetainedByteCounts[interactionID] = interaction.retainedByteCount
        activeRuns[runID] = run

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

        try await write(
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
        if var updatedRun = activeRuns[runID],
           let retainedByteCount = updatedRun.claimedInteractionRetainedByteCounts
            .removeValue(forKey: interactionID) {
            updatedRun.interactionRetainedByteCount -= retainedByteCount
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
            generation: 0,
            name: "Codeness coordinator",
            cwd: request.cwd,
            developerInstructions: request.developerInstructions,
            hasStarted: false
        )
        let handle = try await launch(
            runID: runID,
            sessionID: sessionID,
            session: session,
            cwd: request.cwd,
            prompt: request.prompt,
            target: request.target,
            outputSchema: request.outputSchema,
            utility: true
        )
        do {
            let result = try await withTaskCancellationHandler {
                for await event in handle.events {
                    try Task.checkCancellation()
                    switch event {
                    case .completed(let output, _, let usage):
                        return AgentUtilityResult(output: output, tokenUsage: usage)
                    case .failed(let detail):
                        throw AgentProviderError.invalidResponse(detail)
                    case .sessionUnavailable(let detail):
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
                try Task.checkCancellation()
                throw AgentProviderError.invalidResponse(
                    "the Claude coordinator run ended without a result"
                )
            } onCancel: {
                Task {
                    _ = await self.terminateRunAndWait(
                        runID: runID,
                        terminalEvent: nil,
                        allowNaturalExitFirst: false
                    )
                }
            }
            guard await waitForRunCleanup(runID: runID) else {
                throw AgentProviderError.resourceLimit(
                    "Claude returned a utility result, but Codeness could not verify that its isolated process group exited."
                )
            }
            try Task.checkCancellation()
            return result
        } catch {
            if Task.isCancelled {
                _ = await terminateRunAndWait(
                    runID: runID,
                    terminalEvent: nil,
                    allowNaturalExitFirst: false
                )
                throw CancellationError()
            }
            _ = await waitForRunCleanup(runID: runID)
            throw error
        }
    }

    @discardableResult
    public func releaseSession(id sessionID: String) async -> Bool {
        if let activeRun = activeRuns.first(where: { $0.value.sessionID == sessionID }) {
            guard activeRun.value.terminalDelivered || activeRun.value.teardownRequested else {
                return false
            }
            let releaseGeneration = activeRun.value.sessionGeneration
            pendingSessionReleases[sessionID] = releaseGeneration
            guard await waitForRunCleanup(runID: activeRun.key) else { return false }
            guard pendingSessionReleases[sessionID] == releaseGeneration else {
                return true
            }
            if sessions[sessionID]?.generation == releaseGeneration {
                sessions.removeValue(forKey: sessionID)
            }
            pendingSessionReleases.removeValue(forKey: sessionID)
            return true
        }
        sessions.removeValue(forKey: sessionID)
        pendingSessionReleases.removeValue(forKey: sessionID)
        // A missing local session is equivalent to Claude already being
        // detached: there is no remote subscription to clean up for the CLI.
        return true
    }

    public func shutdown() async {
        _ = await shutdownAndVerify()
    }

    @discardableResult
    public func shutdownAndVerify() async -> Bool {
        isShuttingDown = true
        let runIDs = Array(activeRuns.keys)
        for runID in runIDs {
            var attempt = 0
            while activeRuns[runID] != nil, attempt < 3 {
                await beginTeardown(
                    runID: runID,
                    terminalEvent: attempt == 0 ? .failed("Claude stopped.") : nil,
                    allowNaturalExitFirst: false
                )
                attempt += 1
                if await waitForRunCleanup(runID: runID) { break }
            }
        }
        return activeRuns.isEmpty
    }

    func forceTeardownFailureForTesting(_ detail: String?) {
        testingTeardownFailure = detail
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
    ) async throws -> AgentRunHandle {
        guard !isShuttingDown else {
            throw AgentProviderError.resourceLimit("Claude is shutting down.")
        }
        guard activeRuns[runID] == nil else {
            throw AgentProviderError.invalidSession("run \(runID.uuidString) is already active")
        }
        if let existingRunID = sessionRuns[sessionID],
           let existingRun = activeRuns[existingRunID],
           existingRun.terminalDelivered || existingRun.teardownRequested {
            guard await waitForRunCleanup(runID: existingRunID) else {
                throw AgentProviderError.resourceLimit(
                    "Claude session \(sessionID) finished its turn, but Codeness could not verify that its isolated process group exited. Reuse is blocked to prevent overlapping processes."
                )
            }
        }
        if !utility, sessions[sessionID]?.generation != session.generation {
            throw AgentProviderError.invalidSession(
                "Claude session \(sessionID) was reconfigured while its next run was waiting to launch. Retry with the current session configuration."
            )
        }
        guard !isShuttingDown else {
            throw AgentProviderError.resourceLimit("Claude is shutting down.")
        }
        guard sessionRuns[sessionID] == nil else {
            throw AgentProviderError.invalidSession(
                "Claude session \(sessionID) already has an active run."
            )
        }
        if let debt = activeRuns.values.first(where: { $0.teardownFailure != nil }) {
            throw AgentProviderError.resourceLimit(
                debt.teardownFailure
                    ?? "A Claude process group could not be verified as stopped."
            )
        }
        guard activeRuns.count < maximumActiveProcessCount else {
            throw AgentProviderError.resourceLimit(
                "Claude already has \(activeRuns.count) active Codeness process(es); the safety limit is \(maximumActiveProcessCount). Wait for an active step to finish or stop it before starting more work."
            )
        }
        guard !target.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentProviderError.invalidResponse("the Claude model is empty")
        }

        let process = try AppServerProcess.launch(configuration:
            SupervisedProcessLaunchConfiguration(
                executableURL: executableURL,
                arguments: arguments(
                    sessionID: sessionID,
                    session: session,
                    target: target,
                    outputSchema: outputSchema,
                    utility: utility
                ),
                environment: environment,
                currentDirectoryURL: URL(fileURLWithPath: cwd, isDirectory: true)
            )
        )
        nextProcessGeneration &+= 1
        let generation = nextProcessGeneration
        let inputWriter = OrderedPipeWriter(
            fileDescriptor: process.inputFileDescriptor,
            generation: generation
        )
        let outputReader = BoundedPipeReader(
            fileDescriptor: process.outputFileDescriptor,
            label: "ap.codeness.claude.stdout.\(runID.uuidString)",
            qos: .userInitiated
        )
        let errorReader = BoundedPipeReader(
            fileDescriptor: process.errorFileDescriptor,
            label: "ap.codeness.claude.stderr.\(runID.uuidString)",
            qos: .utility
        )
        let events = BoundedAsyncChannel<AgentEvent>(
            capacity: eventBufferCapacity,
            maximumRetainedCost: maximumEventBufferRetainedBytes,
            retainedCost: Self.retainedCost(of:)
        )

        activeRuns[runID] = ActiveRun(
            sessionID: sessionID,
            process: process,
            inputWriter: inputWriter,
            outputReader: outputReader,
            errorReader: errorReader,
            events: events,
            startedAt: ContinuousClock().now,
            generation: generation,
            sessionGeneration: session.generation,
            resumedSession: session.hasStarted,
            utility: utility,
            didStart: false,
            outputBuffer: Data(),
            outputScanOffset: 0,
            stderrTail: Data(),
            interactions: [:],
            claimedInteractionRetainedByteCounts: [:],
            interactionRetainedByteCount: 0,
            latestUsage: nil,
            latestAssistantText: nil,
            emittedTextHeading: false,
            emittedThinkingHeading: false,
            transcriptSection: nil,
            terminalDelivered: false,
            interruptRequested: false,
            termination: nil,
            outputReachedEOF: false,
            errorReachedEOF: false,
            teardownRequested: false,
            teardownFailure: nil
        )
        sessionRuns[sessionID] = runID
        outputReader.start { [weak self] data in
            await self?.consumeOutput(data, runID: runID)
        } reachedEOF: { [weak self] in
            await self?.outputEOF(runID: runID)
        }
        errorReader.start { [weak self] data in
            await self?.emitStandardError(data, runID: runID)
        } reachedEOF: { [weak self] in
            await self?.standardErrorEOF(runID: runID)
        }
        processWaitTasks[runID] = Self.makeProcessWaiter(
            process: process,
            runID: runID,
            provider: self
        )

        do {
            try await write(
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
            guard let currentRun = activeRuns[runID],
                  currentRun.generation == generation,
                  !currentRun.interruptRequested,
                  !currentRun.teardownRequested,
                  !currentRun.terminalDelivered else {
                throw CancellationError()
            }
            try await write(
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
            _ = await terminateRunAndWait(
                runID: runID,
                terminalEvent: nil,
                allowNaturalExitFirst: false
            )
            throw error
        }

        return AgentRunHandle(
            runID: runID,
            providerID: id,
            sessionID: sessionID,
            executionID: nil,
            events: events.stream(
                cancelChannelOnConsumerCancellation: true,
                onConsumerCancellation: { [weak self] in
                    await self?.runEventConsumerCancelled(runID: runID)
                }
            )
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

    private func write(_ message: JSONValue, runID: UUID) async throws {
        guard let run = activeRuns[runID], !run.teardownRequested else {
            throw AgentProviderError.missingRun(runID)
        }
        var data = try message.encodedData()
        data.append(0x0A)
        let token = UUID()
        defer { run.inputWriter.forget(token: token) }
        do {
            let result = try await Self.raceStdinWrite(
                data: data,
                writer: run.inputWriter,
                token: token,
                timeout: stdinWriteTimeout
            )
            if result == .deadline {
                throw ClaudeStdinWriteTimeoutError(timeout: stdinWriteTimeout)
            }
        } catch {
            scheduleTeardown(
                runID: runID,
                terminalEvent: .failed(
                    "Codeness could not write to Claude: \(error.localizedDescription)"
                ),
                allowNaturalExitFirst: false
            )
            throw error
        }
    }

    private func consumeOutput(_ data: Data, runID: UUID) async {
        guard var run = activeRuns[runID] else { return }
        let maximumTransientByteCount = Self.maximumOutputBufferByteCount
            + Self.maximumOutputReadLookaheadByteCount
        guard data.count <= Self.maximumOutputReadLookaheadByteCount,
              run.outputBuffer.count
                <= maximumTransientByteCount - data.count else {
            let retainedByteCount = run.outputBuffer.count + data.count
            run.outputBuffer.removeAll(keepingCapacity: false)
            run.outputScanOffset = 0
            activeRuns[runID] = run
            await failRunForOutputLimit(
                runID: runID,
                retainedByteCount: retainedByteCount
            )
            return
        }
        run.outputBuffer.append(data)
        while run.outputScanOffset < run.outputBuffer.count {
            let searchStart = run.outputBuffer.index(
                run.outputBuffer.startIndex,
                offsetBy: run.outputScanOffset
            )
            guard let newline = run.outputBuffer[searchStart...].firstIndex(of: 0x0A) else {
                run.outputScanOffset = run.outputBuffer.count
                break
            }
            let lineByteCount = run.outputBuffer.distance(
                from: run.outputBuffer.startIndex,
                to: newline
            )
            guard lineByteCount <= Self.maximumOutputBufferByteCount else {
                run.outputBuffer.removeAll(keepingCapacity: false)
                run.outputScanOffset = 0
                activeRuns[runID] = run
                await failRunForOutputLimit(
                    runID: runID,
                    retainedByteCount: lineByteCount
                )
                return
            }
            let line = Data(run.outputBuffer[..<newline])
            run.outputBuffer.removeSubrange(...newline)
            run.outputScanOffset = 0
            guard !line.isEmpty else { continue }
            activeRuns[runID] = run
            await handleLine(line, runID: runID)
            guard let updatedRun = activeRuns[runID] else { return }
            run = updatedRun
        }
        guard run.outputBuffer.count <= Self.maximumOutputBufferByteCount else {
            let retainedByteCount = run.outputBuffer.count
            run.outputBuffer.removeAll(keepingCapacity: false)
            run.outputScanOffset = 0
            activeRuns[runID] = run
            await failRunForOutputLimit(
                runID: runID,
                retainedByteCount: retainedByteCount
            )
            return
        }
        activeRuns[runID] = run
    }

    private func handleLine(_ data: Data, runID: UUID) async {
        guard var run = activeRuns[runID] else { return }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            let previewData = data.prefix(Self.maximumMalformedJSONPreviewByteCount)
            let preview = String(decoding: previewData, as: UTF8.self)
            let suffix = data.count > previewData.count
                ? "\n[preview truncated; malformed line was \(data.count) UTF-8 bytes]"
                : ""
            let diagnostic = transcriptText(
                "Invalid Claude JSON: \(preview)\(suffix)",
                section: .diagnostic,
                run: &run
            )
            activeRuns[runID] = run
            _ = await admit(.diagnostic(diagnostic), runID: runID)
            return
        }

        switch message["type"]?.stringValue {
        case "system":
            if message["subtype"]?.stringValue == "init" {
                let executionID = message["session_id"]?.stringValue ?? run.sessionID
                run.didStart = true
                activeRuns[runID] = run
                guard await admit(.started(executionID: executionID), runID: runID) else {
                    return
                }
                guard let updatedRun = activeRuns[runID] else { return }
                run = updatedRun
            }
            // Claude emits transient status messages (currently "requesting")
            // around virtually every tool call. They are transport state, not
            // transcript content, and can arrive without line boundaries.
        case "stream_event":
            activeRuns[runID] = run
            await consumeStreamEvent(message["event"] ?? .null, runID: runID)
            guard let updatedRun = activeRuns[runID] else { return }
            run = updatedRun
        case "assistant":
            if let text = Self.assistantText(message["message"] ?? .null), !text.isEmpty {
                run.latestAssistantText = text
            }
            if let usage = Self.usage(message["message"]?["usage"]) {
                run.latestUsage = usage
                activeRuns[runID] = run
                guard await admit(.tokenUsage(usage), runID: runID) else { return }
                guard let updatedRun = activeRuns[runID] else { return }
                run = updatedRun
            }
        case "control_request":
            if let interaction = Self.controlInteraction(
                message,
                retainedByteCount: data.count
            ) {
                if run.utility {
                    activeRuns[runID] = run
                    await beginTeardown(
                        runID: runID,
                        terminalEvent: .failed(
                            "Claude requested user interaction during an unattended coordinator run. Codeness stopped the isolated process group instead of waiting for a dialog that cannot be presented."
                        ),
                        allowNaturalExitFirst: false
                    )
                    return
                }
                guard run.interactions[interaction.control.requestID] == nil,
                      run.claimedInteractionRetainedByteCounts[
                        interaction.control.requestID
                      ] == nil else {
                    activeRuns[runID] = run
                    await beginTeardown(
                        runID: runID,
                        terminalEvent: .failed(
                            "Claude reused an unresolved permission request identifier. Codeness stopped the isolated process group instead of allowing a hidden request to replace the visible request."
                        ),
                        allowNaturalExitFirst: false
                    )
                    return
                }
                let pendingCount = run.interactions.count
                    + run.claimedInteractionRetainedByteCounts.count
                    + 1
                let pendingByteCount = run.interactionRetainedByteCount
                    + interaction.control.retainedByteCount
                guard pendingCount <= Self.maximumPendingInteractionCount,
                      pendingByteCount <= Self.maximumPendingInteractionRetainedBytes else {
                    activeRuns[runID] = run
                    await beginTeardown(
                        runID: runID,
                        terminalEvent: .failed(
                            "Claude accumulated too many unresolved permission requests. Codeness stopped the isolated process group to prevent unbounded memory growth."
                        ),
                        allowNaturalExitFirst: false
                    )
                    return
                }
                run.interactions[interaction.control.requestID] = interaction.control
                run.interactionRetainedByteCount = pendingByteCount
                activeRuns[runID] = run
                guard await admit(.interaction(interaction.presentation), runID: runID) else {
                    return
                }
                guard let updatedRun = activeRuns[runID] else { return }
                run = updatedRun
            }
        case "control_cancel_request":
            if let requestID = message["request_id"]?.stringValue {
                if let removed = run.interactions.removeValue(forKey: requestID) {
                    run.interactionRetainedByteCount -= removed.retainedByteCount
                }
                activeRuns[runID] = run
                guard await admit(.interactionResolved(requestID), runID: runID) else { return }
                guard let updatedRun = activeRuns[runID] else { return }
                run = updatedRun
            }
        case "result":
            activeRuns[runID] = run
            await consumeResult(message, runID: runID)
            return
        case "user", "control_response", "keep_alive":
            break
        default:
            break
        }
        activeRuns[runID] = run
    }

    private func consumeStreamEvent(_ event: JSONValue, runID: UUID) async {
        guard var run = activeRuns[runID] else { return }
        switch event["type"]?.stringValue {
        case "content_block_start":
            let block = event["content_block"] ?? .null
            if block["type"]?.stringValue == "tool_use" {
                let name = block["name"]?.stringValue ?? "tool"
                let text = transcriptText(
                    "\n› \(name)\n",
                    section: .action,
                    run: &run
                )
                activeRuns[runID] = run
                _ = await admit(.transcript(text), runID: runID)
                return
            }
        case "content_block_delta":
            let delta = event["delta"] ?? .null
            switch delta["type"]?.stringValue {
            case "text_delta":
                guard let text = delta["text"]?.stringValue, !text.isEmpty else { return }
                if !run.emittedTextHeading {
                    run.emittedTextHeading = true
                    let heading = transcriptText(
                        "\n\nClaude\n",
                        section: .reasoning,
                        run: &run
                    )
                    activeRuns[runID] = run
                    guard await admit(
                        .transcript(heading),
                        runID: runID
                    ) else { return }
                    guard let updatedRun = activeRuns[runID] else { return }
                    run = updatedRun
                }
                let transcript = transcriptText(
                    text,
                    section: .reasoning,
                    run: &run
                )
                activeRuns[runID] = run
                _ = await admit(.transcript(transcript), runID: runID)
                return
            case "thinking_delta":
                guard let text = delta["thinking"]?.stringValue, !text.isEmpty else { return }
                if !run.emittedThinkingHeading {
                    run.emittedThinkingHeading = true
                    let heading = transcriptText(
                        "\n\nReasoning\n",
                        section: .reasoning,
                        run: &run
                    )
                    activeRuns[runID] = run
                    guard await admit(
                        .transcript(heading),
                        runID: runID
                    ) else { return }
                    guard let updatedRun = activeRuns[runID] else { return }
                    run = updatedRun
                }
                let transcript = transcriptText(
                    text,
                    section: .reasoning,
                    run: &run
                )
                activeRuns[runID] = run
                _ = await admit(.transcript(transcript), runID: runID)
                return
            default:
                break
            }
        case "message_delta":
            if let usage = Self.usage(event["usage"]) {
                run.latestUsage = usage
                activeRuns[runID] = run
                _ = await admit(.tokenUsage(usage), runID: runID)
                return
            }
        default:
            break
        }
        activeRuns[runID] = run
    }

    private func transcriptText(
        _ text: String,
        section: TranscriptSectionKind,
        run: inout ActiveRun
    ) -> String {
        defer { run.transcriptSection = section }
        guard run.transcriptSection != section else { return text }
        return RunTranscriptPresentation.storedText(text, section: section)
    }

    private func consumeResult(_ message: JSONValue, runID: UUID) async {
        guard let run = activeRuns[runID] else { return }
        guard !run.terminalDelivered else { return }
        let usage = Self.usage(message["usage"]) ?? run.latestUsage
        let duration = message["duration_ms"]?.integerValue
        let terminalEvent: AgentEvent
        if message["is_error"]?.boolValue == true {
            let errors = message["errors"]?.arrayValue?.compactMap(\.stringValue)
                .joined(separator: "\n")
            let detail = errors?.isEmpty == false
                ? errors
                : message["result"]?.stringValue
            if run.interruptRequested {
                terminalEvent = .interrupted(detail)
            } else if run.resumedSession,
                      !run.didStart,
                      Self.confirmsMissingSession(detail ?? "") {
                terminalEvent = .sessionUnavailable(
                    detail ?? "The Claude session is unavailable."
                )
            } else {
                terminalEvent = .failed(detail ?? "Claude returned an error result.")
            }
        } else {
            let output = message["result"]?.stringValue
                ?? message["structured_output"]?.encodedString(prettyPrinted: true)
                ?? run.latestAssistantText
                ?? ""
            if output.isEmpty {
                terminalEvent = .failed("Claude completed without a final result.")
            } else {
                terminalEvent = .completed(
                    output: output,
                    durationMilliseconds: duration,
                    tokenUsage: usage
                )
            }
        }
        activeRuns[runID] = run
        await deliverTerminal(terminalEvent, runID: runID)
    }

    private func emitStandardError(_ data: Data, runID: UUID) async {
        guard var run = activeRuns[runID] else { return }
        run.stderrTail.append(data)
        if run.stderrTail.count > 4_000 {
            run.stderrTail = Data(run.stderrTail.suffix(4_000))
        }
        let text = String(decoding: data, as: UTF8.self)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            activeRuns[runID] = run
            return
        }
        let diagnostic = transcriptText(
            "\n\(clean)\n",
            section: .diagnostic,
            run: &run
        )
        activeRuns[runID] = run
        _ = await admit(.diagnostic(diagnostic), runID: runID)
    }

    private func outputEOF(runID: UUID) async {
        guard var run = activeRuns[runID] else { return }
        if !run.outputBuffer.isEmpty {
            let finalLine = run.outputBuffer
            run.outputBuffer.removeAll(keepingCapacity: false)
            run.outputScanOffset = 0
            activeRuns[runID] = run
            await handleLine(finalLine, runID: runID)
            guard let updated = activeRuns[runID] else { return }
            run = updated
        }
        run.outputReachedEOF = true
        activeRuns[runID] = run
        if run.termination != nil {
            await beginTeardown(
                runID: runID,
                terminalEvent: nil,
                allowNaturalExitFirst: false
            )
        } else if !run.terminalDelivered, !run.teardownRequested {
            await beginTeardown(
                runID: runID,
                // Defer classification until the leader is reaped and stderr
                // is fully drained; resumed-session errors often arrive there.
                terminalEvent: nil,
                allowNaturalExitFirst: false
            )
        }
    }

    private func standardErrorEOF(runID: UUID) {
        guard var run = activeRuns[runID] else { return }
        run.errorReachedEOF = true
        activeRuns[runID] = run
    }

    private func processTerminated(
        runID: UUID,
        termination: SubprocessTermination
    ) async {
        guard var run = activeRuns[runID] else { return }
        run.termination = termination
        activeRuns[runID] = run
        await beginTeardown(
            runID: runID,
            terminalEvent: nil,
            allowNaturalExitFirst: !run.outputReachedEOF
        )
    }

    private func admit(_ event: AgentEvent, runID: UUID) async -> Bool {
        guard let events = activeRuns[runID]?.events else { return false }
        switch await events.trySend(event) {
        case .accepted:
            return true
        case .full:
            await beginTeardown(
                runID: runID,
                terminalEvent: .failed(
                    "Claude produced more run output than Codeness could retain because this run's event consumer stopped draining. Codeness stopped the isolated process group to prevent unbounded memory growth."
                ),
                allowNaturalExitFirst: false
            )
            return false
        case .terminated:
            await beginTeardown(
                runID: runID,
                terminalEvent: nil,
                allowNaturalExitFirst: false
            )
            return false
        }
    }

    private func deliverTerminal(_ event: AgentEvent, runID: UUID) async {
        guard var run = activeRuns[runID], !run.terminalDelivered else { return }
        run.terminalDelivered = true
        activeRuns[runID] = run
        if !(await run.events.finish(with: event)) {
            _ = await run.events.finish(with: .failed(
                "Claude ended the turn, but its final event exceeded Codeness's bounded event limit."
            ))
        }
        await beginTeardown(
            runID: runID,
            terminalEvent: nil,
            allowNaturalExitFirst: true
        )
    }

    private func failRunForOutputLimit(runID: UUID, retainedByteCount: Int) async {
        await beginTeardown(
            runID: runID,
            terminalEvent: .failed(
                "Claude emitted an unterminated JSON line larger than Codeness's 32 MiB safety limit (at least \(retainedByteCount) bytes). Codeness stopped the isolated process group."
            ),
            allowNaturalExitFirst: false
        )
    }

    private func beginTeardown(
        runID: UUID,
        terminalEvent: AgentEvent?,
        allowNaturalExitFirst: Bool
    ) async {
        guard var run = activeRuns[runID] else { return }
        interruptWatchdogTasks.removeValue(forKey: runID)?.task.cancel()
        if let terminalEvent, !run.terminalDelivered {
            run.terminalDelivered = true
            activeRuns[runID] = run
            if !(await run.events.finish(with: terminalEvent)) {
                _ = await run.events.finish(with: .failed(
                    "Claude stopped, but Codeness could not retain its final event within the bounded event buffer."
                ))
            }
            guard let updatedRun = activeRuns[runID] else { return }
            run = updatedRun
        }
        guard teardownTasks[runID] == nil else { return }
        run.teardownRequested = true
        run.teardownFailure = nil
        run.interactions.removeAll(keepingCapacity: false)
        run.claimedInteractionRetainedByteCounts.removeAll(keepingCapacity: false)
        run.interactionRetainedByteCount = 0
        activeRuns[runID] = run
        run.inputWriter.close()

        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performVerifiedTeardown(
                runID: runID,
                allowNaturalExitFirst: allowNaturalExitFirst
            )
        }
        teardownTasks[runID] = task
    }

    private func scheduleTeardown(
        runID: UUID,
        terminalEvent: AgentEvent?,
        allowNaturalExitFirst: Bool
    ) {
        Task { [weak self] in
            await self?.beginTeardown(
                runID: runID,
                terminalEvent: terminalEvent,
                allowNaturalExitFirst: allowNaturalExitFirst
            )
        }
    }

    private func performVerifiedTeardown(
        runID: UUID,
        allowNaturalExitFirst: Bool
    ) async -> Bool {
        guard let process = activeRuns[runID]?.process else { return true }
        if let testingTeardownFailure {
            recordTeardownFailure(runID: runID, detail: testingTeardownFailure)
            return false
        }
        if allowNaturalExitFirst {
            try? await Task.sleep(for: terminalExitGrace)
        }
        if process.groupExists {
            _ = process.signalGroup(SIGTERM)
            try? await Task.sleep(for: terminationGrace)
        }
        if process.groupExists {
            _ = process.signalGroup(SIGKILL)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: killVerificationGrace)
            while process.groupExists, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        guard !process.groupExists else {
            recordTeardownFailure(
                runID: runID,
                detail: "SIGKILL did not remove Claude process group \(process.processGroupIdentifier). New Claude work remains blocked to prevent orphan accumulation."
            )
            return false
        }

        let clock = ContinuousClock()
        let reapDeadline = clock.now.advanced(by: killVerificationGrace)
        while activeRuns[runID]?.termination == nil, clock.now < reapDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard activeRuns[runID]?.termination != nil else {
            recordTeardownFailure(
                runID: runID,
                detail: "Claude process group \(process.processGroupIdentifier) disappeared, but Codeness could not confirm that its leader was reaped. New Claude work remains blocked."
            )
            return false
        }

        let drainDeadline = clock.now.advanced(by: outputDrainGrace)
        while activeRuns[runID].map({ !$0.outputReachedEOF || !$0.errorReachedEOF }) == true,
              clock.now < drainDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if activeRuns[runID].map({ !$0.outputReachedEOF || !$0.errorReachedEOF }) == true {
            await deliverTerminal(
                .failed(
                    "Claude exited, but Codeness could not finish draining its bounded stdout/stderr streams before the safety deadline. The isolated process group was stopped."
                ),
                runID: runID
            )
        }

        guard let run = activeRuns[runID] else { return true }
        await run.inputWriter.closeAndWait()
        await run.outputReader.stop(cancelConsumer: true)
        await run.errorReader.stop(cancelConsumer: true)
        await completeVerifiedTeardown(runID: runID)
        return true
    }

    private func recordTeardownFailure(runID: UUID, detail: String) {
        guard var run = activeRuns[runID] else { return }
        run.teardownFailure = detail
        activeRuns[runID] = run
        teardownTasks.removeValue(forKey: runID)
        resolveCleanupWaiters(runID: runID, confirmed: false)
    }

    private func completeVerifiedTeardown(runID: UUID) async {
        guard var run = activeRuns[runID] else { return }
        if !run.terminalDelivered {
            let terminalEvent = terminalEventForProcessExit(run)
            run.terminalDelivered = true
            activeRuns[runID] = run
            if !(await run.events.finish(with: terminalEvent)) {
                _ = await run.events.finish(with: .failed(
                    "Claude exited, but Codeness could not retain its final event within the bounded event buffer."
                ))
            }
        } else {
            await run.events.finish()
        }

        guard let removedRun = activeRuns.removeValue(forKey: runID) else { return }
        if sessionRuns[removedRun.sessionID] == runID {
            sessionRuns.removeValue(forKey: removedRun.sessionID)
        }
        if pendingSessionReleases[removedRun.sessionID] == removedRun.sessionGeneration,
           !activeRuns.values.contains(where: { $0.sessionID == removedRun.sessionID }) {
            if sessions[removedRun.sessionID]?.generation == removedRun.sessionGeneration {
                sessions.removeValue(forKey: removedRun.sessionID)
            }
            pendingSessionReleases.removeValue(forKey: removedRun.sessionID)
        }
        processWaitTasks.removeValue(forKey: runID)
        teardownTasks.removeValue(forKey: runID)
        interruptWatchdogTasks.removeValue(forKey: runID)?.task.cancel()
        resolveCleanupWaiters(runID: runID, confirmed: true)
    }

    private func terminalEventForProcessExit(_ run: ActiveRun) -> AgentEvent {
        let detail = String(decoding: run.stderrTail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if run.interruptRequested {
            return .interrupted(detail.isEmpty ? nil : detail)
        }
        if run.resumedSession,
           !run.didStart,
           Self.confirmsMissingSession(detail) {
            return .sessionUnavailable(detail)
        }
        let termination = run.termination
            ?? SubprocessTermination(reason: .exit, status: -1)
        Self.processLogger.error(
            "\(termination.diagnosticDescription(subject: "Claude"), privacy: .public)"
        )
        return .failed(
            AgentProviderError.processExited(
                provider: id,
                termination: termination,
                detail: detail
            ).localizedDescription
        )
    }

    private func waitForRunCleanup(runID: UUID) async -> Bool {
        guard activeRuns[runID] != nil else { return true }
        if activeRuns[runID]?.teardownFailure != nil,
           teardownTasks[runID] == nil {
            return false
        }
        return await withCheckedContinuation { continuation in
            if activeRuns[runID] == nil {
                continuation.resume(returning: true)
            } else if activeRuns[runID]?.teardownFailure != nil,
                      teardownTasks[runID] == nil {
                continuation.resume(returning: false)
            } else {
                cleanupWaiters[runID, default: []].append(continuation)
            }
        }
    }

    private func resolveCleanupWaiters(runID: UUID, confirmed: Bool) {
        let waiters = cleanupWaiters.removeValue(forKey: runID) ?? []
        waiters.forEach { $0.resume(returning: confirmed) }
    }

    private func terminateRunAndWait(
        runID: UUID,
        terminalEvent: AgentEvent?,
        allowNaturalExitFirst: Bool
    ) async -> Bool {
        await beginTeardown(
            runID: runID,
            terminalEvent: terminalEvent,
            allowNaturalExitFirst: allowNaturalExitFirst
        )
        return await waitForRunCleanup(runID: runID)
    }

    private func runEventConsumerCancelled(runID: UUID) async {
        _ = await terminateRunAndWait(
            runID: runID,
            terminalEvent: nil,
            allowNaturalExitFirst: false
        )
    }

    private func armInterruptWatchdog(runID: UUID, generation: Int64) {
        guard let run = activeRuns[runID],
              run.generation == generation,
              !run.terminalDelivered,
              !run.teardownRequested else { return }
        if let watchdog = interruptWatchdogTasks[runID] {
            guard watchdog.generation != generation else { return }
            interruptWatchdogTasks.removeValue(forKey: runID)?.task.cancel()
        }
        let grace = interruptGrace
        let token = UUID()
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: grace)
            } catch {
                return
            }
            await self?.interruptWatchdogFired(
                runID: runID,
                generation: generation,
                token: token
            )
        }
        interruptWatchdogTasks[runID] = InterruptWatchdog(
            generation: generation,
            token: token,
            task: task
        )
    }

    private func interruptWatchdogFired(
        runID: UUID,
        generation: Int64,
        token: UUID
    ) async {
        guard interruptWatchdogTasks[runID]?.token == token else { return }
        interruptWatchdogTasks.removeValue(forKey: runID)
        guard let run = activeRuns[runID],
              run.generation == generation,
              run.interruptRequested,
              !run.terminalDelivered else { return }
        await beginTeardown(
            runID: runID,
            terminalEvent: .interrupted(
                "Claude did not stop after accepting the interrupt request; Codeness stopped its isolated process group."
            ),
            allowNaturalExitFirst: false
        )
    }

    private static func confirmsMissingSession(_ detail: String) -> Bool {
        detail.localizedCaseInsensitiveContains(
            "no conversation found with session id"
        )
    }

    func activeRunCount() -> Int {
        activeRuns.count
    }

    func interruptWatchdogCount() -> Int {
        interruptWatchdogTasks.count
    }

    func preparedSessionCount() -> Int {
        sessions.count
    }

    func sessionConfigurationSnapshot(
        id sessionID: String
    ) -> ClaudeSessionConfigurationSnapshot? {
        guard let session = sessions[sessionID] else { return nil }
        return ClaudeSessionConfigurationSnapshot(
            generation: session.generation,
            name: session.name,
            developerInstructions: session.developerInstructions,
            hasStarted: session.hasStarted
        )
    }

    func stderrTailByteCount(runID: UUID) -> Int? {
        activeRuns[runID]?.stderrTail.count
    }

    func pendingInteractionCount(runID: UUID) -> Int? {
        activeRuns[runID]?.interactions.count
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
        let input = max(0, value["input_tokens"]?.integerValue ?? 0)
        let cached = max(0, value["cache_read_input_tokens"]?.integerValue ?? 0)
        let cacheWrite = max(0, value["cache_creation_input_tokens"]?.integerValue ?? 0)
        let output = max(0, value["output_tokens"]?.integerValue ?? 0)
        guard input > 0 || cached > 0 || cacheWrite > 0 || output > 0 else { return nil }
        let totalInput = saturatingTokenSum(
            saturatingTokenSum(input, cached),
            cacheWrite
        )
        return RunTokenUsage(
            totalTokens: saturatingTokenSum(totalInput, output),
            inputTokens: totalInput,
            cachedInputTokens: cached,
            cacheWriteInputTokens: cacheWrite,
            outputTokens: output
        )
    }

    private nonisolated static func saturatingTokenSum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private nonisolated static func assistantText(_ message: JSONValue) -> String? {
        let text = message["content"]?.arrayValue?.compactMap { block -> String? in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }.joined(separator: "\n")
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func controlInteraction(
        _ message: JSONValue,
        retainedByteCount: Int
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
                questions: questions,
                retainedByteCount: retainedByteCount
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
                questions: [],
                retainedByteCount: retainedByteCount
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
                questions: [],
                retainedByteCount: retainedByteCount
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

    private nonisolated static func makeProcessWaiter(
        process: AppServerProcess,
        runID: UUID,
        provider: ClaudeAgentProvider
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak provider] in
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
                    ? SubprocessTermination(
                        reason: .exit,
                        status: (waitStatus >> 8) & 0xFF
                    )
                    : SubprocessTermination(reason: .uncaughtSignal, status: signal)
            } else {
                termination = SubprocessTermination(reason: .exit, status: -1)
            }
            await provider?.processTerminated(
                runID: runID,
                termination: termination
            )
        }
    }

    private nonisolated static func raceStdinWrite(
        data: sending Data,
        writer: OrderedPipeWriter,
        token: UUID,
        timeout: Duration
    ) async throws -> StdinWriteRaceResult {
        let writeData = data
        return try await withThrowingTaskGroup(of: StdinWriteRaceResult.self) { group in
            group.addTask {
                try await writer.write(writeData, token: token)
                return .completed
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return stdinWriteCompletedAtDeadline(writer.cancel(token: token))
                    ? .completed
                    : .deadline
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw AgentProviderError.invalidResponse(
                    "Claude stdin write ended without a result."
                )
            }
            return first
        }
    }

    nonisolated static func stdinWriteCompletedAtDeadline(
        _ disposition: OrderedPipeWriter.CancellationDisposition
    ) -> Bool {
        if case .completed = disposition { return true }
        return false
    }

    private nonisolated static func retainedCost(of event: AgentEvent) -> Int {
        let structuralOverhead = 256
        switch event {
        case .started(let executionID), .interactionResolved(let executionID):
            return saturatingSum(structuralOverhead, executionID.utf8.count)
        case .transcript(let text), .diagnostic(let text), .sessionUnavailable(let text),
             .failed(let text):
            return saturatingSum(structuralOverhead, text.utf8.count)
        case .interrupted(let detail):
            return saturatingSum(structuralOverhead, detail?.utf8.count ?? 0)
        case .completed(let output, _, _):
            return saturatingSum(structuralOverhead, output.utf8.count)
        case .tokenUsage:
            return structuralOverhead
        case .interaction(let interaction):
            var cost = structuralOverhead
            cost = saturatingSum(cost, interaction.id.utf8.count)
            cost = saturatingSum(cost, interaction.title.utf8.count)
            cost = saturatingSum(cost, interaction.detail.utf8.count)
            cost = saturatingSum(cost, retainedCost(of: interaction.rawParameters))
            for question in interaction.questions {
                cost = saturatingSum(cost, question.id.utf8.count)
                cost = saturatingSum(cost, question.header.utf8.count)
                cost = saturatingSum(cost, question.question.utf8.count)
                for option in question.options {
                    cost = saturatingSum(cost, option.label.utf8.count)
                    cost = saturatingSum(cost, option.description.utf8.count)
                }
            }
            for decision in interaction.decisions {
                cost = saturatingSum(cost, decision.id.utf8.count)
                cost = saturatingSum(cost, decision.label.utf8.count)
                cost = saturatingSum(cost, decision.explanation.utf8.count)
                cost = saturatingSum(cost, retainedCost(of: decision.payload))
            }
            return cost
        }
    }

    private nonisolated static func retainedCost(of value: JSONValue) -> Int {
        switch value {
        case .null, .bool, .integer, .number:
            return 16
        case .string(let string):
            return saturatingSum(16, string.utf8.count)
        case .array(let values):
            return values.reduce(16) { partial, value in
                saturatingSum(partial, retainedCost(of: value))
            }
        case .object(let object):
            return object.reduce(16) { partial, entry in
                let withKey = saturatingSum(partial, entry.key.utf8.count)
                return saturatingSum(withKey, retainedCost(of: entry.value))
            }
        }
    }

    private nonisolated static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
