import Foundation
import Observation

public struct InputOption: Sendable, Equatable, Identifiable {
    public let label: String
    public let description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }

    public var id: String { label }
}

public struct InputQuestion: Sendable, Equatable, Identifiable {
    public let id: String
    public let header: String
    public let question: String
    public let options: [InputOption]
    public let isSecret: Bool

    public init(id: String, header: String, question: String, options: [InputOption], isSecret: Bool) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.isSecret = isSecret
    }
}

public struct ApprovalDecision: Sendable, Equatable, Identifiable {
    public let value: JSONValue
    public let label: String
    public let explanation: String

    public init(value: JSONValue) {
        self.value = value
        switch value {
        case .string("accept"):
            label = "Approve Once"
            explanation = "Approve this requested action."
        case .string("acceptForSession"):
            label = "Approve for Session"
            explanation = "Approve this action and matching requests in this session."
        case .string("decline"):
            label = "Deny"
            explanation = "Deny this action and let the turn continue."
        case .string("cancel"):
            label = "Cancel Turn"
            explanation = "Deny this action and interrupt the turn."
        case .object(let object) where object["acceptWithExecpolicyAmendment"] != nil:
            label = "Approve and Remember Command"
            explanation = "Approve this command and add the offered execution-policy rule."
        case .object(let object) where object["applyNetworkPolicyAmendment"] != nil:
            let amendment = object["applyNetworkPolicyAmendment"]?["network_policy_amendment"]
            let action = amendment?["action"]?.stringValue
            let host = amendment?["host"]?.stringValue
            switch (action, host) {
            case ("allow", let host?):
                label = "Always Allow \(host)"
                explanation = "Apply the offered network rule allowing this host."
            case ("deny", let host?):
                label = "Always Deny \(host)"
                explanation = "Apply the offered network rule denying this host."
            default:
                label = "Apply Network Policy"
                explanation = "Apply the network-policy decision offered by Codex."
            }
        case .string(let identifier):
            label = identifier
            explanation = "Send this decision exactly as offered by Codex."
        case .object(let object):
            label = object.keys.sorted().first.map { "Use \($0)" } ?? "Use Offered Decision"
            explanation = "Send this structured decision exactly as offered by Codex."
        default:
            label = "Use Offered Decision"
            explanation = "Send this decision exactly as offered by Codex."
        }
    }

    public var id: String { value.encodedString() }

    public var isDestructive: Bool {
        value.stringValue == "cancel"
    }
}

public struct PendingServerInteraction: Sendable, Equatable {
    public let id: JSONValue
    public let method: String
    public let title: String
    public let detail: String
    public let questions: [InputQuestion]
    public let approvalDecisions: [ApprovalDecision]
    public let rawParameters: JSONValue

    public init(
        id: JSONValue,
        method: String,
        title: String,
        detail: String,
        questions: [InputQuestion] = [],
        approvalDecisions: [ApprovalDecision] = [],
        rawParameters: JSONValue
    ) {
        self.id = id
        self.method = method
        self.title = title
        self.detail = detail
        self.questions = questions
        self.approvalDecisions = approvalDecisions
        self.rawParameters = rawParameters
    }
}

public enum DocumentPauseStrategy: Sendable, Equatable {
    case graceful
    case immediate
}

public enum DocumentPauseState: Sendable, Equatable {
    case idle
    case requestingCheckpoint
    case waitingForTurn
    case interrupting
    case saving
    case paused
    case failed(String)

    public var isInProgress: Bool {
        switch self {
        case .requestingCheckpoint, .waitingForTurn, .interrupting, .saving: true
        case .idle, .paused, .failed: false
        }
    }
}

public enum DocumentClosePreparationResult: Sendable, Equatable {
    case ready
    case failed(String)
}

@MainActor
@Observable
public final class RepositoryCoordinator {
    public private(set) var record: RepositoryRecord
    public var selectedRunID: UUID? {
        didSet {
            guard isLoaded, selectedRunID != oldValue else { return }
            viewState.selectedRunID = selectedRunID
            scheduleViewStateSave()
        }
    }
    public var pendingInteraction: PendingServerInteraction? { pendingInteractions.first }
    public var pendingInteractionCount: Int { pendingInteractions.count }
    public private(set) var statusMessage = "Loading repository history…"
    public private(set) var errorMessage: String?
    public private(set) var isLoaded = false
    public private(set) var pauseAfterCurrent = false
    public private(set) var isStartingActivity = false
    public private(set) var isStartingOver = false
    public private(set) var pauseState: DocumentPauseState = .idle
    public private(set) var viewState = RepositoryViewState()

    private let appServer: CodexAppServerClient
    private let router: any HandoffRouting
    private let handoffConfigurationValidator: any HandoffConfigurationValidating
    private let store: any RepositoryWorkspaceStoring
    private var sessionsPrepared = false
    private var itemsWithDeltas: [UUID: Set<String>] = [:]
    private var runIsAtBottom: [UUID: Bool] = [:]
    private var completingRunIDs: Set<UUID> = []
    private var routingTasks: [UUID: Task<Void, Never>] = [:]
    private var viewStateSaveTask: Task<Void, Never>?
    private var closeWaiter: CheckedContinuation<DocumentClosePreparationResult, Never>?
    private var isClosing = false
    private var pendingInteractions: [PendingServerInteraction] = []

    public init(
        canonicalPath: String,
        appServer: CodexAppServerClient,
        router: any HandoffRouting,
        store: any RepositoryWorkspaceStoring,
        handoffConfigurationValidator: any HandoffConfigurationValidating = HandoffConfigurationValidator(),
        initialSettings: RepositorySettings = .init()
    ) {
        record = RepositoryRecord(canonicalPath: canonicalPath, settings: initialSettings)
        self.appServer = appServer
        self.router = router
        self.handoffConfigurationValidator = handoffConfigurationValidator
        self.store = store
    }

    public var repositoryName: String {
        URL(fileURLWithPath: record.canonicalPath).lastPathComponent
    }

    public var activity: ActivityRecord? { record.activity }

    public var selectedRun: RunRecord? {
        guard let selectedRunID else { return activeRun ?? record.activity?.runs.last }
        return record.activity?.runs.first(where: { $0.id == selectedRunID })
    }

    public var activeActivity: ActivityRecord? {
        guard let activity = record.activity,
              activity.status == .running || activity.status == .paused else { return nil }
        return activity
    }

    public var activeRun: RunRecord? {
        activeActivity?.runs.last(where: { [.queued, .running, .routing, .awaitingApproval, .paused].contains($0.status) })
    }

    public var liveRunID: UUID? {
        activeRun?.id
    }

    public var canStartActivity: Bool {
        isLoaded && record.activity == nil && !isStartingActivity && !isStartingOver && !isClosing
    }

    /// Starting over is intentionally unavailable while any repository-changing
    /// work, handoff routing, close preparation, or server interaction is live.
    /// The user can pause/interrupt first and then reset from a durable checkpoint.
    public var canStartOver: Bool {
        guard isLoaded,
              record.activity != nil,
              record.activity?.status != .running,
              !isStartingActivity,
              !isStartingOver,
              !isClosing,
              !pauseState.isInProgress,
              pendingInteractions.isEmpty,
              routingTasks.isEmpty,
              completingRunIDs.isEmpty else { return false }
        guard let run = activeRun else { return true }
        switch run.status {
        case .running, .awaitingApproval:
            return false
        case .queued:
            // A paused pre-launch checkpoint has no App Server turn to stop.
            return run.turnID == nil
        case .routing, .paused, .completed, .interrupted, .failed:
            return true
        }
    }

