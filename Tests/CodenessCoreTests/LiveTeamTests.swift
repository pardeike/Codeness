import Foundation
import Testing
@testable import CodenessCore

struct LiveTeamModelTests {
    @Test
    func predefinedPositionCatalogCoversEveryPositionExactlyOnce() {
        #expect(
            Set(CompanyPositionCatalog.positions.map(\.id))
                == Set(CompanyPositionID.allCases)
        )
        #expect(
            Set(CompanyPositionCatalog.positions.map(\.title)).count
                == CompanyPositionCatalog.positions.count
        )
        #expect(CompanyPositionCatalog.position(.developer).title == "Developer")
        #expect(CompanyPositionCatalog.position(.artDirector).title == "Art Director")
    }

    @Test
    func professionPracticeCatalogCoversEveryPositionWithRealBoundaries() {
        #expect(
            Set(CompanyPositionPracticeCatalog.practices.map(\.positionID))
                == Set(CompanyPositionID.allCases)
        )
        #expect(
            CompanyPositionPracticeCatalog.practices.allSatisfy {
                !$0.purpose.isEmpty
                    && !$0.acceptanceEvidence.isEmpty
                    && !$0.allowedContributions.isEmpty
                    && !$0.allowedCapabilities.isEmpty
                    && !$0.subscribedContributions.isEmpty
                    && !$0.completionCondition.isEmpty
                    && !$0.escalationCondition.isEmpty
            }
        )

        let developer = CompanyPositionPracticeCatalog.practice(.developer)
        let artDirector = CompanyPositionPracticeCatalog.practice(.artDirector)
        let soundDesigner = CompanyPositionPracticeCatalog.practice(.soundDesigner)
        let researcher = CompanyPositionPracticeCatalog.practice(.researcher)

        #expect(developer.allowedCapabilities.contains(.sourceModification))
        #expect(!artDirector.allowedCapabilities.contains(.sourceModification))
        #expect(artDirector.allowedCapabilities.contains(.visualAssetProduction))
        #expect(soundDesigner.allowedCapabilities.contains(.audioAssetProduction))
        #expect(!soundDesigner.allowedCapabilities.contains(.sourceModification))
        #expect(researcher.allowedCapabilities.contains(.webResearch))
        #expect(!researcher.allowedCapabilities.contains(.sourceModification))
    }

    @Test
    func persistentSessionsAreSeparatedByProfessionToolPolicy() {
        let policy = LiveTeamSessionPolicy.sharedMemory(groupID: "creative")
        let artSlot = policy.persistentSlotID(
            memberID: "art",
            positionID: .artDirector
        )
        let developerSlot = policy.persistentSlotID(
            memberID: "developer",
            positionID: .developer
        )

        #expect(artSlot != developerSlot)
        #expect(artSlot?.contains("visualAssetProduction") == true)
        #expect(developerSlot?.contains("sourceModification") == true)

        let researchConfiguration = CodexAgentProvider.companyThreadConfiguration(
            CompanyToolPolicy(positionID: .researcher)
        )
        #expect(researchConfiguration["web_search"]?.stringValue == "live")
        #expect(researchConfiguration["features"]?["plugins"]?.boolValue == false)
        #expect(CompanyToolPolicy(positionID: .researcher).requiresReadOnlySandbox)
        #expect(!CompanyToolPolicy(positionID: .developer).requiresReadOnlySandbox)
    }

    @Test
    func companyAssignmentsFailClosedAcrossProfessionAndTargetBoundaries() {
        let sourceWritingArt = CompanyAssignmentContract(
            contributionKind: .visualDirection,
            requiredCapabilities: [.sourceModification],
            acceptanceEvidence: "A visual direction exists.",
            dependencyContributionKinds: [],
            stopCondition: "Stop when accepted."
        )
        #expect(
            sourceWritingArt.validationMessage(
                positionID: .artDirector,
                target: testTarget()
            )?.contains("Art Director cannot use") == true
        )

        let audioProduction = CompanyAssignmentContract(
            contributionKind: .audioDirection,
            requiredCapabilities: [.audioAssetProduction],
            acceptanceEvidence: "An audio asset can be played.",
            dependencyContributionKinds: [],
            stopCondition: "Stop when playable or blocked."
        )
        #expect(
            audioProduction.validationMessage(
                positionID: .soundDesigner,
                target: testTarget()
            )?.contains("cannot supply") == true
        )

        var localTarget = testTarget()
        localTarget.providerID = .openAICompatible
        let webResearch = CompanyAssignmentContract(
            contributionKind: .researchFinding,
            requiredCapabilities: [.webResearch],
            acceptanceEvidence: "Sources support a decision.",
            dependencyContributionKinds: [],
            stopCondition: "Stop when the question is answered or blocked."
        )
        #expect(
            webResearch.validationMessage(
                positionID: .researcher,
                target: localTarget
            )?.contains("cannot supply") == true
        )
    }

    @Test
    func personaRequirementsRejectIndifferenceAndKeepRandomIngredientsReproducible() {
        var firstGenerator = SeededTestGenerator(seed: 42)
        var secondGenerator = SeededTestGenerator(seed: 42)
        #expect(
            CompanyPersonaIngredients.random(using: &firstGenerator)
                == CompanyPersonaIngredients.random(using: &secondGenerator)
        )

        var person = testCompanyPerson(
            name: "Avery Vale",
            positionID: .developer,
            assignment: "Build the product."
        )
        #expect(person.profile.validationMessage == nil)
        person.profile.workingStyle = "A neutral facilitator who avoids disagreement."
        #expect(
            person.profile.validationMessage
                == "A company persona cannot be neutral, indifferent, or invested in mediocrity."
        )
    }

    @Test
    func companyDefinitionRoundTripPreservesFormerPeopleAndFundingState() throws {
        var definition = companyLiveTeamDefinition()
        var formerChiefExecutive = testCompanyPerson(
            name: "Former CEO",
            positionID: .chiefExecutive,
            assignment: "Fund the original product bet."
        )
        formerChiefExecutive.hiredRevision = definition.revision
        formerChiefExecutive.generationTokenUsage = RunTokenUsage(
            totalTokens: 30,
            inputTokens: 20,
            outputTokens: 10
        )
        definition.formerPeople = [formerChiefExecutive]
        definition.setupTokenUsage = RunTokenUsage(
            totalTokens: 40,
            inputTokens: 30,
            outputTokens: 10
        )

        let data = try JSONEncoder().encode(definition)
        let decoded = try JSONDecoder().decode(LiveTeamDefinition.self, from: data)

        #expect(decoded == definition)
        #expect(decoded.validationMessage == nil)
    }

    @Test
    func companyLanguageAndProductBetSurvivePersistedTextNormalization() throws {
        let definition = companyLiveTeamDefinition()
        let member = try #require(definition.members.first)
        let snapshot = LiveTeamMemberSnapshot(
            member: member,
            workingGoal: definition.workingGoal,
            revision: definition.revision,
            cycle: 1,
            sessionSlotID: "member:\(member.id)",
            productBet: definition.productBet
        )
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: nil,
            model: member.target.model,
            effort: "high",
            prompt: "Build it.",
            startedAt: .now,
            liveTeamMember: snapshot
        )
        var activity = ActivityRecord(
            goal: "Build the product.",
            prompts: .builtInDefaults,
            status: .running,
            runs: [run],
            liveTeam: LiveTeamState(
                overseer: .init(target: member.target, instructions: "Own the goal."),
                currentDefinition: definition
            )
        )

        LiveTeamProductLanguage.normalizePersistedControlText(in: &activity)

        #expect(
            activity.liveTeam?.currentDefinition?.strategicReason
                == definition.strategicReason
        )
        #expect(activity.runs.first?.liveTeamMember?.productBet == definition.productBet)
    }

    @Test
    func productMotorAdvancesWithoutControlTokensUntilInvestmentBoundary() throws {
        var definition = companyLiveTeamDefinition()
        #expect(CompanyProductBet(
            headline: "Build it",
            valuePromise: "A user can use it.",
            showcase: "Working product",
            integrationTarget: "Main surface",
            killCondition: "Direct use disproves the bet.",
            maximumTurns: 2
        ).maximumTurns == 6)
        definition.productBet?.maximumTurns = 6
        let member = try #require(definition.members.last)
        let snapshot = LiveTeamMemberSnapshot(
            member: member,
            workingGoal: definition.workingGoal,
            revision: definition.revision,
            cycle: 1,
            sessionSlotID: "member:\(member.id)",
            productBet: definition.productBet
        )
        let checkpoint = LiveTeamCheckpoint(
            memberID: member.id,
            cycle: 2,
            revision: definition.revision
        )
        let run: (Int) -> RunRecord = { sequence in
            RunRecord(
                sequence: sequence,
                role: .implementer,
                kind: .implementation,
                status: .completed,
                threadID: nil,
                model: member.target.model,
                effort: "high",
                prompt: "Build it.",
                startedAt: .now,
                tokenUsage: .init(
                    totalTokens: 20_000,
                    inputTokens: 18_000,
                    outputTokens: 2_000
                ),
                liveTeamMember: snapshot
            )
        }

        let advancing = CompanyProductMotor.decision(
            sourceResult: "Shipped a visible interaction.",
            snapshot: snapshot,
            definition: definition,
            proposedCheckpoint: checkpoint,
            runs: [run(1)]
        )
        #expect(advancing.disposition == .continueTeam)
        #expect(advancing.tokenUsage == nil)

        let boundary = CompanyProductMotor.decision(
            sourceResult: "Integrated and exercised the slice.",
            snapshot: snapshot,
            definition: definition,
            proposedCheckpoint: checkpoint,
            runs: (1...6).map(run)
        )
        #expect(boundary.disposition == .requestOversight)
        #expect(boundary.evidence.contains("6-turn investment boundary"))
    }

    @Test
    func productMotorDiscountsCachedInputAndProtectsTheFirstSixProductTurns() throws {
        var definition = companyLiveTeamDefinition()
        definition.productBet?.fundedTokenLimit = 1_000_000
        definition.productBet?.maximumTurns = 20
        let member = try #require(definition.members.last)
        let snapshot = LiveTeamMemberSnapshot(
            member: member,
            workingGoal: definition.workingGoal,
            revision: definition.revision,
            cycle: 1,
            sessionSlotID: "member:\(member.id)",
            productBet: definition.productBet
        )
        let checkpoint = LiveTeamCheckpoint(
            memberID: member.id,
            cycle: 2,
            revision: definition.revision
        )
        let run: (Int) -> RunRecord = { sequence in
            RunRecord(
                sequence: sequence,
                role: .implementer,
                kind: .implementation,
                status: .completed,
                threadID: nil,
                model: member.target.model,
                effort: "high",
                prompt: "Build it.",
                startedAt: .now,
                tokenUsage: .init(
                    totalTokens: 1_000_000,
                    inputTokens: 990_000,
                    cachedInputTokens: 980_000,
                    outputTokens: 10_000
                ),
                liveTeamMember: snapshot
            )
        }

        let firstWindow = (1...6).map(run)
        let usage = CompanyProductMotor.usage(for: definition, runs: firstWindow)
        #expect(usage.totalTokens == 6_000_000)
        #expect(usage.effectiveFundingTokens == 708_000)

        let protected = CompanyProductMotor.decision(
            sourceResult: "INVESTMENT BOUNDARY: READY",
            snapshot: snapshot,
            definition: definition,
            proposedCheckpoint: checkpoint,
            runs: Array(firstWindow.prefix(5))
        )
        #expect(protected.disposition == .continueTeam)

        let stillFunded = CompanyProductMotor.decision(
            sourceResult: "The integrated product keeps improving.",
            snapshot: snapshot,
            definition: definition,
            proposedCheckpoint: checkpoint,
            runs: firstWindow
        )
        #expect(stillFunded.disposition == .continueTeam)

        let tokenBoundary = CompanyProductMotor.decision(
            sourceResult: "The integrated product keeps improving.",
            snapshot: snapshot,
            definition: definition,
            proposedCheckpoint: checkpoint,
            runs: (1...9).map(run)
        )
        #expect(tokenBoundary.disposition == .requestOversight)
        #expect(tokenBoundary.evidence.contains("effective funding-token budget"))
    }

    @Test
    func productMotorRepairsAnUnrunnableTeamWithoutWaitingSixTurns() throws {
        let definition = companyLiveTeamDefinition()
        let member = try #require(definition.members.last)
        let snapshot = LiveTeamMemberSnapshot(
            member: member,
            workingGoal: definition.workingGoal,
            revision: definition.revision,
            cycle: 1,
            sessionSlotID: "member:\(member.id)",
            productBet: definition.productBet
        )

        let decision = CompanyProductMotor.decision(
            sourceResult: "The one-time assignments are exhausted.",
            snapshot: snapshot,
            definition: definition,
            proposedCheckpoint: nil,
            runs: []
        )

        #expect(decision.disposition == .requestOversight)
        #expect(decision.evidence.contains("no assigned person remains eligible"))
    }

    @Test
    func productMotorBuildsARecipientAwareHandoffFromStructuredWork() throws {
        var definition = companyLiveTeamDefinition()
        let developer = try #require(definition.members.first { $0.positionID == .developer })
        let artDirector = try #require(definition.members.first { $0.positionID == .artDirector })
        definition.members = [developer, artDirector]
        let snapshot = LiveTeamMemberSnapshot(
            member: developer,
            workingGoal: definition.workingGoal,
            revision: definition.revision,
            cycle: 1,
            sessionSlotID: "member:\(developer.id)",
            productBet: definition.productBet
        )
        let report = CompanyWorkReport(
            workerID: developer.id,
            positionID: .developer,
            contributionKind: .softwareImplementation,
            summary: "Changed twelve private parser functions and rewired the cache internals.",
            artifacts: ["Demo.app", "Sources/Parser.swift"],
            evidence: ["The demo now opens on the main product screen."],
            decisions: ["Internal cache now uses stable keys."],
            constraints: ["The main screen is 900 by 600 points."],
            risks: [],
            capabilityBlock: nil,
            recommendedRecipientPositions: [.artDirector]
        )
        let output = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)

        let decision = CompanyProductMotor.decision(
            sourceResult: output,
            snapshot: snapshot,
            definition: definition,
            proposedCheckpoint: LiveTeamCheckpoint(
                memberID: artDirector.id,
                cycle: 1,
                revision: definition.revision
            ),
            runs: []
        )

        #expect(decision.handoff.contains("For: Art Director"))
        #expect(decision.handoff.contains("Demo.app"))
        #expect(decision.handoff.contains("900 by 600"))
        #expect(!decision.handoff.contains("twelve private parser functions"))
        #expect(!decision.handoff.contains("stable keys"))
    }

    @Test
    func productMotorEscalatesCapabilityBlocksWithoutRetryingTheWrongProfession() throws {
        let definition = companyLiveTeamDefinition()
        let artDirector = try #require(definition.members.first { $0.positionID == .artDirector })
        let snapshot = LiveTeamMemberSnapshot(
            member: artDirector,
            workingGoal: definition.workingGoal,
            revision: definition.revision,
            cycle: 1,
            sessionSlotID: "member:\(artDirector.id)",
            productBet: definition.productBet
        )
        let report = CompanyWorkReport(
            workerID: artDirector.id,
            positionID: .artDirector,
            contributionKind: .visualDirection,
            summary: "The visual direction is ready, but the interaction also needs an audio identity.",
            artifacts: ["VisualDirection.md"],
            evidence: ["Three visual states are specified."],
            decisions: [],
            constraints: ["Audio must follow the three visual states."],
            risks: [],
            capabilityBlock: CompanyCapabilityBlock(
                kind: .professionForbidden,
                requiredCapability: .audioAssetProduction,
                detail: "Producing the score belongs to an audio specialist.",
                artifacts: ["VisualDirection.md"],
                suggestedPositions: [.soundDesigner]
            ),
            recommendedRecipientPositions: [.soundDesigner]
        )
        let output = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)

        let decision = CompanyProductMotor.decision(
            sourceResult: output,
            snapshot: snapshot,
            definition: definition,
            proposedCheckpoint: nil,
            runs: []
        )

        #expect(decision.disposition == .requestOversight)
        #expect(decision.evidence.contains("audioAssetProduction"))
        #expect(decision.handoff.contains("Sound Designer"))
        #expect(decision.handoff.contains("VisualDirection.md"))
    }

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
        #expect(prompt.contains("Do not delegate it to sub-agents"))
        #expect(prompt.contains("Codeness has already assigned the other responsibilities"))
        #expect(prompt.contains("profession-specific contribution"))
        #expect(prompt.contains("stop at that boundary and return a capability block"))
        #expect(prompt.contains("personal or global agent memory"))
        #expect(prompt.contains("previous Codeness runs"))
        #expect(!prompt.contains("Board-only secret constraint"))
    }

    @Test
    func sessionInstructionsRemainValidWhenMembersShareOneConversation() {
        let instructions = LiveTeamPromptBuilder.sessionInstructions()
        #expect(instructions.contains("personality, position, assignment"))
        #expect(instructions.contains("Do not delegate the assignment to sub-agents"))
        #expect(instructions.contains("current turn's profession contract"))
        #expect(instructions.contains("at most 180 words"))
        #expect(instructions.contains("not an academic, consultant, or formal committee"))
        #expect(instructions.contains("personal or global agent memory"))
        #expect(!instructions.contains("visible, usable, integrated product value"))
        #expect(!instructions.contains("prove the best one through the repository"))
        #expect(!instructions.contains("Implement member"))
        #expect(!instructions.contains("Review member"))
    }

    @Test
    func companyMemberPromptMakesProfessionARealWorkBoundary() throws {
        let definition = companyLiveTeamDefinition()
        let member = try #require(definition.members.first)
        let prompt = LiveTeamPromptBuilder.memberPrompt(
            snapshot: LiveTeamMemberSnapshot(
                member: member,
                workingGoal: definition.workingGoal,
                revision: definition.revision,
                cycle: 1,
                sessionSlotID: "member:\(member.id)",
                productBet: definition.productBet
            ),
            handoff: nil
        )

        #expect(prompt.contains("PROFESSION CONTRACT"))
        #expect(prompt.contains("Visual direction and visual asset acceptance"))
        #expect(prompt.contains("visualAssetProduction"))
        #expect(prompt.contains("Do not silently take on:"))
        #expect(prompt.contains("sourceModification"))
        #expect(prompt.contains("ASSIGNMENT CONTRACT"))
        #expect(prompt.contains("Required contribution: visualDirection"))
        #expect(prompt.contains("Relevant predecessor contributions: productDirection, softwareImplementation"))
        #expect(!prompt.contains("Improve the repository's actual product"))
        #expect(!prompt.contains("prove the best one through the repository"))
        #expect(!prompt.contains("Report concrete product changes"))
        #expect(!prompt.contains("Product work may be large"))
    }

}

