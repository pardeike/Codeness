import Foundation
import Testing
@testable import CodenessCore

@MainActor
struct LiveTeamCoordinatorIntegrationTests {
    @Test
    func liveTeamRuntimeRefreshesWithoutRepositoryModelPresets() async throws {
        let fixture = try makeFixture(goal: "Use Terra for the whole team.")
        defer { fixture.remove() }
        let terraModel = "gpt-5.6-terra"
        try await fixture.store.save(RepositoryRecord(canonicalPath: fixture.canonicalPath))
        let terraTarget = liveTarget(model: terraModel)
        let definition = LiveTeamDefinition(
            revision: 1,
            workingGoal: "Deliver with the Board-approved model.",
            members: [
                LiveTeamMember(
                    id: "deliver",
                    name: "Deliver",
                    instructions: "Deliver one bounded result and stop with evidence.",
                    target: terraTarget,
                    runPolicy: .everyCycle,
                    sessionPolicy: .ownMemory
                )
            ],
            coordinator: .init(
                target: terraTarget,
                instructions: "Route local work without changing strategy."
            ),
            strategicReason: "One Terra member is sufficient."
        )
        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.completionCandidate)
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal
        )
        let runtimeProvider: @MainActor @Sendable (RepositorySettings) ->
            LiveTeamRuntimeConfiguration = { _ in
                liveRuntimeConfiguration(model: terraModel)
            }
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer,
            runtimeProvider: runtimeProvider
        )

        await coordinator.load()
        await coordinator.startActivity(goal: fixture.goal)
        try await waitUntil { coordinator.record.activity?.status == .completed }

        #expect(await overseer.bootstrapConfigurations().first?.target.model == terraModel)
        #expect(
            await overseer.recordedBootstrapContexts().first?.targetOptions
                .allSatisfy { $0.target.model == terraModel } == true
        )
        #expect(await provider.runRequests().allSatisfy { $0.target.model == terraModel })
        #expect(
            await coordinatorRouter.contexts().first?.definition.coordinator.target.model
                == terraModel
        )
    }

    @Test
    func existingActivityUsesCurrentOverseerPolicyWithItsChosenTarget() async throws {
        let fixture = try makeFixture(goal: "Keep executive control current.")
        defer { fixture.remove() }
        var deliver = liveMember(id: "deliver", sessionPolicy: .ownMemory)
        deliver.runPolicy = .once
        let definition = liveDefinition(members: [deliver])
        let checkpoint = try #require(LiveTeamStateMachine.initialCheckpoint(for: definition))
        let staleTarget = liveTarget(model: "stale-overseer-model")
        let reviewRequest = LiveTeamOverseerRequest(
            mode: .strategicReview,
            reason: "Resume with the installed executive policy.",
            continuation: checkpoint,
            automatic: false
        )
        var record = RepositoryRecord(canonicalPath: fixture.canonicalPath)
        record.activity = ActivityRecord(
            goal: fixture.goal,
            prompts: .builtInDefaults,
            status: .paused,
            liveTeam: LiveTeamState(
                overseer: LiveTeamOverseerConfiguration(
                    target: staleTarget,
                    instructions: "Obsolete saved policy that asks the user for permission."
                ),
                currentDefinition: definition,
                checkpoint: checkpoint,
                resumeCheckpoint: .invokeOverseer(reviewRequest)
            )
        )
        try await fixture.store.save(record)

        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.completionCandidate)
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal
        )
        let runtime: LiveTeamRuntimeConfiguration = {
            var configuration = liveRuntimeConfiguration(model: "current-default-model")
            configuration.overseer.instructions = "Current decisive executive policy."
            return configuration
        }()
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer,
            runtimeProvider: { _ in runtime }
        )

        await coordinator.load()
        await coordinator.resume()
        try await waitUntil { coordinator.record.activity?.status == .completed }

        let configurations = await overseer.strategicConfigurations()
        #expect(configurations.count == 2)
        #expect(configurations.allSatisfy {
            $0.instructions == "Current decisive executive policy."
                && $0.target == staleTarget
        })
        let persisted = try await fixture.store.load(canonicalPath: fixture.canonicalPath)
        #expect(
            persisted.activity?.liveTeam?.overseer
                == LiveTeamOverseerConfiguration(
                    target: staleTarget,
                    instructions: "Current decisive executive policy."
                )
        )
    }

    @Test
    func goalOnlyBootstrapPersistsBothDurabilityBarriersAndRequiresOverseerCompletion() async throws {
        let fixture = try makeFixture(goal: "Board-only goal: ship the durable result.")
        defer { fixture.remove() }
        let definition = liveDefinition(members: [
            liveMember(id: "deliver", sessionPolicy: .ownMemory)
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.completionCandidate, evidence: "The bounded result is validated.")
        ])
        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()
        await coordinator.startActivity(goal: fixture.goal)
        try await waitUntil { coordinator.record.activity?.status == .completed }
        try await waitUntilAsync { await provider.releasedSessionIDs().count == 1 }

        #expect(await overseer.sawDurableGoalOnlyBootstrap())
        #expect(await provider.preparationFollowedDurableRevision() == [true])
        #expect(await overseer.bootstrapCount() == 1)
        #expect(await overseer.completionReviewCount() == 0)
        #expect(await coordinatorRouter.routeCount() == 1)

        let activity = try #require(coordinator.record.activity)
        #expect(activity.goal == fixture.goal)
        #expect(activity.liveTeam?.currentDefinition == definition)
        #expect(activity.liveTeam?.resumeCheckpoint == nil)
        #expect(activity.runs.count == 1)
        #expect(activity.runs[0].status == .completed)
        #expect(activity.runs[0].liveTeamMember?.workingGoal == definition.workingGoal)
        #expect(!activity.runs[0].prompt.contains(fixture.goal))
        #expect(activity.runs[0].coordinatorDecision?.disposition == .completionCandidate)

        let coordinatorContexts = await coordinatorRouter.contexts()
        #expect(coordinatorContexts.map(\.workingGoal) == [definition.workingGoal])
        #expect(coordinatorContexts[0].sourceResult == "Worker result 1")
        let strategicContexts = await overseer.recordedStrategicContexts()
        #expect(strategicContexts.count == 1)
        #expect(strategicContexts.first?.userGoal == fixture.goal)
        #expect(strategicContexts.first?.currentDefinition == definition)
        #expect(strategicContexts.first?.triggerReason.contains("no agents may be needed") == true)

        let persisted = try await fixture.store.load(canonicalPath: fixture.canonicalPath)
        #expect(persisted.activity?.status == .completed)
        #expect(persisted.activity?.liveTeam?.currentDefinition == definition)
        #expect(await provider.releasedSessionIDs() == ["codex-session-1"])
    }

    @Test
    func resumeContinuesRemainingSameRoundAgentBeforeCompletionReview() async throws {
        let fixture = try makeFixture(goal: "Build and independently review one result.")
        defer { fixture.remove() }
        var build = liveMember(id: "build", sessionPolicy: .ownMemory)
        build.runPolicy = .once
        var review = liveMember(id: "review", sessionPolicy: .freshEveryRun)
        review.runPolicy = .once
        let definition = liveDefinition(members: [build, review])
        let gate = FirstRunGate()
        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            firstRunGate: gate
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.completionCandidate),
            decision(.completionCandidate)
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()
        await coordinator.startActivity(goal: fixture.goal)
        await gate.waitUntilBlocked()
        coordinator.setPauseAfterCurrent(true)
        await gate.release()
        try await waitUntil { coordinator.record.activity?.status == .paused }

        #expect(await provider.runRequests().count == 1)
        #expect(await overseer.recordedStrategicContexts().isEmpty)
        guard case .perform(let resumeCheckpoint)? =
            coordinator.record.activity?.liveTeam?.resumeCheckpoint else {
            Issue.record("Resume did not preserve the remaining same-round agent.")
            return
        }
        #expect(resumeCheckpoint.memberID == "review")

        await coordinator.resume()
        try await waitUntil { coordinator.record.activity?.status == .completed }

        let activity = try #require(coordinator.record.activity)
        #expect(activity.runs.map { $0.liveTeamMember?.member.id } == ["build", "review"])
        #expect(await coordinatorRouter.routeCount() == 2)
        #expect(await overseer.recordedStrategicContexts().count == 1)
        #expect(activity.liveTeam?.reviews.count == 1)
    }

    @Test
    func coordinatorPauseRecommendationCannotStopWithoutOverseerApproval() async throws {
        let fixture = try makeFixture(goal: "Continue unless the fixed goal requires me.")
        defer { fixture.remove() }
        let definition = liveDefinition(members: [
            liveMember(id: "deliver", sessionPolicy: .ownMemory)
        ])
        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.pause, evidence: "The local result suggests asking the user."),
            decision(.completionCandidate)
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()
        await coordinator.startActivity(goal: fixture.goal)
        try await waitUntil { coordinator.record.activity?.status == .completed }

        let activity = try #require(coordinator.record.activity)
        #expect(activity.runs.count == 2)
        #expect(activity.runs.allSatisfy { $0.status == .completed })
        #expect(activity.runs[0].coordinatorDecision?.disposition == .pause)
        #expect(await coordinatorRouter.routeCount() == 2)
        let reviews = await overseer.recordedStrategicContexts()
        #expect(reviews.count == 2)
        #expect(reviews[0].userGoal == fixture.goal)
        #expect(reviews[0].triggerReason.contains("older work-routing action"))
        #expect(reviews[1].triggerReason.contains("no agents may be needed"))
        let reviewRecords = try #require(activity.liveTeam?.reviews)
        #expect(reviewRecords.count == 2)
        #expect(reviewRecords.allSatisfy { $0.status == .completed })
        #expect(reviewRecords.allSatisfy { $0.focusGroup?.participants.count == 4 })
        #expect(reviewRecords.allSatisfy { $0.consultations.count == 2 })
        #expect(reviewRecords.allSatisfy {
            $0.consultations.allSatisfy { $0.status == .completed }
        })
        #expect(reviewRecords.map { $0.decision?.outcome } == [.kept, .completed])

        let persisted = try await fixture.store.load(canonicalPath: fixture.canonicalPath)
        #expect(persisted.activity?.liveTeam?.reviews == reviewRecords)
    }

    @Test
    func ownSharedAndFreshMemoryPoliciesProduceDifferentProviderLifetimes() async throws {
        let own = try await runSessionScenario(members: [
            liveMember(id: "deliver", sessionPolicy: .ownMemory)
        ])
        #expect(own.existingSessionIDs == [nil, "codex-session-1"])
        #expect(own.preparedSessionIDs == ["codex-session-1", "codex-session-1"])
        #expect(own.releasedSessionIDs == ["codex-session-1"])

        let shared = try await runSessionScenario(members: [
            liveMember(
                id: "implement",
                instructions: "Implement one bounded unit.",
                sessionPolicy: .sharedMemory(groupID: "delivery")
            ),
            liveMember(
                id: "review",
                instructions: "Review the bounded unit.",
                sessionPolicy: .sharedMemory(groupID: "delivery")
            )
        ])
        #expect(shared.existingSessionIDs == [nil, "codex-session-1"])
        #expect(shared.preparedSessionIDs == ["codex-session-1", "codex-session-1"])
        #expect(shared.releasedSessionIDs == ["codex-session-1"])

        let fresh = try await runSessionScenario(members: [
            liveMember(id: "inspect", sessionPolicy: .freshEveryRun)
        ])
        #expect(fresh.existingSessionIDs == [nil, nil])
        #expect(fresh.preparedSessionIDs == ["codex-session-1", "codex-session-2"])
        #expect(fresh.releasedSessionIDs == ["codex-session-1", "codex-session-2"])
    }

    @Test
    func pausedPrebootstrapGoalAmendmentUpdatesBootstrapWithoutStartingReview() async throws {
        let fixture = try makeFixture(goal: "Create the first company.")
        defer { fixture.remove() }
        let bootstrapRequest = LiveTeamOverseerRequest(
            mode: .bootstrap,
            reason: "Create the first working goal and agents for the user's goal.",
            automatic: false
        )
        try await fixture.store.save(RepositoryRecord(
            canonicalPath: fixture.canonicalPath,
            activity: ActivityRecord(
                goal: fixture.goal,
                prompts: .builtInDefaults,
                status: .paused,
                liveTeam: LiveTeamState(
                    overseer: liveRuntimeConfiguration().overseer,
                    resumeCheckpoint: .invokeOverseer(bootstrapRequest)
                )
            )
        ))
        let definition = liveDefinition(members: [
            liveMember(id: "deliver", sessionPolicy: .ownMemory)
        ])
        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )
        await coordinator.load()

        let amendedGoal = "Create the first company from the clearer goal."
        #expect(await coordinator.amendGoal(amendedGoal))

        let activity = try #require(coordinator.record.activity)
        #expect(activity.goal == amendedGoal)
        #expect(activity.status == .paused)
        #expect(activity.goalAmendments.count == 1)
        #expect(activity.liveTeam?.resumeCheckpoint == .invokeOverseer(bootstrapRequest))
        #expect(activity.liveTeam?.reviews.isEmpty == true)
        #expect(activity.liveTeam?.boardGoalAmendmentPendingReview == false)
        #expect(await overseer.bootstrapCount() == 0)
        #expect(await overseer.recordedStrategicContexts().isEmpty)

        let persisted = try await fixture.store.load(canonicalPath: fixture.canonicalPath)
        #expect(persisted.activity == activity)
    }

    @Test
    func boardGoalAmendmentDuringMemberTurnQueuesStrategicReviewAtBoundary() async throws {
        let fixture = try makeFixture(goal: "Keep the initial Board goal.")
        defer { fixture.remove() }
        let definition = liveDefinition(members: [
            liveMember(id: "deliver", sessionPolicy: .ownMemory)
        ])
        let gate = FirstRunGate()
        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            firstRunGate: gate
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.continueTeam),
            decision(.completionCandidate)
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()
        await coordinator.startActivity(goal: fixture.goal)
        await gate.waitUntilBlocked()

        let amendedGoal = "Use the amended Board goal at the next safe boundary."
        #expect(await coordinator.amendGoal(amendedGoal))
        #expect(coordinator.record.activity?.pendingGoalAmendment?.revisedGoal == amendedGoal)

        await gate.release()
        try await waitUntil { coordinator.record.activity?.status == .completed }

        let strategicContexts = await overseer.recordedStrategicContexts()
        #expect(strategicContexts.count == 2)
        #expect(strategicContexts.first?.userGoal == amendedGoal)
        #expect(coordinator.record.activity?.goal == amendedGoal)
        #expect(coordinator.record.activity?.goalAmendments.count == 1)
        #expect(await provider.runRequests().allSatisfy { !$0.prompt.contains(amendedGoal) })
    }

    @Test
    func pauseAfterCurrentDefersCoordinatorRequestedReviewUntilResume() async throws {
        let fixture = try makeFixture(goal: "Pause before the next control action.")
        defer { fixture.remove() }
        let definition = liveDefinition(members: [
            liveMember(id: "deliver", sessionPolicy: .ownMemory)
        ])
        let gate = FirstRunGate()
        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            firstRunGate: gate
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.requestOversight, evidence: "The next action needs a strategy change."),
            decision(.completionCandidate)
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()
        await coordinator.startActivity(goal: fixture.goal)
        await gate.waitUntilBlocked()
        let reviewDateBeforePause = coordinator.record.activity?.liveTeam?.lastStrategicReviewAt

        coordinator.setPauseAfterCurrent(true)
        await gate.release()
        try await waitUntil { coordinator.record.activity?.status == .paused }

        #expect(await overseer.recordedStrategicContexts().isEmpty)
        #expect(coordinator.statusMessage == "Paused before investment review")
        #expect(
            coordinator.record.activity?.liveTeam?.lastStrategicReviewAt
                == reviewDateBeforePause
        )
        guard case .invokeOverseer(let request)? =
            coordinator.record.activity?.liveTeam?.resumeCheckpoint else {
            Issue.record("Pause did not preserve the requested Overseer review.")
            return
        }
        #expect(request.reason == "The next action needs a strategy change.")

        await coordinator.resume()
        try await waitUntil { coordinator.record.activity?.status == .completed }

        #expect(await overseer.recordedStrategicContexts().count == 2)
        #expect(await provider.runRequests().count == 2)
    }

    @Test
    func productCompanyResumesDirectWorkWithoutReviewUntilInvestmentBoundary() async throws {
        let fixture = try makeFixture(
            goal: "Keep building product value until the funded boundary."
        )
        defer { fixture.remove() }
        let definition = companyLiveDefinition(maximumTurns: 6)
        let gate = FirstRunGate()
        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            firstRunGate: gate
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal,
            strategicDecision: LiveTeamStrategicDecision(
                action: .complete,
                reason: "The funded demonstration satisfies the fixed goal.",
                evidence: "Six direct product turns produced durable product evidence."
            )
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()
        await coordinator.startActivity(goal: fixture.goal)
        await gate.waitUntilBlocked()
        coordinator.setPauseAfterCurrent(true)
        await gate.release()
        try await waitUntil { coordinator.record.activity?.status == .paused }

        #expect(await provider.runRequests().count == 1)
        #expect(await coordinatorRouter.routeCount() == 0)
        #expect(await overseer.recordedStrategicContexts().isEmpty)
        #expect(
            coordinator.record.activity?.liveTeam?.currentDefinition?.members.first?
                .person?.experience.contains(where: {
                    $0.detail.contains("Worker result 1")
                }) == true
        )
        guard case .perform? = coordinator.record.activity?.liveTeam?.resumeCheckpoint else {
            Issue.record("Pause did not preserve the next direct product assignment.")
            return
        }

        await coordinator.resume()
        try await waitUntil { coordinator.record.activity?.status == .completed }

        #expect(await provider.runRequests().count == 6)
        #expect(await coordinatorRouter.routeCount() == 0)
        #expect(await overseer.recordedStrategicContexts().count == 1)
        #expect(coordinator.record.activity?.liveTeam?.reviews.count == 1)
    }

    @Test
    func automaticRevisionOfExhaustedTeamDoesNotPauseForChurnGuard() async throws {
        let fixture = try makeFixture(goal: "Continue autonomously through bounded stages.")
        defer { fixture.remove() }
        var audit = liveMember(id: "audit", sessionPolicy: .freshEveryRun)
        audit.runPolicy = .once
        let current = LiveTeamDefinition(
            revision: 2,
            workingGoal: "Audit the current bounded stage.",
            members: [audit],
            coordinator: liveCoordinatorConfiguration(),
            strategicReason: "The current stage needs one independent audit."
        )
        var correction = liveMember(id: "correction", sessionPolicy: .ownMemory)
        correction.runPolicy = .once
        let proposed = LiveTeamDefinition(
            revision: 3,
            workingGoal: "Correct the bounded findings.",
            members: [correction],
            coordinator: liveCoordinatorConfiguration(),
            strategicReason: "The completed audit found a bounded correction stage."
        )
        let checkpoint = LiveTeamCheckpoint(
            memberID: audit.id,
            cycle: 1,
            revision: current.revision
        )
        var record = RepositoryRecord(canonicalPath: fixture.canonicalPath)
        record.activity = ActivityRecord(
            goal: fixture.goal,
            prompts: .builtInDefaults,
            status: .paused,
            liveTeam: LiveTeamState(
                overseer: liveOverseerConfiguration(),
                currentDefinition: current,
                checkpoint: checkpoint,
                resumeCheckpoint: .perform(checkpoint),
                cyclesUnderCurrentRevision: 0
            )
        )
        try await fixture.store.save(record)

        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.requestOversight, evidence: "The audit found bounded fixes."),
            decision(.completionCandidate)
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: current,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal,
            strategicDecision: LiveTeamStrategicDecision(
                action: .revise,
                reason: proposed.strategicReason,
                evidence: "The existing Once agent is complete, so another current turn cannot run.",
                proposedDefinition: proposed,
                preferredNextMemberID: correction.id
            )
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()
        await coordinator.resume()
        try await waitUntil { coordinator.record.activity?.status == .completed }

        #expect(
            coordinator.record.activity?.runs.compactMap(\.liveTeamMember?.member.id)
                == [audit.id, correction.id]
        )
        #expect(coordinator.record.activity?.liveTeam?.currentDefinition == proposed)
        #expect(await overseer.recordedStrategicContexts().count == 2)
    }

    @Test
    func exhaustedReplacementPreservesOverseerRetryCheckpoint() async throws {
        let fixture = try makeFixture(goal: "Continue until an eligible stage is available.")
        defer { fixture.remove() }
        var audit = liveMember(id: "audit", sessionPolicy: .freshEveryRun)
        audit.runPolicy = .once
        let current = LiveTeamDefinition(
            revision: 2,
            workingGoal: "Audit the current bounded stage.",
            members: [audit],
            coordinator: liveCoordinatorConfiguration(),
            strategicReason: "The current stage needs one independent audit."
        )
        var unchangedAudit = audit
        unchangedAudit.sessionPolicy = .ownMemory
        let ineffective = LiveTeamDefinition(
            revision: 3,
            workingGoal: current.workingGoal,
            members: [unchangedAudit],
            coordinator: liveCoordinatorConfiguration(),
            strategicReason: "Reuse the completed audit with a different memory policy."
        )
        let checkpoint = LiveTeamCheckpoint(
            memberID: audit.id,
            cycle: 1,
            revision: current.revision
        )
        var record = RepositoryRecord(canonicalPath: fixture.canonicalPath)
        record.activity = ActivityRecord(
            goal: fixture.goal,
            prompts: .builtInDefaults,
            status: .paused,
            liveTeam: LiveTeamState(
                overseer: liveOverseerConfiguration(),
                currentDefinition: current,
                checkpoint: checkpoint,
                resumeCheckpoint: .perform(checkpoint),
                cyclesUnderCurrentRevision: 0
            )
        )
        try await fixture.store.save(record)

        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.requestOversight, evidence: "The audit finished its Once assignment.")
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: current,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal,
            strategicDecision: LiveTeamStrategicDecision(
                action: .revise,
                reason: ineffective.strategicReason,
                evidence: "The replacement leaves the completed Once assignment unchanged.",
                proposedDefinition: ineffective,
                preferredNextMemberID: audit.id
            )
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()
        await coordinator.resume()
        try await waitUntilAsync {
            await overseer.recordedStrategicContexts().count == 1
        }
        try await waitUntil { coordinator.record.activity?.status == .paused }

        #expect(coordinator.record.activity?.liveTeam?.currentDefinition?.revision == 3)
        #expect(coordinator.record.activity?.runs.count == 1)
        guard case .invokeOverseer(let retry)? =
            coordinator.record.activity?.liveTeam?.resumeCheckpoint else {
            Issue.record("The exhausted replacement did not preserve an Overseer retry.")
            return
        }
        #expect(retry.reason.contains("no eligible agent"))
        #expect(coordinator.canResume)

        await coordinator.resume()
        try await waitUntilAsync {
            await overseer.recordedStrategicContexts().count == 2
        }
        try await waitUntil { coordinator.record.activity?.status == .paused }

        #expect(coordinator.record.activity?.runs.count == 1)
        guard case .invokeOverseer? =
            coordinator.record.activity?.liveTeam?.resumeCheckpoint else {
            Issue.record("Retrying the exhausted replacement lost its Overseer checkpoint.")
            return
        }
    }

    @Test
    func successfulSteeringIsRecordedInTheActiveTurnTranscript() async throws {
        let fixture = try makeFixture(goal: "Deliver the fixed user goal.")
        defer { fixture.remove() }
        let definition = liveDefinition(members: [
            liveMember(id: "deliver", sessionPolicy: .ownMemory)
        ])
        let gate = FirstRunGate()
        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            firstRunGate: gate
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.completionCandidate)
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()
        await coordinator.startActivity(goal: fixture.goal)
        await gate.waitUntilBlocked()
        defer { Task { await gate.release() } }

        let message = "Prioritize the native interaction proof."
        #expect(await coordinator.steer(message))
        try await waitUntil {
            guard let run = coordinator.record.activity?.runs.first else { return false }
            return RunTranscriptPresentation.content(
                for: run,
                separatesRuns: true
            ).text.contains(message)
        }

        let run = try #require(coordinator.record.activity?.runs.first)
        let presented = RunTranscriptPresentation.content(
            for: run,
            separatesRuns: true
        )
        #expect(presented.text.contains("You steered\n\(message)"))
        #expect(presented.steeringRanges.count == 1)

        await gate.release()
        try await waitUntil { coordinator.record.activity?.status == .completed }
    }

    @Test
    func interruptedMemberRecoversFromPersistedSnapshotWithoutReinterpretingTheTeam() async throws {
        let fixture = try makeFixture(goal: "Recover the fixed Board goal.")
        defer { fixture.remove() }
        let member = liveMember(id: "deliver", sessionPolicy: .ownMemory)
        let definition = liveDefinition(members: [member])
        let snapshot = LiveTeamMemberSnapshot(
            member: member,
            workingGoal: definition.workingGoal,
            revision: 1,
            cycle: 1,
            sessionSlotID: "member:deliver"
        )
        let interruptedRun = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .running,
            threadID: "codex-session-stale",
            turnID: "codex-execution-stale",
            model: member.target.model,
            effort: member.target.options.effort ?? "",
            prompt: "Original immutable member assignment.",
            agentTarget: member.target,
            sessionLineage: 0,
            liveTeamMember: snapshot
        )
        var record = RepositoryRecord(canonicalPath: fixture.canonicalPath)
        record.activity = ActivityRecord(
            goal: fixture.goal,
            prompts: .builtInDefaults,
            status: .running,
            runs: [interruptedRun],
            stepSessions: [
                "member:deliver": WorkflowSessionState(
                    stepID: "member:deliver",
                    target: member.target,
                    providerSessionID: "codex-session-stale"
                )
            ],
            liveTeam: LiveTeamState(
                overseer: liveOverseerConfiguration(),
                currentDefinition: definition,
                checkpoint: .init(memberID: member.id, cycle: 1, revision: 1),
                resumeCheckpoint: .recoverRun(interruptedRun.id)
            )
        )
        try await fixture.store.save(record)

        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.completionCandidate)
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()
        #expect(coordinator.record.activity?.status == .paused)
        #expect(coordinator.record.activity?.runs[0].status == .interrupted)
        #expect(
            coordinator.record.activity?.liveTeam?.resumeCheckpoint
                == .recoverRun(interruptedRun.id)
        )

        await coordinator.resume()
        try await waitUntil { coordinator.record.activity?.status == .completed }

        let runs = try #require(coordinator.record.activity?.runs)
        #expect(runs.count == 2)
        #expect(runs[1].liveTeamMember == snapshot)
        let recoveredRequest = try #require(await provider.runRequests().first)
        #expect(recoveredRequest.prompt.contains("INTERRUPTED MEMBER RECOVERY"))
        #expect(recoveredRequest.prompt.contains("Original immutable member assignment."))
        #expect(await provider.existingSessionIDs() == ["codex-session-stale"])
        #expect(await provider.preparedSessionIDs() == ["codex-session-stale"])
    }

    @Test
    func olderCoordinatorPauseResumesThroughOverseerAuthority() async throws {
        let fixture = try makeFixture(goal: "Only strategic control may pause this work.")
        defer { fixture.remove() }
        let member = liveMember(id: "deliver", sessionPolicy: .ownMemory)
        let definition = liveDefinition(members: [member])
        let checkpoint = LiveTeamCheckpoint(memberID: member.id, cycle: 1, revision: 1)
        let snapshot = LiveTeamMemberSnapshot(
            member: member,
            workingGoal: definition.workingGoal,
            revision: 1,
            cycle: 1,
            sessionSlotID: "member:deliver"
        )
        let pauseDecision = decision(
            .pause,
            evidence: "The released local router asked for user direction."
        )
        let pausedRun = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .paused,
            threadID: "codex-session-1",
            model: member.target.model,
            effort: member.target.options.effort ?? "",
            prompt: "Original immutable member assignment.",
            finalOutput: "Durable local result",
            relayError: pauseDecision.evidence,
            completedAt: .now,
            agentTarget: member.target,
            sessionLineage: 1,
            liveTeamMember: snapshot,
            coordinatorDecision: pauseDecision
        )
        var record = RepositoryRecord(canonicalPath: fixture.canonicalPath)
        record.activity = ActivityRecord(
            goal: fixture.goal,
            prompts: .builtInDefaults,
            status: .paused,
            runs: [pausedRun],
            liveTeam: LiveTeamState(
                overseer: liveOverseerConfiguration(),
                currentDefinition: definition,
                checkpoint: checkpoint,
                resumeCheckpoint: .perform(checkpoint),
                coordinatorHandoff: pauseDecision.handoff,
                lastCoordinatorDecision: pauseDecision,
                memberFailureCounts: [member.id: 1]
            )
        )
        try await fixture.store.save(record)

        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.completionCandidate)
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()

        #expect(coordinator.record.activity?.runs[0].status == .completed)
        #expect(coordinator.record.activity?.runs[0].relayError == nil)
        #expect(
            coordinator.record.activity?.liveTeam?.resumeCheckpoint
                == .applyCoordinatorDecision(pausedRun.id)
        )
        #expect(coordinator.record.activity?.liveTeam?.memberFailureCounts[member.id] == nil)

        await coordinator.resume()
        try await waitUntil { coordinator.record.activity?.status == .completed }

        #expect(await overseer.recordedStrategicContexts().count == 2)
        #expect(coordinator.record.activity?.runs.count == 2)
        #expect(await coordinatorRouter.routeCount() == 1)
    }

    @Test
    func earlierFixedActivityConvertsAutomaticallyAndPreservesOnlyCompatibleOwnMemory() async throws {
        let fixture = try makeFixture(goal: "Keep the legacy Board goal.")
        defer { fixture.remove() }
        let target = liveTarget()
        let legacyStep = WorkflowStep(
            id: "deliver",
            name: "Deliver",
            section: .loop,
            instructions: "Implement one bounded unit.",
            target: target
        )
        let workflow = WorkflowTemplate(
            id: "legacy",
            name: "Legacy Plan Code Review",
            summary: "Legacy workflow",
            steps: [legacyStep],
            coordinator: WorkflowCoordinatorConfiguration(
                target: target,
                instructions: "Route the old loop."
            )
        )
        let migratedDefinition = liveDefinition(members: [
            liveMember(
                id: legacyStep.id,
                instructions: legacyStep.instructions,
                sessionPolicy: .ownMemory
            )
        ])
        var record = RepositoryRecord(canonicalPath: fixture.canonicalPath)
        record.activity = ActivityRecord(
            goal: fixture.goal,
            prompts: .builtInDefaults,
            status: .paused,
            workflow: workflow,
            workflowCursor: .init(section: .loop, stepIndex: 0),
            workflowResumeCheckpoint: .perform(.init(section: .loop, stepIndex: 0)),
            stepSessions: [
                legacyStep.id: WorkflowSessionState(
                    stepID: legacyStep.id,
                    lineage: 2,
                    target: target,
                    providerSessionID: "codex-legacy-session"
                )
            ]
        )
        try await fixture.store.save(record)

        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [])
        let overseer = RecordingLiveTeamOverseer(
            definition: migratedDefinition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()

        let activity = try #require(coordinator.record.activity)
        #expect(activity.status == .paused)
        #expect(activity.workflow == nil)
        #expect(activity.liveTeam?.currentDefinition == migratedDefinition)
        #expect(activity.stepSessions["member:deliver"]?.lineage == 2)
        #expect(
            activity.stepSessions["member:deliver"]?.providerSessionID
                == "codex-legacy-session"
        )
        #expect(await overseer.migrationCount() == 1)
        let migrationContext = await overseer.migrationContexts().first
        #expect(migrationContext?.userGoal == fixture.goal)
        #expect(migrationContext?.legacyWorkflow == workflow)
        #expect(await provider.sessionRequests().isEmpty)
    }

    @Test
    func resumeAfterConversionFailureRetriesTheDynamicTeamInsteadOfTheOldWorkflow() async throws {
        let fixture = try makeFixture(goal: "Replace the old activity before continuing.")
        defer { fixture.remove() }
        let target = liveTarget()
        let legacyStep = WorkflowStep(
            id: "deliver",
            name: "Deliver",
            section: .loop,
            instructions: "Run the earlier fixed step.",
            target: target
        )
        let workflow = WorkflowTemplate(
            id: "legacy",
            name: "Earlier fixed activity",
            summary: "Conversion retry fixture",
            steps: [legacyStep],
            coordinator: WorkflowCoordinatorConfiguration(
                target: target,
                instructions: "Route the earlier fixed activity."
            )
        )
        let definition = liveDefinition(members: [
            liveMember(id: "dynamic-deliver", sessionPolicy: .freshEveryRun)
        ])
        var record = RepositoryRecord(canonicalPath: fixture.canonicalPath)
        record.activity = ActivityRecord(
            goal: fixture.goal,
            prompts: .builtInDefaults,
            status: .paused,
            workflow: workflow,
            workflowCursor: .init(section: .loop, stepIndex: 0),
            workflowResumeCheckpoint: .perform(.init(section: .loop, stepIndex: 0))
        )
        try await fixture.store.save(record)

        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.completionCandidate, evidence: "The dynamic member finished.")
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal,
            migrationFailuresRemaining: 1
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()

        #expect(coordinator.record.activity?.workflow == workflow)
        #expect(coordinator.record.activity?.liveTeam == nil)
        #expect(coordinator.record.activity?.status == .paused)
        #expect(coordinator.requiresLegacyConversion)
        #expect(coordinator.canResume)
        #expect(coordinator.errorMessage?.contains("could not prepare agents") == true)

        await coordinator.resume()
        try await waitUntil { coordinator.record.activity?.status == .completed }

        let activity = try #require(coordinator.record.activity)
        #expect(activity.workflow == nil)
        #expect(activity.liveTeam?.currentDefinition == definition)
        #expect(!coordinator.requiresLegacyConversion)
        #expect(activity.runs.count == 1)
        #expect(activity.runs.first?.liveTeamMember?.member.id == "dynamic-deliver")
        #expect(await overseer.migrationCount() == 2)
        #expect(await provider.runRequests().count == 1)
    }

    @Test
    func olderOverseerPauseIsRejectedInsteadOfRequestingUserDirection() async throws {
        let fixture = try makeFixture(goal: "Pause when the Board must decide.")
        defer { fixture.remove() }
        let reason = "The remaining evidence decision belongs to the Board."
        var auditMember = liveMember(id: "audit", sessionPolicy: .freshEveryRun)
        auditMember.runPolicy = .once
        let definition = liveDefinition(members: [
            auditMember
        ])
        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.requestOversight)
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal,
            strategicDecision: LiveTeamStrategicDecision(
                action: .pause,
                reason: reason,
                evidence: "The audit found a decision boundary, not a repository failure."
            )
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()
        await coordinator.startActivity(goal: fixture.goal)
        try await waitUntil { coordinator.errorMessage != nil }

        #expect(coordinator.record.activity?.status == .paused)
        #expect(coordinator.errorMessage?.contains("cannot ask you") == true)
        #expect(coordinator.statusMessage == "Strategy review returned an invalid pause")
        #expect(
            coordinator.record.activity?.liveTeam?.editHistory.last?.summary
                == "Rejected autonomous pause"
        )
        let persisted = try await fixture.store.load(canonicalPath: fixture.canonicalPath)
        #expect(persisted.activity?.liveTeam?.editHistory.last?.reason == reason)
        #expect(persisted.activity?.liveTeam?.boardDirectionReason == nil)
        guard case .invokeOverseer(let resumeRequest)? =
            persisted.activity?.liveTeam?.resumeCheckpoint else {
            Issue.record("The Overseer pause did not preserve a review checkpoint.")
            return
        }
        #expect(!resumeRequest.automatic)
        #expect(resumeRequest.continuation == nil)
        #expect(resumeRequest.reason.contains(reason))
        #expect(coordinator.canResume)

        coordinator.clearError()
        await coordinator.resume()
        try await waitUntilAsync {
            await overseer.recordedStrategicContexts().count == 2
        }
        let resumedReviews = await overseer.recordedStrategicContexts()
        #expect(resumedReviews[1].triggerReason.contains("previously stopped at an internal strategy boundary"))
        #expect(resumedReviews[1].triggerReason.contains("cannot manufacture a need for user approval"))
        #expect(resumedReviews[1].triggerReason.contains("Choose and constrain the next reversible internal stage"))
        #expect(coordinator.record.activity?.status == .paused)
    }

    @Test
    func olderDirectionPauseRestoresAutonomousReviewAndDropsCompletedAgentCheckpoint() async throws {
        let fixture = try makeFixture(goal: "Pause when the user must decide.")
        defer { fixture.remove() }
        let oldReason = "The Board must decide after the team revision."
        let normalizedReason = "You must decide after the agent change."
        var auditAgent = liveMember(id: "audit", sessionPolicy: .freshEveryRun)
        auditAgent.runPolicy = .once
        let definition = liveDefinition(members: [auditAgent])
        let checkpoint = LiveTeamCheckpoint(
            memberID: auditAgent.id,
            cycle: 1,
            revision: 1
        )

        // Simulate the earlier prototype format that saved the Board pause only
        // in edit history and retained a checkpoint for the completed Once member.
        var record = RepositoryRecord(canonicalPath: fixture.canonicalPath)
        record.activity = ActivityRecord(
            goal: fixture.goal,
            prompts: .builtInDefaults,
            status: .paused,
            liveTeam: LiveTeamState(
                overseer: liveOverseerConfiguration(),
                currentDefinition: definition,
                checkpoint: checkpoint,
                resumeCheckpoint: .perform(checkpoint),
                completedOnceMemberIDs: [auditAgent.id],
                editHistory: [LiveTeamEditRecord(
                    revision: 1,
                    actor: .overseer,
                    summary: "Paused for Board direction",
                    reason: oldReason,
                    evidence: "Coordinator evidence came from the last team cycle."
                )]
            )
        )
        try await fixture.store.save(record)

        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )
        await coordinator.load()

        #expect(coordinator.statusMessage == "Paused before investment review")
        guard case .invokeOverseer(let resumeRequest)? =
            coordinator.record.activity?.liveTeam?.resumeCheckpoint else {
            Issue.record("The older pause was not repaired to an Overseer checkpoint.")
            return
        }
        #expect(resumeRequest.continuation == nil)
        #expect(resumeRequest.reason.contains(normalizedReason))
        #expect(coordinator.canResume)
        #expect(coordinator.record.activity?.goal == fixture.goal)
        #expect(
            coordinator.record.activity?.liveTeam?.currentDefinition?.strategicReason
                == "This is the smallest coherent agent setup for the current evidence."
        )
        #expect(
            coordinator.record.activity?.liveTeam?.editHistory.last?.summary
                == "Recovered internal strategy boundary"
        )
        #expect(
            coordinator.record.activity?.liveTeam?.editHistory.last?.evidence
                == "routing evidence came from the last round."
        )
        let persisted = try await fixture.store.load(canonicalPath: fixture.canonicalPath)
        #expect(persisted.activity?.liveTeam?.boardDirectionReason == nil)
        #expect(persisted.activity?.liveTeam?.resumeCheckpoint == .invokeOverseer(resumeRequest))
        #expect(
            persisted.activity?.liveTeam?.editHistory.last?.summary
                == "Recovered internal strategy boundary"
        )
    }

    private func runSessionScenario(
        members: [LiveTeamMember]
    ) async throws -> SessionScenarioResult {
        let fixture = try makeFixture(goal: "Exercise a memory policy.")
        defer { fixture.remove() }
        let definition = liveDefinition(members: members)
        let provider = RecordingLiveTeamProvider(
            store: fixture.store,
            canonicalPath: fixture.canonicalPath
        )
        let coordinatorRouter = ScriptedLiveTeamCoordinator(decisions: [
            decision(.continueTeam),
            decision(.completionCandidate)
        ])
        let overseer = RecordingLiveTeamOverseer(
            definition: definition,
            store: fixture.store,
            canonicalPath: fixture.canonicalPath,
            expectedGoal: fixture.goal
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            provider: provider,
            coordinatorRouter: coordinatorRouter,
            overseer: overseer
        )

        await coordinator.load()
        await coordinator.startActivity(goal: fixture.goal)
        try await waitUntil { coordinator.record.activity?.status == .completed }
        let expectedReleaseCount = Set(await provider.preparedSessionIDs()).count
        try await waitUntilAsync {
            await provider.releasedSessionIDs().count == expectedReleaseCount
        }

        return SessionScenarioResult(
            existingSessionIDs: await provider.existingSessionIDs(),
            preparedSessionIDs: await provider.preparedSessionIDs(),
            releasedSessionIDs: await provider.releasedSessionIDs()
        )
    }

    private func makeCoordinator(
        fixture: LiveTeamFixture,
        provider: RecordingLiveTeamProvider,
        coordinatorRouter: ScriptedLiveTeamCoordinator,
        overseer: RecordingLiveTeamOverseer,
        runtimeProvider: (@MainActor @Sendable (
            RepositorySettings
        ) -> LiveTeamRuntimeConfiguration)? = nil
    ) -> RepositoryCoordinator {
        RepositoryCoordinator(
            canonicalPath: fixture.canonicalPath,
            appServer: CodexAppServerClient(),
            router: NoopLiveTeamLegacyRouter(),
            store: fixture.store,
            agentProviders: AgentProviderRegistry(providers: [provider]),
            liveTeamCoordinatorRouter: coordinatorRouter,
            liveTeamOverseerRouter: overseer,
            liveTeamRuntimeConfiguration: liveRuntimeConfiguration(),
            liveTeamRuntimeConfigurationProvider: runtimeProvider
        )
    }

    private func makeFixture(goal: String) throws -> LiveTeamFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return LiveTeamFixture(
            root: root,
            store: WorkspaceStore(rootURL: root),
            canonicalPath: "/tmp/codeness-live-team-\(UUID().uuidString)",
            goal: goal
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    private func waitUntilAsync(
        timeout: Duration = .seconds(5),
        _ condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }
}

