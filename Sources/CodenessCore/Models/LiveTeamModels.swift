import Foundation

public enum LiveTeamRunPolicy: String, Codable, CaseIterable, Sendable {
    case once
    case everyCycle

    public var displayName: String {
        return switch self {
        case .once: "Once"
        case .everyCycle: "Every round"
        }
    }
}

public enum LiveTeamSessionPolicy: Codable, Equatable, Sendable {
    case ownMemory
    case sharedMemory(groupID: String)
    case freshEveryRun

    private enum CodingKeys: String, CodingKey {
        case kind
        case groupID
    }

    private enum Kind: String, Codable {
        case ownMemory
        case sharedMemory
        case freshEveryRun
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .ownMemory:
            self = .ownMemory
        case .freshEveryRun:
            self = .freshEveryRun
        case .sharedMemory:
            let groupID = try container.decode(String.self, forKey: .groupID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !groupID.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .groupID,
                    in: container,
                    debugDescription: "A shared-memory group needs an identifier."
                )
            }
            self = .sharedMemory(groupID: groupID)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ownMemory:
            try container.encode(Kind.ownMemory, forKey: .kind)
        case .freshEveryRun:
            try container.encode(Kind.freshEveryRun, forKey: .kind)
        case .sharedMemory(let groupID):
            try container.encode(Kind.sharedMemory, forKey: .kind)
            try container.encode(groupID, forKey: .groupID)
        }
    }

    public var displayName: String {
        switch self {
        case .ownMemory: "Own memory"
        case .sharedMemory(let groupID): "Shared · \(groupID)"
        case .freshEveryRun: "Fresh every turn"
        }
    }

    public func persistentSlotID(memberID: String) -> String? {
        persistentSlotID(memberID: memberID, positionID: nil)
    }

    public func persistentSlotID(
        memberID: String,
        positionID: CompanyPositionID?
    ) -> String? {
        let policySuffix = positionID.map {
            ":policy:\(CompanyToolPolicy(positionID: $0).id)"
        } ?? ""
        return switch self {
        case .ownMemory:
            "member:\(memberID)\(policySuffix)"
        case .sharedMemory(let groupID):
            "shared:\(groupID)\(policySuffix)"
        case .freshEveryRun:
            nil
        }
    }
}

public struct LiveTeamMember: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var instructions: String
    public var target: AgentTarget
    public var runPolicy: LiveTeamRunPolicy
    public var sessionPolicy: LiveTeamSessionPolicy
    public var positionID: CompanyPositionID?
    public var person: CompanyPerson?
    public var companyAssignment: CompanyAssignmentContract?

    public init(
        id: String,
        name: String,
        instructions: String,
        target: AgentTarget,
        runPolicy: LiveTeamRunPolicy,
        sessionPolicy: LiveTeamSessionPolicy,
        positionID: CompanyPositionID? = nil,
        person: CompanyPerson? = nil,
        companyAssignment: CompanyAssignmentContract? = nil
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.target = target
        self.runPolicy = runPolicy
        self.sessionPolicy = sessionPolicy
        self.positionID = positionID
        self.person = person
        self.companyAssignment = companyAssignment
    }

    public var validationMessage: String? {
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "An agent has no identifier."
        }
        let allowedIdentifierCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_.")
        )
        if id.unicodeScalars.contains(where: {
            !allowedIdentifierCharacters.contains($0)
        }) {
            return "Agent \(id) has an invalid identifier. Use letters, numbers, dash, underscore, or period."
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Agent \(id) has no name."
        }
        if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(name) has no responsibility."
        }
        if let message = target.validationMessage {
            return "\(name): \(message)"
        }
        if let person {
            guard positionID == person.positionID else {
                return "\(name) has a person hired into a different position."
            }
            if let message = person.profile.validationMessage {
                return "\(name): \(message)"
            }
        }
        if let companyAssignment {
            guard let positionID else {
                return "\(name) has a company assignment without a position."
            }
            if let message = companyAssignment.validationMessage(
                positionID: positionID,
                target: target
            ) {
                return "\(name): \(message)"
            }
        }
        if case .sharedMemory(let groupID) = sessionPolicy,
           groupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(name) has an empty shared-memory group."
        }
        return nil
    }

}

public struct LiveTeamCoordinatorConfiguration: Codable, Equatable, Sendable {
    public var target: AgentTarget
    public var instructions: String

    public init(target: AgentTarget, instructions: String) {
        self.target = target
        self.instructions = instructions
    }

    public var validationMessage: String? {
        if let message = target.validationMessage {
            return "Work routing: \(message)"
        }
        if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The work-routing policy is empty."
        }
        return nil
    }
}

public struct LiveTeamOverseerConfiguration: Codable, Equatable, Sendable {
    public var target: AgentTarget
    public var instructions: String

    public init(target: AgentTarget, instructions: String) {
        self.target = target
        self.instructions = instructions
    }

    public var validationMessage: String? {
        if let message = target.validationMessage {
            return "Strategy reviews: \(message)"
        }
        if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The strategy-review policy is empty."
        }
        return nil
    }
}

