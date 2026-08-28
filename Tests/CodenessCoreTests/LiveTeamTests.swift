import Foundation
import Testing
@testable import CodenessCore

struct LiveTeamModelTests {
    @Test
    func schedulerUsesStableMemberIdentityAndSkipsCompletedOnceMembers() throws {
        let definition = liveTeamDefinition()
        let initial = try #require(
            LiveTeamStateMachine.initialCheckpoint(for: definition)
        )
        #expect(initial.memberID == "plan")
        #expect(initial.cycle == 1)

        let afterPlan = try #require(LiveTeamStateMachine.nextCheckpoint(
            after: "plan",
            cycle: 1,
            in: definition,
            completedOnceMemberIDs: ["plan"]
        ))
        #expect(afterPlan.memberID == "implement")
        #expect(afterPlan.cycle == 1)

        let afterReview = try #require(LiveTeamStateMachine.nextCheckpoint(
            after: "review",
            cycle: 1,
            in: definition,
            completedOnceMemberIDs: ["plan"]
        ))
        #expect(afterReview.memberID == "implement")
        #expect(afterReview.cycle == 2)

        var revised = definition
        revised.revision = 2
        revised.members.removeAll { $0.id == "review" }
        let reconciled = try #require(LiveTeamStateMachine.checkpoint(
            reconciling: .init(memberID: "review", cycle: 7, revision: 1),
            in: revised,
            completedOnceMemberIDs: ["plan"]
        ))
        #expect(reconciled.memberID == "implement")
        #expect(reconciled.revision == 2)
    }

    @Test
    func revisionRerunsChangedOnceWorkButRetainsUnchangedOnceWork() {
        let original = liveTeamDefinition()
        var unchanged = original
        unchanged.revision = 2
        #expect(
            LiveTeamStateMachine.reconciledCompletedOnceMemberIDs(
                ["plan"],
                from: original,
                to: unchanged
            ) == ["plan"]
        )

        var changedMember = unchanged
        changedMember.members[0].instructions = "Re-plan the revised approach, then stop."
        #expect(
            LiveTeamStateMachine.reconciledCompletedOnceMemberIDs(
                ["plan"],
                from: original,
                to: changedMember
            ).isEmpty
        )

        var changedGoal = unchanged
        changedGoal.workingGoal = "Deliver the amended feature."
        #expect(
            LiveTeamStateMachine.reconciledCompletedOnceMemberIDs(
                ["plan"],
                from: original,
                to: changedGoal
            ).isEmpty
        )
    }

    @Test
    func boardRevisionCannotBeDisplacedByAutomaticOverseerRevision() throws {
        let current = liveTeamDefinition()
        var boardDefinition = current
        boardDefinition.workingGoal = "Board-directed working goal"
        let board = try LiveTeamStateMachine.pendingRevision(
            definition: boardDefinition,
            baseRevision: 1,
            actor: .board,
            reason: "Board changed the operating brief.",
            evidence: "Manual edit",
            currentDefinition: current,
            existingPending: nil
        )

        #expect(throws: LiveTeamRevisionError.pendingBoardRevision) {
            try LiveTeamStateMachine.pendingRevision(
                definition: current,
                baseRevision: 1,
                actor: .overseer,
                reason: "Automatic proposal",
                evidence: "Periodic review",
                currentDefinition: current,
                existingPending: board
            )
        }
        #expect(throws: LiveTeamRevisionError.stale(base: 0, current: 1)) {
            try LiveTeamStateMachine.pendingRevision(
                definition: current,
                baseRevision: 0,
                actor: .board,
                reason: "Stale edit",
                evidence: "Manual edit",
                currentDefinition: current,
                existingPending: nil
            )
        }
    }

    @Test
    func sharedMemoryRequiresCompatibleExecutionIdentity() {
        var definition = liveTeamDefinition()
        definition.members[0].sessionPolicy = .sharedMemory(groupID: "delivery")
        definition.members[1].sessionPolicy = .sharedMemory(groupID: "delivery")
        definition.members[1].target.model = "different-model"
        #expect(
            definition.validationMessage
                == "Shared-memory group delivery contains incompatible agent targets."
        )
    }

    @Test
    func persistedStateDecodesFieldsAddedAfterInitialPrototype() throws {
        let state = LiveTeamState(
            overseer: LiveTeamOverseerConfiguration(
                target: testTarget(),
                instructions: "Audit strategy."
            )
        )
        let encoded = try JSONEncoder().encode(state)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let overseer = try #require(object["overseer"])
        let minimal = ["overseer": overseer]
        let data = try JSONSerialization.data(withJSONObject: minimal)
        let decoded = try JSONDecoder().decode(LiveTeamState.self, from: data)

        #expect(decoded.overseer == state.overseer)
        #expect(decoded.editHistory.isEmpty)
        #expect(decoded.reviews.isEmpty)
        #expect(decoded.completedOnceMemberIDs.isEmpty)
        #expect(decoded.workerTurnsSinceStrategicReview == 0)
        #expect(decoded.lastStrategicReviewAt == nil)
        #expect(decoded.boardDirectionReason == nil)
    }

    @Test
    func periodicReviewUsesElapsedTimeOnlyAsACooldown() {
        let policy = LiveTeamOversightPolicy(
            periodicRoundInterval: 3,
            periodicWorkerTurnInterval: 12,
            minimumPeriodicReviewInterval: 10 * 60
        )
        let now = Date(timeIntervalSinceReferenceDate: 20_000)

        #expect(!policy.periodicReviewIsDue(
            roundsSinceReview: 2,
            workerTurnsSinceReview: 11,
            lastReviewAt: now.addingTimeInterval(-20 * 60),
            now: now
        ))
        #expect(!policy.periodicReviewIsDue(
            roundsSinceReview: 3,
            workerTurnsSinceReview: 12,
            lastReviewAt: now.addingTimeInterval(-9 * 60),
            now: now
        ))
        #expect(policy.periodicReviewIsDue(
            roundsSinceReview: 3,
            workerTurnsSinceReview: 0,
            lastReviewAt: now.addingTimeInterval(-10 * 60),
            now: now
        ))
        #expect(policy.periodicReviewIsDue(
            roundsSinceReview: 0,
            workerTurnsSinceReview: 12,
            lastReviewAt: nil,
            now: now
        ))
    }

    @Test
    func runtimeRejectsDuplicateTargetIdentifiersBeforeRouting() {
        let target = testTarget()
        let runtime = LiveTeamRuntimeConfiguration(
            overseer: .init(target: target, instructions: "Control strategy."),
            defaultCoordinator: .init(target: target, instructions: "Route local work."),
            targetOptions: [
                .init(id: "same", label: "First", target: target),
                .init(id: "same", label: "Second", target: target)
            ]
        )

        #expect(
            runtime.validationMessage
                == "Available agent target identifiers must be unique."
        )
    }

    @Test
    func boardGoalCanSelectTheFirstOverseerTargetWithoutAFixedModelDefault() {
        let sol = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-sol",
            options: .init(effort: "high")
        )
        let terra = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-terra",
            options: .init(effort: "medium")
        )
        let runtime = LiveTeamRuntimeConfiguration(
            overseer: .init(target: sol, instructions: "Control strategy."),
            defaultCoordinator: .init(target: sol, instructions: "Route local work."),
            targetOptions: [
                .init(id: "sol", label: "Sol", target: sol),
                .init(id: "terra", label: "Terra", target: terra)
            ]
        )

        #expect(
            runtime.bootstrapOverseerConfiguration(
                for: "Use only Codex gpt-5.6-terra for every role."
            ).target == terra
        )
        #expect(
            runtime.bootstrapOverseerConfiguration(
                for: "Do not use gpt-5.6-terra; use only gpt-5.6-sol."
            ).target == sol
        )
        #expect(
            runtime.bootstrapOverseerConfiguration(
                for: "Choose the smallest capable team."
            ).target == sol
        )
    }

    @Test
    func memberPromptCannotExposeAnUnpassedBoardGoal() {
        let member = liveTeamDefinition().members[1]
        let prompt = LiveTeamPromptBuilder.memberPrompt(
            snapshot: LiveTeamMemberSnapshot(
                member: member,
                workingGoal: "Implement the current accepted unit.",
                revision: 1,
                cycle: 1,
                sessionSlotID: "member:implement"
            ),
            handoff: "Start with the parser."
        )
        #expect(prompt.contains("Implement the current accepted unit."))
        #expect(prompt.contains("Start with the parser."))
        #expect(prompt.contains("Explicitly disclose any network or external-service use"))
        #expect(!prompt.contains("Board-only secret constraint"))
    }

    @Test
    func sessionInstructionsRemainValidWhenMembersShareOneConversation() {
        let instructions = LiveTeamPromptBuilder.sessionInstructions()
        #expect(instructions.contains("Each turn supplies your current name"))
        #expect(!instructions.contains("Implement member"))
        #expect(!instructions.contains("Review member"))
    }
}