private struct LiveTeamFixture {
    let root: URL
    let store: WorkspaceStore
    let canonicalPath: String
    let goal: String

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct SessionScenarioResult {
    let existingSessionIDs: [String?]
    let preparedSessionIDs: [String]
    let releasedSessionIDs: [String]
}

private actor RecordingLiveTeamProvider: AgentProviding {
    nonisolated let id: AgentProviderID = .codex

    private let store: WorkspaceStore
    private let canonicalPath: String
    private let firstRunGate: FirstRunGate?
    private var prepared: [AgentSessionRequest] = []
    private var preparedIDs: [String] = []
    private var revisionWasDurableAtPreparation: [Bool] = []
    private var started: [AgentRunRequest] = []
    private var released: [String] = []
    private var sessionCounter = 0

    init(
        store: WorkspaceStore,
        canonicalPath: String,
        firstRunGate: FirstRunGate? = nil
    ) {
        self.store = store
        self.canonicalPath = canonicalPath
        self.firstRunGate = firstRunGate
    }

    func prepareSession(_ request: AgentSessionRequest) async throws -> AgentSession {
        prepared.append(request)
        let persisted = try await store.load(canonicalPath: canonicalPath)
        revisionWasDurableAtPreparation.append(
            persisted.activity?.liveTeam?.currentDefinition != nil
                && persisted.activity?.runs.last?.status == .queued
        )
        let sessionID: String
        if let existingSessionID = request.existingSessionID {
            sessionID = existingSessionID
        } else {
            sessionCounter += 1
            sessionID = "codex-session-\(sessionCounter)"
        }
        preparedIDs.append(sessionID)
        return AgentSession(providerID: id, id: sessionID, target: request.target)
    }

    func startRun(_ request: AgentRunRequest) -> AgentRunHandle {
        started.append(request)
        let runNumber = started.count
        let output = request.outputSchema == nil
            ? "Worker result \(runNumber)"
            : Self.companyOutput(prompt: request.prompt, runNumber: runNumber)
        let pair = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
        let firstRunGate = firstRunGate
        Task {
            pair.continuation.yield(.started(executionID: "execution-\(runNumber)"))
            await firstRunGate?.blockIfNeeded(runNumber: runNumber)
            pair.continuation.yield(.transcript("Worker transcript \(runNumber)"))
            pair.continuation.yield(.completed(
                output: output,
                durationMilliseconds: 1,
                tokenUsage: RunTokenUsage(totalTokens: 2, inputTokens: 1, outputTokens: 1)
            ))
            pair.continuation.finish()
        }
        return AgentRunHandle(
            runID: request.runID,
            providerID: id,
            sessionID: request.session.id,
            executionID: "execution-\(runNumber)",
            events: pair.stream
        )
    }

    private nonisolated static func companyOutput(
        prompt: String,
        runNumber: Int
    ) -> String {
        func value(after prefix: String, before suffix: String) -> String? {
            guard let start = prompt.range(of: prefix)?.upperBound,
                  let end = prompt[start...].range(of: suffix)?.lowerBound else {
                return nil
            }
            return String(prompt[start..<end])
        }
        let workerID = value(after: "Use workerID \"", before: "\"") ?? "worker"
        let positionID = value(after: "positionID \"", before: "\"") ?? "developer"
        let contribution = value(
            after: "one of these contribution kinds: ",
            before: "."
        )?.split(separator: ",").first.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? "softwareImplementation"
        let object: [String: Any] = [
            "workerID": workerID,
            "positionID": positionID,
            "contributionKind": contribution,
            "summary": "Worker result \(runNumber)",
            "artifacts": [],
            "evidence": ["Worker result \(runNumber)"],
            "decisions": [],
            "constraints": [],
            "risks": [],
            "capabilityBlock": NSNull(),
            "recommendedRecipientPositions": []
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    func steer(runID: UUID, message: String) throws {
        _ = runID
        _ = message
    }

    func interrupt(runID: UUID) throws {
        _ = runID
    }

    func resolveInteraction(
        runID: UUID,
        interactionID: String,
        resolution: AgentInteractionResolution
    ) throws {
        _ = runID
        _ = interactionID
        _ = resolution
    }

    func runUtility(_ request: AgentUtilityRequest) throws -> AgentUtilityResult {
        _ = request
        throw AgentProviderError.invalidResponse("Utility routing is supplied by the fixture.")
    }

    func releaseSession(id: String) -> Bool {
        if !released.contains(id) {
            released.append(id)
        }
        return true
    }

    func shutdown() {}

    func sessionRequests() -> [AgentSessionRequest] { prepared }
    func existingSessionIDs() -> [String?] { prepared.map(\.existingSessionID) }
    func preparedSessionIDs() -> [String] { preparedIDs }
    func preparationFollowedDurableRevision() -> [Bool] {
        revisionWasDurableAtPreparation
    }
    func runRequests() -> [AgentRunRequest] { started }
    func releasedSessionIDs() -> [String] { released }
}

private actor FirstRunGate {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func blockIfNeeded(runNumber: Int) async {
        guard runNumber == 1, !released else { return }
        blocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor ScriptedLiveTeamCoordinator: LiveTeamCoordinatorRouting {
    private let decisions: [LiveTeamCoordinatorDecision]
    private var routedContexts: [LiveTeamCoordinatorContext] = []

    init(decisions: [LiveTeamCoordinatorDecision]) {
        self.decisions = decisions
    }

    func coordinate(
        _ context: LiveTeamCoordinatorContext,
        configuration: LiveTeamCoordinatorConfiguration,
        cwd: String
    ) throws -> LiveTeamCoordinatorDecision {
        _ = configuration
        _ = cwd
        let index = routedContexts.count
        routedContexts.append(context)
        guard decisions.indices.contains(index) else {
            throw AgentProviderError.invalidResponse(
                "The test Coordinator received an unexpected handoff."
            )
        }
        return decisions[index]
    }

    func contexts() -> [LiveTeamCoordinatorContext] { routedContexts }
    func routeCount() -> Int { routedContexts.count }
}

private actor RecordingLiveTeamOverseer: LiveTeamOverseerRouting {
    private let definition: LiveTeamDefinition
    private let store: WorkspaceStore
    private let canonicalPath: String
    private let expectedGoal: String
    private let strategicDecision: LiveTeamStrategicDecision
    private var migrationFailuresRemaining: Int
    private var durableGoalOnlyBootstrap = false
    private var bootstrapContexts: [LiveTeamOverseerContext] = []
    private var usedBootstrapConfigurations: [LiveTeamOverseerConfiguration] = []
    private var usedStrategicConfigurations: [LiveTeamOverseerConfiguration] = []
    private var strategicContexts: [LiveTeamOverseerContext] = []
    private var reviewedCompletionContexts: [LiveTeamOverseerContext] = []
    private var reviewedMigrationContexts: [LiveTeamOverseerContext] = []

    init(
        definition: LiveTeamDefinition,
        store: WorkspaceStore,
        canonicalPath: String,
        expectedGoal: String,
        migrationFailuresRemaining: Int = 0,
        strategicDecision: LiveTeamStrategicDecision = LiveTeamStrategicDecision(
            action: .keep,
            reason: "The current team remains proportionate.",
            evidence: "The bounded flow is advancing."
        )
    ) {
        self.definition = definition
        self.store = store
        self.canonicalPath = canonicalPath
        self.expectedGoal = expectedGoal
        self.migrationFailuresRemaining = migrationFailuresRemaining
        self.strategicDecision = strategicDecision
    }

    func bootstrap(
        _ context: LiveTeamOverseerContext,
        configuration: LiveTeamOverseerConfiguration,
        defaultCoordinator: LiveTeamCoordinatorConfiguration,
        cwd: String
    ) async throws -> LiveTeamDefinition {
        _ = configuration
        _ = defaultCoordinator
        _ = cwd
        bootstrapContexts.append(context)
        usedBootstrapConfigurations.append(configuration)
        let persisted = try await store.load(canonicalPath: canonicalPath)
        durableGoalOnlyBootstrap = persisted.activity?.goal == expectedGoal
            && persisted.activity?.runs.isEmpty == true
            && persisted.activity?.liveTeam?.currentDefinition == nil
            && persisted.activity?.liveTeam?.resumeCheckpoint
                == .invokeOverseer(.init(
                    mode: .bootstrap,
                    reason: "Create the first working goal and agents for the user's goal.",
                    automatic: false
                ))
        return definition
    }

    func reviewStrategy(
        _ context: LiveTeamOverseerContext,
        configuration: LiveTeamOverseerConfiguration,
        cwd: String
    ) -> LiveTeamStrategicDecision {
        _ = cwd
        strategicContexts.append(context)
        usedStrategicConfigurations.append(configuration)
        if context.triggerReason.contains("no agents may be needed") {
            return LiveTeamStrategicDecision(
                action: .complete,
                reason: "The fixed goal is satisfied and no agents are needed.",
                evidence: "The bounded durable evidence satisfies the full goal."
            )
        }
        return strategicDecision
    }

    func reviewStrategy(
        _ context: LiveTeamOverseerContext,
        configuration: LiveTeamOverseerConfiguration,
        cwd: String,
        progress: @escaping LiveTeamReviewProgressHandler
    ) async -> LiveTeamStrategicDecision {
        await reportFixtureConsultation(progress)
        return reviewStrategy(context, configuration: configuration, cwd: cwd)
    }

    func reviewCompletion(
        _ context: LiveTeamOverseerContext,
        configuration: LiveTeamOverseerConfiguration,
        cwd: String
    ) -> LiveTeamCompletionDecision {
        _ = configuration
        _ = cwd
        reviewedCompletionContexts.append(context)
        return LiveTeamCompletionDecision(
            outcome: .complete,
            evidence: "The worker result and Coordinator evidence satisfy the Board goal.",
            reason: "Independent completion review passed."
        )
    }

    func reviewCompletion(
        _ context: LiveTeamOverseerContext,
        configuration: LiveTeamOverseerConfiguration,
        cwd: String,
        progress: @escaping LiveTeamReviewProgressHandler
    ) async -> LiveTeamCompletionDecision {
        await reportFixtureConsultation(progress)
        return reviewCompletion(context, configuration: configuration, cwd: cwd)
    }

    private func reportFixtureConsultation(
        _ progress: LiveTeamReviewProgressHandler
    ) async {
        await progress(.focusGroupCompleted(LiveTeamFocusGroupReport(
            subject: "A bounded product demonstration",
            question: "Would the intended audience choose it?",
            audience: "Intended users",
            comparison: "A close alternative",
            comparisonReason: "It serves the same user need.",
            researchBasis: .generalKnowledge,
            sources: [],
            participants: (1...4).map { index in
                LiveTeamFocusGroupParticipant(
                    archetype: "Participant \(index)",
                    expectation: "Immediate product value.",
                    choice: index.isMultiple(of: 2) ? .comparison : .currentProduct,
                    reaction: "The bounded result supports a concrete choice."
                )
            },
            findings: ["The product creates directional value."],
            verdict: "Continue the stronger product direction.",
            nextExperiment: "Exercise one sharper product interaction.",
            limitations: "Fixture simulation."
        )))
        let managers = [
            LiveTeamManagerConsultation(
                name: "Product Director",
                mandate: "Judge delivery progress.",
                status: .reporting
            ),
            LiveTeamManagerConsultation(
                name: "Engineering Director",
                mandate: "Judge execution readiness.",
                status: .reporting
            )
        ]
        await progress(.personasSelected(managers))
        for (index, manager) in managers.enumerated() {
            await progress(.consultationCompleted(
                index: index,
                consultation: LiveTeamManagerConsultation(
                    id: manager.id,
                    name: manager.name,
                    mandate: manager.mandate,
                    status: .completed,
                    involvement: "material",
                    progress: "advancing",
                    evidence: "The fixture recorded durable progress.",
                    concern: "none",
                    nextMove: "Continue the bounded plan."
                )
            ))
        }
        await progress(.overseerDeciding)
    }

    func migrate(
        _ context: LiveTeamOverseerContext,
        configuration: LiveTeamOverseerConfiguration,
        defaultCoordinator: LiveTeamCoordinatorConfiguration,
        cwd: String
    ) throws -> LiveTeamDefinition {
        _ = configuration
        _ = defaultCoordinator
        _ = cwd
        reviewedMigrationContexts.append(context)
        if migrationFailuresRemaining > 0 {
            migrationFailuresRemaining -= 1
            throw AgentProviderError.invalidResponse("Simulated conversion failure.")
        }
        return definition
    }

    func sawDurableGoalOnlyBootstrap() -> Bool { durableGoalOnlyBootstrap }
    func bootstrapCount() -> Int { bootstrapContexts.count }
    func recordedBootstrapContexts() -> [LiveTeamOverseerContext] { bootstrapContexts }
    func bootstrapConfigurations() -> [LiveTeamOverseerConfiguration] {
        usedBootstrapConfigurations
    }
    func completionReviewCount() -> Int { reviewedCompletionContexts.count }
    func completionContexts() -> [LiveTeamOverseerContext] {
        reviewedCompletionContexts
    }
    func recordedStrategicContexts() -> [LiveTeamOverseerContext] {
        strategicContexts
    }
    func strategicConfigurations() -> [LiveTeamOverseerConfiguration] {
        usedStrategicConfigurations
    }
    func migrationCount() -> Int { reviewedMigrationContexts.count }
    func migrationContexts() -> [LiveTeamOverseerContext] {
        reviewedMigrationContexts
    }
}

private actor NoopLiveTeamLegacyRouter: HandoffRouting {
    func route(
        _ context: HandoffContext,
        settings: RelaySettings
    ) -> HandoffEnvelope {
        _ = context
        _ = settings
        return HandoffEnvelope(
            handoffText: "Unused legacy handoff",
            sourceDisposition: .unclear,
            runLabel: "Unused"
        )
    }
}

private func liveTarget(model: String = "gpt-live-test") -> AgentTarget {
    AgentTarget(
        providerID: .codex,
        model: model,
        options: .init(effort: "high")
    )
}

private func liveMember(
    id: String,
    instructions: String = "Deliver one bounded result and report evidence.",
    sessionPolicy: LiveTeamSessionPolicy
) -> LiveTeamMember {
    LiveTeamMember(
        id: id,
        name: id.capitalized,
        instructions: instructions,
        target: liveTarget(),
        runPolicy: .everyCycle,
        sessionPolicy: sessionPolicy
    )
}

private func liveDefinition(members: [LiveTeamMember]) -> LiveTeamDefinition {
    LiveTeamDefinition(
        revision: 1,
        workingGoal: "Deliver and validate one bounded result.",
        members: members,
        coordinator: liveCoordinatorConfiguration(),
        strategicReason: "This is the smallest coherent team for the current evidence."
    )
}

private func companyLiveDefinition(maximumTurns: Int) -> LiveTeamDefinition {
    let chiefExecutive = companyPerson(
        name: "Mara Voss",
        positionID: .chiefExecutive,
        assignment: "Own the fixed goal and product investment."
    )
    let developer = companyPerson(
        name: "Ivo Chen",
        positionID: .developer,
        assignment: "Build and exercise the integrated product."
    )
    let member = LiveTeamMember(
        id: "build",
        name: "Ship Visible Value",
        instructions: developer.assignment,
        target: liveTarget(),
        runPolicy: .everyCycle,
        sessionPolicy: .ownMemory,
        positionID: .developer,
        person: developer,
        companyAssignment: CompanyAssignmentContract(
            contributionKind: .softwareImplementation,
            requiredCapabilities: [.workspaceRead, .sourceModification, .commandExecution],
            acceptanceEvidence: "The integrated product works under focused exercise.",
            dependencyContributionKinds: [],
            stopCondition: "Stop after verification or report a capability block."
        )
    )
    return LiveTeamDefinition(
        revision: 1,
        workingGoal: "Build and exercise the integrated product.",
        members: [member],
        coordinator: liveCoordinatorConfiguration(),
        strategicReason: "Direct product work has the highest expected return.",
        operatingModelVersion: 2,
        overseerPerson: chiefExecutive,
        productBet: CompanyProductBet(
            headline: "Ship visible value",
            valuePromise: "The product can be exercised directly.",
            showcase: "A working integrated demonstration",
            integrationTarget: "The repository's main product",
            killCondition: "Stop if direct use disproves the value promise.",
            fundedTokenLimit: 1_000_000,
            maximumTurns: maximumTurns
        )
    )
}

private func companyPerson(
    name: String,
    positionID: CompanyPositionID,
    assignment: String
) -> CompanyPerson {
    CompanyPerson(
        positionID: positionID,
        profile: CompanyPersonaProfile(
            fullName: name,
            background: "Built ambitious products under real delivery pressure.",
            formativeSuccess: "Shipped a result customers immediately adopted.",
            formativeScar: "Once polished the wrong feature instead of testing the core bet.",
            convictions: [
                "Working product evidence beats status prose.",
                "One integrated bet beats disconnected prototypes.",
                "Strong opinions must yield to direct evidence."
            ],
            personalStake: "Wants this product to become the reference result.",
            workingStyle: "Fast, direct, and relentlessly product-focused.",
            conflictStyle: "Challenges timid choices with a working alternative.",
            blindSpot: "Can underestimate the cost of changing a promising direction.",
            evidenceThatChangesTheirMind: "Observed product behavior and repeated user use.",
            ingredients: CompanyPersonaIngredients(
                spark: "A breakthrough shipped early.",
                riskPosture: "Bold reversible bets.",
                conflictStyle: "Direct and energetic.",
                craftObsession: "A product people ask to use again.",
                ambition: "Build the reference product."
            )
        ),
        assignment: assignment,
        hiredRevision: 1
    )
}

private func liveCoordinatorConfiguration() -> LiveTeamCoordinatorConfiguration {
    LiveTeamCoordinatorConfiguration(
        target: liveTarget(),
        instructions: "Manage local flow only; do not reinterpret the Board goal."
    )
}

private func liveOverseerConfiguration() -> LiveTeamOverseerConfiguration {
    LiveTeamOverseerConfiguration(
        target: liveTarget(),
        instructions: "Control strategy and completion against the Board goal."
    )
}

private func liveRuntimeConfiguration(
    model: String = "gpt-live-test"
) -> LiveTeamRuntimeConfiguration {
    let target = liveTarget(model: model)
    return LiveTeamRuntimeConfiguration(
        overseer: LiveTeamOverseerConfiguration(
            target: target,
            instructions: "Control strategy and completion against the Board goal."
        ),
        defaultCoordinator: LiveTeamCoordinatorConfiguration(
            target: target,
            instructions: "Manage local flow only; do not reinterpret the Board goal."
        ),
        targetOptions: [
            LiveTeamTargetOption(
                id: "primary",
                label: "Primary",
                target: target
            )
        ]
    )
}

private func decision(
    _ disposition: LiveTeamCoordinatorDisposition,
    evidence: String = "The previous member completed its bounded responsibility."
) -> LiveTeamCoordinatorDecision {
    LiveTeamCoordinatorDecision(
        handoff: "Continue from the accepted local result.",
        runLabel: "Bounded delivery",
        disposition: disposition,
        evidence: evidence,
        progressEvidence: .acceptedValidation
    )
}