public struct LiveTeamDefinition: Codable, Equatable, Sendable {
    public var revision: Int
    public var workingGoal: String
    public var members: [LiveTeamMember]
    public var coordinator: LiveTeamCoordinatorConfiguration
    public var overseerTarget: AgentTarget
    public var strategicReason: String
    public var operatingModelVersion: Int
    public var overseerPerson: CompanyPerson?
    public var formerPeople: [CompanyPerson]
    public var productBet: CompanyProductBet?
    public var setupTokenUsage: RunTokenUsage?

    public init(
        revision: Int,
        workingGoal: String,
        members: [LiveTeamMember],
        coordinator: LiveTeamCoordinatorConfiguration,
        overseerTarget: AgentTarget? = nil,
        strategicReason: String,
        operatingModelVersion: Int = 1,
        overseerPerson: CompanyPerson? = nil,
        formerPeople: [CompanyPerson] = [],
        productBet: CompanyProductBet? = nil,
        setupTokenUsage: RunTokenUsage? = nil
    ) {
        self.revision = max(revision, 1)
        self.workingGoal = workingGoal
        self.members = members
        self.coordinator = coordinator
        self.overseerTarget = overseerTarget ?? coordinator.target
        self.strategicReason = strategicReason
        self.operatingModelVersion = max(operatingModelVersion, 1)
        self.overseerPerson = overseerPerson
        self.formerPeople = formerPeople
        self.productBet = productBet
        self.setupTokenUsage = setupTokenUsage
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case workingGoal
        case members
        case coordinator
        case overseerTarget
        case strategicReason
        case operatingModelVersion
        case overseerPerson
        case formerPeople
        case productBet
        case setupTokenUsage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let coordinator = try container.decode(
            LiveTeamCoordinatorConfiguration.self,
            forKey: .coordinator
        )
        self.init(
            revision: try container.decode(Int.self, forKey: .revision),
            workingGoal: try container.decode(String.self, forKey: .workingGoal),
            members: try container.decode([LiveTeamMember].self, forKey: .members),
            coordinator: coordinator,
            overseerTarget: try container.decodeIfPresent(
                AgentTarget.self,
                forKey: .overseerTarget
            ) ?? coordinator.target,
            strategicReason: try container.decode(String.self, forKey: .strategicReason),
            operatingModelVersion: try container.decodeIfPresent(
                Int.self,
                forKey: .operatingModelVersion
            ) ?? 1,
            overseerPerson: try container.decodeIfPresent(
                CompanyPerson.self,
                forKey: .overseerPerson
            ),
            formerPeople: try container.decodeIfPresent(
                [CompanyPerson].self,
                forKey: .formerPeople
            ) ?? [],
            productBet: try container.decodeIfPresent(
                CompanyProductBet.self,
                forKey: .productBet
            ),
            setupTokenUsage: try container.decodeIfPresent(
                RunTokenUsage.self,
                forKey: .setupTokenUsage
            )
        )
    }

    public func member(id: String) -> LiveTeamMember? {
        members.first { $0.id == id }
    }

    public var validationMessage: String? {
        if workingGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The working goal is empty."
        }
        if members.isEmpty {
            return "At least one agent is required."
        }
        let identifiers = members.map(\.id)
        if Set(identifiers).count != identifiers.count {
            return "The agents contain duplicate identifiers."
        }
        if let message = members.compactMap(\.validationMessage).first {
            return message
        }
        if let message = coordinator.validationMessage {
            return message
        }
        if let message = overseerTarget.validationMessage {
            return "Strategy reviews: \(message)"
        }
        if strategicReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The strategic reason is empty."
        }
        if operatingModelVersion >= 2 {
            guard let overseerPerson,
                  overseerPerson.positionID == .chiefExecutive else {
                return "The company needs a CEO."
            }
            if let message = overseerPerson.profile.validationMessage {
                return "CEO: \(message)"
            }
            guard let productBet else {
                return "The company needs a funded product bet."
            }
            if let message = productBet.validationMessage {
                return message
            }
            if members.contains(where: { $0.positionID == .chiefExecutive }) {
                return "The CEO cannot also occupy a worker assignment."
            }
            if members.contains(where: {
                $0.positionID == nil || $0.person == nil || $0.companyAssignment == nil
            }) {
                return "Every company assignment needs a person, standard position, and exact contribution contract."
            }
            var suppliedContributions: Set<CompanyContributionKind> = []
            for member in members {
                guard let assignment = member.companyAssignment else { continue }
                let missing = Set(assignment.dependencyContributionKinds)
                    .subtracting(suppliedContributions)
                if !missing.isEmpty {
                    let names = missing.map(\.rawValue).sorted().joined(separator: ", ")
                    return "\(member.name) depends on contributions that are not supplied earlier in the company: \(names)."
                }
                suppliedContributions.insert(assignment.contributionKind)
            }
            let currentPeople = [overseerPerson] + members.map(\.person)
            if Set(currentPeople.compactMap { $0?.id }).count != currentPeople.count {
                return "Every current company position needs a distinct person."
            }
        }

        let sharedEntries: [(groupID: String, member: LiveTeamMember)] = members.compactMap { member in
            guard case .sharedMemory(let groupID) = member.sessionPolicy else {
                return nil
            }
            return (groupID: groupID, member: member)
        }
        let sharedGroups = Dictionary(grouping: sharedEntries, by: \.groupID)
        for (groupID, entries) in sharedGroups {
            guard let first = entries.first?.member else { continue }
            let incompatible = entries.dropFirst().contains { entry in
                !Self.canShareSession(first.target, entry.member.target)
            }
            if incompatible {
                return "Shared-memory group \(groupID) contains incompatible agent targets."
            }
        }
        return nil
    }

    public static func canShareSession(_ lhs: AgentTarget, _ rhs: AgentTarget) -> Bool {
        lhs.providerID == rhs.providerID
            && lhs.model == rhs.model
            && lhs.options.mode == rhs.options.mode
    }
}