struct AgentLiveTeamRouterTests {
    @Test
    func rolePromptsEnforceUserGoalVisibilityAndMapTargetChoices() async throws {
        let provider = LiveTeamUtilityProvider()
        let registry = AgentProviderRegistry(providers: [provider])
        let router = AgentLiveTeamRouter(providers: registry)
        let target = testTarget()
        let targetOptions = [
            LiveTeamTargetOption(id: "primary", label: "Primary", target: target)
        ]
        let coordinator = LiveTeamCoordinatorConfiguration(
            target: target,
            instructions: "Manage local flow only."
        )
        let overseer = LiveTeamOverseerConfiguration(
            target: target,
            instructions: "Audit strategy against the Board goal."
        )
        let boardGoal = "Board-only secret constraint: finish the durable feature."
        let overseerContext = LiveTeamOverseerContext(
            userGoal: boardGoal,
            currentDefinition: nil,
            coordinatorHandoff: nil,
            recentEvidence: [],
            editHistory: [],
            targetOptions: targetOptions,
            triggerReason: "Bootstrap"
        )
        let definition = try await router.bootstrap(
            overseerContext,
            configuration: overseer,
            defaultCoordinator: coordinator,
            cwd: "/tmp/live-team-router"
        )
        #expect(definition.members.first?.target == target)

        let snapshot = LiveTeamMemberSnapshot(
            member: try #require(definition.members.first),
            workingGoal: definition.workingGoal,
            revision: 1,
            cycle: 1,
            sessionSlotID: "member:deliver"
        )
        let decision = try await router.coordinate(
            LiveTeamCoordinatorContext(
                workingGoal: definition.workingGoal,
                definition: definition,
                sourceMember: snapshot,
                proposedNextMember: definition.members.first,
                previousHandoff: nil,
                recentDecisions: [],
                sourceResult: "Implemented and tested the bounded unit."
            ),
            configuration: coordinator,
            cwd: "/tmp/live-team-router"
        )
        #expect(decision.disposition == .continueTeam)

        let requests = await provider.requests()
        #expect(requests.count == 2)
        #expect(requests[0].prompt.contains(boardGoal))
        #expect(!requests[1].prompt.contains(boardGoal))
        let goalPosition = try #require(requests[0].prompt.range(of: "FIXED USER GOAL"))
        let feedbackPosition = try #require(
            requests[0].prompt.range(of: "RECENT SUBORDINATE EVIDENCE")
        )
        #expect(goalPosition.lowerBound > feedbackPosition.lowerBound)
        #expect(requests[0].developerInstructions.contains("strategic control"))
        #expect(requests[0].developerInstructions.contains("model"))
        #expect(requests[0].developerInstructions.contains("binding for every Codeness agent"))
        #expect(requests[0].developerInstructions.contains("affirmative evidence"))
        #expect(requests[0].developerInstructions.contains("subordinate working material"))
        #expect(requests[0].developerInstructions.contains("every reversible internal stage"))
        #expect(requests[0].developerInstructions.contains("sole authority source"))
        #expect(requests[0].developerInstructions.contains("advice and evidence, not decisions"))
        #expect(requests[0].developerInstructions.contains("opportunity cost"))
        #expect(requests[0].developerInstructions.contains("does not increase their authority"))
        #expect(requests[0].developerInstructions.contains("Repeated support work"))
        #expect(requests[0].developerInstructions.contains("Do not add independent review after every small change"))
        #expect(requests[0].developerInstructions.contains("outcome-led headline"))
        #expect(requests[1].developerInstructions.contains("route local agent work"))
        #expect(requests[1].developerInstructions.contains("evidence and advice, not authority"))
        #expect(requests[1].developerInstructions.contains("Do not turn suggestions"))
        #expect(requests[1].developerInstructions.contains("outcome-led headline"))
    }

    @Test
    func strategicReviewRetriesOneInvalidResponseWithCorrectionFeedback() async throws {
        let provider = LiveTeamUtilityProvider(outputs: [
            Self.invalidStrategicRevision,
            Self.validStrategicKeep
        ])
        let registry = AgentProviderRegistry(providers: [provider])
        let router = AgentLiveTeamRouter(providers: registry)
        let target = testTarget()
        let decision = try await router.reviewStrategy(
            strategicContext(target: target),
            configuration: LiveTeamOverseerConfiguration(
                target: target,
                instructions: "Keep reversible work moving."
            ),
            cwd: "/tmp/live-team-router-retry"
        )

        #expect(decision.action == .keep)
        let requests = await provider.requests()
        let reviews = requests.filter { request in
            request.outputSchema.objectValue?["properties"]?.objectValue?["action"] != nil
        }
        #expect(reviews.count == 2)
        #expect(reviews[1].prompt.contains("CORRECTION RETRY"))
        #expect(reviews[1].prompt.contains("work-routing configuration is invalid"))
        #expect(reviews[1].outputSchema == reviews[0].outputSchema)
    }

    @Test
    func strategicReviewStopsAfterSecondInvalidResponse() async {
        let provider = LiveTeamUtilityProvider(outputs: [
            Self.invalidStrategicRevision,
            Self.invalidStrategicRevision
        ])
        let registry = AgentProviderRegistry(providers: [provider])
        let router = AgentLiveTeamRouter(providers: registry)
        let target = testTarget()

        await #expect(throws: AgentProviderError.self) {
            try await router.reviewStrategy(
                strategicContext(target: target),
                configuration: LiveTeamOverseerConfiguration(
                    target: target,
                    instructions: "Keep reversible work moving."
                ),
                cwd: "/tmp/live-team-router-retry"
            )
        }
        let reviews = await provider.requests().filter { request in
            request.outputSchema.objectValue?["properties"]?.objectValue?["action"] != nil
        }
        #expect(reviews.count == 2)
    }

    @Test
    func strategicReviewConsultsFreshManagersInParallelWithoutSharingFixedGoal() async throws {
        let provider = LiveTeamUtilityProvider(consultationDelay: .milliseconds(50))
        let registry = AgentProviderRegistry(providers: [provider])
        let router = AgentLiveTeamRouter(providers: registry)
        let progressRecorder = LiveTeamReviewProgressRecorder()
        let target = testTarget()
        let context = strategicContext(target: target)

        let decision = try await router.reviewStrategy(
            context,
            configuration: LiveTeamOverseerConfiguration(
                target: target,
                instructions: "Keep executive control decisive."
            ),
            cwd: "/tmp/live-team-staff-consultation",
            progress: { progress in
                await progressRecorder.append(progress)
            }
        )

        #expect(decision.action == .keep)
        let requests = await provider.requests()
        let selection = try #require(requests.first(where: {
            $0.developerInstructions.contains("opening a short staff consultation")
        }))
        let reports = requests.filter {
            $0.developerInstructions.contains("one fresh, independent advisory manager")
                && !$0.prompt.contains("CORRECTION RETRY")
        }
        let finalReview = try #require(requests.first(where: {
            $0.outputSchema.objectValue?["properties"]?.objectValue?["action"] != nil
        }))

        #expect(selection.prompt.contains(context.userGoal))
        #expect(reports.count == 2)
        #expect(reports.allSatisfy { !$0.prompt.contains(context.userGoal) })
        #expect(reports.allSatisfy { $0.target == target })
        #expect(reports.allSatisfy { $0.developerInstructions.contains("have no authority") })
        #expect(finalReview.prompt.contains("STAFF CONSULTATION"))
        #expect(finalReview.prompt.contains("Creative direction is stalled"))
        #expect(finalReview.prompt.contains("Engineering has a working vertical path"))
        #expect(finalReview.prompt.contains(context.userGoal))
        #expect(finalReview.prompt.contains("do not count votes"))
        #expect(finalReview.prompt.contains("vote count is not a reason to act"))
        #expect(await provider.maximumConcurrentConsultations() == 2)

        let progress = await progressRecorder.values()
        #expect(progress.count == 4)
        guard case .personasSelected(let managers) = progress[0] else {
            Issue.record("The manager list must be the first visible review update.")
            return
        }
        #expect(managers.map(\.name) == ["Creative Director", "Engineering Director"])
        let completed: [(Int, LiveTeamManagerConsultation)] = progress
            .dropFirst()
            .dropLast()
            .compactMap { update in
                guard case .consultationCompleted(let index, let manager) = update else {
                    return nil
                }
                return (index, manager)
            }
        #expect(completed.count == 2)
        #expect(Set(completed.map(\.0)) == [0, 1])
        #expect(completed.allSatisfy { $0.1.status == .completed })
        #expect(progress.last == .overseerDeciding)
    }

    @Test
    func strategicReviewPreservesAnUnavailableManagerWithoutLosingOtherAdvice() async throws {
        let provider = LiveTeamUtilityProvider(unavailablePersona: "Creative Director")
        let registry = AgentProviderRegistry(providers: [provider])
        let router = AgentLiveTeamRouter(providers: registry)
        let target = testTarget()

        let decision = try await router.reviewStrategy(
            strategicContext(target: target),
            configuration: LiveTeamOverseerConfiguration(
                target: target,
                instructions: "Keep executive control decisive."
            ),
            cwd: "/tmp/live-team-partial-staff-consultation"
        )

        #expect(decision.action == .keep)
        let requests = await provider.requests()
        let creativeReports = requests.filter {
            $0.developerInstructions.contains("one fresh, independent advisory manager")
                && $0.prompt.contains("Creative Director")
        }
        #expect(creativeReports.count == 2)
        let finalReview = try #require(requests.first(where: {
            $0.outputSchema.objectValue?["properties"]?.objectValue?["action"] != nil
        }))
        #expect(finalReview.prompt.contains("Creative Director"))
        #expect(finalReview.prompt.contains("unavailable after retry"))
        #expect(finalReview.prompt.contains("Engineering has a working vertical path"))
    }

    @Test
    func strategicReviewDoesNotSilentlySkipAnEntireFailedConsultation() async {
        let provider = LiveTeamUtilityProvider(unavailablePersona: "Director")
        let registry = AgentProviderRegistry(providers: [provider])
        let router = AgentLiveTeamRouter(providers: registry)
        let target = testTarget()

        await #expect(throws: AgentProviderError.self) {
            try await router.reviewStrategy(
                strategicContext(target: target),
                configuration: LiveTeamOverseerConfiguration(
                    target: target,
                    instructions: "Keep executive control decisive."
                ),
                cwd: "/tmp/live-team-failed-staff-consultation"
            )
        }

        let requests = await provider.requests()
        #expect(requests.filter {
            $0.developerInstructions.contains("one fresh, independent advisory manager")
        }.count == 4)
        #expect(!requests.contains(where: {
            $0.outputSchema.objectValue?["properties"]?.objectValue?["action"] != nil
        }))
    }

    @Test
    func completionReviewAlsoUsesStaffConsultation() async throws {
        let provider = LiveTeamUtilityProvider()
        let registry = AgentProviderRegistry(providers: [provider])
        let router = AgentLiveTeamRouter(providers: registry)
        let target = testTarget()
        let context = strategicContext(target: target)

        let decision = try await router.reviewCompletion(
            context,
            configuration: LiveTeamOverseerConfiguration(
                target: target,
                instructions: "Keep executive control decisive."
            ),
            cwd: "/tmp/live-team-completion-consultation"
        )

        #expect(decision.outcome == .continueWork)
        let requests = await provider.requests()
        let finalReview = try #require(requests.first(where: {
            $0.outputSchema.objectValue?["properties"]?.objectValue?["outcome"] != nil
        }))
        #expect(finalReview.prompt.contains("STAFF CONSULTATION"))
        #expect(finalReview.prompt.contains("Creative Director"))
        #expect(finalReview.prompt.contains(context.userGoal))
    }

    @Test
    func coordinatorDecoderRejectsStrategicSmuggling() {
        #expect(throws: (any Error).self) {
            try AgentLiveTeamRouter.decodeCoordinatorDecision(
                """
                {
                  "handoff": "Continue.",
                  "runLabel": "Delivery",
                  "disposition": "continueTeam",
                  "evidence": "Tests pass.",
                  "progressEvidence": "acceptedValidation",
                  "workingGoal": "Secret strategic edit"
                }
                """
            )
        }
    }

    @Test
    func generatedControlTextUsesProductLanguageWithoutRewritingProjectTerms() throws {
        let decision = try AgentLiveTeamRouter.decodeCoordinatorDecision(
            """
            {
              "handoff": "The Overseer should review the Board goal after this team member's cycle.",
              "runLabel": "compliance-evidence-audit-revision-2",
              "disposition": "requestOversight",
              "evidence": "Coordinator evidence requires a fresh team revision.",
              "progressEvidence": "resolvedBlocker"
            }
            """
        )
        #expect(
            decision.handoff
                == "Codeness should review the user goal after this agent's round."
        )
        #expect(decision.runLabel == "compliance-evidence-audit")
        #expect(decision.evidence == "routing evidence requires a fresh agent change.")

        let target = testTarget()
        let definition = try AgentLiveTeamRouter.decodeDefinition(
            """
            {
              "workingGoal": "Every Overseer, Coordinator, and team member must preserve the game board and render cycle.",
              "strategicReason": "This is the smallest useful team for revision 2.",
              "members": [
                {
                  "id": "review",
                  "name": "Revision reviewer",
                  "instructions": "Review the game board as one team member.",
                  "targetID": "primary",
                  "runPolicy": "everyCycle",
                  "sessionPolicy": "ownMemory",
                  "sharedGroupID": null
                }
              ],
              "coordinator": {
                "targetID": "primary",
                "instructions": "The Coordinator routes each team cycle."
              },
              "overseerTargetID": "primary"
            }
            """,
            revision: 2,
            targetOptions: [
                LiveTeamTargetOption(id: "primary", label: "Primary", target: target)
            ],
            defaultCoordinator: LiveTeamCoordinatorConfiguration(
                target: target,
                instructions: "Route work."
            )
        )
        #expect(
            definition.workingGoal
                == "Every Codeness agent must preserve the game board and render cycle."
        )
        #expect(
            definition.strategicReason
                == "This is the smallest useful agent setup for change 2."
        )
        #expect(definition.members.first?.name == "Change reviewer")
        #expect(
            definition.members.first?.instructions
                == "Review the game board as one agent."
        )
        #expect(definition.coordinator.instructions == "Codeness routes each round.")
    }

    @Test
    func legacyStrategicPauseAndCurrentNonRevisionActionsIgnoreStrayFields() throws {
        let current = liveTeamDefinition()
        let targetOptions = [
            LiveTeamTargetOption(id: "primary", label: "Primary", target: testTarget())
        ]

        for action in ["keep", "pause", "complete"] {
            let decision = try AgentLiveTeamRouter.decodeStrategicDecision(
                """
                {
                  "action": "\(action)",
                  "reason": "The controlling action is safe.",
                  "evidence": "The current evidence supports this action.",
                  "workingGoal": "This stray edit must not be applied.",
                  "members": [],
                  "coordinator": {"unexpected": "shape"},
                  "overseerTargetID": "primary",
                  "preferredNextMemberID": "not-a-member"
                }
                """,
                current: current,
                targetOptions: targetOptions
            )

            #expect(decision.action.rawValue == action)
            #expect(decision.proposedDefinition == nil)
            #expect(decision.preferredNextMemberID == nil)
        }
    }

    @Test
    func liveTeamOutputSchemasRequireEveryDeclaredProperty() {
        let targetOptions = [
            LiveTeamTargetOption(id: "primary", label: "Primary", target: testTarget())
        ]
        #expect(schemaUsesStrictObjectProperties(
            AgentLiveTeamRouter.definitionSchema(targetOptions: targetOptions)
        ))
        #expect(schemaUsesStrictObjectProperties(
            AgentLiveTeamRouter.strategicSchema(targetOptions: targetOptions)
        ))
        #expect(schemaUsesStrictObjectProperties(AgentLiveTeamRouter.coordinatorSchema))
        #expect(schemaUsesStrictObjectProperties(AgentLiveTeamRouter.completionSchema))
        #expect(schemaUsesStrictObjectProperties(AgentLiveTeamRouter.staffSelectionSchema))
        #expect(schemaUsesStrictObjectProperties(AgentLiveTeamRouter.staffReportSchema))
        #expect(schemaEnumValues(
            AgentLiveTeamRouter.coordinatorSchema,
            property: "disposition"
        ) == ["continueTeam", "retryCurrent", "requestOversight", "completionCandidate"])
        #expect(schemaEnumValues(
            AgentLiveTeamRouter.strategicSchema(targetOptions: targetOptions),
            property: "action"
        ) == ["keep", "revise", "complete"])
        #expect(schemaEnumValues(
            AgentLiveTeamRouter.completionSchema,
            property: "outcome"
        ) == ["complete", "continueWork"])
        #expect(schemaEnumValues(
            AgentLiveTeamRouter.staffReportSchema,
            property: "involvement"
        ) == ["essential", "supporting", "notNeeded", "unknown"])
        #expect(schemaEnumValues(
            AgentLiveTeamRouter.staffReportSchema,
            property: "progress"
        ) == ["advancing", "stalled", "regressing", "unknown"])
    }

    private static let invalidStrategicRevision = """
    {
      "action": "revise",
      "reason": "The next stage needs a replacement setup.",
      "evidence": "The current agents have finished.",
      "workingGoal": "Continue the fixed goal.",
      "members": [
        {
          "id": "deliver",
          "name": "Deliver",
          "instructions": "Implement the next reversible unit.",
          "targetID": "primary",
          "runPolicy": "once",
          "sessionPolicy": "ownMemory",
          "sharedGroupID": null
        }
      ],
      "coordinator": {
        "targetID": "missing",
        "instructions": "Route the next turn."
      },
      "overseerTargetID": "primary",
      "preferredNextMemberID": "deliver"
    }
    """

    private static let validStrategicKeep = """
    {
      "action": "keep",
      "reason": "The current setup still has useful work.",
      "evidence": "An eligible agent can continue.",
      "workingGoal": null,
      "members": null,
      "coordinator": null,
      "overseerTargetID": null,
      "preferredNextMemberID": null
    }
    """
}

