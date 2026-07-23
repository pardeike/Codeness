import Foundation

public enum AgentRole: String, Codable, Sendable, CaseIterable {
    case implementer
    case reviewer

    public var displayName: String {
        switch self {
        case .implementer: "Implementer"
        case .reviewer: "Reviewer"
        }
    }
}

public enum RunKind: String, Codable, Sendable {
    case implementation
    case review
    case fix

    public var displayName: String {
        switch self {
        case .implementation: "Implement"
        case .review: "Review"
        case .fix: "Fix"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case Self.implementation.rawValue, "checkpointImplementation": self = .implementation
        case Self.review.rawValue, "checkpointReview", "finalReview": self = .review
        case Self.fix.rawValue, "finalCloseout": self = .fix
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown run kind \(value)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum RunStatus: String, Codable, Sendable {
    case queued
    case running
    case routing
    case awaitingApproval
    case paused
    case completed
    case interrupted
    case failed
}

public enum ActivityStatus: String, Codable, Sendable {
    case running
    case paused
    case completed
    case cancelled
    case failed
}

public enum SourceDisposition: String, Codable, Sendable, CaseIterable {
    case implementationCheckpoint
    case implementationComplete
    case reviewComplete
    case fixComplete
    case blocked
    case failed
    case unclear

    public var displayName: String {
        switch self {
        case .implementationCheckpoint: "Implementation checkpoint"
        case .implementationComplete: "Implementation complete"
        case .reviewComplete: "Review complete"
        case .fixComplete: "Fixes complete"
        case .blocked: "Blocked"
        case .failed: "Failed"
        case .unclear: "Unclear"
        }
    }

    public static func validValues(for runKind: RunKind) -> [SourceDisposition] {
        switch runKind {
        case .implementation:
            [.implementationCheckpoint, .implementationComplete, .blocked, .failed, .unclear]
        case .review:
            [.reviewComplete, .blocked, .failed, .unclear]
        case .fix:
            [.fixComplete, .blocked, .failed, .unclear]
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "closeoutComplete" {
            self = .fixComplete
        } else if let disposition = Self(rawValue: value) {
            self = disposition
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown source disposition \(value)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct HandoffEnvelope: Codable, Sendable, Equatable {
    public var handoffText: String
    public var sourceDisposition: SourceDisposition
    public var runLabel: String

    public init(handoffText: String, sourceDisposition: SourceDisposition, runLabel: String) {
        self.handoffText = handoffText
        self.sourceDisposition = sourceDisposition
        self.runLabel = runLabel
    }
}

public struct ModelSelection: Codable, Sendable, Equatable {
    public var model: String
    public var effort: String

    public init(model: String, effort: String) {
        self.model = model
        self.effort = effort
    }
}

public struct RepositoryModelDefaults: Codable, Sendable, Equatable {
    public static let builtInDefaults = RepositoryModelDefaults(
        implementer: .init(model: "gpt-5.6-sol", effort: "high"),
        reviewer: .init(model: "gpt-5.6-sol", effort: "max"),
        fixer: .init(model: "gpt-5.6-sol", effort: "high"),
        handoff: .init(model: "gpt-5.6-luna", effort: "low")
    )

    public var implementer: ModelSelection
    public var reviewer: ModelSelection
    public var fixer: ModelSelection
    public var handoff: ModelSelection

    public init(
        implementer: ModelSelection,
        reviewer: ModelSelection,
        fixer: ModelSelection,
        handoff: ModelSelection
    ) {
        self.implementer = implementer
        self.reviewer = reviewer
        self.fixer = fixer
        self.handoff = handoff
    }

    public init(settings: RepositorySettings) {
        implementer = settings.implementer
        reviewer = settings.reviewer
        fixer = settings.fixer
        handoff = settings.relay.selection
    }

    public func applying(to settings: RepositorySettings) -> RepositorySettings {
        var result = settings
        result.implementer = implementer
        result.reviewer = reviewer
        result.fixer = fixer
        result.relay.selection = handoff
        return result
    }
}

public struct RelaySettings: Codable, Sendable, Equatable {
    public var apiKeyFile: String
    public var apiKeyName: String
    public var selection: ModelSelection

    public init(
        apiKeyFile: String = "~/.api-keys",
        apiKeyName: String = "OPENAI_API_KEY",
        selection: ModelSelection = .init(model: "gpt-5.6-luna", effort: "low")
    ) {
        self.apiKeyFile = apiKeyFile
        self.apiKeyName = apiKeyName
        self.selection = selection
    }
}

public struct ActivityPrompts: Codable, Sendable, Equatable {
    public static let implementationOutputPlaceholder = "{{implementation_output}}"
    public static let reviewOutputPlaceholder = "{{review_output}}"

    public static let builtInDefaults = ActivityPrompts(
        implementation: """
        Let's start or continue implementing the goal above and stop when you think a review is useful. If the whole goal is implemented, say so clearly. Your last output will be passed on to the reviewer.
        """,
        review: """
        The implementer has completed an implementation step toward the goal above and waits for you to review the progress so far. You have one chance to judge the progress against the full goal. Inspect the actual repository and do not modify files. Your feedback will be provided to the implementer so it can address the review before continuing.

        This is what the implementer wrote before it stopped:
        {{implementation_output}}
        """,
        fix: """
        Here comes the review feedback for the goal above. Address it, then stop without continuing with the next implementation step:

        {{review_output}}
        """
    )

    public var implementation: String
    public var review: String
    public var fix: String

    public init(implementation: String, review: String, fix: String) {
        self.implementation = implementation
        self.review = review
        self.fix = fix
    }

    public var validationMessage: String? {
        if implementation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The implementation prompt is empty."
        }
        if review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The review prompt is empty."
        }
        if fix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The fix prompt is empty."
        }
        if !review.contains(Self.implementationOutputPlaceholder) {
            return "The review prompt must contain \(Self.implementationOutputPlaceholder)."
        }
        if !fix.contains(Self.reviewOutputPlaceholder) {
            return "The fix prompt must contain \(Self.reviewOutputPlaceholder)."
        }
        return nil
    }
}

public struct RepositorySettings: Codable, Sendable, Equatable {
    public var implementer: ModelSelection
    public var reviewer: ModelSelection
    public var fixer: ModelSelection
    public var relay: RelaySettings

    public init(
        implementer: ModelSelection = .init(model: "gpt-5.6-sol", effort: "high"),
        reviewer: ModelSelection = .init(model: "gpt-5.6-sol", effort: "max"),
        fixer: ModelSelection? = nil,
        relay: RelaySettings = .init()
    ) {
        self.implementer = implementer
        self.reviewer = reviewer
        self.fixer = fixer ?? implementer
        self.relay = relay
    }

    private enum CodingKeys: String, CodingKey {
        case implementer
        case reviewer
        case fixer
        case relay
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        implementer = try container.decodeIfPresent(ModelSelection.self, forKey: .implementer)
            ?? .init(model: "gpt-5.6-sol", effort: "high")
        reviewer = try container.decodeIfPresent(ModelSelection.self, forKey: .reviewer)
            ?? .init(model: "gpt-5.6-sol", effort: "max")
        fixer = try container.decodeIfPresent(ModelSelection.self, forKey: .fixer) ?? implementer
        relay = try container.decodeIfPresent(RelaySettings.self, forKey: .relay) ?? .init()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(implementer, forKey: .implementer)
        try container.encode(reviewer, forKey: .reviewer)
        try container.encode(fixer, forKey: .fixer)
        try container.encode(relay, forKey: .relay)
    }
}

public struct CodexModel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let model: String
    public let displayName: String
    public let description: String
    public let defaultEffort: String
    public let efforts: [String]
    public let hidden: Bool

    public init(
        id: String,
        model: String,
        displayName: String,
        description: String,
        defaultEffort: String,
        efforts: [String],
        hidden: Bool
    ) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.description = description
        self.defaultEffort = defaultEffort
        self.efforts = efforts
        self.hidden = hidden
    }
}

public enum PendingAction: String, Codable, Sendable, Equatable {
    case implement
    case review
    case fix
    case complete
}

public enum ResumeCheckpoint: Codable, Sendable, Equatable {
    case recoverRun(UUID)
    case routeCompletedRun(UUID)
    case perform(PendingAction)
}

public struct GoalAmendment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let previousGoal: String
    public let revisedGoal: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        previousGoal: String,
        revisedGoal: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.previousGoal = previousGoal
        self.revisedGoal = revisedGoal
        self.createdAt = createdAt
    }
}