public struct LiveTeamCheckpoint: Codable, Equatable, Sendable {
    public var memberID: String
    public var cycle: Int
    public var revision: Int

    public init(memberID: String, cycle: Int, revision: Int) {
        self.memberID = memberID
        self.cycle = max(cycle, 1)
        self.revision = max(revision, 1)
    }
}

public enum LiveTeamOverseerMode: String, Codable, CaseIterable, Sendable {
    case bootstrap
    case strategicReview
    case completionReview
    case migration

    public var displayName: String {
        switch self {
        case .bootstrap: "Initial Setup"
        case .strategicReview: "Investment Review"
        case .completionReview: "Completion Review"
        case .migration: "Earlier Activity Setup"
        }
    }
}

public struct LiveTeamOverseerRequest: Codable, Equatable, Sendable {
    public var mode: LiveTeamOverseerMode
    public var reason: String
    public var sourceRunID: UUID?
    public var continuation: LiveTeamCheckpoint?
    public var automatic: Bool
    public var leavePaused: Bool

    public init(
        mode: LiveTeamOverseerMode,
        reason: String,
        sourceRunID: UUID? = nil,
        continuation: LiveTeamCheckpoint? = nil,
        automatic: Bool,
        leavePaused: Bool = false
    ) {
        self.mode = mode
        self.reason = reason
        self.sourceRunID = sourceRunID
        self.continuation = continuation
        self.automatic = automatic
        self.leavePaused = leavePaused
    }
}

public enum LiveTeamResumeCheckpoint: Codable, Equatable, Sendable {
    case invokeOverseer(LiveTeamOverseerRequest)
    case recoverRun(UUID)
    case routeCompletedRun(UUID)
    case applyCoordinatorDecision(UUID)
    case perform(LiveTeamCheckpoint)
}

public enum LiveTeamRevisionActor: String, Codable, CaseIterable, Sendable {
    case board
    case overseer

    public var displayName: String {
        switch self {
        case .board: "User"
        case .overseer: "Codeness"
        }
    }
}

public struct LiveTeamPendingRevision: Codable, Equatable, Sendable {
    public var definition: LiveTeamDefinition
    public var baseRevision: Int
    public var actor: LiveTeamRevisionActor
    public var reason: String
    public var evidence: String
    public var preferredNextMemberID: String?
    public var createdAt: Date

    public init(
        definition: LiveTeamDefinition,
        baseRevision: Int,
        actor: LiveTeamRevisionActor,
        reason: String,
        evidence: String,
        preferredNextMemberID: String? = nil,
        createdAt: Date = .now
    ) {
        self.definition = definition
        self.baseRevision = baseRevision
        self.actor = actor
        self.reason = reason
        self.evidence = evidence
        self.preferredNextMemberID = preferredNextMemberID
        self.createdAt = createdAt
    }
}

public struct LiveTeamEditRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let revision: Int
    public let actor: LiveTeamRevisionActor
    public let summary: String
    public let reason: String
    public let evidence: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        revision: Int,
        actor: LiveTeamRevisionActor,
        summary: String,
        reason: String,
        evidence: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.revision = revision
        self.actor = actor
        self.summary = summary
        self.reason = reason
        self.evidence = evidence
        self.createdAt = createdAt
    }
}

public enum LiveTeamReviewStatus: String, Codable, Equatable, Sendable {
    case researchingFocusGroup
    case selectingManagers
    case consultingManagers
    case overseerDeciding
    case completed
    case failed
}

public enum LiveTeamManagerConsultationStatus: String, Codable, Equatable, Sendable {
    case waiting
    case reporting
    case completed
    case unavailable
}

public enum LiveTeamFocusGroupResearchBasis: String, Codable, Equatable, Sendable {
    case liveWeb
    case generalKnowledge

    public var displayName: String {
        switch self {
        case .liveWeb: "Live web comparison"
        case .generalKnowledge: "General category knowledge"
        }
    }
}

public enum LiveTeamFocusGroupChoice: String, Codable, CaseIterable, Equatable, Sendable {
    case currentProduct
    case comparison
    case neither