private func schemaEnumValues(_ value: JSONValue, property: String) -> [String] {
    value.objectValue?["properties"]?.objectValue?[property]?.objectValue?["enum"]?
        .arrayValue?
        .compactMap(\.stringValue) ?? []
}

private func schemaUsesStrictObjectProperties(_ value: JSONValue) -> Bool {
    switch value {
    case .object(let object):
        if let properties = object["properties"]?.objectValue {
            let required = Set(
                object["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
            guard required == Set(properties.keys) else { return false }
        }
        return object.values.allSatisfy(schemaUsesStrictObjectProperties)
    case .array(let values):
        return values.allSatisfy(schemaUsesStrictObjectProperties)
    case .null, .bool, .integer, .number, .string:
        return true
    }
}

private actor LiveTeamReviewProgressRecorder {
    private var progress: [LiveTeamReviewProgress] = []

    func append(_ value: LiveTeamReviewProgress) {
        progress.append(value)
    }

    func values() -> [LiveTeamReviewProgress] { progress }
}

private actor LiveTeamUtilityProvider: AgentProviding {
    nonisolated let id: AgentProviderID = .codex
    private var utilityRequests: [AgentUtilityRequest] = []
    private var outputs: [String]
    private let consultationDelay: Duration
    private let unavailablePersona: String?
    private var activeConsultations = 0
    private var maximumActiveConsultations = 0

    init(
        outputs: [String] = [],
        consultationDelay: Duration = .zero,
        unavailablePersona: String? = nil
    ) {
        self.outputs = outputs
        self.consultationDelay = consultationDelay
        self.unavailablePersona = unavailablePersona
    }

    func prepareSession(_ request: AgentSessionRequest) throws -> AgentSession {
        throw AgentProviderError.invalidSession(request.name)
    }

    func startRun(_ request: AgentRunRequest) throws -> AgentRunHandle {
        throw AgentProviderError.missingRun(request.runID)
    }

    func steer(runID: UUID, message: String) throws {
        _ = message
        throw AgentProviderError.missingRun(runID)
    }

    func interrupt(runID: UUID) throws {
        throw AgentProviderError.missingRun(runID)
    }

    func resolveInteraction(
        runID: UUID,
        interactionID: String,
        resolution: AgentInteractionResolution
    ) throws {
        _ = interactionID
        _ = resolution
        throw AgentProviderError.missingRun(runID)
    }

    func runUtility(_ request: AgentUtilityRequest) async -> AgentUtilityResult {
        utilityRequests.append(request)
        if request.developerInstructions.contains("opening a short staff consultation") {
            return AgentUtilityResult(output: """
            {
              "personas": [
                {
                  "name": "Creative Director",
                  "mandate": "Judge whether the experience is becoming a coherent product."
                },
                {
                  "name": "Engineering Director",
                  "mandate": "Judge implementation progress, technical risk, and the next production move."
                }
              ]
            }
            """)
        }
        if request.developerInstructions.contains("one fresh, independent advisory manager") {
            activeConsultations += 1
            maximumActiveConsultations = max(
                maximumActiveConsultations,
                activeConsultations
            )
            if consultationDelay > .zero {
                try? await Task.sleep(for: consultationDelay)
            }
            activeConsultations -= 1
            if let unavailablePersona,
               request.prompt.contains(unavailablePersona) {
                return AgentUtilityResult(output: "invalid report")
            }
            if request.prompt.contains("Creative Director") {
                return AgentUtilityResult(output: """
                {
                  "involvement": "essential",
                  "progress": "stalled",
                  "evidence": "Creative direction is stalled while recent work concentrates on support documents.",
                  "concern": "The playable experience is not yet carrying the product ambition.",
                  "nextMove": "Build and evaluate the next player-facing slice."
                }
                """)
            }
            return AgentUtilityResult(output: """
            {
              "involvement": "essential",
              "progress": "advancing",
              "evidence": "Engineering has a working vertical path and can continue implementation.",
              "concern": "None supported by the supplied evidence.",
              "nextMove": "Continue the highest-value production unit."
            }
            """)
        }
        if !outputs.isEmpty {
            return AgentUtilityResult(output: outputs.removeFirst())
        }
        if request.developerInstructions.contains("route local agent work") {
            return AgentUtilityResult(output: """
            {
              "handoff": "Continue to the next bounded member.",
              "runLabel": "Bounded delivery",
              "disposition": "continueTeam",
              "evidence": "The member reported implementation and tests.",
              "progressEvidence": "acceptedValidation"
            }
            """)
        }
        if request.outputSchema.objectValue?["properties"]?.objectValue?["action"] != nil {
            return AgentUtilityResult(output: """
            {
              "action": "keep",
              "reason": "The current setup still has useful product work.",
              "evidence": "The staff reports and durable result support forward motion.",
              "workingGoal": null,
              "members": null,
              "coordinator": null,
              "overseerTargetID": null,
              "preferredNextMemberID": null
            }
            """)
        }
        if request.outputSchema.objectValue?["properties"]?.objectValue?["outcome"] != nil {
            return AgentUtilityResult(output: """
            {
              "outcome": "continueWork",
              "evidence": "The staff reports show meaningful work remains.",
              "reason": "The fixed goal is not yet complete."
            }
            """)
        }
        return AgentUtilityResult(output: """
        {
          "workingGoal": "Implement and verify one durable feature unit.",
          "strategicReason": "A single delivery member is sufficient to begin.",
          "members": [
            {
              "id": "deliver",
              "name": "Deliver",
              "instructions": "Implement one bounded unit, test it, and stop with evidence.",
              "targetID": "primary",
              "runPolicy": "everyCycle",
              "sessionPolicy": "ownMemory",
              "sharedGroupID": null
            }
          ],
          "coordinator": {
            "targetID": "primary",
            "instructions": "Manage local flow only."
          },
          "overseerTargetID": "primary"
        }
        """)
    }

    func shutdown() {}
    func shutdownAndVerify() -> Bool { true }
    func requests() -> [AgentUtilityRequest] { utilityRequests }
    func maximumConcurrentConsultations() -> Int { maximumActiveConsultations }
}

private func strategicContext(target: AgentTarget) -> LiveTeamOverseerContext {
    LiveTeamOverseerContext(
        userGoal: "Finish the project autonomously.",
        currentDefinition: liveTeamDefinition(),
        coordinatorHandoff: "The current agents finished their work.",
        recentEvidence: [],
        editHistory: [],
        targetOptions: [
            LiveTeamTargetOption(id: "primary", label: "Primary", target: target)
        ],
        triggerReason: "The current agents are exhausted."
    )
}

private func testTarget() -> AgentTarget {
    AgentTarget(
        providerID: .codex,
        model: "test-model",
        options: .init(effort: "high")
    )
}

private func liveTeamDefinition() -> LiveTeamDefinition {
    let target = testTarget()
    return LiveTeamDefinition(
        revision: 1,
        workingGoal: "Deliver and validate the feature.",
        members: [
            LiveTeamMember(
                id: "plan",
                name: "Plan",
                instructions: "Create a bounded plan, then stop.",
                target: target,
                runPolicy: .once,
                sessionPolicy: .ownMemory
            ),
            LiveTeamMember(
                id: "implement",
                name: "Implement",
                instructions: "Implement one unit, test it, then stop.",
                target: target,
                runPolicy: .everyCycle,
                sessionPolicy: .ownMemory
            ),
            LiveTeamMember(
                id: "review",
                name: "Review",
                instructions: "Review the unit without editing, then stop.",
                target: target,
                runPolicy: .everyCycle,
                sessionPolicy: .freshEveryRun
            )
        ],
        coordinator: LiveTeamCoordinatorConfiguration(
            target: target,
            instructions: "Manage local flow only."
        ),
        strategicReason: "This is the smallest coherent team."
    )
}
