import Foundation

public struct LiveTeamEvidenceItem: Sendable, Equatable {
    public let sequence: Int
    public let memberName: String
    public let status: RunStatus
    public let result: String
    public let coordinatorEvidence: String

    public init(
        sequence: Int,
        memberName: String,
        status: RunStatus,
        result: String,
        coordinatorEvidence: String
    ) {
        self.sequence = sequence
        self.memberName = memberName
        self.status = status
        self.result = result
        self.coordinatorEvidence = coordinatorEvidence
    }
}

public struct LiveTeamCoordinatorContext: Sendable, Equatable {
    public let workingGoal: String
    public let definition: LiveTeamDefinition
    public let sourceMember: LiveTeamMemberSnapshot
    public let proposedNextMember: LiveTeamMember?
    public let previousHandoff: String?
    public let recentDecisions: [LiveTeamCoordinatorDecision]
    public let sourceResult: String

    public init(
        workingGoal: String,
        definition: LiveTeamDefinition,
        sourceMember: LiveTeamMemberSnapshot,
        proposedNextMember: LiveTeamMember?,
        previousHandoff: String?,
        recentDecisions: [LiveTeamCoordinatorDecision],
        sourceResult: String
    ) {
        self.workingGoal = workingGoal
        self.definition = definition
        self.sourceMember = sourceMember
        self.proposedNextMember = proposedNextMember
        self.previousHandoff = previousHandoff
        self.recentDecisions = recentDecisions
        self.sourceResult = sourceResult
    }
}

public struct LiveTeamOverseerContext: Sendable, Equatable {
    public let userGoal: String
    public let currentDefinition: LiveTeamDefinition?
    public let coordinatorHandoff: String?
    public let recentEvidence: [LiveTeamEvidenceItem]
    public let editHistory: [LiveTeamEditRecord]
    public let targetOptions: [LiveTeamTargetOption]
    public let triggerReason: String
    public let legacyWorkflow: WorkflowTemplate?
    public let legacyCursor: WorkflowCursor?
    public let legacySessions: [String: WorkflowSessionState]

    public init(
        userGoal: String,
        currentDefinition: LiveTeamDefinition?,
        coordinatorHandoff: String?,
        recentEvidence: [LiveTeamEvidenceItem],
        editHistory: [LiveTeamEditRecord],
        targetOptions: [LiveTeamTargetOption],
        triggerReason: String,
        legacyWorkflow: WorkflowTemplate? = nil,
        legacyCursor: WorkflowCursor? = nil,
        legacySessions: [String: WorkflowSessionState] = [:]
    ) {
        self.userGoal = userGoal
        self.currentDefinition = currentDefinition
        self.coordinatorHandoff = coordinatorHandoff
        self.recentEvidence = recentEvidence
        self.editHistory = editHistory
        self.targetOptions = targetOptions
        self.triggerReason = triggerReason
        self.legacyWorkflow = legacyWorkflow
        self.legacyCursor = legacyCursor
        self.legacySessions = legacySessions
    }
}

public protocol LiveTeamCoordinatorRouting: Sendable {
    func coordinate(
        _ context: LiveTeamCoordinatorContext,
        configuration: LiveTeamCoordinatorConfiguration,
        cwd: String
    ) async throws -> LiveTeamCoordinatorDecision

    func summarizeWork(
        _ context: WorkSummaryContext,
        configuration: LiveTeamCoordinatorConfiguration,
        cwd: String
    ) async throws -> String
}

public extension LiveTeamCoordinatorRouting {
    func summarizeWork(
        _ context: WorkSummaryContext,
        configuration: LiveTeamCoordinatorConfiguration,
        cwd: String
    ) async throws -> String {
        _ = context
        _ = configuration
        _ = cwd
        throw HandoffRouterError.workSummaryUnsupported
    }
}

public protocol LiveTeamOverseerRouting: Sendable {
    func bootstrap(
        _ context: LiveTeamOverseerContext,
        configuration: LiveTeamOverseerConfiguration,
        defaultCoordinator: LiveTeamCoordinatorConfiguration,
        cwd: String
    ) async throws -> LiveTeamDefinition