    public var displayName: String {
        switch self {
        case .currentProduct: "Current product"
        case .comparison: "Comparison"
        case .neither: "Neither"
        }
    }
}

public struct LiveTeamFocusGroupSource: Codable, Equatable, Sendable {
    public let title: String
    public let url: String
    public let publishedAt: String?
    public let relevance: String

    public init(
        title: String,
        url: String,
        publishedAt: String? = nil,
        relevance: String
    ) {
        self.title = title
        self.url = url
        self.publishedAt = publishedAt
        self.relevance = relevance
    }
}

public struct LiveTeamFocusGroupParticipant: Codable, Equatable, Sendable {
    public let archetype: String
    public let expectation: String
    public let choice: LiveTeamFocusGroupChoice
    public let reaction: String

    public init(
        archetype: String,
        expectation: String,
        choice: LiveTeamFocusGroupChoice,
        reaction: String
    ) {
        self.archetype = archetype
        self.expectation = expectation
        self.choice = choice
        self.reaction = reaction
    }
}

public struct LiveTeamFocusGroupReport: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let subject: String
    public let question: String
    public let audience: String
    public let comparison: String
    public let comparisonReason: String
    public let researchBasis: LiveTeamFocusGroupResearchBasis
    public let sources: [LiveTeamFocusGroupSource]
    public let participants: [LiveTeamFocusGroupParticipant]
    public let findings: [String]
    public let verdict: String
    public let nextExperiment: String
    public var limitations: String
    public var documentPath: String?
    public var failure: String?
    public let tokenUsage: RunTokenUsage?
    public let completedAt: Date

    public init(
        id: UUID = UUID(),
        subject: String,
        question: String,
        audience: String,
        comparison: String,
        comparisonReason: String,
        researchBasis: LiveTeamFocusGroupResearchBasis,
        sources: [LiveTeamFocusGroupSource],
        participants: [LiveTeamFocusGroupParticipant],
        findings: [String],
        verdict: String,
        nextExperiment: String,
        limitations: String,
        documentPath: String? = nil,
        failure: String? = nil,
        tokenUsage: RunTokenUsage? = nil,
        completedAt: Date = .now
    ) {
        self.id = id
        self.subject = subject
        self.question = question
        self.audience = audience
        self.comparison = comparison
        self.comparisonReason = comparisonReason
        self.researchBasis = researchBasis
        self.sources = sources
        self.participants = participants
        self.findings = findings
        self.verdict = verdict
        self.nextExperiment = nextExperiment
        self.limitations = limitations
        self.documentPath = documentPath
        self.failure = failure
        self.tokenUsage = tokenUsage
        self.completedAt = completedAt
    }

    public var isAvailable: Bool { failure == nil }
}

public struct LiveTeamManagerConsultation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let mandate: String
    public var status: LiveTeamManagerConsultationStatus
    public var involvement: String?
    public var progress: String?
    public var evidence: String?
    public var concern: String?
    public var nextMove: String?
    public var failure: String?
    public var tokenUsage: RunTokenUsage?

    public init(
        id: UUID = UUID(),
        name: String,
        mandate: String,
        status: LiveTeamManagerConsultationStatus = .waiting,
        involvement: String? = nil,
        progress: String? = nil,
        evidence: String? = nil,
        concern: String? = nil,
        nextMove: String? = nil,
        failure: String? = nil,
        tokenUsage: RunTokenUsage? = nil
    ) {
        self.id = id
        self.name = name
        self.mandate = mandate
        self.status = status
        self.involvement = involvement
        self.progress = progress
        self.evidence = evidence
        self.concern = concern
        self.nextMove = nextMove
        self.failure = failure
        self.tokenUsage = tokenUsage
    }
}

public enum LiveTeamReviewOutcome: String, Codable, Equatable, Sendable {
    case kept
    case revised
    case completed
    case continueWork
    case rejectedPause
    case failed

    public var displayName: String {
        switch self {
        case .kept: "Product bet renewed"
        case .revised: "New product bet funded"
        case .completed: "Goal confirmed complete"
        case .continueWork: "More work found"
        case .rejectedPause: "Autonomous pause rejected"
        case .failed: "Review interrupted"
        }
    }
}

public struct LiveTeamReviewDecision: Codable, Equatable, Sendable {
    public let outcome: LiveTeamReviewOutcome
    public let summary: String
    public let reason: String
    public let evidence: String

    public init(
        outcome: LiveTeamReviewOutcome,
        summary: String,
        reason: String,
        evidence: String
    ) {
        self.outcome = outcome
        self.summary = summary
        self.reason = reason
        self.evidence = evidence
    }
}