public struct TranscriptViewportState: Codable, Sendable, Equatable {
    public var topCharacterOffset: Int
    public var verticalOffset: Double
    public var followsOutput: Bool

    public init(
        topCharacterOffset: Int = 0,
        verticalOffset: Double = 0,
        followsOutput: Bool = true
    ) {
        self.topCharacterOffset = topCharacterOffset
        self.verticalOffset = verticalOffset
        self.followsOutput = followsOutput
    }
}

public struct StoredWindowFrame: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var displayIdentifier: String?

    public init(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        displayIdentifier: String? = nil
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.displayIdentifier = displayIdentifier
    }
}

public struct RepositoryViewState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var selectedRunID: UUID?
    public var transcriptViewports: [UUID: TranscriptViewportState]
    public var windowFrame: StoredWindowFrame?
    public var sidebarWidth: Double?
    public var sidebarVisible: Bool
    public var pauseAfterCurrent: Bool
    public var detailPresentation: RunDetailPresentation?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        selectedRunID: UUID? = nil,
        transcriptViewports: [UUID: TranscriptViewportState] = [:],
        windowFrame: StoredWindowFrame? = nil,
        sidebarWidth: Double? = nil,
        sidebarVisible: Bool = true,
        pauseAfterCurrent: Bool = false,
        detailPresentation: RunDetailPresentation? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.selectedRunID = selectedRunID
        self.transcriptViewports = transcriptViewports
        self.windowFrame = windowFrame
        self.sidebarWidth = sidebarWidth
        self.sidebarVisible = sidebarVisible
        self.pauseAfterCurrent = pauseAfterCurrent
        self.detailPresentation = detailPresentation
    }
}