private struct SeededTestGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
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
        #expect(definition.productBet?.audience == "People who need the feature")
        #expect(
            definition.productBet?.focusQuestion
                == "Would the intended audience choose this feature over the closest alternative?"
        )
        #expect(
            definition.members.first?.companyAssignment?.contributionKind
                == .softwareImplementation
        )
        #expect(
            definition.members.first?.companyAssignment?.requiredCapabilities
                == [.workspaceRead, .sourceModification, .commandExecution]
        )

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
        #expect(requests.count == 4)
        let bootstrapRequest = try #require(requests.first(where: {
            $0.outputSchema.objectValue?["properties"]?.objectValue?["productBet"] != nil
                && $0.outputSchema.objectValue?["properties"]?.objectValue?["action"] == nil
        }))
        let coordinatorRequest = try #require(requests.first(where: {
            $0.developerInstructions.contains("route local agent work")
        }))
        let personaRequests = requests.filter {
            $0.outputSchema.objectValue?["properties"]?.objectValue?["personalStake"] != nil
        }
        #expect(personaRequests.count == 2)
        #expect(personaRequests[0].prompt.contains(boardGoal))
        #expect(!personaRequests[1].prompt.contains(boardGoal))
        #expect(bootstrapRequest.prompt.contains(boardGoal))
        #expect(!coordinatorRequest.prompt.contains(boardGoal))
        let goalPosition = try #require(bootstrapRequest.prompt.range(of: "FIXED USER GOAL"))
        let feedbackPosition = try #require(
            bootstrapRequest.prompt.range(of: "RECENT SUBORDINATE EVIDENCE")
        )
        #expect(goalPosition.lowerBound > feedbackPosition.lowerBound)
        #expect(bootstrapRequest.developerInstructions.contains("strategic control"))
        #expect(bootstrapRequest.developerInstructions.contains("sole authority source"))
        #expect(bootstrapRequest.developerInstructions.contains("useful goal progress and learning per effective token cost"))
        #expect(bootstrapRequest.developerInstructions.contains("External access that is unavailable is an evidence gap"))
        #expect(bootstrapRequest.developerInstructions.contains("Never sound like an academic"))
        #expect(bootstrapRequest.developerInstructions.contains("PROJECT MEMORY BOUNDARY"))
        #expect(bootstrapRequest.prompt.contains("first six eligible company turns"))
        #expect(bootstrapRequest.developerInstructions.contains("choose only from this catalog"))
        let bootstrapInstructions = bootstrapRequest.developerInstructions
            + bootstrapRequest.prompt
        #expect(bootstrapInstructions.contains("Order people by real execution dependency"))
        #expect(bootstrapInstructions.contains("required contribution and acceptance evidence"))
        #expect(bootstrapInstructions.contains("Art Director owns visualDirection"))
        #expect(bootstrapInstructions.contains("Sound Designer owns audioDirection"))
        #expect(bootstrapInstructions.contains("capability block"))
        let memberProperties = try #require(
            bootstrapRequest.outputSchema["properties"]?["members"]?["items"]?["properties"]?
                .objectValue
        )
        #expect(memberProperties["contributionKind"] != nil)
        #expect(memberProperties["requiredCapabilities"] != nil)
        #expect(memberProperties["acceptanceEvidence"] != nil)
        #expect(memberProperties["dependencyContributionKinds"] != nil)
        #expect(memberProperties["stopCondition"] != nil)
        #expect(!bootstrapInstructions.contains("Treat Developer as a default hire"))
        #expect(!bootstrapInstructions.contains("first person must own the next tangible product change"))
        #expect(coordinatorRequest.developerInstructions.contains("route local agent work"))
        #expect(coordinatorRequest.developerInstructions.contains("evidence and advice, not authority"))
    }

    @Test
    func companyStaffingRetriesANameAlreadyUsedByTheChiefExecutive() async throws {
        let provider = LiveTeamUtilityProvider(personaNames: [
            "Rhea Calder",
            "Rhea Calder",
            "Eli Navarro"
        ])
        let registry = AgentProviderRegistry(providers: [provider])
        let router = AgentLiveTeamRouter(providers: registry)
        let target = testTarget()
        let definition = try await router.bootstrap(
            LiveTeamOverseerContext(
                userGoal: "Build a real product.",
                currentDefinition: nil,
                coordinatorHandoff: nil,
                recentEvidence: [],
                editHistory: [],
                targetOptions: [
                    LiveTeamTargetOption(id: "primary", label: "Primary", target: target)
                ],
                triggerReason: "Bootstrap"
            ),
            configuration: LiveTeamOverseerConfiguration(
                target: target,
                instructions: "Keep direct product work moving."
            ),
            defaultCoordinator: LiveTeamCoordinatorConfiguration(
                target: target,
                instructions: "Route direct product work."
            ),
            cwd: "/tmp/live-team-unique-people"
        )

        #expect(definition.overseerPerson?.profile.fullName == "Rhea Calder")
        #expect(definition.members.first?.person?.profile.fullName == "Eli Navarro")
        let personaRequests = await provider.requests().filter {
            $0.developerInstructions.contains("Create one memorable startup colleague")
        }
        #expect(personaRequests.count == 3)
        #expect(personaRequests[1].prompt.contains("rhea calder"))
        #expect(personaRequests[2].prompt.contains("CORRECTION RETRY"))
        #expect(personaRequests[2].prompt.contains("reused an existing colleague's name"))
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
        #expect(reviews[1].prompt.contains("a company assignment has missing, extra, or invalid profession fields"))
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
    func strategicReviewConsultsPersistedCompanyPeopleInSequenceWithoutSharingFixedGoal() async throws {
        let provider = LiveTeamUtilityProvider(consultationDelay: .milliseconds(50))
        let registry = AgentProviderRegistry(providers: [provider])
        let router = AgentLiveTeamRouter(providers: registry)
        let progressRecorder = LiveTeamReviewProgressRecorder()
        let target = testTarget()
        let context = strategicContext(target: target)
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codeness-focus-group-test.\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }

        let decision = try await router.reviewStrategy(
            context,
            configuration: LiveTeamOverseerConfiguration(
                target: target,
                instructions: "Keep executive control decisive."
            ),
            cwd: repository.path,
            progress: { progress in
                await progressRecorder.append(progress)
            }
        )

        #expect(decision.action == .keep)
        let requests = await provider.requests()
        let focusRequest = try #require(requests.first {
            $0.developerInstructions.contains("simulate a small focus group")
        })
        let reports = requests.filter {
            $0.developerInstructions.contains("persisted named company person")
                && !$0.prompt.contains("CORRECTION RETRY")
        }
        let finalReview = try #require(requests.first(where: {
            $0.outputSchema.objectValue?["properties"]?.objectValue?["action"] != nil
        }))

        #expect(reports.count == 2)
        #expect(reports.allSatisfy { !$0.prompt.contains(context.userGoal) })
        #expect(reports.allSatisfy { $0.prompt.contains("FOCUS GROUP") })
        #expect(reports.allSatisfy { $0.prompt.contains("A close established alternative") })
        #expect(reports.allSatisfy { $0.target == target })
        #expect(reports.allSatisfy { $0.developerInstructions.contains("have no authority") })
        #expect(finalReview.prompt.contains("COMPANY CHECK-IN"))
        #expect(finalReview.prompt.contains("FOCUS GROUP"))
        #expect(finalReview.prompt.contains("A close established alternative"))
        #expect(finalReview.prompt.contains("Creative direction is stalled"))
        #expect(finalReview.prompt.contains("Engineering has a working vertical path"))
        #expect(finalReview.prompt.contains(context.userGoal))
        #expect(finalReview.prompt.contains("do not count votes"))
        #expect(finalReview.prompt.contains("vote count is not a reason to act"))
        #expect(await provider.maximumConcurrentConsultations() == 1)
        #expect(focusRequest.allowsWebResearch)
        #expect(focusRequest.cwd != repository.path)
        #expect(!focusRequest.prompt.contains(repository.path))
        #expect(!focusRequest.prompt.contains(context.userGoal))
        #expect(!focusRequest.prompt.contains("Mira Voss"))
        #expect(!FileManager.default.fileExists(atPath: focusRequest.cwd))

        let progress = await progressRecorder.values()
        #expect(progress.count == 5)
        guard case .focusGroupCompleted(let focusGroup) = progress[0] else {
            Issue.record("The focus group must report before the company check-in.")
            return
        }
        #expect(focusGroup.researchBasis == .liveWeb)
        #expect(focusGroup.participants.count == 4)
        let reportPath = try #require(focusGroup.documentPath)
        #expect(FileManager.default.fileExists(
            atPath: repository.appendingPathComponent(reportPath).path
        ))
        guard case .personasSelected(let managers) = progress[1] else {
            Issue.record("The manager list must follow the focus-group report.")
            return
        }
        #expect(managers.map(\.name) == ["Mira Voss", "Eli Navarro"])
        let completed: [(Int, LiveTeamManagerConsultation)] = progress
            .dropFirst(2)
            .dropLast()
            .compactMap { update in
                guard case .consultationCompleted(let index, let manager) = update else {
                    return nil
                }
                return (index, manager)
            }
        #expect(completed.count == 2)
        #expect(completed.map(\.0) == [0, 1])
        #expect(completed.allSatisfy { $0.1.status == .completed })
        #expect(progress.last == .overseerDeciding)
    }

    @Test
    func strategicReviewPreservesAnUnavailableManagerWithoutLosingOtherAdvice() async throws {
        let provider = LiveTeamUtilityProvider(unavailablePersona: "Mira Voss")
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
            $0.developerInstructions.contains("persisted named company person")
                && $0.prompt.contains("WHO YOU ARE\nMira Voss")
        }
        #expect(creativeReports.count == 2)
        let finalReview = try #require(requests.first(where: {
            $0.outputSchema.objectValue?["properties"]?.objectValue?["action"] != nil
        }))
        #expect(finalReview.prompt.contains("Mira Voss"))
        #expect(finalReview.prompt.contains("unavailable after retry"))
        #expect(finalReview.prompt.contains("Engineering has a working vertical path"))
    }

    @Test
    func strategicReviewContinuesWhenEveryCompanyCheckInIsUnavailable() async throws {
        let provider = LiveTeamUtilityProvider(unavailablePersona: "ALL")
        let registry = AgentProviderRegistry(providers: [provider])
        let router = AgentLiveTeamRouter(providers: registry)
        let target = testTarget()

        let decision = try await router.reviewStrategy(
            strategicContext(target: target),
            configuration: LiveTeamOverseerConfiguration(
                target: target,
                instructions: "Keep executive control decisive."
            ),
            cwd: "/tmp/live-team-failed-staff-consultation"
        )
        #expect(decision.action == .keep)

        let requests = await provider.requests()
        #expect(requests.filter {
            $0.developerInstructions.contains("persisted named company person")
        }.count >= 2)
        #expect(requests.contains(where: {
            $0.outputSchema.objectValue?["properties"]?.objectValue?["action"] != nil
        }))
    }

    @Test
    func strategicReviewContinuesWhenTheIsolatedFocusGroupIsUnavailable() async throws {
        let provider = LiveTeamUtilityProvider(focusGroupUnavailable: true)
        let registry = AgentProviderRegistry(providers: [provider])
        let router = AgentLiveTeamRouter(providers: registry)
        let progressRecorder = LiveTeamReviewProgressRecorder()
        let target = testTarget()
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codeness-unavailable-focus-group.\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }

        let decision = try await router.reviewStrategy(
            strategicContext(target: target),
            configuration: LiveTeamOverseerConfiguration(
                target: target,
                instructions: "Keep executive control decisive."
            ),
            cwd: repository.path,
            progress: { progress in
                await progressRecorder.append(progress)
            }
        )

        #expect(decision.action == .keep)
        let progress = await progressRecorder.values()
        guard let firstProgress = progress.first,
              case .focusGroupCompleted(let report) = firstProgress else {
            Issue.record("An unavailable focus group must still finish before staff reports.")
            return
        }
        #expect(report.failure != nil)
        #expect(report.nextExperiment.contains("without waiting"))
        let reportPath = try #require(report.documentPath)
        #expect(FileManager.default.fileExists(
            atPath: repository.appendingPathComponent(reportPath).path
        ))
        let requests = await provider.requests()
        let staffRequests = requests.filter {
            $0.developerInstructions.contains("persisted named company person")
        }
        #expect(staffRequests.count == 2)
        #expect(staffRequests.allSatisfy {
            $0.prompt.contains("Continue product work without waiting")
        })
        #expect(requests.contains {
            $0.outputSchema.objectValue?["properties"]?.objectValue?["action"] != nil
                && $0.prompt.contains("Continue product work without waiting")
        })
    }

    @Test
    func strategicReviewKeepsAValidFocusGroupBeyondTheOldWordLimit() async throws {
        let provider = LiveTeamUtilityProvider(verboseFocusGroup: true)
        let registry = AgentProviderRegistry(providers: [provider])
        let router = AgentLiveTeamRouter(providers: registry)
        let progressRecorder = LiveTeamReviewProgressRecorder()
        let target = testTarget()
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codeness-verbose-focus-group.\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }

        let decision = try await router.reviewStrategy(
            strategicContext(target: target),
            configuration: LiveTeamOverseerConfiguration(
                target: target,
                instructions: "Keep executive control decisive."
            ),
            cwd: repository.path,
            progress: { progress in
                await progressRecorder.append(progress)
            }
        )

        #expect(decision.action == .keep)
        let progress = await progressRecorder.values()
        guard let firstProgress = progress.first,
              case .focusGroupCompleted(let report) = firstProgress else {
            Issue.record("A valid focus group must finish before staff reports.")
            return
        }
        #expect(report.failure == nil)
        #expect(report.participants.count == 4)
        let focusRequest = try #require(await provider.requests().first {
            $0.developerInstructions.contains("simulate a small focus group")
        })
        #expect(focusRequest.developerInstructions.contains("below 500 words"))
    }

    @Test
    func strategicReviewKeepsLongButValidStaffOpinions() async throws {
        let provider = LiveTeamUtilityProvider(verboseStaffReports: true)
        let registry = AgentProviderRegistry(providers: [provider])
        let router = AgentLiveTeamRouter(providers: registry)
        let progressRecorder = LiveTeamReviewProgressRecorder()
        let target = testTarget()

        _ = try await router.reviewStrategy(
            strategicContext(target: target),
            configuration: LiveTeamOverseerConfiguration(
                target: target,
                instructions: "Keep executive control decisive."
            ),
            cwd: "/tmp/repository",
            progress: { progress in
                await progressRecorder.append(progress)
            }
        )

        let consultations = await progressRecorder.values().compactMap {
            progress -> LiveTeamManagerConsultation? in
            guard case .consultationCompleted(_, let consultation) = progress else {
                return nil
            }
            return consultation
        }
        #expect(!consultations.isEmpty)
        #expect(consultations.allSatisfy {
            $0.status == .completed && $0.failure == nil
        })
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
        #expect(finalReview.prompt.contains("COMPANY CHECK-IN"))
        #expect(finalReview.prompt.contains("Mira Voss"))
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
        #expect(schemaUsesStrictObjectProperties(
            AgentLiveTeamRouter.companyDefinitionSchema(targetOptions: targetOptions)
        ))
        #expect(schemaUsesStrictObjectProperties(
            AgentLiveTeamRouter.companyStrategicSchema(targetOptions: targetOptions)
        ))
        #expect(schemaUsesStrictObjectProperties(AgentLiveTeamRouter.personaSchema))
        #expect(schemaUsesStrictObjectProperties(AgentLiveTeamRouter.coordinatorSchema))
        #expect(schemaUsesStrictObjectProperties(AgentLiveTeamRouter.completionSchema))
        #expect(schemaUsesStrictObjectProperties(AgentLiveTeamRouter.focusGroupSchema))
        #expect(schemaUsesStrictObjectProperties(AgentLiveTeamRouter.staffReportSchema))
        #expect(!schemaContainsKey(AgentLiveTeamRouter.focusGroupSchema, key: "maxLength"))
        #expect(!schemaContainsKey(AgentLiveTeamRouter.staffReportSchema, key: "maxLength"))
        #expect(!schemaContainsKey(AgentLiveTeamRouter.coordinatorSchema, key: "maxLength"))
        #expect(!schemaContainsKey(AgentLiveTeamRouter.personaSchema, key: "maxLength"))
        #expect(!schemaContainsKey(
            AgentLiveTeamRouter.companyDefinitionSchema(targetOptions: targetOptions),
            key: "maxLength"
        ))
        #expect(!schemaContainsKey(
            AgentLiveTeamRouter.companyStrategicSchema(targetOptions: targetOptions),
            key: "maxLength"
        ))
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
      "productBet": {
        "headline": "Ship the next unit",
        "valuePromise": "A user can exercise the next feature.",
        "audience": "People who need the next feature",
        "focusQuestion": "Would the intended audience choose this feature over the closest alternative?",
        "showcase": "An integrated feature demonstration",
        "integrationTarget": "The primary product surface",
        "killCondition": "Stop if it produces no visible value.",
        "fundingUnits": 4,
        "maximumTurns": 6
      },
      "members": [
        {
          "id": "deliver",
          "name": "Deliver",
          "instructions": "Implement the next reversible unit.",
          "targetID": "missing",
          "runPolicy": "once",
          "sessionPolicy": "ownMemory",
          "sharedGroupID": null,
          "positionID": "developer"
        }
      ],
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
      "productBet": null,
      "members": null,
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