    public var canInterrupt: Bool {
        guard let status = activeRun?.status else { return false }
        return status == .running || status == .awaitingApproval
    }

    public var hasActiveCodexTurn: Bool {
        guard let status = activeRun?.status else { return false }
        return [.queued, .running, .awaitingApproval].contains(status)
    }

    public var canResume: Bool {
        guard let activity = activeActivity, activity.status == .paused else { return false }
        if activity.resumeCheckpoint != nil { return true }
        if activity.pendingAction != nil { return true }
        guard let run = activity.runs.last else { return false }
        if run.status == .interrupted { return true }
        guard run.finalOutput?.isEmpty == false else { return false }
        return run.status == .routing || (run.status == .paused && run.relayError != nil)
    }

    public var canAmendGoal: Bool {
        guard let activity = activeActivity,
              activity.status == .paused,
              !isStartingActivity,
              !isStartingOver,
              !isClosing,
              !pauseState.isInProgress,
              pendingInteractions.isEmpty,
              routingTasks.isEmpty,
              completingRunIDs.isEmpty else { return false }
        guard let run = activeRun else { return true }
        return ![.queued, .running, .routing, .awaitingApproval].contains(run.status)
    }

    public var runDetailPresentation: RunDetailPresentation {
        viewState.detailPresentation ?? .split
    }

    public var requiresCloseConfirmation: Bool {
        activeActivity?.status == .running
    }

    public func load() async {
        guard !isLoaded else { return }
        errorMessage = nil
        do {
            record = try await store.load(
                canonicalPath: record.canonicalPath,
                defaultSettings: record.settings
            )
            viewState = (try? await store.loadViewState(canonicalPath: record.canonicalPath))
                ?? RepositoryViewState()
            await recoverAppendOnlyTranscripts()
            recoverInterruptedState()
            migrateResumeCheckpointIfNeeded()
            pauseAfterCurrent = viewState.pauseAfterCurrent
            runIsAtBottom = viewState.transcriptViewports.mapValues(\.followsOutput)
            if let restoredRunID = viewState.selectedRunID,
               record.activity?.runs.contains(where: { $0.id == restoredRunID }) == true {
                selectedRunID = restoredRunID
            } else {
                selectedRunID = record.activity?.runs.last?.id
                viewState.selectedRunID = selectedRunID
            }
            isLoaded = true
            switch record.activity?.status {
            case nil: statusMessage = "Configure this activity"
            case .completed: statusMessage = "Activity complete"
            case .cancelled: statusMessage = "Activity cancelled"
            case .failed: statusMessage = "Activity failed"
            case .paused: statusMessage = pausedStatusMessage
            case .running: statusMessage = "Activity running"
            }
            do {
                try await persistDocumentState()
            } catch {
                // Loading succeeded; keep the real record active even if recovery/view
                // state cannot be written back yet.
                errorMessage = "Repository history loaded, but its recovered state could not be saved: \(error.localizedDescription)"
            }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not load repository history"
        }
    }

    public func startActivity(goal: String, prompts: ActivityPrompts) async {
        guard canStartActivity else { return }
        let cleanGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGoal.isEmpty else {
            errorMessage = "The goal is empty."
            return
        }
        if let validationMessage = prompts.validationMessage {
            errorMessage = validationMessage
            return
        }
        isStartingActivity = true
        defer { isStartingActivity = false }

        do {
            try await handoffConfigurationValidator.validateLocal(record.settings.relay)
            try await ensureSessions(allowRecreate: true)
            guard !isClosing else { return }
            record.activityDraft = nil
            record.activity = ActivityRecord(
                goal: cleanGoal,
                prompts: prompts,
                pendingAction: .implement,
                resumeCheckpoint: .perform(.implement)
            )
            pauseAfterCurrent = false
            viewState.pauseAfterCurrent = false
            scheduleViewStateSave()
            errorMessage = nil
            do {
                try await persist()
            } catch {
                let initialSaveError = error
                record.activity?.status = .paused
                record.activity?.pendingAction = .implement
                record.activity?.resumeCheckpoint = .perform(.implement)
                statusMessage = "Paused before implementation"
                do {
                    try await persist()
                    errorMessage = "Could not save the new activity before starting Codex: \(initialSaveError.localizedDescription)"
                } catch {
                    errorMessage = "Could not save the new activity before starting Codex: \(initialSaveError.localizedDescription). The retry checkpoint also could not be saved: \(error.localizedDescription)"
                }
                return
            }
            await perform(action: .implement, handoff: nil)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not start activity"
        }
    }

    public func handle(_ event: AppServerEvent) async {
        if case .notification(let method, let params, _) = event,
           method == "serverRequest/resolved",
           let requestID = params["requestId"],
           pendingInteractions.contains(where: { $0.id == requestID }) {
            await finishInteraction(id: requestID)
            return
        }
        guard belongsToRepository(event) else { return }

        switch event {
        case .request(let id, let method, let params, let rawLine):
            await appendRawLine(rawLine, event: event)
            presentInteraction(id: id, method: method, params: params)
            try? await persist()
        case .notification(let method, let params, let rawLine):
            await appendRawLine(rawLine, event: event)
            await handleNotification(method: method, params: params, event: event)
        case .standardError, .exited:
            break
        }
    }

    public func setPauseAfterCurrent(_ enabled: Bool) {
        pauseAfterCurrent = enabled
        viewState.pauseAfterCurrent = enabled
        scheduleViewStateSave()
        statusMessage = enabled ? "Will pause after the current handoff" : "Automatic switching enabled"
    }

    /// Keeps edits made on the pre-start screen in the document record. They are
    /// committed by the ordinary Save/Close/Quit path even if the user does not
    /// start the activity immediately.
    public func updateActivityDraft(goal: String, prompts: ActivityPrompts) {
        guard isLoaded, record.activity == nil, !isStartingActivity, !isStartingOver else { return }
        let draft = ActivityConfigurationDraft(goal: goal, prompts: prompts)
        guard record.activityDraft != draft else { return }
        record.activityDraft = draft
    }

    public func selectLiveRun() {
        selectedRunID = liveRunID
    }

    public func updateScrollPosition(for runID: UUID, isAtBottom: Bool) {
        runIsAtBottom[runID] = isAtBottom
        var viewport = viewState.transcriptViewports[runID] ?? TranscriptViewportState()
        viewport.followsOutput = isAtBottom
        viewState.transcriptViewports[runID] = viewport
        scheduleViewStateSave()
    }

    public func transcriptViewport(for runID: UUID) -> TranscriptViewportState {
        viewState.transcriptViewports[runID] ?? TranscriptViewportState()
    }

    public func updateTranscriptViewport(for runID: UUID, state: TranscriptViewportState) {
        runIsAtBottom[runID] = state.followsOutput
        viewState.transcriptViewports[runID] = state
        scheduleViewStateSave()
    }