public struct LiveTeamReviewRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let mode: LiveTeamOverseerMode
    public let trigger: String
    public let sourceRunID: UUID?
    public let baseRevision: Int
    public let startedAt: Date
    public var status: LiveTeamReviewStatus
    public var focusGroup: LiveTeamFocusGroupReport?
    public var consultations: [LiveTeamManagerConsultation]
    public var decision: LiveTeamReviewDecision?
    public var resultingRevision: Int?
    public var resultingDefinition: LiveTeamDefinition?
    public var completedAt: Date?
    public var controlTokenUsage: RunTokenUsage?

    public init(
        id: UUID = UUID(),
        mode: LiveTeamOverseerMode,
        trigger: String,
        sourceRunID: UUID?,
        baseRevision: Int,
        startedAt: Date = .now,
        status: LiveTeamReviewStatus = .researchingFocusGroup,
        focusGroup: LiveTeamFocusGroupReport? = nil,
        consultations: [LiveTeamManagerConsultation] = [],
        decision: LiveTeamReviewDecision? = nil,
        resultingRevision: Int? = nil,
        resultingDefinition: LiveTeamDefinition? = nil,
        completedAt: Date? = nil,
        controlTokenUsage: RunTokenUsage? = nil
    ) {
        self.id = id
        self.mode = mode
        self.trigger = trigger
        self.sourceRunID = sourceRunID
        self.baseRevision = max(baseRevision, 1)
        self.startedAt = startedAt
        self.status = status
        self.focusGroup = focusGroup
        self.consultations = consultations
        self.decision = decision
        self.resultingRevision = resultingRevision
        self.resultingDefinition = resultingDefinition
        self.completedAt = completedAt
        self.controlTokenUsage = controlTokenUsage
    }

    public var completedConsultationCount: Int {
        consultations.count {
            $0.status == .completed || $0.status == .unavailable
        }
    }
}

public enum LiveTeamReviewProgress: Sendable, Equatable {
    case focusGroupCompleted(LiveTeamFocusGroupReport)
    case personasSelected([LiveTeamManagerConsultation])
    case consultationCompleted(index: Int, consultation: LiveTeamManagerConsultation)
    case overseerDeciding
}

public typealias LiveTeamReviewProgressHandler = @Sendable (
    LiveTeamReviewProgress
) async -> Void

public enum LiveTeamProgressEvidence: String, Codable, CaseIterable, Sendable {
    case none
    case repositoryChange
    case acceptedValidation
    case resolvedBlocker
    case boardAcknowledgment

    public var isDurable: Bool { self != .none }
}

public enum LiveTeamCoordinatorDisposition: String, Codable, CaseIterable, Sendable {
    case continueTeam
    case retryCurrent
    case pause
    case requestOversight
    case completionCandidate

    public var displayName: String {
        switch self {
        case .continueTeam: "Continue"
        case .retryCurrent: "Retry current agent"
        case .pause: "Request strategy review"
        case .requestOversight: "Review strategy"
        case .completionCandidate: "Suggest goal complete"
        }
    }
}

public struct LiveTeamCoordinatorDecision: Codable, Equatable, Sendable {
    public var handoff: String
    public var runLabel: String
    public var disposition: LiveTeamCoordinatorDisposition
    public var evidence: String
    public var progressEvidence: LiveTeamProgressEvidence
    public var tokenUsage: RunTokenUsage?

    public init(
        handoff: String,
        runLabel: String,
        disposition: LiveTeamCoordinatorDisposition,
        evidence: String,
        progressEvidence: LiveTeamProgressEvidence = .none,
        tokenUsage: RunTokenUsage? = nil
    ) {
        self.handoff = handoff
        self.runLabel = runLabel
        self.disposition = disposition
        self.evidence = evidence
        self.progressEvidence = progressEvidence
        self.tokenUsage = tokenUsage
    }
}

public struct LiveTeamMemberSnapshot: Codable, Equatable, Sendable {
    public let member: LiveTeamMember
    public let workingGoal: String
    public let revision: Int
    public let cycle: Int
    public let sessionSlotID: String
    public let productBet: CompanyProductBet?

    public init(
        member: LiveTeamMember,
        workingGoal: String,
        revision: Int,
        cycle: Int,
        sessionSlotID: String,
        productBet: CompanyProductBet? = nil
    ) {
        self.member = member
        self.workingGoal = workingGoal
        self.revision = revision
        self.cycle = max(cycle, 1)
        self.sessionSlotID = sessionSlotID
        self.productBet = productBet
    }
}

public struct LiveTeamState: Codable, Equatable, Sendable {
    public var overseer: LiveTeamOverseerConfiguration
    public var currentDefinition: LiveTeamDefinition?
    public var pendingRevision: LiveTeamPendingRevision?
    public var checkpoint: LiveTeamCheckpoint?
    public var resumeCheckpoint: LiveTeamResumeCheckpoint?
    public var completedOnceMemberIDs: Set<String>
    public var coordinatorHandoff: String?
    public var lastCoordinatorDecision: LiveTeamCoordinatorDecision?
    public var editHistory: [LiveTeamEditRecord]
    public var reviews: [LiveTeamReviewRecord]
    public var workerTurnsSinceStrategicReview: Int
    public var cyclesSinceStrategicReview: Int
    public var lastStrategicReviewAt: Date?
    public var cyclesUnderCurrentRevision: Int
    public var localRetryMemberID: String?
    public var localRetryCount: Int
    public var memberFailureCounts: [String: Int]
    public var boardGoalAmendmentPendingReview: Bool
    public var strategicReviewAfterBoundary: LiveTeamOverseerRequest?
    public var boardDirectionReason: String?
    public var definitionHistory: [LiveTeamDefinition]