    func reviewStrategy(
        _ context: LiveTeamOverseerContext,
        configuration: LiveTeamOverseerConfiguration,
        cwd: String
    ) async throws -> LiveTeamStrategicDecision

    func reviewCompletion(
        _ context: LiveTeamOverseerContext,
        configuration: LiveTeamOverseerConfiguration,
        cwd: String
    ) async throws -> LiveTeamCompletionDecision

    func migrate(
        _ context: LiveTeamOverseerContext,
        configuration: LiveTeamOverseerConfiguration,
        defaultCoordinator: LiveTeamCoordinatorConfiguration,
        cwd: String
    ) async throws -> LiveTeamDefinition
}

public actor AgentLiveTeamRouter: LiveTeamCoordinatorRouting, LiveTeamOverseerRouting {
    private static let maximumGoalCharacters = 24_000
    private static let maximumResultCharacters = 8_000
    private static let maximumEvidenceItems = 12
    private static let maximumEditItems = 12

    private let providers: AgentProviderRegistry

    public init(providers: AgentProviderRegistry) {
        self.providers = providers
    }

    public func coordinate(
        _ context: LiveTeamCoordinatorContext,
        configuration: LiveTeamCoordinatorConfiguration,
        cwd: String
    ) async throws -> LiveTeamCoordinatorDecision {
        let request = AgentUtilityRequest(
            cwd: cwd,
            prompt: Self.coordinatorPrompt(context, policy: configuration.instructions),
            target: configuration.target,
            developerInstructions: Self.coordinatorDeveloperInstructions,
            outputSchema: Self.coordinatorSchema
        )
        let result = try await providers.runUtility(request)
        return try Self.decodeCoordinatorDecision(result.output)
    }

    public func summarizeWork(
        _ context: WorkSummaryContext,
        configuration: LiveTeamCoordinatorConfiguration,
        cwd: String
    ) async throws -> String {
        let request = AgentUtilityRequest(
            cwd: cwd,
            prompt: WorkSummaryPrompt.utilityPrompt(
                context,
                coordinatorInstructions: configuration.instructions
            ),
            target: configuration.target,
            developerInstructions: configuration.instructions,
            outputSchema: WorkSummaryPrompt.outputSchema
        )
        let result = try await providers.runUtility(request)
        return try WorkSummaryPrompt.decodeUtilityOutput(result.output)
    }

    public func bootstrap(
        _ context: LiveTeamOverseerContext,
        configuration: LiveTeamOverseerConfiguration,
        defaultCoordinator: LiveTeamCoordinatorConfiguration,
        cwd: String
    ) async throws -> LiveTeamDefinition {
        let request = AgentUtilityRequest(
            cwd: cwd,
            prompt: Self.overseerPrompt(context, mode: .bootstrap),
            target: configuration.target,
            developerInstructions: Self.overseerDeveloperInstructions(
                policy: configuration.instructions
            ),
            outputSchema: Self.definitionSchema(targetOptions: context.targetOptions)
        )
        let result = try await providers.runUtility(request)
        return try Self.decodeDefinition(
            result.output,
            revision: 1,
            targetOptions: context.targetOptions,
            defaultCoordinator: defaultCoordinator
        )
    }

    public func reviewStrategy(
        _ context: LiveTeamOverseerContext,
        configuration: LiveTeamOverseerConfiguration,
        cwd: String
    ) async throws -> LiveTeamStrategicDecision {
        guard let current = context.currentDefinition else {
            throw AgentProviderError.invalidResponse(
                "strategic review requires a current live-team definition"
            )
        }
        let request = AgentUtilityRequest(
            cwd: cwd,
            prompt: Self.overseerPrompt(context, mode: .strategicReview),
            target: configuration.target,
            developerInstructions: Self.overseerDeveloperInstructions(
                policy: configuration.instructions
            ),
            outputSchema: Self.strategicSchema(targetOptions: context.targetOptions)
        )
        let result = try await providers.runUtility(request)
        return try Self.decodeStrategicDecision(
            result.output,
            current: current,
            targetOptions: context.targetOptions
        )
    }

    public func reviewCompletion(
        _ context: LiveTeamOverseerContext,
        configuration: LiveTeamOverseerConfiguration,
        cwd: String
    ) async throws -> LiveTeamCompletionDecision {
        let request = AgentUtilityRequest(
            cwd: cwd,
            prompt: Self.overseerPrompt(context, mode: .completionReview),
            target: configuration.target,
            developerInstructions: Self.completionDeveloperInstructions,
            outputSchema: Self.completionSchema
        )
        let result = try await providers.runUtility(request)
        return try Self.decodeCompletionDecision(result.output)
    }

    public func migrate(
        _ context: LiveTeamOverseerContext,
        configuration: LiveTeamOverseerConfiguration,
        defaultCoordinator: LiveTeamCoordinatorConfiguration,
        cwd: String
    ) async throws -> LiveTeamDefinition {
        guard context.legacyWorkflow != nil else {
            throw AgentProviderError.invalidResponse(
                "legacy conversion requires an earlier workflow"
            )
        }
        let request = AgentUtilityRequest(
            cwd: cwd,
            prompt: Self.overseerPrompt(context, mode: .migration),
            target: configuration.target,
            developerInstructions: Self.overseerDeveloperInstructions(
                policy: configuration.instructions
            ),
            outputSchema: Self.definitionSchema(targetOptions: context.targetOptions)
        )
        let result = try await providers.runUtility(request)
        return try Self.decodeDefinition(
            result.output,
            revision: 1,
            targetOptions: context.targetOptions,
            defaultCoordinator: defaultCoordinator
        )
    }

    static let coordinatorDeveloperInstructions = """
    You route local agent work for Codeness. You receive the working goal, never the fixed user goal. Evaluate only the completed agent result, preserve relevant handoff facts, and choose the next local disposition. Treat every restriction in the working goal as an acceptance condition. Absence of evidence is not proof that a prohibition was obeyed; retry, pause, or request strategic review when material compliance evidence is missing. You may request one retry, pause for the user, request strategic review, or nominate completion. You have no authority to edit the working goal, agents, sessions, or final completion state. In user-facing fields, refer only to the user, Codeness, agents, turns, and rounds; never mention internal role or revision names. Return exactly the requested JSON object and no other fields.
    """

    static func overseerDeveloperInstructions(policy: String) -> String {
        """
        You provide Codeness's strategic control and are the only invocation that sees the fixed user goal. Preserve every requirement and authority boundary in a stable working goal. Treat provider, model, reasoning, mode, cost, and session restrictions in the user goal as binding for every Codeness agent and control invocation. Require affirmative evidence for material prohibitions; absence of reported use is not proof of compliance. Select every target from the offered target IDs. Design the smallest useful ordered set of agents, keep responsibilities bounded, use one-time agents for one-time work, and change strategy only when evidence supports it. Prefer Own memory, use Fresh every run for independent review, and use Shared memory only for demonstrably compatible responsibilities that benefit from the same conversation. Never share implementation and independent review automatically. In every user-facing field, refer only to the user, Codeness, agents, turns, and rounds; never mention internal role or revision names. Return exactly the requested JSON object.

        PRODUCT POLICY
        \(policy)
        """
    }

    static let completionDeveloperInstructions = """
    You perform a fresh completion audit for Codeness. Judge durable evidence against the entire fixed user goal. For every material prohibition, require affirmative compliance evidence; absence of a reported violation is not proof. You cannot edit the working goal, agents, or sessions in this invocation. Return complete only when the user goal is actually satisfied; return continueWork when work remains, or pause when the user's authority or judgment is required. In user-facing fields, refer only to the user, Codeness, agents, turns, and rounds; never mention internal role or revision names. Return exactly the requested JSON object.
    """

    static var coordinatorSchema: JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "handoff": .object(["type": .string("string"), "minLength": .integer(1)]),
                "runLabel": .object(["type": .string("string"), "minLength": .integer(1)]),
                "disposition": .object([
                    "type": .string("string"),
                    "enum": .array(LiveTeamCoordinatorDisposition.allCases.map {
                        .string($0.rawValue)
                    })
                ]),
                "evidence": .object(["type": .string("string")]),
                "progressEvidence": .object([
                    "type": .string("string"),
                    "enum": .array(LiveTeamProgressEvidence.allCases.map {
                        .string($0.rawValue)
                    })
                ])
            ]),
            "required": .array([
                .string("handoff"),
                .string("runLabel"),
                .string("disposition"),
                .string("evidence"),
                .string("progressEvidence")
            ])
        ])
    }

    static func definitionSchema(targetOptions: [LiveTeamTargetOption]) -> JSONValue {
        let targetIDs = targetOptions.map { JSONValue.string($0.id) }
        return .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "workingGoal": .object(["type": .string("string"), "minLength": .integer(1)]),
                "strategicReason": .object(["type": .string("string"), "minLength": .integer(1)]),
                "members": .object([
                    "type": .string("array"),
                    "minItems": .integer(1),
                    "items": memberSchema(targetIDs: targetIDs)
                ]),
                "coordinator": coordinatorConfigurationSchema(targetIDs: targetIDs),
                "overseerTargetID": .object([
                    "type": .string("string"),
                    "enum": .array(targetIDs)
                ])
            ]),
            "required": .array([
                .string("workingGoal"),
                .string("strategicReason"),
                .string("members"),
                .string("coordinator"),
                .string("overseerTargetID")
            ])
        ])
    }

    static func strategicSchema(targetOptions: [LiveTeamTargetOption]) -> JSONValue {
        let targetIDs = targetOptions.map { JSONValue.string($0.id) }
        return .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "enum": .array(LiveTeamStrategicAction.allCases.map {
                        .string($0.rawValue)
                    })
                ]),
                "reason": .object(["type": .string("string"), "minLength": .integer(1)]),
                "evidence": .object(["type": .string("string")]),
                "workingGoal": nullable(.object(["type": .string("string")])),
                "members": nullable(.object([
                    "type": .string("array"),
                    "items": memberSchema(targetIDs: targetIDs)
                ])),
                "coordinator": nullable(
                    coordinatorConfigurationSchema(targetIDs: targetIDs)
                ),
                "overseerTargetID": nullable(.object([
                    "type": .string("string"),
                    "enum": .array(targetIDs)
                ])),
                "preferredNextMemberID": .object(["type": .array([.string("string"), .string("null")])])
            ]),
            "required": .array([
                .string("action"),
                .string("reason"),
                .string("evidence"),
                .string("workingGoal"),
                .string("members"),
                .string("coordinator"),
                .string("overseerTargetID"),
                .string("preferredNextMemberID")
            ])
        ])
    }

    static var completionSchema: JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "outcome": .object([
                    "type": .string("string"),
                    "enum": .array(LiveTeamCompletionOutcome.allCases.map {
                        .string($0.rawValue)
                    })
                ]),
                "evidence": .object(["type": .string("string"), "minLength": .integer(1)]),
                "reason": .object(["type": .string("string"), "minLength": .integer(1)])
            ]),
            "required": .array([
                .string("outcome"),
                .string("evidence"),
                .string("reason")
            ])
        ])
    }

    private static func memberSchema(targetIDs: [JSONValue]) -> JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "id": .object(["type": .string("string"), "minLength": .integer(1)]),
                "name": .object(["type": .string("string"), "minLength": .integer(1)]),
                "instructions": .object(["type": .string("string"), "minLength": .integer(1)]),
                "targetID": .object(["type": .string("string"), "enum": .array(targetIDs)]),
                "runPolicy": .object([
                    "type": .string("string"),
                    "enum": .array(LiveTeamRunPolicy.allCases.map { .string($0.rawValue) })
                ]),
                "sessionPolicy": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string("ownMemory"),
                        .string("sharedMemory"),
                        .string("freshEveryRun")
                    ])
                ]),
                "sharedGroupID": .object(["type": .array([.string("string"), .string("null")])])
            ]),
            "required": .array([
                .string("id"),
                .string("name"),
                .string("instructions"),
                .string("targetID"),
                .string("runPolicy"),
                .string("sessionPolicy"),
                .string("sharedGroupID")
            ])
        ])
    }

    private static func nullable(_ schema: JSONValue) -> JSONValue {
        .object([
            "anyOf": .array([
                schema,
                .object(["type": .string("null")])
            ])
        ])
    }

    private static func coordinatorConfigurationSchema(targetIDs: [JSONValue]) -> JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "targetID": .object(["type": .string("string"), "enum": .array(targetIDs)]),
                "instructions": .object(["type": .string("string"), "minLength": .integer(1)])
            ]),
            "required": .array([.string("targetID"), .string("instructions")])
        ])
    }

    private static func coordinatorPrompt(
        _ context: LiveTeamCoordinatorContext,
        policy: String
    ) -> String {
        let agents = context.definition.members.enumerated().map { index, member in
            "\(index + 1). \(member.name) [\(member.runPolicy.displayName)] — \(member.instructions)"
        }.joined(separator: "\n")
        let recent = context.recentDecisions.suffix(4).map {
            "- \($0.runLabel): \($0.disposition.displayName) — \($0.handoff)"
        }.joined(separator: "\n")
        return """
        WORK-ROUTING POLICY
        \(policy)

        WORKING GOAL
        \(abbreviated(context.workingGoal, limit: maximumGoalCharacters))

        ACTIVE SETUP
        \(context.definition.revision)

        AGENTS
        \(agents)

        COMPLETED AGENT
        \(context.sourceMember.member.name) · round \(context.sourceMember.cycle) · launched under setup \(context.sourceMember.revision)

        PROPOSED NEXT AGENT
        \(context.proposedNextMember?.name ?? "No eligible agent")

        PREVIOUS HANDOFF
        \(context.previousHandoff ?? "None")

        RECENT LOCAL DECISIONS
        \(recent.isEmpty ? "None" : recent)

        SOURCE RESULT
        \(abbreviated(context.sourceResult, limit: maximumResultCharacters))

        Return only the structured routing decision. A completionCandidate is a nomination for a fresh independent completion review, never final completion. Keep every returned text field user-facing: use user, Codeness, agents, turns, and rounds; do not name internal roles or revisions.
        """
    }

    private static func overseerPrompt(
        _ context: LiveTeamOverseerContext,
        mode: LiveTeamOverseerMode
    ) -> String {
        let targets = context.targetOptions.map {
            "- \($0.id): \($0.label) [\($0.target.providerID.rawValue) / \($0.target.model) / \($0.target.options.mode.rawValue)]"
        }.joined(separator: "\n")
        let evidence = context.recentEvidence.suffix(maximumEvidenceItems).map {
            """
            - Run \($0.sequence), \($0.memberName), \($0.status.displayName)
              Result: \(abbreviated($0.result, limit: 1_500))
              Routing evidence: \(abbreviated($0.coordinatorEvidence, limit: 600))
            """
        }.joined(separator: "\n")
        let edits = context.editHistory.suffix(maximumEditItems).map {
            "- Setup \($0.revision), \($0.actor.displayName): \($0.summary) — \($0.reason)"
        }.joined(separator: "\n")
        let current = context.currentDefinition.map(definitionDescription) ?? "No working goal or agents exist yet."
        let legacy = context.legacyWorkflow.map { workflow in
            let cursor = context.legacyCursor.map {
                "\($0.section.rawValue) index \($0.stepIndex), loop \($0.loopIteration)"
            } ?? "none"
            let steps = workflow.steps.map { step in
                let session = context.legacySessions[step.id]
                return "- \(step.id): \(step.name) [\(step.section.rawValue)] target \(step.target.providerID.rawValue)/\(step.target.model), lineage \(session?.lineage ?? 1), session \(session?.providerSessionID == nil ? "none" : "established") — \(step.instructions)"
            }.joined(separator: "\n")
            return """
            LEGACY WORKFLOW
            \(workflow.name)
            Cursor: \(cursor)
            \(steps)
            """
        } ?? ""
        return """
        MODE
        \(mode.displayName)

        TRIGGER
        \(context.triggerReason)

        USER GOAL
        \(abbreviated(context.userGoal, limit: maximumGoalCharacters))

        CURRENT STRATEGY
        \(current)

        CURRENT HANDOFF
        \(context.coordinatorHandoff ?? "None")

        BOUNDED DURABLE EVIDENCE
        \(evidence.isEmpty ? "No agent turns yet." : evidence)

        STRATEGIC EDIT HISTORY
        \(edits.isEmpty ? "None" : edits)

        AVAILABLE TARGET IDS
        \(targets)

        \(legacy)

        \(modeInstruction(mode))
        """
    }

    private static func modeInstruction(_ mode: LiveTeamOverseerMode) -> String {
        switch mode {
        case .bootstrap:
            "Create the first setup: a stable working goal, your future target, the smallest useful set of agents, and a narrow work-routing policy. Obey every agent constraint in the user goal. Each responsibility must include a stopping condition."
        case .migration:
            "Replace the earlier workflow with the first coherent agent setup. Preserve an old agent ID only when its responsibility and execution identity remain compatible; do not imply that histories were merged."
        case .strategicReview:
            "Return keep when the current strategy is working. Return revise with one complete replacement definition only when concrete evidence justifies one strategic change. Return pause when the user must decide. For keep or pause, set workingGoal, members, coordinator, overseerTargetID, and preferredNextMemberID to null."
        case .completionReview:
            "Audit the fixed user goal against durable evidence. You cannot alter strategy in this response."
        }
    }

    private static func definitionDescription(_ definition: LiveTeamDefinition) -> String {
        let members = definition.members.enumerated().map { index, member in
            "\(index + 1). \(member.id): \(member.name) [\(member.runPolicy.displayName), \(member.sessionPolicy.displayName)] — \(member.instructions)"
        }.joined(separator: "\n")
        return """
        Setup \(definition.revision)
        Working goal: \(definition.workingGoal)
        Strategic reason: \(definition.strategicReason)
        Work routing: \(definition.coordinator.target.providerID.rawValue)/\(definition.coordinator.target.model) — \(definition.coordinator.instructions)
        Strategy reviews: \(definition.overseerTarget.providerID.rawValue)/\(definition.overseerTarget.model)
        Agents:
        \(members)
        """
    }

    static func decodeCoordinatorDecision(_ output: String) throws -> LiveTeamCoordinatorDecision {
        let object = try decodedObject(output, purpose: "routing decision")
        let allowed: Set<String> = [
            "handoff", "runLabel", "disposition", "evidence", "progressEvidence"
        ]
        guard Set(object.keys) == allowed,
              let handoff = cleanRequiredString(object["handoff"]),
              let label = cleanRequiredString(object["runLabel"]),
              let dispositionRaw = object["disposition"]?.stringValue,
              let disposition = LiveTeamCoordinatorDisposition(rawValue: dispositionRaw),
              let evidence = object["evidence"]?.stringValue,
              let progressRaw = object["progressEvidence"]?.stringValue,
              let progress = LiveTeamProgressEvidence(rawValue: progressRaw) else {
            throw AgentProviderError.invalidResponse(
                "work routing returned missing, extra, or invalid fields"
            )
        }
        return LiveTeamProductLanguage.coordinatorDecision(LiveTeamCoordinatorDecision(
            handoff: handoff,
            runLabel: String(label.prefix(100)),
            disposition: disposition,
            evidence: evidence,
            progressEvidence: progress
        ))
    }

    static func decodeDefinition(
        _ output: String,
        revision: Int,
        targetOptions: [LiveTeamTargetOption],
        defaultCoordinator: LiveTeamCoordinatorConfiguration
    ) throws -> LiveTeamDefinition {
        let value = try decodedValue(output, purpose: "agent setup")
        return try decodeDefinitionValue(
            value,
            revision: revision,
            targetOptions: targetOptions,
            defaultCoordinator: defaultCoordinator
        )
    }

    static func decodeStrategicDecision(
        _ output: String,
        current: LiveTeamDefinition,
        targetOptions: [LiveTeamTargetOption]
    ) throws -> LiveTeamStrategicDecision {
        let object = try decodedObject(output, purpose: "strategic decision")
        let allowed: Set<String> = [
            "action", "reason", "evidence", "workingGoal", "members",
            "coordinator", "overseerTargetID", "preferredNextMemberID"
        ]
        guard Set(object.keys) == allowed,
              let actionRaw = object["action"]?.stringValue,
              let action = LiveTeamStrategicAction(rawValue: actionRaw),
              let reason = cleanRequiredString(object["reason"]),
              let evidence = object["evidence"]?.stringValue else {
            throw AgentProviderError.invalidResponse(
                "the strategic review returned an invalid decision"
            )
        }
        let proposed: LiveTeamDefinition?
        let preferred: String?
        switch action {
        case .revise:
            preferred = object["preferredNextMemberID"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let definitionObject: JSONValue = .object([
                "workingGoal": object["workingGoal"] ?? .null,
                "strategicReason": .string(reason),
                "members": object["members"] ?? .null,
                "coordinator": object["coordinator"] ?? .null,
                "overseerTargetID": object["overseerTargetID"] ?? .null
            ])
            proposed = try decodeDefinitionValue(
                definitionObject,
                revision: current.revision + 1,
                targetOptions: targetOptions,
                defaultCoordinator: current.coordinator
            )
            if let preferred, proposed?.member(id: preferred) == nil {
                throw AgentProviderError.invalidResponse(
                    "the preferred next agent is not part of the proposed setup"
                )
            }
        case .keep, .pause:
            proposed = nil
            preferred = nil
        }
        return LiveTeamProductLanguage.strategicDecision(LiveTeamStrategicDecision(
            action: action,
            reason: reason,
            evidence: evidence,
            proposedDefinition: proposed,
            preferredNextMemberID: preferred
        ))
    }

    static func decodeCompletionDecision(_ output: String) throws -> LiveTeamCompletionDecision {
        let object = try decodedObject(output, purpose: "completion decision")
        let allowed: Set<String> = ["outcome", "evidence", "reason"]
        guard Set(object.keys) == allowed,
              let outcomeRaw = object["outcome"]?.stringValue,
              let outcome = LiveTeamCompletionOutcome(rawValue: outcomeRaw),
              let evidence = cleanRequiredString(object["evidence"]),
              let reason = cleanRequiredString(object["reason"]) else {
            throw AgentProviderError.invalidResponse(
                "the completion review returned missing, extra, or invalid fields"
            )
        }
        return LiveTeamProductLanguage.completionDecision(LiveTeamCompletionDecision(
            outcome: outcome,
            evidence: evidence,
            reason: reason
        ))
    }

    private static func decodeDefinitionValue(
        _ value: JSONValue,
        revision: Int,
        targetOptions: [LiveTeamTargetOption],
        defaultCoordinator: LiveTeamCoordinatorConfiguration
    ) throws -> LiveTeamDefinition {
        guard let object = value.objectValue else {
            throw AgentProviderError.invalidResponse("the agent setup is not an object")
        }
        let allowed: Set<String> = [
            "workingGoal", "strategicReason", "members", "coordinator",
            "overseerTargetID"
        ]
        guard Set(object.keys) == allowed,
              let workingGoal = cleanRequiredString(object["workingGoal"]),
              let reason = cleanRequiredString(object["strategicReason"]),
              let memberValues = object["members"]?.arrayValue,
              !memberValues.isEmpty,
              let coordinatorValue = object["coordinator"],
              let overseerTargetID = object["overseerTargetID"]?.stringValue else {
            throw AgentProviderError.invalidResponse(
                "the agent setup has missing or extra fields"
            )
        }
        let targetPairs = targetOptions.map { ($0.id, $0.target) }
        guard Set(targetPairs.map(\.0)).count == targetPairs.count else {
            throw AgentProviderError.invalidResponse(
                "available agent target identifiers are not unique"
            )
        }
        let targets = Dictionary(uniqueKeysWithValues: targetPairs)
        guard let overseerTarget = targets[overseerTargetID] else {
            throw AgentProviderError.invalidResponse(
                "the strategy-review target is invalid"
            )
        }
        let members = try memberValues.map { value -> LiveTeamMember in
            guard let member = value.objectValue else {
                throw AgentProviderError.invalidResponse("an agent is not an object")
            }
            let memberAllowed: Set<String> = [
                "id", "name", "instructions", "targetID", "runPolicy",
                "sessionPolicy", "sharedGroupID"
            ]
            guard Set(member.keys) == memberAllowed,
                  let id = cleanRequiredString(member["id"]),
                  let name = cleanRequiredString(member["name"]),
                  let instructions = cleanRequiredString(member["instructions"]),
                  let targetID = member["targetID"]?.stringValue,
                  let target = targets[targetID],
                  let runRaw = member["runPolicy"]?.stringValue,
                  let runPolicy = LiveTeamRunPolicy(rawValue: runRaw),
                  let sessionRaw = member["sessionPolicy"]?.stringValue else {
                throw AgentProviderError.invalidResponse(
                    "an agent has missing, extra, or invalid fields"
                )
            }
            let sessionPolicy: LiveTeamSessionPolicy
            switch sessionRaw {
            case "ownMemory":
                guard member["sharedGroupID"] == .null else {
                    throw AgentProviderError.invalidResponse(
                        "Own memory cannot name a shared group"
                    )
                }
                sessionPolicy = .ownMemory
            case "freshEveryRun":
                guard member["sharedGroupID"] == .null else {
                    throw AgentProviderError.invalidResponse(
                        "Fresh every turn cannot name a shared group"
                    )
                }
                sessionPolicy = .freshEveryRun
            case "sharedMemory":
                guard let groupID = cleanRequiredString(member["sharedGroupID"]) else {
                    throw AgentProviderError.invalidResponse(
                        "Shared memory requires a group identifier"
                    )
                }
                sessionPolicy = .sharedMemory(groupID: groupID)
            default:
                throw AgentProviderError.invalidResponse("unknown session policy")
            }
            return LiveTeamMember(
                id: id,
                name: name,
                instructions: instructions,
                target: target,
                runPolicy: runPolicy,
                sessionPolicy: sessionPolicy
            )
        }

        guard let coordinatorObject = coordinatorValue.objectValue,
              Set(coordinatorObject.keys) == ["targetID", "instructions"],
              let coordinatorTargetID = coordinatorObject["targetID"]?.stringValue,
              let coordinatorTarget = targets[coordinatorTargetID],
              let coordinatorInstructions = cleanRequiredString(
                coordinatorObject["instructions"]
              ) else {
            throw AgentProviderError.invalidResponse(
                "the work-routing configuration is invalid"
            )
        }
        let coordinator = LiveTeamCoordinatorConfiguration(
            target: coordinatorTarget,
            instructions: coordinatorInstructions
        )
        var definition = LiveTeamDefinition(
            revision: revision,
            workingGoal: workingGoal,
            members: members,
            coordinator: coordinator,
            overseerTarget: overseerTarget,
            strategicReason: reason
        )
        if targetOptions.isEmpty {
            definition.coordinator = defaultCoordinator
        }
        if let message = definition.validationMessage {
            throw AgentProviderError.invalidResponse(message)
        }
        return LiveTeamProductLanguage.definition(definition)
    }

    private static func decodedObject(
        _ output: String,
        purpose: String
    ) throws -> [String: JSONValue] {
        let value = try decodedValue(output, purpose: purpose)
        guard let object = value.objectValue else {
            throw AgentProviderError.invalidResponse("the \(purpose) is not a JSON object")
        }
        return object
    }

    private static func decodedValue(_ output: String, purpose: String) throws -> JSONValue {
        let clean = stripCodeFence(output)
        do {
            return try JSONDecoder().decode(JSONValue.self, from: Data(clean.utf8))
        } catch {
            throw AgentProviderError.invalidResponse(
                "the \(purpose) is not valid JSON: \(error.localizedDescription)"
            )
        }
    }

    private static func cleanRequiredString(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func stripCodeFence(_ output: String) -> String {
        let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("```"), clean.hasSuffix("```") else { return clean }
        var lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3 else { return clean }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
    }

    private static func abbreviated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let marker = "\n[… omitted …]\n"
        let retained = max(0, limit - marker.count)
        return String(text.prefix((retained + 1) / 2))
            + marker
            + String(text.suffix(retained / 2))
    }
}