    public func updateWindowFrame(_ frame: StoredWindowFrame) {
        viewState.windowFrame = frame
        scheduleViewStateSave()
    }

    public func updateSidebar(width: Double?, isVisible: Bool) {
        if let width {
            viewState.sidebarWidth = min(max(width, 275), 430)
        }
        viewState.sidebarVisible = isVisible
        scheduleViewStateSave()
    }

    public func updateRunDetailPresentation(_ presentation: RunDetailPresentation) {
        guard viewState.detailPresentation != presentation else { return }
        viewState.detailPresentation = presentation
        scheduleViewStateSave()
    }

    public func flushDocumentState() async -> Bool {
        guard !isStartingOver else {
            errorMessage = "Wait for Start Over to finish before saving or closing this repository."
            return false
        }
        viewStateSaveTask?.cancel()
        viewStateSaveTask = nil
        // A load failure leaves `record` as an empty constructor placeholder. Never
        // replace the unreadable source file with that placeholder during Save/Close/Quit.
        guard isLoaded else { return true }
        do {
            try await persistDocumentState()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func resume() async {
        guard record.activity?.status == .paused else { return }
        // Resume means returning to the normal automatic workflow. Keeping the
        // one-shot pause flag set made every subsequent phase require another click.
        pauseAfterCurrent = false
        viewState.pauseAfterCurrent = false
        scheduleViewStateSave()
        statusMessage = "Resuming automatic workflow…"
        if let checkpoint = record.activity?.resumeCheckpoint {
            do {
                record.activity?.status = .running
                record.activity?.resumeCheckpoint = nil
                record.activity?.pendingAction = nil
                switch checkpoint {
                case .recoverRun(let runID):
                    guard let run = run(withID: runID) else {
                        throw RepositoryCoordinatorError.missingRun(runID)
                    }
                    await recoverInterruptedPass(run)
                case .routeCompletedRun(let runID):
                    guard let run = run(withID: runID),
                          let finalOutput = run.finalOutput,
                          !finalOutput.isEmpty else {
                        throw RepositoryCoordinatorError.missingRunOutput(runID)
                    }
                    await beginRouting(runID: runID, finalOutput: finalOutput)
                case .perform(let action):
                    await perform(
                        action: action,
                        handoff: record.activity?.runs.last(where: { $0.handoff != nil })?.handoff
                    )
                }
            } catch {
                record.activity?.status = .paused
                record.activity?.resumeCheckpoint = checkpoint
                errorMessage = error.localizedDescription
                try? await persist()
            }
            return
        }
        if let action = record.activity?.pendingAction {
            do {
                try await ensureSessions(allowRecreate: false)
                record.activity?.status = .running
                record.activity?.pendingAction = nil
                await perform(action: action, handoff: record.activity?.runs.last(where: { $0.handoff != nil })?.handoff)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        guard let run = record.activity?.runs.last else { return }
        let shouldRetryRelay = run.status == .routing
            || (run.status == .paused && run.relayError != nil)
            || (run.status == .interrupted && run.handoff == nil)
        if let finalOutput = run.finalOutput, !finalOutput.isEmpty, shouldRetryRelay {
            record.activity?.status = .running
            await beginRouting(runID: run.id, finalOutput: finalOutput)
        } else if run.status == .interrupted {
            await recoverInterruptedPass(run)
        }
    }

    public func interrupt() async {
        guard let run = activeRun, let threadID = run.threadID, let turnID = run.turnID else { return }
        do {
            try await appServer.interrupt(threadID: threadID, turnID: turnID)
            statusMessage = "Interrupting " + run.kind.displayName.lowercased() + "…"
        } catch {
            if canInterrupt {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func prepareForClose(
        strategy: DocumentPauseStrategy = .immediate
    ) async -> DocumentClosePreparationResult {
        guard !isStartingOver else {
            let message = "Wait for Start Over to finish, then close this repository."
            errorMessage = message
            return .failed(message)
        }
        if isClosing {
            return pauseState == .paused
                ? .ready
                : .failed("This repository is already being paused.")
        }
        guard closeWaiter == nil else {
            return .failed("This repository is already being paused.")
        }

        isClosing = true
        pauseState = .saving
        await cancelRoutingTasks()

        guard record.activity?.status == .running else {
            return await finishCloseWithoutActiveTurn()
        }

        guard let run = activeRun else {
            record.activity?.status = .paused
            migrateResumeCheckpointIfNeeded()
            return await finishCloseWithoutActiveTurn()
        }

        switch run.status {
        case .routing:
            record.activity?.status = .paused
            record.activity?.resumeCheckpoint = .routeCompletedRun(run.id)
            statusMessage = "Paused before preparing the handoff"
            return await finishCloseWithoutActiveTurn()
        case .paused:
            record.activity?.status = .paused
            migrateResumeCheckpointIfNeeded()
            return await finishCloseWithoutActiveTurn()
        case .queued where run.turnID == nil:
            pauseState = .waitingForTurn
            statusMessage = "Waiting for the Codex turn to become interruptible…"
            return await waitForCloseCompletion()
        case .queued, .running, .awaitingApproval:
            guard let threadID = run.threadID, let turnID = run.turnID else {
                pauseState = .waitingForTurn
                return await waitForCloseCompletion()
            }
            do {
                if strategy == .graceful, run.status == .running {
                    pauseState = .requestingCheckpoint
                    statusMessage = "Asking " + run.role.displayName.lowercased() + " to stop coherently…"
                    try await appServer.steer(
                        threadID: threadID,
                        turnID: turnID,
                        message: Self.gracefulPausePrompt
                    )
                    if pauseState != .paused {
                        pauseState = .waitingForTurn
                        statusMessage = "Waiting for " + run.kind.displayName.lowercased()
                            + " to reach a stopping point…"
                    }
                } else {
                    pauseState = .interrupting
                    statusMessage = "Interrupting " + run.kind.displayName.lowercased() + "…"
                    try await appServer.interrupt(threadID: threadID, turnID: turnID)
                }
                return await waitForCloseCompletion()
            } catch {
                if pauseState == .paused {
                    return .ready
                }
                return await reconcileCloseControlFailure(error.localizedDescription)
            }
        case .interrupted, .failed, .completed:
            record.activity?.status = .paused
            migrateResumeCheckpointIfNeeded()
            return await finishCloseWithoutActiveTurn()
        }
    }

    public func interruptCloseWait() async {
        guard isClosing,
              pauseState == .waitingForTurn || pauseState == .requestingCheckpoint,
              let run = activeRun,
              let threadID = run.threadID,
              let turnID = run.turnID else { return }
        do {
            pauseState = .interrupting
            statusMessage = "Interrupting " + run.kind.displayName.lowercased() + "…"
            try await appServer.interrupt(threadID: threadID, turnID: turnID)
        } catch {
            _ = await reconcileCloseControlFailure(error.localizedDescription)
        }
    }

    public func documentDidClose() {
        isClosing = true
        viewStateSaveTask?.cancel()
        viewStateSaveTask = nil
    }

    public func cancelClosePreparation() {
        guard closeWaiter == nil, !pauseState.isInProgress else { return }
        isClosing = false
        pauseState = .idle
        if record.activity?.status == .paused {
            statusMessage = pausedStatusMessage
        }
    }

    @discardableResult
    public func steer(_ message: String) async -> Bool {
        guard let run = activeRun, let threadID = run.threadID, let turnID = run.turnID else { return false }
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMessage.isEmpty else { return false }
        do {
            try await appServer.steer(threadID: threadID, turnID: turnID, message: cleanMessage)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func resolveApproval(_ decision: ApprovalDecision) async {
        guard let interaction = pendingInteraction else { return }
        do {
            try await appServer.respond(
                to: interaction.id,
                result: .object(["decision": decision.value])
            )
            await finishInteraction(id: interaction.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func resolveQuestions(_ answers: [String: [String]]) async {
        guard let interaction = pendingInteraction else { return }
        let values = answers.mapValues { answer in
            JSONValue.object(["answers": .array(answer.map(JSONValue.string))])
        }
        do {
            try await appServer.respond(to: interaction.id, result: .object(["answers": .object(values)]))
            await finishInteraction(id: interaction.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func resolveRawInteraction(_ resultText: String) async {
        guard let interaction = pendingInteraction else { return }
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(resultText.utf8))
            try await appServer.respond(to: interaction.id, result: value)
            await finishInteraction(id: interaction.id)
        } catch {
            errorMessage = "The response is not valid JSON: \(error.localizedDescription)"
        }
    }

    public func cancelInteraction() async {
        guard let interaction = pendingInteraction else { return }
        do {
            try await appServer.respondWithError(to: interaction.id, message: "Cancelled by the user")
            await finishInteraction(id: interaction.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func retryRelay() async {
        guard let run = activeRun ?? record.activity?.runs.last,
              let finalOutput = run.finalOutput else { return }
        record.activity?.status = .running
        record.activity?.resumeCheckpoint = nil
        await beginRouting(runID: run.id, finalOutput: finalOutput)
    }

    public func useHandoff(text: String, disposition: SourceDisposition, label: String) async {
        guard let run = activeRun ?? record.activity?.runs.last else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "The handoff must contain information for the next session."
            return
        }
        let envelope = HandoffEnvelope(
            handoffText: text,
            sourceDisposition: disposition,
            runLabel: normalizedRunLabel(label, fallback: run.kind.displayName)
        )
        updateRun(run.id) {
            $0.handoff = envelope
            $0.relayError = nil
            $0.status = .completed
        }
        record.activity?.status = .running
        record.activity?.resumeCheckpoint = nil
        await applyWorkflowDecision(runID: run.id, for: run.kind, envelope: envelope)
    }

    @discardableResult
    public func updateSettings(_ settings: RepositorySettings) async -> Bool {
        do {
            try await handoffConfigurationValidator.validateLocal(settings.relay)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        let previousSettings = record.settings
        record.settings = settings
        do {
            try await persist()
            return true
        } catch {
            record.settings = previousSettings
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func testHandoffConfiguration(_ settings: RelaySettings) async throws {
        try await handoffConfigurationValidator.testRemote(settings)
    }

    @discardableResult
    public func amendGoal(_ revisedGoal: String) async -> Bool {
        guard canAmendGoal, var activity = record.activity else { return false }
        let cleanGoal = revisedGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGoal.isEmpty else {
            errorMessage = "The goal is empty."
            return false
        }
        guard cleanGoal != activity.goal else { return true }

        let previousActivity = activity
        activity.goalAmendments.append(GoalAmendment(
            previousGoal: activity.goal,
            revisedGoal: cleanGoal
        ))
        activity.goal = cleanGoal
        record.activity = activity
        do {
            try await persist()
            statusMessage = pausedStatusMessage
            return true
        } catch {
            record.activity = previousActivity
            errorMessage = "Could not save the revised goal: \(error.localizedDescription)"
            return false
        }
    }

    /// Archives the current Codeness-owned activity, then returns this repository
    /// window to its editable pre-start state. This method only writes through the
    /// workspace store under Application Support; it never mutates the repository.
    public func startOver() async {
        guard canStartOver, let previousActivity = record.activity else { return }
        isStartingOver = true
        defer { isStartingOver = false }

        let pendingViewSave = viewStateSaveTask
        viewStateSaveTask?.cancel()
        viewStateSaveTask = nil
        await pendingViewSave?.value
        await cancelRoutingTasks()

        let archivedRecord = record
        let resetRecord = RepositoryRecord(
            id: record.id,
            canonicalPath: record.canonicalPath,
            implementerThreadID: nil,
            reviewerThreadID: nil,
            settings: record.settings,
            activityDraft: ActivityConfigurationDraft(
                goal: previousActivity.goal,
                prompts: previousActivity.prompts
            ),
            activity: nil,
            createdAt: record.createdAt,
            updatedAt: .now
        )
        let resetViewState = RepositoryViewState(
            schemaVersion: viewState.schemaVersion,
            selectedRunID: nil,
            transcriptViewports: [:],
            windowFrame: viewState.windowFrame,
            sidebarWidth: viewState.sidebarWidth,
            sidebarVisible: false,
            pauseAfterCurrent: false,
            detailPresentation: viewState.detailPresentation
        )

        do {
            guard !isClosing else {
                throw RepositoryCoordinatorError.startOverWhileClosing
            }
            try await store.archiveActivity(archivedRecord)
            guard !isClosing else {
                throw RepositoryCoordinatorError.startOverWhileClosing
            }
            // workspace.json is the authoritative reset commit. The view-state
            // file is non-authoritative and can safely be retried afterward.
            try await store.save(resetRecord)

            record = resetRecord
            viewState = resetViewState
            selectedRunID = nil
            pauseAfterCurrent = false
            sessionsPrepared = false
            itemsWithDeltas.removeAll()
            runIsAtBottom.removeAll()
            completingRunIDs.removeAll()
            pendingInteractions.removeAll()
            pauseState = .idle
            statusMessage = "Configure this activity"
            errorMessage = nil

            do {
                try await store.saveViewState(resetViewState, canonicalPath: resetRecord.canonicalPath)
            } catch {
                errorMessage = "The activity was reset, but its window state could not be saved: \(error.localizedDescription)"
            }
        } catch {
            errorMessage = "Could not start over: \(error.localizedDescription)"
        }
    }

    public func appServerRestarted() async {
        sessionsPrepared = false
        pendingInteractions.removeAll()
        if record.activity?.status == .running {
            record.activity?.status = .paused
            markLastRunInterruptedIfNeeded()
            migrateResumeCheckpointIfNeeded()
            statusMessage = pausedStatusMessage
        }
        if isClosing {
            await completeCloseAfterTerminalEvent()
        } else {
            try? await persist()
        }
    }

    public func clearError() {
        errorMessage = nil
    }

    private func handleNotification(method: String, params: JSONValue, event: AppServerEvent) async {
        if method == "serverRequest/resolved" {
            if let requestID = params["requestId"],
               pendingInteractions.contains(where: { $0.id == requestID }) {
                await finishInteraction(id: requestID)
            }
            return
        }

        guard let runID = runID(for: event) else { return }

        if method == "turn/started", let turnID = params["turn"]?["id"]?.stringValue {
            updateRun(runID) {
                $0.turnID = turnID
                $0.status = .running
            }
        }

        let deltaItems = itemsWithDeltas[runID] ?? []
        let update = TranscriptFormatter.update(method: method, params: params, itemsWithDeltas: deltaItems)
        if let itemID = update.itemID, method.hasSuffix("/delta") || method.hasSuffix("Delta") {
            itemsWithDeltas[runID, default: []].insert(itemID)
        }
        let storedText = RunTranscriptPresentation.storedText(for: update)
        if !storedText.isEmpty {
            updateRun(runID) { $0.transcript += storedText }
            await appendTranscript(storedText, runID: runID)
        }
        if let finalOutput = update.finalOutput, !finalOutput.isEmpty {
            updateRun(runID) { $0.finalOutput = finalOutput }
        }

        if method == "turn/completed" {
            let turn = params["turn"] ?? .null
            let finalOutput = TranscriptFormatter.finalOutput(from: turn) ?? run(withID: runID)?.finalOutput
            let status = turn["status"]?.stringValue ?? "failed"
            updateRun(runID) {
                $0.turnID = turn["id"]?.stringValue ?? $0.turnID
                $0.durationMilliseconds = turn["durationMs"]?.integerValue
                $0.completedAt = .now
            }
            if status == "completed", let finalOutput, !finalOutput.isEmpty {
                updateRun(runID) {
                    $0.finalOutput = finalOutput
                    $0.status = .routing
                }
                if isClosing {
                    record.activity?.resumeCheckpoint = .routeCompletedRun(runID)
                    pauseActivity(message: "Paused before preparing the handoff")
                    await completeCloseAfterTerminalEvent()
                } else {
                    await beginRouting(runID: runID, finalOutput: finalOutput)
                }
            } else {
                updateRun(runID) { $0.status = status == "interrupted" ? .interrupted : .failed }
                record.activity?.resumeCheckpoint = .recoverRun(runID)
                pauseActivity(message: "The Codex turn ended with status \(status).")
                if isClosing {
                    await completeCloseAfterTerminalEvent()
                } else {
                    try? await persist()
                }
            }
        }
    }

    private func beginRouting(runID: UUID, finalOutput: String) async {
        guard !completingRunIDs.contains(runID), run(withID: runID) != nil else { return }
        completingRunIDs.insert(runID)
        updateRun(runID) {
            $0.status = .routing
            $0.relayError = nil
            $0.handoff = nil
        }
        statusMessage = "Preparing handoff…"
        do {
            try await persist()
        } catch {
            let checkpointError = error
            completingRunIDs.remove(runID)
            updateRun(runID) {
                $0.status = .paused
                $0.relayError = "The completed turn could not be saved before preparing its handoff."
            }
            record.activity?.status = .paused
            record.activity?.resumeCheckpoint = .routeCompletedRun(runID)
            statusMessage = "Completed turn is waiting for a durable checkpoint"
            errorMessage = "Codeness did not start the handoff because the completed turn could not be saved: \(checkpointError.localizedDescription)"
            // A transient first failure may allow this explicit paused retry checkpoint
            // to become durable. Regardless, relay I/O must not start in this branch.
            try? await persist()
            return
        }

        routingTasks[runID] = Task { [weak self] in
            await self?.routeCompletedRun(runID: runID, finalOutput: finalOutput)
        }
    }

    private func routeCompletedRun(runID: UUID, finalOutput: String) async {
        defer {
            completingRunIDs.remove(runID)
            routingTasks.removeValue(forKey: runID)
        }
        guard let run = run(withID: runID) else { return }

        let context = handoffContext(for: run, source: finalOutput)
        do {
            var envelope = try await router.route(context, settings: record.settings.relay)
            guard !isClosing else { return }
            envelope.runLabel = normalizedRunLabel(envelope.runLabel, fallback: run.kind.displayName)
            updateRun(runID) {
                $0.handoff = envelope
                $0.status = .completed
                $0.relayError = nil
            }
            record.activity?.resumeCheckpoint = nil
            await applyWorkflowDecision(runID: runID, for: run.kind, envelope: envelope)
        } catch {
            guard !isClosing else { return }
            updateRun(runID) {
                $0.status = .paused
                $0.relayError = error.localizedDescription
            }
            record.activity?.resumeCheckpoint = .routeCompletedRun(runID)
            pauseActivity(message: "Relay paused: \(error.localizedDescription)")
            try? await persist()
        }
    }

    private func applyWorkflowDecision(runID: UUID, for kind: RunKind, envelope: HandoffEnvelope) async {
        if kind == .implementation {
            record.activity?.implementationClaimedComplete = envelope.sourceDisposition == .implementationComplete
        } else if kind == .fix {
            switch envelope.sourceDisposition {
            case .fixCheckpoint:
                record.activity?.implementationClaimedComplete = false
            case .fixComplete:
                record.activity?.implementationClaimedComplete = true
            default:
                break
            }
        }
        switch WorkflowStateMachine.decision(
            after: kind,
            disposition: envelope.sourceDisposition
        ) {
        case .pause(let reason):
            updateRun(runID) {
                $0.status = .paused
                $0.relayError = reason
            }
            record.activity?.resumeCheckpoint = .routeCompletedRun(runID)
            pauseActivity(message: reason)
            try? await persist()
        case .continueWith(let action):
            if pauseAfterCurrent || isClosing || record.activity?.status == .paused {
                guard record.activity != nil else { return }
                record.activity?.status = .paused
                record.activity?.pendingAction = action
                record.activity?.resumeCheckpoint = .perform(action)
                statusMessage = "Paused before \(action.displayName)"
                try? await persist()
            } else {
                await perform(action: action, handoff: envelope)
            }
        }
    }

    private func perform(action: PendingAction, handoff: HandoffEnvelope?) async {
        guard let activity = record.activity else { return }
        record.activity?.pendingAction = action
        record.activity?.resumeCheckpoint = .perform(action)
        if action != .complete {
            do {
                try await ensureSessions(allowRecreate: false)
            } catch {
                record.activity?.status = .paused
                record.activity?.pendingAction = action
                record.activity?.resumeCheckpoint = .perform(action)
                errorMessage = error.localizedDescription
                statusMessage = "Could not resume the saved Codex sessions"
                try? await persist()
                return
            }
        }
        guard !isClosing else {
            record.activity?.status = .paused
            return
        }
        record.activity?.status = .running

        switch action {
        case .implement:
            await launchRun(
                role: .implementer,
                kind: .implementation,
                prompt: PromptBuilder.implementation(
                    goal: activity.goal,
                    template: activity.prompts.implementation
                )
            )
        case .review:
            guard let handoff else {
                pauseActivity(message: "The implementation handoff is missing.")
                try? await persist()
                return
            }
            await launchRun(
                role: .reviewer,
                kind: .review,
                prompt: PromptBuilder.review(
                    goal: activity.goal,
                    template: activity.prompts.review,
                    implementationOutput: handoff.handoffText
                )
            )
        case .fix:
            guard let handoff else {
                pauseActivity(message: "The review handoff is missing.")
                try? await persist()
                return
            }
            await launchRun(
                role: .implementer,
                kind: .fix,
                prompt: PromptBuilder.fix(
                    goal: activity.goal,
                    template: activity.prompts.fix,
                    reviewOutput: handoff.handoffText
                )
            )
        case .complete:
            record.activity?.status = .completed
            record.activity?.completedAt = .now
            record.activity?.pendingAction = nil
            record.activity?.resumeCheckpoint = nil
            statusMessage = "Activity complete"
            pauseAfterCurrent = false
            viewState.pauseAfterCurrent = false
            scheduleViewStateSave()
            try? await persist()
        }
    }

    private func launchRun(role: AgentRole, kind: RunKind, prompt: String) async {
        guard !isClosing, record.activity != nil else { return }
        let selection: ModelSelection = switch kind {
        case .implementation: record.settings.implementer
        case .review: record.settings.reviewer
        case .fix: record.settings.fixer
        }
        let action: PendingAction = switch kind {
        case .implementation: .implement
        case .review: .review
        case .fix: .fix
        }
        let threadID = role == .implementer ? record.implementerThreadID : record.reviewerThreadID
        guard let threadID else {
            pauseActivity(message: "The \(role.displayName.lowercased()) session is missing.")
            return
        }
        let previousRunID = record.activity?.runs.last?.id
        let followsLiveRun = RunSelectionPolicy.shouldSelectNextRun(
            selectedRunID: selectedRunID,
            activeRunID: previousRunID,
            activeRunIsAtBottom: previousRunID.flatMap { runIsAtBottom[$0] }
        )

        let run = RunRecord(
            sequence: (record.activity?.runs.count ?? 0) + 1,
            role: role,
            kind: kind,
            status: .queued,
            threadID: threadID,
            model: selection.model,
            effort: selection.effort,
            prompt: prompt
        )
        record.activity?.pendingAction = nil
        record.activity?.resumeCheckpoint = .recoverRun(run.id)
        record.activity?.runs.append(run)
        runIsAtBottom[run.id] = true
        if followsLiveRun {
            selectedRunID = run.id
        }
        itemsWithDeltas[run.id] = []
        statusMessage = "Starting \(kind.displayName.lowercased())…"

        do {
            try await persist()
        } catch {
            let queuedSaveError = error
            // No Codex turn exists yet, so remove the in-memory row and restore the
            // previous durable phase checkpoint instead of running without a record.
            record.activity?.runs.removeAll(where: { $0.id == run.id })
            itemsWithDeltas.removeValue(forKey: run.id)
            runIsAtBottom.removeValue(forKey: run.id)
            record.activity?.status = .paused
            record.activity?.pendingAction = action
            record.activity?.resumeCheckpoint = .perform(action)
            selectedRunID = previousRunID
            do {
                // The failed queued record must never launch a turn. A second save
                // records the safe paused checkpoint if the first failure was transient.
                try await persist()
                errorMessage = "Could not save the next run before starting Codex: \(queuedSaveError.localizedDescription)"
            } catch {
                errorMessage = "Could not save the next run before starting Codex: \(queuedSaveError.localizedDescription). The paused checkpoint also could not be saved: \(error.localizedDescription)"
            }
            statusMessage = "Paused before \(action.displayName.lowercased())"
            return
        }

        let turnID: String
        do {
            turnID = try await appServer.startTurn(
                threadID: threadID,
                prompt: prompt,
                cwd: record.canonicalPath,
                model: selection.model,
                effort: selection.effort
            )
        } catch {
            if let knownTurnID = self.run(withID: run.id)?.turnID {
                // A turn/started notification can win the race with a failed start
                // response. That notification is authoritative; it may even have
                // reached a later state already, so do not regress its status here.
                errorMessage = "Codex started turn \(knownTurnID), but its start response failed: \(error.localizedDescription)"
                if self.run(withID: run.id)?.status == .running {
                    statusMessage = "\(kind.displayName) running"
                }
                return
            }
            let failureText = RunTranscriptPresentation.storedText(
                "\nCould not start turn: \(error.localizedDescription)\n",
                section: .diagnostic
            )
            updateRun(run.id) {
                $0.status = .failed
                $0.completedAt = .now
                $0.transcript += failureText
            }
            await appendTranscript(failureText, runID: run.id)
            record.activity?.resumeCheckpoint = .recoverRun(run.id)
            pauseActivity(message: error.localizedDescription)
            if isClosing {
                await completeCloseAfterTerminalEvent()
            } else {
                try? await persist()
            }
            return
        }

        updateRun(run.id) {
            if $0.turnID == nil {
                $0.turnID = turnID
            }
            if $0.status == .queued {
                $0.status = .running
            }
        }

        do {
            try await persist()
        } catch {
            // App Server has accepted the turn. Keep it active in memory so close/quit
            // can still interrupt it; the mandatory queued-run save above remains the
            // durable crash-recovery checkpoint.
            errorMessage = "The Codex turn started, but its latest state could not be saved: \(error.localizedDescription)"
        }

        if isClosing {
            pauseState = .interrupting
            statusMessage = "Interrupting \(kind.displayName.lowercased())…"
            do {
                try await appServer.interrupt(threadID: threadID, turnID: turnID)
            } catch {
                _ = await reconcileCloseControlFailure(error.localizedDescription)
            }
            return
        }
        statusMessage = "\(kind.displayName) running"
    }

    private func ensureSessions(allowRecreate: Bool) async throws {
        guard !sessionsPrepared else { return }
        let implementerThreadID = try await prepareThread(
            existingID: record.implementerThreadID,
            role: .implementer,
            selection: record.settings.implementer,
            instructions: PromptBuilder.implementerInstructions,
            allowRecreate: allowRecreate
        )
        record.implementerThreadID = implementerThreadID
        try await persist()

        let reviewerThreadID = try await prepareThread(
            existingID: record.reviewerThreadID,
            role: .reviewer,
            selection: record.settings.reviewer,
            instructions: PromptBuilder.reviewerInstructions,
            allowRecreate: allowRecreate
        )
        record.reviewerThreadID = reviewerThreadID
        try await persist()
        sessionsPrepared = true
    }

    private func prepareThread(
        existingID: String?,
        role: AgentRole,
        selection: ModelSelection,
        instructions: String,
        allowRecreate: Bool
    ) async throws -> String {
        if let existingID {
            do {
                try await appServer.resumeThread(
                    id: existingID,
                    cwd: record.canonicalPath,
                    model: selection.model,
                    developerInstructions: instructions
                )
                return existingID
            } catch where allowRecreate {
                statusMessage = "Recreating unavailable \(role.displayName.lowercased()) session…"
            }
        }
        guard allowRecreate else {
            throw RepositoryCoordinatorError.missingSession(role)
        }
        let identifier = try await appServer.startThread(
            cwd: record.canonicalPath,
            model: selection.model,
            developerInstructions: instructions
        )
        try await appServer.setThreadName(id: identifier, name: "\(repositoryName) — \(role.displayName)")
        return identifier
    }

    private func recoverInterruptedPass(_ interruptedRun: RunRecord) async {
        record.activity?.resumeCheckpoint = .recoverRun(interruptedRun.id)
        do {
            try await ensureSessions(allowRecreate: false)
            guard record.activity != nil, !isClosing else {
                record.activity?.status = .paused
                return
            }
            record.activity?.status = .running
            let recoveryPrompt = """
            The preceding Codeness pass was interrupted and may have partially changed the repository. Inspect the current repository state, recover the intended pass below without blindly replaying completed edits, and finish at the same kind of checkpoint.

            PREVIOUS PASS INSTRUCTION

            \(interruptedRun.prompt)
            """
            await launchRun(role: interruptedRun.role, kind: interruptedRun.kind, prompt: recoveryPrompt)
        } catch {
            errorMessage = error.localizedDescription
            record.activity?.resumeCheckpoint = .recoverRun(interruptedRun.id)
            pauseActivity(message: "Could not resume the interrupted session.")
            try? await persist()
        }
    }

    private func recoverInterruptedState() {
        guard record.activity?.status == .running else { return }
        record.activity?.status = .paused
        markLastRunInterruptedIfNeeded()
        migrateResumeCheckpointIfNeeded()
    }

    private func markLastRunInterruptedIfNeeded() {
        if let runIndex = record.activity?.runs.indices.last {
            let run = record.activity?.runs[runIndex]
            if let status = run?.status,
               [.queued, .running, .awaitingApproval].contains(status) {
                record.activity?.runs[runIndex].status = .interrupted
                record.activity?.runs[runIndex].completedAt = .now
                if let runID = run?.id {
                    record.activity?.resumeCheckpoint = .recoverRun(runID)
                }
            } else if run?.status == .routing, run?.finalOutput?.isEmpty != false {
                record.activity?.runs[runIndex].status = .interrupted
                record.activity?.runs[runIndex].completedAt = .now
                if let runID = run?.id {
                    record.activity?.resumeCheckpoint = .recoverRun(runID)
                }
            } else if run?.status == .routing, let runID = run?.id {
                record.activity?.resumeCheckpoint = .routeCompletedRun(runID)
            }
        }
    }

    private func recoverAppendOnlyTranscripts() async {
        guard let activity = record.activity else { return }
        for run in activity.runs {
            guard let recovered = try? await store.recoveredTranscript(
                repositoryPath: record.canonicalPath,
                activityID: activity.id,
                runID: run.id
            ), !recovered.isEmpty, recovered != run.transcript else { continue }
            let reconciled = RunTranscriptPresentation.reconciledTranscript(
                metadata: run.transcript,
                appendLog: recovered
            )
            updateRun(run.id) { $0.transcript = reconciled }
        }
    }

    private func presentInteraction(id: JSONValue, method: String, params: JSONValue) {
        let title: String
        let detail: String
        var questions: [InputQuestion] = []
        var approvalDecisions: [ApprovalDecision] = []

        switch method {
        case "item/commandExecution/requestApproval":
            title = "Approve Command"
            let command = params["command"]?.stringValue ?? "Unknown command"
            let cwd = params["cwd"]?.stringValue ?? record.canonicalPath
            let reason = params["reason"]?.stringValue ?? "Codex requested approval."
            detail = "\(command)\n\nWorking directory: \(cwd)\n\n\(reason)"
            approvalDecisions = decodeApprovalDecisions(params["availableDecisions"])
        case "item/fileChange/requestApproval":
            title = "Approve File Changes"
            detail = params["reason"]?.stringValue ?? "Codex requested approval to change files."
            approvalDecisions = decodeApprovalDecisions(params["availableDecisions"])
        case "item/tool/requestUserInput":
            title = "Codex Needs Input"
            detail = "Answer the questions to continue the active turn."
            questions = decodeQuestions(params["questions"]?.arrayValue ?? [])
        default:
            title = "Codex Request"
            detail = "Codeness does not have a specialized editor for \(method). Supply its JSON result or cancel the request."
        }

        let interaction = PendingServerInteraction(
            id: id,
            method: method,
            title: title,
            detail: detail,
            questions: questions,
            approvalDecisions: approvalDecisions,
            rawParameters: params
        )
        guard !pendingInteractions.contains(where: { $0.id == id }) else { return }
        pendingInteractions.append(interaction)
        if let run = activeRun {
            updateRun(run.id) { $0.status = .awaitingApproval }
        }
        if pendingInteractions.count == 1 {
            statusMessage = title
        }
    }

    private func finishInteraction(id: JSONValue) async {
        pendingInteractions.removeAll(where: { $0.id == id })
        if pendingInteractions.isEmpty,
           let run = activeRun,
           run.status == .awaitingApproval {
            updateRun(run.id) { $0.status = .running }
        }
        if let nextInteraction = pendingInteraction {
            statusMessage = nextInteraction.title
            try? await persist()
            return
        }
        switch activeRun?.status {
        case .routing: statusMessage = "Preparing handoff…"
        case .running: statusMessage = activeRun.map { "\($0.role.displayName) running" } ?? "Running"
        case .paused: statusMessage = "Paused"
        default: statusMessage = "Ready"
        }
        try? await persist()
    }

    private func decodeQuestions(_ values: [JSONValue]) -> [InputQuestion] {
        values.compactMap { value in
            guard let id = value["id"]?.stringValue,
                  let question = value["question"]?.stringValue else { return nil }
            let options = value["options"]?.arrayValue?.compactMap { option -> InputOption? in
                guard let label = option["label"]?.stringValue else { return nil }
                return InputOption(label: label, description: option["description"]?.stringValue ?? "")
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

    private func decodeApprovalDecisions(_ offeredValue: JSONValue?) -> [ApprovalDecision] {
        if let offeredValue {
            switch offeredValue {
            case .array(let decisions):
                return decisions.map { ApprovalDecision(value: $0) }
            case .null:
                break
            default:
                // An explicitly malformed field must not cause Codeness to invent
                // choices that the running App Server may reject.
                return []
            }
        }
        return ["accept", "acceptForSession", "decline", "cancel"].map {
            ApprovalDecision(value: .string($0))
        }
    }

    private func handoffContext(for run: RunRecord, source: String) -> HandoffContext {
        switch run.kind {
        case .implementation:
            return .init(
                sender: .implementer,
                recipient: .reviewer,
                runKind: run.kind,
                recipientPurpose: "Inspect the repository and review this implementation checkpoint or completion claim.",
                source: source
            )
        case .review:
            return .init(
                sender: .reviewer,
                recipient: .implementer,
                runKind: run.kind,
                recipientPurpose: "Address the review feedback once without beginning another implementation work unit.",
                source: source
            )
        case .fix:
            return .init(
                sender: .implementer,
                recipient: .implementer,
                runKind: run.kind,
                recipientPurpose: "Preserve the fixes and explicit whole-goal verdict so Codeness can either begin the next implementation work unit or finish the activity.",
                source: source
            )
        }
    }

    private func belongsToRepository(_ event: AppServerEvent) -> Bool {
        guard let threadID = event.threadID else { return false }
        return threadID == record.implementerThreadID || threadID == record.reviewerThreadID
    }

    private func runID(for event: AppServerEvent) -> UUID? {
        guard let threadID = event.threadID else { return nil }
        if let turnID = event.turnID {
            if let run = record.activity?.runs.last(where: { $0.turnID == turnID }) {
                return run.id
            }
        }
        return record.activity?.runs.last(where: {
            $0.threadID == threadID && [.queued, .running, .awaitingApproval].contains($0.status)
        })?.id
    }

    private func run(withID id: UUID) -> RunRecord? {
        record.activity?.runs.first(where: { $0.id == id })
    }

    private func updateRun(_ id: UUID, update: (inout RunRecord) -> Void) {
        guard var activity = record.activity,
              let runIndex = activity.runs.firstIndex(where: { $0.id == id }) else { return }
        update(&activity.runs[runIndex])
        record.activity = activity
        record.updatedAt = .now
    }

    private func pauseActivity(message: String) {
        guard record.activity != nil else { return }
        record.activity?.status = .paused
        statusMessage = message
    }

    private var pausedStatusMessage: String {
        guard let activity = record.activity else { return "Paused" }
        if let checkpoint = activity.resumeCheckpoint {
            switch checkpoint {
            case .recoverRun:
                return "Interrupted; inspect the repository before resuming"
            case .routeCompletedRun:
                return "Handoff pending; resume without replaying the completed pass"
            case .perform(let action):
                return "Paused before \(action.displayName)"
            }
        }
        if let action = activity.pendingAction {
            return "Paused before \(action.displayName)"
        }
        if let run = activity.runs.last {
            if run.status == .routing || (run.status == .interrupted && run.finalOutput?.isEmpty == false) {
                return "Handoff pending; resume without replaying the completed pass"
            }
            if run.relayError != nil {
                return "Handoff needs attention"
            }
        }
        return "Interrupted; inspect the repository before resuming"
    }

    private func appendRawLine(_ line: String, event: AppServerEvent) async {
        guard let runID = runID(for: event), let activityID = record.activity?.id else { return }
        try? await store.appendRawLine(
            line,
            repositoryPath: record.canonicalPath,
            activityID: activityID,
            runID: runID
        )
    }

    private func appendTranscript(_ text: String, runID: UUID) async {
        guard let activityID = record.activity?.id,
              record.activity?.runs.contains(where: { $0.id == runID }) == true else { return }
        try? await store.appendTranscript(
            text,
            repositoryPath: record.canonicalPath,
            activityID: activityID,
            runID: runID
        )
    }

    private func persist() async throws {
        guard isLoaded else { throw RepositoryCoordinatorError.documentNotLoaded }
        record.updatedAt = .now
        try await store.save(record)
    }

    private func persistDocumentState() async throws {
        guard isLoaded else { throw RepositoryCoordinatorError.documentNotLoaded }
        viewState.selectedRunID = selectedRunID
        viewState.pauseAfterCurrent = pauseAfterCurrent
        try await persist()
        try await store.saveViewState(viewState, canonicalPath: record.canonicalPath)
    }

    private func scheduleViewStateSave() {
        guard isLoaded, !isClosing, !isStartingOver else { return }
        viewStateSaveTask?.cancel()
        viewStateSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                try await self.store.saveViewState(
                    self.viewState,
                    canonicalPath: self.record.canonicalPath
                )
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func migrateResumeCheckpointIfNeeded() {
        guard var activity = record.activity,
              activity.status == .paused,
              activity.resumeCheckpoint == nil else { return }

        if let action = activity.pendingAction {
            activity.resumeCheckpoint = .perform(action)
        } else if let run = activity.runs.last {
            if run.status == .routing,
               run.finalOutput?.isEmpty == false {
                activity.resumeCheckpoint = .routeCompletedRun(run.id)
            } else if run.status == .interrupted {
                activity.resumeCheckpoint = run.finalOutput?.isEmpty == false && run.handoff == nil
                    ? .routeCompletedRun(run.id)
                    : .recoverRun(run.id)
            } else if run.status == .paused, run.relayError != nil,
                      run.finalOutput?.isEmpty == false {
                activity.resumeCheckpoint = .routeCompletedRun(run.id)
            }
        }
        record.activity = activity
    }

    private func cancelRoutingTasks() async {
        let tasks = Array(routingTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
        routingTasks.removeAll()
        completingRunIDs.removeAll()
    }

    private func finishCloseWithoutActiveTurn() async -> DocumentClosePreparationResult {
        pauseState = .saving
        guard isLoaded else {
            pauseState = .paused
            statusMessage = "Saved data left unchanged"
            return .ready
        }
        if record.activity?.status == .running {
            record.activity?.status = .paused
            migrateResumeCheckpointIfNeeded()
        }
        guard await flushDocumentState() else {
            return failClose(errorMessage ?? "Could not save this repository document.")
        }
        pauseState = .paused
        statusMessage = record.activity == nil ? "Repository saved" : pausedStatusMessage
        return .ready
    }

    private func waitForCloseCompletion() async -> DocumentClosePreparationResult {
        if pauseState == .paused {
            return .ready
        }
        return await withCheckedContinuation { continuation in
            closeWaiter = continuation
        }
    }

    private func completeCloseAfterTerminalEvent() async {
        pauseState = .saving
        pendingInteractions.removeAll()
        let saved = await flushDocumentState()
        if saved {
            pauseState = .paused
            let waiter = closeWaiter
            closeWaiter = nil
            waiter?.resume(returning: .ready)
        } else {
            let result = failClose(errorMessage ?? "Could not save this repository document.")
            let waiter = closeWaiter
            closeWaiter = nil
            waiter?.resume(returning: result)
        }
    }

    private func reconcileCloseControlFailure(
        _ message: String
    ) async -> DocumentClosePreparationResult {
        pauseState = .waitingForTurn
        statusMessage = "Confirming whether the Codex turn already stopped…"
        try? await Task.sleep(for: .milliseconds(500))
        if pauseState == .paused {
            return .ready
        }
        return failClose(message)
    }

    @discardableResult
    private func failClose(_ message: String) -> DocumentClosePreparationResult {
        errorMessage = message
        pauseState = .failed(message)
        isClosing = false
        let result = DocumentClosePreparationResult.failed(message)
        let waiter = closeWaiter
        closeWaiter = nil
        waiter?.resume(returning: result)
        return result
    }

    private func normalizedRunLabel(_ label: String, fallback: String) -> String {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleanLabel.isEmpty ? fallback : cleanLabel).prefix(48))
    }

    private static let gracefulPausePrompt = """
    Codeness is pausing this document. Reach the nearest coherent stopping point as soon as practical. Do not begin another task. Leave the repository in a consistent state where possible, briefly state what is completed and what remains, then end this turn.
    """
}

private enum RepositoryCoordinatorError: LocalizedError {
    case documentNotLoaded
    case startOverWhileClosing
    case missingSession(AgentRole)
    case missingRun(UUID)
    case missingRunOutput(UUID)

    var errorDescription: String? {
        switch self {
        case .documentNotLoaded:
            "Repository state has not loaded; its saved data was left unchanged."
        case .startOverWhileClosing:
            "The repository window began closing before its activity could be reset."
        case .missingSession(let role):
            "The saved \(role.displayName.lowercased()) Codex session is missing. Its context was not replaced."
        case .missingRun(let id):
            "The saved resume checkpoint refers to missing run \(id.uuidString)."
        case .missingRunOutput(let id):
            "Run \(id.uuidString) has no completed output to route."
        }
    }
}

private extension PendingAction {
    var displayName: String {
        switch self {
        case .implement: "implementation"
        case .review: "review"
        case .fix: "review fixes"
        case .complete: "activity completion"
        }
    }
}