    public init(
        overseer: LiveTeamOverseerConfiguration,
        currentDefinition: LiveTeamDefinition? = nil,
        pendingRevision: LiveTeamPendingRevision? = nil,
        checkpoint: LiveTeamCheckpoint? = nil,
        resumeCheckpoint: LiveTeamResumeCheckpoint? = nil,
        completedOnceMemberIDs: Set<String> = [],
        coordinatorHandoff: String? = nil,
        lastCoordinatorDecision: LiveTeamCoordinatorDecision? = nil,
        editHistory: [LiveTeamEditRecord] = [],
        reviews: [LiveTeamReviewRecord] = [],
        workerTurnsSinceStrategicReview: Int = 0,
        cyclesSinceStrategicReview: Int = 0,
        lastStrategicReviewAt: Date? = nil,
        cyclesUnderCurrentRevision: Int = 0,
        localRetryMemberID: String? = nil,
        localRetryCount: Int = 0,
        memberFailureCounts: [String: Int] = [:],
        boardGoalAmendmentPendingReview: Bool = false,
        strategicReviewAfterBoundary: LiveTeamOverseerRequest? = nil,
        boardDirectionReason: String? = nil,
        definitionHistory: [LiveTeamDefinition] = []
    ) {
        self.overseer = overseer
        self.currentDefinition = currentDefinition
        self.pendingRevision = pendingRevision
        self.checkpoint = checkpoint
        self.resumeCheckpoint = resumeCheckpoint
        self.completedOnceMemberIDs = completedOnceMemberIDs
        self.coordinatorHandoff = coordinatorHandoff
        self.lastCoordinatorDecision = lastCoordinatorDecision
        self.editHistory = editHistory
        self.reviews = reviews
        self.workerTurnsSinceStrategicReview = max(workerTurnsSinceStrategicReview, 0)
        self.cyclesSinceStrategicReview = max(cyclesSinceStrategicReview, 0)
        self.lastStrategicReviewAt = lastStrategicReviewAt
        self.cyclesUnderCurrentRevision = max(cyclesUnderCurrentRevision, 0)
        self.localRetryMemberID = localRetryMemberID
        self.localRetryCount = max(localRetryCount, 0)
        self.memberFailureCounts = memberFailureCounts
        self.boardGoalAmendmentPendingReview = boardGoalAmendmentPendingReview
        self.strategicReviewAfterBoundary = strategicReviewAfterBoundary
        self.boardDirectionReason = boardDirectionReason
        self.definitionHistory = definitionHistory
    }

