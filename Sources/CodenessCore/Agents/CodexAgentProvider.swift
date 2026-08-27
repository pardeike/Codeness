import Foundation

struct CodexProviderCleanupDebtSnapshot: Sendable, Equatable {
    let interruptedRuns: [UUID: String]
    let deleteThreads: [String: String]
    let unsubscribeThreads: [String: String]
    let protocolContainment: String?
}

struct CodexProviderRunEventSnapshot: Sendable, Equatable {
    let itemsWithDeltas: Set<String>
    let finalOutput: String?
}

struct CodexCleanupRetryPolicy: Sendable {
    let maximumAttemptCount: Int
    let baseDelay: Duration
    let maximumDelay: Duration

    init(
        maximumAttemptCount: Int = 8,
        baseDelay: Duration = .milliseconds(250),
        maximumDelay: Duration = .seconds(8)
    ) {
        self.maximumAttemptCount = max(1, maximumAttemptCount)
        self.baseDelay = max(.zero, baseDelay)
        self.maximumDelay = max(.zero, maximumDelay)
    }

    func delay(afterAttempt attempt: Int, resourceKey: String) -> Duration {
        let exponent = min(max(0, attempt - 1), 10)
        let exponentialDelay = baseDelay * (1 << exponent)
        let jitter = Self.jitterNumerator(resourceKey: resourceKey, attempt: attempt)
        return min(maximumDelay, exponentialDelay * jitter / 1_000)
    }

    private static func jitterNumerator(resourceKey: String, attempt: Int) -> Int {
        // Stable per-resource jitter keeps concurrent cleanup waves from
        // synchronizing while preserving deterministic tests and diagnostics.
        var checksum = UInt64(truncatingIfNeeded: attempt)
        for byte in resourceKey.utf8 {
            checksum = (checksum &* 16_777_619) ^ UInt64(byte)
        }
        return 875 + Int(checksum % 251)
    }
}

