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
    private let destructiveOverride: Bool?

    public init(value: JSONValue) {
        self.value = value
        destructiveOverride = nil
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

    public init(
        value: JSONValue,
        label: String,
        explanation: String,
        isDestructive: Bool = false
    ) {
        self.value = value
        self.label = label
        self.explanation = explanation
        destructiveOverride = isDestructive
    }

    public var id: String { value.encodedString() }

    public var isDestructive: Bool {
        destructiveOverride ?? (value.stringValue == "cancel")
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
    private struct GenericInteractionRoute {
        let providerID: AgentProviderID
        let runID: UUID
        let interactionID: String
    }

    private struct GenericSessionFallback {
        let cursor: WorkflowCursor
        let prompt: String
    }

    private struct LiveTeamSessionFallback {
        let checkpoint: LiveTeamCheckpoint
        let prompt: String
    }

    private struct ProviderSessionReference: Hashable {
        let providerID: AgentProviderID
        let sessionID: String
    }

    private struct TranscriptChunk: Sendable {
        let sequence: UInt64
        let text: String
        let utf8Count: Int
    }

    private final class PendingTranscriptBuffer {
        var chunks: [TranscriptChunk] = []
        var utf8Count = 0

        func append(_ chunk: TranscriptChunk) {
            chunks.append(chunk)
            utf8Count += chunk.utf8Count
        }

        func text(through sequence: UInt64? = nil) -> String {
            let selected = sequence.map { upperBound in
                chunks.prefix { $0.sequence <= upperBound }
            } ?? chunks[...]
            return selected.map(\.text).joined()
        }

        func consume(through sequence: UInt64) {
            guard let firstRemaining = chunks.firstIndex(where: {
                $0.sequence > sequence
            }) else {
                chunks.removeAll(keepingCapacity: true)
                utf8Count = 0
                return
            }
            let consumedBytes = chunks[..<firstRemaining].reduce(0) {
                $0 + $1.utf8Count
            }
            chunks.removeFirst(firstRemaining)
            utf8Count -= consumedBytes
        }
    }

    private struct TranscriptFlush {
        let id: UUID
        let lastSequence: UInt64
        let task: Task<Void, Error>
    }

    private struct WorkSummarySnapshot {
        let context: WorkSummaryContext
        let sourceSignature: String
    }

    static let maximumPresentedTranscriptUTF8Bytes = 4 * 1_024 * 1_024
    static let truncatedTranscriptMarker = "[Earlier transcript output remains available in the on-disk activity log.]\n"
    private static let transcriptFlushDelay: Duration = .milliseconds(25)
    private static let transcriptFlushByteThreshold = 256 * 1_024
    private static let transcriptFlushChunkThreshold = 1_024
    static let maximumPendingTranscriptUTF8Bytes = 8 * 1_024 * 1_024
    static let maximumPendingTranscriptChunkCount = 4_096
    static let maximumPendingInteractionCount = 64
    static let maximumPendingInteractionRetainedBytes = 4 * 1_024 * 1_024
    static let maximumTrackedDeltaItemCount = 2_048
    static let maximumTrackedDeltaItemRetainedBytes = 2 * 1_024 * 1_024
    private static let maximumRetiredTurnIDCount = 4_096

    public private(set) var record: RepositoryRecord
    public var selectedRunID: UUID? {
        didSet {
            guard isLoaded, selectedRunID != oldValue else { return }
            viewState.selectedRunID = selectedRunID
            viewState.runSelectionWasSaved = true
            scheduleViewStateSave()
            scheduleSelectedTranscriptLoad(previousRunID: oldValue)
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
    public private(set) var isGeneratingWorkOverviewSummary = false
    public private(set) var workOverviewSummaryError: String?
    public private(set) var transcriptFollowRequestRunID: UUID?
    public private(set) var transcriptFollowRequestRevision = 0

    func pendingTranscriptUTF8ByteCount(for runID: UUID) -> Int {
        pendingTranscriptBuffers[runID]?.utf8Count ?? 0
    }

    func pendingTranscriptChunkCount(for runID: UUID) -> Int {
        pendingTranscriptBuffers[runID]?.chunks.count ?? 0
    }

    func droppedTranscriptUTF8ByteCount(for runID: UUID) -> Int {
        droppedTranscriptUTF8Bytes[runID] ?? 0
    }

    func transcriptIsBackpressured(for runID: UUID) -> Bool {
        transcriptBackpressureRunIDs.contains(runID)
    }

    func trackedDeltaItemCount(for runID: UUID) -> Int {
        itemsWithDeltas[runID]?.count ?? 0
    }

    func hasTokenUsageBaseline(for runID: UUID) -> Bool {
        tokenUsageBaselines[runID] != nil
    }

    var interactionSafetyTerminationCount: Int {
        interactionSafetyTerminatingRunIDs.count
    }

    var transcriptBackpressureTerminationCount: Int {
        transcriptBackpressureRunIDs.count
    }

    var protocolContainmentIsActive: Bool {
        protocolContainment != nil
    }

    var legacyInterruptionDebtCount: Int {
        legacyInterruptionDebts.count
    }

    var legacyInterruptionWatchdogCount: Int {
        legacyInterruptionWatchdogs.count
    }

    private struct ProtocolContainment {
        let id: UUID
        var detail: String
    }

    private struct LegacyInterruptionKey: Hashable {
        let appServerGeneration: UInt64
        let threadID: String
        let turnID: String
    }

    private struct LegacyInterruptionDebt {
        enum State {
            case requestInFlight
            case requestFailed
            case awaitingTerminal
        }

        let runID: UUID
        let identity: UUID
        var attempts: Int
        var lastError: String
        var state: State
    }

    private let appServer: CodexAppServerClient
    private let router: any HandoffRouting
    private let handoffConfigurationValidator: any HandoffConfigurationValidating
    private let store: any RepositoryWorkspaceStoring
    private let agentProviders: AgentProviderRegistry?
    private let workflowRouter: (any WorkflowHandoffRouting)?
    private let liveTeamCoordinatorRouter: (any LiveTeamCoordinatorRouting)?
    private let liveTeamOverseerRouter: (any LiveTeamOverseerRouting)?
    private var liveTeamRuntimeConfiguration: LiveTeamRuntimeConfiguration?
    private let liveTeamRuntimeConfigurationProvider: (@MainActor @Sendable (
        RepositorySettings
    ) -> LiveTeamRuntimeConfiguration)?
    private var sessionsPrepared = false
    private var itemsWithDeltas: [UUID: Set<String>] = [:]
    private var deltaItemRetainedByteCounts: [UUID: Int] = [:]
    private var tokenUsageBaselines: [UUID: RunTokenUsage] = [:]
    private var runIsAtBottom: [UUID: Bool] = [:]
    private var followsActiveProgress = false
    private var completingRunIDs: Set<UUID> = []
    private var routingTasks: [UUID: Task<Void, Never>] = [:]
    private var viewStateSaveTask: Task<Void, Never>?
    private var transcriptLoadTask: Task<Void, Never>?
    private var hydratedTranscriptRunIDs: Set<UUID> = []
    private var nextTranscriptSequence: UInt64 = 0
    private var pendingTranscriptBuffers: [UUID: PendingTranscriptBuffer] = [:]
    private var visibleTranscriptChunks: [UUID: [TranscriptChunk]] = [:]
    private var visibleTranscriptUTF8ByteCounts: [UUID: Int] = [:]
    private var visibleTranscriptTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptHydrationIDs: [UUID: UUID] = [:]
    private var transcriptHydrationChunks: [UUID: [TranscriptChunk]] = [:]
    private var transcriptHydrationWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var scheduledTranscriptFlushTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptFlushes: [UUID: TranscriptFlush] = [:]
    private var transcriptFlushFailureRunIDs: Set<UUID> = []
    private var transcriptBackpressureRunIDs: Set<UUID> = []
    private var droppedTranscriptUTF8Bytes: [UUID: Int] = [:]
    private var transcriptBackpressureFailureDetails: [UUID: String] = [:]
    private(set) var transcriptPresentationMutationCount = 0
    private var workOverviewSummaryTask: Task<Void, Never>?
    private var workOverviewSummaryTaskSignature: String?
    @ObservationIgnored private var workSummarySnapshotCache: WorkSummarySnapshot?
    @ObservationIgnored private(set) var workSummarySnapshotBuildCount = 0
    private var closeWaiter: CheckedContinuation<DocumentClosePreparationResult, Never>?
    private var isClosing = false
    private var lifecycleGeneration = UUID()
    private var loadInProgressGeneration: UUID?
    private var loadQuiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingInteractions: [PendingServerInteraction] = []
    private var pendingInteractionRetainedByteCount = 0
    private var interactionResolutionInFlight = false
    private var claimedInteractionID: JSONValue?
    private var claimedInteractionRetainedByteCount = 0
    private var interactionResolutionClaimID: UUID?
    private var interactionSafetyTerminatingRunIDs: Set<UUID> = []
    private var protocolContainment: ProtocolContainment?
    private var legacyAppServerGeneration: UInt64 = 0
    private var legacyInterruptionDebts: [
        LegacyInterruptionKey: LegacyInterruptionDebt
    ] = [:]
    private var legacyInterruptionWatchdogs: [
        LegacyInterruptionKey: Task<Void, Never>
    ] = [:]
    private var legacyInterruptionRetryTasks: [
        LegacyInterruptionKey: Task<Void, Never>
    ] = [:]
    private let legacyInterruptionMaximumAttemptCount: Int
    private let legacyInterruptionRetryDelay: Duration
    private let legacyInterruptionTerminalTimeout: Duration
    private var retiredTurnIDs: Set<String> = []
    private var retiredTurnIDOrder: [String] = []
    private var genericRunTasks: [UUID: Task<Void, Never>] = [:]
    private var genericInteractionRoutes: [String: GenericInteractionRoute] = [:]
    private var genericSessionFallbacks: [UUID: GenericSessionFallback] = [:]
    private var liveTeamSessionFallbacks: [UUID: LiveTeamSessionFallback] = [:]
    private var liveTeamControlInvocationCount = 0
    private var providerLaunchLeases: [UUID: UUID] = [:]
    private var providerLaunchWaiters: [CheckedContinuation<Void, Never>] = []
    /// Sessions attached by this coordinator in the current app process.
    /// Persisted session IDs are resume handles, not proof of a live attachment.
    private var attachedProviderSessions: Set<ProviderSessionReference> = []
    private var providerSessionReleaseWaiters: [
        ProviderSessionReference: [CheckedContinuation<Bool, Never>]
    ] = [:]

    public init(
        canonicalPath: String,
        appServer: CodexAppServerClient,
        router: any HandoffRouting,
        store: any RepositoryWorkspaceStoring,
        handoffConfigurationValidator: any HandoffConfigurationValidating = HandoffConfigurationValidator(),
        initialSettings: RepositorySettings = .init(),
        agentProviders: AgentProviderRegistry? = nil,
        workflowRouter: (any WorkflowHandoffRouting)? = nil,
        liveTeamCoordinatorRouter: (any LiveTeamCoordinatorRouting)? = nil,
        liveTeamOverseerRouter: (any LiveTeamOverseerRouting)? = nil,
        liveTeamRuntimeConfiguration: LiveTeamRuntimeConfiguration? = nil,
        liveTeamRuntimeConfigurationProvider: (@MainActor @Sendable (
            RepositorySettings
        ) -> LiveTeamRuntimeConfiguration)? = nil,
        legacyInterruptionMaximumAttemptCount: Int = 3,
        legacyInterruptionRetryDelay: Duration = .milliseconds(250),
        legacyInterruptionTerminalTimeout: Duration = .seconds(2)
    ) {
        record = RepositoryRecord(canonicalPath: canonicalPath, settings: initialSettings)
        self.appServer = appServer
        self.router = router
        self.handoffConfigurationValidator = handoffConfigurationValidator
        self.store = store
        self.agentProviders = agentProviders
        self.workflowRouter = workflowRouter
        self.liveTeamCoordinatorRouter = liveTeamCoordinatorRouter
        self.liveTeamOverseerRouter = liveTeamOverseerRouter
        self.liveTeamRuntimeConfiguration = liveTeamRuntimeConfiguration
        self.liveTeamRuntimeConfigurationProvider = liveTeamRuntimeConfigurationProvider
        self.legacyInterruptionMaximumAttemptCount = max(
            1,
            legacyInterruptionMaximumAttemptCount
        )
        self.legacyInterruptionRetryDelay = max(
            .milliseconds(10),
            legacyInterruptionRetryDelay
        )
        self.legacyInterruptionTerminalTimeout = max(
            .milliseconds(10),
            legacyInterruptionTerminalTimeout
        )
    }

    public var repositoryName: String {
        URL(fileURLWithPath: record.canonicalPath).lastPathComponent
    }

    public var activity: ActivityRecord? { record.activity }

    public var liveTeamDefinition: LiveTeamDefinition? {
        record.activity?.liveTeam?.currentDefinition
    }

    public var pendingLiveTeamRevision: LiveTeamPendingRevision? {
        record.activity?.liveTeam?.pendingRevision
    }

    public var selectedRun: RunRecord? {
        guard let selectedRunID else { return nil }
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
        isLoaded
            && loadInProgressGeneration == nil
            && record.activity == nil
            && !isStartingActivity
            && !isStartingOver
            && !isClosing
    }

    /// Starting over creates a new activity only after the Overseer has completed
    /// the current goal. Paused work resumes from its durable checkpoint instead.
    public var canStartOver: Bool {
        guard isLoaded,
              loadInProgressGeneration == nil,
              record.activity?.status == .completed,
              !isStartingActivity,
              !isStartingOver,
              !isClosing,
              !pauseState.isInProgress,
              pendingInteractions.isEmpty,
              routingTasks.isEmpty,
              completingRunIDs.isEmpty,
              !hasUnconfirmedSafetyStop else { return false }
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
        guard let run = activeRun,
              (run.agentTarget?.providerID ?? .codex) == .codex else { return false }
        let status = run.status
        return [.queued, .running, .awaitingApproval].contains(status)
    }

    public var hasActiveAgentTurn: Bool {
        guard let status = activeRun?.status else { return false }
        return [.queued, .running, .awaitingApproval].contains(status)
    }

    public func hasActiveWork(for providerID: AgentProviderID) -> Bool {
        if let run = activeRun,
           [.queued, .running, .awaitingApproval].contains(run.status),
           (run.agentTarget?.providerID ?? .codex) == providerID {
            return true
        }
        if let liveTeam = record.activity?.liveTeam {
            let usesCoordinator = liveTeam.currentDefinition?.coordinator.target.providerID
                == providerID
            let usesOverseer = liveTeam.overseer.target.providerID == providerID
            return (usesCoordinator || usesOverseer)
                && (!routingTasks.isEmpty || workOverviewSummaryTask != nil)
        }
        guard let workflow = record.activity?.workflow,
              workflow.coordinator.target.providerID == providerID else { return false }
        return !routingTasks.isEmpty || workOverviewSummaryTask != nil
    }

    public var canResume: Bool {
        guard loadInProgressGeneration == nil,
              !hasUnconfirmedSafetyStop,
              let activity = activeActivity,
              activity.status == .paused else { return false }
        if requiresLegacyConversion { return true }
        if let liveTeam = activity.liveTeam {
            if liveTeam.resumeCheckpoint != nil { return true }
            guard let run = activity.runs.last else {
                return liveTeam.checkpoint != nil || liveTeam.currentDefinition == nil
            }
            if run.status == .interrupted { return true }
            guard run.finalOutput?.isEmpty == false else { return false }
            return run.status == .routing
                || (run.status == .paused && run.relayError != nil)
        }
        if activity.workflow != nil {
            if activity.workflowResumeCheckpoint != nil { return true }
            guard let run = activity.runs.last else { return activity.workflowCursor != nil }
            if run.status == .interrupted { return true }
            guard run.finalOutput?.isEmpty == false else { return false }
            return run.status == .routing || (run.status == .paused && run.relayError != nil)
        }
        if activity.resumeCheckpoint != nil { return true }
        if activity.pendingAction != nil { return true }
        guard let run = activity.runs.last else { return false }
        if run.status == .interrupted { return true }
        guard run.finalOutput?.isEmpty == false else { return false }
        return run.status == .routing || (run.status == .paused && run.relayError != nil)
    }

    public func canRestartWorkflowStep(_ runID: UUID) -> Bool {
        guard !hasUnconfirmedSafetyStop else { return false }
        guard !requiresLegacyConversion else { return false }
        if let activity = record.activity,
           activity.status == .paused,
           case .recoverRun(let checkpointRunID)? = activity.liveTeam?.resumeCheckpoint,
           checkpointRunID == runID,
           let run = activity.runs.first(where: { $0.id == runID }),
           run.liveTeamMember != nil,
           [.failed, .interrupted].contains(run.status) {
            return true
        }
        return restartableWorkflowContext(for: runID) != nil
    }

    private var hasUnconfirmedSafetyStop: Bool {
        protocolContainment != nil
            || !interactionSafetyTerminatingRunIDs.isEmpty
            || !transcriptBackpressureRunIDs.isEmpty
    }

    public var canAmendGoal: Bool {
        isLoaded
            && loadInProgressGeneration == nil
            && record.activity != nil
            && !isStartingActivity
            && !isStartingOver
            && !isClosing
    }

    public var requiresLegacyConversion: Bool {
        record.activity?.workflow != nil
            && record.activity?.liveTeam == nil
            && liveTeamOverseerRouter != nil
            && liveTeamRuntimeConfiguration != nil
    }

    public var goalForAmendment: String {
        record.activity?.pendingGoalAmendment?.revisedGoal
            ?? record.activity?.goal
            ?? ""
    }

    public var goalAmendmentWillBeDeferred: Bool {
        record.activity?.status == .running
    }

    public var hasPendingGoalAmendment: Bool {
        record.activity?.pendingGoalAmendment != nil
    }

    public var runDetailPresentation: RunDetailPresentation {
        viewState.detailPresentation ?? .split
    }

    public var workOverviewSummarySourceSignature: String? {
        workSummarySnapshot?.sourceSignature
    }

    public var workOverviewSummaryText: String? {
        guard let signature = workOverviewSummarySourceSignature,
              viewState.workOverviewSummary?.sourceSignature == signature else { return nil }
        return viewState.workOverviewSummary?.text
    }

    public var workOverviewSummaryGeneratedAt: Date? {
        guard workOverviewSummaryText != nil else { return nil }
        return viewState.workOverviewSummary?.generatedAt
    }

    public var hasWorkOverviewSummarySource: Bool {
        workOverviewSummarySourceSignature != nil
    }

    public var requiresCloseConfirmation: Bool {
        activeActivity?.status == .running
    }

    public func load() async {
        guard !isLoaded, !isClosing else { return }
        if loadInProgressGeneration != nil {
            // Multiple lifecycle surfaces can request the initial load (for
            // example, the window controller and a caller awaiting readiness).
            // An awaited load must not return while that shared operation is
            // still in flight, or the caller can observe a false `isLoaded`
            // state and silently discard its next action.
            await waitForLoadQuiescence()
            return
        }
        let generation = lifecycleGeneration
        loadInProgressGeneration = generation
        defer { finishLoad(generation: generation) }
        errorMessage = nil
        do {
            let loadedRecord = try await store.load(
                canonicalPath: record.canonicalPath,
                defaultSettings: record.settings
            )
            guard isCurrentLoad(generation) else { return }
            let loadedViewState = (try? await store.loadViewState(
                canonicalPath: loadedRecord.canonicalPath
            ))
                ?? RepositoryViewState()
            guard isCurrentLoad(generation) else { return }

            cancelWorkOverviewSummaryRequest()
            record = loadedRecord
            if let liveTeamRuntimeConfigurationProvider {
                liveTeamRuntimeConfiguration = liveTeamRuntimeConfigurationProvider(
                    loadedRecord.settings
                )
            }
            viewState = loadedViewState
            normalizeLiveTeamProductLanguageIfNeeded()
            pauseAfterCurrent = viewState.pauseAfterCurrent
            runIsAtBottom = viewState.transcriptViewports.mapValues(\.followsOutput)
            if viewState.runSelectionWasSaved {
                if let restoredRunID = viewState.selectedRunID,
                   record.activity?.runs.contains(where: { $0.id == restoredRunID }) == true {
                    selectedRunID = restoredRunID
                } else {
                    selectedRunID = nil
                    viewState.selectedRunID = nil
                }
            } else {
                selectedRunID = record.activity?.runs.last?.id
                viewState.selectedRunID = selectedRunID
                viewState.runSelectionWasSaved = true
            }
            guard await recoverAppendOnlyTokenUsage(loadGeneration: generation),
                  isCurrentLoad(generation) else { return }
            try await recoverOperationalRunPayloads(loadGeneration: generation)
            guard isCurrentLoad(generation) else { return }
            if record.activity?.liveTeam != nil {
                recoverInterruptedLiveTeamState()
                if record.activity?.liveTeam?.pendingRevision != nil {
                    _ = await activatePendingLiveTeamRevision()
                }
                repairCoordinatorPauseAuthorityIfNeeded()
                repairAutonomousDirectionPauseIfNeeded()
            } else if record.activity?.workflow != nil {
                recoverInterruptedGenericState()
            } else {
                recoverInterruptedState()
                migrateResumeCheckpointIfNeeded()
            }
            await recoverAppendOnlyTranscript(
                runID: selectedRunID,
                loadGeneration: generation
            )
            guard isCurrentLoad(generation) else { return }
            repairCompletedPlanTurnIfNeeded()
            evictTranscripts(except: selectedRunID)
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
                guard isCurrentLoad(generation) else { return }
                try await persistDocumentState()
                guard isCurrentLoad(generation) else { return }
            } catch {
                guard isCurrentLoad(generation) else { return }
                // Loading succeeded; keep the real record active even if recovery/view
                // state cannot be written back yet.
                errorMessage = "Repository history loaded, but its recovered state could not be saved: \(error.localizedDescription)"
            }
            if record.activity?.workflow != nil,
               record.activity?.liveTeam == nil,
               let status = record.activity?.status,
               ![.completed, .cancelled].contains(status) {
                await convertLegacyWorkflowNow()
            }
        } catch {
            guard isCurrentLoad(generation) else { return }
            errorMessage = error.localizedDescription
            statusMessage = "Could not load repository history"
        }
    }

    private func isCurrentLoad(_ generation: UUID) -> Bool {
        lifecycleGeneration == generation
            && loadInProgressGeneration == generation
            && !Task.isCancelled
    }

    private func finishLoad(generation: UUID) {
        guard loadInProgressGeneration == generation else { return }
        loadInProgressGeneration = nil
        let waiters = loadQuiescenceWaiters
        loadQuiescenceWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private func invalidateLoadGeneration() {
        lifecycleGeneration = UUID()
    }

    private func waitForLoadQuiescence() async {
        guard loadInProgressGeneration != nil else { return }
        await withCheckedContinuation { continuation in
            if loadInProgressGeneration == nil {
                continuation.resume()
            } else {
                loadQuiescenceWaiters.append(continuation)
            }
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
            cancelWorkOverviewSummaryRequest()
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
            guard !isClosing else { return }
            errorMessage = error.localizedDescription
            statusMessage = "Could not start activity"
        }
    }

    public func startActivity(goal: String, workflow: WorkflowTemplate) async {
        guard canStartActivity else { return }
        guard let agentProviders, workflowRouter != nil else {
            errorMessage = "The agent providers are not configured."
            return
        }
        _ = agentProviders
        let cleanGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGoal.isEmpty else {
            errorMessage = "The goal is empty."
            return
        }
        if let validationMessage = workflow.validationMessage {
            errorMessage = validationMessage
            return
        }
        guard let cursor = GenericWorkflowStateMachine.initialCursor(for: workflow) else {
            errorMessage = "The workflow has no runnable steps."
            return
        }

        isStartingActivity = true
        defer { isStartingActivity = false }
        cancelWorkOverviewSummaryRequest()
        record.activityDraft = nil
        record.activity = ActivityRecord(
            goal: cleanGoal,
            prompts: .builtInDefaults,
            workflow: workflow,
            workflowCursor: cursor,
            workflowResumeCheckpoint: .perform(cursor)
        )
        pauseAfterCurrent = false
        viewState.pauseAfterCurrent = false
        scheduleViewStateSave()
        errorMessage = nil

        do {
            try await persist()
        } catch {
            record.activity?.status = .paused
            statusMessage = "Paused before \(genericStepName(at: cursor).lowercased())"
            do {
                try await persist()
                errorMessage = "Could not save the new activity before starting its first step: \(error.localizedDescription)"
            } catch {
                errorMessage = "Could not save the new activity or its paused retry checkpoint: \(error.localizedDescription)"
            }
            return
        }
        await performGeneric(cursor: cursor, previousHandoff: nil)
    }

    /// Starts the live-team product path. The activity is saved in a goal-only
    /// state before the fresh Overseer invocation, and revision 1 is saved again
    /// before Codeness prepares any worker session.
    public func startActivity(goal: String) async {
        guard canStartActivity else { return }
        if let liveTeamRuntimeConfigurationProvider {
            liveTeamRuntimeConfiguration = liveTeamRuntimeConfigurationProvider(record.settings)
        }
        guard agentProviders != nil,
              liveTeamCoordinatorRouter != nil,
              liveTeamOverseerRouter != nil,
              let runtime = liveTeamRuntimeConfiguration else {
            errorMessage = "The agents are not configured."
            return
        }
        let cleanGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGoal.isEmpty else {
            errorMessage = "The user goal is empty."
            return
        }
        guard runtime.validationMessage == nil else {
            errorMessage = runtime.validationMessage
                ?? "Codeness has no valid agent targets."
            return
        }

        isStartingActivity = true
        defer { isStartingActivity = false }
        cancelWorkOverviewSummaryRequest()
        let request = LiveTeamOverseerRequest(
            mode: .bootstrap,
            reason: "Create the first working goal and agents for the user's goal.",
            automatic: false
        )
        record.activityDraft = nil
        record.activity = ActivityRecord(
            goal: cleanGoal,
            prompts: .builtInDefaults,
            liveTeam: LiveTeamState(
                overseer: runtime.bootstrapOverseerConfiguration(for: cleanGoal),
                resumeCheckpoint: .invokeOverseer(request)
            )
        )
        pauseAfterCurrent = false
        viewState.pauseAfterCurrent = false
        scheduleViewStateSave()
        errorMessage = nil
        statusMessage = "Saving the goal…"

        do {
            try await persist()
        } catch {
            record.activity?.status = .paused
            statusMessage = "Paused before preparing agents"
            do {
                try await persist()
                errorMessage = "Could not save the goal before Codeness prepared the agents: \(error.localizedDescription)"
            } catch {
                errorMessage = "Could not save the goal or its retry point: \(error.localizedDescription)"
            }
            return
        }
        await invokeLiveTeamOverseer(request)
    }

    public func handle(_ event: AppServerEvent) async {
        if protocolContainment != nil {
            if case .exited = event {
                await appServerRestarted()
            }
            // Once turn identity is ambiguous, no request or notification from
            // that generation is trustworthy enough to mutate document state.
            return
        }
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
            await presentInteraction(id: id, method: method, params: params)
            try? await persist()
        case .notification(let method, let params, let rawLine):
            await appendRawLine(rawLine, event: event)
            await handleNotification(method: method, params: params, event: event)
        case .standardError, .exited:
            break
        }
    }

    public func acceptsCodexEvent(_ event: AppServerEvent) -> Bool {
        if protocolContainment != nil {
            if case .exited = event { return true }
            return false
        }
        guard record.activity?.workflow == nil,
              record.activity?.liveTeam == nil else { return false }
        if case .notification(let method, let params, _) = event,
           method == "serverRequest/resolved",
           let requestID = params["requestId"] {
            return pendingInteractions.contains { $0.id == requestID }
        }
        return belongsToRepository(event)
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

    public func updateActivityDraft(goal: String, workflow: WorkflowTemplate) {
        guard isLoaded, record.activity == nil, !isStartingActivity, !isStartingOver else { return }
        let draft = ActivityConfigurationDraft(
            goal: goal,
            prompts: .builtInDefaults,
            workflow: workflow
        )
        guard record.activityDraft != draft else { return }
        record.activityDraft = draft
    }

    public func updateActivityDraft(goal: String) {
        guard isLoaded, record.activity == nil, !isStartingActivity, !isStartingOver else { return }
        let draft = ActivityConfigurationDraft(
            goal: goal,
            prompts: .builtInDefaults,
            workflow: nil
        )
        guard record.activityDraft != draft else { return }
        record.activityDraft = draft
    }

    public func selectLiveRun() {
        guard let liveRunID else { return }
        focusActiveProgress(on: liveRunID)
    }

    public func selectRun(_ runID: UUID?) {
        followsActiveProgress = false
        selectedRunID = runID
    }

    public func stopFollowingActiveProgress(for runID: UUID) {
        guard selectedRunID == runID else { return }
        followsActiveProgress = false
        runIsAtBottom[runID] = false
        var viewport = viewState.transcriptViewports[runID] ?? TranscriptViewportState()
        viewport.followsOutput = false
        viewState.transcriptViewports[runID] = viewport
        scheduleViewStateSave()
    }

    private func focusActiveProgress(on requestedRunID: UUID? = nil) {
        guard let runID = requestedRunID
            ?? liveRunID
            ?? record.activity?.runs.last?.id else { return }

        followsActiveProgress = true
        runIsAtBottom[runID] = true
        var viewport = viewState.transcriptViewports[runID] ?? TranscriptViewportState()
        viewport.followsOutput = true
        viewState.transcriptViewports[runID] = viewport
        selectedRunID = runID
        transcriptFollowRequestRunID = runID
        transcriptFollowRequestRevision &+= 1
        scheduleViewStateSave()
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
        var changed = false
        if let width {
            let width = min(max(width, 220), 430)
            if viewState.sidebarWidth.map({ abs($0 - width) >= 0.5 }) != false {
                viewState.sidebarWidth = width
                changed = true
            }
        }
        if viewState.sidebarVisible != isVisible {
            viewState.sidebarVisible = isVisible
            changed = true
        }
        guard changed else { return }
        scheduleViewStateSave()
    }

    public func updateRunDetailPresentation(_ presentation: RunDetailPresentation) {
        guard viewState.detailPresentation != presentation else { return }
        viewState.detailPresentation = presentation
        scheduleViewStateSave()
    }

    public func updateRunDetailSplitFraction(_ fraction: Double) {
        let fraction = min(max(fraction, 0.15), 0.85)
        guard viewState.detailSplitFraction != fraction else { return }
        viewState.detailSplitFraction = fraction
        scheduleViewStateSave()
    }

    public func requestWorkOverviewSummary(force: Bool = false) {
        guard !isClosing, let snapshot = workSummarySnapshot else {
            workOverviewSummaryError = nil
            return
        }
        let context = snapshot.context
        let signature = snapshot.sourceSignature
        if !force, viewState.workOverviewSummary?.sourceSignature == signature {
            workOverviewSummaryError = nil
            return
        }
        if !force,
           workOverviewSummaryTask != nil,
           workOverviewSummaryTaskSignature == signature {
            return
        }

        workOverviewSummaryTask?.cancel()
        workOverviewSummaryTaskSignature = signature
        isGeneratingWorkOverviewSummary = true
        workOverviewSummaryError = nil
        let router = self.router
        let workflowRouter = self.workflowRouter
        let workflowCoordinator = record.activity?.workflow?.coordinator
        let liveTeamRouter = self.liveTeamCoordinatorRouter
        let liveTeamCoordinator = record.activity?.liveTeam?.currentDefinition?.coordinator
        let settings = record.settings.relay
        let store = self.store
        let canonicalPath = record.canonicalPath

        workOverviewSummaryTask = Task { @MainActor [weak self] in
            do {
                let text: String
                if let liveTeamCoordinator {
                    guard let liveTeamRouter else {
                        throw AgentProviderError.invalidResponse(
                            "work routing is unavailable"
                        )
                    }
                    text = try await liveTeamRouter.summarizeWork(
                        context,
                        configuration: liveTeamCoordinator,
                        cwd: canonicalPath
                    )
                } else if let workflowCoordinator {
                    guard let workflowRouter else {
                        throw AgentProviderError.invalidResponse(
                            "the configured work router is unavailable"
                        )
                    }
                    text = try await workflowRouter.summarizeWork(
                        context,
                        configuration: workflowCoordinator,
                        cwd: canonicalPath
                    )
                } else {
                    text = try await router.summarizeWork(context, settings: settings)
                }
                try Task.checkCancellation()
                if let self,
                   self.workSummarySnapshot?.sourceSignature == signature,
                   self.workOverviewSummaryTaskSignature == signature {
                    self.viewState.workOverviewSummary = WorkOverviewSummaryCache(
                        sourceSignature: signature,
                        text: LiveTeamProductLanguage.workSummary(text)
                    )
                    try? await store.saveViewState(
                        self.viewState,
                        canonicalPath: canonicalPath
                    )
                }
            } catch is CancellationError {
                // A newer set of handoffs superseded this request.
            } catch {
                if let self,
                   self.workSummarySnapshot?.sourceSignature == signature,
                   self.workOverviewSummaryTaskSignature == signature {
                    self.workOverviewSummaryError = error.localizedDescription
                }
            }

            guard let self,
                  self.workOverviewSummaryTaskSignature == signature else { return }
            self.isGeneratingWorkOverviewSummary = false
            self.workOverviewSummaryTaskSignature = nil
            self.workOverviewSummaryTask = nil
        }
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
        guard record.activity?.status == .paused,
              !hasUnconfirmedSafetyStop else { return }
        focusActiveProgress()
        if requiresLegacyConversion {
            await convertLegacyWorkflowNow()
            guard record.activity?.liveTeam != nil else { return }
            await resumeLiveTeam()
            return
        }
        if record.activity?.liveTeam != nil {
            await resumeLiveTeam()
            return
        }
        if record.activity?.workflow != nil {
            await resumeGeneric()
            return
        }
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
                try await ensureSessions(
                    allowRecreate: record.requiresFreshProviderSessions
                )
                record.activity?.status = .running
                record.activity?.pendingAction = nil
                await perform(action: action, handoff: record.activity?.runs.last(where: { $0.handoff != nil })?.handoff)
            } catch {
                guard !isClosing else { return }
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
        if let run = activeRun, let target = run.agentTarget {
            guard let agentProviders else { return }
            focusActiveProgress(on: run.id)
            do {
                try await agentProviders.interrupt(providerID: target.providerID, runID: run.id)
                statusMessage = "Stopping \(run.displayName.lowercased())…"
            } catch {
                if canInterrupt {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        guard let run = activeRun, let threadID = run.threadID, let turnID = run.turnID else { return }
        focusActiveProgress(on: run.id)
        do {
            try await interruptLegacyTurn(
                runID: run.id,
                threadID: threadID,
                turnID: turnID
            )
            statusMessage = "Stopping " + run.kind.displayName.lowercased() + "…"
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
        // A cancelled SwiftUI `.task` is not a completion barrier for an actor
        // store operation. Let the mounted document's initial load finish and wait
        // for it before close/export is allowed to inspect or replace the workspace.
        await waitForLoadQuiescence()
        // A failed or defensively invalidated load is not an active document.
        guard isLoaded else {
            return await finishCloseWithoutActiveTurn()
        }
        await cancelRoutingTasks()
        await waitForProviderLaunches()
        if let containment = protocolContainment {
            return failClose(
                "\(containment.detail) The document remains open until App Server termination is confirmed."
            )
        }
        if hasUnconfirmedSafetyStop {
            return await prepareSafetyStoppedRunsForClose()
        }
        if record.activity?.liveTeam != nil {
            return await prepareLiveTeamForClose(strategy: strategy)
        }
        if record.activity?.workflow != nil {
            return await prepareGenericWorkflowForClose(strategy: strategy)
        }

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
                    statusMessage = "Stopping " + run.kind.displayName.lowercased() + "…"
                    try await interruptLegacyTurn(
                        runID: run.id,
                        threadID: threadID,
                        turnID: turnID
                    )
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
              let run = activeRun else { return }
        if let target = run.agentTarget {
            guard let agentProviders else { return }
            do {
                pauseState = .interrupting
                statusMessage = "Stopping \(run.displayName.lowercased())…"
                try await agentProviders.interrupt(providerID: target.providerID, runID: run.id)
            } catch {
                _ = await reconcileCloseControlFailure(error.localizedDescription)
            }
            return
        }
        guard let threadID = run.threadID,
              let turnID = run.turnID else { return }
        do {
            pauseState = .interrupting
            statusMessage = "Stopping " + run.kind.displayName.lowercased() + "…"
            try await interruptLegacyTurn(
                runID: run.id,
                threadID: threadID,
                turnID: turnID
            )
        } catch {
            _ = await reconcileCloseControlFailure(error.localizedDescription)
        }
    }

    public func documentDidClose() {
        isClosing = true
        invalidateLoadGeneration()
        clearAllLegacyInterruptionDebts(advanceGeneration: false)
        viewStateSaveTask?.cancel()
        viewStateSaveTask = nil
        transcriptLoadTask?.cancel()
        transcriptLoadTask = nil
        visibleTranscriptTasks.values.forEach { $0.cancel() }
        visibleTranscriptTasks.removeAll()
        visibleTranscriptChunks.removeAll()
        visibleTranscriptUTF8ByteCounts.removeAll()
        scheduledTranscriptFlushTasks.values.forEach { $0.cancel() }
        scheduledTranscriptFlushTasks.removeAll()
        transcriptFlushFailureRunIDs.removeAll()
        transcriptBackpressureRunIDs.removeAll()
        droppedTranscriptUTF8Bytes.removeAll()
        transcriptBackpressureFailureDetails.removeAll()
        cancelWorkOverviewSummaryRequest()
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
        guard let run = activeRun else { return false }
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMessage.isEmpty else { return false }
        focusActiveProgress(on: run.id)
        if let target = run.agentTarget {
            guard let agentProviders else { return false }
            do {
                try await agentProviders.steer(
                    providerID: target.providerID,
                    runID: run.id,
                    message: cleanMessage
                )
                await recordTranscript(
                    RunTranscriptPresentation.storedSteeringMessage(cleanMessage),
                    runID: run.id
                )
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        guard let threadID = run.threadID, let turnID = run.turnID else { return false }
        do {
            try await appServer.steer(threadID: threadID, turnID: turnID, message: cleanMessage)
            await recordTranscript(
                RunTranscriptPresentation.storedSteeringMessage(cleanMessage),
                runID: run.id
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func resolveApproval(_ decision: ApprovalDecision) async {
        guard let claim = claimPendingInteractionForResolution() else { return }
        let interaction = claim.interaction
        let route = claim.route
        focusActiveProgress(on: claim.runID)
        if let route {
            await resolveGenericInteraction(
                route,
                claimID: claim.claimID,
                resolution: .decision(decision.value)
            )
            return
        }
        do {
            try await appServer.respond(
                to: interaction.id,
                result: .object(["decision": decision.value])
            )
        } catch {
            await failClaimedInteraction(
                claimID: claim.claimID,
                runID: claim.runID,
                detail: "Could not send the Codex approval response: \(error.localizedDescription)"
            )
        }
        await completeInteractionResolutionClaim(claimID: claim.claimID)
    }

    public func resolveQuestions(_ answers: [String: [String]]) async {
        guard let claim = claimPendingInteractionForResolution() else { return }
        let interaction = claim.interaction
        let route = claim.route
        focusActiveProgress(on: claim.runID)
        if let route {
            await resolveGenericInteraction(
                route,
                claimID: claim.claimID,
                resolution: .answers(answers)
            )
            return
        }
        let values = answers.mapValues { answer in
            JSONValue.object(["answers": .array(answer.map(JSONValue.string))])
        }
        do {
            try await appServer.respond(to: interaction.id, result: .object(["answers": .object(values)]))
        } catch {
            await failClaimedInteraction(
                claimID: claim.claimID,
                runID: claim.runID,
                detail: "Could not send the Codex answer response: \(error.localizedDescription)"
            )
        }
        await completeInteractionResolutionClaim(claimID: claim.claimID)
    }

    public func resolveRawInteraction(_ resultText: String) async {
        guard let interaction = pendingInteraction else { return }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: Data(resultText.utf8))
        } catch {
            errorMessage = "The response is not valid JSON: \(error.localizedDescription)"
            return
        }
        guard let claim = claimPendingInteractionForResolution(
            expectedID: interaction.id
        ) else { return }
        let route = claim.route
        focusActiveProgress(on: claim.runID)
        if let route {
            await resolveGenericInteraction(
                route,
                claimID: claim.claimID,
                resolution: .raw(value)
            )
            return
        }
        do {
            try await appServer.respond(to: interaction.id, result: value)
        } catch {
            await failClaimedInteraction(
                claimID: claim.claimID,
                runID: claim.runID,
                detail: "Could not send the Codex JSON response: \(error.localizedDescription)"
            )
        }
        await completeInteractionResolutionClaim(claimID: claim.claimID)
    }

    public func cancelInteraction() async {
        guard let claim = claimPendingInteractionForResolution() else { return }
        let interaction = claim.interaction
        let route = claim.route
        focusActiveProgress(on: claim.runID)
        if let route {
            await resolveGenericInteraction(
                route,
                claimID: claim.claimID,
                resolution: .cancel
            )
            return
        }
        do {
            try await appServer.respondWithError(to: interaction.id, message: "Cancelled by the user")
        } catch {
            await failClaimedInteraction(
                claimID: claim.claimID,
                runID: claim.runID,
                detail: "Could not send the Codex cancellation response: \(error.localizedDescription)"
            )
        }
        await completeInteractionResolutionClaim(claimID: claim.claimID)
    }

    public func restartWorkflowStep(_ runID: UUID) async {
        guard !hasUnconfirmedSafetyStop else {
            errorMessage = "Wait until the stopped provider turn confirms termination before restarting this workflow step."
            return
        }
        if canRestartLiveTeamRun(runID) {
            await restartLiveTeamRun(runID)
            return
        }
        guard var context = restartableWorkflowContext(for: runID) else {
            errorMessage = "Only the current failed or stopped workflow step can be restarted."
            return
        }
        guard agentProviders != nil, workflowRouter != nil else {
            errorMessage = "The agent providers are not configured."
            return
        }
        focusActiveProgress(on: runID)

        let previousActivity = context.activity
        let previousPauseAfterCurrent = pauseAfterCurrent
        let previousViewPauseAfterCurrent = viewState.pauseAfterCurrent
        let interruptedRun = context.activity.runs[context.runIndex]
        let supersededSession = context.activity.stepSessions[context.step.id]
            .flatMap { session in
                session.providerSessionID.map {
                    ProviderSessionReference(
                        providerID: session.target.providerID,
                        sessionID: $0
                    )
                }
            }
            ?? interruptedRun.threadID.map {
                ProviderSessionReference(
                    providerID: context.step.target.providerID,
                    sessionID: $0
                )
            }
        let previousHandoff = context.activity.runs[..<context.runIndex]
            .last(where: { $0.workflowHandoff != nil })?
            .workflowHandoff

        var session = context.activity.stepSessions[context.step.id]
            ?? WorkflowSessionState(
                stepID: context.step.id,
                lineage: (interruptedRun.sessionLineage ?? 1) + 1,
                target: context.step.target
            )
        if session.lineage <= (interruptedRun.sessionLineage ?? 0) {
            session.lineage = (interruptedRun.sessionLineage ?? session.lineage) + 1
        }
        session.target = context.step.target
        session.providerSessionID = nil
        context.activity.stepSessions[context.step.id] = session
        context.activity.workflowResumeCheckpoint = .perform(context.cursor)
        record.activity = context.activity
        pauseAfterCurrent = false
        viewState.pauseAfterCurrent = false
        scheduleViewStateSave()
        errorMessage = nil
        statusMessage = "Restarting \(context.step.name.lowercased()) in a fresh session…"

        do {
            try await persist()
        } catch {
            record.activity = previousActivity
            pauseAfterCurrent = previousPauseAfterCurrent
            viewState.pauseAfterCurrent = previousViewPauseAfterCurrent
            scheduleViewStateSave()
            errorMessage = "Could not save the fresh step restart: \(error.localizedDescription)"
            statusMessage = pausedStatusMessage
            return
        }

        if let supersededSession {
            await releaseProviderSessions([supersededSession])
        }

        let stepPrompt = GenericPromptBuilder.stepPrompt(
            goal: context.activity.goal,
            workflow: context.workflow,
            step: context.step,
            cursor: context.cursor,
            previousHandoff: previousHandoff
        )
        let restartPrompt = """
        FRESH STEP RESTART

        This step is being rerun in a new provider session because the previous attempt did not \
        finish cleanly. The previous run remains in history and may have partially changed the \
        repository. Inspect the current repository state before editing. Do not assume either that \
        nothing ran or that prior edits are correct. Treat the current step instruction and latest \
        completed handoff below as scope authority.

        \(stepPrompt)
        """
        await performGeneric(
            cursor: context.cursor,
            previousHandoff: previousHandoff,
            promptOverride: restartPrompt
        )
    }

    private func canRestartLiveTeamRun(_ runID: UUID) -> Bool {
        guard let activity = record.activity,
              activity.status == .paused,
              case .recoverRun(let checkpointRunID)? = activity.liveTeam?.resumeCheckpoint,
              checkpointRunID == runID,
              let run = activity.runs.first(where: { $0.id == runID }),
              run.liveTeamMember != nil,
              [.failed, .interrupted].contains(run.status) else { return false }
        return true
    }

    private func restartLiveTeamRun(_ runID: UUID) async {
        guard let run = run(withID: runID),
              let snapshot = run.liveTeamMember,
              canRestartLiveTeamRun(runID) else { return }
        let previousActivity = record.activity
        let previousPause = pauseAfterCurrent
        let slotID = snapshot.sessionSlotID
        var session = record.activity?.stepSessions[slotID]
            ?? WorkflowSessionState(
                stepID: slotID,
                lineage: (run.sessionLineage ?? 1) + 1,
                target: snapshot.member.target
            )
        let superseded = session.providerSessionID.map {
            ProviderSessionReference(
                providerID: session.target.providerID,
                sessionID: $0
            )
        }
        session.lineage = max(session.lineage, run.sessionLineage ?? 0) + 1
        session.providerSessionID = nil
        session.target = snapshot.member.target
        record.activity?.stepSessions[slotID] = session
        let checkpoint = LiveTeamCheckpoint(
            memberID: snapshot.member.id,
            cycle: snapshot.cycle,
            revision: snapshot.revision
        )
        record.activity?.status = .running
        record.activity?.liveTeam?.checkpoint = checkpoint
        record.activity?.liveTeam?.resumeCheckpoint = .perform(checkpoint)
        pauseAfterCurrent = false
        viewState.pauseAfterCurrent = false
        scheduleViewStateSave()
        statusMessage = "Restarting \(snapshot.member.name.lowercased()) in a fresh session…"
        do {
            try await persist()
        } catch {
            record.activity = previousActivity
            pauseAfterCurrent = previousPause
            viewState.pauseAfterCurrent = previousPause
            scheduleViewStateSave()
            errorMessage = "Could not save the fresh agent turn: \(error.localizedDescription)"
            return
        }
        if let superseded {
            await releaseProviderSessions([superseded])
        }
        let prompt = """
        FRESH MEMBER RESTART

        The previous attempt did not finish cleanly. Its run remains in history and may have partially changed the repository. Inspect current state before editing and recover the exact immutable assignment below in a new provider session.

        \(LiveTeamPromptBuilder.memberPrompt(
            snapshot: snapshot,
            handoff: record.activity?.liveTeam?.coordinatorHandoff
        ))
        """
        await performLiveTeam(
            checkpoint: checkpoint,
            promptOverride: prompt,
            snapshotOverride: snapshot,
            allowsSessionFallback: false
        )
    }

    public func retryWorkflowStep(_ runID: UUID) async {
        guard var context = restartableWorkflowContext(for: runID),
              case .routeCompletedRun(let checkpointRunID)? =
                context.activity.workflowResumeCheckpoint,
              checkpointRunID == runID else {
            errorMessage = "Only the current blocked workflow step can be tried again."
            return
        }
        guard agentProviders != nil, workflowRouter != nil else {
            errorMessage = "The agent providers are not configured."
            return
        }
        focusActiveProgress(on: runID)

        let previousActivity = context.activity
        let previousPauseAfterCurrent = pauseAfterCurrent
        let previousViewPauseAfterCurrent = viewState.pauseAfterCurrent
        let blockedRun = context.activity.runs[context.runIndex]
        let previousHandoff = context.activity.runs[..<context.runIndex]
            .last(where: { $0.workflowHandoff != nil })?
            .workflowHandoff

        context.activity.workflowResumeCheckpoint = .perform(context.cursor)
        record.activity = context.activity
        pauseAfterCurrent = false
        viewState.pauseAfterCurrent = false
        scheduleViewStateSave()
        errorMessage = nil
        statusMessage = "Trying \(context.step.name.lowercased()) again…"

        do {
            try await persist()
        } catch {
            record.activity = previousActivity
            pauseAfterCurrent = previousPauseAfterCurrent
            viewState.pauseAfterCurrent = previousViewPauseAfterCurrent
            scheduleViewStateSave()
            errorMessage = "Could not save the step retry: \(error.localizedDescription)"
            statusMessage = pausedStatusMessage
            return
        }

        let stepPrompt = GenericPromptBuilder.stepPrompt(
            goal: context.activity.goal,
            workflow: context.workflow,
            step: context.step,
            cursor: context.cursor,
            previousHandoff: previousHandoff
        )
        let previousResult = blockedRun.workflowHandoff?.text
            ?? blockedRun.finalOutput
            ?? blockedRun.relayError
            ?? "The previous attempt did not provide a result."
        let retryPrompt = """
        RETRY CURRENT STEP

        The previous attempt completed with a \(blockedRun.workflowHandoff?.outcome.displayName.lowercased() ?? "non-continuing") workflow outcome, and the user chose Try Again. Reassess the blocker against the current repository and external state, then continue the same step if it is now possible. Do not merely repeat the previous result. The previous result below is diagnostic context, not an instruction to advance to any next step it names.

        PREVIOUS ATTEMPT RESULT

        \(previousResult)

        CURRENT STEP

        \(stepPrompt)
        """
        await performGeneric(
            cursor: context.cursor,
            previousHandoff: previousHandoff,
            promptOverride: retryPrompt,
            allowsSessionFallback: true
        )
    }

    public func retryRelay() async {
        guard let run = activeRun ?? record.activity?.runs.last,
              let finalOutput = run.finalOutput else { return }
        focusActiveProgress(on: run.id)
        if record.activity?.liveTeam != nil {
            record.activity?.status = .running
            record.activity?.liveTeam?.resumeCheckpoint = nil
            await beginLiveTeamRouting(runID: run.id, finalOutput: finalOutput)
            return
        }
        if record.activity?.workflow != nil {
            record.activity?.status = .running
            record.activity?.workflowResumeCheckpoint = nil
            await beginGenericRouting(runID: run.id, finalOutput: finalOutput)
            return
        }
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
        if record.activity?.liveTeam != nil {
            let liveDisposition: LiveTeamCoordinatorDisposition = switch disposition {
            case .implementationComplete, .fixComplete: .completionCandidate
            case .blocked, .failed, .unclear: .pause
            case .implementationCheckpoint, .reviewComplete, .fixCheckpoint: .continueTeam
            }
            await useLiveTeamCoordinatorDecision(
                handoff: text,
                disposition: liveDisposition,
                label: label,
                evidence: "The user supplied the handoff after routing needed attention."
            )
            return
        }
        if record.activity?.workflow != nil {
            let outcome: WorkflowOutcome = switch disposition {
            case .implementationComplete, .fixComplete: .complete
            case .blocked: .blocked
            case .failed: .failed
            case .unclear: .unclear
            case .implementationCheckpoint, .reviewComplete, .fixCheckpoint: .continueWorkflow
            }
            await useWorkflowHandoff(text: text, outcome: outcome, label: label)
            return
        }
        focusActiveProgress(on: run.id)
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
        activatePendingGoalAmendment()
        record.activity?.status = .running
        record.activity?.resumeCheckpoint = nil
        await applyWorkflowDecision(runID: run.id, for: run.kind, envelope: envelope)
    }

    public func useWorkflowHandoff(
        text: String,
        outcome: WorkflowOutcome,
        label: String
    ) async {
        guard record.activity?.workflow != nil,
              let run = activeRun ?? record.activity?.runs.last else { return }
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            errorMessage = "The handoff must contain information for the next step."
            return
        }
        focusActiveProgress(on: run.id)
        let handoff = WorkflowHandoff(
            text: cleanText,
            outcome: outcome,
            runLabel: normalizedRunLabel(label, fallback: run.displayName)
        )
        updateRun(run.id) {
            $0.workflowHandoff = handoff
            $0.relayError = nil
            $0.status = .completed
        }
        activatePendingGoalAmendment()
        record.activity?.status = .running
        record.activity?.workflowResumeCheckpoint = nil
        await applyGenericWorkflowDecision(runID: run.id, handoff: handoff)
    }

    public func useLiveTeamCoordinatorDecision(
        handoff: String,
        disposition: LiveTeamCoordinatorDisposition,
        label: String,
        evidence: String
    ) async {
        guard record.activity?.liveTeam != nil,
              let run = activeRun ?? record.activity?.runs.last,
              run.liveTeamMember != nil else { return }
        let clean = handoff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            errorMessage = "The handoff must contain information for the agents."
            return
        }
        focusActiveProgress(on: run.id)
        let decision = LiveTeamCoordinatorDecision(
            handoff: clean,
            runLabel: normalizedRunLabel(label, fallback: run.displayName),
            disposition: disposition,
            evidence: evidence,
            progressEvidence: .none
        )
        updateRun(run.id) {
            $0.coordinatorDecision = decision
            $0.relayError = nil
            $0.status = .completed
        }
        record.activity?.liveTeam?.coordinatorHandoff = clean
        record.activity?.liveTeam?.lastCoordinatorDecision = decision
        record.activity?.status = .running
        record.activity?.liveTeam?.resumeCheckpoint = .applyCoordinatorDecision(run.id)
        do {
            try await persist()
            guard await releaseFreshLiveTeamSessionIfNeeded(for: run.id) else {
                return
            }
            await applyLiveTeamCoordinatorDecision(runID: run.id, decision: decision)
        } catch {
            record.activity?.status = .paused
            errorMessage = "Could not save the user-supplied handoff: \(error.localizedDescription)"
        }
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
        let previousLiveTeamRuntimeConfiguration = liveTeamRuntimeConfiguration
        record.settings = settings
        if let liveTeamRuntimeConfigurationProvider {
            liveTeamRuntimeConfiguration = liveTeamRuntimeConfigurationProvider(settings)
        }
        do {
            try await persist()
            return true
        } catch {
            record.settings = previousSettings
            liveTeamRuntimeConfiguration = previousLiveTeamRuntimeConfiguration
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func updateWorkflowPreferences(_ updatedWorkflow: WorkflowTemplate) async -> Bool {
        guard var activity = record.activity,
              let currentWorkflow = activity.workflow,
              activity.status == .paused else {
            errorMessage = "Workflow preferences can only be changed while the activity is paused."
            return false
        }
        guard Self.sameFrozenWorkflowTopology(currentWorkflow, updatedWorkflow) else {
            errorMessage = "Workflow identity, step names, stages, and order are frozen after an activity starts."
            return false
        }
        if let validationMessage = updatedWorkflow.validationMessage {
            errorMessage = validationMessage
            return false
        }

        let previousActivity = activity
        var supersededSessions: Set<ProviderSessionReference> = []
        for updatedStep in updatedWorkflow.steps {
            guard let previousStep = currentWorkflow.step(id: updatedStep.id) else { continue }
            guard var session = activity.stepSessions[updatedStep.id] else { continue }
            if Self.requiresNewLineage(from: previousStep.target, to: updatedStep.target) {
                if let sessionID = session.providerSessionID {
                    supersededSessions.insert(ProviderSessionReference(
                        providerID: session.target.providerID,
                        sessionID: sessionID
                    ))
                }
                session.lineage += 1
                session.providerSessionID = nil
            }
            session.target = updatedStep.target
            activity.stepSessions[updatedStep.id] = session
        }
        activity.workflow = updatedWorkflow
        record.activity = activity
        do {
            try await persist()
            await releaseProviderSessions(supersededSessions)
            statusMessage = pausedStatusMessage
            return true
        } catch {
            record.activity = previousActivity
            errorMessage = "Could not save the workflow preferences: \(error.localizedDescription)"
            return false
        }
    }

    private func convertLegacyWorkflowNow() async {
        if let liveTeamRuntimeConfigurationProvider {
            liveTeamRuntimeConfiguration = liveTeamRuntimeConfigurationProvider(record.settings)
        }
        guard let router = liveTeamOverseerRouter,
              let runtime = liveTeamRuntimeConfiguration,
              let legacyActivity = record.activity,
              ![.completed, .cancelled].contains(legacyActivity.status),
              let legacyWorkflow = legacyActivity.workflow else { return }
        errorMessage = nil
        guard !legacyActivity.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            record.activity?.status = .paused
            statusMessage = "Define the goal before Codeness prepares the agents"
            try? await persist()
            return
        }
        let authoritativeLegacyActivity = legacyActivity
        record.activity?.status = .paused
        statusMessage = "Codeness · Preparing agents…"
        let context = makeLiveTeamOverseerContext(
            reason: "Use the earlier fixed activity configuration as evidence when preparing the first agents."
        )
        liveTeamControlInvocationCount += 1
        defer {
            liveTeamControlInvocationCount = max(0, liveTeamControlInvocationCount - 1)
        }
        do {
            let definition = try await router.migrate(
                context,
                configuration: runtime.bootstrapOverseerConfiguration(
                    for: legacyActivity.goal
                ),
                defaultCoordinator: runtime.defaultCoordinator,
                cwd: record.canonicalPath
            )
            guard let checkpoint = LiveTeamStateMachine.initialCheckpoint(for: definition) else {
                throw LiveTeamRevisionError.invalid("The prepared setup has no eligible agent.")
            }
            var migratedSessions: [String: WorkflowSessionState] = [:]
            for member in definition.members {
                guard case .ownMemory = member.sessionPolicy,
                      let oldStep = legacyWorkflow.step(id: member.id),
                      oldStep.instructions == member.instructions,
                      !Self.requiresNewLineage(from: oldStep.target, to: member.target),
                      var oldSession = authoritativeLegacyActivity.stepSessions[member.id]
                else { continue }
                let slotID = member.sessionPolicy.persistentSlotID(memberID: member.id)!
                oldSession.target = member.target
                migratedSessions[slotID] = WorkflowSessionState(
                    stepID: slotID,
                    lineage: oldSession.lineage,
                    target: oldSession.target,
                    providerSessionID: oldSession.providerSessionID
                )
            }
            var overseer = runtime.overseer
            overseer.target = definition.overseerTarget
            let state = LiveTeamState(
                overseer: overseer,
                currentDefinition: definition,
                checkpoint: checkpoint,
                resumeCheckpoint: .perform(checkpoint),
                editHistory: [LiveTeamEditRecord(
                    revision: 1,
                    actor: .overseer,
                    summary: "Prepared \(definition.members.count) agents from earlier activity state",
                    reason: definition.strategicReason,
                    evidence: "Codeness considered the earlier \(legacyWorkflow.name) activity configuration once."
                )]
            )
            record.activity?.workflow = nil
            record.activity?.workflowCursor = nil
            record.activity?.workflowResumeCheckpoint = nil
            record.activity?.stepSessions = migratedSessions
            record.activity?.liveTeam = state
            record.activity?.status = .paused
            try await persist()
            statusMessage = "Agents ready; review the goal or resume"
        } catch {
            record.activity = authoritativeLegacyActivity
            record.activity?.status = .paused
            errorMessage = "Codeness could not prepare agents from the earlier activity state: \(error.localizedDescription)"
            statusMessage = "Paused before preparing agents; Resume will try again"
            try? await persist()
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
        let currentlyRequestedGoal = activity.pendingGoalAmendment?.revisedGoal ?? activity.goal
        guard cleanGoal != currentlyRequestedGoal else { return true }

        let previousActivity = activity
        if activity.status == .running {
            if cleanGoal == activity.goal {
                activity.pendingGoalAmendment = nil
            } else {
                let pending = activity.pendingGoalAmendment
                activity.pendingGoalAmendment = GoalAmendment(
                    id: pending?.id ?? UUID(),
                    previousGoal: activity.goal,
                    revisedGoal: cleanGoal,
                    createdAt: pending?.createdAt ?? .now
                )
            }
        } else {
            if let pending = activity.pendingGoalAmendment {
                activity.goalAmendments.append(pending)
                activity.goal = pending.revisedGoal
                activity.pendingGoalAmendment = nil
            }
            if cleanGoal != activity.goal {
                activity.goalAmendments.append(GoalAmendment(
                    previousGoal: activity.goal,
                    revisedGoal: cleanGoal
                ))
                activity.goal = cleanGoal
            }
        }
        if activity.liveTeam != nil, activity.status != .running {
            activity.liveTeam?.boardGoalAmendmentPendingReview = true
        }
        record.activity = activity
        cancelWorkOverviewSummaryRequest()
        do {
            try await persist()
            if record.activity?.workflow != nil,
               record.activity?.liveTeam == nil {
                await convertLegacyWorkflowNow()
            }
            if record.activity?.liveTeam?.boardGoalAmendmentPendingReview == true,
               record.activity?.status == .paused {
                record.activity?.liveTeam?.boardGoalAmendmentPendingReview = false
                await requestLiveTeamStrategicReview(
                    reason: "The user amended the goal.",
                    automatic: false,
                    continuation: record.activity?.liveTeam?.checkpoint,
                    unrunnable: false,
                    leavePaused: true
                )
            }
            return true
        } catch {
            record.activity = previousActivity
            errorMessage = "Could not save the revised goal: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func activatePendingGoalAmendment() -> Bool {
        guard var activity = record.activity,
              let pending = activity.pendingGoalAmendment else { return false }
        activity.pendingGoalAmendment = nil
        if pending.revisedGoal != activity.goal {
            activity.goalAmendments.append(GoalAmendment(
                id: pending.id,
                previousGoal: activity.goal,
                revisedGoal: pending.revisedGoal,
                createdAt: pending.createdAt
            ))
            activity.goal = pending.revisedGoal
        }
        record.activity = activity
        cancelWorkOverviewSummaryRequest()
        return true
    }

    private func activatePendingLiveTeamGoalAmendment() {
        if activatePendingGoalAmendment() {
            record.activity?.liveTeam?.boardGoalAmendmentPendingReview = true
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
        let pendingTranscriptLoad = transcriptLoadTask
        transcriptLoadTask?.cancel()
        transcriptLoadTask = nil
        cancelWorkOverviewSummaryRequest()
        await pendingViewSave?.value
        await pendingTranscriptLoad?.value
        await cancelRoutingTasks()

        let archivedRecord = record
        let abandonedSessions = attachedProviderSessions
        let restartGoal = previousActivity.pendingGoalAmendment?.revisedGoal
            ?? previousActivity.goal
        let resetRecord = RepositoryRecord(
            id: record.id,
            canonicalPath: record.canonicalPath,
            implementerThreadID: nil,
            reviewerThreadID: nil,
            settings: record.settings,
            activityDraft: ActivityConfigurationDraft(
                goal: restartGoal,
                prompts: previousActivity.prompts,
                workflow: nil
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
            detailPresentation: viewState.detailPresentation,
            detailSplitFraction: viewState.detailSplitFraction
        )

        do {
            guard !isClosing else {
                throw RepositoryCoordinatorError.startOverWhileClosing
            }
            try await flushPendingTranscripts()
            // `record` may contain only the bounded UI projection of a large
            // transcript. Empty metadata tells WorkspaceStore to reconstruct the
            // authoritative, complete archive from the append-only run logs.
            try await store.archiveActivity(workspaceMetadataSnapshot(archivedRecord))
            guard !isClosing else {
                throw RepositoryCoordinatorError.startOverWhileClosing
            }
            let unreleasedSessions = await unreleasedProviderSessions(
                afterReleasing: abandonedSessions
            )
            guard unreleasedSessions.isEmpty else {
                throw RepositoryCoordinatorError.providerSessionsStillAttached(
                    providerSessionDescription(unreleasedSessions)
                )
            }
            sessionsPrepared = false
            // workspace.json is the authoritative reset commit. The view-state
            // file is non-authoritative and can safely be retried afterward. The
            // old provider sessions have already confirmed detachment, so this
            // reset can never make an unconfirmed live turn invisible.
            try await store.save(resetRecord)

            record = resetRecord
            viewState = resetViewState
            selectedRunID = nil
            pauseAfterCurrent = false
            itemsWithDeltas.removeAll()
            deltaItemRetainedByteCounts.removeAll()
            interactionSafetyTerminatingRunIDs.removeAll(keepingCapacity: false)
            runIsAtBottom.removeAll()
            completingRunIDs.removeAll()
            clearPendingInteractions()
            interactionResolutionInFlight = false
            genericRunTasks.values.forEach { $0.cancel() }
            genericRunTasks.removeAll()
            genericSessionFallbacks.removeAll()
            liveTeamSessionFallbacks.removeAll()
            hydratedTranscriptRunIDs.removeAll()
            pendingTranscriptBuffers.removeAll()
            visibleTranscriptChunks.removeAll()
            visibleTranscriptUTF8ByteCounts.removeAll()
            visibleTranscriptTasks.values.forEach { $0.cancel() }
            visibleTranscriptTasks.removeAll()
            transcriptHydrationIDs.removeAll()
            transcriptHydrationChunks.removeAll()
            let hydrationWaiters = transcriptHydrationWaiters.values.flatMap { $0 }
            transcriptHydrationWaiters.removeAll()
            hydrationWaiters.forEach { $0.resume() }
            scheduledTranscriptFlushTasks.values.forEach { $0.cancel() }
            scheduledTranscriptFlushTasks.removeAll()
            transcriptFlushes.values.forEach { $0.task.cancel() }
            transcriptFlushes.removeAll()
            transcriptFlushFailureRunIDs.removeAll()
            transcriptBackpressureRunIDs.removeAll()
            droppedTranscriptUTF8Bytes.removeAll()
            transcriptBackpressureFailureDetails.removeAll()
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

    @discardableResult
    private func releaseProviderSessions(
        _ sessions: some Sequence<ProviderSessionReference>
    ) async -> Set<ProviderSessionReference> {
        let sessions = Set(sessions).intersection(attachedProviderSessions)
        var released: Set<ProviderSessionReference> = []
        for session in sessions {
            if await releaseProviderSession(session) {
                released.insert(session)
            }
        }
        return released
    }

    private func releaseProviderSession(_ session: ProviderSessionReference) async -> Bool {
        if !attachedProviderSessions.contains(session) {
            return true
        }
        if providerSessionReleaseWaiters[session] != nil {
            return await withCheckedContinuation { continuation in
                if !attachedProviderSessions.contains(session) {
                    continuation.resume(returning: true)
                } else if providerSessionReleaseWaiters[session] != nil {
                    providerSessionReleaseWaiters[session, default: []].append(continuation)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }

        providerSessionReleaseWaiters[session] = []
        let attemptSucceeded: Bool
        if let agentProviders {
            attemptSucceeded = await agentProviders.releaseSession(
                providerID: session.providerID,
                id: session.sessionID
            )
        } else if session.providerID == .codex {
            do {
                let status = try await appServer.unsubscribeThread(id: session.sessionID)
                attemptSucceeded = ["unsubscribed", "notSubscribed", "notLoaded"].contains(status)
            } catch {
                attemptSucceeded = false
            }
        } else {
            attemptSucceeded = false
        }

        // An App Server generation boundary can confirm Codex detachment while
        // the unsubscribe request above is suspended. Honor that stronger proof
        // even if the now-defunct request itself resumes with notRunning.
        let succeeded = attemptSucceeded || !attachedProviderSessions.contains(session)
        if succeeded {
            attachedProviderSessions.remove(session)
        }
        let waiters = providerSessionReleaseWaiters.removeValue(forKey: session) ?? []
        waiters.forEach { $0.resume(returning: succeeded) }
        return succeeded
    }

    private func markProviderSessionAttached(_ session: ProviderSessionReference) {
        attachedProviderSessions.insert(session)
    }

    private func unreleasedProviderSessions(
        afterReleasing sessions: some Sequence<ProviderSessionReference>
    ) async -> Set<ProviderSessionReference> {
        let requested = Set(sessions)
        _ = await releaseProviderSessions(requested)
        return requested.intersection(attachedProviderSessions)
    }

    private func detachProviderSessionsForCurrentDocument() async -> Set<ProviderSessionReference> {
        let unreleased = await unreleasedProviderSessions(
            afterReleasing: attachedProviderSessions
        )
        sessionsPrepared = false
        return unreleased
    }

    private func providerSessionDescription(
        _ sessions: Set<ProviderSessionReference>
    ) -> String {
        sessions
            .map { "\($0.providerID.rawValue):\($0.sessionID)" }
            .sorted()
            .joined(separator: ", ")
    }

    private func prepareGenericSession(
        _ request: AgentSessionRequest,
        runID: UUID,
        using agentProviders: AgentProviderRegistry
    ) async throws -> AgentSession? {
        let leaseID = beginProviderLaunchLease(runID: runID)
        defer { finishProviderLaunchLease(leaseID) }

        let session = try await agentProviders.prepareSession(request)
        let reference = ProviderSessionReference(
            providerID: session.providerID,
            sessionID: session.id
        )
        markProviderSessionAttached(reference)
        guard !isClosing else {
            _ = await releaseProviderSessions([reference])
            return nil
        }
        return session
    }

    private func beginProviderLaunchLease(runID: UUID) -> UUID {
        let leaseID = UUID()
        providerLaunchLeases[leaseID] = runID
        return leaseID
    }

    private func finishProviderLaunchLease(_ leaseID: UUID) {
        providerLaunchLeases.removeValue(forKey: leaseID)
        guard providerLaunchLeases.isEmpty else { return }
        let waiters = providerLaunchWaiters
        providerLaunchWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForProviderLaunches() async {
        guard !providerLaunchLeases.isEmpty else { return }
        await withCheckedContinuation { continuation in
            if providerLaunchLeases.isEmpty {
                continuation.resume()
            } else {
                providerLaunchWaiters.append(continuation)
            }
        }
    }

    public func appServerRestarted() async {
        sessionsPrepared = false
        // The process-generation boundary is definitive even if a prior
        // bounded termination wait returned without observing cleanup.
        protocolContainment = nil
        clearAllLegacyInterruptionDebts(advanceGeneration: true)
        markProviderSessionsDetachedByProcessBoundary(.codex)
        if (record.activity?.workflow != nil || record.activity?.liveTeam != nil),
           activeRun?.agentTarget?.providerID != .codex {
            return
        }
        clearPendingInteractions()
        clearSafetyStopStateAfterAppServerBoundary()
        interactionResolutionInFlight = false
        if record.activity?.status == .running {
            record.activity?.status = .paused
            if record.activity?.liveTeam != nil {
                recoverInterruptedLiveTeamState()
            } else if record.activity?.workflow != nil {
                markLastGenericRunInterruptedIfNeeded()
            } else {
                markLastRunInterruptedIfNeeded()
                migrateResumeCheckpointIfNeeded()
            }
            statusMessage = pausedStatusMessage
        }
        if isClosing {
            await completeCloseAfterTerminalEvent()
        } else {
            try? await persist()
        }
    }

    private func clearSafetyStopStateAfterAppServerBoundary() {
        interactionSafetyTerminatingRunIDs.removeAll(keepingCapacity: false)
        let terminatedBackpressureRunIDs = transcriptBackpressureRunIDs
        for runID in terminatedBackpressureRunIDs {
            applyTranscriptBackpressureFailure(runID: runID)
            itemsWithDeltas.removeValue(forKey: runID)
            deltaItemRetainedByteCounts.removeValue(forKey: runID)
            tokenUsageBaselines.removeValue(forKey: runID)
            droppedTranscriptUTF8Bytes.removeValue(forKey: runID)
            transcriptBackpressureFailureDetails.removeValue(forKey: runID)
        }
        transcriptBackpressureRunIDs.removeAll(keepingCapacity: false)
    }

    /// A confirmed provider process boundary is stronger proof of detachment
    /// than an individual release request. Resume IDs remain persisted so the
    /// replacement provider can reattach them later.
    public func providerRestarted(_ providerID: AgentProviderID) {
        markProviderSessionsDetachedByProcessBoundary(providerID)
    }

    private func markProviderSessionsDetachedByProcessBoundary(
        _ providerID: AgentProviderID
    ) {
        let detached = attachedProviderSessions.filter {
            $0.providerID == providerID
        }
        attachedProviderSessions.subtract(detached)
        for session in detached {
            let waiters = providerSessionReleaseWaiters.removeValue(forKey: session) ?? []
            waiters.forEach { $0.resume(returning: true) }
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

        if method == "turn/started",
           await terminateGenerationForUnexpectedLegacyStartedIdentityIfNeeded(
                event: event
           ) {
            return
        }

        if method == "turn/completed",
           let threadID = event.threadID,
           let turnID = event.turnID {
            // Only the exact terminal for the acknowledged turn discharges its
            // watchdog. Delayed terminals from another turn or generation do
            // not affect the debt.
            clearLegacyInterruptionDebt(threadID: threadID, turnID: turnID)
        }

        if method == "thread/closed",
           let threadID = event.threadID,
           let unresolved = unresolvedLegacyInterruption(forThreadID: threadID) {
            let detail = "Codex closed thread \(threadID) after Codeness requested interruption of turn \(unresolved.key.turnID), but did not emit the exact matching turn/completed notification. Codeness stopped the App Server generation because thread closure alone cannot prove that turn and its MCP/background processes ended."
            await containLegacyAppServerGeneration(
                runID: unresolved.debt.runID,
                turnIDs: [unresolved.key.turnID],
                detail: detail
            )
            return
        }

        guard let runID = runID(for: event) else { return }

        if ["thread/closed", "turn/completed"].contains(method) {
            if let terminalTurnID = event.turnID ?? run(withID: runID)?.turnID {
                retireTurnID(terminalTurnID)
            }
            if await finishInteractionSafetyStopIfNeeded(runID: runID) {
                return
            }
            if transcriptBackpressureRunIDs.contains(runID) {
                itemsWithDeltas.removeValue(forKey: runID)
                deltaItemRetainedByteCounts.removeValue(forKey: runID)
                tokenUsageBaselines.removeValue(forKey: runID)
                await finishBackpressuredRunAfterTerminalEvent(runID: runID)
                return
            }
            clearPendingInteractions()
        }

        if method == "thread/closed" {
            clearPendingInteractions()
            interactionSafetyTerminatingRunIDs.remove(runID)
            itemsWithDeltas.removeValue(forKey: runID)
            deltaItemRetainedByteCounts.removeValue(forKey: runID)
            tokenUsageBaselines.removeValue(forKey: runID)
            updateRun(runID) {
                $0.status = .interrupted
                $0.completedAt = .now
                $0.relayError = "Codex closed the active thread unexpectedly."
            }
            activatePendingGoalAmendment()
            record.activity?.resumeCheckpoint = .recoverRun(runID)
            pauseActivity(
                message: "Codex closed the active thread. Inspect the repository before resuming."
            )
            if isClosing {
                await completeCloseAfterTerminalEvent()
            } else {
                try? await persist()
            }
            return
        }

        if method == "turn/started",
           !transcriptBackpressureRunIDs.contains(runID),
           let turnID = params["turn"]?["id"]?.stringValue {
            updateRun(runID) {
                $0.turnID = turnID
                $0.status = .running
            }
        }

        if method == "thread/tokenUsage/updated",
           let usage = params["tokenUsage"],
           let total = RunTokenUsage(appServerValue: usage["total"]),
           let last = RunTokenUsage(appServerValue: usage["last"]) {
            let baseline = tokenUsageBaselines[runID] ?? total.subtracting(last)
            tokenUsageBaselines[runID] = baseline
            updateRun(runID) {
                $0.tokenUsage = total.subtracting(baseline)
            }
        }

        let deltaItems = itemsWithDeltas[runID] ?? []
        let update = TranscriptFormatter.update(method: method, params: params, itemsWithDeltas: deltaItems)
        if let itemID = update.itemID, method.hasSuffix("/delta") || method.hasSuffix("Delta") {
            if itemsWithDeltas[runID]?.contains(itemID) != true {
                let retainedByteCount = itemID.utf8.count
                let currentByteCount = deltaItemRetainedByteCounts[runID] ?? 0
                guard (itemsWithDeltas[runID]?.count ?? 0)
                        < Self.maximumTrackedDeltaItemCount,
                      retainedByteCount <= Self.maximumTrackedDeltaItemRetainedBytes,
                      currentByteCount
                        <= Self.maximumTrackedDeltaItemRetainedBytes - retainedByteCount else {
                    await stopRunForInteractionSafety(
                        runID: runID,
                        detail: "Codex emitted deltas for too many unfinished items. Codeness stopped the turn to prevent unbounded memory growth."
                    )
                    return
                }
                itemsWithDeltas[runID, default: []].insert(itemID)
                deltaItemRetainedByteCounts[runID] = currentByteCount + retainedByteCount
            }
        }
        if method == "item/completed", let itemID = update.itemID {
            if itemsWithDeltas[runID]?.remove(itemID) != nil {
                deltaItemRetainedByteCounts[runID] = max(
                    0,
                    (deltaItemRetainedByteCounts[runID] ?? 0) - itemID.utf8.count
                )
            }
        }
        let storedText = RunTranscriptPresentation.storedText(for: update)
        if !storedText.isEmpty {
            await recordTranscript(storedText, runID: runID)
        }
        if let finalOutput = update.finalOutput, !finalOutput.isEmpty {
            updateRun(runID) { $0.finalOutput = finalOutput }
        }

        if method == "turn/completed" {
            interactionSafetyTerminatingRunIDs.remove(runID)
            itemsWithDeltas.removeValue(forKey: runID)
            deltaItemRetainedByteCounts.removeValue(forKey: runID)
            tokenUsageBaselines.removeValue(forKey: runID)
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
                activatePendingGoalAmendment()
                if isClosing {
                    record.activity?.resumeCheckpoint = .routeCompletedRun(runID)
                    pauseActivity(message: "Paused before preparing the handoff")
                    await completeCloseAfterTerminalEvent()
                } else {
                    await beginRouting(runID: runID, finalOutput: finalOutput)
                }
            } else {
                updateRun(runID) { $0.status = status == "interrupted" ? .interrupted : .failed }
                activatePendingGoalAmendment()
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
        activatePendingGoalAmendment()
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
            activatePendingGoalAmendment()
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
            activatePendingGoalAmendment()
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
        activatePendingGoalAmendment()
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
            // Make the stopped-step controls observable atomically with the paused
            // state. The routing task is already on its terminal branch, and its
            // defer will harmlessly repeat these removals.
            completingRunIDs.remove(runID)
            routingTasks.removeValue(forKey: runID)
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
        activatePendingGoalAmendment()
        guard let activity = record.activity else { return }
        record.activity?.pendingAction = action
        record.activity?.resumeCheckpoint = .perform(action)
        if action != .complete {
            do {
                try await ensureSessions(
                    allowRecreate: record.requiresFreshProviderSessions
                )
            } catch {
                guard !isClosing else {
                    record.activity?.status = .paused
                    return
                }
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
            await persistCompletedActivityAndDetachSessions()
        }
    }

    private func launchRun(role: AgentRole, kind: RunKind, prompt: String) async {
        guard !isClosing, record.activity != nil else { return }
        let launchLeaseID = beginProviderLaunchLease(runID: UUID())
        defer { finishProviderLaunchLease(launchLeaseID) }
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
        let followsLiveRun = followsActiveProgress
            || RunSelectionPolicy.shouldSelectNextRun(
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
            focusActiveProgress(on: run.id)
        }
        itemsWithDeltas[run.id] = []
        deltaItemRetainedByteCounts[run.id] = 0
        statusMessage = "Starting \(kind.displayName.lowercased())…"

        do {
            try await persist()
        } catch {
            let queuedSaveError = error
            // No Codex turn exists yet, so remove the in-memory row and restore the
            // previous durable phase checkpoint instead of running without a record.
            record.activity?.runs.removeAll(where: { $0.id == run.id })
            itemsWithDeltas.removeValue(forKey: run.id)
            deltaItemRetainedByteCounts.removeValue(forKey: run.id)
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

        guard !isClosing else {
            updateRun(run.id) {
                $0.status = .interrupted
                $0.completedAt = .now
            }
            record.activity?.status = .paused
            record.activity?.resumeCheckpoint = .recoverRun(run.id)
            try? await persist()
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
            }
            await recordTranscript(failureText, runID: run.id)
            record.activity?.resumeCheckpoint = .recoverRun(run.id)
            pauseActivity(message: error.localizedDescription)
            if !isClosing {
                try? await persist()
            }
            return
        }

        if let notificationTurnID = self.run(withID: run.id)?.turnID,
           notificationTurnID != turnID {
            await containLegacyAppServerGeneration(
                runID: run.id,
                turnIDs: [notificationTurnID, turnID],
                detail: "Codex identified the same started turn as both \(notificationTurnID) and \(turnID). Codeness stopped the App Server generation instead of attaching this run to an ambiguous execution."
            )
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
            // Close is waiting for this launch lease. Let its single control path
            // issue the interrupt after the accepted turn is durably registered.
            statusMessage = "Preparing to stop \(kind.displayName.lowercased())…"
            return
        }
        statusMessage = "\(kind.displayName) running"
    }

    private func resumeLiveTeam() async {
        guard let activity = record.activity,
              let liveTeam = activity.liveTeam else { return }
        pauseAfterCurrent = false
        viewState.pauseAfterCurrent = false
        scheduleViewStateSave()
        record.activity?.liveTeam?.boardDirectionReason = nil
        statusMessage = "Resuming…"

        let checkpoint = liveTeam.resumeCheckpoint
        record.activity?.status = .running
        record.activity?.liveTeam?.resumeCheckpoint = nil
        do {
            switch checkpoint {
            case .invokeOverseer(let request):
                await invokeLiveTeamOverseer(request)
            case .recoverRun(let runID):
                guard let run = run(withID: runID) else {
                    throw RepositoryCoordinatorError.missingRun(runID)
                }
                await recoverLiveTeamRun(run)
            case .routeCompletedRun(let runID):
                guard let run = run(withID: runID),
                      let output = run.finalOutput,
                      !output.isEmpty else {
                    throw RepositoryCoordinatorError.missingRunOutput(runID)
                }
                await beginLiveTeamRouting(runID: runID, finalOutput: output)
            case .applyCoordinatorDecision(let runID):
                guard let decision = run(withID: runID)?.coordinatorDecision else {
                    throw RepositoryCoordinatorError.missingRunOutput(runID)
                }
                await applyLiveTeamCoordinatorDecision(
                    runID: runID,
                    decision: decision
                )
            case .perform(let liveCheckpoint):
                await performLiveTeam(checkpoint: liveCheckpoint)
            case nil:
                if liveTeam.currentDefinition == nil {
                    let request = LiveTeamOverseerRequest(
                        mode: .bootstrap,
                        reason: "Retry preparing the first agents.",
                        automatic: false
                    )
                    await invokeLiveTeamOverseer(request)
                } else if let run = activity.runs.last,
                          let output = run.finalOutput,
                          !output.isEmpty,
                          run.coordinatorDecision == nil {
                    await beginLiveTeamRouting(runID: run.id, finalOutput: output)
                } else if let current = liveTeam.checkpoint {
                    await performLiveTeam(checkpoint: current)
                }
            }
        } catch {
            record.activity?.status = .paused
            record.activity?.liveTeam?.resumeCheckpoint = checkpoint
            errorMessage = error.localizedDescription
            try? await persist()
        }
    }

    private func performLiveTeam(
        checkpoint requestedCheckpoint: LiveTeamCheckpoint,
        promptOverride: String? = nil,
        snapshotOverride: LiveTeamMemberSnapshot? = nil,
        allowsSessionFallback: Bool = true
    ) async {
        guard !isClosing else {
            record.activity?.status = .paused
            record.activity?.liveTeam?.checkpoint = requestedCheckpoint
            record.activity?.liveTeam?.resumeCheckpoint = .perform(requestedCheckpoint)
            return
        }
        if snapshotOverride == nil,
           !(await activatePendingLiveTeamRevisionAtSafeBoundary()) {
            return
        }
        guard let state = record.activity?.liveTeam,
              let definition = state.currentDefinition else {
            pauseLiveTeamActivity(message: "Codeness has not prepared the agents.")
            return
        }

        let snapshot: LiveTeamMemberSnapshot
        let checkpoint: LiveTeamCheckpoint
        if let snapshotOverride {
            snapshot = snapshotOverride
            checkpoint = LiveTeamCheckpoint(
                memberID: snapshot.member.id,
                cycle: snapshot.cycle,
                revision: snapshot.revision
            )
        } else {
            guard let reconciled = LiveTeamStateMachine.checkpoint(
                reconciling: requestedCheckpoint,
                in: definition,
                completedOnceMemberIDs: state.completedOnceMemberIDs
            ),
            let member = definition.member(id: reconciled.memberID) else {
                await requestLiveTeamStrategicReview(
                    reason: "No eligible agent remains at the saved scheduling point.",
                    automatic: true,
                    continuation: nil,
                    unrunnable: true
                )
                return
            }
            let runID = UUID()
            let slotID = member.sessionPolicy.persistentSlotID(memberID: member.id)
                ?? "fresh:\(member.id):\(runID.uuidString)"
            snapshot = LiveTeamMemberSnapshot(
                member: member,
                workingGoal: definition.workingGoal,
                revision: definition.revision,
                cycle: reconciled.cycle,
                sessionSlotID: slotID
            )
            checkpoint = reconciled
        }

        record.activity?.status = .running
        record.activity?.liveTeam?.checkpoint = checkpoint
        record.activity?.liveTeam?.resumeCheckpoint = .perform(checkpoint)
        let prompt = promptOverride ?? LiveTeamPromptBuilder.memberPrompt(
            snapshot: snapshot,
            handoff: state.coordinatorHandoff
        )
        await launchLiveTeamRun(
            snapshot: snapshot,
            checkpoint: checkpoint,
            prompt: prompt,
            allowsSessionFallback: allowsSessionFallback
        )
    }

    private func launchLiveTeamRun(
        snapshot: LiveTeamMemberSnapshot,
        checkpoint: LiveTeamCheckpoint,
        prompt: String,
        allowsSessionFallback: Bool
    ) async {
        guard let agentProviders,
              record.activity?.liveTeam != nil,
              !isClosing else {
            pauseLiveTeamActivity(message: "The agent providers are not available.")
            return
        }
        let member = snapshot.member
        let previousRunID = record.activity?.runs.last?.id
        let followsLiveRun = followsActiveProgress
            || RunSelectionPolicy.shouldSelectNextRun(
                selectedRunID: selectedRunID,
                activeRunID: previousRunID,
                activeRunIsAtBottom: previousRunID.flatMap { runIsAtBottom[$0] }
            )
        let compatibility = Self.compatibilityRoleAndKind(
            for: WorkflowStep(
                id: member.id,
                name: member.name,
                section: .loop,
                instructions: member.instructions,
                target: member.target
            )
        )
        var sessionState = record.activity?.stepSessions[snapshot.sessionSlotID]
            ?? WorkflowSessionState(
                stepID: snapshot.sessionSlotID,
                target: member.target
            )
        sessionState.target = member.target
        record.activity?.stepSessions[snapshot.sessionSlotID] = sessionState

        let run = RunRecord(
            sequence: (record.activity?.runs.count ?? 0) + 1,
            role: compatibility.role,
            kind: compatibility.kind,
            status: .queued,
            threadID: sessionState.providerSessionID,
            model: member.target.model,
            effort: member.target.options.effort ?? "",
            prompt: prompt,
            workflowStep: WorkflowStepSnapshot(
                step: WorkflowStep(
                    id: member.id,
                    name: member.name,
                    section: .loop,
                    instructions: member.instructions,
                    target: member.target
                ),
                loopIteration: checkpoint.cycle
            ),
            agentTarget: member.target,
            sessionLineage: sessionState.lineage,
            liveTeamMember: snapshot
        )
        record.activity?.liveTeam?.resumeCheckpoint = .recoverRun(run.id)
        record.activity?.runs.append(run)
        runIsAtBottom[run.id] = true
        if followsLiveRun {
            focusActiveProgress(on: run.id)
        }
        statusMessage = "Starting \(member.name.lowercased())…"
        let launchLeaseID = beginProviderLaunchLease(runID: run.id)
        defer { finishProviderLaunchLease(launchLeaseID) }

        do {
            try await persist()
        } catch {
            let queuedSaveError = error
            record.activity?.runs.removeAll { $0.id == run.id }
            runIsAtBottom.removeValue(forKey: run.id)
            record.activity?.status = .paused
            record.activity?.liveTeam?.resumeCheckpoint = .perform(checkpoint)
            selectedRunID = previousRunID
            try? await persist()
            errorMessage = "Could not save \(member.name) before starting it: \(queuedSaveError.localizedDescription)"
            statusMessage = "Paused before \(member.name.lowercased())"
            return
        }

        guard !isClosing else { return }

        let reusableSessionID: String?
        if member.sessionPolicy == .freshEveryRun {
            reusableSessionID = nil
        } else {
            reusableSessionID = reusableLiveTeamProviderSessionID(
                sessionState,
                slotID: snapshot.sessionSlotID
            )
        }
        var resumedExistingSession = reusableSessionID != nil
        var session: AgentSession
        do {
            guard let preparedSession = try await prepareGenericSession(
                liveTeamSessionRequest(
                    existingSessionID: reusableSessionID,
                    snapshot: snapshot
                ),
                runID: run.id,
                using: agentProviders
            ) else { return }
            session = preparedSession
        } catch {
            guard !isClosing else { return }
            guard allowsSessionFallback,
                  let reusableSessionID,
                  Self.confirmsUnavailableSession(error) else {
                await failLiveTeamRunBeforeStart(
                    runID: run.id,
                    message: "Could not prepare \(member.name): \(error.localizedDescription)"
                )
                return
            }
            await recordGenericSessionFallback(runID: run.id, error: error)
            await releaseProviderSessions([ProviderSessionReference(
                providerID: member.target.providerID,
                sessionID: reusableSessionID
            )])
            guard !isClosing else { return }
            do {
                guard let preparedSession = try await prepareGenericSession(
                    liveTeamSessionRequest(existingSessionID: nil, snapshot: snapshot),
                    runID: run.id,
                    using: agentProviders
                ) else { return }
                session = preparedSession
                sessionState = advanceLiveTeamSessionLineage(
                    sessionState,
                    snapshot: snapshot,
                    runID: run.id
                )
                resumedExistingSession = false
            } catch {
                await failLiveTeamRunBeforeStart(
                    runID: run.id,
                    message: "Could not prepare \(member.name): \(error.localizedDescription)"
                )
                return
            }
        }

        do {
            sessionState.providerSessionID = session.id
            record.activity?.stepSessions[snapshot.sessionSlotID] = sessionState
            updateRun(run.id) {
                $0.threadID = session.id
                $0.sessionLineage = sessionState.lineage
            }
            try await persist()
        } catch {
            await failLiveTeamRunBeforeStart(
                runID: run.id,
                message: "Could not prepare \(member.name): \(error.localizedDescription)"
            )
            return
        }

        guard !isClosing else {
            updateRun(run.id) { $0.status = .interrupted }
            record.activity?.status = .paused
            record.activity?.liveTeam?.resumeCheckpoint = .recoverRun(run.id)
            try? await persist()
            return
        }

        if allowsSessionFallback, resumedExistingSession {
            liveTeamSessionFallbacks[run.id] = LiveTeamSessionFallback(
                checkpoint: checkpoint,
                prompt: prompt
            )
        }

        do {
            var handle: AgentRunHandle
            do {
                handle = try await agentProviders.startRun(
                    AgentRunRequest(
                        runID: run.id,
                        session: session,
                        cwd: record.canonicalPath,
                        prompt: prompt,
                        target: member.target
                    )
                )
            } catch {
                guard !isClosing else {
                    liveTeamSessionFallbacks.removeValue(forKey: run.id)
                    return
                }
                guard allowsSessionFallback,
                      resumedExistingSession,
                      Self.confirmsUnavailableSession(error) else {
                    throw error
                }
                liveTeamSessionFallbacks.removeValue(forKey: run.id)
                await recordGenericSessionFallback(runID: run.id, error: error)
                await releaseProviderSessions([ProviderSessionReference(
                    providerID: session.providerID,
                    sessionID: session.id
                )])
                guard !isClosing else { return }
                guard let preparedSession = try await prepareGenericSession(
                    liveTeamSessionRequest(existingSessionID: nil, snapshot: snapshot),
                    runID: run.id,
                    using: agentProviders
                ) else { return }
                session = preparedSession
                sessionState = advanceLiveTeamSessionLineage(
                    sessionState,
                    snapshot: snapshot,
                    runID: run.id
                )
                sessionState.providerSessionID = session.id
                record.activity?.stepSessions[snapshot.sessionSlotID] = sessionState
                updateRun(run.id) {
                    $0.threadID = session.id
                    $0.sessionLineage = sessionState.lineage
                }
                try await persist()
                guard !isClosing else { return }
                handle = try await agentProviders.startRun(
                    AgentRunRequest(
                        runID: run.id,
                        session: session,
                        cwd: record.canonicalPath,
                        prompt: prompt,
                        target: member.target
                    )
                )
            }
            updateRun(run.id) {
                $0.turnID = handle.executionID
                $0.status = .running
            }
            do {
                try await persist()
            } catch {
                errorMessage = "\(member.name) started, but its latest state could not be saved: \(error.localizedDescription)"
            }

            genericRunTasks[run.id] = Task { [weak self] in
                for await event in handle.events {
                    guard let self else { return }
                    await self.handleAgentEvent(event, runID: run.id)
                }
                self?.genericRunTasks.removeValue(forKey: run.id)
            }
            statusMessage = isClosing
                ? "Preparing to stop \(member.name.lowercased())…"
                : "\(member.name) running"
        } catch {
            liveTeamSessionFallbacks.removeValue(forKey: run.id)
            guard !isClosing else { return }
            await failLiveTeamRunBeforeStart(
                runID: run.id,
                message: "Could not start \(member.name): \(error.localizedDescription)"
            )
        }
    }

    private func liveTeamSessionRequest(
        existingSessionID: String?,
        snapshot: LiveTeamMemberSnapshot
    ) -> AgentSessionRequest {
        AgentSessionRequest(
            existingSessionID: existingSessionID,
            name: "\(repositoryName) — \(snapshot.member.name)",
            cwd: record.canonicalPath,
            target: snapshot.member.target,
            developerInstructions: LiveTeamPromptBuilder.sessionInstructions()
        )
    }

    private func reusableLiveTeamProviderSessionID(
        _ session: WorkflowSessionState,
        slotID: String
    ) -> String? {
        guard let providerSessionID = session.providerSessionID else { return nil }
        let wasEstablished = record.activity?.runs.contains { run in
            run.liveTeamMember?.sessionSlotID == slotID
                && run.threadID == providerSessionID
                && run.turnID != nil
        } == true
        return wasEstablished ? providerSessionID : nil
    }

    private func advanceLiveTeamSessionLineage(
        _ sessionState: WorkflowSessionState,
        snapshot: LiveTeamMemberSnapshot,
        runID: UUID,
        updatesRun: Bool = true
    ) -> WorkflowSessionState {
        var freshState = sessionState
        let runLineage = run(withID: runID)?.sessionLineage ?? 0
        freshState.lineage = max(freshState.lineage, runLineage) + 1
        freshState.target = snapshot.member.target
        freshState.providerSessionID = nil
        record.activity?.stepSessions[snapshot.sessionSlotID] = freshState
        if updatesRun {
            updateRun(runID) {
                $0.threadID = nil
                $0.turnID = nil
                $0.sessionLineage = freshState.lineage
            }
        }
        return freshState
    }

    private func failLiveTeamRunBeforeStart(runID: UUID, message: String) async {
        let text = RunTranscriptPresentation.storedText(
            "\n\(message)\n",
            section: .diagnostic
        )
        updateRun(runID) {
            $0.status = .failed
            $0.completedAt = .now
        }
        await recordTranscript(text, runID: runID)
        record.activity?.status = .paused
        record.activity?.liveTeam?.resumeCheckpoint = .recoverRun(runID)
        statusMessage = "Paused after an agent start failure"
        errorMessage = message
        await noteLiveTeamFailureAndReviewIfRepeated(runID: runID)
        if isClosing {
            await completeCloseAfterTerminalEvent()
        } else {
            try? await persist()
        }
    }

    private func recoverLiveTeamRun(_ interruptedRun: RunRecord) async {
        guard let snapshot = interruptedRun.liveTeamMember else {
            pauseLiveTeamActivity(message: "The interrupted turn has no saved agent assignment.")
            return
        }
        let checkpoint = LiveTeamCheckpoint(
            memberID: snapshot.member.id,
            cycle: snapshot.cycle,
            revision: snapshot.revision
        )
        let recoveryPrompt = """
        INTERRUPTED MEMBER RECOVERY

        The preceding Codeness member turn was interrupted and may have partially changed the repository. Inspect the current state, recover the member's exact launch responsibility without blindly replaying completed edits, and finish with factual evidence for the Coordinator.

        ORIGINAL IMMUTABLE ASSIGNMENT

        \(interruptedRun.prompt)
        """
        record.activity?.liveTeam?.resumeCheckpoint = .recoverRun(interruptedRun.id)
        await performLiveTeam(
            checkpoint: checkpoint,
            promptOverride: recoveryPrompt,
            snapshotOverride: snapshot,
            allowsSessionFallback: true
        )
    }

    private func beginLiveTeamRouting(runID: UUID, finalOutput: String) async {
        guard !completingRunIDs.contains(runID),
              run(withID: runID)?.liveTeamMember != nil else { return }
        completingRunIDs.insert(runID)
        activatePendingLiveTeamGoalAmendment()
        updateRun(runID) {
            $0.status = .routing
            $0.relayError = nil
            $0.coordinatorDecision = nil
        }
        record.activity?.liveTeam?.resumeCheckpoint = .routeCompletedRun(runID)
        statusMessage = "Activating safe-boundary changes…"
        do {
            try await persist()
        } catch {
            completingRunIDs.remove(runID)
            updateRun(runID) {
                $0.status = .paused
                $0.relayError = "The completed result could not be saved before work routing."
            }
            record.activity?.status = .paused
            errorMessage = "Codeness did not route the completed result because it could not be saved: \(error.localizedDescription)"
            try? await persist()
            return
        }

        guard await activatePendingLiveTeamRevisionAtSafeBoundary() else {
            completingRunIDs.remove(runID)
            return
        }
        statusMessage = "Preparing handoff…"
        routingTasks[runID] = Task { [weak self] in
            await self?.routeLiveTeamRun(runID: runID, finalOutput: finalOutput)
        }
    }

    private func routeLiveTeamRun(runID: UUID, finalOutput: String) async {
        defer {
            completingRunIDs.remove(runID)
            routingTasks.removeValue(forKey: runID)
        }
        guard let router = liveTeamCoordinatorRouter,
              let activity = record.activity,
              let state = activity.liveTeam,
              let definition = state.currentDefinition,
              let run = run(withID: runID),
              let snapshot = run.liveTeamMember else { return }

        var completedOnce = state.completedOnceMemberIDs
        if snapshot.member.runPolicy == .once {
            completedOnce.insert(snapshot.member.id)
        }
        let proposedCheckpoint = LiveTeamStateMachine.nextCheckpoint(
            after: snapshot.member.id,
            cycle: snapshot.cycle,
            in: definition,
            completedOnceMemberIDs: completedOnce
        )
        let context = LiveTeamCoordinatorContext(
            workingGoal: definition.workingGoal,
            definition: definition,
            sourceMember: snapshot,
            proposedNextMember: proposedCheckpoint.flatMap {
                definition.member(id: $0.memberID)
            },
            previousHandoff: state.coordinatorHandoff,
            recentDecisions: activity.runs.compactMap(\.coordinatorDecision).suffix(4),
            sourceResult: finalOutput
        )
        do {
            var decision = try await router.coordinate(
                context,
                configuration: definition.coordinator,
                cwd: record.canonicalPath
            )
            guard !isClosing else { return }
            decision.runLabel = normalizedRunLabel(
                decision.runLabel,
                fallback: snapshot.member.name
            )
            updateRun(runID) {
                $0.coordinatorDecision = decision
                $0.status = .completed
                $0.relayError = nil
            }
            record.activity?.liveTeam?.coordinatorHandoff = decision.handoff
            record.activity?.liveTeam?.lastCoordinatorDecision = decision
            record.activity?.liveTeam?.resumeCheckpoint = .applyCoordinatorDecision(runID)
            do {
                try await persist()
            } catch {
                updateRun(runID) {
                    $0.status = .paused
                    $0.relayError = "The routing decision could not be saved."
                }
                pauseLiveTeamActivity(
                    message: "The routing decision could not be saved: \(error.localizedDescription)"
                )
                try? await persist()
                return
            }
            guard await releaseFreshLiveTeamSessionIfNeeded(for: runID) else {
                return
            }
            await applyLiveTeamCoordinatorDecision(runID: runID, decision: decision)
        } catch {
            guard !isClosing else { return }
            updateRun(runID) {
                $0.status = .paused
                $0.relayError = error.localizedDescription
            }
            record.activity?.liveTeam?.resumeCheckpoint = .routeCompletedRun(runID)
            pauseLiveTeamActivity(message: "Handoff paused: \(error.localizedDescription)")
            try? await persist()
        }
    }

    private func applyLiveTeamCoordinatorDecision(
        runID: UUID,
        decision: LiveTeamCoordinatorDecision
    ) async {
        guard let run = run(withID: runID),
              let snapshot = run.liveTeamMember,
              var state = record.activity?.liveTeam,
              let definition = state.currentDefinition else { return }

        state.workerTurnsSinceStrategicReview += 1
        state.lastCoordinatorDecision = decision
        state.coordinatorHandoff = decision.handoff
        record.activity?.liveTeam = state

        switch decision.disposition {
        case .retryCurrent:
            let retryCount = state.localRetryMemberID == snapshot.member.id
                ? state.localRetryCount
                : 0
            guard retryCount < 1,
                  let currentMember = definition.member(id: snapshot.member.id) else {
                await requestLiveTeamStrategicReview(
                    reason: "Work routing requested another retry for \(snapshot.member.name), exceeding the one-retry local limit or referring to a removed agent.",
                    automatic: true,
                    continuation: nextLiveTeamCheckpoint(after: snapshot),
                    unrunnable: true,
                    sourceRunID: runID
                )
                return
            }
            record.activity?.liveTeam?.localRetryMemberID = snapshot.member.id
            record.activity?.liveTeam?.localRetryCount = retryCount + 1
            let checkpoint = LiveTeamCheckpoint(
                memberID: currentMember.id,
                cycle: snapshot.cycle,
                revision: definition.revision
            )
            let retryPrompt = """
            COORDINATOR RETRY

            The Coordinator judged the preceding local result incomplete and permits one bounded retry. Inspect the repository's current state; do not blindly replay edits.

            COORDINATOR HANDOFF
            \(decision.handoff)

            \(LiveTeamPromptBuilder.memberPrompt(
                snapshot: LiveTeamMemberSnapshot(
                    member: currentMember,
                    workingGoal: definition.workingGoal,
                    revision: definition.revision,
                    cycle: snapshot.cycle,
                    sessionSlotID: currentMember.sessionPolicy.persistentSlotID(
                        memberID: currentMember.id
                    ) ?? "fresh:\(currentMember.id):retry"
                ),
                handoff: decision.handoff
            ))
            """
            await scheduleLiveTeamRun(
                checkpoint,
                afterRunID: runID,
                promptOverride: retryPrompt
            )

        case .pause:
            let failures = (state.memberFailureCounts[snapshot.member.id] ?? 0) + 1
            record.activity?.liveTeam?.memberFailureCounts[snapshot.member.id] = failures
            let failureThreshold = liveTeamRuntimeConfiguration?
                .oversightPolicy.repeatedFailureThreshold ?? 2
            let repeated = failures >= failureThreshold
            let reason = repeated
                ? "\(snapshot.member.name) has remained blocked \(failureThreshold) times."
                : decision.evidence.isEmpty
                    ? "An older work-routing action requested a strategy review."
                    : "An older work-routing action requested a strategy review: \(decision.evidence)"
            await requestLiveTeamStrategicReview(
                reason: reason,
                automatic: true,
                continuation: LiveTeamCheckpoint(
                    memberID: snapshot.member.id,
                    cycle: snapshot.cycle,
                    revision: definition.revision
                ),
                unrunnable: repeated,
                sourceRunID: runID
            )

        case .requestOversight:
            markLiveTeamMemberComplete(snapshot)
            await requestLiveTeamStrategicReview(
                reason: decision.evidence.isEmpty
                    ? "Work routing requested a strategy review."
                    : decision.evidence,
                automatic: true,
                continuation: nextLiveTeamCheckpoint(after: snapshot),
                unrunnable: false,
                sourceRunID: runID
            )

        case .completionCandidate:
            markLiveTeamMemberComplete(snapshot)
            await requestLiveTeamStrategicReview(
                reason: decision.evidence.isEmpty
                    ? "Work routing suggests the fixed goal may be complete and no agents may be needed."
                    : "Work routing suggests the fixed goal may be complete and no agents may be needed: \(decision.evidence)",
                automatic: true,
                continuation: nextLiveTeamCheckpoint(after: snapshot),
                unrunnable: false,
                sourceRunID: runID
            )

        case .continueTeam:
            markLiveTeamMemberComplete(snapshot)
            record.activity?.liveTeam?.localRetryMemberID = nil
            record.activity?.liveTeam?.localRetryCount = 0
            let next = nextLiveTeamCheckpoint(after: snapshot)
            guard let next else {
                await requestLiveTeamStrategicReview(
                    reason: "Work routing chose Continue, but no eligible agent remains.",
                    automatic: true,
                    continuation: nil,
                    unrunnable: true,
                    sourceRunID: runID
                )
                return
            }
            if next.cycle > snapshot.cycle {
                record.activity?.liveTeam?.cyclesSinceStrategicReview += 1
                record.activity?.liveTeam?.cyclesUnderCurrentRevision += 1
            }
            if var request = record.activity?.liveTeam?.strategicReviewAfterBoundary {
                record.activity?.liveTeam?.strategicReviewAfterBoundary = nil
                request.continuation = next
                request.sourceRunID = runID
                await invokeLiveTeamOverseer(request)
                return
            }
            if record.activity?.liveTeam?.boardGoalAmendmentPendingReview == true {
                record.activity?.liveTeam?.boardGoalAmendmentPendingReview = false
                await requestLiveTeamStrategicReview(
                    reason: "The user amended the goal.",
                    automatic: false,
                    continuation: next,
                    unrunnable: false,
                    sourceRunID: runID
                )
                return
            }
            if liveTeamPeriodicReviewIsDue {
                await requestLiveTeamStrategicReview(
                    reason: "Periodic control review reached its round or agent-turn limit.",
                    automatic: true,
                    continuation: next,
                    unrunnable: false,
                    sourceRunID: runID
                )
                return
            }
            await scheduleLiveTeamRun(next, afterRunID: runID)
        }
    }

    private func markLiveTeamMemberComplete(_ snapshot: LiveTeamMemberSnapshot) {
        guard snapshot.member.runPolicy == .once else { return }
        record.activity?.liveTeam?.completedOnceMemberIDs.insert(snapshot.member.id)
    }

    private func nextLiveTeamCheckpoint(
        after snapshot: LiveTeamMemberSnapshot
    ) -> LiveTeamCheckpoint? {
        guard let state = record.activity?.liveTeam,
              let definition = state.currentDefinition else { return nil }
        var completed = state.completedOnceMemberIDs
        if snapshot.member.runPolicy == .once {
            completed.insert(snapshot.member.id)
        }
        return LiveTeamStateMachine.nextCheckpoint(
            after: snapshot.member.id,
            cycle: snapshot.cycle,
            in: definition,
            completedOnceMemberIDs: completed,
            preferredMemberID: state.pendingRevision?.preferredNextMemberID
        )
    }

    private func scheduleLiveTeamRun(
        _ checkpoint: LiveTeamCheckpoint,
        afterRunID: UUID,
        promptOverride: String? = nil
    ) async {
        record.activity?.liveTeam?.checkpoint = checkpoint
        record.activity?.liveTeam?.resumeCheckpoint = .perform(checkpoint)
        if pauseAfterCurrent || isClosing || record.activity?.status == .paused {
            record.activity?.status = .paused
            statusMessage = "Paused before \(liveTeamMemberName(at: checkpoint).lowercased())"
            try? await persist()
        } else {
            await performLiveTeam(
                checkpoint: checkpoint,
                promptOverride: promptOverride
            )
        }
        _ = afterRunID
    }

    private var liveTeamPeriodicReviewIsDue: Bool {
        guard let state = record.activity?.liveTeam,
              let runtime = liveTeamRuntimeConfiguration else { return false }
        return runtime.oversightPolicy.periodicReviewIsDue(
            roundsSinceReview: state.cyclesSinceStrategicReview,
            workerTurnsSinceReview: state.workerTurnsSinceStrategicReview,
            lastReviewAt: state.lastStrategicReviewAt
        )
    }

    private func releaseFreshLiveTeamSessionIfNeeded(for runID: UUID) async -> Bool {
        guard let run = run(withID: runID),
              let snapshot = run.liveTeamMember,
              snapshot.member.sessionPolicy == .freshEveryRun,
              let session = record.activity?.stepSessions.removeValue(
                  forKey: snapshot.sessionSlotID
              ) else { return true }
        guard let sessionID = session.providerSessionID else { return true }
        do {
            try await persist()
        } catch {
            record.activity?.stepSessions[snapshot.sessionSlotID] = session
            pauseLiveTeamActivity(
                message: "Fresh session cleanup paused before the next agent."
            )
            errorMessage = "Codeness kept the provider session because its removal could not be saved: \(error.localizedDescription)"
            return false
        }
        await releaseProviderSessions([ProviderSessionReference(
            providerID: session.target.providerID,
            sessionID: sessionID
        )])
        return true
    }

    private func pauseLiveTeamActivity(message: String) {
        record.activity?.status = .paused
        statusMessage = message
    }

    private func liveTeamMemberName(at checkpoint: LiveTeamCheckpoint) -> String {
        record.activity?.liveTeam?.currentDefinition?.member(id: checkpoint.memberID)?.name
            ?? "agent"
    }

    private func requestLiveTeamStrategicReview(
        reason: String,
        automatic: Bool,
        continuation: LiveTeamCheckpoint?,
        unrunnable: Bool,
        sourceRunID: UUID? = nil,
        leavePaused: Bool = false
    ) async {
        let request = LiveTeamOverseerRequest(
            mode: .strategicReview,
            reason: unrunnable ? "UNRUNNABLE: \(reason)" : reason,
            sourceRunID: sourceRunID,
            continuation: continuation,
            automatic: automatic,
            leavePaused: leavePaused
        )
        await invokeLiveTeamOverseer(request)
    }

    private func invokeLiveTeamOverseer(_ request: LiveTeamOverseerRequest) async {
        if let liveTeamRuntimeConfigurationProvider {
            liveTeamRuntimeConfiguration = liveTeamRuntimeConfigurationProvider(record.settings)
        }
        guard !isClosing,
              let router = liveTeamOverseerRouter,
              let runtime = liveTeamRuntimeConfiguration,
              let activity = record.activity,
              var state = activity.liveTeam else {
            pauseLiveTeamActivity(message: "Codeness cannot review the strategy right now.")
            return
        }
        if pauseAfterCurrent {
            state.resumeCheckpoint = .invokeOverseer(request)
            state.boardDirectionReason = nil
            record.activity?.liveTeam = state
            record.activity?.status = .paused
            statusMessage = "Paused before \(request.mode.displayName.lowercased())"
            try? await persist()
            return
        }
        if request.mode == .bootstrap || request.mode == .strategicReview {
            state.lastStrategicReviewAt = .now
        }
        liveTeamControlInvocationCount += 1
        defer { liveTeamControlInvocationCount = max(0, liveTeamControlInvocationCount - 1) }
        state.resumeCheckpoint = .invokeOverseer(request)
        state.boardDirectionReason = nil
        record.activity?.liveTeam = state
        record.activity?.status = .running
        statusMessage = switch request.mode {
        case .bootstrap: "Codeness · Preparing agents…"
        case .strategicReview: "Codeness · Reviewing strategy…"
        case .completionReview: "Codeness · Reviewing completion…"
        case .migration: "Codeness · Preparing agents…"
        }
        do {
            try await persist()
        } catch {
            pauseLiveTeamActivity(message: "Paused before review")
            errorMessage = "Could not save the review point: \(error.localizedDescription)"
            try? await persist()
            return
        }

        let context = makeLiveTeamOverseerContext(reason: request.reason)
        do {
            switch request.mode {
            case .bootstrap:
                let definition = try await router.bootstrap(
                    context,
                    configuration: state.overseer,
                    defaultCoordinator: runtime.defaultCoordinator,
                    cwd: record.canonicalPath
                )
                guard !isClosing else { return }
                try await installInitialLiveTeamDefinition(
                    definition,
                    actor: .overseer,
                    reason: definition.strategicReason,
                    evidence: "Codeness prepared the first agents."
                )
                guard let checkpoint = record.activity?.liveTeam?.checkpoint else {
                    throw LiveTeamRevisionError.invalid(
                        "The first setup has no eligible agent."
                    )
                }
                if request.leavePaused {
                    record.activity?.status = .paused
                    record.activity?.liveTeam?.resumeCheckpoint = .perform(checkpoint)
                    statusMessage = "Agents ready; paused for your review"
                    try await persist()
                } else {
                    await performLiveTeam(checkpoint: checkpoint)
                }

            case .strategicReview:
                let decision = try await router.reviewStrategy(
                    context,
                    configuration: state.overseer,
                    cwd: record.canonicalPath
                )
                guard !isClosing else { return }
                await applyLiveTeamStrategicDecision(decision, request: request)

            case .completionReview:
                let decision = try await router.reviewCompletion(
                    context,
                    configuration: state.overseer,
                    cwd: record.canonicalPath
                )
                guard !isClosing else { return }
                await applyLiveTeamCompletionDecision(decision, request: request)

            case .migration:
                throw AgentProviderError.invalidResponse(
                    "earlier activity conversion does not resume through this checkpoint"
                )
            }
        } catch {
            guard !isClosing else { return }
            record.activity?.status = .paused
            record.activity?.liveTeam?.resumeCheckpoint = .invokeOverseer(request)
            statusMessage = "Codeness needs attention during \(request.mode.displayName.lowercased())"
            errorMessage = error.localizedDescription
            try? await persist()
        }
    }

    private func installInitialLiveTeamDefinition(
        _ definition: LiveTeamDefinition,
        actor: LiveTeamRevisionActor,
        reason: String,
        evidence: String
    ) async throws {
        guard definition.revision == 1,
              definition.validationMessage == nil,
              record.activity?.liveTeam?.currentDefinition == nil else {
            throw LiveTeamRevisionError.invalid(
                definition.validationMessage
                    ?? "The initial agent setup is invalid."
            )
        }
        guard let checkpoint = LiveTeamStateMachine.initialCheckpoint(for: definition) else {
            throw LiveTeamRevisionError.invalid("The initial setup has no eligible agent.")
        }
        let previousActivity = record.activity
        record.activity?.liveTeam?.currentDefinition = definition
        record.activity?.liveTeam?.overseer.target = definition.overseerTarget
        record.activity?.liveTeam?.checkpoint = checkpoint
        record.activity?.liveTeam?.resumeCheckpoint = .perform(checkpoint)
        record.activity?.liveTeam?.editHistory.append(LiveTeamEditRecord(
            revision: 1,
            actor: actor,
            summary: "Prepared \(definition.members.count) agents",
            reason: reason,
            evidence: evidence
        ))
        do {
            // This is the hard durability barrier before the first worker
            // session is prepared.
            try await persist()
        } catch {
            record.activity = previousActivity
            throw error
        }
    }

    private func applyLiveTeamStrategicDecision(
        _ decision: LiveTeamStrategicDecision,
        request: LiveTeamOverseerRequest
    ) async {
        guard let current = record.activity?.liveTeam?.currentDefinition else {
            pauseLiveTeamActivity(message: "Strategic review has no current agents.")
            return
        }
        switch decision.action {
        case .complete:
            await completeLiveTeam(
                reason: decision.reason,
                evidence: decision.evidence
            )

        case .keep:
            let continuation = preferredLiveTeamContinuation(
                requested: request.continuation,
                preferredMemberID: nil
            )
            record.activity?.liveTeam?.workerTurnsSinceStrategicReview = 0
            record.activity?.liveTeam?.cyclesSinceStrategicReview = 0
            record.activity?.liveTeam?.resumeCheckpoint = continuation.map {
                .perform($0)
            }
            if request.leavePaused || pauseAfterCurrent {
                record.activity?.status = .paused
                statusMessage = "Strategy reviewed; current agents retained"
                try? await persist()
            } else if let continuation {
                await performLiveTeam(checkpoint: continuation)
            } else {
                record.activity?.status = .paused
                record.activity?.liveTeam?.resumeCheckpoint = .invokeOverseer(
                    autonomousContinuationOverseerRequest(
                        previousReason: "The strategy was kept even though no eligible agent remained.",
                        sourceRunID: request.sourceRunID,
                        continuation: nil
                    )
                )
                statusMessage = "Strategy review returned no runnable agent"
                errorMessage = "Codeness kept a strategy that has no eligible agent. Resume will retry the strategic decision."
                try? await persist()
            }

        case .pause:
            let continuation = preferredLiveTeamContinuation(
                requested: request.continuation,
                preferredMemberID: nil
            )
            record.activity?.status = .paused
            record.activity?.liveTeam?.resumeCheckpoint = .invokeOverseer(
                autonomousContinuationOverseerRequest(
                    previousReason: decision.reason,
                    sourceRunID: request.sourceRunID,
                    continuation: continuation
                )
            )
            record.activity?.liveTeam?.boardDirectionReason = nil
            record.activity?.liveTeam?.editHistory.append(LiveTeamEditRecord(
                revision: current.revision,
                actor: .overseer,
                summary: "Rejected autonomous pause",
                reason: decision.reason,
                evidence: decision.evidence
            ))
            statusMessage = "Strategy review returned an invalid pause"
            errorMessage = "Codeness cannot ask you to manage an internal stage. Resume will retry the strategic decision."
            try? await persist()

        case .revise:
            guard let proposed = decision.proposedDefinition else {
                pauseLiveTeamActivity(message: "Codeness proposed no replacement agents.")
                return
            }
            let isUnrunnable = request.reason.hasPrefix("UNRUNNABLE:")
            if request.automatic,
               record.activity?.liveTeam?.cyclesUnderCurrentRevision == 0,
               current.revision > 1,
               !isUnrunnable,
               let continuation = request.continuation {
                record.activity?.liveTeam?.workerTurnsSinceStrategicReview = 0
                record.activity?.liveTeam?.cyclesSinceStrategicReview = 0
                await scheduleLiveTeamRun(
                    continuation,
                    afterRunID: request.sourceRunID ?? UUID()
                )
                return
            }

            do {
                let pending = try LiveTeamStateMachine.pendingRevision(
                    definition: proposed,
                    baseRevision: current.revision,
                    actor: .overseer,
                    reason: decision.reason,
                    evidence: decision.evidence,
                    preferredNextMemberID: decision.preferredNextMemberID,
                    currentDefinition: current,
                    existingPending: record.activity?.liveTeam?.pendingRevision
                )
                record.activity?.liveTeam?.pendingRevision = pending
                record.activity?.liveTeam?.resumeCheckpoint = request.continuation.map {
                    .perform($0)
                }
                guard await activatePendingLiveTeamRevision() else { return }
                record.activity?.liveTeam?.workerTurnsSinceStrategicReview = 0
                record.activity?.liveTeam?.cyclesSinceStrategicReview = 0
                record.activity?.liveTeam?.cyclesUnderCurrentRevision = 0
                let continuation = preferredLiveTeamContinuation(
                    requested: request.continuation,
                    preferredMemberID: decision.preferredNextMemberID
                )
                if let continuation, request.leavePaused || pauseAfterCurrent {
                    record.activity?.status = .paused
                    record.activity?.liveTeam?.resumeCheckpoint = .perform(continuation)
                    statusMessage = "Agent changes applied; paused"
                    try? await persist()
                } else if let continuation {
                    await performLiveTeam(checkpoint: continuation)
                } else {
                    record.activity?.liveTeam?.resumeCheckpoint = .invokeOverseer(
                        autonomousContinuationOverseerRequest(
                            previousReason: "The changed setup has no eligible agent.",
                            sourceRunID: request.sourceRunID,
                            continuation: nil
                        )
                    )
                    pauseLiveTeamActivity(message: "The changed setup has no eligible agent.")
                    try? await persist()
                }
            } catch {
                record.activity?.status = .paused
                record.activity?.liveTeam?.resumeCheckpoint = .invokeOverseer(request)
                errorMessage = error.localizedDescription
                statusMessage = "Agent changes could not be applied"
                try? await persist()
            }
        }
    }

    private func applyLiveTeamCompletionDecision(
        _ decision: LiveTeamCompletionDecision,
        request: LiveTeamOverseerRequest
    ) async {
        switch decision.outcome {
        case .complete:
            await completeLiveTeam(reason: decision.reason, evidence: decision.evidence)

        case .continueWork:
            await requestLiveTeamStrategicReview(
                reason: "Completion review found remaining work: \(decision.reason)",
                automatic: true,
                continuation: request.continuation,
                unrunnable: false,
                sourceRunID: request.sourceRunID
            )

        case .pause:
            let revision = record.activity?.liveTeam?.currentDefinition?.revision ?? 1
            let continuation = preferredLiveTeamContinuation(
                requested: request.continuation,
                preferredMemberID: nil
            )
            record.activity?.status = .paused
            record.activity?.liveTeam?.resumeCheckpoint = .invokeOverseer(
                autonomousContinuationOverseerRequest(
                    previousReason: decision.reason,
                    sourceRunID: request.sourceRunID,
                    continuation: continuation
                )
            )
            record.activity?.liveTeam?.boardDirectionReason = nil
            record.activity?.liveTeam?.editHistory.append(LiveTeamEditRecord(
                revision: revision,
                actor: .overseer,
                summary: "Rejected autonomous pause",
                reason: decision.reason,
                evidence: decision.evidence
            ))
            statusMessage = "Completion review returned an invalid pause"
            errorMessage = "Codeness cannot ask you to manage an internal stage. Resume will return to strategic control."
            try? await persist()
        }
    }

    private func completeLiveTeam(reason: String, evidence: String) async {
        let revision = record.activity?.liveTeam?.currentDefinition?.revision ?? 1
        record.activity?.status = .completed
        record.activity?.completedAt = .now
        record.activity?.liveTeam?.checkpoint = nil
        record.activity?.liveTeam?.resumeCheckpoint = nil
        record.activity?.liveTeam?.editHistory.append(LiveTeamEditRecord(
            revision: revision,
            actor: .overseer,
            summary: "Confirmed goal complete",
            reason: reason,
            evidence: evidence
        ))
        statusMessage = "Activity complete"
        pauseAfterCurrent = false
        viewState.pauseAfterCurrent = false
        scheduleViewStateSave()
        await persistCompletedActivityAndDetachSessions()
    }

    private func autonomousContinuationOverseerRequest(
        previousReason: String,
        sourceRunID: UUID?,
        continuation: LiveTeamCheckpoint?
    ) -> LiveTeamOverseerRequest {
        LiveTeamOverseerRequest(
            mode: .strategicReview,
            reason: """
            Codeness previously stopped at an internal strategy boundary for this reason: \(previousReason)

            This was not a valid completion decision. Reassess the fixed user goal and durable evidence. Earlier working goals, agent instructions, handoffs, strategies, and self-imposed stage gates are project state you control; they cannot manufacture a need for user approval. Choose and constrain the next reversible internal stage, then keep or replace the agents. Complete the activity only when the fixed goal is satisfied and no work remains.
            """,
            sourceRunID: sourceRunID,
            continuation: continuation,
            automatic: false
        )
    }

    private func makeLiveTeamOverseerContext(reason: String) -> LiveTeamOverseerContext {
        let activity = record.activity
        let evidence = activity?.runs.suffix(12).map { run in
            LiveTeamEvidenceItem(
                sequence: run.sequence,
                memberName: run.liveTeamMember?.member.name
                    ?? run.workflowStep?.name
                    ?? run.displayName,
                status: run.status,
                result: run.finalOutput
                    ?? run.coordinatorDecision?.handoff
                    ?? run.workflowHandoff?.text
                    ?? run.relayError
                    ?? "No result recorded.",
                coordinatorEvidence: run.coordinatorDecision?.evidence
                    ?? run.workflowHandoff?.text
                    ?? ""
            )
        } ?? []
        var targetOptions = liveTeamRuntimeConfiguration?.targetOptions ?? []
        let existingTargets = (activity?.liveTeam?.currentDefinition?.members.map(\.target) ?? [])
            + [activity?.liveTeam?.currentDefinition?.coordinator.target].compactMap { $0 }
            + [activity?.liveTeam?.currentDefinition?.overseerTarget].compactMap { $0 }
            + (activity?.workflow?.steps.map(\.target) ?? [])
            + [activity?.workflow?.coordinator.target].compactMap { $0 }
        for target in existingTargets where !targetOptions.contains(where: { $0.target == target }) {
            targetOptions.append(LiveTeamTargetOption(
                id: "existing-\(targetOptions.count + 1)",
                label: "Existing \(target.providerID.rawValue) \(target.model)",
                target: target
            ))
        }
        return LiveTeamOverseerContext(
            userGoal: activity?.goal ?? "",
            currentDefinition: activity?.liveTeam?.currentDefinition,
            coordinatorHandoff: activity?.liveTeam?.coordinatorHandoff,
            recentEvidence: Array(evidence),
            editHistory: Array(activity?.liveTeam?.editHistory.suffix(12) ?? []),
            targetOptions: targetOptions,
            triggerReason: reason,
            legacyWorkflow: activity?.workflow,
            legacyCursor: activity?.workflowCursor,
            legacySessions: activity?.stepSessions ?? [:]
        )
    }

    private func preferredLiveTeamContinuation(
        requested: LiveTeamCheckpoint?,
        preferredMemberID: String?
    ) -> LiveTeamCheckpoint? {
        guard let state = record.activity?.liveTeam,
              let definition = state.currentDefinition else { return nil }
        if let preferredMemberID,
           let member = definition.member(id: preferredMemberID),
           member.runPolicy == .everyCycle
                || !state.completedOnceMemberIDs.contains(member.id) {
            return LiveTeamCheckpoint(
                memberID: member.id,
                cycle: requested?.cycle ?? state.checkpoint?.cycle ?? 1,
                revision: definition.revision
            )
        }
        return LiveTeamStateMachine.checkpoint(
            reconciling: requested,
            in: definition,
            completedOnceMemberIDs: state.completedOnceMemberIDs
        )
    }

    private func activatePendingLiveTeamRevisionAtSafeBoundary() async -> Bool {
        guard record.activity?.liveTeam?.pendingRevision != nil else {
            return true
        }
        return await activatePendingLiveTeamRevision()
    }

    private func activatePendingLiveTeamRevision() async -> Bool {
        guard let activity = record.activity,
              let oldDefinition = activity.liveTeam?.currentDefinition,
              let pending = activity.liveTeam?.pendingRevision,
              pending.baseRevision == oldDefinition.revision else {
            errorMessage = LiveTeamRevisionError.stale(
                base: record.activity?.liveTeam?.pendingRevision?.baseRevision ?? 0,
                current: record.activity?.liveTeam?.currentDefinition?.revision ?? 0
            ).localizedDescription
            return false
        }
        let newDefinition = pending.definition
        guard newDefinition.validationMessage == nil else {
            errorMessage = newDefinition.validationMessage
            return false
        }
        let previousActivity = activity
        let protectedFreshSlot = activity.runs.last(where: {
            $0.liveTeamMember?.member.sessionPolicy == .freshEveryRun
                && [.routing, .completed, .paused].contains($0.status)
        })?.liveTeamMember?.sessionSlotID
        let reconciliation = reconciledLiveTeamSessions(
            oldDefinition: oldDefinition,
            newDefinition: newDefinition,
            existing: activity.stepSessions,
            protectedSlotID: protectedFreshSlot
        )
        record.activity?.stepSessions = reconciliation.sessions
        record.activity?.liveTeam?.currentDefinition = newDefinition
        record.activity?.liveTeam?.overseer.target = newDefinition.overseerTarget
        record.activity?.liveTeam?.pendingRevision = nil
        record.activity?.liveTeam?.cyclesUnderCurrentRevision = 0
        record.activity?.liveTeam?.completedOnceMemberIDs =
            LiveTeamStateMachine.reconciledCompletedOnceMemberIDs(
                activity.liveTeam?.completedOnceMemberIDs ?? [],
                from: oldDefinition,
                to: newDefinition
            )
        record.activity?.liveTeam?.editHistory.append(LiveTeamEditRecord(
            revision: newDefinition.revision,
            actor: pending.actor,
            summary: LiveTeamStateMachine.activationSummary(
                from: oldDefinition,
                to: newDefinition
            ),
            reason: pending.reason,
            evidence: pending.evidence
        ))
        let completedOnceMemberIDs = record.activity?.liveTeam?.completedOnceMemberIDs ?? []
        if let checkpoint = record.activity?.liveTeam?.checkpoint {
            record.activity?.liveTeam?.checkpoint = LiveTeamStateMachine.checkpoint(
                reconciling: checkpoint,
                in: newDefinition,
                completedOnceMemberIDs: completedOnceMemberIDs
            )
        }
        do {
            try await persist()
        } catch {
            record.activity = previousActivity
            errorMessage = "Could not apply the agent changes: \(error.localizedDescription)"
            pauseLiveTeamActivity(message: "Pending agent changes could not be applied")
            return false
        }
        await releaseProviderSessions(reconciliation.supersededSessions)
        cancelWorkOverviewSummaryRequest()
        return true
    }

    private func reconciledLiveTeamSessions(
        oldDefinition: LiveTeamDefinition,
        newDefinition: LiveTeamDefinition,
        existing: [String: WorkflowSessionState],
        protectedSlotID: String?
    ) -> (
        sessions: [String: WorkflowSessionState],
        supersededSessions: Set<ProviderSessionReference>
    ) {
        let oldMembersBySlot = Dictionary(grouping: oldDefinition.members.compactMap { member in
            member.sessionPolicy.persistentSlotID(memberID: member.id).map {
                ($0, member)
            }
        }, by: \.0)
        let newMembersBySlot = Dictionary(grouping: newDefinition.members.compactMap { member in
            member.sessionPolicy.persistentSlotID(memberID: member.id).map {
                ($0, member)
            }
        }, by: \.0)
        var sessions: [String: WorkflowSessionState] = [:]
        var superseded: Set<ProviderSessionReference> = []

        for (slotID, entries) in newMembersBySlot {
            guard let representative = entries.first?.1 else { continue }
            let previousEntries = oldMembersBySlot[slotID] ?? []
            let previousSession = existing[slotID]
            let preservesHistory: Bool
            if slotID.hasPrefix("member:"),
               let oldMember = previousEntries.first?.1,
               entries.count == 1,
               oldMember.id == representative.id {
                preservesHistory = oldMember.instructions == representative.instructions
                    && !Self.requiresNewLineage(
                        from: oldMember.target,
                        to: representative.target
                    )
            } else if slotID.hasPrefix("shared:"), !previousEntries.isEmpty {
                preservesHistory = previousEntries.allSatisfy { oldEntry in
                    guard let newEntry = entries.first(where: {
                        $0.1.id == oldEntry.1.id
                    }) else { return true }
                    return oldEntry.1.instructions == newEntry.1.instructions
                        && !Self.requiresNewLineage(
                            from: oldEntry.1.target,
                            to: newEntry.1.target
                        )
                }
            } else {
                preservesHistory = false
            }

            if var previousSession, preservesHistory {
                previousSession.target = representative.target
                sessions[slotID] = previousSession
            } else {
                if let previousSession,
                   let sessionID = previousSession.providerSessionID {
                    superseded.insert(ProviderSessionReference(
                        providerID: previousSession.target.providerID,
                        sessionID: sessionID
                    ))
                }
                sessions[slotID] = WorkflowSessionState(
                    stepID: slotID,
                    lineage: (previousSession?.lineage ?? 0) + 1,
                    target: representative.target
                )
            }
        }

        for (slotID, previousSession) in existing where sessions[slotID] == nil {
            if slotID == protectedSlotID {
                sessions[slotID] = previousSession
            } else if let sessionID = previousSession.providerSessionID {
                superseded.insert(ProviderSessionReference(
                    providerID: previousSession.target.providerID,
                    sessionID: sessionID
                ))
            }
        }
        return (sessions, superseded)
    }

    private func noteLiveTeamFailureAndReviewIfRepeated(runID: UUID) async {
        guard let memberID = run(withID: runID)?.liveTeamMember?.member.id else { return }
        let count = (record.activity?.liveTeam?.memberFailureCounts[memberID] ?? 0) + 1
        record.activity?.liveTeam?.memberFailureCounts[memberID] = count
        let failureThreshold = liveTeamRuntimeConfiguration?
            .oversightPolicy.repeatedFailureThreshold ?? 2
        guard count >= failureThreshold, !isClosing else { return }
        let continuation = run(withID: runID)?.liveTeamMember.map {
            LiveTeamCheckpoint(
                memberID: $0.member.id,
                cycle: $0.cycle,
                revision: record.activity?.liveTeam?.currentDefinition?.revision
                    ?? $0.revision
            )
        }
        record.activity?.liveTeam?.resumeCheckpoint = .invokeOverseer(
            LiveTeamOverseerRequest(
                mode: .strategicReview,
                reason: "UNRUNNABLE: \(memberID) failed \(failureThreshold) times.",
                sourceRunID: runID,
                continuation: continuation,
                automatic: true
            )
        )
        statusMessage = "Repeated agent failure requires a strategy review"
    }

    private func recoverInterruptedLiveTeamState() {
        guard record.activity?.status == .running else { return }
        record.activity?.status = .paused
        guard let index = record.activity?.runs.indices.last else {
            if let checkpoint = record.activity?.liveTeam?.checkpoint {
                record.activity?.liveTeam?.resumeCheckpoint = .perform(checkpoint)
            } else if record.activity?.liveTeam?.currentDefinition == nil {
                record.activity?.liveTeam?.resumeCheckpoint = .invokeOverseer(
                    LiveTeamOverseerRequest(
                        mode: .bootstrap,
                        reason: "Recover interrupted initial setup.",
                        automatic: false
                    )
                )
            }
            return
        }
        let run = record.activity?.runs[index]
        if let status = run?.status,
           [.queued, .running, .awaitingApproval].contains(status),
           let runID = run?.id {
            record.activity?.runs[index].status = .interrupted
            record.activity?.runs[index].completedAt = .now
            record.activity?.liveTeam?.resumeCheckpoint = .recoverRun(runID)
        } else if run?.status == .routing,
                  let runID = run?.id,
                  run?.finalOutput?.isEmpty == false {
            record.activity?.liveTeam?.resumeCheckpoint = .routeCompletedRun(runID)
        } else if let runID = run?.id,
                  run?.coordinatorDecision != nil {
            record.activity?.liveTeam?.resumeCheckpoint = .applyCoordinatorDecision(runID)
        }
    }

    private func resumeGeneric() async {
        guard let activity = record.activity,
              let workflow = activity.workflow else { return }
        pauseAfterCurrent = false
        viewState.pauseAfterCurrent = false
        scheduleViewStateSave()
        statusMessage = "Resuming automatic workflow…"

        let checkpoint = activity.workflowResumeCheckpoint
        record.activity?.status = .running
        record.activity?.workflowResumeCheckpoint = nil
        do {
            switch checkpoint {
            case .recoverRun(let runID):
                guard let run = run(withID: runID) else {
                    throw RepositoryCoordinatorError.missingRun(runID)
                }
                await recoverGenericRun(run)
            case .routeCompletedRun(let runID):
                guard let run = run(withID: runID),
                      let output = run.finalOutput,
                      !output.isEmpty else {
                    throw RepositoryCoordinatorError.missingRunOutput(runID)
                }
                await beginGenericRouting(runID: runID, finalOutput: output)
            case .perform(let cursor):
                await performGeneric(
                    cursor: cursor,
                    previousHandoff: activity.runs.last(where: {
                        $0.workflowHandoff != nil
                    })?.workflowHandoff
                )
            case nil:
                if let run = activity.runs.last,
                   let output = run.finalOutput,
                   !output.isEmpty,
                   run.workflowHandoff == nil {
                    await beginGenericRouting(runID: run.id, finalOutput: output)
                } else if let cursor = activity.workflowCursor {
                    await performGeneric(
                        cursor: cursor,
                        previousHandoff: activity.runs.last(where: {
                            $0.workflowHandoff != nil
                        })?.workflowHandoff
                    )
                } else if GenericWorkflowStateMachine.initialCursor(for: workflow) == nil {
                    completeGenericActivity()
                    await persistCompletedActivityAndDetachSessions()
                }
            }
        } catch {
            record.activity?.status = .paused
            record.activity?.workflowResumeCheckpoint = checkpoint
            errorMessage = error.localizedDescription
            try? await persist()
        }
    }

    private func performGeneric(
        cursor: WorkflowCursor,
        previousHandoff: WorkflowHandoff?,
        promptOverride: String? = nil,
        allowsSessionFallback: Bool = false
    ) async {
        activatePendingGoalAmendment()
        guard let workflow = record.activity?.workflow,
              let step = GenericWorkflowStateMachine.step(at: cursor, in: workflow) else {
            pauseGenericActivity(
                message: "The saved workflow cursor does not identify a configured step."
            )
            try? await persist()
            return
        }
        guard !isClosing else {
            record.activity?.status = .paused
            record.activity?.workflowCursor = cursor
            record.activity?.workflowResumeCheckpoint = .perform(cursor)
            return
        }
        record.activity?.status = .running
        record.activity?.workflowCursor = cursor
        record.activity?.workflowResumeCheckpoint = .perform(cursor)
        let prompt = promptOverride ?? GenericPromptBuilder.stepPrompt(
            goal: record.activity?.goal ?? "",
            workflow: workflow,
            step: step,
            cursor: cursor,
            previousHandoff: previousHandoff
        )
        await launchGenericRun(
            step: step,
            cursor: cursor,
            prompt: prompt,
            allowsSessionFallback: allowsSessionFallback
        )
    }

    private func launchGenericRun(
        step: WorkflowStep,
        cursor: WorkflowCursor,
        prompt: String,
        allowsSessionFallback: Bool = false
    ) async {
        guard let agentProviders,
              let workflow = record.activity?.workflow,
              !isClosing else {
            pauseGenericActivity(message: "The agent providers are not available.")
            return
        }
        let previousRunID = record.activity?.runs.last?.id
        let followsLiveRun = followsActiveProgress
            || RunSelectionPolicy.shouldSelectNextRun(
                selectedRunID: selectedRunID,
                activeRunID: previousRunID,
                activeRunIsAtBottom: previousRunID.flatMap { runIsAtBottom[$0] }
            )
        let compatibility = Self.compatibilityRoleAndKind(for: step)
        var sessionState = record.activity?.stepSessions[step.id]
            ?? WorkflowSessionState(stepID: step.id, target: step.target)
        sessionState.target = step.target
        record.activity?.stepSessions[step.id] = sessionState

        let run = RunRecord(
            sequence: (record.activity?.runs.count ?? 0) + 1,
            role: compatibility.role,
            kind: compatibility.kind,
            status: .queued,
            threadID: sessionState.providerSessionID,
            model: step.target.model,
            effort: step.target.options.effort ?? "",
            prompt: prompt,
            workflowStep: WorkflowStepSnapshot(
                step: step,
                loopIteration: cursor.loopIteration
            ),
            agentTarget: step.target,
            sessionLineage: sessionState.lineage
        )
        record.activity?.workflowResumeCheckpoint = .recoverRun(run.id)
        record.activity?.runs.append(run)
        runIsAtBottom[run.id] = true
        if followsLiveRun {
            focusActiveProgress(on: run.id)
        }
        statusMessage = "Starting \(step.name.lowercased())…"
        let launchLeaseID = beginProviderLaunchLease(runID: run.id)
        defer { finishProviderLaunchLease(launchLeaseID) }

        do {
            try await persist()
        } catch {
            let queuedSaveError = error
            record.activity?.runs.removeAll { $0.id == run.id }
            runIsAtBottom.removeValue(forKey: run.id)
            record.activity?.status = .paused
            record.activity?.workflowResumeCheckpoint = .perform(cursor)
            selectedRunID = previousRunID
            try? await persist()
            errorMessage = "Could not save \(step.name) before starting it: \(queuedSaveError.localizedDescription)"
            statusMessage = "Paused before \(step.name.lowercased())"
            return
        }

        guard !isClosing else { return }

        let reusableSessionID = reusableProviderSessionID(
            sessionState,
            stepID: step.id
        )
        var resumedExistingSession = reusableSessionID != nil
        var session: AgentSession
        do {
            guard let preparedSession = try await prepareGenericSession(
                genericSessionRequest(
                    existingSessionID: reusableSessionID,
                    workflow: workflow,
                    step: step
                ),
                runID: run.id,
                using: agentProviders
            ) else { return }
            session = preparedSession
        } catch {
            guard !isClosing else { return }
            guard allowsSessionFallback,
                  let reusableSessionID,
                  Self.confirmsUnavailableSession(error) else {
                await failGenericRunBeforeStart(
                    runID: run.id,
                    message: "Could not prepare \(step.name): \(error.localizedDescription)"
                )
                return
            }
            await recordGenericSessionFallback(runID: run.id, error: error)
            guard !isClosing else { return }
            await releaseProviderSessions([ProviderSessionReference(
                providerID: step.target.providerID,
                sessionID: reusableSessionID
            )])
            guard !isClosing else { return }
            do {
                guard let preparedSession = try await prepareGenericSession(
                    genericSessionRequest(
                        existingSessionID: nil,
                        workflow: workflow,
                        step: step
                    ),
                    runID: run.id,
                    using: agentProviders
                ) else { return }
                session = preparedSession
                sessionState = advanceGenericSessionLineage(
                    sessionState,
                    step: step,
                    runID: run.id
                )
                resumedExistingSession = false
            } catch {
                guard !isClosing else { return }
                await failGenericRunBeforeStart(
                    runID: run.id,
                    message: "Could not prepare \(step.name): \(error.localizedDescription)"
                )
                return
            }
        }

        do {
            sessionState.providerSessionID = session.id
            record.activity?.stepSessions[step.id] = sessionState
            updateRun(run.id) {
                $0.threadID = session.id
                $0.sessionLineage = sessionState.lineage
            }
            try await persist()
        } catch {
            await failGenericRunBeforeStart(
                runID: run.id,
                message: "Could not prepare \(step.name): \(error.localizedDescription)"
            )
            return
        }

        guard !isClosing else {
            updateRun(run.id) { $0.status = .interrupted }
            record.activity?.status = .paused
            record.activity?.workflowResumeCheckpoint = .recoverRun(run.id)
            try? await persist()
            return
        }

        if allowsSessionFallback, resumedExistingSession {
            genericSessionFallbacks[run.id] = GenericSessionFallback(
                cursor: cursor,
                prompt: prompt
            )
        }

        do {
            var handle: AgentRunHandle
            do {
                handle = try await agentProviders.startRun(
                    genericRunRequest(
                        runID: run.id,
                        session: session,
                        prompt: prompt,
                        step: step
                    )
                )
            } catch {
                guard !isClosing else {
                    genericSessionFallbacks.removeValue(forKey: run.id)
                    return
                }
                guard allowsSessionFallback,
                      resumedExistingSession,
                      Self.confirmsUnavailableSession(error) else {
                    throw error
                }
                genericSessionFallbacks.removeValue(forKey: run.id)
                await recordGenericSessionFallback(runID: run.id, error: error)
                guard !isClosing else { return }
                // `prepareSession` successfully attached the resumed phase before
                // `startRun` proved it unavailable. Detach that exact attachment
                // before replacing the durable phase ID with the fallback lineage.
                await releaseProviderSessions([ProviderSessionReference(
                    providerID: session.providerID,
                    sessionID: session.id
                )])
                guard !isClosing else { return }
                guard let preparedSession = try await prepareGenericSession(
                    genericSessionRequest(
                        existingSessionID: nil,
                        workflow: workflow,
                        step: step
                    ),
                    runID: run.id,
                    using: agentProviders
                ) else { return }
                session = preparedSession
                sessionState = advanceGenericSessionLineage(
                    sessionState,
                    step: step,
                    runID: run.id
                )
                sessionState.providerSessionID = session.id
                record.activity?.stepSessions[step.id] = sessionState
                updateRun(run.id) {
                    $0.threadID = session.id
                    $0.sessionLineage = sessionState.lineage
                }
                try await persist()
                guard !isClosing else { return }
                handle = try await agentProviders.startRun(
                    genericRunRequest(
                        runID: run.id,
                        session: session,
                        prompt: prompt,
                        step: step
                    )
                )
            }
            updateRun(run.id) {
                $0.turnID = handle.executionID
                $0.status = .running
            }
            do {
                try await persist()
            } catch {
                errorMessage = "\(step.name) started, but its latest state could not be saved: \(error.localizedDescription)"
            }

            genericRunTasks[run.id] = Task { [weak self] in
                for await event in handle.events {
                    guard let self else { return }
                    await self.handleAgentEvent(event, runID: run.id)
                }
                self?.genericRunTasks.removeValue(forKey: run.id)
            }
            if isClosing {
                statusMessage = "Preparing to stop \(step.name.lowercased())…"
            } else {
                statusMessage = "\(step.name) running"
            }
        } catch {
            genericSessionFallbacks.removeValue(forKey: run.id)
            guard !isClosing else { return }
            await failGenericRunBeforeStart(
                runID: run.id,
                message: "Could not start \(step.name): \(error.localizedDescription)"
            )
        }
    }

    private func genericSessionRequest(
        existingSessionID: String?,
        workflow: WorkflowTemplate,
        step: WorkflowStep
    ) -> AgentSessionRequest {
        AgentSessionRequest(
            existingSessionID: existingSessionID,
            name: "\(repositoryName) — \(step.name)",
            cwd: record.canonicalPath,
            target: step.target,
            developerInstructions: GenericPromptBuilder.sessionInstructions(
                workflow: workflow,
                step: step
            )
        )
    }

    private func genericRunRequest(
        runID: UUID,
        session: AgentSession,
        prompt: String,
        step: WorkflowStep
    ) -> AgentRunRequest {
        AgentRunRequest(
            runID: runID,
            session: session,
            cwd: record.canonicalPath,
            prompt: prompt,
            target: step.target
        )
    }

    private func advanceGenericSessionLineage(
        _ sessionState: WorkflowSessionState,
        step: WorkflowStep,
        runID: UUID,
        updatesRun: Bool = true
    ) -> WorkflowSessionState {
        var freshState = sessionState
        let runLineage = run(withID: runID)?.sessionLineage ?? 0
        freshState.lineage = max(freshState.lineage, runLineage) + 1
        freshState.target = step.target
        freshState.providerSessionID = nil
        record.activity?.stepSessions[step.id] = freshState
        if updatesRun {
            updateRun(runID) {
                $0.threadID = nil
                $0.turnID = nil
                $0.sessionLineage = freshState.lineage
            }
        }
        return freshState
    }

    private func recordGenericSessionFallback(runID: UUID, error: any Error) async {
        let text = RunTranscriptPresentation.storedText(
            "\nThe existing agent session could not be resumed (\(error.localizedDescription)). Retrying automatically in a fresh session.\n",
            section: .diagnostic
        )
        await recordTranscript(text, runID: runID)
        statusMessage = "Recreating the unavailable agent session…"
    }

    private static func confirmsUnavailableSession(_ error: any Error) -> Bool {
        guard let providerError = error as? AgentProviderError,
              case .sessionUnavailable = providerError else {
            return false
        }
        return true
    }

    private func failGenericRunBeforeStart(runID: UUID, message: String) async {
        let text = RunTranscriptPresentation.storedText(
            "\n\(message)\n",
            section: .diagnostic
        )
        updateRun(runID) {
            $0.status = .failed
            $0.completedAt = .now
        }
        await recordTranscript(text, runID: runID)
        record.activity?.status = .paused
        record.activity?.workflowResumeCheckpoint = .recoverRun(runID)
        statusMessage = "Paused after an agent start failure"
        errorMessage = message
        if isClosing {
            await completeCloseAfterTerminalEvent()
        } else {
            try? await persist()
        }
    }

    private func handleAgentEvent(_ event: AgentEvent, runID: UUID) async {
        guard let run = run(withID: runID) else { return }
        let activeStatuses: [RunStatus] = [.queued, .running, .awaitingApproval]
        let isTerminalEvent: Bool = switch event {
        case .completed, .interrupted, .sessionUnavailable, .failed: true
        case .started, .transcript, .diagnostic, .tokenUsage, .interaction,
                .interactionResolved: false
        }
        guard activeStatuses.contains(run.status)
                || (isTerminalEvent && interactionSafetyTerminatingRunIDs.contains(runID))
                || (isTerminalEvent && transcriptBackpressureRunIDs.contains(runID)) else {
            return
        }
        if isTerminalEvent {
            clearPendingInteractions()
        }
        switch event {
        case .started(let executionID):
            guard !transcriptBackpressureRunIDs.contains(runID) else { return }
            genericSessionFallbacks.removeValue(forKey: runID)
            liveTeamSessionFallbacks.removeValue(forKey: runID)
            updateRun(runID) {
                $0.turnID = executionID
                $0.status = .running
            }
            try? await persist()

        case .transcript(let text), .diagnostic(let text):
            guard !text.isEmpty else { return }
            await recordTranscript(text, runID: runID)

        case .tokenUsage(let usage):
            updateRun(runID) { $0.tokenUsage = usage }
            await appendTokenUsage(usage, runID: runID)

        case .interaction(let interaction):
            guard !transcriptBackpressureRunIDs.contains(runID) else { return }
            await presentGenericInteraction(
                interaction,
                runID: runID,
                providerID: run.agentTarget?.providerID
            )
            try? await persist()

        case .interactionResolved(let interactionID):
            if let presentationKey = genericInteractionRoutes.first(where: {
                $0.value.runID == runID && $0.value.interactionID == interactionID
            })?.key {
                await finishGenericInteraction(presentationKey: presentationKey)
            }

        case .completed(let output, let duration, let usage):
            if await finishInteractionSafetyStopIfNeeded(runID: runID) { return }
            guard !transcriptBackpressureRunIDs.contains(runID) else {
                await finishBackpressuredRunAfterTerminalEvent(runID: runID)
                return
            }
            genericSessionFallbacks.removeValue(forKey: runID)
            liveTeamSessionFallbacks.removeValue(forKey: runID)
            updateRun(runID) {
                $0.finalOutput = output
                $0.durationMilliseconds = duration
                $0.tokenUsage = usage ?? $0.tokenUsage
                $0.completedAt = .now
                $0.status = .routing
            }
            if let usage {
                await appendTokenUsage(usage, runID: runID)
            }
            if run.liveTeamMember != nil {
                activatePendingLiveTeamGoalAmendment()
                if isClosing {
                    record.activity?.liveTeam?.resumeCheckpoint = .routeCompletedRun(runID)
                    pauseLiveTeamActivity(message: "Paused before work routing")
                    await completeCloseAfterTerminalEvent()
                } else {
                    await beginLiveTeamRouting(runID: runID, finalOutput: output)
                }
            } else {
                activatePendingGoalAmendment()
                if isClosing {
                    record.activity?.workflowResumeCheckpoint = .routeCompletedRun(runID)
                    pauseGenericActivity(message: "Paused before preparing the handoff")
                    await completeCloseAfterTerminalEvent()
                } else {
                    await beginGenericRouting(runID: runID, finalOutput: output)
                }
            }

        case .interrupted(let detail):
            if await finishInteractionSafetyStopIfNeeded(runID: runID) { return }
            guard !transcriptBackpressureRunIDs.contains(runID) else {
                await finishBackpressuredRunAfterTerminalEvent(runID: runID)
                return
            }
            genericSessionFallbacks.removeValue(forKey: runID)
            liveTeamSessionFallbacks.removeValue(forKey: runID)
            updateRun(runID) {
                $0.status = .interrupted
                $0.completedAt = .now
                if let detail, !detail.isEmpty {
                    $0.relayError = detail
                }
            }
            if run.liveTeamMember != nil {
                activatePendingLiveTeamGoalAmendment()
                record.activity?.liveTeam?.resumeCheckpoint = .recoverRun(runID)
                pauseLiveTeamActivity(message: detail ?? "\(run.displayName) was interrupted.")
            } else {
                activatePendingGoalAmendment()
                record.activity?.workflowResumeCheckpoint = .recoverRun(runID)
                pauseGenericActivity(message: detail ?? "\(run.displayName) was interrupted.")
            }
            if isClosing {
                await completeCloseAfterTerminalEvent()
            } else {
                try? await persist()
            }

        case .sessionUnavailable(let detail):
            if await finishInteractionSafetyStopIfNeeded(runID: runID) { return }
            guard !transcriptBackpressureRunIDs.contains(runID) else {
                await finishBackpressuredRunAfterTerminalEvent(runID: runID)
                return
            }
            if run.liveTeamMember != nil {
                await failLiveTeamRunFromEvent(
                    runID: runID,
                    detail: detail,
                    allowsSessionFallback: true
                )
            } else {
                await failGenericRunFromEvent(
                    runID: runID,
                    detail: detail,
                    allowsSessionFallback: true
                )
            }

        case .failed(let detail):
            if await finishInteractionSafetyStopIfNeeded(runID: runID) { return }
            guard !transcriptBackpressureRunIDs.contains(runID) else {
                await finishBackpressuredRunAfterTerminalEvent(runID: runID)
                return
            }
            if run.liveTeamMember != nil {
                await failLiveTeamRunFromEvent(
                    runID: runID,
                    detail: detail,
                    allowsSessionFallback: false
                )
            } else {
                await failGenericRunFromEvent(
                    runID: runID,
                    detail: detail,
                    allowsSessionFallback: false
                )
            }
        }
    }

    private func failLiveTeamRunFromEvent(
        runID: UUID,
        detail: String,
        allowsSessionFallback: Bool
    ) async {
        guard let run = run(withID: runID),
              let snapshot = run.liveTeamMember else { return }
        let sessionFallback = allowsSessionFallback && run.turnID == nil
            ? liveTeamSessionFallbacks.removeValue(forKey: runID)
            : nil
        if sessionFallback == nil {
            liveTeamSessionFallbacks.removeValue(forKey: runID)
        }
        updateRun(runID) {
            $0.status = .failed
            $0.completedAt = .now
            $0.relayError = detail
        }
        activatePendingLiveTeamGoalAmendment()
        record.activity?.liveTeam?.resumeCheckpoint = .recoverRun(runID)
        pauseLiveTeamActivity(message: detail)
        await noteLiveTeamFailureAndReviewIfRepeated(runID: runID)
        if isClosing {
            await completeCloseAfterTerminalEvent()
        } else {
            try? await persist()
        }
        if let sessionFallback, !isClosing {
            let previousActivity = record.activity
            var sessionState = record.activity?.stepSessions[snapshot.sessionSlotID]
                ?? WorkflowSessionState(
                    stepID: snapshot.sessionSlotID,
                    target: snapshot.member.target
                )
            if let sessionID = sessionState.providerSessionID {
                await releaseProviderSessions([ProviderSessionReference(
                    providerID: sessionState.target.providerID,
                    sessionID: sessionID
                )])
            }
            sessionState = advanceLiveTeamSessionLineage(
                sessionState,
                snapshot: snapshot,
                runID: runID,
                updatesRun: false
            )
            record.activity?.stepSessions[snapshot.sessionSlotID] = sessionState
            record.activity?.status = .running
            record.activity?.liveTeam?.resumeCheckpoint = .perform(
                sessionFallback.checkpoint
            )
            do {
                try await persist()
                await performLiveTeam(
                    checkpoint: sessionFallback.checkpoint,
                    promptOverride: sessionFallback.prompt,
                    snapshotOverride: snapshot,
                    allowsSessionFallback: false
                )
            } catch {
                record.activity = previousActivity
                errorMessage = "Could not save the fresh-session fallback: \(error.localizedDescription)"
            }
        }
    }

    private func failGenericRunFromEvent(
        runID: UUID,
        detail: String,
        allowsSessionFallback: Bool
    ) async {
        guard let run = run(withID: runID) else { return }
        let sessionFallback = allowsSessionFallback && run.turnID == nil
            ? genericSessionFallbacks.removeValue(forKey: runID)
            : nil
        if sessionFallback == nil {
            genericSessionFallbacks.removeValue(forKey: runID)
        }
        updateRun(runID) {
            $0.status = .failed
            $0.completedAt = .now
            $0.relayError = detail
        }
        activatePendingGoalAmendment()
        record.activity?.workflowResumeCheckpoint = .recoverRun(runID)
        pauseGenericActivity(message: detail)
        if isClosing {
            await completeCloseAfterTerminalEvent()
        } else {
            try? await persist()
        }
        if let sessionFallback, !isClosing {
            await startFreshGenericSessionFallback(
                after: runID,
                fallback: sessionFallback
            )
        }
    }

    private func startFreshGenericSessionFallback(
        after failedRunID: UUID,
        fallback: GenericSessionFallback
    ) async {
        let launchLeaseID = beginProviderLaunchLease(runID: failedRunID)
        defer { finishProviderLaunchLease(launchLeaseID) }
        guard !isClosing,
              var activity = record.activity,
              activity.status == .paused,
              activity.workflowResumeCheckpoint == .recoverRun(failedRunID),
              activity.workflowCursor == fallback.cursor,
              let workflow = activity.workflow,
              let step = GenericWorkflowStateMachine.step(at: fallback.cursor, in: workflow),
              let failedRun = activity.runs.first(where: { $0.id == failedRunID }),
              failedRun.workflowStep?.id == step.id else {
            return
        }

        let previousActivity = activity
        var sessionState = activity.stepSessions[step.id]
            ?? WorkflowSessionState(stepID: step.id, target: step.target)
        if let supersededSessionID = sessionState.providerSessionID {
            await releaseProviderSessions([ProviderSessionReference(
                providerID: sessionState.target.providerID,
                sessionID: supersededSessionID
            )])
            guard !isClosing else { return }
        }
        sessionState = advanceGenericSessionLineage(
            sessionState,
            step: step,
            runID: failedRunID,
            updatesRun: false
        )
        activity = record.activity ?? activity
        activity.stepSessions[step.id] = sessionState
        activity.workflowResumeCheckpoint = .perform(fallback.cursor)
        record.activity = activity
        errorMessage = nil
        statusMessage = "Recreating the unavailable agent session…"

        do {
            try await persist()
        } catch {
            record.activity = previousActivity
            errorMessage = "Could not save the automatic session fallback: \(error.localizedDescription)"
            statusMessage = pausedStatusMessage
            return
        }

        guard !isClosing else { return }
        await performGeneric(
            cursor: fallback.cursor,
            previousHandoff: nil,
            promptOverride: fallback.prompt
        )
    }

    private func beginGenericRouting(runID: UUID, finalOutput: String) async {
        guard !completingRunIDs.contains(runID), run(withID: runID) != nil else { return }
        completingRunIDs.insert(runID)
        activatePendingGoalAmendment()
        updateRun(runID) {
            $0.status = .routing
            $0.relayError = nil
            $0.workflowHandoff = nil
        }
        record.activity?.workflowResumeCheckpoint = .routeCompletedRun(runID)
        statusMessage = "Preparing handoff…"
        do {
            try await persist()
        } catch {
            completingRunIDs.remove(runID)
            updateRun(runID) {
                $0.status = .paused
                $0.relayError = "The completed step could not be saved before preparing its handoff."
            }
            record.activity?.status = .paused
            errorMessage = "Codeness did not start the handoff because the completed step could not be saved: \(error.localizedDescription)"
            try? await persist()
            return
        }
        routingTasks[runID] = Task { [weak self] in
            await self?.routeGenericRun(runID: runID, finalOutput: finalOutput)
        }
    }

    private func routeGenericRun(runID: UUID, finalOutput: String) async {
        defer {
            completingRunIDs.remove(runID)
            routingTasks.removeValue(forKey: runID)
        }
        guard let workflowRouter,
              let activity = record.activity,
              let workflow = activity.workflow,
              let run = run(withID: runID),
              let sourceStep = run.workflowStep,
              let cursor = activity.workflowCursor else { return }
        let continuingTransition = GenericWorkflowStateMachine.transition(
            after: cursor,
            outcome: .continueWorkflow,
            in: workflow
        )
        let nextStepName: String? = switch continuingTransition {
        case .run(let nextCursor):
            GenericWorkflowStateMachine.step(at: nextCursor, in: workflow)?.name
        case .complete, .pause:
            nil
        }
        let context = WorkflowHandoffContext(
            goal: activity.goal,
            workflowName: workflow.name,
            sourceStep: sourceStep,
            nextStepName: nextStepName,
            makesLoopDecision: GenericWorkflowStateMachine.isLoopDecision(cursor, in: workflow),
            previousHandoff: activity.runs.last(where: {
                $0.id != runID && $0.workflowHandoff != nil
            })?.workflowHandoff,
            source: finalOutput
        )
        do {
            let handoff = try await workflowRouter.route(
                context,
                configuration: workflow.coordinator,
                cwd: record.canonicalPath
            )
            guard !isClosing else { return }
            activatePendingGoalAmendment()
            var normalized = handoff
            normalized.runLabel = normalizedRunLabel(
                handoff.runLabel,
                fallback: sourceStep.name
            )
            updateRun(runID) {
                $0.workflowHandoff = normalized
                $0.status = .completed
                $0.relayError = nil
            }
            record.activity?.workflowResumeCheckpoint = nil
            await applyGenericWorkflowDecision(runID: runID, handoff: normalized)
        } catch {
            guard !isClosing else { return }
            activatePendingGoalAmendment()
            updateRun(runID) {
                $0.status = .paused
                $0.relayError = error.localizedDescription
            }
            record.activity?.workflowResumeCheckpoint = .routeCompletedRun(runID)
            pauseGenericActivity(message: "Handoff paused: \(error.localizedDescription)")
            try? await persist()
        }
    }

    private func applyGenericWorkflowDecision(
        runID: UUID,
        handoff: WorkflowHandoff
    ) async {
        activatePendingGoalAmendment()
        guard let activity = record.activity,
              let workflow = activity.workflow,
              let cursor = activity.workflowCursor else { return }
        switch GenericWorkflowStateMachine.transition(
            after: cursor,
            outcome: handoff.outcome,
            in: workflow
        ) {
        case .pause(let reason):
            // Publish the paused checkpoint only after the terminal routing task is
            // no longer considered active, so retry/restart cannot lose a click to
            // a transient state where the UI looks paused but remains ineligible.
            completingRunIDs.remove(runID)
            routingTasks.removeValue(forKey: runID)
            updateRun(runID) {
                $0.status = .paused
                $0.relayError = reason
            }
            record.activity?.workflowResumeCheckpoint = .routeCompletedRun(runID)
            pauseGenericActivity(message: reason)
            try? await persist()

        case .run(let nextCursor):
            record.activity?.workflowCursor = nextCursor
            if pauseAfterCurrent || isClosing || record.activity?.status == .paused {
                record.activity?.status = .paused
                record.activity?.workflowResumeCheckpoint = .perform(nextCursor)
                statusMessage = "Paused before \(genericStepName(at: nextCursor).lowercased())"
                try? await persist()
            } else {
                await performGeneric(cursor: nextCursor, previousHandoff: handoff)
            }

        case .complete:
            completeGenericActivity()
            await persistCompletedActivityAndDetachSessions()
        }
    }

    private func completeGenericActivity() {
        activatePendingGoalAmendment()
        record.activity?.status = .completed
        record.activity?.completedAt = .now
        record.activity?.workflowCursor = nil
        record.activity?.workflowResumeCheckpoint = nil
        statusMessage = "Activity complete"
        pauseAfterCurrent = false
        viewState.pauseAfterCurrent = false
        scheduleViewStateSave()
    }

    private func persistCompletedActivityAndDetachSessions() async {
        do {
            try await persist()
        } catch {
            errorMessage = "The activity completed, but its final state could not be saved: \(error.localizedDescription)"
        }
        let unreleasedSessions = await unreleasedProviderSessions(
            afterReleasing: attachedProviderSessions
        )
        sessionsPrepared = false
        if !unreleasedSessions.isEmpty {
            errorMessage = "The activity completed, but Codeness could not confirm provider-session detachment for \(providerSessionDescription(unreleasedSessions))."
        }
    }

    private func recoverGenericRun(_ interruptedRun: RunRecord) async {
        guard let cursor = record.activity?.workflowCursor else {
            pauseGenericActivity(message: "The interrupted step has no workflow cursor.")
            return
        }
        let recoveryPrompt = """
        The preceding Codeness step was interrupted and may have partially changed the repository. \
        Inspect the current state, recover the intended step without blindly replaying completed \
        edits, and finish at the same kind of checkpoint.

        PREVIOUS STEP INSTRUCTION

        \(interruptedRun.prompt)
        """
        record.activity?.workflowResumeCheckpoint = .recoverRun(interruptedRun.id)
        await performGeneric(
            cursor: cursor,
            previousHandoff: record.activity?.runs.dropLast().last(where: {
                $0.workflowHandoff != nil
            })?.workflowHandoff,
            promptOverride: recoveryPrompt
        )
    }

    private func presentGenericInteraction(
        _ interaction: AgentInteraction,
        runID: UUID,
        providerID: AgentProviderID?
    ) async {
        guard let providerID else { return }
        guard !interactionSafetyTerminatingRunIDs.contains(runID) else { return }
        let presentationKey = "agent:\(providerID.rawValue):\(runID.uuidString):\(interaction.id)"
        let presentationID = JSONValue.string(presentationKey)
        guard claimedInteractionID != presentationID,
              !pendingInteractions.contains(where: { $0.id == presentationID }) else {
            await stopRunForInteractionSafety(
                runID: runID,
                detail: "The agent reused an unresolved interaction identifier. Codeness stopped the run instead of allowing a hidden request to replace the visible request."
            )
            return
        }
        let pending = PendingServerInteraction(
            id: presentationID,
            method: "agent/\(providerID.rawValue)/\(interaction.kind.rawValue)",
            title: interaction.title,
            detail: interaction.detail,
            questions: interaction.questions,
            approvalDecisions: interaction.decisions.map {
                ApprovalDecision(
                    value: $0.payload,
                    label: $0.label,
                    explanation: $0.explanation,
                    isDestructive: $0.isDestructive
                )
            },
            rawParameters: interaction.rawParameters
        )
        guard appendPendingInteraction(pending) else {
            await stopRunForInteractionSafety(
                runID: runID,
                detail: "The agent accumulated too many unresolved interactions. Codeness stopped the run to prevent unbounded memory growth."
            )
            return
        }
        genericInteractionRoutes[presentationKey] = GenericInteractionRoute(
            providerID: providerID,
            runID: runID,
            interactionID: interaction.id
        )
        updateRun(runID) { $0.status = .awaitingApproval }
        if pendingInteractions.count == 1 {
            statusMessage = interaction.title
        }
    }

    private func genericRoute(for presentationID: JSONValue) -> GenericInteractionRoute? {
        guard let key = presentationID.stringValue else { return nil }
        return genericInteractionRoutes[key]
    }

    private func claimPendingInteractionForResolution(
        expectedID: JSONValue? = nil
    ) -> (
        interaction: PendingServerInteraction,
        route: GenericInteractionRoute?,
        runID: UUID?,
        claimID: UUID
    )? {
        guard !interactionResolutionInFlight,
              let interaction = pendingInteraction,
              expectedID == nil || expectedID == interaction.id else { return nil }
        interactionResolutionInFlight = true
        let claimID = UUID()
        interactionResolutionClaimID = claimID
        claimedInteractionID = interaction.id
        claimedInteractionRetainedByteCount = Self.retainedCost(of: interaction)
        let route = genericRoute(for: interaction.id)
        let runID = route?.runID ?? activeRun?.id
        removePendingInteraction(id: interaction.id)
        if let key = interaction.id.stringValue {
            genericInteractionRoutes.removeValue(forKey: key)
        }
        return (interaction, route, runID, claimID)
    }

    private func failClaimedInteraction(
        claimID: UUID,
        runID: UUID?,
        detail: String
    ) async {
        guard interactionResolutionClaimID == claimID else { return }
        guard let runID else {
            errorMessage = detail
            clearPendingInteractions()
            return
        }
        await stopRunForInteractionSafety(runID: runID, detail: detail)
    }

    private func completeInteractionResolutionClaim(claimID: UUID) async {
        guard interactionResolutionClaimID == claimID else { return }
        interactionResolutionInFlight = false
        interactionResolutionClaimID = nil
        claimedInteractionID = nil
        claimedInteractionRetainedByteCount = 0
        await refreshInteractionPresentationState()
    }

    private func resolveGenericInteraction(
        _ route: GenericInteractionRoute,
        claimID: UUID,
        resolution: AgentInteractionResolution
    ) async {
        guard let agentProviders else {
            await completeInteractionResolutionClaim(claimID: claimID)
            return
        }
        do {
            try await agentProviders.resolveInteraction(
                providerID: route.providerID,
                runID: route.runID,
                interactionID: route.interactionID,
                resolution: resolution
            )
        } catch {
            await failClaimedInteraction(
                claimID: claimID,
                runID: route.runID,
                detail: "Could not send the agent interaction response: \(error.localizedDescription)"
            )
        }
        await completeInteractionResolutionClaim(claimID: claimID)
    }

    private func finishGenericInteraction(presentationKey: String) async {
        genericInteractionRoutes.removeValue(forKey: presentationKey)
        await finishInteraction(id: .string(presentationKey))
    }

    private func prepareLiveTeamForClose(
        strategy: DocumentPauseStrategy
    ) async -> DocumentClosePreparationResult {
        guard record.activity?.status == .running else {
            return await finishCloseWithoutActiveTurn()
        }
        guard let run = activeRun else {
            record.activity?.status = .paused
            if let checkpoint = record.activity?.liveTeam?.checkpoint {
                record.activity?.liveTeam?.resumeCheckpoint = .perform(checkpoint)
            }
            return await finishCloseWithoutActiveTurn()
        }
        switch run.status {
        case .routing:
            record.activity?.status = .paused
            record.activity?.liveTeam?.resumeCheckpoint = .routeCompletedRun(run.id)
            statusMessage = "Paused before work routing"
            return await finishCloseWithoutActiveTurn()
        case .queued where genericRunTasks[run.id] == nil:
            record.activity?.status = .paused
            record.activity?.liveTeam?.resumeCheckpoint = .recoverRun(run.id)
            return await finishCloseWithoutActiveTurn()
        case .queued, .running, .awaitingApproval:
            guard let target = run.agentTarget, let agentProviders else {
                return failClose("The active agent provider is unavailable.")
            }
            do {
                if strategy == .graceful, run.status == .running {
                    pauseState = .requestingCheckpoint
                    statusMessage = "Asking \(run.displayName.lowercased()) to stop coherently…"
                    try await agentProviders.steer(
                        providerID: target.providerID,
                        runID: run.id,
                        message: Self.gracefulPausePrompt
                    )
                    pauseState = .waitingForTurn
                } else {
                    pauseState = .interrupting
                    statusMessage = "Stopping \(run.displayName.lowercased())…"
                    try await agentProviders.interrupt(
                        providerID: target.providerID,
                        runID: run.id
                    )
                }
                return await waitForCloseCompletion()
            } catch {
                return await reconcileCloseControlFailure(error.localizedDescription)
            }
        case .paused, .interrupted, .failed:
            record.activity?.status = .paused
            record.activity?.liveTeam?.resumeCheckpoint = .recoverRun(run.id)
            return await finishCloseWithoutActiveTurn()
        case .completed:
            record.activity?.status = .paused
            if run.coordinatorDecision != nil {
                record.activity?.liveTeam?.resumeCheckpoint = .applyCoordinatorDecision(run.id)
            } else if run.finalOutput?.isEmpty == false {
                record.activity?.liveTeam?.resumeCheckpoint = .routeCompletedRun(run.id)
            } else {
                record.activity?.liveTeam?.resumeCheckpoint = .recoverRun(run.id)
            }
            return await finishCloseWithoutActiveTurn()
        }
    }

    private func prepareGenericWorkflowForClose(
        strategy: DocumentPauseStrategy
    ) async -> DocumentClosePreparationResult {
        guard record.activity?.status == .running else {
            return await finishCloseWithoutActiveTurn()
        }
        guard let run = activeRun else {
            record.activity?.status = .paused
            if let cursor = record.activity?.workflowCursor {
                record.activity?.workflowResumeCheckpoint = .perform(cursor)
            }
            return await finishCloseWithoutActiveTurn()
        }
        switch run.status {
        case .routing:
            record.activity?.status = .paused
            record.activity?.workflowResumeCheckpoint = .routeCompletedRun(run.id)
            statusMessage = "Paused before preparing the handoff"
            return await finishCloseWithoutActiveTurn()
        case .queued where genericRunTasks[run.id] == nil:
            record.activity?.status = .paused
            record.activity?.workflowResumeCheckpoint = .recoverRun(run.id)
            return await finishCloseWithoutActiveTurn()
        case .queued, .running, .awaitingApproval:
            guard let target = run.agentTarget, let agentProviders else {
                return failClose("The active agent provider is unavailable.")
            }
            do {
                if strategy == .graceful, run.status == .running {
                    pauseState = .requestingCheckpoint
                    statusMessage = "Asking \(run.displayName.lowercased()) to stop coherently…"
                    try await agentProviders.steer(
                        providerID: target.providerID,
                        runID: run.id,
                        message: Self.gracefulPausePrompt
                    )
                    pauseState = .waitingForTurn
                } else {
                    pauseState = .interrupting
                    statusMessage = "Stopping \(run.displayName.lowercased())…"
                    try await agentProviders.interrupt(
                        providerID: target.providerID,
                        runID: run.id
                    )
                }
                return await waitForCloseCompletion()
            } catch {
                return await reconcileCloseControlFailure(error.localizedDescription)
            }
        case .paused, .interrupted, .failed, .completed:
            record.activity?.status = .paused
            if run.status == .completed, run.workflowHandoff != nil,
               let cursor = record.activity?.workflowCursor,
               let workflow = record.activity?.workflow {
                switch GenericWorkflowStateMachine.transition(
                    after: cursor,
                    outcome: run.workflowHandoff?.outcome ?? .unclear,
                    in: workflow
                ) {
                case .run(let next):
                    record.activity?.workflowCursor = next
                    record.activity?.workflowResumeCheckpoint = .perform(next)
                case .complete:
                    completeGenericActivity()
                case .pause:
                    record.activity?.workflowResumeCheckpoint = .routeCompletedRun(run.id)
                }
            } else {
                record.activity?.workflowResumeCheckpoint = .recoverRun(run.id)
            }
            return await finishCloseWithoutActiveTurn()
        }
    }

    private func prepareSafetyStoppedRunsForClose() async -> DocumentClosePreparationResult {
        pauseState = .interrupting
        statusMessage = "Confirming that the safety-stopped agent turn has ended…"
        let runIDs = interactionSafetyTerminatingRunIDs
            .union(transcriptBackpressureRunIDs)
            .sorted { $0.uuidString < $1.uuidString }

        for runID in runIDs {
            guard interactionSafetyTerminatingRunIDs.contains(runID)
                    || transcriptBackpressureRunIDs.contains(runID) else {
                continue
            }
            guard let run = run(withID: runID) else {
                return failClose(
                    "Codeness could not identify a safety-stopped run whose termination is still unconfirmed. The document remains open."
                )
            }
            do {
                if let target = run.agentTarget {
                    guard let agentProviders else {
                        return failClose(
                            "The active agent provider is unavailable, so Codeness could not confirm that the safety-stopped run ended."
                        )
                    }
                    try await agentProviders.interrupt(
                        providerID: target.providerID,
                        runID: runID
                    )
                } else {
                    guard let threadID = run.threadID,
                          let turnID = run.turnID else {
                        return failClose(
                            "The safety-stopped Codex run has no interruptible turn identifier. The document remains open until termination can be confirmed."
                        )
                    }
                    try await interruptLegacyTurn(
                        runID: runID,
                        threadID: threadID,
                        turnID: turnID
                    )
                }
            } catch {
                return await reconcileCloseControlFailure(error.localizedDescription)
            }
        }

        if pauseState == .paused { return .ready }
        if !isClosing {
            return .failed(errorMessage ?? "Codeness could not confirm that the safety-stopped run ended.")
        }
        return await waitForCloseCompletion()
    }

    private func pauseGenericActivity(message: String) {
        record.activity?.status = .paused
        statusMessage = message
    }

    private func genericStepName(at cursor: WorkflowCursor) -> String {
        guard let workflow = record.activity?.workflow else { return "step" }
        return GenericWorkflowStateMachine.step(at: cursor, in: workflow)?.name ?? "step"
    }

    private func recoverInterruptedGenericState() {
        guard record.activity?.status == .running else { return }
        record.activity?.status = .paused
        markLastGenericRunInterruptedIfNeeded()
    }

    private func markLastGenericRunInterruptedIfNeeded() {
        guard let index = record.activity?.runs.indices.last else {
            if let cursor = record.activity?.workflowCursor {
                record.activity?.workflowResumeCheckpoint = .perform(cursor)
            }
            return
        }
        let run = record.activity?.runs[index]
        if let status = run?.status,
           [.queued, .running, .awaitingApproval].contains(status),
           let runID = run?.id {
            record.activity?.runs[index].status = .interrupted
            record.activity?.runs[index].completedAt = .now
            record.activity?.workflowResumeCheckpoint = .recoverRun(runID)
        } else if run?.status == .routing,
                  let runID = run?.id,
                  run?.finalOutput?.isEmpty == false {
            record.activity?.workflowResumeCheckpoint = .routeCompletedRun(runID)
        } else if let runID = run?.id, run?.status == .routing {
            record.activity?.runs[index].status = .interrupted
            record.activity?.workflowResumeCheckpoint = .recoverRun(runID)
        }
    }

    private static func compatibilityRoleAndKind(
        for step: WorkflowStep
    ) -> (role: AgentRole, kind: RunKind) {
        let name = step.name.lowercased()
        if step.target.options.mode == .plan || name.contains("review") || name.contains("plan") {
            return (.reviewer, .review)
        }
        if name.contains("fix") {
            return (.implementer, .fix)
        }
        return (.implementer, .implementation)
    }

    private static func sameFrozenWorkflowTopology(
        _ lhs: WorkflowTemplate,
        _ rhs: WorkflowTemplate
    ) -> Bool {
        guard lhs.id == rhs.id,
              lhs.name == rhs.name,
              lhs.summary == rhs.summary,
              lhs.steps.count == rhs.steps.count else { return false }
        return zip(lhs.steps, rhs.steps).allSatisfy { old, new in
            old.id == new.id
                && old.name == new.name
                && old.section == new.section
        }
    }

    private static func requiresNewLineage(
        from old: AgentTarget,
        to new: AgentTarget
    ) -> Bool {
        old.providerID != new.providerID
            || old.model != new.model
            || old.options.mode != new.options.mode
    }

    private func restartableWorkflowContext(
        for runID: UUID
    ) -> (
        activity: ActivityRecord,
        workflow: WorkflowTemplate,
        cursor: WorkflowCursor,
        step: WorkflowStep,
        runIndex: Int
    )? {
        guard isLoaded,
              !isClosing,
              !pauseState.isInProgress,
              pendingInteractions.isEmpty,
              routingTasks.isEmpty,
              completingRunIDs.isEmpty,
              let activity = record.activity,
              activity.status == .paused,
              let workflow = activity.workflow,
              let cursor = activity.workflowCursor,
              let runIndex = activity.runs.firstIndex(where: { $0.id == runID }),
              let snapshot = activity.runs[runIndex].workflowStep,
              let step = GenericWorkflowStateMachine.step(at: cursor, in: workflow),
              step.id == snapshot.id else {
            return nil
        }

        let run = activity.runs[runIndex]
        switch activity.workflowResumeCheckpoint {
        case .recoverRun(let checkpointRunID) where checkpointRunID == runID:
            guard [.failed, .interrupted].contains(run.status) else { return nil }

        case .routeCompletedRun(let checkpointRunID) where checkpointRunID == runID:
            guard run.status == .paused,
                  let outcome = run.workflowHandoff?.outcome,
                  [.blocked, .failed, .unclear].contains(outcome) else {
                return nil
            }

        case .perform, .recoverRun, .routeCompletedRun, nil:
            return nil
        }

        return (activity, workflow, cursor, step, runIndex)
    }

    private func reusableProviderSessionID(
        _ session: WorkflowSessionState,
        stepID: String
    ) -> String? {
        guard let providerSessionID = session.providerSessionID else { return nil }
        // Claude reserves an ID locally before its process creates the session.
        // Reuse only after a started execution was durably observed; otherwise a
        // crash between reservation and launch would retry `--resume` against a
        // conversation that never existed. Creating a fresh lineage session here
        // is safe for Codex too and leaves the lineage number unchanged.
        let wasEstablished = record.activity?.runs.contains { run in
            run.workflowStep?.id == stepID
                && run.threadID == providerSessionID
                && run.turnID != nil
        } == true
        return wasEstablished ? providerSessionID : nil
    }

    private func ensureSessions(allowRecreate: Bool) async throws {
        guard !sessionsPrepared else { return }
        let leaseID = beginProviderLaunchLease(runID: UUID())
        defer { finishProviderLaunchLease(leaseID) }
        guard !isClosing else {
            throw RepositoryCoordinatorError.providerLaunchCancelledForClose
        }
        let previousImplementerThreadID = record.implementerThreadID
        let implementerThreadID = try await prepareThread(
            existingID: previousImplementerThreadID,
            role: .implementer,
            selection: record.settings.implementer,
            instructions: PromptBuilder.implementerInstructions,
            allowRecreate: allowRecreate
        )
        record.implementerThreadID = implementerThreadID
        try await persist()
        if let previousImplementerThreadID,
           previousImplementerThreadID != implementerThreadID {
            await releaseProviderSessions([ProviderSessionReference(
                providerID: .codex,
                sessionID: previousImplementerThreadID
            )])
        }
        guard !isClosing else {
            throw RepositoryCoordinatorError.providerLaunchCancelledForClose
        }

        let previousReviewerThreadID = record.reviewerThreadID
        let reviewerThreadID = try await prepareThread(
            existingID: previousReviewerThreadID,
            role: .reviewer,
            selection: record.settings.reviewer,
            instructions: PromptBuilder.reviewerInstructions,
            allowRecreate: allowRecreate
        )
        record.reviewerThreadID = reviewerThreadID
        record.requiresFreshProviderSessions = false
        try await persist()
        if let previousReviewerThreadID,
           previousReviewerThreadID != reviewerThreadID {
            await releaseProviderSessions([ProviderSessionReference(
                providerID: .codex,
                sessionID: previousReviewerThreadID
            )])
        }
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
                let reference = ProviderSessionReference(
                    providerID: .codex,
                    sessionID: existingID
                )
                markProviderSessionAttached(reference)
                guard !isClosing else {
                    await releaseProviderSessions([reference])
                    throw RepositoryCoordinatorError.providerLaunchCancelledForClose
                }
                return existingID
            } catch where allowRecreate {
                guard !isClosing else {
                    throw RepositoryCoordinatorError.providerLaunchCancelledForClose
                }
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
        let reference = ProviderSessionReference(providerID: .codex, sessionID: identifier)
        markProviderSessionAttached(reference)
        guard !isClosing else {
            await releaseProviderSessions([reference])
            throw RepositoryCoordinatorError.providerLaunchCancelledForClose
        }
        do {
            try await appServer.setThreadName(
                id: identifier,
                name: "\(repositoryName) — \(role.displayName)"
            )
        } catch {
            await releaseProviderSessions([reference])
            throw error
        }
        guard !isClosing else {
            await releaseProviderSessions([reference])
            throw RepositoryCoordinatorError.providerLaunchCancelledForClose
        }
        return identifier
    }

    private func recoverInterruptedPass(_ interruptedRun: RunRecord) async {
        record.activity?.resumeCheckpoint = .recoverRun(interruptedRun.id)
        do {
            try await ensureSessions(
                allowRecreate: record.requiresFreshProviderSessions
            )
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
            guard !isClosing else {
                record.activity?.status = .paused
                return
            }
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

    func recoverAppendOnlyTranscript(
        runID: UUID?,
        loadGeneration: UUID? = nil
    ) async {
        guard loadGeneration.map(isCurrentLoad) ?? true else { return }
        guard let runID,
              let activity = record.activity,
              activity.runs.contains(where: { $0.id == runID }) else { return }

        // A scheduled UI append may contain the same bytes that are about to be
        // reconstructed from disk. Cancel it and rebuild from the durable log plus
        // identity-tracked pending chunks instead of guessing from string content.
        visibleTranscriptTasks.removeValue(forKey: runID)?.cancel()
        visibleTranscriptChunks.removeValue(forKey: runID)
        visibleTranscriptUTF8ByteCounts.removeValue(forKey: runID)
        let wasAlreadyHydrated = hydratedTranscriptRunIDs.contains(runID)
        hydratedTranscriptRunIDs.remove(runID)
        let hydrationID = UUID()
        transcriptHydrationIDs[runID] = hydrationID
        transcriptHydrationChunks[runID] = []
        defer { finishTranscriptHydration(runID: runID, hydrationID: hydrationID) }

        do {
            try await flushPendingTranscript(runID: runID)
            guard loadGeneration.map(isCurrentLoad) ?? true else { return }
            guard transcriptHydrationIDs[runID] == hydrationID else { return }
            // Every chunk captured before this point is now in the durable prefix
            // that the following tail read observes. New chunks are held aside
            // until that read publishes, preventing disk-tail/UI-batch overlap.
            transcriptHydrationChunks[runID] = []
        } catch {
            // Keep both the pre-existing pending buffer and hydration captures.
            // Their sequence identities are merged below without guessing from
            // repeated text content.
        }
        guard transcriptHydrationIDs[runID] == hydrationID else { return }
        let currentTranscript = self.run(withID: runID)?.transcript ?? ""
        let metadata = wasAlreadyHydrated ? "" : currentTranscript
        var completeTranscript: String
        do {
            if metadata.isEmpty {
                // WorkspaceStore externalizes live transcripts into per-run files.
                // Read only the suffix that can survive the presentation bound;
                // selecting a very large run must not allocate its entire log.
                let recovered = try await store.recoveredTranscriptTail(
                    repositoryPath: record.canonicalPath,
                    activityID: activity.id,
                    runID: runID,
                    maximumUTF8Bytes: Self.maximumPresentedTranscriptUTF8Bytes
                )
                guard loadGeneration.map(isCurrentLoad) ?? true else { return }
                completeTranscript = recovered.wasTruncated
                    ? Self.truncatedTranscriptMarker + recovered.text
                    : recovered.text
            } else {
                // A non-externalizing store or legacy fixture can still supply
                // transcript metadata. Full reconciliation is required once to
                // avoid choosing a divergent append-log suffix as canonical.
                let recovered = try await store.recoveredTranscript(
                    repositoryPath: record.canonicalPath,
                    activityID: activity.id,
                    runID: runID
                )
                guard loadGeneration.map(isCurrentLoad) ?? true else { return }
                completeTranscript = RunTranscriptPresentation.reconciledTranscript(
                    metadata: metadata,
                    appendLog: recovered
                )
            }
        } catch {
            return
        }
        guard loadGeneration.map(isCurrentLoad) ?? true else { return }
        guard transcriptHydrationIDs[runID] == hydrationID else { return }
        let pendingTranscript = transcriptSuffixCapturedDuringHydration(runID: runID)
        if !pendingTranscript.isEmpty {
            // Pending chunks have not been acknowledged by WorkspaceStore. They
            // are a distinct ordered suffix even when their text is byte-for-byte
            // identical to the existing log tail.
            completeTranscript += pendingTranscript
        }
        guard !Task.isCancelled, selectedRunID == runID else { return }
        hydratedTranscriptRunIDs.insert(runID)
        setRunTranscript(
            Self.boundedTranscriptForPresentation(completeTranscript),
            runID: runID
        )
    }

    private func transcriptSuffixCapturedDuringHydration(runID: UUID) -> String {
        var chunksBySequence: [UInt64: TranscriptChunk] = [:]
        if let pending = pendingTranscriptBuffers[runID] {
            for chunk in pending.chunks {
                chunksBySequence[chunk.sequence] = chunk
            }
        }
        for chunk in transcriptHydrationChunks[runID] ?? [] {
            chunksBySequence[chunk.sequence] = chunk
        }
        return chunksBySequence.values
            .sorted { $0.sequence < $1.sequence }
            .map(\.text)
            .joined()
    }

    private func finishTranscriptHydration(runID: UUID, hydrationID: UUID) {
        guard transcriptHydrationIDs[runID] == hydrationID else { return }
        transcriptHydrationIDs.removeValue(forKey: runID)
        transcriptHydrationChunks.removeValue(forKey: runID)
        if let buffer = pendingTranscriptBuffers[runID], !buffer.chunks.isEmpty {
            scheduleTranscriptFlush(
                runID: runID,
                immediately: buffer.utf8Count >= Self.transcriptFlushByteThreshold
                    || buffer.chunks.count >= Self.transcriptFlushChunkThreshold
            )
        }
        let waiters = transcriptHydrationWaiters.removeValue(forKey: runID) ?? []
        waiters.forEach { $0.resume() }
    }

    private func waitForTranscriptHydration(runID: UUID) async {
        guard transcriptHydrationIDs[runID] != nil else { return }
        await withCheckedContinuation { continuation in
            if transcriptHydrationIDs[runID] == nil {
                continuation.resume()
            } else {
                transcriptHydrationWaiters[runID, default: []].append(continuation)
            }
        }
    }

    private func scheduleSelectedTranscriptLoad(previousRunID: UUID?) {
        guard isLoaded, !isClosing, !isStartingOver else { return }
        transcriptLoadTask?.cancel()
        let requestedRunID = selectedRunID
        transcriptLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var canEvictPreviousTranscripts = true
            if let previousRunID, self.pendingTranscriptBuffers[previousRunID] != nil {
                do {
                    try await self.flushPendingTranscript(runID: previousRunID)
                } catch {
                    canEvictPreviousTranscripts = false
                }
            }
            guard !Task.isCancelled, self.selectedRunID == requestedRunID else { return }
            do {
                try await self.recoverRunPayload(runID: requestedRunID)
                self.evictExternalizedRunPayloads()
            } catch {
                self.errorMessage = "Could not load this run's saved prompt and result: \(error.localizedDescription)"
            }
            guard !Task.isCancelled, self.selectedRunID == requestedRunID else { return }
            await self.recoverAppendOnlyTranscript(runID: requestedRunID)
            guard !Task.isCancelled, self.selectedRunID == requestedRunID else { return }
            if canEvictPreviousTranscripts {
                self.evictTranscripts(except: requestedRunID)
            }
            self.transcriptLoadTask = nil
        }
    }

    private func evictTranscripts(except retainedRunID: UUID?) {
        guard var activity = record.activity else { return }
        var changed = false
        for runIndex in activity.runs.indices {
            let runID = activity.runs[runIndex].id
            guard runID != retainedRunID else { continue }
            hydratedTranscriptRunIDs.remove(runID)
            visibleTranscriptTasks.removeValue(forKey: runID)?.cancel()
            visibleTranscriptChunks.removeValue(forKey: runID)
            visibleTranscriptUTF8ByteCounts.removeValue(forKey: runID)
            guard !activity.runs[runIndex].transcript.isEmpty else { continue }
            activity.runs[runIndex].transcript = ""
            changed = true
        }
        if changed {
            record.activity = activity
        }
    }

    private func recoverOperationalRunPayloads(
        loadGeneration: UUID
    ) async throws {
        guard let activity = record.activity else { return }
        var runIDs = Set([activity.runs.last?.id, selectedRunID].compactMap { $0 })
        if let checkpoint = activity.resumeCheckpoint {
            switch checkpoint {
            case .recoverRun(let runID), .routeCompletedRun(let runID):
                runIDs.insert(runID)
            case .perform:
                break
            }
        }
        if let checkpoint = activity.workflowResumeCheckpoint {
            switch checkpoint {
            case .recoverRun(let runID), .routeCompletedRun(let runID):
                runIDs.insert(runID)
            case .perform:
                break
            }
        }
        if let checkpoint = activity.liveTeam?.resumeCheckpoint {
            switch checkpoint {
            case .recoverRun(let runID), .routeCompletedRun(let runID),
                    .applyCoordinatorDecision(let runID):
                runIDs.insert(runID)
            case .invokeOverseer, .perform:
                break
            }
        }
        for runID in runIDs {
            try await recoverRunPayload(runID: runID, loadGeneration: loadGeneration)
        }
    }

    private func recoverRunPayload(
        runID: UUID?,
        loadGeneration: UUID? = nil
    ) async throws {
        guard let runID,
              loadGeneration.map(isCurrentLoad) ?? true,
              let activity = record.activity,
              let run = activity.runs.first(where: { $0.id == runID }),
              run.externalPayload == true,
              run.prompt.isEmpty else { return }
        guard let payload = try await store.recoveredRunPayload(
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: runID
        ) else {
            throw RepositoryCoordinatorError.missingExternalRunPayload(runID)
        }
        guard loadGeneration.map(isCurrentLoad) ?? true else { return }
        updateRun(runID) {
            $0.prompt = payload.prompt
            $0.finalOutput = payload.finalOutput
        }
    }

    private func evictExternalizedRunPayloads() {
        guard store.externalizesRunPayloads, var activity = record.activity else { return }
        var retainedRunIDs = Set([selectedRunID, activeRun?.id].compactMap { $0 })
        if let checkpoint = activity.resumeCheckpoint {
            switch checkpoint {
            case .recoverRun(let runID), .routeCompletedRun(let runID):
                retainedRunIDs.insert(runID)
            case .perform:
                break
            }
        }
        if let checkpoint = activity.workflowResumeCheckpoint {
            switch checkpoint {
            case .recoverRun(let runID), .routeCompletedRun(let runID):
                retainedRunIDs.insert(runID)
            case .perform:
                break
            }
        }
        if let checkpoint = activity.liveTeam?.resumeCheckpoint {
            switch checkpoint {
            case .recoverRun(let runID), .routeCompletedRun(let runID),
                    .applyCoordinatorDecision(let runID):
                retainedRunIDs.insert(runID)
            case .invokeOverseer, .perform:
                break
            }
        }
        for runIndex in activity.runs.indices {
            activity.runs[runIndex].externalPayload = true
            guard !retainedRunIDs.contains(activity.runs[runIndex].id) else { continue }
            activity.runs[runIndex].prompt = ""
            activity.runs[runIndex].finalOutput = nil
        }
        record.activity = activity
    }

    private func setRunTranscript(_ transcript: String, runID: UUID) {
        guard var activity = record.activity,
              let runIndex = activity.runs.firstIndex(where: { $0.id == runID }) else { return }
        guard activity.runs[runIndex].transcript != transcript else { return }
        activity.runs[runIndex].transcript = transcript
        record.activity = activity
        transcriptPresentationMutationCount += 1
    }

    private static func boundedTranscriptForPresentation(_ transcript: String) -> String {
        guard transcript.utf8.count > maximumPresentedTranscriptUTF8Bytes else {
            return transcript
        }
        let markerBytes = truncatedTranscriptMarker.utf8.count
        let suffixBudget = max(0, maximumPresentedTranscriptUTF8Bytes - markerBytes)
        let utf8 = transcript.utf8
        var start = utf8.index(utf8.endIndex, offsetBy: -suffixBudget)
        while start != utf8.endIndex, utf8[start] & 0xC0 == 0x80 {
            start = utf8.index(after: start)
        }
        return truncatedTranscriptMarker + String(decoding: utf8[start...], as: UTF8.self)
    }

    private func recoverAppendOnlyTokenUsage(
        loadGeneration: UUID? = nil
    ) async -> Bool {
        guard loadGeneration.map(isCurrentLoad) ?? true else { return false }
        guard let activity = record.activity else { return true }
        for run in activity.runs {
            let mayHaveUnpersistedUsage = [
                RunStatus.queued,
                .running,
                .awaitingApproval,
                .interrupted
            ].contains(run.status)
            guard run.tokenUsage == nil || mayHaveUnpersistedUsage else { continue }
            guard let recovered = try? await store.recoveredTokenUsage(
                repositoryPath: record.canonicalPath,
                activityID: activity.id,
                runID: run.id
            ), recovered != run.tokenUsage else {
                guard loadGeneration.map(isCurrentLoad) ?? true else { return false }
                continue
            }
            guard loadGeneration.map(isCurrentLoad) ?? true else { return false }
            updateRun(run.id) { $0.tokenUsage = recovered }
        }
        return true
    }

    private func appendPendingInteraction(_ interaction: PendingServerInteraction) -> Bool {
        let retainedByteCount = Self.retainedCost(of: interaction)
        let claimedCount = claimedInteractionID == nil ? 0 : 1
        let retainedBeforeAppend = Self.saturatingSum(
            pendingInteractionRetainedByteCount,
            claimedInteractionRetainedByteCount
        )
        guard pendingInteractions.count + claimedCount
                < Self.maximumPendingInteractionCount,
              retainedByteCount <= Self.maximumPendingInteractionRetainedBytes,
              retainedBeforeAppend
                <= Self.maximumPendingInteractionRetainedBytes - retainedByteCount else {
            return false
        }
        pendingInteractions.append(interaction)
        pendingInteractionRetainedByteCount += retainedByteCount
        return true
    }

    private func clearPendingInteractions() {
        pendingInteractions.removeAll(keepingCapacity: false)
        pendingInteractionRetainedByteCount = 0
        genericInteractionRoutes.removeAll(keepingCapacity: false)
        interactionResolutionInFlight = false
        interactionResolutionClaimID = nil
        claimedInteractionID = nil
        claimedInteractionRetainedByteCount = 0
    }

    private func stopRunForInteractionSafety(runID: UUID, detail: String) async {
        interactionSafetyTerminatingRunIDs.insert(runID)
        clearPendingInteractions()
        errorMessage = detail
        updateRun(runID) {
            $0.status = .failed
            $0.completedAt = .now
            $0.relayError = detail
        }
        var controlFailure: String?
        if let run = run(withID: runID), let target = run.agentTarget {
            if let agentProviders {
                do {
                    try await agentProviders.interrupt(
                        providerID: target.providerID,
                        runID: runID
                    )
                } catch {
                    controlFailure = error.localizedDescription
                }
            } else {
                controlFailure = "The active agent provider is unavailable."
            }
            record.activity?.workflowResumeCheckpoint = .recoverRun(runID)
            pauseGenericActivity(message: detail)
        } else if let run = run(withID: runID),
                  let threadID = run.threadID,
                  let turnID = run.turnID {
            do {
                try await interruptLegacyTurn(
                    runID: runID,
                    threadID: threadID,
                    turnID: turnID
                )
            } catch {
                controlFailure = error.localizedDescription
            }
            record.activity?.resumeCheckpoint = .recoverRun(runID)
            pauseActivity(message: detail)
        } else {
            controlFailure = "The stopped run has no interruptible provider turn identifier."
            pauseActivity(message: detail)
        }
        if let controlFailure {
            errorMessage = "\(detail) Codeness could not confirm that the provider turn stopped: \(controlFailure)"
            statusMessage = "Paused; provider termination is unconfirmed"
        }
        try? await persist()
    }

    /// A natural-looking terminal can race the interrupt requested by a
    /// fail-closed interaction or delta-limit stop. Never let that terminal
    /// promote the run to routing after the safety failure was committed.
    private func finishInteractionSafetyStopIfNeeded(runID: UUID) async -> Bool {
        guard interactionSafetyTerminatingRunIDs.remove(runID) != nil else {
            return false
        }
        clearPendingInteractions()
        itemsWithDeltas.removeValue(forKey: runID)
        deltaItemRetainedByteCounts.removeValue(forKey: runID)
        tokenUsageBaselines.removeValue(forKey: runID)
        let detail = run(withID: runID)?.relayError
            ?? "Codeness stopped this run after an unsafe interaction or output flood."
        updateRun(runID) {
            $0.status = .failed
            $0.completedAt = $0.completedAt ?? .now
            $0.relayError = detail
        }
        if record.activity?.liveTeam != nil {
            record.activity?.liveTeam?.resumeCheckpoint = .recoverRun(runID)
            pauseLiveTeamActivity(message: detail)
        } else if record.activity?.workflow != nil {
            record.activity?.workflowResumeCheckpoint = .recoverRun(runID)
            pauseGenericActivity(message: detail)
        } else {
            record.activity?.resumeCheckpoint = .recoverRun(runID)
            pauseActivity(message: detail)
        }
        if isClosing, !hasUnconfirmedSafetyStop {
            await completeCloseAfterTerminalEvent()
        } else if !isClosing {
            try? await persist()
        }
        return true
    }

    private nonisolated static func retainedCost(
        of interaction: PendingServerInteraction
    ) -> Int {
        var cost = 256
        cost = saturatingSum(cost, retainedCost(of: interaction.id))
        cost = saturatingSum(cost, interaction.method.utf8.count)
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
        for decision in interaction.approvalDecisions {
            cost = saturatingSum(cost, retainedCost(of: decision.value))
            cost = saturatingSum(cost, decision.label.utf8.count)
            cost = saturatingSum(cost, decision.explanation.utf8.count)
        }
        return cost
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
                saturatingSum(
                    saturatingSum(partial, entry.key.utf8.count),
                    retainedCost(of: entry.value)
                )
            }
        }
    }

    private nonisolated static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private func presentInteraction(
        id: JSONValue,
        method: String,
        params: JSONValue
    ) async {
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
        if let runID = activeRun?.id,
           interactionSafetyTerminatingRunIDs.contains(runID) {
            return
        }
        guard claimedInteractionID != id,
              !pendingInteractions.contains(where: { $0.id == id }) else {
            if let runID = activeRun?.id {
                await stopRunForInteractionSafety(
                    runID: runID,
                    detail: "Codex reused an unresolved interaction identifier. Codeness stopped the turn instead of allowing a hidden request to replace the visible request."
                )
            }
            return
        }
        guard appendPendingInteraction(interaction) else {
            if let runID = activeRun?.id {
                await stopRunForInteractionSafety(
                    runID: runID,
                    detail: "Codex accumulated too many unresolved interactions. Codeness stopped the turn to prevent unbounded memory growth."
                )
            }
            return
        }
        if let run = activeRun {
            updateRun(run.id) { $0.status = .awaitingApproval }
        }
        if pendingInteractions.count == 1 {
            statusMessage = title
        }
    }

    private func finishInteraction(id: JSONValue) async {
        removePendingInteraction(id: id)
        await refreshInteractionPresentationState()
    }

    private func removePendingInteraction(id: JSONValue) {
        var removedByteCount = 0
        pendingInteractions.removeAll { interaction in
            guard interaction.id == id else { return false }
            removedByteCount = Self.saturatingSum(
                removedByteCount,
                Self.retainedCost(of: interaction)
            )
            return true
        }
        pendingInteractionRetainedByteCount = max(
            0,
            pendingInteractionRetainedByteCount - removedByteCount
        )
    }

    private func refreshInteractionPresentationState() async {
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

    private func interruptLegacyTurn(
        runID: UUID,
        threadID: String,
        turnID: String
    ) async throws {
        let key = LegacyInterruptionKey(
            appServerGeneration: legacyAppServerGeneration,
            threadID: threadID,
            turnID: turnID
        )
        let debtIdentity: UUID
        if var debt = legacyInterruptionDebts[key] {
            guard debt.runID == runID,
                  debt.state == .requestFailed else {
                return
            }
            debtIdentity = debt.identity
            debt.lastError = "Codeness is retrying the interruption request."
            debt.state = .requestInFlight
            legacyInterruptionDebts[key] = debt
            legacyInterruptionRetryTasks.removeValue(forKey: key)?.cancel()
        } else {
            debtIdentity = UUID()
            legacyInterruptionDebts[key] = LegacyInterruptionDebt(
                runID: runID,
                identity: debtIdentity,
                attempts: 0,
                lastError: "Codeness requested interruption and is waiting for Codex to acknowledge the request.",
                state: .requestInFlight
            )
        }
        do {
            try await appServer.interrupt(threadID: threadID, turnID: turnID)
        } catch {
            await recordLegacyInterruptionFailureIfCurrent(
                runID: runID,
                key: key,
                debtIdentity: debtIdentity,
                detail: error.localizedDescription
            )
            throw error
        }
        recordLegacyInterruptionAcknowledgement(
            runID: runID,
            key: key,
            debtIdentity: debtIdentity
        )
    }

    private func recordLegacyInterruptionFailureIfCurrent(
        runID: UUID,
        key: LegacyInterruptionKey,
        debtIdentity: UUID,
        detail: String
    ) async {
        guard protocolContainment == nil,
              key.appServerGeneration == legacyAppServerGeneration,
              var debt = legacyInterruptionDebts[key],
              debt.runID == runID,
              debt.identity == debtIdentity,
              debt.state == .requestInFlight else {
            // The exact terminal or a generation boundary may have won while
            // the RPC was suspended. Never recreate debt after either proof.
            return
        }
        debt.attempts += 1
        debt.lastError = detail
        debt.state = .requestFailed
        legacyInterruptionDebts[key] = debt

        guard debt.attempts < legacyInterruptionMaximumAttemptCount else {
            let attemptLabel = debt.attempts == 1 ? "attempt" : "attempts"
            let containmentDetail = "Codeness could not confirm interruption of Codex turn \(key.turnID) after \(debt.attempts) \(attemptLabel): \(detail) Codeness stopped the App Server generation so the turn and its MCP/background processes cannot remain orphaned."
            await containLegacyAppServerGeneration(
                runID: runID,
                turnIDs: [key.turnID],
                detail: containmentDetail
            )
            return
        }
        scheduleLegacyInterruptionRetry(
            runID: runID,
            key: key,
            debtIdentity: debtIdentity
        )
    }

    private func scheduleLegacyInterruptionRetry(
        runID: UUID,
        key: LegacyInterruptionKey,
        debtIdentity: UUID
    ) {
        guard legacyInterruptionRetryTasks[key] == nil else { return }
        let delay = legacyInterruptionRetryDelay
        legacyInterruptionRetryTasks[key] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.retryLegacyInterruption(
                runID: runID,
                key: key,
                debtIdentity: debtIdentity
            )
        }
    }

    private func retryLegacyInterruption(
        runID: UUID,
        key: LegacyInterruptionKey,
        debtIdentity: UUID
    ) async {
        // Remove the current task before retrying so generation containment can
        // cancel every other retry without cancelling its own cleanup wait.
        legacyInterruptionRetryTasks.removeValue(forKey: key)
        guard protocolContainment == nil,
              key.appServerGeneration == legacyAppServerGeneration,
              let debt = legacyInterruptionDebts[key],
              debt.runID == runID,
              debt.identity == debtIdentity,
              debt.state == .requestFailed else {
            return
        }
        try? await interruptLegacyTurn(
            runID: runID,
            threadID: key.threadID,
            turnID: key.turnID
        )
    }

    private func recordLegacyInterruptionAcknowledgement(
        runID: UUID,
        key: LegacyInterruptionKey,
        debtIdentity: UUID
    ) {
        guard protocolContainment == nil,
              key.appServerGeneration == legacyAppServerGeneration,
              let run = run(withID: runID),
              run.threadID == key.threadID,
              run.turnID == key.turnID,
              legacyTurnStillRequiresTermination(runID: runID, run: run),
              var debt = legacyInterruptionDebts[key],
              debt.runID == runID,
              debt.identity == debtIdentity,
              debt.state == .requestInFlight else {
            return
        }
        debt.lastError = "Codex acknowledged interruption, but Codeness is waiting for the exact matching turn/completed notification."
        debt.state = .awaitingTerminal
        legacyInterruptionDebts[key] = debt
        legacyInterruptionRetryTasks.removeValue(forKey: key)?.cancel()
        // Repeated Pause/Stop requests must not extend the bounded deadline.
        guard legacyInterruptionWatchdogs[key] == nil else { return }
        let timeout = legacyInterruptionTerminalTimeout
        legacyInterruptionWatchdogs[key] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.legacyInterruptionTimedOut(
                key: key,
                debtIdentity: debtIdentity
            )
        }
    }

    private func legacyTurnStillRequiresTermination(
        runID: UUID,
        run: RunRecord
    ) -> Bool {
        [.queued, .running, .awaitingApproval].contains(run.status)
            || interactionSafetyTerminatingRunIDs.contains(runID)
            || transcriptBackpressureRunIDs.contains(runID)
    }

    private func legacyInterruptionTimedOut(
        key: LegacyInterruptionKey,
        debtIdentity: UUID
    ) async {
        guard protocolContainment == nil,
              key.appServerGeneration == legacyAppServerGeneration,
              legacyInterruptionDebts[key]?.identity == debtIdentity,
              legacyInterruptionDebts[key]?.state == .awaitingTerminal,
              let runID = legacyInterruptionDebts[key]?.runID else {
            return
        }
        legacyInterruptionWatchdogs.removeValue(forKey: key)
        let detail = "Codex acknowledged interruption of turn \(key.turnID), but did not emit the exact matching turn/completed notification within the bounded wait. Codeness stopped the App Server generation so the turn and its MCP/background processes cannot be orphaned."
        await containLegacyAppServerGeneration(
            runID: runID,
            turnIDs: [key.turnID],
            detail: detail
        )
    }

    private func clearLegacyInterruptionDebt(
        threadID: String,
        turnID: String
    ) {
        let key = LegacyInterruptionKey(
            appServerGeneration: legacyAppServerGeneration,
            threadID: threadID,
            turnID: turnID
        )
        clearLegacyInterruptionDebt(key)
    }

    private func clearLegacyInterruptionDebt(_ key: LegacyInterruptionKey) {
        legacyInterruptionDebts.removeValue(forKey: key)
        legacyInterruptionRetryTasks.removeValue(forKey: key)?.cancel()
        legacyInterruptionWatchdogs.removeValue(forKey: key)?.cancel()
    }

    private func clearAllLegacyInterruptionDebts(advanceGeneration: Bool) {
        legacyInterruptionRetryTasks.values.forEach { $0.cancel() }
        legacyInterruptionRetryTasks.removeAll()
        legacyInterruptionWatchdogs.values.forEach { $0.cancel() }
        legacyInterruptionWatchdogs.removeAll()
        legacyInterruptionDebts.removeAll()
        if advanceGeneration {
            legacyAppServerGeneration &+= 1
        }
    }

    private func unresolvedLegacyInterruption(
        forThreadID threadID: String
    ) -> (key: LegacyInterruptionKey, debt: LegacyInterruptionDebt)? {
        legacyInterruptionDebts.first { key, _ in
            key.appServerGeneration == legacyAppServerGeneration
                && key.threadID == threadID
        }.map { (key: $0.key, debt: $0.value) }
    }

    private func belongsToRepository(_ event: AppServerEvent) -> Bool {
        guard let threadID = event.threadID else { return false }
        return threadID == record.implementerThreadID || threadID == record.reviewerThreadID
    }

    private func runID(for event: AppServerEvent) -> UUID? {
        guard let threadID = event.threadID else { return nil }
        let activeStatuses: [RunStatus] = [.queued, .running, .awaitingApproval]
        let isTerminalEvent: Bool = switch event {
        case .notification(let method, _, _):
            ["thread/closed", "turn/completed"].contains(method)
        case .request, .standardError, .exited:
            false
        }
        let admitsRun: (RunRecord) -> Bool = { run in
            activeStatuses.contains(run.status)
                || (isTerminalEvent && self.interactionSafetyTerminatingRunIDs.contains(run.id))
                || (isTerminalEvent && self.transcriptBackpressureRunIDs.contains(run.id))
        }
        if let turnID = event.turnID {
            if let run = record.activity?.runs.last(where: {
                $0.turnID == turnID && admitsRun($0)
            }) {
                return run.id
            }
            if retiredTurnIDs.contains(turnID)
                || record.activity?.runs.contains(where: {
                    $0.threadID == threadID && $0.turnID == turnID
                }) == true {
                return nil
            }
            // Only turn/started is allowed to bind a previously queued run by
            // thread. Every later turn-scoped event must match its exact turn;
            // otherwise a delayed terminal from a superseded turn could be
            // attributed to the replacement run on the same persistent thread.
            guard case .notification(let method, _, _) = event,
                  method == "turn/started" else {
                return nil
            }
            let candidates = record.activity?.runs.filter {
                $0.threadID == threadID
                    && $0.status == .queued
                    && $0.turnID == nil
            } ?? []
            guard candidates.count == 1 else { return nil }
            return candidates[0].id
        }
        return record.activity?.runs.last(where: {
            $0.threadID == threadID && admitsRun($0)
        })?.id
    }

    private func terminateGenerationForUnexpectedLegacyStartedIdentityIfNeeded(
        event: AppServerEvent
    ) async -> Bool {
        guard let threadID = event.threadID,
              let incomingTurnID = event.turnID,
              !retiredTurnIDs.contains(incomingTurnID),
              record.activity?.runs.contains(where: {
                  $0.threadID == threadID && $0.turnID == incomingTurnID
              }) != true,
              let run = record.activity?.runs.last(where: {
                  $0.threadID == threadID
                      && [.queued, .running, .awaitingApproval].contains($0.status)
                      && $0.turnID != nil
              }),
              let currentTurnID = run.turnID,
              currentTurnID != incomingTurnID else {
            return false
        }
        await containLegacyAppServerGeneration(
            runID: run.id,
            turnIDs: [currentTurnID, incomingTurnID],
            detail: "Codex identified the active turn as both \(currentTurnID) and \(incomingTurnID). Codeness stopped the App Server generation instead of attaching this run to an ambiguous execution."
        )
        return true
    }

    private func containLegacyAppServerGeneration(
        runID: UUID,
        turnIDs: Set<String>,
        detail: String
    ) async {
        guard protocolContainment == nil else { return }
        let preservedSafetyFailure = (
            interactionSafetyTerminatingRunIDs.contains(runID)
                || transcriptBackpressureRunIDs.contains(runID)
        ) ? run(withID: runID)?.relayError : nil
        let containmentID = UUID()
        // Install the generation-wide gate before any persistence or process
        // cleanup await can re-enter this actor. A terminal for either candidate
        // turn ID must never release this ownership fence.
        protocolContainment = ProtocolContainment(
            id: containmentID,
            detail: detail
        )
        clearAllLegacyInterruptionDebts(advanceGeneration: false)
        for turnID in turnIDs {
            retireTurnID(turnID)
        }
        clearPendingInteractions()
        itemsWithDeltas.removeValue(forKey: runID)
        deltaItemRetainedByteCounts.removeValue(forKey: runID)
        tokenUsageBaselines.removeValue(forKey: runID)
        updateRun(runID) {
            $0.status = .failed
            $0.turnID = nil
            $0.completedAt = .now
            $0.relayError = preservedSafetyFailure ?? detail
        }
        record.activity?.resumeCheckpoint = .recoverRun(runID)
        pauseActivity(message: detail)
        errorMessage = detail
        let containmentConfirmed = await appServer
            .terminateGenerationForProtocolViolation(detail)
        guard protocolContainment?.id == containmentID else {
            // An .exited event confirmed cleanup while termination was waiting.
            return
        }
        if !containmentConfirmed {
            let unresolvedDetail = "\(detail) Codeness could not confirm that the isolated App Server process scope terminated, so replacement work remains blocked."
            protocolContainment?.detail = unresolvedDetail
            errorMessage = unresolvedDetail
            statusMessage = "Paused; App Server containment is unconfirmed"
        } else {
            protocolContainment = nil
            clearAllLegacyInterruptionDebts(advanceGeneration: true)
            markProviderSessionsDetachedByProcessBoundary(.codex)
            clearSafetyStopStateAfterAppServerBoundary()
        }
        if isClosing, containmentConfirmed {
            await completeCloseAfterTerminalEvent()
        } else if isClosing {
            try? await persist()
            _ = failClose(errorMessage ?? detail)
        } else {
            try? await persist()
        }
    }

    private func retireTurnID(_ turnID: String) {
        guard retiredTurnIDs.insert(turnID).inserted else { return }
        retiredTurnIDOrder.append(turnID)
        let overflow = retiredTurnIDOrder.count - Self.maximumRetiredTurnIDCount
        guard overflow > 0 else { return }
        for retiredID in retiredTurnIDOrder.prefix(overflow) {
            retiredTurnIDs.remove(retiredID)
        }
        retiredTurnIDOrder.removeFirst(overflow)
    }

    private func run(withID id: UUID) -> RunRecord? {
        record.activity?.runs.first(where: { $0.id == id })
    }

    private func updateRun(_ id: UUID, update: (inout RunRecord) -> Void) {
        guard var activity = record.activity,
              let runIndex = activity.runs.firstIndex(where: { $0.id == id }) else { return }
        let previousHandoff = activity.runs[runIndex].handoff
        let previousWorkflowHandoff = activity.runs[runIndex].workflowHandoff
        let previousCoordinatorDecision = activity.runs[runIndex].coordinatorDecision
        update(&activity.runs[runIndex])
        let workSummarySourceChanged = previousHandoff != activity.runs[runIndex].handoff
            || previousWorkflowHandoff != activity.runs[runIndex].workflowHandoff
            || previousCoordinatorDecision != activity.runs[runIndex].coordinatorDecision
        record.activity = activity
        record.updatedAt = .now
        if workSummarySourceChanged {
            cancelWorkOverviewSummaryRequest()
        }
    }

    private func pauseActivity(message: String) {
        guard record.activity != nil else { return }
        record.activity?.status = .paused
        statusMessage = message
    }

    private func repairAutonomousDirectionPauseIfNeeded() {
        guard record.activity?.status == .paused,
              record.activity?.liveTeam != nil else {
            return
        }
        if let index = record.activity?.liveTeam?.editHistory.indices.last,
           let edit = record.activity?.liveTeam?.editHistory[index] {
            let normalizedSummary: String? = switch edit.summary {
            case "Paused for Board direction": "Paused for your direction"
            case "Completion needs Board direction": "Completion needs your direction"
            default: nil
            }
            if let normalizedSummary {
                record.activity?.liveTeam?.editHistory[index] = LiveTeamEditRecord(
                    id: edit.id,
                    revision: edit.revision,
                    actor: edit.actor,
                    summary: normalizedSummary,
                    reason: edit.reason,
                    evidence: edit.evidence,
                    createdAt: edit.createdAt
                )
            }
        }
        if record.activity?.liveTeam?.boardDirectionReason == nil,
           let lastEdit = record.activity?.liveTeam?.editHistory.last,
           [
               "Paused for your direction",
               "Completion needs your direction"
           ]
            .contains(lastEdit.summary) {
            record.activity?.liveTeam?.boardDirectionReason = lastEdit.reason
        }
        if let reason = record.activity?.liveTeam?.boardDirectionReason {
            let existingCheckpoint = record.activity?.liveTeam?.resumeCheckpoint
            let continuation: LiveTeamCheckpoint?
            let sourceRunID: UUID?
            switch existingCheckpoint {
            case .invokeOverseer(let request):
                continuation = preferredLiveTeamContinuation(
                    requested: request.continuation,
                    preferredMemberID: nil
                )
                sourceRunID = request.sourceRunID ?? record.activity?.runs.last?.id
            case .perform(let checkpoint):
                continuation = preferredLiveTeamContinuation(
                    requested: checkpoint,
                    preferredMemberID: nil
                )
                sourceRunID = record.activity?.runs.last?.id
            case nil:
                continuation = nil
                sourceRunID = record.activity?.runs.last?.id
            default:
                continuation = nil
                sourceRunID = record.activity?.runs.last?.id
            }
            let resumeRequest = autonomousContinuationOverseerRequest(
                previousReason: reason,
                sourceRunID: sourceRunID,
                continuation: continuation
            )
            record.activity?.liveTeam?.resumeCheckpoint = .invokeOverseer(resumeRequest)
            record.activity?.liveTeam?.boardDirectionReason = nil
            if let index = record.activity?.liveTeam?.editHistory.indices.last,
               let edit = record.activity?.liveTeam?.editHistory[index],
               [
                   "Paused for your direction",
                   "Completion needs your direction"
               ].contains(edit.summary) {
                record.activity?.liveTeam?.editHistory[index] = LiveTeamEditRecord(
                    id: edit.id,
                    revision: edit.revision,
                    actor: edit.actor,
                    summary: "Recovered internal strategy boundary",
                    reason: edit.reason,
                    evidence: edit.evidence,
                    createdAt: edit.createdAt
                )
            }
        }
    }

    /// Earlier goal-directed builds let a local routing decision pause the
    /// activity directly. Restore that exact saved shape to the decision
    /// boundary so Resume asks the control invocation that sees the user goal.
    private func repairCoordinatorPauseAuthorityIfNeeded() {
        guard var activity = record.activity,
              activity.status == .paused,
              activity.liveTeam?.boardDirectionReason == nil,
              case .perform(let checkpoint)? = activity.liveTeam?.resumeCheckpoint,
              let runIndex = activity.runs.indices.last,
              activity.runs[runIndex].status == .paused,
              activity.runs[runIndex].coordinatorDecision?.disposition == .pause,
              activity.runs[runIndex].liveTeamMember?.member.id == checkpoint.memberID else {
            return
        }

        let runID = activity.runs[runIndex].id
        let memberID = checkpoint.memberID
        activity.runs[runIndex].status = .completed
        activity.runs[runIndex].relayError = nil
        activity.liveTeam?.resumeCheckpoint = .applyCoordinatorDecision(runID)
        if let failures = activity.liveTeam?.memberFailureCounts[memberID] {
            if failures <= 1 {
                activity.liveTeam?.memberFailureCounts.removeValue(forKey: memberID)
            } else {
                activity.liveTeam?.memberFailureCounts[memberID] = failures - 1
            }
        }
        record.activity = activity
    }

    private func normalizeLiveTeamProductLanguageIfNeeded() {
        if var activity = record.activity, activity.liveTeam != nil {
            LiveTeamProductLanguage.normalizePersistedControlText(in: &activity)
            record.activity = activity
        }
        if let summary = viewState.workOverviewSummary {
            viewState.workOverviewSummary = WorkOverviewSummaryCache(
                sourceSignature: summary.sourceSignature,
                text: LiveTeamProductLanguage.workSummary(summary.text),
                generatedAt: summary.generatedAt
            )
        }
    }

    /// Codex Plan mode can end a turn with a `plan` item instead of an
    /// `agentMessage`. Earlier builds displayed that valid terminal output but
    /// classified the turn as failed. Repair only that exact persisted shape;
    /// ordinary failures remain failures.
    private func repairCompletedPlanTurnIfNeeded() {
        guard var activity = record.activity,
              activity.status == .paused,
              activity.liveTeam != nil,
              case .recoverRun(let runID)? = activity.liveTeam?.resumeCheckpoint,
              let runIndex = activity.runs.firstIndex(where: { $0.id == runID }),
              runIndex == activity.runs.count - 1,
              activity.runs[runIndex].status == .failed,
              activity.runs[runIndex].relayError == "Codex turn ended with status completed.",
              activity.runs[runIndex].finalOutput?.isEmpty != false,
              activity.runs[runIndex].agentTarget?.options.mode == .plan,
              let output = Self.terminalPlanOutput(from: activity.runs[runIndex]),
              let memberID = activity.runs[runIndex].liveTeamMember?.member.id else {
            return
        }

        activity.runs[runIndex].finalOutput = output
        activity.runs[runIndex].relayError = nil
        activity.runs[runIndex].status = .routing
        activity.runs[runIndex].completedAt = activity.runs[runIndex].completedAt ?? .now
        activity.liveTeam?.resumeCheckpoint = .routeCompletedRun(runID)
        if let failures = activity.liveTeam?.memberFailureCounts[memberID] {
            if failures <= 1 {
                activity.liveTeam?.memberFailureCounts.removeValue(forKey: memberID)
            } else {
                activity.liveTeam?.memberFailureCounts[memberID] = failures - 1
            }
        }
        record.activity = activity
    }

    private static func terminalPlanOutput(from run: RunRecord) -> String? {
        let transcript = RunTranscriptPresentation.text(
            for: run,
            separatesRuns: true,
            visibility: .all
        )
        let marker = "\nPlan\n"
        let output: Substring
        if let range = transcript.range(of: marker, options: .backwards) {
            output = transcript[range.upperBound...]
        } else if transcript.hasPrefix("Plan\n") {
            output = transcript.dropFirst("Plan\n".count)
        } else {
            return nil
        }
        let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private var pausedStatusMessage: String {
        guard let activity = record.activity else { return "Paused" }
        if let checkpoint = activity.liveTeam?.resumeCheckpoint {
            switch checkpoint {
            case .invokeOverseer(let request):
                return "Paused before \(request.mode.displayName.lowercased())"
            case .recoverRun:
                return "Interrupted; inspect the repository before resuming"
            case .routeCompletedRun:
                return "Handoff pending; resume without replaying the agent"
            case .applyCoordinatorDecision:
                return "Routing decision saved; resume local flow"
            case .perform(let checkpoint):
                return "Paused before \(liveTeamMemberName(at: checkpoint))"
            }
        }
        if let checkpoint = activity.workflowResumeCheckpoint {
            switch checkpoint {
            case .recoverRun:
                return "Interrupted; inspect the repository before resuming"
            case .routeCompletedRun:
                return "Handoff pending; resume without replaying the completed step"
            case .perform(let cursor):
                return "Paused before \(genericStepName(at: cursor))"
            }
        }
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

    private func recordTranscript(_ text: String, runID: UUID) async {
        guard !text.isEmpty,
              record.activity?.runs.contains(where: { $0.id == runID }) == true else { return }

        let utf8 = text.utf8
        var cursor = utf8.startIndex
        while cursor != utf8.endIndex {
            if transcriptBackpressureRunIDs.contains(runID) {
                recordDroppedTranscriptBytes(
                    utf8.distance(from: cursor, to: utf8.endIndex),
                    runID: runID
                )
                return
            }

            let bufferedByteCount = pendingTranscriptBuffers[runID]?.utf8Count ?? 0
            let bufferedChunkCount = pendingTranscriptBuffers[runID]?.chunks.count ?? 0
            if bufferedByteCount == Self.maximumPendingTranscriptUTF8Bytes
                || bufferedChunkCount == Self.maximumPendingTranscriptChunkCount {
                if transcriptHydrationIDs[runID] != nil {
                    await waitForTranscriptHydration(runID: runID)
                    continue
                }
                do {
                    try await flushPendingTranscript(runID: runID)
                } catch {
                    await stopRunForTranscriptBackpressure(
                        runID: runID,
                        droppedByteCount: utf8.distance(from: cursor, to: utf8.endIndex),
                        error: error
                    )
                    return
                }
                continue
            }
            let availableByteCount = Self.maximumPendingTranscriptUTF8Bytes - bufferedByteCount

            let remainingByteCount = utf8.distance(from: cursor, to: utf8.endIndex)
            let fragmentByteBudget = min(availableByteCount, remainingByteCount)
            var fragmentEnd = utf8.index(cursor, offsetBy: fragmentByteBudget)
            while fragmentEnd != cursor,
                  fragmentEnd != utf8.endIndex,
                  utf8[fragmentEnd] & 0xC0 == 0x80 {
                fragmentEnd = utf8.index(before: fragmentEnd)
            }
            // The remaining capacity can be smaller than the next multi-byte
            // scalar. Flush the existing prefix and retry with an empty buffer.
            if fragmentEnd == cursor {
                if transcriptHydrationIDs[runID] != nil {
                    await waitForTranscriptHydration(runID: runID)
                    continue
                }
                do {
                    try await flushPendingTranscript(runID: runID)
                } catch {
                    await stopRunForTranscriptBackpressure(
                        runID: runID,
                        droppedByteCount: remainingByteCount,
                        error: error
                    )
                    return
                }
                continue
            }

            let fragment = String(text[cursor..<fragmentEnd])
            appendPendingTranscriptFragment(fragment, runID: runID)
            cursor = fragmentEnd
        }
    }

    private func appendPendingTranscriptFragment(_ text: String, runID: UUID) {
        nextTranscriptSequence &+= 1
        let chunk = TranscriptChunk(
            sequence: nextTranscriptSequence,
            text: text,
            utf8Count: text.utf8.count
        )
        let buffer: PendingTranscriptBuffer
        if let existing = pendingTranscriptBuffers[runID] {
            buffer = existing
        } else {
            buffer = PendingTranscriptBuffer()
            pendingTranscriptBuffers[runID] = buffer
        }
        buffer.append(chunk)

        precondition(buffer.utf8Count <= Self.maximumPendingTranscriptUTF8Bytes)
        precondition(buffer.chunks.count <= Self.maximumPendingTranscriptChunkCount)
        if transcriptHydrationIDs[runID] != nil {
            transcriptHydrationChunks[runID, default: []].append(chunk)
        } else if selectedRunID == runID, hydratedTranscriptRunIDs.contains(runID) {
            visibleTranscriptChunks[runID, default: []].append(chunk)
            visibleTranscriptUTF8ByteCounts[runID, default: 0] += chunk.utf8Count
            if visibleTranscriptUTF8ByteCounts[runID, default: 0]
                >= Self.transcriptFlushByteThreshold
                || visibleTranscriptChunks[runID, default: []].count
                    >= Self.transcriptFlushChunkThreshold {
                visibleTranscriptTasks.removeValue(forKey: runID)?.cancel()
                flushVisibleTranscriptUpdate(runID: runID)
            } else {
                scheduleVisibleTranscriptUpdate(runID: runID)
            }
            precondition(
                visibleTranscriptUTF8ByteCounts[runID, default: 0]
                    < Self.transcriptFlushByteThreshold
            )
            precondition(
                visibleTranscriptChunks[runID, default: []].count
                    < Self.transcriptFlushChunkThreshold
            )
        }
        scheduleTranscriptFlush(
            runID: runID,
            immediately: buffer.utf8Count >= Self.transcriptFlushByteThreshold
                || buffer.chunks.count >= Self.transcriptFlushChunkThreshold
        )
    }

    private func scheduleVisibleTranscriptUpdate(runID: UUID) {
        guard visibleTranscriptTasks[runID] == nil else { return }
        visibleTranscriptTasks[runID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.transcriptFlushDelay)
            guard !Task.isCancelled, let self else { return }
            self.visibleTranscriptTasks.removeValue(forKey: runID)
            self.flushVisibleTranscriptUpdate(runID: runID)
        }
    }

    private func flushVisibleTranscriptUpdate(runID: UUID) {
        guard selectedRunID == runID,
              hydratedTranscriptRunIDs.contains(runID) else { return }
        let chunks = visibleTranscriptChunks.removeValue(forKey: runID) ?? []
        visibleTranscriptUTF8ByteCounts.removeValue(forKey: runID)
        guard !chunks.isEmpty else { return }
        let appended = chunks.map(\.text).joined()
        let current = run(withID: runID)?.transcript ?? ""
        setRunTranscript(
            Self.boundedTranscriptForPresentation(current + appended),
            runID: runID
        )
    }

    private func scheduleTranscriptFlush(runID: UUID, immediately: Bool) {
        guard transcriptHydrationIDs[runID] == nil,
              scheduledTranscriptFlushTasks[runID] == nil,
              transcriptFlushes[runID] == nil else { return }
        scheduledTranscriptFlushTasks[runID] = Task { @MainActor [weak self] in
            if !immediately {
                try? await Task.sleep(for: Self.transcriptFlushDelay)
            }
            guard !Task.isCancelled, let self else { return }
            self.scheduledTranscriptFlushTasks.removeValue(forKey: runID)
            do {
                try await self.flushPendingTranscript(runID: runID)
            } catch {
                self.transcriptFlushFailureRunIDs.insert(runID)
            }
        }
    }

    private func flushPendingTranscript(runID: UUID) async throws {
        scheduledTranscriptFlushTasks.removeValue(forKey: runID)?.cancel()
        var shouldRefreshSelectedTranscript = false

        while let buffer = pendingTranscriptBuffers[runID], !buffer.chunks.isEmpty {
            let flush: TranscriptFlush
            if let existing = transcriptFlushes[runID] {
                flush = existing
            } else {
                guard let activity = record.activity,
                      activity.runs.contains(where: { $0.id == runID }),
                      let lastSequence = buffer.chunks.last?.sequence else {
                    throw RepositoryCoordinatorError.missingTranscriptRun(runID)
                }
                let pending = buffer.text(through: lastSequence)
                let operationID = UUID()
                let store = self.store
                let repositoryPath = record.canonicalPath
                let activityID = activity.id
                let task = Task {
                    try await store.appendTranscript(
                        pending,
                        repositoryPath: repositoryPath,
                        activityID: activityID,
                        runID: runID
                    )
                }
                flush = TranscriptFlush(
                    id: operationID,
                    lastSequence: lastSequence,
                    task: task
                )
                transcriptFlushes[runID] = flush
            }

            do {
                try await flush.task.value
            } catch {
                if transcriptFlushes[runID]?.id == flush.id {
                    transcriptFlushes.removeValue(forKey: runID)
                    transcriptFlushFailureRunIDs.insert(runID)
                }
                throw error
            }

            if transcriptFlushes[runID]?.id == flush.id {
                transcriptFlushes.removeValue(forKey: runID)
                buffer.consume(through: flush.lastSequence)
                if buffer.chunks.isEmpty {
                    pendingTranscriptBuffers.removeValue(forKey: runID)
                    evictTranscriptIfUnselected(runID: runID)
                }
                shouldRefreshSelectedTranscript = transcriptFlushFailureRunIDs.remove(runID) != nil
                    || shouldRefreshSelectedTranscript
            }
        }

        if shouldRefreshSelectedTranscript,
           transcriptHydrationIDs[runID] == nil,
           selectedRunID == runID {
            await recoverAppendOnlyTranscript(runID: runID)
        }
    }

    private func evictTranscriptIfUnselected(runID: UUID) {
        guard selectedRunID != runID else { return }
        hydratedTranscriptRunIDs.remove(runID)
        setRunTranscript("", runID: runID)
    }

    private func flushPendingTranscripts() async throws {
        for runID in Array(pendingTranscriptBuffers.keys) {
            try await flushPendingTranscript(runID: runID)
        }
    }

    private func stopRunForTranscriptBackpressure(
        runID: UUID,
        droppedByteCount: Int,
        error: Error
    ) async {
        let isFirstFailure = transcriptBackpressureRunIDs.insert(runID).inserted
        if transcriptBackpressureFailureDetails[runID] == nil {
            transcriptBackpressureFailureDetails[runID] = error.localizedDescription
        }
        recordDroppedTranscriptBytes(droppedByteCount, runID: runID)
        guard isFirstFailure, let run = run(withID: runID) else { return }

        var controlFailure: String?
        if let target = run.agentTarget {
            if let agentProviders {
                do {
                    try await agentProviders.interrupt(
                        providerID: target.providerID,
                        runID: runID
                    )
                } catch {
                    controlFailure = error.localizedDescription
                }
            } else {
                controlFailure = "The active agent provider is unavailable."
            }
        } else if let threadID = run.threadID, let turnID = run.turnID {
            do {
                try await interruptLegacyTurn(
                    runID: runID,
                    threadID: threadID,
                    turnID: turnID
                )
            } catch {
                controlFailure = error.localizedDescription
            }
        } else {
            controlFailure = "The stopped run has no interruptible provider turn identifier."
        }
        if let controlFailure {
            errorMessage = "\(transcriptBackpressureMessage(runID: runID)) Codeness could not confirm that the provider turn stopped: \(controlFailure)"
            statusMessage = "Paused; provider termination is unconfirmed"
        }
        await persistTranscriptBackpressureMetadata()
    }

    private func recordDroppedTranscriptBytes(_ byteCount: Int, runID: UUID) {
        guard byteCount > 0 else { return }
        let current = droppedTranscriptUTF8Bytes[runID] ?? 0
        let (sum, overflow) = current.addingReportingOverflow(byteCount)
        droppedTranscriptUTF8Bytes[runID] = overflow ? Int.max : sum
        applyTranscriptBackpressureFailure(runID: runID)
    }

    private func applyTranscriptBackpressureFailure(runID: UUID) {
        let message = transcriptBackpressureMessage(runID: runID)
        errorMessage = message
        updateRun(runID) {
            $0.status = .failed
            $0.completedAt = $0.completedAt ?? .now
            $0.relayError = message
        }
        record.activity?.status = .paused
        if record.activity?.liveTeam != nil {
            record.activity?.liveTeam?.resumeCheckpoint = .recoverRun(runID)
        } else if record.activity?.workflow != nil {
            record.activity?.workflowResumeCheckpoint = .recoverRun(runID)
        } else {
            record.activity?.resumeCheckpoint = .recoverRun(runID)
        }
        statusMessage = "Paused because transcript output could not be saved"
    }

    private func transcriptBackpressureMessage(runID: UUID) -> String {
        let droppedByteCount = droppedTranscriptUTF8Bytes[runID] ?? 0
        let detail = transcriptBackpressureFailureDetails[runID]
            ?? RepositoryCoordinatorError.transcriptBackpressureLimit(runID).localizedDescription
        return "Codeness stopped this run after \(droppedByteCount) UTF-8 bytes of transcript output could not be persisted. Its pending transcript memory remains capped at 8 MiB. \(detail)"
    }

    private func finishBackpressuredRunAfterTerminalEvent(runID: UUID) async {
        applyTranscriptBackpressureFailure(runID: runID)
        // The terminal event is definitive, so it no longer needs an admission
        // tombstone. Keep any pending transcript buffer and flush-failure marker:
        // those bytes remain authoritative and must still be retried durably.
        transcriptBackpressureRunIDs.remove(runID)
        droppedTranscriptUTF8Bytes.removeValue(forKey: runID)
        transcriptBackpressureFailureDetails.removeValue(forKey: runID)
        if isClosing, !hasUnconfirmedSafetyStop {
            await completeCloseAfterTerminalEvent()
        } else if !isClosing {
            await persistTranscriptBackpressureMetadata()
        }
    }

    private func persistTranscriptBackpressureMetadata() async {
        guard isLoaded else { return }
        record.updatedAt = .now
        try? await store.save(workspaceMetadataSnapshot(record))
    }

    private func appendTokenUsage(_ usage: RunTokenUsage, runID: UUID) async {
        guard let activityID = record.activity?.id,
              record.activity?.runs.contains(where: { $0.id == runID }) == true else { return }
        try? await store.appendTokenUsage(
            usage,
            repositoryPath: record.canonicalPath,
            activityID: activityID,
            runID: runID
        )
    }

    private func persist() async throws {
        guard isLoaded else { throw RepositoryCoordinatorError.documentNotLoaded }
        try await flushPendingTranscripts()
        record.updatedAt = .now
        try await store.save(workspaceMetadataSnapshot(record))
        evictExternalizedRunPayloads()
    }

    private func workspaceMetadataSnapshot(_ source: RepositoryRecord) -> RepositoryRecord {
        var snapshot = source
        guard let runIndices = snapshot.activity?.runs.indices else { return snapshot }
        for runIndex in runIndices {
            snapshot.activity?.runs[runIndex].transcript = ""
        }
        return snapshot
    }

    private func persistDocumentState() async throws {
        guard isLoaded else { throw RepositoryCoordinatorError.documentNotLoaded }
        viewState.selectedRunID = selectedRunID
        viewState.runSelectionWasSaved = true
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

    private var workSummarySnapshot: WorkSummarySnapshot? {
        if let workSummarySnapshotCache {
            return workSummarySnapshotCache
        }
        guard let context = makeWorkSummaryContext() else { return nil }
        let snapshot = WorkSummarySnapshot(
            context: context,
            sourceSignature: context.sourceSignature
        )
        workSummarySnapshotCache = snapshot
        workSummarySnapshotBuildCount += 1
        return snapshot
    }

    private func makeWorkSummaryContext() -> WorkSummaryContext? {
        guard let activity = record.activity else { return nil }
        let handoffs = activity.runs.compactMap { run -> WorkSummaryHandoff? in
            if let decision = run.coordinatorDecision {
                let disposition: SourceDisposition = switch decision.disposition {
                case .continueTeam, .retryCurrent: .implementationCheckpoint
                case .completionCandidate: .implementationComplete
                case .pause, .requestOversight: .blocked
                }
                return WorkSummaryHandoff(
                    runID: run.id,
                    sequence: run.sequence,
                    kind: run.kind,
                    label: decision.runLabel,
                    disposition: disposition,
                    text: decision.handoff
                )
            }
            if let handoff = run.workflowHandoff {
                let disposition: SourceDisposition = switch handoff.outcome {
                case .continueWorkflow: .implementationCheckpoint
                case .complete: .fixComplete
                case .blocked: .blocked
                case .failed: .failed
                case .unclear: .unclear
                }
                return WorkSummaryHandoff(
                    runID: run.id,
                    sequence: run.sequence,
                    kind: run.kind,
                    label: handoff.runLabel,
                    disposition: disposition,
                    text: handoff.text
                )
            }
            guard let handoff = run.handoff else { return nil }
            return WorkSummaryHandoff(
                runID: run.id,
                sequence: run.sequence,
                kind: run.kind,
                label: handoff.runLabel,
                disposition: handoff.sourceDisposition,
                text: handoff.handoffText
            )
        }
        guard !handoffs.isEmpty else { return nil }
        return WorkSummaryContext(
            goal: activity.liveTeam?.currentDefinition?.workingGoal ?? activity.goal,
            handoffs: handoffs
        )
    }

    private func cancelWorkOverviewSummaryRequest() {
        workOverviewSummaryTask?.cancel()
        workOverviewSummaryTask = nil
        workOverviewSummaryTaskSignature = nil
        isGeneratingWorkOverviewSummary = false
        workSummarySnapshotCache = nil
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
            if record.activity?.liveTeam != nil {
                if record.activity?.liveTeam?.resumeCheckpoint == nil,
                   let checkpoint = record.activity?.liveTeam?.checkpoint {
                    record.activity?.liveTeam?.resumeCheckpoint = .perform(checkpoint)
                }
            } else if record.activity?.workflow != nil {
                if record.activity?.workflowResumeCheckpoint == nil,
                   let cursor = record.activity?.workflowCursor {
                    record.activity?.workflowResumeCheckpoint = .perform(cursor)
                }
            } else {
                migrateResumeCheckpointIfNeeded()
            }
        }
        guard await flushDocumentState() else {
            return failClose(errorMessage ?? "Could not save this repository document.")
        }
        let unreleasedSessions = await detachProviderSessionsForCurrentDocument()
        guard unreleasedSessions.isEmpty else {
            return failClose(
                "Codeness saved this repository, but could not confirm provider-session detachment for \(providerSessionDescription(unreleasedSessions)). The document remains open so no agent work is orphaned."
            )
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
        clearPendingInteractions()
        interactionResolutionInFlight = false
        let saved = await flushDocumentState()
        if saved {
            let unreleasedSessions = await detachProviderSessionsForCurrentDocument()
            if unreleasedSessions.isEmpty {
                pauseState = .paused
                let waiter = closeWaiter
                closeWaiter = nil
                waiter?.resume(returning: .ready)
            } else {
                _ = failClose(
                    "Codeness saved this repository, but could not confirm provider-session detachment for \(providerSessionDescription(unreleasedSessions)). The document remains open so no agent work is orphaned."
                )
            }
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
    case providerLaunchCancelledForClose
    case providerSessionsStillAttached(String)
    case missingSession(AgentRole)
    case missingRun(UUID)
    case missingExternalRunPayload(UUID)
    case missingTranscriptRun(UUID)
    case transcriptBackpressureLimit(UUID)
    case missingRunOutput(UUID)

    var errorDescription: String? {
        switch self {
        case .documentNotLoaded:
            "Repository state has not loaded; its saved data was left unchanged."
        case .startOverWhileClosing:
            "The repository window began closing before its activity could be reset."
        case .providerLaunchCancelledForClose:
            "The provider launch stopped because this repository window is closing."
        case .providerSessionsStillAttached(let sessions):
            "Provider-session detachment was not confirmed for \(sessions). The existing activity was left in place so no agent work is orphaned."
        case .missingSession(let role):
            "The saved \(role.displayName.lowercased()) Codex session is missing. Its context was not replaced."
        case .missingRun(let id):
            "The saved resume checkpoint refers to missing run \(id.uuidString)."
        case .missingExternalRunPayload(let id):
            "The saved prompt and result for run \(id.uuidString) are missing."
        case .missingTranscriptRun(let id):
            "Transcript output for run \(id.uuidString) no longer belongs to the current activity."
        case .transcriptBackpressureLimit(let id):
            "Transcript output for run \(id.uuidString) reached Codeness's 8 MiB pending-write safety limit."
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