    private enum CodingKeys: String, CodingKey {
        case overseer
        case currentDefinition
        case pendingRevision
        case checkpoint
        case resumeCheckpoint
        case completedOnceMemberIDs
        case coordinatorHandoff
        case lastCoordinatorDecision
        case editHistory
        case reviews
        case workerTurnsSinceStrategicReview
        case cyclesSinceStrategicReview
        case lastStrategicReviewAt
        case cyclesUnderCurrentRevision
        case localRetryMemberID
        case localRetryCount
        case memberFailureCounts
        case boardGoalAmendmentPendingReview
        case strategicReviewAfterBoundary
        case boardDirectionReason
        case definitionHistory
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            overseer: try container.decode(
                LiveTeamOverseerConfiguration.self,
                forKey: .overseer
            ),
            currentDefinition: try container.decodeIfPresent(
                LiveTeamDefinition.self,
                forKey: .currentDefinition
            ),
            pendingRevision: try container.decodeIfPresent(
                LiveTeamPendingRevision.self,
                forKey: .pendingRevision
            ),
            checkpoint: try container.decodeIfPresent(
                LiveTeamCheckpoint.self,
                forKey: .checkpoint
            ),
            resumeCheckpoint: try container.decodeIfPresent(
                LiveTeamResumeCheckpoint.self,
                forKey: .resumeCheckpoint
            ),
            completedOnceMemberIDs: try container.decodeIfPresent(
                Set<String>.self,
                forKey: .completedOnceMemberIDs
            ) ?? [],
            coordinatorHandoff: try container.decodeIfPresent(
                String.self,
                forKey: .coordinatorHandoff
            ),
            lastCoordinatorDecision: try container.decodeIfPresent(
                LiveTeamCoordinatorDecision.self,
                forKey: .lastCoordinatorDecision
            ),
            editHistory: try container.decodeIfPresent(
                [LiveTeamEditRecord].self,
                forKey: .editHistory
            ) ?? [],
            reviews: try container.decodeIfPresent(
                [LiveTeamReviewRecord].self,
                forKey: .reviews
            ) ?? [],
            workerTurnsSinceStrategicReview: try container.decodeIfPresent(
                Int.self,
                forKey: .workerTurnsSinceStrategicReview
            ) ?? 0,
            cyclesSinceStrategicReview: try container.decodeIfPresent(
                Int.self,
                forKey: .cyclesSinceStrategicReview
            ) ?? 0,
            lastStrategicReviewAt: try container.decodeIfPresent(
                Date.self,
                forKey: .lastStrategicReviewAt
            ),
            cyclesUnderCurrentRevision: try container.decodeIfPresent(
                Int.self,
                forKey: .cyclesUnderCurrentRevision
            ) ?? 0,
            localRetryMemberID: try container.decodeIfPresent(
                String.self,
                forKey: .localRetryMemberID
            ),
            localRetryCount: try container.decodeIfPresent(
                Int.self,
                forKey: .localRetryCount
            ) ?? 0,
            memberFailureCounts: try container.decodeIfPresent(
                [String: Int].self,
                forKey: .memberFailureCounts
            ) ?? [:],
            boardGoalAmendmentPendingReview: try container.decodeIfPresent(
                Bool.self,
                forKey: .boardGoalAmendmentPendingReview
            ) ?? false,
            strategicReviewAfterBoundary: try container.decodeIfPresent(
                LiveTeamOverseerRequest.self,
                forKey: .strategicReviewAfterBoundary
            ),
            boardDirectionReason: try container.decodeIfPresent(
                String.self,
                forKey: .boardDirectionReason
            ),
            definitionHistory: try container.decodeIfPresent(
                [LiveTeamDefinition].self,
                forKey: .definitionHistory
            ) ?? []
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(overseer, forKey: .overseer)
        try container.encodeIfPresent(currentDefinition, forKey: .currentDefinition)
        try container.encodeIfPresent(pendingRevision, forKey: .pendingRevision)
        try container.encodeIfPresent(checkpoint, forKey: .checkpoint)
        try container.encodeIfPresent(resumeCheckpoint, forKey: .resumeCheckpoint)
        try container.encode(completedOnceMemberIDs, forKey: .completedOnceMemberIDs)
        try container.encodeIfPresent(coordinatorHandoff, forKey: .coordinatorHandoff)
        try container.encodeIfPresent(
            lastCoordinatorDecision,
            forKey: .lastCoordinatorDecision
        )
        try container.encode(editHistory, forKey: .editHistory)
        try container.encode(reviews, forKey: .reviews)
        try container.encode(
            workerTurnsSinceStrategicReview,
            forKey: .workerTurnsSinceStrategicReview
        )
        try container.encode(cyclesSinceStrategicReview, forKey: .cyclesSinceStrategicReview)
        try container.encodeIfPresent(
            lastStrategicReviewAt,
            forKey: .lastStrategicReviewAt
        )
        try container.encode(cyclesUnderCurrentRevision, forKey: .cyclesUnderCurrentRevision)
        try container.encodeIfPresent(localRetryMemberID, forKey: .localRetryMemberID)
        try container.encode(localRetryCount, forKey: .localRetryCount)
        try container.encode(memberFailureCounts, forKey: .memberFailureCounts)
        try container.encode(
            boardGoalAmendmentPendingReview,
            forKey: .boardGoalAmendmentPendingReview
        )
        try container.encodeIfPresent(
            strategicReviewAfterBoundary,
            forKey: .strategicReviewAfterBoundary
        )
        try container.encodeIfPresent(
            boardDirectionReason,
            forKey: .boardDirectionReason
        )
        try container.encode(definitionHistory, forKey: .definitionHistory)
    }
}

public struct LiveTeamTargetOption: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let target: AgentTarget

    public init(id: String, label: String, target: AgentTarget) {
        self.id = id
        self.label = label
        self.target = target
    }
}

public struct LiveTeamOversightPolicy: Sendable, Equatable {
    public var repeatedFailureThreshold: Int

    public init(
        repeatedFailureThreshold: Int = 2
    ) {
        self.repeatedFailureThreshold = max(repeatedFailureThreshold, 1)
    }
}

public struct LiveTeamRuntimeConfiguration: Sendable, Equatable {
    public var overseer: LiveTeamOverseerConfiguration
    public var defaultCoordinator: LiveTeamCoordinatorConfiguration
    public var targetOptions: [LiveTeamTargetOption]
    public var oversightPolicy: LiveTeamOversightPolicy

    public init(
        overseer: LiveTeamOverseerConfiguration,
        defaultCoordinator: LiveTeamCoordinatorConfiguration,
        targetOptions: [LiveTeamTargetOption],
        oversightPolicy: LiveTeamOversightPolicy = .init()
    ) {
        self.overseer = overseer
        self.defaultCoordinator = defaultCoordinator
        self.targetOptions = targetOptions
        self.oversightPolicy = oversightPolicy
    }