public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sequence: Int
    public let role: AgentRole
    public let kind: RunKind
    public var status: RunStatus
    public var threadID: String?
    public var turnID: String?
    public let model: String
    public let effort: String
    public let prompt: String
    public var transcript: String
    public var finalOutput: String?
    public var handoff: HandoffEnvelope?
    public var relayError: String?
    public let startedAt: Date
    public var completedAt: Date?
    public var durationMilliseconds: Int64?

    public init(
        id: UUID = UUID(),
        sequence: Int,
        role: AgentRole,
        kind: RunKind,
        status: RunStatus,
        threadID: String?,
        turnID: String? = nil,
        model: String,
        effort: String,
        prompt: String,
        transcript: String = "",
        finalOutput: String? = nil,
        handoff: HandoffEnvelope? = nil,
        relayError: String? = nil,
        startedAt: Date = .now,
        completedAt: Date? = nil,
        durationMilliseconds: Int64? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.role = role
        self.kind = kind
        self.status = status
        self.threadID = threadID
        self.turnID = turnID
        self.model = model
        self.effort = effort
        self.prompt = prompt
        self.transcript = transcript
        self.finalOutput = finalOutput
        self.handoff = handoff
        self.relayError = relayError
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct ActivityRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var goal: String
    public let prompts: ActivityPrompts
    public var status: ActivityStatus
    public var runs: [RunRecord]
    public var pendingAction: PendingAction?
    public var resumeCheckpoint: ResumeCheckpoint?
    public var implementationClaimedComplete: Bool
    public var goalAmendments: [GoalAmendment]
    public let createdAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        goal: String,
        prompts: ActivityPrompts,
        status: ActivityStatus = .running,
        runs: [RunRecord] = [],
        pendingAction: PendingAction? = nil,
        resumeCheckpoint: ResumeCheckpoint? = nil,
        implementationClaimedComplete: Bool = false,
        goalAmendments: [GoalAmendment] = [],
        createdAt: Date = .now,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.goal = goal
        self.prompts = prompts
        self.status = status
        self.runs = runs
        self.pendingAction = pendingAction
        self.resumeCheckpoint = resumeCheckpoint
        self.implementationClaimedComplete = implementationClaimedComplete
        self.goalAmendments = goalAmendments
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case goal
        case prompts
        case status
        case runs
        case pendingAction
        case resumeCheckpoint
        case implementationClaimedComplete
        case goalAmendments
        case createdAt
        case completedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        goal = try container.decode(String.self, forKey: .goal)
        prompts = try container.decode(ActivityPrompts.self, forKey: .prompts)
        status = try container.decodeIfPresent(ActivityStatus.self, forKey: .status) ?? .paused
        runs = try container.decodeIfPresent([RunRecord].self, forKey: .runs) ?? []
        pendingAction = try container.decodeIfPresent(PendingAction.self, forKey: .pendingAction)
        resumeCheckpoint = try container.decodeIfPresent(ResumeCheckpoint.self, forKey: .resumeCheckpoint)
        implementationClaimedComplete = try container.decodeIfPresent(
            Bool.self,
            forKey: .implementationClaimedComplete
        ) ?? false
        goalAmendments = try container.decodeIfPresent(
            [GoalAmendment].self,
            forKey: .goalAmendments
        ) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(goal, forKey: .goal)
        try container.encode(prompts, forKey: .prompts)
        try container.encode(status, forKey: .status)
        try container.encode(runs, forKey: .runs)
        try container.encodeIfPresent(pendingAction, forKey: .pendingAction)
        try container.encodeIfPresent(resumeCheckpoint, forKey: .resumeCheckpoint)
        try container.encode(implementationClaimedComplete, forKey: .implementationClaimedComplete)
        if !goalAmendments.isEmpty {
            try container.encode(goalAmendments, forKey: .goalAmendments)
        }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}