public actor CodexAgentProvider: AgentProviding {
    public nonisolated let id = AgentProviderID.codex
    public static let maximumLoadedThreadBudget = 24
    public static let maximumPersistentWorkflowSessionCount =
        maximumLoadedThreadBudget - 1

    private struct PendingInteractionRequest {
        let requestID: JSONValue
        let retainedByteCount: Int
    }

    private final class ActiveRun {
        let sessionID: String
        var executionID: String?
        let events: BoundedAsyncChannel<AgentEvent>
        var itemsWithDeltas: Set<String>
        var deltaItemRetainedByteCount: Int
        var tokenUsageBaseline: RunTokenUsage?
        var latestUsage: RunTokenUsage?
        var finalOutput: String?
        var interactionRequests: [String: PendingInteractionRequest]
        var claimedInteractionRequests: [String: PendingInteractionRequest]
        var interactionRetainedByteCount: Int
        var isTerminating: Bool
        var isFinishing: Bool

        init(
            sessionID: String,
            executionID: String?,
            events: BoundedAsyncChannel<AgentEvent>
        ) {
            self.sessionID = sessionID
            self.executionID = executionID
            self.events = events
            itemsWithDeltas = []
            deltaItemRetainedByteCount = 0
            tokenUsageBaseline = nil
            latestUsage = nil
            finalOutput = nil
            interactionRequests = [:]
            claimedInteractionRequests = [:]
            interactionRetainedByteCount = 0
            isTerminating = false
            isFinishing = false
        }
    }

    private struct CleanupDebt {
        enum State {
            case requestInFlight
            case requestFailed
            case awaitingTerminal
            case terminalReceived
        }

        var attempts: Int
        var lastError: String
        var state: State
        var target: InterruptionTarget?
    }

    private struct InterruptionTarget: Equatable {
        let protocolGenerationRevision: UInt64
        let sessionID: String
        let executionID: String
    }

    private struct CleanupTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct ProtocolContainment {
        let id: UUID
        var detail: String
        var cleanupIsUnconfirmed: Bool
    }

    private struct UnsubscribeTask {
        let id: UUID
        let task: Task<Bool, Never>
    }

    private enum ThreadReleaseReadiness {
        case ready
        case generationContained
        case cleanupUnconfirmed
    }

    private let appServer: CodexAppServerClient
    private var models: [CodexModel]
    private var activeRuns: [UUID: ActiveRun] = [:]
    private var sessionRuns: [String: UUID] = [:]
    private var executionRuns: [String: UUID] = [:]
    private var retiredExecutionIDs: Set<String> = []
    private var retiredExecutionIDOrder: [String] = []
    private var requestRuns: [String: UUID] = [:]
    private var attachedSessionIDs: Set<String> = []
    private var retainedUtilityThreadIDs: Set<String> = []
    private var utilityRunSessions: [UUID: String] = [:]
    private var runCancellationTasks: [UUID: CleanupTask] = [:]
    private var runCancellationRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var interruptionTerminalTasks: [UUID: Task<Void, Never>] = [:]
    private var interruptionDebts: [UUID: CleanupDebt] = [:]
    private var protocolContainment: ProtocolContainment?
    private var protocolGenerationRevision: UInt64 = 0
    private var runTerminationWaiters: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
    private var utilityRunsAwaitingProviderCancellation: Set<UUID> = []
    private var unsubscribeTasks: [String: UnsubscribeTask] = [:]
    private var unsubscribeRetryTasks: [String: Task<Void, Never>] = [:]
    private var unsubscribeDebts: [String: CleanupDebt] = [:]
    private var deleteTasks: [String: UnsubscribeTask] = [:]
    private var deleteRetryTasks: [String: Task<Void, Never>] = [:]
    private var deleteDebts: [String: CleanupDebt] = [:]
    private var admissionLocked = false
    private var admissionWaiters: [CheckedContinuation<Void, Never>] = []
    private let maximumLoadedThreadCount: Int
    private let maximumRetainedUtilityThreadCount: Int
    private let cleanupRetryPolicy: CodexCleanupRetryPolicy
    private let interruptionTerminalTimeout: Duration
    private let backgroundTerminalCleanupTimeout: Duration
    private let eventBufferCapacity: Int
    private let maximumEventBufferRetainedBytes: Int
    private static let maximumPendingInteractionCount = 64
    private static let maximumPendingInteractionRetainedBytes = 4 * 1_024 * 1_024
    private static let maximumDeltaItemCount = 2_048
    private static let maximumDeltaItemRetainedBytes = 2 * 1_024 * 1_024
    private static let maximumRetiredExecutionIDCount = 4_096

    public init(
        appServer: CodexAppServerClient,
        models: [CodexModel] = [],
        maximumLoadedThreadCount: Int = CodexAgentProvider.maximumLoadedThreadBudget,
        maximumRetainedUtilityThreadCount: Int = 20,
        maximumCleanupAttemptCount: Int = 8,
        cleanupRetryDelay: Duration = .milliseconds(250),
        interruptionTerminalTimeout: Duration = .seconds(2),
        backgroundTerminalCleanupTimeout: Duration = .seconds(1),
        eventBufferCapacity: Int = 64,
        maximumEventBufferRetainedBytes: Int = 4 * 1_024 * 1_024
    ) {
        self.appServer = appServer
        self.models = models
        self.maximumLoadedThreadCount = max(1, maximumLoadedThreadCount)
        self.maximumRetainedUtilityThreadCount = max(1, maximumRetainedUtilityThreadCount)
        cleanupRetryPolicy = CodexCleanupRetryPolicy(
            maximumAttemptCount: maximumCleanupAttemptCount,
            baseDelay: cleanupRetryDelay
        )
        self.interruptionTerminalTimeout = max(.milliseconds(10), interruptionTerminalTimeout)
        self.backgroundTerminalCleanupTimeout = max(
            .milliseconds(10),
            backgroundTerminalCleanupTimeout
        )
        self.eventBufferCapacity = max(1, eventBufferCapacity)
        self.maximumEventBufferRetainedBytes = max(1_024, maximumEventBufferRetainedBytes)
    }

    public func updateModels(_ models: [CodexModel]) {
        self.models = models
    }

    public func prepareSession(_ request: AgentSessionRequest) async throws -> AgentSession {
        guard request.target.providerID == id else {
            throw AgentProviderError.unsupportedProvider(request.target.providerID)
        }
        try requireAvailableProtocolGeneration()
        let admittedProtocolRevision = protocolGenerationRevision
        await acquireAdmission()
        defer { releaseAdmission() }
        try requireAvailableProtocolGeneration(admittedRevision: admittedProtocolRevision)
        try Task.checkCancellation()
        if let existingSessionID = request.existingSessionID {
            if attachedSessionIDs.contains(existingSessionID) {
                return AgentSession(providerID: id, id: existingSessionID, target: request.target)
            }
            await cancelPendingUnsubscribe(for: existingSessionID)
            try requireAvailableProtocolGeneration(admittedRevision: admittedProtocolRevision)
            try await enforceLoadedThreadLimit(reusing: existingSessionID)
            try requireAvailableProtocolGeneration(admittedRevision: admittedProtocolRevision)
            do {
                try await appServer.resumeThread(
                    id: existingSessionID,
                    cwd: request.cwd,
                    model: request.target.model,
                    developerInstructions: request.developerInstructions,
                    approvalPolicy: "never"
                )
                try requireAvailableProtocolGeneration(admittedRevision: admittedProtocolRevision)
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
            if Task.isCancelled {
                await releaseDetachedThread(id: existingSessionID)
                throw CancellationError()
            }
            attachedSessionIDs.insert(existingSessionID)
            return AgentSession(providerID: id, id: existingSessionID, target: request.target)
        }

        try await enforceLoadedThreadLimit(reusing: nil)
        try requireAvailableProtocolGeneration(admittedRevision: admittedProtocolRevision)
        let sessionID = try await appServer.startThread(
            cwd: request.cwd,
            model: request.target.model,
            developerInstructions: request.developerInstructions,
            readOnly: request.target.options.mode == .plan,
            approvalPolicy: "never"
        )
        try requireAvailableProtocolGeneration(admittedRevision: admittedProtocolRevision)
        if Task.isCancelled {
            await releaseDetachedThread(id: sessionID)
            throw CancellationError()
        }
        do {
            try await appServer.setThreadName(id: sessionID, name: request.name)
            try requireAvailableProtocolGeneration(admittedRevision: admittedProtocolRevision)
        } catch {
            if protocolContainment == nil,
               protocolGenerationRevision == admittedProtocolRevision {
                await releaseDetachedThread(id: sessionID)
            }
            throw error
        }
        if Task.isCancelled {
            await releaseDetachedThread(id: sessionID)
            throw CancellationError()
        }
        attachedSessionIDs.insert(sessionID)
        return AgentSession(providerID: id, id: sessionID, target: request.target)
    }

    public func startRun(_ request: AgentRunRequest) async throws -> AgentRunHandle {
        guard request.target.providerID == id, request.session.providerID == id else {
            throw AgentProviderError.unsupportedProvider(request.target.providerID)
        }
        guard activeRuns[request.runID] == nil else {
            throw AgentProviderError.invalidSession("run \(request.runID.uuidString) is already active")
        }
        guard sessionRuns[request.session.id] == nil else {
            throw AgentProviderError.invalidSession(
                "Codex session \(request.session.id) already has an active run."
            )
        }
        try requireAvailableProtocolGeneration()
        let admittedProtocolRevision = protocolGenerationRevision
        try Task.checkCancellation()

        let events = BoundedAsyncChannel<AgentEvent>(
            capacity: eventBufferCapacity,
            maximumRetainedCost: maximumEventBufferRetainedBytes,
            retainedCost: Self.retainedCost(of:)
        )
        activeRuns[request.runID] = ActiveRun(
            sessionID: request.session.id,
            executionID: nil,
            events: events
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
            try requireAvailableProtocolGeneration(admittedRevision: admittedProtocolRevision)
            if let activeRun = activeRuns[request.runID] {
                if let notificationExecutionID = activeRun.executionID,
                   notificationExecutionID != executionID {
                    let detail = "Codex identified the same started turn as both \(notificationExecutionID) and \(executionID). Codeness stopped the App Server generation instead of attaching this run to an ambiguous execution."
                    executionRuns[executionID] = request.runID
                    _ = await containProtocolGeneration(detail: detail)
                    throw AgentProviderError.invalidResponse(detail)
                }
                activeRun.executionID = executionID
                executionRuns[executionID] = request.runID
            }
            if Task.isCancelled {
                await cancelRun(runID: request.runID)
                throw CancellationError()
            }
            return AgentRunHandle(
                runID: request.runID,
                providerID: id,
                sessionID: request.session.id,
                executionID: executionID,
                events: events.stream(
                    cancelChannelOnConsumerCancellation: true,
                    onConsumerCancellation: { [weak self] in
                        await self?.runEventConsumerCancelled(runID: request.runID)
                    }
                )
            )
        } catch {
            if protocolContainment == nil,
               interruptionDebts[request.runID] == nil {
                await finish(runID: request.runID)
            }
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
        try requireAvailableProtocolGeneration()
        let admittedProtocolRevision = protocolGenerationRevision
        guard let run = activeRuns[runID], let executionID = run.executionID else {
            throw AgentProviderError.missingRun(runID)
        }
        try await appServer.steer(
            threadID: run.sessionID,
            turnID: executionID,
            message: message
        )
        try requireAvailableProtocolGeneration(admittedRevision: admittedProtocolRevision)
    }

    public func interrupt(runID: UUID) async throws {
        try requireAvailableProtocolGeneration()
        let admittedProtocolRevision = protocolGenerationRevision
        guard let run = activeRuns[runID], let executionID = run.executionID else {
            throw AgentProviderError.missingRun(runID)
        }
        guard let target = beginInterruptionRequest(
            runID: runID,
            run: run,
            executionID: executionID,
            protocolRevision: admittedProtocolRevision,
            detail: "Codeness requested interruption and is waiting for Codex to acknowledge the request."
        ) else { return }
        do {
            try await appServer.interrupt(
                threadID: target.sessionID,
                turnID: target.executionID
            )
            try requireAvailableProtocolGeneration(
                admittedRevision: target.protocolGenerationRevision
            )
        } catch {
            await recordInterruptionFailureIfCurrent(
                runID: runID,
                run: run,
                target: target,
                detail: error.localizedDescription
            )
            throw error
        }
        recordInterruptionAcknowledgement(
            runID: runID,
            run: run,
            target: target,
            detail: "Codex acknowledged the interruption request, but Codeness is still waiting for the matching turn/completed notification."
        )
    }

    public func resolveInteraction(
        runID: UUID,
        interactionID: String,
        resolution: AgentInteractionResolution
    ) async throws {
        try requireAvailableProtocolGeneration()
        let admittedProtocolRevision = protocolGenerationRevision
        guard let run = activeRuns[runID],
              !run.isTerminating,
              let pending = run.interactionRequests.removeValue(
                forKey: interactionID
              ) else {
            throw AgentProviderError.missingRun(runID)
        }
        run.claimedInteractionRequests[interactionID] = pending
        let result: JSONValue
        switch resolution {
        case .decision(let value), .raw(let value):
            result = value
        case .answers(let answers):
            result = .object([
                "answers": .object(answers.mapValues { .array($0.map(JSONValue.string)) })
            ])
        case .cancel:
            do {
                try await appServer.respondWithError(
                    to: pending.requestID,
                    message: "The user cancelled this request."
                )
                try requireAvailableProtocolGeneration(
                    admittedRevision: admittedProtocolRevision
                )
                completeInteractionResponse(
                    interactionID: interactionID,
                    run: run
                )
                return
            } catch {
                await failRunAndCancel(
                    runID: runID,
                    run: run,
                    detail: "Could not send the Codex interaction cancellation: \(error.localizedDescription)"
                )
                throw error
            }
        }
        do {
            try await appServer.respond(to: pending.requestID, result: result)
            try requireAvailableProtocolGeneration(
                admittedRevision: admittedProtocolRevision
            )
            completeInteractionResponse(interactionID: interactionID, run: run)
        } catch {
            await failRunAndCancel(
                runID: runID,
                run: run,
                detail: "Could not send the Codex interaction response: \(error.localizedDescription)"
            )
            throw error
        }
    }

    public func runUtility(_ request: AgentUtilityRequest) async throws -> AgentUtilityResult {
        guard request.target.providerID == id else {
            throw AgentProviderError.unsupportedProvider(request.target.providerID)
        }
        try requireAvailableProtocolGeneration()
        let admittedProtocolRevision = protocolGenerationRevision
        let runID = UUID()
        let sessionID: String
        await acquireAdmission()
        do {
            try requireAvailableProtocolGeneration(admittedRevision: admittedProtocolRevision)
            try Task.checkCancellation()
            try await enforceLoadedThreadLimit(reusing: nil, startingUtility: true)
            try requireAvailableProtocolGeneration(admittedRevision: admittedProtocolRevision)
            sessionID = try await appServer.startThread(
                cwd: request.cwd,
                model: request.target.model,
                developerInstructions: request.developerInstructions,
                // Utility threads are persisted only long enough to make
                // thread/delete available; phase sessions remain persistent
                // and are never deleted by this path.
                ephemeral: false,
                readOnly: true,
                approvalPolicy: "never"
            )
            try requireAvailableProtocolGeneration(admittedRevision: admittedProtocolRevision)
            retainedUtilityThreadIDs.insert(sessionID)
            utilityRunSessions[runID] = sessionID
            releaseAdmission()
        } catch {
            releaseAdmission()
            throw error
        }
        let session = AgentSession(providerID: id, id: sessionID, target: request.target)
        var result: Result<AgentUtilityResult, any Error>
        do {
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
            result = await withTaskCancellationHandler {
                await utilityResult(from: handle)
            } onCancel: {
                Task { await self.cancelRun(runID: runID) }
            }
        } catch {
            result = .failure(error)
        }
        let requiresProviderCancellation = Task.isCancelled
            || utilityRunsAwaitingProviderCancellation.contains(runID)
        if requiresProviderCancellation {
            await cancelRun(runID: runID)
        }
        let terminationWasConfirmed = await waitForRunTermination(runID: runID)
        utilityRunsAwaitingProviderCancellation.remove(runID)
        if Task.isCancelled {
            result = .failure(CancellationError())
        }
        if terminationWasConfirmed,
           let retainedSessionID = utilityRunSessions.removeValue(forKey: runID) {
            await releaseUtilityThread(id: retainedSessionID)
        }
        return try result.get()
    }

    @discardableResult
    public func releaseSession(id sessionID: String) async -> Bool {
        guard protocolContainment == nil else { return false }
        let admittedProtocolRevision = protocolGenerationRevision
        if let runID = sessionRuns[sessionID] {
            guard activeRuns[runID]?.isFinishing == true,
                  await waitForRunTermination(runID: runID) else { return false }
        }
        guard protocolContainment == nil,
              protocolGenerationRevision == admittedProtocolRevision else { return false }
        attachedSessionIDs.remove(sessionID)
        let confirmed = await releaseDetachedThread(id: sessionID)
        return confirmed
            && protocolContainment == nil
            && protocolGenerationRevision == admittedProtocolRevision
    }

    private func utilityResult(
        from handle: AgentRunHandle
    ) async -> Result<AgentUtilityResult, any Error> {
        for await event in handle.events {
            if Task.isCancelled {
                return .failure(CancellationError())
            }
            switch event {
            case .completed(let output, _, let usage):
                return .success(AgentUtilityResult(output: output, tokenUsage: usage))
            case .failed(let detail):
                return .failure(AgentProviderError.invalidResponse(detail))
            case .sessionUnavailable(let detail):
                return .failure(AgentProviderError.invalidResponse(detail))
            case .interrupted(let detail):
                return .failure(AgentProviderError.invalidResponse(
                    detail ?? "The coordinator run was interrupted."
                ))
            case .started, .transcript, .diagnostic, .tokenUsage, .interaction,
                 .interactionResolved:
                continue
            }
        }
        if Task.isCancelled {
            return .failure(CancellationError())
        }
        return .failure(AgentProviderError.invalidResponse(
            "the coordinator run ended without a result"
        ))
    }

    private func cancelRun(runID: UUID) async {
        guard protocolContainment == nil else { return }
        if let state = interruptionDebts[runID]?.state,
           state != .requestFailed {
            return
        }
        if let existing = runCancellationTasks[runID] {
            await existing.task.value
            return
        }
        let operationID = UUID()
        guard activeRuns[runID] != nil || utilityRunSessions[runID] != nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performCancellationAttempt(runID: runID)
        }
        runCancellationTasks[runID] = CleanupTask(id: operationID, task: task)
        await task.value
        if runCancellationTasks[runID]?.id == operationID {
            runCancellationTasks.removeValue(forKey: runID)
        }
    }

    private func performCancellationAttempt(runID: UUID) async {
        guard !Task.isCancelled else { return }
        guard let run = activeRuns[runID] else {
            clearInterruptionDebt(runID: runID)
            if let sessionID = utilityRunSessions.removeValue(forKey: runID) {
                await releaseUtilityThread(id: sessionID)
            }
            return
        }
        guard let executionID = run.executionID else {
            await recordInterruptionFailure(
                runID: runID,
                detail: "The Codex turn did not expose an execution identifier before cancellation."
            )
            return
        }
        let admittedProtocolRevision = protocolGenerationRevision
        guard let target = beginInterruptionRequest(
            runID: runID,
            run: run,
            executionID: executionID,
            protocolRevision: admittedProtocolRevision,
            detail: "Codeness requested cancellation and is waiting for Codex to acknowledge the request."
        ) else { return }
        do {
            try await appServer.interrupt(
                threadID: target.sessionID,
                turnID: target.executionID
            )
            try requireAvailableProtocolGeneration(
                admittedRevision: target.protocolGenerationRevision
            )
        } catch {
            if activeRuns[runID] == nil {
                clearInterruptionDebt(runID: runID)
                if let sessionID = utilityRunSessions.removeValue(forKey: runID) {
                    await releaseUtilityThread(id: sessionID)
                }
            } else {
                await recordInterruptionFailureIfCurrent(
                    runID: runID,
                    run: run,
                    target: target,
                    detail: error.localizedDescription
                )
            }
            return
        }
        recordInterruptionAcknowledgement(
            runID: runID,
            run: run,
            target: target,
            detail: "Codex acknowledged cancellation, but Codeness is still waiting for the matching turn/completed notification."
        )
    }

    private func beginInterruptionRequest(
        runID: UUID,
        run: ActiveRun,
        executionID: String,
        protocolRevision: UInt64,
        detail: String
    ) -> InterruptionTarget? {
        guard protocolContainment == nil,
              protocolGenerationRevision == protocolRevision,
              activeRuns[runID] === run else { return nil }
        if let state = interruptionDebts[runID]?.state,
           state != .requestFailed {
            return nil
        }
        let target = InterruptionTarget(
            protocolGenerationRevision: protocolRevision,
            sessionID: run.sessionID,
            executionID: executionID
        )
        interruptionDebts[runID] = CleanupDebt(
            attempts: interruptionDebts[runID]?.attempts ?? 0,
            lastError: detail,
            state: .requestInFlight,
            target: target
        )
        run.isTerminating = true
        runCancellationRetryTasks.removeValue(forKey: runID)?.cancel()
        return target
    }

    private func recordInterruptionFailureIfCurrent(
        runID: UUID,
        run: ActiveRun,
        target: InterruptionTarget,
        detail: String
    ) async {
        guard protocolContainment == nil,
              protocolGenerationRevision == target.protocolGenerationRevision,
              activeRuns[runID] === run,
              interruptionDebts[runID]?.state == .requestInFlight,
              interruptionDebts[runID]?.target == target else { return }
        await recordInterruptionFailure(
            runID: runID,
            target: target,
            detail: detail
        )
    }

    private func recordInterruptionFailure(
        runID: UUID,
        target: InterruptionTarget? = nil,
        detail: String
    ) async {
        let existingDebt = interruptionDebts[runID]
        let attempts = (existingDebt?.attempts ?? 0) + 1
        interruptionDebts[runID] = CleanupDebt(
            attempts: attempts,
            lastError: detail,
            state: .requestFailed,
            target: target ?? existingDebt?.target
        )
        guard attempts < cleanupRetryPolicy.maximumAttemptCount else {
            let attemptLabel = attempts == 1 ? "attempt" : "attempts"
            let containmentDetail = "Codeness could not confirm interruption of a Codex turn after \(attempts) \(attemptLabel): \(detail) Codeness stopped the App Server generation so the turn and its MCP/background processes cannot remain orphaned."
            _ = await containProtocolGeneration(
                detail: containmentDetail,
                excludingRunCancellationTaskFor: runCancellationTasks[runID] == nil
                    ? nil
                    : runID
            )
            return
        }
        guard runCancellationRetryTasks[runID] == nil else { return }
        let delay = cleanupRetryPolicy.delay(
            afterAttempt: attempts,
            resourceKey: runID.uuidString
        )
        runCancellationRetryTasks[runID] = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.retryRunCancellation(runID: runID)
        }
    }

    private func recordInterruptionAcknowledgement(
        runID: UUID,
        run: ActiveRun,
        target: InterruptionTarget,
        detail: String
    ) {
        guard protocolContainment == nil,
              protocolGenerationRevision == target.protocolGenerationRevision,
              activeRuns[runID] === run,
              interruptionDebts[runID]?.state == .requestInFlight,
              interruptionDebts[runID]?.target == target else { return }
        run.isTerminating = true
        let attempts = max(1, interruptionDebts[runID]?.attempts ?? 0)
        interruptionDebts[runID] = CleanupDebt(
            attempts: attempts,
            lastError: detail,
            state: .awaitingTerminal,
            target: target
        )
        runCancellationRetryTasks.removeValue(forKey: runID)?.cancel()
        guard interruptionTerminalTasks[runID] == nil else { return }
        let timeout = interruptionTerminalTimeout
        interruptionTerminalTasks[runID] = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.interruptionTerminalTimedOut(runID: runID)
        }
    }

    private func interruptionTerminalTimedOut(runID: UUID) async {
        interruptionTerminalTasks.removeValue(forKey: runID)
        guard protocolContainment == nil,
              interruptionDebts[runID]?.state == .awaitingTerminal,
              let run = activeRuns[runID] else { return }
        let executionDetail = run.executionID.map { " turn \($0)" } ?? " turn"
        let detail = "Codex acknowledged interruption of\(executionDetail), but did not emit the authoritative turn/completed notification within the bounded wait. Codeness stopped the App Server generation so the turn and its MCP/background processes cannot be orphaned."
        _ = await containProtocolGeneration(detail: detail)
    }

    private func retryRunCancellation(runID: UUID) async {
        runCancellationRetryTasks.removeValue(forKey: runID)
        guard interruptionDebts[runID]?.state == .requestFailed else { return }
        await cancelRun(runID: runID)
    }

    private func clearInterruptionDebt(runID: UUID) {
        interruptionDebts.removeValue(forKey: runID)
        runCancellationRetryTasks.removeValue(forKey: runID)?.cancel()
        interruptionTerminalTasks.removeValue(forKey: runID)?.cancel()
    }

    private func recordAuthoritativeInterruptionTerminal(
        runID: UUID,
        sessionID: String,
        executionID: String
    ) -> Bool {
        guard var debt = interruptionDebts[runID] else { return false }
        if let target = debt.target {
            guard target.protocolGenerationRevision == protocolGenerationRevision,
                  target.sessionID == sessionID,
                  target.executionID == executionID else { return false }
        }
        debt.state = .terminalReceived
        debt.lastError = "Codex emitted the matching turn/completed notification; Codeness is finishing owned thread cleanup."
        interruptionDebts[runID] = debt
        interruptionTerminalTasks.removeValue(forKey: runID)?.cancel()
        return true
    }

    private func waitForRunTermination(runID: UUID) async -> Bool {
        guard activeRuns[runID] != nil else { return true }
        if protocolContainment?.cleanupIsUnconfirmed == true {
            return false
        }
        if let debt = interruptionDebts[runID],
           debt.state == .requestFailed,
           debt.attempts >= cleanupRetryPolicy.maximumAttemptCount,
           runCancellationRetryTasks[runID] == nil {
            return false
        }
        return await withCheckedContinuation { continuation in
            if activeRuns[runID] == nil {
                continuation.resume(returning: true)
            } else if protocolContainment?.cleanupIsUnconfirmed == true {
                continuation.resume(returning: false)
            } else if let debt = interruptionDebts[runID],
                      debt.state == .requestFailed,
                      debt.attempts >= cleanupRetryPolicy.maximumAttemptCount,
                      runCancellationRetryTasks[runID] == nil {
                continuation.resume(returning: false)
            } else {
                runTerminationWaiters[runID, default: []].append(continuation)
            }
        }
    }

    private func resolveRunTerminationWaiters(runID: UUID, confirmed: Bool) {
        let waiters = runTerminationWaiters.removeValue(forKey: runID) ?? []
        waiters.forEach { $0.resume(returning: confirmed) }
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

    public func shutdown() async {
        _ = await shutdownAndVerify()
    }

    @discardableResult
    public func shutdownAndVerify() async -> Bool {
        // Stopping the entire isolated generation is the only shutdown proof
        // that also covers acknowledged-but-not-terminal turns and background
        // terminals. Local bookkeeping is cleared only after that proof.
        guard await appServer.shutdown() else { return false }
        await appServerCleanupConfirmed()
        await performLocalShutdown()
        return true
    }

    private func performLocalShutdown() async {
        guard protocolContainment == nil else { return }
        protocolGenerationRevision &+= 1
        for runID in Array(activeRuns.keys) {
            await finish(
                runID: runID,
                terminalEvent: .failed("Codex stopped.")
            )
        }
        // The whole isolated process generation is already gone. Do not issue
        // thread-scoped cleanup RPCs against a stopped server; process-group
        // termination is the stronger proof that also covers background
        // terminals which are not represented by ordinary turn bookkeeping.
        attachedSessionIDs.removeAll()
        retainedUtilityThreadIDs.removeAll()
        utilityRunSessions.removeAll()
        runCancellationTasks.values.forEach { $0.task.cancel() }
        runCancellationTasks.removeAll()
        runCancellationRetryTasks.values.forEach { $0.cancel() }
        runCancellationRetryTasks.removeAll()
        interruptionTerminalTasks.values.forEach { $0.cancel() }
        interruptionTerminalTasks.removeAll()
        interruptionDebts.removeAll()
        retiredExecutionIDs.removeAll(keepingCapacity: false)
        retiredExecutionIDOrder.removeAll(keepingCapacity: false)
        let terminationWaiters = runTerminationWaiters.values.flatMap { $0 }
        runTerminationWaiters.removeAll()
        terminationWaiters.forEach { $0.resume(returning: true) }
        utilityRunsAwaitingProviderCancellation.removeAll()
        unsubscribeTasks.values.forEach { $0.task.cancel() }
        unsubscribeTasks.removeAll()
        unsubscribeRetryTasks.values.forEach { $0.cancel() }
        unsubscribeRetryTasks.removeAll()
        unsubscribeDebts.removeAll()
        deleteTasks.values.forEach { $0.task.cancel() }
        deleteTasks.removeAll()
        deleteRetryTasks.values.forEach { $0.cancel() }
        deleteRetryTasks.removeAll()
        deleteDebts.removeAll()
    }

    /// A suppressed transport exit still constitutes a definitive generation
    /// boundary when the caller has observed `CodexAppServerClient.shutdown()`
    /// return true. Keep this explicit so no ordinary turn terminal can unlock
    /// protocol containment.
    public func appServerCleanupConfirmed() async {
        guard protocolContainment != nil else { return }
        protocolContainment = nil
        protocolGenerationRevision &+= 1
        attachedSessionIDs.removeAll()
        runCancellationTasks.values.forEach { $0.task.cancel() }
        runCancellationTasks.removeAll()
        runCancellationRetryTasks.values.forEach { $0.cancel() }
        runCancellationRetryTasks.removeAll()
        for runID in Array(activeRuns.keys) {
            clearInterruptionDebt(runID: runID)
            await finish(
                runID: runID,
                terminalEvent: .failed("Codex App Server stopped.")
            )
        }
        retiredExecutionIDs.removeAll(keepingCapacity: false)
        retiredExecutionIDOrder.removeAll(keepingCapacity: false)
    }

    public func receive(_ event: AppServerEvent) async {
        if protocolContainment != nil {
            switch event {
            case .exited:
                // Process exit is definitive containment. No turn-scoped event,
                // including a plausible terminal for either ambiguous ID, may
                // clear this generation-wide gate.
                break
            case .standardError, .request, .notification:
                return
            }
        }
        switch event {
        case .standardError:
            return
        case .exited(let termination):
            let containedProtocolGeneration = protocolContainment != nil
            await appServerCleanupConfirmed()
            if !containedProtocolGeneration {
                protocolGenerationRevision &+= 1
            }
            attachedSessionIDs.removeAll()
            retainedUtilityThreadIDs.formUnion(utilityRunSessions.values)
            deleteTasks.values.forEach { $0.task.cancel() }
            deleteTasks.removeAll()
            deleteRetryTasks.values.forEach { $0.cancel() }
            deleteRetryTasks.removeAll()
            for sessionID in retainedUtilityThreadIDs {
                recordDeleteFailure(
                    sessionID: sessionID,
                    detail: termination.userFacingDescription(subject: "Codex App Server")
                )
            }
            utilityRunSessions.removeAll()
            runCancellationTasks.values.forEach { $0.task.cancel() }
            runCancellationTasks.removeAll()
            runCancellationRetryTasks.values.forEach { $0.cancel() }
            runCancellationRetryTasks.removeAll()
            interruptionTerminalTasks.values.forEach { $0.cancel() }
            interruptionTerminalTasks.removeAll()
            interruptionDebts.removeAll()
            let terminationWaiters = runTerminationWaiters.values.flatMap { $0 }
            runTerminationWaiters.removeAll()
            terminationWaiters.forEach { $0.resume(returning: true) }
            utilityRunsAwaitingProviderCancellation.removeAll()
            unsubscribeTasks.values.forEach { $0.task.cancel() }
            unsubscribeTasks.removeAll()
            unsubscribeRetryTasks.values.forEach { $0.cancel() }
            unsubscribeRetryTasks.removeAll()
            unsubscribeDebts.removeAll()
            let runIDs = Array(activeRuns.keys)
            for runID in runIDs {
                await finish(
                    runID: runID,
                    terminalEvent: .failed(
                        termination.userFacingDescription(subject: "Codex App Server")
                    )
                )
            }
            retiredExecutionIDs.removeAll(keepingCapacity: false)
            retiredExecutionIDOrder.removeAll(keepingCapacity: false)
        case .request(let requestID, let method, let params, _):
            guard let runID = runID(for: event),
                  let run = activeRuns[runID],
                  !run.isTerminating else { return }
            if let response = Self.automaticResponse(method: method, params: params) {
                do {
                    try await appServer.respond(to: requestID, result: response)
                } catch {
                    await failRunAndCancel(
                        runID: runID,
                        run: run,
                        detail: "Could not automatically approve the Codex MCP tool call: \(error.localizedDescription)"
                    )
                }
                return
            }
            if utilityRunSessions[runID] != nil {
                await failRunAndCancel(
                    runID: runID,
                    run: run,
                    detail: "Codex requested user interaction during an unattended coordinator run. Codeness cancelled the temporary turn instead of waiting for a dialog that cannot be presented."
                )
                return
            }
            let interactionID = requestID.encodedString()
            guard run.interactionRequests[interactionID] == nil,
                  run.claimedInteractionRequests[interactionID] == nil,
                  requestRuns[interactionID] == nil else {
                await failRunAndCancel(
                    runID: runID,
                    run: run,
                    detail: "Codex reused an unresolved interaction identifier. Codeness cancelled the turn instead of allowing a hidden request to replace the visible request."
                )
                return
            }
            var retainedByteCount = Self.saturatingSum(
                interactionID.utf8.count,
                method.utf8.count
            )
            retainedByteCount = Self.saturatingSum(
                retainedByteCount,
                Self.retainedCost(of: requestID)
            )
            retainedByteCount = Self.saturatingSum(
                retainedByteCount,
                Self.retainedCost(of: params)
            )
            guard run.interactionRequests.count + run.claimedInteractionRequests.count
                    < Self.maximumPendingInteractionCount,
                  retainedByteCount <= Self.maximumPendingInteractionRetainedBytes,
                  run.interactionRetainedByteCount
                    <= Self.maximumPendingInteractionRetainedBytes - retainedByteCount else {
                await failRunAndCancel(
                    runID: runID,
                    run: run,
                    detail: "Codex accumulated too many unresolved interactions. Codeness cancelled the turn to prevent unbounded memory growth."
                )
                return
            }
            run.interactionRequests[interactionID] = PendingInteractionRequest(
                requestID: requestID,
                retainedByteCount: retainedByteCount
            )
            run.interactionRetainedByteCount += retainedByteCount
            requestRuns[interactionID] = runID
            guard await admit(
                .interaction(Self.interaction(
                    id: interactionID,
                    method: method,
                    params: params
                )),
                to: run,
                runID: runID
            ) else { return }
        case .notification(let method, let params, _):
            if method == "turn/started",
               await terminateGenerationForUnexpectedStartedIdentityIfNeeded(
                    event: event
               ) {
                return
            }
            if method == "thread/closed", let sessionID = params["threadId"]?.stringValue {
                let unresolvedCancellationRunIDs: [UUID] = activeRuns.compactMap {
                    runID, run -> UUID? in
                    guard run.sessionID == sessionID,
                          let debt = interruptionDebts[runID],
                          debt.state != .terminalReceived else { return nil }
                    if let target = debt.target,
                       target.protocolGenerationRevision != protocolGenerationRevision
                            || target.sessionID != sessionID {
                        return nil
                    }
                    return runID
                }
                if !unresolvedCancellationRunIDs.isEmpty {
                    let detail = "Codex closed thread \(sessionID) while cancellation was unresolved and did not emit the matching turn/completed notification. Codeness stopped the App Server generation because thread closure alone cannot prove the interrupted turn and its background processes ended."
                    _ = await containProtocolGeneration(detail: detail)
                    return
                }
                let terminalReceivedRunIDs: [UUID] = activeRuns.compactMap {
                    runID, run -> UUID? in
                    run.sessionID == sessionID
                        && interruptionDebts[runID]?.state == .terminalReceived
                        ? runID
                        : nil
                }
                if !terminalReceivedRunIDs.isEmpty {
                    // The matching terminal already won the race. Let its
                    // in-flight cleanup/finish path publish that authoritative
                    // outcome instead of replacing it with sessionUnavailable.
                    attachedSessionIDs.remove(sessionID)
                    await cancelPendingUnsubscribe(for: sessionID)
                    return
                }
                attachedSessionIDs.remove(sessionID)
                await cancelPendingUnsubscribe(for: sessionID)
                let closedRunIDs = activeRuns.compactMap { runID, run in
                    run.sessionID == sessionID ? runID : nil
                }
                for runID in closedRunIDs {
                    let utilitySessionID = utilityRunSessions.removeValue(forKey: runID)
                    await finish(
                        runID: runID,
                        terminalEvent: .sessionUnavailable(
                            "Codex closed the active thread unexpectedly."
                        )
                    )
                    if let utilitySessionID {
                        await releaseUtilityThread(id: utilitySessionID)
                    }
                }
                return
            }
            if method == "serverRequest/resolved",
               let requestID = params["requestId"] {
                let interactionID = requestID.encodedString()
                if let runID = requestRuns[interactionID],
                   let run = activeRuns[runID],
                   !run.isTerminating {
                    if let removed = run.interactionRequests.removeValue(
                        forKey: interactionID
                    ) {
                        requestRuns.removeValue(forKey: interactionID)
                        run.interactionRetainedByteCount -= removed.retainedByteCount
                        guard await admit(
                            .interactionResolved(interactionID),
                            to: run,
                            runID: runID
                        ) else { return }
                    }
                }
                return
            }
            guard let runID = runID(for: event), let run = activeRuns[runID] else { return }
            if run.isTerminating, method != "turn/completed" {
                return
            }
            if method == "turn/started", let executionID = params["turn"]?["id"]?.stringValue {
                run.executionID = executionID
                executionRuns[executionID] = runID
                guard await admit(
                    .started(executionID: executionID),
                    to: run,
                    runID: runID
                ) else { return }
                guard activeRuns[runID] === run else { return }
            }

            if method == "thread/tokenUsage/updated",
               let usage = params["tokenUsage"],
               let total = RunTokenUsage(appServerValue: usage["total"]),
               let last = RunTokenUsage(appServerValue: usage["last"]) {
                let baseline = run.tokenUsageBaseline ?? total.subtracting(last)
                let current = total.subtracting(baseline)
                run.tokenUsageBaseline = baseline
                run.latestUsage = current
                guard await admit(.tokenUsage(current), to: run, runID: runID) else {
                    return
                }
                guard activeRuns[runID] === run else { return }
            }

            let update = TranscriptFormatter.update(
                method: method,
                params: params,
                itemsWithDeltas: run.itemsWithDeltas
            )
            if let itemID = update.itemID,
               method.hasSuffix("/delta") || method.hasSuffix("Delta") {
                if !run.itemsWithDeltas.contains(itemID) {
                    let retainedByteCount = itemID.utf8.count
                    guard run.itemsWithDeltas.count < Self.maximumDeltaItemCount,
                          retainedByteCount <= Self.maximumDeltaItemRetainedBytes,
                          run.deltaItemRetainedByteCount
                            <= Self.maximumDeltaItemRetainedBytes - retainedByteCount else {
                        await failRunAndCancel(
                            runID: runID,
                            run: run,
                            detail: "Codex emitted deltas for too many unfinished items. Codeness cancelled the turn to prevent unbounded memory growth."
                        )
                        return
                    }
                    run.itemsWithDeltas.insert(itemID)
                    run.deltaItemRetainedByteCount += retainedByteCount
                }
            }
            if method == "item/completed", let itemID = update.itemID {
                if run.itemsWithDeltas.remove(itemID) != nil {
                    run.deltaItemRetainedByteCount -= itemID.utf8.count
                }
            }
            if !update.text.isEmpty {
                guard await admit(
                    .transcript(RunTranscriptPresentation.storedText(for: update)),
                    to: run,
                    runID: runID
                ) else { return }
                guard activeRuns[runID] === run else { return }
            }
            if let finalOutput = update.finalOutput, !finalOutput.isEmpty {
                run.finalOutput = finalOutput
            }

            if method == "turn/completed" {
                let turn = params["turn"] ?? .null
                let output = TranscriptFormatter.finalOutput(from: turn) ?? run.finalOutput
                let status = turn["status"]?.stringValue ?? "failed"
                let duration = turn["durationMs"]?.integerValue
                let terminalEvent: AgentEvent
                if status == "completed", let output, !output.isEmpty {
                    run.finalOutput = output
                    terminalEvent = .completed(
                        output: output,
                        durationMilliseconds: duration,
                        tokenUsage: run.latestUsage
                    )
                } else if status == "interrupted" {
                    terminalEvent = .interrupted(nil)
                } else {
                    let error = turn["error"]
                    let message = error?["message"]?.stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let additionalDetails = error?["additionalDetails"]?.stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let details = [message, additionalDetails]
                        .compactMap { detail in
                            guard let detail, !detail.isEmpty else { return nil }
                            return detail
                        }
                        .joined(separator: " ")
                    terminalEvent = .failed(
                        details.isEmpty
                            ? "Codex turn ended with status \(status)."
                            : "Codex turn ended with status \(status): \(details)"
                    )
                }
                let wasCancelling = interruptionDebts[runID] != nil
                let cancelledUtilitySession = wasCancelling
                    ? utilityRunSessions[runID]
                    : nil
                if wasCancelling {
                    // Cancel the ACK watchdog before any cleanup await. The
                    // terminal is now authoritative, while ownership remains
                    // represented by `terminalReceived` until cleanup settles.
                    guard let terminalExecutionID = turn["id"]?.stringValue,
                          recordAuthoritativeInterruptionTerminal(
                            runID: runID,
                            sessionID: run.sessionID,
                            executionID: terminalExecutionID
                          ) else {
                        let detail = "Codex emitted a turn/completed notification that did not match the exact generation, thread, and turn awaiting cancellation. Codeness stopped the App Server generation instead of releasing ambiguous interruption ownership."
                        _ = await containProtocolGeneration(detail: detail)
                        return
                    }
                }
                // The exact terminal authorizes cleanup; it does not itself
                // prove that a temporary thread's background terminals were
                // removed. Keep the run and cancellation debt owned until that
                // cleanup (or generation-wide containment) completes so later
                // admission cannot race ahead and accumulate terminal processes.
                if let cancelledUtilitySession {
                    await releaseUtilityThread(id: cancelledUtilitySession)
                    utilityRunSessions.removeValue(forKey: runID)
                }
                await finish(runID: runID, terminalEvent: terminalEvent)
                if wasCancelling {
                    clearInterruptionDebt(runID: runID)
                }
            }
        }
    }

    private func runID(for event: AppServerEvent) -> UUID? {
        if let executionID = event.turnID {
            if let runID = executionRuns[executionID] {
                return runID
            }
            guard !retiredExecutionIDs.contains(executionID) else {
                return nil
            }
            // turn/started can arrive before the turn/start response registers
            // the execution ID. Every later turn-scoped event must match its
            // exact execution; otherwise a delayed terminal from turn A could
            // finish turn B on the same persistent phase session.
            guard case .notification(let method, _, _) = event,
                  method == "turn/started" else {
                return nil
            }
            guard let sessionID = event.threadID,
                  let runID = sessionRuns[sessionID],
                  activeRuns[runID]?.executionID == nil else {
                return nil
            }
            return runID
        }
        if let sessionID = event.threadID {
            return sessionRuns[sessionID]
        }
        return nil
    }

    private func terminateGenerationForUnexpectedStartedIdentityIfNeeded(
        event: AppServerEvent
    ) async -> Bool {
        guard let sessionID = event.threadID,
              let incomingExecutionID = event.turnID,
              !retiredExecutionIDs.contains(incomingExecutionID),
              let runID = sessionRuns[sessionID],
              let run = activeRuns[runID],
              let currentExecutionID = run.executionID,
              currentExecutionID != incomingExecutionID else {
            return false
        }
        let detail = "Codex identified the active turn as both \(currentExecutionID) and \(incomingExecutionID). Codeness stopped the App Server generation instead of attaching this run to an ambiguous execution."
        executionRuns[incomingExecutionID] = runID
        _ = await containProtocolGeneration(detail: detail)
        return true
    }

    /// Atomically fences the entire App Server generation before process cleanup
    /// can suspend this actor. Turn identity is no longer trustworthy after this
    /// point, so a terminal for either candidate ID cannot release the fence.
    private func containProtocolGeneration(
        detail: String,
        excludingRunCancellationTaskFor excludedRunID: UUID? = nil
    ) async -> Bool {
        if protocolContainment != nil { return false }

        let containmentID = UUID()
        protocolGenerationRevision &+= 1
        protocolContainment = ProtocolContainment(
            id: containmentID,
            detail: detail,
            cleanupIsUnconfirmed: false
        )
        let containedRuns = activeRuns
        for run in containedRuns.values {
            run.isTerminating = true
        }
        runCancellationTasks.forEach { runID, operation in
            if runID != excludedRunID {
                operation.task.cancel()
            }
        }
        runCancellationTasks.removeAll()
        runCancellationRetryTasks.values.forEach { $0.cancel() }
        runCancellationRetryTasks.removeAll()
        interruptionTerminalTasks.values.forEach { $0.cancel() }
        interruptionTerminalTasks.removeAll()
        unsubscribeTasks.values.forEach { $0.task.cancel() }
        unsubscribeTasks.removeAll()
        unsubscribeRetryTasks.values.forEach { $0.cancel() }
        unsubscribeRetryTasks.removeAll()
        deleteTasks.values.forEach { $0.task.cancel() }
        deleteTasks.removeAll()
        deleteRetryTasks.values.forEach { $0.cancel() }
        deleteRetryTasks.removeAll()

        // Close every consumer only after the generation gate is visible. The
        // channel hop can re-enter this actor, but all incoming protocol work is
        // already fenced above.
        for run in containedRuns.values {
            _ = await run.events.finish(with: .failed(detail))
        }
        guard protocolContainment?.id == containmentID else {
            return true
        }

        let containmentConfirmed = await appServer
            .terminateGenerationForProtocolViolation(detail)
        guard protocolContainment?.id == containmentID else {
            // An .exited event confirmed cleanup while the transport call was
            // suspended and performed the ordinary generation teardown.
            return true
        }
        guard containmentConfirmed else {
            let unresolvedDetail = "\(detail) Codeness could not confirm that the isolated App Server process scope terminated, so it will not admit replacement work or detach its sessions."
            protocolContainment?.detail = unresolvedDetail
            protocolContainment?.cleanupIsUnconfirmed = true
            for runID in activeRuns.keys {
                resolveRunTerminationWaiters(runID: runID, confirmed: false)
            }
            return false
        }

        protocolContainment = nil
        attachedSessionIDs.removeAll()
        for runID in Array(activeRuns.keys) {
            clearInterruptionDebt(runID: runID)
            await finish(runID: runID)
        }
        retiredExecutionIDs.removeAll(keepingCapacity: false)
        retiredExecutionIDOrder.removeAll(keepingCapacity: false)
        return true
    }

    private func admit(
        _ event: AgentEvent,
        to run: ActiveRun,
        runID: UUID,
        isTerminal: Bool = false
    ) async -> Bool {
        switch await run.events.trySend(event) {
        case .accepted:
            return true
        case .terminated:
            if isTerminal {
                return true
            }
            run.isTerminating = true
            markUtilityRunAsAwaitingProviderCancellation(runID: runID)
            scheduleRunCancellation(runID: runID)
            return false
        case .full:
            let detail = isTerminal
                ? "Codex ended the turn, but Codeness could not retain its final event because this run's event consumer stopped draining. Codeness discarded no already-admitted output and closed the local run to prevent unbounded memory growth."
                : "Codex produced more run output than Codeness could retain because this run's event consumer stopped draining. Codeness cancelled the turn to prevent unbounded memory growth."
            _ = await run.events.finish(with: .failed(detail))
            if isTerminal {
                return true
            } else {
                run.isTerminating = true
                markUtilityRunAsAwaitingProviderCancellation(runID: runID)
                scheduleRunCancellation(runID: runID)
                return false
            }
        }
    }

    private func failRunAndCancel(
        runID: UUID,
        run: ActiveRun,
        detail: String
    ) async {
        // Keep unresolved and claimed request identifiers owned until the server
        // confirms turn termination and `finish` removes the run. Otherwise a
        // repeated request arriving during cancellation could be staged against
        // an event channel that has already been closed.
        run.isTerminating = true
        _ = await run.events.finish(with: .failed(detail))
        markUtilityRunAsAwaitingProviderCancellation(runID: runID)
        scheduleRunCancellation(runID: runID)
    }

    private func clearPendingInteractions(run: ActiveRun) {
        for interactionID in run.interactionRequests.keys {
            requestRuns.removeValue(forKey: interactionID)
        }
        for interactionID in run.claimedInteractionRequests.keys {
            requestRuns.removeValue(forKey: interactionID)
        }
        run.interactionRequests.removeAll(keepingCapacity: false)
        run.claimedInteractionRequests.removeAll(keepingCapacity: false)
        run.interactionRetainedByteCount = 0
    }

    private func completeInteractionResponse(
        interactionID: String,
        run: ActiveRun
    ) {
        guard let removed = run.claimedInteractionRequests.removeValue(
            forKey: interactionID
        ) else { return }
        requestRuns.removeValue(forKey: interactionID)
        run.interactionRetainedByteCount -= removed.retainedByteCount
    }

    private func markUtilityRunAsAwaitingProviderCancellation(runID: UUID) {
        guard utilityRunSessions[runID] != nil else { return }
        utilityRunsAwaitingProviderCancellation.insert(runID)
    }

    private func scheduleRunCancellation(runID: UUID) {
        Task { [weak self] in
            await self?.cancelRun(runID: runID)
        }
    }

    private func runEventConsumerCancelled(runID: UUID) async {
        guard activeRuns[runID] != nil else { return }
        markUtilityRunAsAwaitingProviderCancellation(runID: runID)
        await cancelRun(runID: runID)
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

    private func finish(
        runID: UUID,
        terminalEvent: AgentEvent? = nil
    ) async {
        // Only confirmed generation cleanup (or .exited/shutdown, which clears
        // the gate first) may release ownership after ambiguous turn identity.
        guard protocolContainment == nil else { return }
        guard let run = activeRuns[runID] else { return }
        if run.isFinishing {
            _ = await waitForRunTermination(runID: runID)
            return
        }
        run.isFinishing = true
        run.isTerminating = true
        if let terminalEvent {
            if !(await run.events.finish(with: terminalEvent)) {
                _ = await run.events.finish(with: .failed(
                    "Codex ended the turn, but its final event exceeded Codeness's bounded event limit."
                ))
            }
        } else {
            await run.events.finish()
        }
        guard let removedRun = activeRuns.removeValue(forKey: runID),
              removedRun === run else { return }
        if sessionRuns[run.sessionID] == runID {
            sessionRuns.removeValue(forKey: run.sessionID)
        }
        let mappedExecutionIDs = executionRuns.compactMap { executionID, mappedRunID in
            mappedRunID == runID ? executionID : nil
        }
        for executionID in mappedExecutionIDs {
            executionRuns.removeValue(forKey: executionID)
            retireExecutionID(executionID)
        }
        clearPendingInteractions(run: run)
        run.itemsWithDeltas.removeAll(keepingCapacity: false)
        run.deltaItemRetainedByteCount = 0
        resolveRunTerminationWaiters(runID: runID, confirmed: true)
    }

    private func retireExecutionID(_ executionID: String) {
        guard retiredExecutionIDs.insert(executionID).inserted else { return }
        retiredExecutionIDOrder.append(executionID)
        let overflow = retiredExecutionIDOrder.count - Self.maximumRetiredExecutionIDCount
        guard overflow > 0 else { return }
        for retiredID in retiredExecutionIDOrder.prefix(overflow) {
            retiredExecutionIDs.remove(retiredID)
        }
        retiredExecutionIDOrder.removeFirst(overflow)
    }

    func cleanupDebtSnapshot() -> CodexProviderCleanupDebtSnapshot {
        CodexProviderCleanupDebtSnapshot(
            interruptedRuns: interruptionDebts.mapValues(\.lastError),
            deleteThreads: deleteDebts.mapValues(\.lastError),
            unsubscribeThreads: unsubscribeDebts.mapValues(\.lastError),
            protocolContainment: protocolContainment?.detail
        )
    }

    func runEventSnapshot(runID: UUID) -> CodexProviderRunEventSnapshot? {
        guard let run = activeRuns[runID] else { return nil }
        return CodexProviderRunEventSnapshot(
            itemsWithDeltas: run.itemsWithDeltas,
            finalOutput: run.finalOutput
        )
    }

    private func acquireAdmission() async {
        if !admissionLocked {
            admissionLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            admissionWaiters.append(continuation)
        }
    }

    private func releaseAdmission() {
        guard !admissionWaiters.isEmpty else {
            admissionLocked = false
            return
        }
        admissionWaiters.removeFirst().resume()
    }

    private func releaseUtilityThread(id sessionID: String) async {
        guard protocolContainment == nil else { return }
        let deleted = await deleteUtilityThread(id: sessionID)
        guard protocolContainment == nil else { return }
        guard !deleted else { return }
        // A failed hard delete must not leave the thread loaded while retries
        // continue. Unsubscribe is a fail-safe, not proof of deletion.
        _ = await releaseDetachedThread(id: sessionID)
    }

    @discardableResult
    private func deleteUtilityThread(id sessionID: String) async -> Bool {
        guard protocolContainment == nil else { return false }
        if let existing = deleteTasks[sessionID] {
            return await existing.task.value
        }
        let operationID = UUID()
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performDeleteAttempt(sessionID: sessionID)
        }
        deleteTasks[sessionID] = UnsubscribeTask(id: operationID, task: task)
        let confirmed = await task.value
        if deleteTasks[sessionID]?.id == operationID {
            deleteTasks.removeValue(forKey: sessionID)
        }
        return confirmed
    }

    private func performDeleteAttempt(sessionID: String) async -> Bool {
        switch await prepareThreadForRelease(sessionID: sessionID) {
        case .ready:
            break
        case .generationContained:
            clearDeleteDebt(sessionID: sessionID)
            retainedUtilityThreadIDs.remove(sessionID)
            await cancelPendingUnsubscribe(for: sessionID)
            return true
        case .cleanupUnconfirmed:
            return false
        }
        do {
            try await appServer.deleteThread(id: sessionID)
            guard protocolContainment == nil else { return false }
            clearDeleteDebt(sessionID: sessionID)
            retainedUtilityThreadIDs.remove(sessionID)
            await cancelPendingUnsubscribe(for: sessionID)
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            guard protocolContainment == nil else { return false }
            recordDeleteFailure(
                sessionID: sessionID,
                detail: error.localizedDescription
            )
            return false
        }
    }

    private func recordDeleteFailure(sessionID: String, detail: String) {
        let attempts = (deleteDebts[sessionID]?.attempts ?? 0) + 1
        deleteDebts[sessionID] = CleanupDebt(
            attempts: attempts,
            lastError: detail,
            state: .requestFailed
        )
        guard attempts < cleanupRetryPolicy.maximumAttemptCount,
              deleteRetryTasks[sessionID] == nil else { return }
        let delay = cleanupRetryPolicy.delay(
            afterAttempt: attempts,
            resourceKey: "delete:\(sessionID)"
        )
        deleteRetryTasks[sessionID] = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.retryDelete(sessionID: sessionID)
        }
    }

    private func retryDelete(sessionID: String) async {
        deleteRetryTasks.removeValue(forKey: sessionID)
        guard deleteDebts[sessionID] != nil else { return }
        let deleted = await deleteUtilityThread(id: sessionID)
        if !deleted {
            _ = await releaseDetachedThread(id: sessionID)
        }
    }

    private func clearDeleteDebt(sessionID: String) {
        deleteDebts.removeValue(forKey: sessionID)
        deleteRetryTasks.removeValue(forKey: sessionID)?.cancel()
    }

    @discardableResult
    private func releaseDetachedThread(id sessionID: String) async -> Bool {
        guard protocolContainment == nil else { return false }
        if let existing = unsubscribeTasks[sessionID] {
            return await existing.task.value
        }
        let operationID = UUID()
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performUnsubscribeAttempt(sessionID: sessionID)
        }
        unsubscribeTasks[sessionID] = UnsubscribeTask(id: operationID, task: task)
        let confirmed = await task.value
        if unsubscribeTasks[sessionID]?.id == operationID {
            unsubscribeTasks.removeValue(forKey: sessionID)
        }
        return confirmed
    }

    private func performUnsubscribeAttempt(sessionID: String) async -> Bool {
        switch await prepareThreadForRelease(sessionID: sessionID) {
        case .ready:
            break
        case .generationContained:
            clearUnsubscribeDebt(sessionID: sessionID)
            retainedUtilityThreadIDs.remove(sessionID)
            return true
        case .cleanupUnconfirmed:
            return false
        }
        do {
            let status = try await appServer.unsubscribeThread(id: sessionID)
            guard protocolContainment == nil else { return false }
            switch status {
            case "unsubscribed", "notSubscribed", "notLoaded":
                clearUnsubscribeDebt(sessionID: sessionID)
            default:
                recordUnsubscribeFailure(
                    sessionID: sessionID,
                    detail: "Codex returned unsupported unsubscribe status \(status)."
                )
                return false
            }
            if status == "notLoaded" {
                retainedUtilityThreadIDs.remove(sessionID)
            }
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            guard protocolContainment == nil else { return false }
            recordUnsubscribeFailure(
                sessionID: sessionID,
                detail: error.localizedDescription
            )
            return false
        }
    }

    /// An App Server turn terminal does not imply that terminal processes
    /// launched in the background have exited. A thread may only be detached or
    /// deleted after the experimental cleanup request is followed by an
    /// authoritative empty list. If that proof cannot be obtained, stop the
    /// entire isolated generation before releasing any ownership.
    private func prepareThreadForRelease(
        sessionID: String
    ) async -> ThreadReleaseReadiness {
        do {
            let loadedThreadIDs = try await appServer.loadedThreadIDs()
            guard protocolContainment == nil else { return .cleanupUnconfirmed }
            guard loadedThreadIDs.contains(sessionID) else { return .ready }

            try await appServer.cleanBackgroundTerminals(threadID: sessionID)
            guard protocolContainment == nil else { return .cleanupUnconfirmed }

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: backgroundTerminalCleanupTimeout)
            var remaining = try await appServer.backgroundTerminalIDs(
                threadID: sessionID
            )
            while !remaining.isEmpty, clock.now < deadline {
                do {
                    try await Task.sleep(for: .milliseconds(25))
                } catch {
                    guard protocolContainment == nil else {
                        return .cleanupUnconfirmed
                    }
                    throw error
                }
                remaining = try await appServer.backgroundTerminalIDs(
                    threadID: sessionID
                )
            }
            guard remaining.isEmpty else {
                let sample = remaining.sorted().prefix(8).joined(separator: ", ")
                return await containGenerationForBackgroundTerminalCleanupFailure(
                    sessionID: sessionID,
                    detail: "Codex still reported \(remaining.count) background terminal process(es) after cleanup (sample: \(sample))."
                )
            }
            return .ready
        } catch {
            guard protocolContainment == nil else { return .cleanupUnconfirmed }
            return await containGenerationForBackgroundTerminalCleanupFailure(
                sessionID: sessionID,
                detail: "Codeness could not clean and verify the thread's background terminals: \(error.localizedDescription)"
            )
        }
    }

    private func containGenerationForBackgroundTerminalCleanupFailure(
        sessionID: String,
        detail: String
    ) async -> ThreadReleaseReadiness {
        let contained = await containProtocolGeneration(
            detail: "Before releasing Codex thread \(sessionID), \(detail) Codeness stopped the App Server generation so no terminal process could be orphaned."
        )
        return contained ? .generationContained : .cleanupUnconfirmed
    }

    private func recordUnsubscribeFailure(sessionID: String, detail: String) {
        let attempts = (unsubscribeDebts[sessionID]?.attempts ?? 0) + 1
        unsubscribeDebts[sessionID] = CleanupDebt(
            attempts: attempts,
            lastError: detail,
            state: .requestFailed
        )
        guard attempts < cleanupRetryPolicy.maximumAttemptCount,
              unsubscribeRetryTasks[sessionID] == nil else { return }
        let delay = cleanupRetryPolicy.delay(
            afterAttempt: attempts,
            resourceKey: sessionID
        )
        unsubscribeRetryTasks[sessionID] = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.retryUnsubscribe(sessionID: sessionID)
        }
    }

    private func retryUnsubscribe(sessionID: String) async {
        unsubscribeRetryTasks.removeValue(forKey: sessionID)
        guard unsubscribeDebts[sessionID] != nil else { return }
        await releaseDetachedThread(id: sessionID)
    }

    private func clearUnsubscribeDebt(sessionID: String) {
        unsubscribeDebts.removeValue(forKey: sessionID)
        unsubscribeRetryTasks.removeValue(forKey: sessionID)?.cancel()
    }

    private func cancelPendingUnsubscribe(for sessionID: String) async {
        clearUnsubscribeDebt(sessionID: sessionID)
        guard let operation = unsubscribeTasks.removeValue(forKey: sessionID) else { return }
        operation.task.cancel()
        _ = await operation.task.value
        clearUnsubscribeDebt(sessionID: sessionID)
    }

    private func enforceLoadedThreadLimit(
        reusing sessionID: String?,
        startingUtility: Bool = false
    ) async throws {
        try requireAvailableProtocolGeneration()
        let exhaustedInterruptionDebt = interruptionDebts.keys
            .filter {
                runCancellationTasks[$0] == nil
                    && runCancellationRetryTasks[$0] == nil
            }
            .sorted { $0.uuidString < $1.uuidString }
        for runID in exhaustedInterruptionDebt {
            await cancelRun(runID: runID)
            if let state = interruptionDebts[runID]?.state,
               state != .requestFailed {
                _ = await waitForRunTermination(runID: runID)
            }
            try requireAvailableProtocolGeneration()
        }
        let unresolvedInterruptionCount = interruptionDebts.keys.filter {
            activeRuns[$0] != nil
        }.count
        if unresolvedInterruptionCount > 0 {
            throw AgentProviderError.resourceLimit(
                "Codex still has \(unresolvedInterruptionCount) cancelled turn(s) whose interruption could not be confirmed. Codeness stopped before admitting more work to prevent stranded MCP processes. Retry after Codex recovers or restart Codex App Server."
            )
        }

        var loaded: Set<String>
        do {
            loaded = try await appServer.loadedThreadIDs()
            try requireAvailableProtocolGeneration()
        } catch {
            if protocolContainment != nil {
                try requireAvailableProtocolGeneration()
            }
            throw AgentProviderError.resourceLimit(
                "Codeness could not verify Codex's loaded-thread count, so it stopped before admitting another thread: \(error.localizedDescription)"
            )
        }
        let quiescentDeleteDebt = deleteDebts.keys
            .filter {
                deleteTasks[$0] == nil && deleteRetryTasks[$0] == nil
            }
            .sorted()
        for debtSessionID in quiescentDeleteDebt {
            let deleted = await deleteUtilityThread(id: debtSessionID)
            try requireAvailableProtocolGeneration()
            if !deleted {
                _ = await releaseDetachedThread(id: debtSessionID)
                try requireAvailableProtocolGeneration()
            }
        }
        for debtSessionID in Array(unsubscribeDebts.keys) where !loaded.contains(debtSessionID) {
            clearUnsubscribeDebt(sessionID: debtSessionID)
        }
        let quiescentDebt = unsubscribeDebts.keys
            .filter {
                loaded.contains($0)
                    && unsubscribeTasks[$0] == nil
                    && unsubscribeRetryTasks[$0] == nil
            }
            .sorted()
        if !quiescentDebt.isEmpty {
            for debtSessionID in quiescentDebt {
                await releaseDetachedThread(id: debtSessionID)
                try requireAvailableProtocolGeneration()
            }
            do {
                loaded = try await appServer.loadedThreadIDs()
                try requireAvailableProtocolGeneration()
            } catch {
                if protocolContainment != nil {
                    try requireAvailableProtocolGeneration()
                }
                throw AgentProviderError.resourceLimit(
                    "Codeness retried pending Codex cleanup but could not refresh the loaded-thread count, so it stopped before admitting another thread: \(error.localizedDescription)"
                )
            }
            for debtSessionID in Array(unsubscribeDebts.keys) where !loaded.contains(debtSessionID) {
                clearUnsubscribeDebt(sessionID: debtSessionID)
            }
        }
        let effectivelyLoaded = loaded
            .union(attachedSessionIDs)
            .union(retainedUtilityThreadIDs)
        if effectivelyLoaded.count >= maximumLoadedThreadCount,
           sessionID.map(effectivelyLoaded.contains) != true {
            throw AgentProviderError.resourceLimit(
                "Codex has \(effectivelyLoaded.count) loaded or reserved threads. Codeness stopped before starting another thread to prevent unbounded MCP resource growth. Wait for idle threads to unload or restart Codex App Server."
            )
        }
        if startingUtility,
           retainedUtilityThreadIDs.count >= maximumRetainedUtilityThreadCount {
            throw AgentProviderError.resourceLimit(
                "Codex is still retaining \(retainedUtilityThreadIDs.count) completed coordinator threads. Codeness stopped before creating another MCP process set. Wait for idle threads to unload or restart Codex App Server."
            )
        }
    }

    private func requireAvailableProtocolGeneration(
        admittedRevision: UInt64? = nil
    ) throws {
        if let containment = protocolContainment {
            throw AgentProviderError.resourceLimit(containment.detail)
        }
        if let admittedRevision,
           admittedRevision != protocolGenerationRevision {
            throw AgentProviderError.resourceLimit(
                "Codex App Server changed generations while this operation was suspended. Codeness discarded its stale result; retry after Codex recovers."
            )
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