    public var validationMessage: String? {
        if let message = overseer.validationMessage {
            return message
        }
        if let message = defaultCoordinator.validationMessage {
            return message
        }
        if targetOptions.isEmpty {
            return "Codeness has no available agent targets."
        }
        let cleanIDs = targetOptions.map {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleanIDs.contains(where: \.isEmpty) {
            return "An available agent target has no identifier."
        }
        if Set(cleanIDs).count != cleanIDs.count {
            return "Available agent target identifiers must be unique."
        }
        if let message = targetOptions.compactMap(\.target.validationMessage).first {
            return message
        }
        return nil
    }

    /// Selects the target for the first Overseer call before any agent has had
    /// an opportunity to interpret the Board goal. An unambiguous, non-negated
    /// provider or model identifier in the goal wins; otherwise the configured
    /// ready target remains the fallback.
    public func bootstrapOverseerConfiguration(
        for userGoal: String
    ) -> LiveTeamOverseerConfiguration {
        let goal = userGoal.lowercased()
        let modelIDs = Set(targetOptions.map { $0.target.model.lowercased() })
            .filter { $0.count >= 5 && $0 != "default" }
        let providerIDs = Set(targetOptions.map {
            $0.target.providerID.rawValue.lowercased()
        })
        let rawMentionedModels = modelIDs.filter {
            Self.hasNonNegatedMention(of: $0, in: goal)
        }
        let mentionedModels = rawMentionedModels.filter { candidate in
            !rawMentionedModels.contains(where: {
                $0 != candidate && $0.contains(candidate)
            })
        }
        let mentionedProviders = providerIDs.filter {
            Self.hasNonNegatedMention(of: $0, in: goal)
        }

        var candidates = targetOptions
        if mentionedModels.count == 1, let modelID = mentionedModels.first {
            candidates = candidates.filter { $0.target.model.lowercased() == modelID }
        }
        if mentionedProviders.count == 1, let providerID = mentionedProviders.first {
            let providerCandidates = candidates.filter {
                $0.target.providerID.rawValue.lowercased() == providerID
            }
            if !providerCandidates.isEmpty {
                candidates = providerCandidates
            }
        }
        guard mentionedModels.count == 1 || mentionedProviders.count == 1,
              let selected = candidates.first(where: {
                  $0.target.options.mode == .standard
                      && $0.target.options.speed == .standard
              }) ?? candidates.first else {
            return overseer
        }

        var selectedOverseer = overseer
        selectedOverseer.target = selected.target
        return selectedOverseer
    }

    private static func hasNonNegatedMention(of token: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: token, range: searchStart..<text.endIndex) {
            let clauseStart = text[..<range.lowerBound].lastIndex(where: {
                ".;\n".contains($0)
            }).map { text.index(after: $0) } ?? text.startIndex
            let prefix = text[clauseStart..<range.lowerBound]
            let negations = [
                "do not ", "don't ", "not ", "never ",
                "avoid ", "exclude ", "excluding "
            ]
            if !negations.contains(where: { prefix.contains($0) }) {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }
}

public enum LiveTeamStrategicAction: String, Codable, CaseIterable, Sendable {
    case keep
    case revise
    case pause
    case complete
}

public struct LiveTeamStrategicDecision: Codable, Equatable, Sendable {
    public var action: LiveTeamStrategicAction
    public var reason: String
    public var evidence: String
    public var proposedDefinition: LiveTeamDefinition?
    public var preferredNextMemberID: String?
    public var tokenUsage: RunTokenUsage?

    public init(
        action: LiveTeamStrategicAction,
        reason: String,
        evidence: String,
        proposedDefinition: LiveTeamDefinition? = nil,
        preferredNextMemberID: String? = nil,
        tokenUsage: RunTokenUsage? = nil
    ) {
        self.action = action
        self.reason = reason
        self.evidence = evidence
        self.proposedDefinition = proposedDefinition
        self.preferredNextMemberID = preferredNextMemberID
        self.tokenUsage = tokenUsage
    }
}

public enum LiveTeamCompletionOutcome: String, Codable, CaseIterable, Sendable {
    case complete
    case continueWork
    case pause
}

public struct LiveTeamCompletionDecision: Codable, Equatable, Sendable {
    public var outcome: LiveTeamCompletionOutcome
    public var evidence: String
    public var reason: String
    public var tokenUsage: RunTokenUsage?

    public init(
        outcome: LiveTeamCompletionOutcome,
        evidence: String,
        reason: String,
        tokenUsage: RunTokenUsage? = nil
    ) {
        self.outcome = outcome
        self.evidence = evidence
        self.reason = reason
        self.tokenUsage = tokenUsage
    }
}

public enum LiveTeamRevisionError: LocalizedError, Equatable, Sendable {
    case noCurrentDefinition
    case stale(base: Int, current: Int)
    case invalid(String)
    case pendingBoardRevision
    case pendingRevisionRequiresDecision

    public var errorDescription: String? {
        switch self {
        case .noCurrentDefinition:
            "Codeness has not prepared the agents yet."
        case .stale:
            "The agents changed while you were editing. Reopen the editor and try again."
        case .invalid(let detail):
            detail
        case .pendingBoardRevision:
            "Automatic agent changes cannot replace your pending changes."
        case .pendingRevisionRequiresDecision:
            "Review or discard the pending agent changes before saving another change."
        }
    }
}