/// The editable configuration shown before an activity starts.
///
/// Fresh repository windows have no draft and therefore use the application's
/// current defaults. Starting over captures the preceding activity here so the
/// same goal and prompts can be edited before a new session pair is created.
public struct ActivityConfigurationDraft: Codable, Sendable, Equatable {
    public var goal: String
    public var prompts: ActivityPrompts

    public init(goal: String, prompts: ActivityPrompts) {
        self.goal = goal
        self.prompts = prompts
    }
}

public struct RepositoryRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let canonicalPath: String
    public var implementerThreadID: String?
    public var reviewerThreadID: String?
    public var settings: RepositorySettings
    public var activityDraft: ActivityConfigurationDraft?
    public var activity: ActivityRecord?
    public let createdAt: Date
    public var updatedAt: Date
    private var legacyTasks: [LegacyTaskRecord]

    public init(
        id: UUID = UUID(),
        canonicalPath: String,
        implementerThreadID: String? = nil,
        reviewerThreadID: String? = nil,
        settings: RepositorySettings = .init(),
        activityDraft: ActivityConfigurationDraft? = nil,
        activity: ActivityRecord? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.canonicalPath = canonicalPath
        self.implementerThreadID = implementerThreadID
        self.reviewerThreadID = reviewerThreadID
        self.settings = settings
        self.activityDraft = activityDraft
        self.activity = activity
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        legacyTasks = []
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case canonicalPath
        case implementerThreadID
        case reviewerThreadID
        case settings
        case activityDraft
        case activity
        case tasks
        case createdAt
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        canonicalPath = try container.decode(String.self, forKey: .canonicalPath)
        implementerThreadID = try container.decodeIfPresent(String.self, forKey: .implementerThreadID)
        reviewerThreadID = try container.decodeIfPresent(String.self, forKey: .reviewerThreadID)
        settings = try container.decodeIfPresent(RepositorySettings.self, forKey: .settings) ?? .init()
        activityDraft = try container.decodeIfPresent(
            ActivityConfigurationDraft.self,
            forKey: .activityDraft
        )
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        legacyTasks = try container.decodeIfPresent([LegacyTaskRecord].self, forKey: .tasks) ?? []
        activity = try container.decodeIfPresent(ActivityRecord.self, forKey: .activity)
            ?? legacyTasks.last.map(ActivityRecord.init(legacy:))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(canonicalPath, forKey: .canonicalPath)
        try container.encodeIfPresent(implementerThreadID, forKey: .implementerThreadID)
        try container.encodeIfPresent(reviewerThreadID, forKey: .reviewerThreadID)
        try container.encode(settings, forKey: .settings)
        try container.encodeIfPresent(activityDraft, forKey: .activityDraft)
        try container.encodeIfPresent(activity, forKey: .activity)
        if !legacyTasks.isEmpty {
            try container.encode(legacyTasks, forKey: .tasks)
        }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

private struct LegacyTaskRecord: Codable, Sendable, Equatable {
    let id: UUID
    let title: String
    let specification: String
    let status: ActivityStatus
    let runs: [RunRecord]
    let pendingAction: PendingAction?
    let implementationClaimedComplete: Bool
    let createdAt: Date
    let completedAt: Date?
    private let encodedPendingAction: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case specification
        case status
        case runs
        case pendingAction
        case createdAt
        case completedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Legacy activity"
        specification = try container.decodeIfPresent(String.self, forKey: .specification) ?? ""
        status = try container.decodeIfPresent(ActivityStatus.self, forKey: .status) ?? .completed
        runs = try container.decodeIfPresent([RunRecord].self, forKey: .runs) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)

        encodedPendingAction = try container.decodeIfPresent(JSONValue.self, forKey: .pendingAction)
        let actionName = encodedPendingAction?.stringValue ?? encodedPendingAction?.objectValue?.keys.first
        switch actionName {
        case "intermediateReview", "finalReview", PendingAction.review.rawValue:
            pendingAction = .review
        case "fixAndContinue", "finalCloseout", PendingAction.fix.rawValue:
            pendingAction = .fix
        case PendingAction.implement.rawValue:
            pendingAction = .implement
        case PendingAction.complete.rawValue:
            pendingAction = .complete
        default:
            pendingAction = nil
        }
        implementationClaimedComplete = actionName == "finalReview" || actionName == "finalCloseout"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(specification, forKey: .specification)
        try container.encode(status, forKey: .status)
        try container.encode(runs, forKey: .runs)
        try container.encodeIfPresent(encodedPendingAction, forKey: .pendingAction)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}

private extension ActivityRecord {
    init(legacy: LegacyTaskRecord) {
        let title = legacy.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let specification = legacy.specification.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = specification.isEmpty
            ? title
            : [title, specification].filter { !$0.isEmpty }.joined(separator: "\n\n")
        self.init(
            id: legacy.id,
            goal: goal,
            prompts: .builtInDefaults,
            status: legacy.status,
            runs: legacy.runs,
            pendingAction: legacy.pendingAction,
            implementationClaimedComplete: legacy.implementationClaimedComplete,
            createdAt: legacy.createdAt,
            completedAt: legacy.completedAt
        )
    }
}

public struct HandoffContext: Sendable, Equatable {
    public let sender: AgentRole
    public let recipient: AgentRole?
    public let runKind: RunKind
    public let recipientPurpose: String
    public let source: String

    public init(sender: AgentRole, recipient: AgentRole?, runKind: RunKind, recipientPurpose: String, source: String) {
        self.sender = sender
        self.recipient = recipient
        self.runKind = runKind
        self.recipientPurpose = recipientPurpose
        self.source = source
    }
}