private func schemaContainsKey(_ value: JSONValue, key: String) -> Bool {
    switch value {
    case .object(let object):
        return object[key] != nil || object.values.contains {
            schemaContainsKey($0, key: key)
        }
    case .array(let values):
        return values.contains { schemaContainsKey($0, key: key) }
    case .null, .bool, .integer, .number, .string:
        return false
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
    nonisolated let supportsLiveWebResearch = true
    private var utilityRequests: [AgentUtilityRequest] = []
    private var outputs: [String]
    private var personaNames: [String]
    private let consultationDelay: Duration
    private let unavailablePersona: String?
    private let focusGroupUnavailable: Bool
    private let verboseFocusGroup: Bool
    private let verboseStaffReports: Bool
    private var activeConsultations = 0
    private var maximumActiveConsultations = 0

    init(
        outputs: [String] = [],
        consultationDelay: Duration = .zero,
        unavailablePersona: String? = nil,
        focusGroupUnavailable: Bool = false,
        verboseFocusGroup: Bool = false,
        verboseStaffReports: Bool = false,
        personaNames: [String] = []
    ) {
        self.outputs = outputs
        self.consultationDelay = consultationDelay
        self.unavailablePersona = unavailablePersona
        self.focusGroupUnavailable = focusGroupUnavailable
        self.verboseFocusGroup = verboseFocusGroup
        self.verboseStaffReports = verboseStaffReports
        self.personaNames = personaNames
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
        if request.developerInstructions.contains("Create one memorable startup colleague") {
            let name: String
            if !personaNames.isEmpty {
                name = personaNames.removeFirst()
            } else if request.prompt.contains("Chief Executive") {
                name = "Rhea Calder"
            } else if request.prompt.contains("Developer") {
                name = "Eli Navarro"
            } else {
                name = "Mira Voss"
            }
            return AgentUtilityResult(output: """
            {
              "fullName": "\(name)",
              "background": "Built ambitious products with small teams.",
              "formativeSuccess": "Shipped a product customers immediately adopted.",
              "formativeScar": "Lost a year to cautious consensus and paperwork.",
              "convictions": [
                "Working product evidence beats status prose.",
                "Bold ideas earn trust by becoming usable.",
                "Mediocrity is an expensive choice."
              ],
              "personalStake": "Wants this company to create work people seek out.",
              "workingStyle": "Fast, visual, direct, and evidence hungry.",
              "conflictStyle": "Challenges weak assumptions without hiding disagreement.",
              "blindSpot": "Can underestimate final integration cost.",
              "evidenceThatChangesTheirMind": "A real user session or measured product failure."
            }
            """, tokenUsage: .init(totalTokens: 100, inputTokens: 80, outputTokens: 20))
        }
        if request.developerInstructions.contains("simulate a small focus group") {
            if focusGroupUnavailable {
                return AgentUtilityResult(output: "invalid focus group")
            }
            if verboseFocusGroup {
                let longText = Array(repeating: "evidence", count: 140)
                    .joined(separator: " ")
                return AgentUtilityResult(output: """
                {
                  "comparison": "\(longText)",
                  "comparisonReason": "\(longText)",
                  "sources": [],
                  "participants": [
                    {"archetype":"Newcomer","expectation":"\(longText)","choice":"currentProduct","reaction":"\(longText)"},
                    {"archetype":"Enthusiast","expectation":"\(longText)","choice":"comparison","reaction":"\(longText)"},
                    {"archetype":"Skeptic","expectation":"\(longText)","choice":"neither","reaction":"\(longText)"},
                    {"archetype":"Returning user","expectation":"\(longText)","choice":"currentProduct","reaction":"\(longText)"}
                  ],
                  "findings": ["\(longText)", "\(longText)"],
                  "verdict": "\(longText)",
                  "nextExperiment": "\(longText)",
                  "limitations": "\(longText)"
                }
                """)
            }
            return AgentUtilityResult(output: """
            {
              "comparison": "A close established alternative",
              "comparisonReason": "It serves the same audience need with a familiar interaction pattern.",
              "sources": [
                {
                  "title": "Current comparison product overview",
                  "url": "https://example.com/product",
                  "publishedAt": "2026-08-01",
                  "relevance": "Describes the current alternative and its user-facing interaction."
                },
                {
                  "title": "Recent user reactions",
                  "url": "https://example.com/reviews",
                  "publishedAt": "2026-08-10",
                  "relevance": "Shows what the audience praises and rejects."
                }
              ],
              "participants": [
                {
                  "archetype": "Curious newcomer",
                  "expectation": "Understand the value within a minute.",
                  "choice": "currentProduct",
                  "reaction": "The direct interaction makes the promise easier to grasp."
                },
                {
                  "archetype": "Experienced category user",
                  "expectation": "Familiar control with one memorable difference.",
                  "choice": "comparison",
                  "reaction": "The current evidence does not yet prove the distinctive interaction."
                },
                {
                  "archetype": "Time-poor user",
                  "expectation": "Reach useful value without setup work.",
                  "choice": "currentProduct",
                  "reaction": "The focused demonstration sounds faster to enter."
                },
                {
                  "archetype": "Skeptical enthusiast",
                  "expectation": "See a strong reason to switch.",
                  "choice": "neither",
                  "reaction": "Neither option proves a compelling repeat-use moment yet."
                }
              ],
              "findings": [
                "The current product promise is easier to understand than the alternative.",
                "The distinctive repeat-use moment still needs visible proof."
              ],
              "verdict": "The direction is credible, but the next product slice must make its distinctive value unmistakable.",
              "nextExperiment": "Build one complete repeat-use interaction and exercise it against the comparison expectation.",
              "limitations": "Participants are simulated from a bounded test card and two web sources."
            }
            """, tokenUsage: .init(totalTokens: 50, inputTokens: 35, outputTokens: 15))
        }
        if request.developerInstructions.contains("persisted named company person") {
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
               (unavailablePersona == "ALL"
                    || request.prompt.contains(
                        "WHO YOU ARE\n\(unavailablePersona)"
                    )) {
                return AgentUtilityResult(output: "invalid report")
            }
            if verboseStaffReports {
                let longOpinion = Array(
                    repeating: "I see real product progress and want the next useful version in people's hands.",
                    count: 18
                ).joined(separator: " ")
                return AgentUtilityResult(output: """
                {
                  "involvement": "essential",
                  "progress": "advancing",
                  "evidence": "\(longOpinion)",
                  "concern": "\(longOpinion)",
                  "nextMove": "\(longOpinion)"
                }
                """)
            }
            if request.prompt.contains("WHO YOU ARE\nMira Voss") {
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
              "productBet": null,
              "members": null,
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
          "productBet": {
            "headline": "Show one durable feature",
            "valuePromise": "A user can exercise the feature directly.",
            "audience": "People who need the feature",
            "focusQuestion": "Would the intended audience choose this feature over the closest alternative?",
            "showcase": "A working integrated feature demonstration",
            "integrationTarget": "The repository's primary product surface",
            "killCondition": "Stop if the exercised feature does not create user value.",
            "fundingUnits": 4,
            "maximumTurns": 6
          },
          "members": [
            {
              "id": "deliver",
              "name": "Deliver",
              "instructions": "Implement one bounded unit, test it, and stop with evidence.",
              "targetID": "primary",
              "runPolicy": "everyCycle",
              "sessionPolicy": "ownMemory",
              "sharedGroupID": null,
              "positionID": "developer",
              "contributionKind": "softwareImplementation",
              "requiredCapabilities": ["workspaceRead", "sourceModification", "commandExecution"],
              "acceptanceEvidence": "The bounded behavior works and focused tests pass.",
              "dependencyContributionKinds": ["productDirection"],
              "stopCondition": "Stop after focused verification or report a capability block."
            }
          ],
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
        currentDefinition: companyLiveTeamDefinition(),
        coordinatorHandoff: "The current agents finished their work.",
        recentEvidence: [],
        editHistory: [],
        targetOptions: [
            LiveTeamTargetOption(id: "primary", label: "Primary", target: target)
        ],
        triggerReason: "The current agents are exhausted."
    )
}

private func companyLiveTeamDefinition() -> LiveTeamDefinition {
    let target = testTarget()
    let chiefExecutive = testCompanyPerson(
        name: "Rhea Calder",
        positionID: .chiefExecutive,
        assignment: "Own the goal and invest in the highest-return product bet."
    )
    let artDirector = testCompanyPerson(
        name: "Mira Voss",
        positionID: .artDirector,
        assignment: "Make the experience distinctive and immediately visible."
    )
    let developer = testCompanyPerson(
        name: "Eli Navarro",
        positionID: .developer,
        assignment: "Build and exercise the integrated product slice."
    )
    return LiveTeamDefinition(
        revision: 2,
        workingGoal: "Ship and exercise an integrated product slice.",
        members: [
            LiveTeamMember(
                id: "art",
                name: "Make It Distinctive",
                instructions: artDirector.assignment,
                target: target,
                runPolicy: .once,
                sessionPolicy: .ownMemory,
                positionID: .artDirector,
                person: artDirector,
                companyAssignment: CompanyAssignmentContract(
                    contributionKind: .visualDirection,
                    requiredCapabilities: [.workspaceRead, .authoredArtifactWrite],
                    acceptanceEvidence: "A distinct visual direction is inspectable.",
                    dependencyContributionKinds: [.productDirection, .softwareImplementation],
                    stopCondition: "Stop when the direction is decision-ready or blocked."
                )
            ),
            LiveTeamMember(
                id: "build",
                name: "Ship Product Slice",
                instructions: developer.assignment,
                target: target,
                runPolicy: .everyCycle,
                sessionPolicy: .ownMemory,
                positionID: .developer,
                person: developer,
                companyAssignment: CompanyAssignmentContract(
                    contributionKind: .softwareImplementation,
                    requiredCapabilities: [.workspaceRead, .sourceModification, .commandExecution],
                    acceptanceEvidence: "The integrated slice works and focused tests pass.",
                    dependencyContributionKinds: [.visualDirection, .productDirection],
                    stopCondition: "Stop after focused verification or report a capability block."
                )
            )
        ],
        coordinator: .init(target: target, instructions: "Route direct product work."),
        strategicReason: "The smallest team that can create an integrated demonstration.",
        operatingModelVersion: 2,
        overseerPerson: chiefExecutive,
        productBet: CompanyProductBet(
            headline: "Show the real product",
            valuePromise: "A user can experience the core value directly.",
            showcase: "An integrated, runnable demonstration",
            integrationTarget: "The repository's main product surface",
            killCondition: "Stop if two exercised slices fail to produce visible value."
        )
    )
}

private func testCompanyPerson(
    name: String,
    positionID: CompanyPositionID,
    assignment: String
) -> CompanyPerson {
    CompanyPerson(
        positionID: positionID,
        profile: CompanyPersonaProfile(
            fullName: name,
            background: "Built ambitious products with small teams.",
            formativeSuccess: "Shipped a product customers immediately adopted.",
            formativeScar: "Lost a year to cautious consensus and paperwork.",
            convictions: [
                "Working product evidence beats status prose.",
                "Bold ideas earn trust by becoming usable.",
                "Mediocrity is an expensive choice."
            ],
            personalStake: "Wants this company to create work people actively seek out.",
            workingStyle: "Fast, visual, direct, and evidence hungry.",
            conflictStyle: "Challenges weak assumptions without hiding disagreement.",
            blindSpot: "Can underestimate the final integration cost.",
            evidenceThatChangesTheirMind: "A real user session or measured product failure.",
            ingredients: CompanyPersonaIngredients(
                spark: "A risky launch that worked",
                riskPosture: "bold reversible bets",
                conflictStyle: "direct and energetic",
                craftObsession: "delight visible in seconds",
                ambition: "build the reference product"
            )
        ),
        assignment: assignment
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
