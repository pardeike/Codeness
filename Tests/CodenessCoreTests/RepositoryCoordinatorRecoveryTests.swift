import Foundation
import Testing
@testable import CodenessCore

@Suite(.serialized)
@MainActor
struct RepositoryCoordinatorRecoveryTests {
    @Test
    func explicitRunDeselectionLeavesTheDetailWithoutAFallbackRun() async throws {
        let savedRun = run(status: .completed)
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: savedRun
        ))
        defer { harness.remove() }

        #expect(harness.coordinator.selectedRunID == savedRun.id)
        #expect(harness.coordinator.selectedRun?.id == savedRun.id)

        harness.coordinator.selectedRunID = nil

        #expect(harness.coordinator.selectedRunID == nil)
        #expect(harness.coordinator.selectedRun == nil)
        #expect(harness.coordinator.viewState.selectedRunID == nil)
        #expect(harness.coordinator.viewState.runSelectionWasSaved)
        #expect(await harness.coordinator.flushDocumentState())

        let reloaded = RepositoryCoordinator(
            canonicalPath: harness.coordinator.record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: WorkspaceStore(rootURL: harness.root)
        )
        await reloaded.load()

        #expect(reloaded.selectedRunID == nil)
        #expect(reloaded.selectedRun == nil)
        #expect(reloaded.viewState.runSelectionWasSaved)
    }

    @Test
    func selectingTheLiveRunRestoresTranscriptFollowMode() async throws {
        let savedRun = run(status: .paused)
        let harness = try await CoordinatorHarness(
            record: repositoryRecord(activityStatus: .paused, run: savedRun),
            viewState: RepositoryViewState(
                selectedRunID: nil,
                runSelectionWasSaved: true,
                transcriptViewports: [
                    savedRun.id: TranscriptViewportState(
                        topCharacterOffset: 80,
                        verticalOffset: 2,
                        followsOutput: false
                    )
                ]
            )
        )
        defer { harness.remove() }

        harness.coordinator.selectLiveRun()

        #expect(harness.coordinator.selectedRunID == savedRun.id)
        #expect(harness.coordinator.transcriptViewport(for: savedRun.id).followsOutput)
        #expect(harness.coordinator.transcriptFollowRequestRunID == savedRun.id)
        #expect(harness.coordinator.transcriptFollowRequestRevision == 1)
    }

    @Test
    func loadTurnsAnOrphanedRunningPassIntoAPausedRecoveryCheckpoint() async throws {
        let savedRun = run(status: .running)
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .running,
            run: savedRun
        ))
        defer { harness.remove() }

        let activity = try #require(harness.coordinator.record.activity)
        #expect(activity.status == .paused)
        #expect(activity.runs.last?.status == .interrupted)
        #expect(activity.resumeCheckpoint == .recoverRun(savedRun.id))
        #expect(harness.coordinator.canResume)
    }

    @Test
    func interruptedOverseerReviewPreservesItsCheckpointAndMarksTheReviewFailed() async throws {
        let target = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-sol",
            options: .init(effort: "high", mode: .standard)
        )
        let member = LiveTeamMember(
            id: "deliver",
            name: "Deliver",
            instructions: "Continue the bounded production stage.",
            target: target,
            runPolicy: .everyCycle,
            sessionPolicy: .ownMemory
        )
        let definition = LiveTeamDefinition(
            revision: 2,
            workingGoal: "Advance the customer-facing result.",
            members: [member],
            coordinator: .init(target: target, instructions: "Route local work."),
            strategicReason: "Production work remains."
        )
        let checkpoint = LiveTeamCheckpoint(memberID: member.id, cycle: 2, revision: 2)
        let completedRunID = UUID()
        let request = LiveTeamOverseerRequest(
            mode: .strategicReview,
            reason: "Periodic review is due.",
            sourceRunID: completedRunID,
            continuation: checkpoint,
            automatic: true
        )
        let review = LiveTeamReviewRecord(
            mode: .strategicReview,
            trigger: request.reason,
            sourceRunID: completedRunID,
            baseRevision: definition.revision,
            status: .overseerDeciding
        )
        let decision = LiveTeamCoordinatorDecision(
            handoff: "Continue production.",
            runLabel: "Production turn",
            disposition: .continueTeam,
            evidence: "The prior turn produced durable progress.",
            progressEvidence: .repositoryChange
        )
        let completedRun = RunRecord(
            id: completedRunID,
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: "member:deliver",
            model: target.model,
            effort: "high",
            prompt: "Deliver the next result.",
            finalOutput: "Production advanced.",
            completedAt: .now,
            agentTarget: target,
            liveTeamMember: LiveTeamMemberSnapshot(
                member: member,
                workingGoal: definition.workingGoal,
                revision: definition.revision,
                cycle: checkpoint.cycle,
                sessionSlotID: "member:deliver"
            ),
            coordinatorDecision: decision
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/codeness-review-recovery-\(UUID().uuidString)",
            activity: ActivityRecord(
                goal: "Deliver the fixed goal.",
                prompts: .builtInDefaults,
                status: .running,
                runs: [completedRun],
                liveTeam: LiveTeamState(
                    overseer: .init(target: target, instructions: "Own strategy."),
                    currentDefinition: definition,
                    checkpoint: checkpoint,
                    resumeCheckpoint: .invokeOverseer(request),
                    coordinatorHandoff: decision.handoff,
                    lastCoordinatorDecision: decision,
                    reviews: [review]
                )
            )
        )
        let harness = try await CoordinatorHarness(record: record)
        defer { harness.remove() }

        #expect(harness.coordinator.record.activity?.status == .paused)
        #expect(
            harness.coordinator.record.activity?.liveTeam?.resumeCheckpoint
                == .invokeOverseer(request)
        )
        let recoveredReview = try #require(
            harness.coordinator.record.activity?.liveTeam?.reviews.first
        )
        #expect(recoveredReview.status == .failed)
        #expect(recoveredReview.decision?.outcome == .failed)
        #expect(recoveredReview.decision?.summary == "Review interrupted")
        #expect(recoveredReview.completedAt != nil)
    }

    @Test
    func loadRepairsAReviewCheckpointCreatedBeforeInitialSetup() async throws {
        let target = AgentTarget(providerID: .codex, model: "gpt-5.6-luna")
        let invalidRequest = LiveTeamOverseerRequest(
            mode: .strategicReview,
            reason: "The user amended the goal.",
            automatic: false,
            leavePaused: true
        )
        let invalidReview = LiveTeamReviewRecord(
            mode: .strategicReview,
            trigger: invalidRequest.reason,
            sourceRunID: nil,
            baseRevision: 1,
            status: .failed,
            decision: .init(
                outcome: .failed,
                summary: "Review interrupted",
                reason: "Strategic review requires a current live-team definition.",
                evidence: "The checkpoint was preserved for retry."
            ),
            completedAt: .now
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/codeness-prebootstrap-goal-\(UUID().uuidString)",
            activity: ActivityRecord(
                goal: "Use the revised goal.",
                prompts: .builtInDefaults,
                status: .paused,
                liveTeam: LiveTeamState(
                    overseer: .init(target: target, instructions: "Own the goal."),
                    resumeCheckpoint: .invokeOverseer(invalidRequest),
                    reviews: [invalidReview],
                    lastStrategicReviewAt: .now,
                    boardGoalAmendmentPendingReview: true
                )
            )
        )
        let harness = try await CoordinatorHarness(record: record)
        defer { harness.remove() }

        let state = try #require(harness.coordinator.activity?.liveTeam)
        guard case .invokeOverseer(let repairedRequest)? = state.resumeCheckpoint else {
            Issue.record("Expected a repaired bootstrap checkpoint")
            return
        }
        #expect(repairedRequest.mode == .bootstrap)
        #expect(!repairedRequest.automatic)
        #expect(state.reviews.isEmpty)
        #expect(state.lastStrategicReviewAt == nil)
        #expect(!state.boardGoalAmendmentPendingReview)
    }

    @Test
    func interruptedLastRunIsResumable() async throws {
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: run(status: .interrupted)
        ))
        defer { harness.remove() }

        #expect(harness.coordinator.canResume)
        let savedRunID = try #require(harness.coordinator.record.activity?.runs.last?.id)
        #expect(harness.coordinator.record.activity?.resumeCheckpoint == .recoverRun(savedRunID))
    }

    @Test
    func safeResumeCheckpointRemainsPausedUntilUserResumes() async throws {
        let completedRun = run(status: .routing, finalOutput: "Completed repository edits")
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: completedRun,
            resumeCheckpoint: .routeCompletedRun(completedRun.id)
        ))
        defer { harness.remove() }

        #expect(harness.coordinator.record.activity?.status == .paused)
        #expect(harness.coordinator.record.activity?.resumeCheckpoint == .routeCompletedRun(completedRun.id))
        #expect(harness.coordinator.canResume)
    }

    @Test
    func completedPlanOutputIsRecoveredWithoutReplayingTheAgent() async throws {
        let planTarget = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-sol",
            options: .init(effort: "high", mode: .plan)
        )
        let member = LiveTeamMember(
            id: "review",
            name: "Review",
            instructions: "Review without editing.",
            target: planTarget,
            runPolicy: .everyCycle,
            sessionPolicy: .freshEveryRun
        )
        let definition = LiveTeamDefinition(
            revision: 1,
            workingGoal: "Deliver a verified app.",
            members: [member],
            coordinator: .init(target: planTarget, instructions: "Route local work."),
            strategicReason: "Independent review is required."
        )
        let snapshot = LiveTeamMemberSnapshot(
            member: member,
            workingGoal: definition.workingGoal,
            revision: 1,
            cycle: 1,
            sessionSlotID: "fresh:review:one"
        )
        let failedRun = RunRecord(
            sequence: 1,
            role: .reviewer,
            kind: .review,
            status: .failed,
            threadID: "plan-thread",
            turnID: "plan-turn",
            model: planTarget.model,
            effort: "high",
            prompt: "Review the current app.",
            transcript: RunTranscriptPresentation.storedText(
                "\n\nPlan\nFix the disconnected objective, then refresh runtime evidence.\n",
                section: .reasoning
            ),
            relayError: "Codex turn ended with status completed.",
            completedAt: .now,
            agentTarget: planTarget,
            liveTeamMember: snapshot
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/codeness-plan-recovery-\(UUID().uuidString)",
            activity: ActivityRecord(
                goal: "Build the app.",
                prompts: .builtInDefaults,
                status: .paused,
                runs: [failedRun],
                stepSessions: [
                    snapshot.sessionSlotID: WorkflowSessionState(
                        stepID: snapshot.sessionSlotID,
                        target: planTarget,
                        providerSessionID: "plan-thread"
                    )
                ],
                liveTeam: LiveTeamState(
                    overseer: .init(target: planTarget, instructions: "Review strategy."),
                    currentDefinition: definition,
                    resumeCheckpoint: .recoverRun(failedRun.id),
                    memberFailureCounts: [member.id: 1]
                )
            )
        )
        let harness = try await CoordinatorHarness(record: record)
        defer { harness.remove() }

        let recovered = try #require(harness.coordinator.record.activity)
        let recoveredRun = try #require(recovered.runs.last)
        #expect(recovered.status == .paused)
        #expect(recoveredRun.status == .routing)
        #expect(
            recoveredRun.finalOutput
                == "Fix the disconnected objective, then refresh runtime evidence."
        )
        #expect(recoveredRun.relayError == nil)
        #expect(recovered.liveTeam?.resumeCheckpoint == .routeCompletedRun(failedRun.id))
        #expect(recovered.liveTeam?.memberFailureCounts[member.id] == nil)
        #expect(recovered.liveTeam?.overseer.target.options.mode == .standard)
        #expect(recovered.liveTeam?.currentDefinition?.members.first?.target.options.mode == .standard)
        #expect(recoveredRun.liveTeamMember?.member.target.options.mode == .standard)
        #expect(recoveredRun.agentTarget?.options.mode == .plan)
        #expect(recovered.stepSessions[snapshot.sessionSlotID]?.target.options.mode == .standard)
        #expect(recovered.stepSessions[snapshot.sessionSlotID]?.providerSessionID == nil)
        #expect(harness.coordinator.canResume)
    }

    @Test
    func workOverviewSummaryIsGeneratedOnceAndDurablyCachedForItsHandoffs() async throws {
        var completedRun = run(status: .completed, finalOutput: "Implemented parser")
        completedRun.handoff = HandoffEnvelope(
            handoffText: "Parser foundation is complete; malformed-input tests remain.",
            sourceDisposition: .implementationCheckpoint,
            runLabel: "Parser foundation"
        )
        let router = RecordingSummaryRouter()
        let harness = try await CoordinatorHarness(
            record: repositoryRecord(activityStatus: .paused, run: completedRun),
            router: router
        )
        defer { harness.remove() }

        harness.coordinator.requestWorkOverviewSummary()
        await waitUntil {
            harness.coordinator.workOverviewSummaryText != nil
                && !harness.coordinator.isGeneratingWorkOverviewSummary
        }

        #expect(harness.coordinator.workOverviewSummaryText == "Parser foundation is complete.")
        #expect(harness.coordinator.workOverviewSummaryError == nil)
        #expect(await router.summaryCallCount == 1)
        let signature = try #require(harness.coordinator.workOverviewSummarySourceSignature)
        let persistedState = try await WorkspaceStore(rootURL: harness.root)
            .loadViewState(canonicalPath: harness.coordinator.record.canonicalPath)
        #expect(persistedState.workOverviewSummary?.sourceSignature == signature)
        #expect(persistedState.workOverviewSummary?.text == "Parser foundation is complete.")

        harness.coordinator.requestWorkOverviewSummary()
        #expect(await router.summaryCallCount == 1)

        let snapshotBuildCount = harness.coordinator.workSummarySnapshotBuildCount
        for _ in 0..<100 {
            #expect(harness.coordinator.workOverviewSummarySourceSignature == signature)
        }
        #expect(harness.coordinator.workSummarySnapshotBuildCount == snapshotBuildCount)

        #expect(await harness.coordinator.amendGoal("Recovery with an added constraint"))
        let revisedSignature = try #require(
            harness.coordinator.workOverviewSummarySourceSignature
        )
        #expect(revisedSignature != signature)
        #expect(harness.coordinator.workSummarySnapshotBuildCount == snapshotBuildCount + 1)
    }

    @Test
    func routingRecoveryRetriesTheHandoffWithoutReplayingThePass() async throws {
        let router = DelayedBlockedRouter(delay: .milliseconds(10))
        let savedRun = run(status: .routing, finalOutput: "Completed repository edits")
        let harness = try await CoordinatorHarness(
            record: repositoryRecord(
                activityStatus: .running,
                run: savedRun
            ),
            router: router,
            viewState: RepositoryViewState(
                selectedRunID: nil,
                runSelectionWasSaved: true,
                transcriptViewports: [
                    savedRun.id: TranscriptViewportState(
                        topCharacterOffset: 120,
                        verticalOffset: 4,
                        followsOutput: false
                    )
                ]
            )
        )
        defer { harness.remove() }

        #expect(harness.coordinator.record.activity?.status == .paused)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .routing)
        #expect(harness.coordinator.canResume)
        #expect(harness.coordinator.selectedRunID == nil)
        #expect(!harness.coordinator.transcriptViewport(for: savedRun.id).followsOutput)
        let routingRunID = try #require(harness.coordinator.record.activity?.runs.last?.id)
        #expect(harness.coordinator.record.activity?.resumeCheckpoint == .routeCompletedRun(routingRunID))

        await harness.coordinator.resume()
        await waitUntil { harness.coordinator.record.activity?.runs.last?.relayError != nil }

        #expect(harness.coordinator.selectedRunID == savedRun.id)
        #expect(harness.coordinator.transcriptViewport(for: savedRun.id).followsOutput)
        #expect(harness.coordinator.transcriptFollowRequestRunID == savedRun.id)
        #expect(harness.coordinator.transcriptFollowRequestRevision == 1)
        #expect(await router.callCount == 1)
        #expect(harness.coordinator.record.activity?.runs.count == 1)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .paused)
    }

    @Test
    func relayWorkDoesNotBlockNotificationConsumption() async throws {
        let router = DelayedBlockedRouter(delay: .seconds(1))
        let savedRun = run(status: .running, finalOutput: "Completed output")
        let harness = try await CoordinatorHarness(
            record: repositoryRecord(activityStatus: .paused, run: savedRun),
            router: router
        )
        defer { harness.remove() }
        let event = completedEvent(for: savedRun)
        let clock = ContinuousClock()
        let started = clock.now

        await harness.coordinator.handle(event)

        #expect(started.duration(to: clock.now) < .milliseconds(300))
        #expect(harness.coordinator.record.activity?.runs.last?.status == .routing)
        await waitUntil(timeout: .seconds(2)) {
            harness.coordinator.record.activity?.runs.last?.relayError != nil
        }
    }

    @Test
    func nonActionableDispositionExposesRelayRecovery() async throws {
        let savedRun = run(status: .completed, finalOutput: "Source result")
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: savedRun
        ))
        defer { harness.remove() }

        await harness.coordinator.useHandoff(
            text: "The source is blocked.",
            disposition: .blocked,
            label: "Blocked parser work"
        )

        let recoveredRun = try #require(harness.coordinator.record.activity?.runs.last)
        #expect(recoveredRun.status == .paused)
        #expect(recoveredRun.relayError?.isEmpty == false)
        #expect(recoveredRun.handoff?.sourceDisposition == .blocked)
        #expect(harness.coordinator.canResume)
    }

    @Test
    func terminalTurnNotificationIsHandledWhileClosing() async throws {
        let savedRun = run(status: .running, finalOutput: "Finished before close")
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: savedRun
        ))
        defer { harness.remove() }
        harness.coordinator.documentDidClose()

        await harness.coordinator.handle(completedEvent(for: savedRun))

        let closedRun = try #require(harness.coordinator.record.activity?.runs.last)
        #expect(closedRun.status == .routing)
        #expect(closedRun.finalOutput == "Finished before close")
        #expect(harness.coordinator.record.activity?.status == .paused)
    }

    @Test
    func loadRestoresAppendOnlyTranscriptBeforeRecovery() async throws {
        var savedRun = run(status: .completed)
        savedRun.transcript = "persisted\n"
        let record = repositoryRecord(activityStatus: .completed, run: savedRun)
        let root = temporaryRoot()
        let store = WorkspaceStore(rootURL: root)
        try await writeLegacyWorkspace(record, to: store)
        let activity = try #require(record.activity)
        try await store.appendTranscript(
            "persisted\nlatest delta\n",
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: savedRun.id
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }

        await coordinator.load()

        #expect(coordinator.record.activity?.runs.last?.transcript == "persisted\nlatest delta\n")
    }

    @Test
    func loadKeepsNewerMetadataWhenTheAppendLogIsOnlyAStalePrefix() async throws {
        var savedRun = run(status: .completed)
        savedRun.transcript = "persisted\nnewer metadata\n"
        let record = repositoryRecord(activityStatus: .completed, run: savedRun)
        let root = temporaryRoot()
        let store = WorkspaceStore(rootURL: root)
        try await writeLegacyWorkspace(record, to: store)
        let activity = try #require(record.activity)
        try await store.appendTranscript(
            "persisted\n",
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: savedRun.id
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }

        await coordinator.load()

        #expect(coordinator.record.activity?.runs.last?.transcript == "persisted\nnewer metadata\n")
    }

    @Test
    func loadsOnlyTheSelectedTranscriptAndEvictsItWhenSelectionChanges() async throws {
        var firstRun = run(status: .completed)
        firstRun.transcript = "first run transcript\n"
        let secondRun = RunRecord(
            sequence: 2,
            role: .reviewer,
            kind: .review,
            status: .completed,
            threadID: "reviewer-thread",
            turnID: "turn-2",
            model: "model",
            effort: "high",
            prompt: "Review",
            transcript: "second run transcript\n"
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/codeness-lazy-transcript-\(UUID().uuidString)",
            implementerThreadID: "implementer-thread",
            reviewerThreadID: "reviewer-thread",
            activity: ActivityRecord(
                goal: "Lazy transcript recovery",
                prompts: .builtInDefaults,
                status: .completed,
                runs: [firstRun, secondRun]
            )
        )
        let root = temporaryRoot()
        let store = WorkspaceStore(rootURL: root)
        try await store.save(record)
        try await store.saveViewState(
            RepositoryViewState(selectedRunID: firstRun.id),
            canonicalPath: record.canonicalPath
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }

        await coordinator.load()

        #expect(coordinator.record.activity?.runs[0].transcript == "first run transcript\n")
        #expect(coordinator.record.activity?.runs[1].transcript == "")

        coordinator.selectedRunID = secondRun.id
        await waitUntil {
            coordinator.record.activity?.runs[0].transcript == ""
                && coordinator.record.activity?.runs[1].transcript == "second run transcript\n"
        }

        #expect(coordinator.record.activity?.runs[0].transcript == "")
        #expect(coordinator.record.activity?.runs[1].transcript == "second run transcript\n")
    }

    @Test
    func pendingTranscriptFlushPreservesTextThatArrivesWhileTheRetryIsBlocked() async throws {
        var savedRun = run(status: .running)
        savedRun.transcript = "existing\n"
        let record = repositoryRecord(activityStatus: .paused, run: savedRun)
        let root = temporaryRoot()
        let baseStore = WorkspaceStore(rootURL: root)
        try await baseStore.save(record)
        let store = BlockingTranscriptRetryStore(base: baseStore)
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }
        await coordinator.load()

        await coordinator.handle(transcriptDelta(
            "first\n",
            itemID: "item-1",
            run: savedRun
        ))
        for _ in 0..<100 {
            if await store.appendCallCount() >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await store.appendCallCount() == 1)
        coordinator.selectedRunID = nil
        for _ in 0..<100 {
            if await store.appendCallCount() >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await store.appendCallCount() == 2)

        await coordinator.handle(transcriptDelta(
            "second\n",
            itemID: "item-2",
            run: savedRun
        ))
        await store.releaseBlockedRetry()

        for _ in 0..<100 {
            if await store.appendCallCount() >= 3 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let activity = try #require(record.activity)
        let recovered = try await baseStore.recoveredTranscript(
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: savedRun.id
        )

        #expect(await store.appendCallCount() == 3)
        #expect(recovered == "existing\nfirst\nsecond\n")
        #expect(coordinator.record.activity?.runs.last?.transcript == "")
    }

    @Test
    func closeCannotOvertakeABlockedFirstTranscriptAppend() async throws {
        var savedRun = run(status: .running)
        savedRun.transcript = "existing\n"
        let record = repositoryRecord(activityStatus: .paused, run: savedRun)
        let root = temporaryRoot()
        let baseStore = WorkspaceStore(rootURL: root)
        try await baseStore.save(record)
        let store = BlockingFirstTranscriptStore(base: baseStore, firstAppendFails: true)
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }
        await coordinator.load()

        let eventTask = Task {
            await coordinator.handle(transcriptDelta(
                "must survive close\n",
                itemID: "blocked-item",
                run: savedRun
            ))
        }
        await store.waitUntilFirstAppendIsBlocked()
        let closeTask = Task {
            await coordinator.prepareForClose(strategy: .immediate)
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(coordinator.pauseState == .saving)
        await store.releaseFirstAppend()
        await eventTask.value
        #expect(await closeTask.value != .ready)

        #expect(await coordinator.flushDocumentState())
        let activity = try #require(record.activity)
        let recovered = try await baseStore.recoveredTranscript(
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: savedRun.id
        )
        #expect(recovered == "existing\nmust survive close\n")
        #expect(await store.appendCallCount() == 2)
    }

    @Test
    func hydrationAwaitsTheInFlightAppendAndPresentsTheChunkExactlyOnce() async throws {
        var savedRun = run(status: .running)
        savedRun.transcript = "existing\n"
        let record = repositoryRecord(activityStatus: .paused, run: savedRun)
        let root = temporaryRoot()
        let baseStore = WorkspaceStore(rootURL: root)
        try await baseStore.save(record)
        let store = AppendCompletionGateStore(base: baseStore)
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }
        await coordinator.load()
        coordinator.selectedRunID = nil
        await waitUntil {
            coordinator.record.activity?.runs.last?.transcript == ""
        }
        await store.blockNextAppendAfterWriting()

        let eventTask = Task {
            await coordinator.handle(transcriptDelta(
                "live delta\n",
                itemID: "hydration-item",
                run: savedRun
            ))
        }
        await store.waitUntilAppendIsWrittenAndBlocked()
        coordinator.selectedRunID = savedRun.id
        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.record.activity?.runs.last?.transcript == "")

        await store.releaseBlockedAppend()
        await eventTask.value
        await waitUntil {
            coordinator.record.activity?.runs.last?.transcript == "existing\nlive delta\n"
        }
        #expect(coordinator.record.activity?.runs.last?.transcript == "existing\nlive delta\n")
    }

    @Test
    func deltaArrivingDuringTailHydrationIsPresentedExactlyOnce() async throws {
        var savedRun = run(status: .running)
        savedRun.transcript = "existing\n"
        let record = repositoryRecord(activityStatus: .paused, run: savedRun)
        let root = temporaryRoot()
        let baseStore = WorkspaceStore(rootURL: root)
        try await baseStore.save(record)
        let store = BlockingTranscriptTailStore(base: baseStore)
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }
        await coordinator.load()
        await store.blockNextTailRead()

        let hydration = Task {
            await coordinator.recoverAppendOnlyTranscript(runID: savedRun.id)
        }
        await store.waitUntilTailReadIsBlocked()
        await coordinator.handle(transcriptDelta(
            "during hydration\n",
            itemID: "tail-hydration-item",
            run: savedRun
        ))
        await store.releaseBlockedTailRead()
        await hydration.value

        #expect(
            coordinator.record.activity?.runs.last?.transcript
                == "existing\nduring hydration\n"
        )
        #expect(await coordinator.flushDocumentState())
        let activity = try #require(record.activity)
        #expect(
            try await baseStore.recoveredTranscript(
                repositoryPath: record.canonicalPath,
                activityID: activity.id,
                runID: savedRun.id
            ) == "existing\nduring hydration\n"
        )
    }

    @Test
    func repeatedIdenticalPendingChunkIsPresentedOnceAndRemainsExactAfterRetry() async throws {
        var savedRun = run(status: .running)
        savedRun.transcript = "repeat\n"
        let record = repositoryRecord(activityStatus: .paused, run: savedRun)
        let root = temporaryRoot()
        let baseStore = WorkspaceStore(rootURL: root)
        try await baseStore.save(record)
        let store = TranscriptAppendProbeStore(base: baseStore, failureCount: 2)
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }
        await coordinator.load()

        await coordinator.handle(transcriptDelta(
            "repeat\n",
            itemID: "repeated-item",
            run: savedRun
        ))
        for _ in 0..<100 {
            if await store.appendCallCount() >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        coordinator.selectedRunID = nil
        await waitUntil {
            coordinator.record.activity?.runs.last?.transcript == ""
        }
        coordinator.selectedRunID = savedRun.id
        await waitUntil {
            coordinator.record.activity?.runs.last?.transcript == "repeat\nrepeat\n"
        }
        #expect(await store.appendCallCount() == 2)

        #expect(await coordinator.flushDocumentState())
        await waitUntil {
            coordinator.record.activity?.runs.last?.transcript == "repeat\nrepeat\n"
        }
        let activity = try #require(record.activity)
        let recovered = try await baseStore.recoveredTranscript(
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: savedRun.id
        )
        #expect(recovered == "repeat\nrepeat\n")
        #expect(await store.appendCallCount() == 3)
    }

    @Test
    func manySmallTranscriptDeltasAreBatchedForDiskAndPresentation() async throws {
        var savedRun = run(status: .running)
        savedRun.transcript = "prefix:"
        let record = repositoryRecord(activityStatus: .paused, run: savedRun)
        let root = temporaryRoot()
        let baseStore = WorkspaceStore(rootURL: root)
        try await baseStore.save(record)
        let store = TranscriptAppendProbeStore(base: baseStore)
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }
        await coordinator.load()
        let baselineMutations = coordinator.transcriptPresentationMutationCount
        let deltaCount = 2_000

        for index in 0..<deltaCount {
            await coordinator.handle(transcriptDelta(
                "x",
                itemID: "burst-\(index)",
                run: savedRun
            ))
        }
        #expect(await coordinator.flushDocumentState())
        await waitUntil(timeout: .seconds(3)) {
            (coordinator.record.activity?.runs.last?.transcript ?? "").utf8.count
                == "prefix:".utf8.count + deltaCount
        }

        #expect(
            coordinator.record.activity?.runs.last?.transcript
                == "prefix:" + String(repeating: "x", count: deltaCount)
        )
        #expect(coordinator.transcriptPresentationMutationCount - baselineMutations < deltaCount / 10)
        #expect(await store.appendCallCount() < deltaCount / 10)
    }

    @Test
    func failedTranscriptFlushIgnoresEveryLaterDeltaWithoutGrowingRetainedState() async throws {
        let pendingLimit = RepositoryCoordinator.maximumPendingTranscriptUTF8Bytes
        let bufferedText = String(repeating: "b", count: pendingLimit)
        let firstRejectedText = "first rejected delta\n"
        let laterRejectedText = "later rejected delta\n"
        let laterDeltaCount = 500
        let savedRun = run(status: .running)
        let record = repositoryRecord(activityStatus: .paused, run: savedRun)
        let root = temporaryRoot()
        let baseStore = WorkspaceStore(rootURL: root)
        try await baseStore.save(record)
        let store = TranscriptAppendProbeStore(base: baseStore, failureCount: .max)
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }
        await coordinator.load()

        await coordinator.handle(transcriptDelta(
            bufferedText,
            itemID: "fills-pending-limit",
            run: savedRun
        ))
        for _ in 0..<100 {
            if await store.appendCallCount() >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await store.appendCallCount() == 1)

        await coordinator.handle(transcriptDelta(
            firstRejectedText,
            itemID: "triggers-fail-closed",
            run: savedRun
        ))
        for index in 0..<laterDeltaCount {
            await coordinator.handle(transcriptDelta(
                laterRejectedText,
                itemID: "rejected-after-failure-\(index)",
                run: savedRun
            ))
        }

        // The first rejected chunk records the diagnostic count and marks the
        // run failed. Exact active-run admission then ignores every later event
        // for that turn instead of continuing to parse or account hostile input.
        let expectedDroppedByteCount = firstRejectedText.utf8.count
        #expect(coordinator.transcriptIsBackpressured(for: savedRun.id))
        #expect(coordinator.pendingTranscriptUTF8ByteCount(for: savedRun.id) == pendingLimit)
        #expect(coordinator.droppedTranscriptUTF8ByteCount(for: savedRun.id) == expectedDroppedByteCount)
        #expect(await store.appendCallCount() == 2)
        #expect(coordinator.record.activity?.status == .paused)
        #expect(coordinator.record.activity?.runs.last?.status == .failed)
        #expect(coordinator.record.activity?.resumeCheckpoint == .recoverRun(savedRun.id))
        #expect(coordinator.errorMessage?.contains("\(expectedDroppedByteCount) UTF-8 bytes") == true)
    }

    @Test
    func singleOversizedTranscriptDeltaRetainsOnlyTheCappedPrefixWhenItsFlushFails() async throws {
        let pendingLimit = RepositoryCoordinator.maximumPendingTranscriptUTF8Bytes
        let rejectedSuffixByteCount = 4_097
        let oversizedText = String(repeating: "z", count: pendingLimit + rejectedSuffixByteCount)
        let savedRun = run(status: .running)
        let record = repositoryRecord(activityStatus: .paused, run: savedRun)
        let root = temporaryRoot()
        let baseStore = WorkspaceStore(rootURL: root)
        try await baseStore.save(record)
        let store = TranscriptAppendProbeStore(base: baseStore, failureCount: .max)
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }
        await coordinator.load()

        await coordinator.handle(transcriptDelta(
            oversizedText,
            itemID: "single-oversized-delta",
            run: savedRun
        ))

        #expect(coordinator.transcriptIsBackpressured(for: savedRun.id))
        #expect(coordinator.pendingTranscriptUTF8ByteCount(for: savedRun.id) == pendingLimit)
        #expect(coordinator.droppedTranscriptUTF8ByteCount(for: savedRun.id) == rejectedSuffixByteCount)
        #expect(await store.appendCallCount() == 1)
        #expect(coordinator.record.activity?.status == .paused)
        #expect(coordinator.record.activity?.runs.last?.status == .failed)
        #expect(coordinator.errorMessage?.contains("\(rejectedSuffixByteCount) UTF-8 bytes") == true)
    }

    @Test
    func tinyTranscriptDeltasCannotExceedThePendingChunkCapWhenPersistenceFails() async throws {
        let chunkLimit = RepositoryCoordinator.maximumPendingTranscriptChunkCount
        let savedRun = run(status: .running)
        let record = repositoryRecord(activityStatus: .paused, run: savedRun)
        let root = temporaryRoot()
        let baseStore = WorkspaceStore(rootURL: root)
        try await baseStore.save(record)
        let store = TranscriptAppendProbeStore(base: baseStore, failureCount: .max)
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }
        await coordinator.load()

        for _ in 0...chunkLimit {
            await coordinator.handle(transcriptDelta(
                "x",
                itemID: "one-streaming-item",
                run: savedRun
            ))
        }

        #expect(coordinator.transcriptIsBackpressured(for: savedRun.id))
        #expect(coordinator.pendingTranscriptChunkCount(for: savedRun.id) == chunkLimit)
        #expect(coordinator.pendingTranscriptUTF8ByteCount(for: savedRun.id) == chunkLimit)
        #expect(coordinator.droppedTranscriptUTF8ByteCount(for: savedRun.id) == 1)
        #expect(coordinator.record.activity?.status == .paused)
        #expect(coordinator.record.activity?.runs.last?.status == .failed)
    }

    @Test
    func transcriptTailReadNeverBeginsInsideAMultibyteScalar() async throws {
        let transcript = "head" + String(repeating: "🙂", count: 10) + "tail"
        var savedRun = run(status: .completed)
        savedRun.transcript = transcript
        let record = repositoryRecord(activityStatus: .completed, run: savedRun)
        let root = temporaryRoot()
        let store = WorkspaceStore(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.save(record)
        let activity = try #require(record.activity)

        let recovered = try await store.recoveredTranscriptTail(
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: savedRun.id,
            maximumUTF8Bytes: 7
        )

        #expect(recovered.wasTruncated)
        #expect(recovered.text == "tail")
        #expect(recovered.text.utf8.count <= 7)
    }

    @Test
    func largeSelectedTranscriptUsesABoundedTailButStartOverArchivesEveryByte() async throws {
        let maximumBytes = RepositoryCoordinator.maximumPresentedTranscriptUTF8Bytes
        let fullTranscript = String(repeating: "a", count: maximumBytes + 256 * 1_024)
            + "authoritative-tail\n"
        var savedRun = run(status: .interrupted)
        savedRun.transcript = fullTranscript
        let record = repositoryRecord(activityStatus: .completed, run: savedRun)
        let root = temporaryRoot()
        let baseStore = WorkspaceStore(rootURL: root)
        try await baseStore.save(record)
        let store = TranscriptAppendProbeStore(base: baseStore)
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }

        await coordinator.load()

        let presented = try #require(coordinator.record.activity?.runs.last?.transcript)
        #expect(presented.hasPrefix(RepositoryCoordinator.truncatedTranscriptMarker))
        #expect(presented.hasSuffix("authoritative-tail\n"))
        #expect(presented.utf8.count <= maximumBytes)
        #expect(await store.recoveredTranscriptTailCallCount() == 1)
        #expect(await store.recoveredTranscriptCallCount() == 0)

        await coordinator.startOver()

        let activity = try #require(record.activity)
        let repositoryDirectory = await baseStore.repositoryDirectory(
            canonicalPath: record.canonicalPath
        )
        let archiveURL = repositoryDirectory
            .appendingPathComponent("activity-archives", isDirectory: true)
            .appendingPathComponent("\(activity.id.uuidString).json")
        let archived = try JSONDecoder().decode(
            RepositoryRecord.self,
            from: Data(contentsOf: archiveURL)
        )
        #expect(archived.activity?.runs.last?.transcript == fullTranscript)
    }

    @Test
    func liveAppendPreservesTheTruncationMarkerOnALargeSelectedTranscript() async throws {
        let maximumBytes = RepositoryCoordinator.maximumPresentedTranscriptUTF8Bytes
        let fullTranscript = String(repeating: "a", count: maximumBytes + 256 * 1_024)
            + "loaded-tail\n"
        var savedRun = run(status: .running)
        savedRun.transcript = fullTranscript
        let record = repositoryRecord(activityStatus: .paused, run: savedRun)
        let root = temporaryRoot()
        let store = WorkspaceStore(rootURL: root)
        try await store.save(record)
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }

        await coordinator.load()
        #expect(
            coordinator.record.activity?.runs.last?.transcript.hasPrefix(
                RepositoryCoordinator.truncatedTranscriptMarker
            ) == true
        )

        await coordinator.handle(transcriptDelta(
            "live-suffix\n",
            itemID: "live-after-truncated-load",
            run: savedRun
        ))
        await waitUntil {
            coordinator.record.activity?.runs.last?.transcript.hasSuffix("live-suffix\n")
                == true
        }

        let presented = try #require(coordinator.record.activity?.runs.last?.transcript)
        #expect(presented.hasPrefix(RepositoryCoordinator.truncatedTranscriptMarker))
        #expect(presented.hasSuffix("live-suffix\n"))
        #expect(presented.utf8.count <= maximumBytes)
        #expect(await coordinator.flushDocumentState())
    }

    @Test
    func loadRestoresSelectionViewportAndWorkflowControls() async throws {
        let firstRun = run(status: .completed)
        var secondRun = run(status: .interrupted)
        secondRun = RunRecord(
            id: secondRun.id,
            sequence: 2,
            role: secondRun.role,
            kind: .review,
            status: secondRun.status,
            threadID: "reviewer-thread",
            turnID: secondRun.turnID,
            model: secondRun.model,
            effort: secondRun.effort,
            prompt: secondRun.prompt
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/codeness-view-state-" + UUID().uuidString,
            implementerThreadID: "implementer-thread",
            reviewerThreadID: "reviewer-thread",
            activity: ActivityRecord(
                goal: "Recovery",
                prompts: .builtInDefaults,
                status: .paused,
                runs: [firstRun, secondRun]
            )
        )
        let root = temporaryRoot()
        let store = WorkspaceStore(rootURL: root)
        try await store.save(record)
        let viewport = TranscriptViewportState(
            topCharacterOffset: 125,
            verticalOffset: 4,
            followsOutput: false
        )
        try await store.saveViewState(
            RepositoryViewState(
                selectedRunID: firstRun.id,
                transcriptViewports: [firstRun.id: viewport],
                sidebarWidth: 380,
                pauseAfterCurrent: true,
                detailPresentation: .result,
                detailSplitFraction: 0.62
            ),
            canonicalPath: record.canonicalPath
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }

        await coordinator.load()

        #expect(coordinator.selectedRunID == firstRun.id)
        #expect(coordinator.transcriptViewport(for: firstRun.id) == viewport)
        #expect(coordinator.pauseAfterCurrent)
        #expect(coordinator.viewState.sidebarWidth == 380)
        #expect(coordinator.runDetailPresentation == .result)
        #expect(coordinator.viewState.detailSplitFraction == 0.62)

        coordinator.updateRunDetailSplitFraction(0.99)
        #expect(await coordinator.flushDocumentState())
        #expect(coordinator.viewState.detailSplitFraction == 0.85)
        #expect(
            try await store.loadViewState(canonicalPath: record.canonicalPath)
                .detailSplitFraction == 0.85
        )
    }

    @Test
    func resumeReturnsAPausedWorkflowToAutomaticContinuation() async throws {
        let record = RepositoryRecord(
            canonicalPath: "/tmp/codeness-auto-resume-\(UUID().uuidString)",
            activity: ActivityRecord(
                goal: "Finish",
                prompts: .builtInDefaults,
                status: .paused,
                pendingAction: .complete,
                resumeCheckpoint: .perform(.complete)
            )
        )
        let harness = try await CoordinatorHarness(
            record: record,
            viewState: RepositoryViewState(pauseAfterCurrent: true)
        )
        defer { harness.remove() }
        #expect(harness.coordinator.pauseAfterCurrent)

        await harness.coordinator.resume()
        #expect(await harness.coordinator.flushDocumentState())

        #expect(!harness.coordinator.pauseAfterCurrent)
        #expect(!harness.coordinator.viewState.pauseAfterCurrent)
        let storedViewState = try await WorkspaceStore(rootURL: harness.root)
            .loadViewState(canonicalPath: record.canonicalPath)
        #expect(!storedViewState.pauseAfterCurrent)
    }

    @Test
    func fixCheckpointOverridesAnEarlierCompletionClaimAndQueuesMoreImplementation() async throws {
        let fixRun = RunRecord(
            sequence: 3,
            role: .implementer,
            kind: .fix,
            status: .paused,
            threadID: "implementer-thread",
            turnID: "fix-turn",
            model: "model",
            effort: "high",
            prompt: "Address review findings",
            finalOutput: "The findings are addressed. More implementation work remains."
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/codeness-fix-checkpoint-\(UUID().uuidString)",
            implementerThreadID: "implementer-thread",
            reviewerThreadID: "reviewer-thread",
            activity: ActivityRecord(
                goal: "Finish the whole repository goal",
                prompts: .builtInDefaults,
                status: .paused,
                runs: [fixRun],
                implementationClaimedComplete: true
            )
        )
        let harness = try await CoordinatorHarness(
            record: record,
            viewState: RepositoryViewState(pauseAfterCurrent: true)
        )
        defer { harness.remove() }

        await harness.coordinator.useHandoff(
            text: "The findings are addressed. More implementation work remains.",
            disposition: .fixCheckpoint,
            label: "Review fixes with remaining work"
        )

        let activity = try #require(harness.coordinator.record.activity)
        #expect(activity.status == .paused)
        #expect(activity.runs.last?.handoff?.sourceDisposition == .fixCheckpoint)
        #expect(!activity.implementationClaimedComplete)
        #expect(activity.pendingAction == .implement)
        #expect(activity.resumeCheckpoint == .perform(.implement))
        #expect(activity.completedAt == nil)
        #expect(harness.coordinator.canResume)
    }

    @Test
    func pausedActivityCanAmendItsGoalWithoutLosingHistoryOrSessions() async throws {
        let record = RepositoryRecord(
            canonicalPath: "/tmp/codeness-goal-amendment-\(UUID().uuidString)",
            implementerThreadID: "implementer-thread",
            reviewerThreadID: "reviewer-thread",
            activity: ActivityRecord(
                goal: "Original goal",
                prompts: .builtInDefaults,
                status: .paused,
                pendingAction: .implement,
                resumeCheckpoint: .perform(.implement)
            )
        )
        let harness = try await CoordinatorHarness(record: record)
        defer { harness.remove() }
        #expect(harness.coordinator.canAmendGoal)

        #expect(await harness.coordinator.amendGoal("Revised goal with an added constraint"))

        let activity = try #require(harness.coordinator.activity)
        let amendment = try #require(activity.goalAmendments.last)
        #expect(activity.goal == "Revised goal with an added constraint")
        #expect(amendment.previousGoal == "Original goal")
        #expect(amendment.revisedGoal == activity.goal)
        #expect(harness.coordinator.record.implementerThreadID == "implementer-thread")
        #expect(harness.coordinator.record.reviewerThreadID == "reviewer-thread")

        let persisted = try await WorkspaceStore(rootURL: harness.root)
            .load(canonicalPath: record.canonicalPath)
        #expect(persisted.activity?.goal == activity.goal)
        #expect(persisted.activity?.goalAmendments == activity.goalAmendments)
    }

    @Test
    func completedActivityCanAmendTheGoalUsedByStartOver() async throws {
        let record = RepositoryRecord(
            canonicalPath: "/tmp/codeness-completed-goal-amendment-\(UUID().uuidString)",
            activity: ActivityRecord(
                goal: "Completed goal",
                prompts: .builtInDefaults,
                status: .completed,
                completedAt: .now
            )
        )
        let harness = try await CoordinatorHarness(record: record)
        defer { harness.remove() }

        #expect(harness.coordinator.canAmendGoal)
        #expect(!harness.coordinator.goalAmendmentWillBeDeferred)
        #expect(await harness.coordinator.amendGoal("Revised rerun goal"))
        #expect(harness.coordinator.activity?.goal == "Revised rerun goal")
        #expect(harness.coordinator.activity?.pendingGoalAmendment == nil)

        await harness.coordinator.startOver()

        #expect(harness.coordinator.activity == nil)
        #expect(harness.coordinator.record.activityDraft?.goal == "Revised rerun goal")
    }

    @Test
    func invalidHandoffCredentialsBlockTheFirstImplementationTurn() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let path = "/tmp/codeness-invalid-handoff-\(UUID().uuidString)"
        let coordinator = RepositoryCoordinator(
            canonicalPath: path,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store,
            handoffConfigurationValidator: RejectingHandoffConfigurationValidator()
        )
        await coordinator.load()

        await coordinator.startActivity(goal: "Do not start Codex yet", prompts: .builtInDefaults)

        #expect(coordinator.activity == nil)
        #expect(coordinator.errorMessage == "Fixture handoff credentials are invalid.")
        #expect(coordinator.statusMessage == "Could not start activity")
    }

    @Test
    func startOverArchivesHistoryAndRestoresThePreviousEditableConfiguration() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let savedRun = run(status: .interrupted)
        let prompts = ActivityPrompts(
            implementation: "Implement one review-sized slice.",
            review: "Review this result: \(ActivityPrompts.implementationOutputPlaceholder)",
            fix: "Fix these findings: \(ActivityPrompts.reviewOutputPlaceholder)"
        )
        let settings = RepositorySettings(
            implementer: .init(model: "window-implementer", effort: "medium"),
            reviewer: .init(model: "window-reviewer", effort: "max"),
            fixer: .init(model: "window-fixer", effort: "high"),
            relay: RelaySettings(
                apiKeyFile: "/tmp/keys.json",
                apiKeyName: "TEST_KEY",
                selection: .init(model: "window-handoff", effort: "low")
            )
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/codeness-start-over-\(UUID().uuidString)",
            settings: settings,
            activity: ActivityRecord(
                goal: "Rebuild the parser from Docs/Parser.md",
                prompts: prompts,
                status: .completed,
                runs: [savedRun],
                completedAt: .now
            )
        )
        let frame = StoredWindowFrame(x: 10, y: 20, width: 1_100, height: 760)
        let oldViewport = TranscriptViewportState(
            topCharacterOffset: 120,
            verticalOffset: 8,
            followsOutput: false
        )
        try await store.save(record)
        try await store.saveViewState(
            RepositoryViewState(
                selectedRunID: savedRun.id,
                transcriptViewports: [savedRun.id: oldViewport],
                windowFrame: frame,
                sidebarWidth: 372,
                sidebarVisible: true,
                pauseAfterCurrent: true,
                detailPresentation: .transcript,
                detailSplitFraction: 0.58
            ),
            canonicalPath: record.canonicalPath
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        await coordinator.load()
        let archivedRecord = coordinator.record
        let archivedActivity = try #require(archivedRecord.activity)
        #expect(coordinator.canStartOver)

        await coordinator.startOver()

        #expect(coordinator.record.activity == nil)
        #expect(coordinator.record.activityDraft == ActivityConfigurationDraft(
            goal: "Rebuild the parser from Docs/Parser.md",
            prompts: prompts
        ))
        #expect(coordinator.record.implementerThreadID == nil)
        #expect(coordinator.record.reviewerThreadID == nil)
        #expect(coordinator.record.settings == settings)
        #expect(coordinator.selectedRunID == nil)
        #expect(coordinator.viewState.selectedRunID == nil)
        #expect(coordinator.viewState.transcriptViewports.isEmpty)
        #expect(coordinator.viewState.windowFrame == frame)
        #expect(coordinator.viewState.sidebarWidth == 372)
        #expect(!coordinator.viewState.sidebarVisible)
        #expect(coordinator.runDetailPresentation == .transcript)
        #expect(coordinator.viewState.detailSplitFraction == 0.58)
        #expect(!coordinator.pauseAfterCurrent)
        #expect(coordinator.canStartActivity)
        #expect(coordinator.statusMessage == "Configure this activity")
        #expect(coordinator.errorMessage == nil)

        let persistedReset = try await store.load(canonicalPath: record.canonicalPath)
        #expect(persistedReset == coordinator.record)
        let repositoryDirectory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        let archiveURL = repositoryDirectory
            .appendingPathComponent("activity-archives", isDirectory: true)
            .appendingPathComponent("\(archivedActivity.id.uuidString).json")
        let persistedArchive = try JSONDecoder().decode(
            RepositoryRecord.self,
            from: Data(contentsOf: archiveURL)
        )
        var expectedArchive = archivedRecord
        if let runIndices = expectedArchive.activity?.runs.indices {
            for runIndex in runIndices {
                expectedArchive.activity?.runs[runIndex].externalPayload = nil
            }
        }
        #expect(persistedArchive == expectedArchive)

        coordinator.updateActivityDraft(goal: "Edited before restarting", prompts: prompts)
        #expect(await coordinator.flushDocumentState())
        let persistedEdit = try await store.load(canonicalPath: record.canonicalPath)
        #expect(persistedEdit.activityDraft?.goal == "Edited before restarting")
        #expect(persistedEdit.activityDraft?.prompts == prompts)
    }

    @Test
    func loadFailureRemainsRetryableAndVisibleToTheHost() async throws {
        let root = temporaryRoot()
        let store = WorkspaceStore(rootURL: root)
        let path = "/tmp/codeness-corrupt-\(UUID().uuidString)"
        let directory = await store.repositoryDirectory(canonicalPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corruptData = Data("not json".utf8)
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        try corruptData.write(to: workspaceURL)
        let coordinator = RepositoryCoordinator(
            canonicalPath: path,
            appServer: CodexAppServerClient(),
            router: DelayedBlockedRouter(),
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }

        await coordinator.load()

        #expect(!coordinator.isLoaded)
        #expect(coordinator.errorMessage?.isEmpty == false)
        #expect(await coordinator.flushDocumentState())
        #expect(try Data(contentsOf: workspaceURL) == corruptData)
        #expect(await coordinator.prepareForClose(strategy: .immediate) == .ready)
        #expect(try Data(contentsOf: workspaceURL) == corruptData)
        coordinator.cancelClosePreparation()
        coordinator.clearError()
        await coordinator.load()
        #expect(coordinator.errorMessage?.isEmpty == false)
    }

    @Test
    func serverResolvedNotificationClearsMatchingInteraction() async throws {
        let savedRun = run(status: .running)
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: savedRun
        ))
        defer { harness.remove() }
        let requestID = JSONValue.integer(42)
        await harness.coordinator.handle(.request(
            id: requestID,
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("implementer-thread"),
                "turnId": .string("turn-1"),
                "questions": .array([])
            ]),
            rawLine: "request"
        ))
        #expect(harness.coordinator.pendingInteraction?.id == requestID)

        await harness.coordinator.handle(.notification(
            method: "serverRequest/resolved",
            params: .object([
                "threadId": .string("implementer-thread"),
                "requestId": requestID
            ]),
            rawLine: "resolved"
        ))

        #expect(harness.coordinator.pendingInteraction == nil)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .running)
    }

    @Test
    func unexpectedThreadCloseInterruptsLegacyRunAndPersistsRecoveryCheckpoint() async throws {
        let savedRun = run(status: .running)
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: savedRun
        ))
        defer { harness.remove() }
        await harness.coordinator.handle(.notification(
            method: "thread/closed",
            params: .object(["threadId": .string("implementer-thread")]),
            rawLine: "closed"
        ))

        #expect(harness.coordinator.record.activity?.status == .paused)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .interrupted)
        #expect(
            harness.coordinator.record.activity?.resumeCheckpoint
                == .recoverRun(savedRun.id)
        )
        #expect(
            harness.coordinator.record.activity?.runs.last?.relayError
                == "Codex closed the active thread unexpectedly."
        )
        #expect(harness.coordinator.pendingInteraction == nil)
    }

    @Test
    func tokenUsageNotificationsTrackTheRunDeltaWithoutCountingDuplicates() async throws {
        let savedRun = run(status: .running)
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: savedRun
        ))
        defer { harness.remove() }

        let first = tokenUsageParameters(
            total: RunTokenUsage(
                totalTokens: 10_100,
                inputTokens: 10_000,
                cachedInputTokens: 8_000,
                outputTokens: 100,
                reasoningOutputTokens: 20
            ),
            last: RunTokenUsage(
                totalTokens: 100,
                inputTokens: 90,
                cachedInputTokens: 80,
                outputTokens: 10,
                reasoningOutputTokens: 2
            )
        )
        let latest = tokenUsageParameters(
            total: RunTokenUsage(
                totalTokens: 10_600,
                inputTokens: 10_480,
                cachedInputTokens: 8_400,
                outputTokens: 120,
                reasoningOutputTokens: 25
            ),
            last: RunTokenUsage(
                totalTokens: 500,
                inputTokens: 480,
                cachedInputTokens: 400,
                outputTokens: 20,
                reasoningOutputTokens: 5
            )
        )

        await harness.coordinator.handle(.notification(
            method: "thread/tokenUsage/updated",
            params: first,
            rawLine: first.encodedString()
        ))
        await harness.coordinator.handle(.notification(
            method: "thread/tokenUsage/updated",
            params: latest,
            rawLine: latest.encodedString()
        ))
        await harness.coordinator.handle(.notification(
            method: "thread/tokenUsage/updated",
            params: latest,
            rawLine: latest.encodedString()
        ))

        let usage = try #require(
            harness.coordinator.record.activity?.runs.last?.tokenUsage
        )
        #expect(usage.totalTokens == 600)
        #expect(usage.inputTokens == 570)
        #expect(usage.cachedInputTokens == 480)
        #expect(usage.outputTokens == 30)
        #expect(usage.reasoningOutputTokens == 7)
        #expect(harness.coordinator.hasTokenUsageBaseline(for: savedRun.id))

        await harness.coordinator.handle(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string("implementer-thread"),
                "turn": .object([
                    "id": .string("turn-1"),
                    "items": .array([]),
                    "status": .string("interrupted")
                ])
            ]),
            rawLine: "interrupted"
        ))

        #expect(!harness.coordinator.hasTokenUsageBaseline(for: savedRun.id))
    }

    @Test
    func completedLegacyDeltaItemsDoNotAccumulateInCoordinatorState() async throws {
        let savedRun = run(status: .running)
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: savedRun
        ))
        defer { harness.remove() }

        for index in 0..<1_000 {
            let itemID = "legacy-completed-item-\(index)"
            await harness.coordinator.handle(.notification(
                method: "item/agentMessage/delta",
                params: .object([
                    "threadId": .string("implementer-thread"),
                    "turnId": .string("turn-1"),
                    "itemId": .string(itemID),
                    "delta": .string("x")
                ]),
                rawLine: "delta"
            ))
            await harness.coordinator.handle(.notification(
                method: "item/completed",
                params: .object([
                    "threadId": .string("implementer-thread"),
                    "turnId": .string("turn-1"),
                    "item": .object([
                        "id": .string(itemID),
                        "type": .string("agentMessage"),
                        "phase": .string("final_answer"),
                        "text": .string("x")
                    ])
                ]),
                rawLine: "completed"
            ))
        }

        #expect(harness.coordinator.trackedDeltaItemCount(for: savedRun.id) == 0)
    }

    @Test
    func queuesConcurrentServerInteractionsUntilEachOneResolves() async throws {
        let savedRun = run(status: .running)
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: savedRun
        ))
        defer { harness.remove() }
        let firstID = JSONValue.integer(44)
        let secondID = JSONValue.integer(45)
        for requestID in [firstID, secondID] {
            await harness.coordinator.handle(.request(
                id: requestID,
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string("implementer-thread"),
                    "turnId": .string("turn-1"),
                    "questions": .array([])
                ]),
                rawLine: "request"
            ))
        }

        #expect(harness.coordinator.pendingInteraction?.id == firstID)
        #expect(harness.coordinator.pendingInteractionCount == 2)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .awaitingApproval)

        await harness.coordinator.handle(.notification(
            method: "serverRequest/resolved",
            params: .object(["requestId": secondID]),
            rawLine: "resolved second"
        ))
        #expect(harness.coordinator.pendingInteraction?.id == firstID)
        #expect(harness.coordinator.pendingInteractionCount == 1)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .awaitingApproval)

        await harness.coordinator.handle(.notification(
            method: "serverRequest/resolved",
            params: .object(["requestId": firstID]),
            rawLine: "resolved first"
        ))
        #expect(harness.coordinator.pendingInteraction == nil)
        #expect(harness.coordinator.pendingInteractionCount == 0)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .running)
    }

    @Test
    func safetyStoppedLegacyRunCannotBePromotedByALateCompletedTerminal() async throws {
        let savedRun = run(status: .running, finalOutput: "Unsafe late result")
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: savedRun
        ))
        defer { harness.remove() }
        let request: AppServerEvent = .request(
            id: .integer(404),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("implementer-thread"),
                "turnId": .string("turn-1"),
                "questions": .array([])
            ]),
            rawLine: "duplicate"
        )
        await harness.coordinator.handle(request)
        await harness.coordinator.handle(request)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)

        await harness.coordinator.handle(completedEvent(for: savedRun))

        #expect(harness.coordinator.record.activity?.status == .paused)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)
        #expect(
            harness.coordinator.record.activity?.resumeCheckpoint
                == .recoverRun(savedRun.id)
        )
    }

    @Test
    func recoveryWaitsForSafetyStopTerminalBeforeAdmittingReplacementWork() async throws {
        let savedRun = run(status: .running, finalOutput: "Unsafe late result")
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: savedRun
        ))
        defer { harness.remove() }
        let request: AppServerEvent = .request(
            id: .integer(405),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("implementer-thread"),
                "turnId": .string("turn-1"),
                "questions": .array([])
            ]),
            rawLine: "duplicate"
        )
        await harness.coordinator.handle(request)
        await harness.coordinator.handle(request)
        #expect(harness.coordinator.interactionSafetyTerminationCount == 1)

        // Recovery must not retire the stop merely because the failed run has a
        // durable checkpoint. The old provider turn may still be changing the
        // repository until a terminal event confirms otherwise.
        await harness.coordinator.resume()
        #expect(harness.coordinator.interactionSafetyTerminationCount == 1)
        #expect(harness.coordinator.record.activity?.runs.count == 1)

        await harness.coordinator.handle(completedEvent(for: savedRun))
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)
        #expect(harness.coordinator.interactionSafetyTerminationCount == 0)
    }

    @Test
    func staleStartAndTerminalCannotBindAStartPendingReplacementOnTheSameThread() async throws {
        var oldRun = run(status: .failed, finalOutput: "Old result")
        oldRun.turnID = "old-turn"
        var replacementRun = run(status: .queued)
        replacementRun.turnID = nil
        var record = repositoryRecord(activityStatus: .paused, run: oldRun)
        record.activity?.runs.append(replacementRun)
        let harness = try await CoordinatorHarness(record: record)
        defer { harness.remove() }

        await harness.coordinator.handle(.notification(
            method: "turn/started",
            params: .object([
                "threadId": .string("implementer-thread"),
                "turn": .object([
                    "id": .string("old-turn"),
                    "status": .string("inProgress"),
                    "items": .array([])
                ])
            ]),
            rawLine: "stale started while replacement start is pending"
        ))
        await harness.coordinator.handle(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string("implementer-thread"),
                "turn": .object([
                    "id": .string("old-turn"),
                    "status": .string("completed"),
                    "items": .array([])
                ])
            ]),
            rawLine: "stale completed"
        ))

        var runs = try #require(harness.coordinator.record.activity?.runs)
        #expect(runs[0].status == .failed)
        #expect(runs[1].status == .queued)
        #expect(runs[1].turnID == nil)

        await harness.coordinator.handle(.notification(
            method: "turn/started",
            params: .object([
                "threadId": .string("implementer-thread"),
                "turn": .object([
                    "id": .string("replacement-turn"),
                    "status": .string("inProgress"),
                    "items": .array([])
                ])
            ]),
            rawLine: "replacement started"
        ))
        runs = try #require(harness.coordinator.record.activity?.runs)
        #expect(runs[1].status == .running)
        #expect(runs[1].turnID == "replacement-turn")
    }

    @Test
    func commandApprovalPreservesTheServersOrderedStructuredDecisions() async throws {
        let savedRun = run(status: .running)
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: savedRun
        ))
        defer { harness.remove() }
        let offered: [JSONValue] = [
            .string("decline"),
            .object([
                "acceptWithExecpolicyAmendment": .object([
                    "execpolicy_amendment": .array([.string("prefix_rule(pattern=[\"git\", \"status\"])" )])
                ])
            ]),
            .object([
                "applyNetworkPolicyAmendment": .object([
                    "network_policy_amendment": .object([
                        "action": .string("allow"),
                        "host": .string("example.com")
                    ])
                ])
            ]),
            .string("accept")
        ]

        await harness.coordinator.handle(.request(
            id: .integer(51),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("implementer-thread"),
                "turnId": .string("turn-1"),
                "command": .string("git status"),
                "availableDecisions": .array(offered)
            ]),
            rawLine: "approval"
        ))

        let decisions = try #require(harness.coordinator.pendingInteraction?.approvalDecisions)
        #expect(decisions.map(\.value) == offered)
        #expect(decisions.map(\.label) == [
            "Deny",
            "Approve and Remember Command",
            "Always Allow example.com",
            "Approve Once"
        ])
    }

    @Test
    func approvalChoicesFallBackOnlyWhenTheServerDoesNotSupplyTheField() async throws {
        let savedRun = run(status: .running)
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: savedRun
        ))
        defer { harness.remove() }

        await harness.coordinator.handle(.request(
            id: .integer(52),
            method: "item/fileChange/requestApproval",
            params: .object([
                "threadId": .string("implementer-thread"),
                "turnId": .string("turn-1")
            ]),
            rawLine: "legacy approval"
        ))
        #expect(
            harness.coordinator.pendingInteraction?.approvalDecisions.map(\.value)
                == ["accept", "acceptForSession", "decline", "cancel"].map { .string($0) }
        )

        await harness.coordinator.handle(.notification(
            method: "serverRequest/resolved",
            params: .object(["requestId": .integer(52)]),
            rawLine: "resolved"
        ))
        await harness.coordinator.handle(.request(
            id: .integer(53),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("implementer-thread"),
                "turnId": .string("turn-1"),
                "availableDecisions": .array([])
            ]),
            rawLine: "empty approval"
        ))
        #expect(harness.coordinator.pendingInteraction?.approvalDecisions.isEmpty == true)
    }

    @Test
    func lateServerResolutionDoesNotReopenACompletedTurn() async throws {
        let savedRun = run(status: .running, finalOutput: "Turn result")
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: savedRun
        ))
        defer { harness.remove() }
        let requestID = JSONValue.integer(43)
        await harness.coordinator.handle(.request(
            id: requestID,
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("implementer-thread"),
                "turnId": .string("turn-1"),
                "questions": .array([])
            ]),
            rawLine: "request"
        ))
        harness.coordinator.documentDidClose()
        await harness.coordinator.handle(completedEvent(for: savedRun))

        await harness.coordinator.handle(.notification(
            method: "serverRequest/resolved",
            params: .object([
                "threadId": .string("implementer-thread"),
                "requestId": requestID
            ]),
            rawLine: "resolved"
        ))

        #expect(harness.coordinator.pendingInteraction == nil)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .routing)
    }

    @Test
    func legacyTerminalClearsAnInteractionTheServerDidNotResolve() async throws {
        let savedRun = run(status: .running)
        let harness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: savedRun
        ))
        defer { harness.remove() }
        let requestID = JSONValue.integer(54)
        await harness.coordinator.handle(.request(
            id: requestID,
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("implementer-thread"),
                "turnId": .string("turn-1"),
                "questions": .array([])
            ]),
            rawLine: "request"
        ))
        #expect(harness.coordinator.pendingInteraction?.id == requestID)

        await harness.coordinator.handle(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string("implementer-thread"),
                "turn": .object([
                    "id": .string("turn-1"),
                    "items": .array([]),
                    "status": .string("interrupted")
                ])
            ]),
            rawLine: "interrupted"
        ))

        #expect(harness.coordinator.pendingInteraction == nil)
        #expect(harness.coordinator.pendingInteractionCount == 0)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .interrupted)
    }

    private func repositoryRecord(
        activityStatus: ActivityStatus,
        run: RunRecord,
        resumeCheckpoint: ResumeCheckpoint? = nil
    ) -> RepositoryRecord {
        RepositoryRecord(
            canonicalPath: "/tmp/codeness-repository-\(UUID().uuidString)",
            implementerThreadID: "implementer-thread",
            reviewerThreadID: "reviewer-thread",
            activity: ActivityRecord(
                goal: "Recovery",
                prompts: .builtInDefaults,
                status: activityStatus,
                runs: [run],
                resumeCheckpoint: resumeCheckpoint
            )
        )
    }

    private func run(
        status: RunStatus,
        finalOutput: String? = nil
    ) -> RunRecord {
        RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: status,
            threadID: "implementer-thread",
            turnID: "turn-1",
            model: "model",
            effort: "high",
            prompt: "Implement",
            finalOutput: finalOutput
        )
    }

    private func completedEvent(for run: RunRecord) -> AppServerEvent {
        .notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(run.threadID ?? "implementer-thread"),
                "turn": .object([
                    "id": .string(run.turnID ?? "turn-1"),
                    "status": .string("completed"),
                    "durationMs": .integer(10),
                    "items": .array([])
                ])
            ]),
            rawLine: "completed"
        )
    }

    private func transcriptDelta(
        _ text: String,
        itemID: String,
        run: RunRecord
    ) -> AppServerEvent {
        .notification(
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string(run.threadID ?? "implementer-thread"),
                "turnId": .string(run.turnID ?? "turn-1"),
                "itemId": .string(itemID),
                "delta": .string(text)
            ]),
            rawLine: text
        )
    }

    private func tokenUsageParameters(
        total: RunTokenUsage,
        last: RunTokenUsage
    ) -> JSONValue {
        .object([
            "threadId": .string("implementer-thread"),
            "turnId": .string("turn-1"),
            "tokenUsage": .object([
                "total": tokenUsageValue(total),
                "last": tokenUsageValue(last),
                "modelContextWindow": .integer(258_400)
            ])
        ])
    }

    private func tokenUsageValue(_ usage: RunTokenUsage) -> JSONValue {
        .object([
            "totalTokens": .integer(usage.totalTokens),
            "inputTokens": .integer(usage.inputTokens),
            "cachedInputTokens": .integer(usage.cachedInputTokens),
            "cacheWriteInputTokens": .integer(usage.cacheWriteInputTokens),
            "outputTokens": .integer(usage.outputTokens),
            "reasoningOutputTokens": .integer(usage.reasoningOutputTokens)
        ])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-recovery-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeLegacyWorkspace(
        _ record: RepositoryRecord,
        to store: WorkspaceStore
    ) async throws {
        let directory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(
            to: directory.appendingPathComponent("workspace.json"),
            options: .atomic
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private struct CoordinatorHarness {
    let coordinator: RepositoryCoordinator
    let root: URL

    init(
        record: RepositoryRecord,
        router: any HandoffRouting = DelayedBlockedRouter(),
        viewState: RepositoryViewState? = nil
    ) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-coordinator-\(UUID().uuidString)", isDirectory: true)
        let store = WorkspaceStore(rootURL: root)
        try await store.save(record)
        if let viewState {
            try await store.saveViewState(viewState, canonicalPath: record.canonicalPath)
        }
        coordinator = RepositoryCoordinator(
            canonicalPath: record.canonicalPath,
            appServer: CodexAppServerClient(),
            router: router,
            store: store
        )
        await coordinator.load()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor TranscriptAppendProbeStore: RepositoryWorkspaceStoring {
    private let base: WorkspaceStore
    private let failureCount: Int
    private var appendCalls = 0
    private var recoveredTranscriptCalls = 0
    private var recoveredTranscriptTailCalls = 0

    init(base: WorkspaceStore, failureCount: Int = 0) {
        self.base = base
        self.failureCount = failureCount
    }

    func load(
        canonicalPath: String,
        defaultSettings: RepositorySettings
    ) async throws -> RepositoryRecord {
        try await base.load(canonicalPath: canonicalPath, defaultSettings: defaultSettings)
    }

    func save(_ record: RepositoryRecord) async throws {
        try await base.save(record)
    }

    func archiveActivity(_ record: RepositoryRecord) async throws {
        try await base.archiveActivity(record)
    }

    func loadViewState(canonicalPath: String) async throws -> RepositoryViewState {
        try await base.loadViewState(canonicalPath: canonicalPath)
    }

    func saveViewState(
        _ state: RepositoryViewState,
        canonicalPath: String
    ) async throws {
        try await base.saveViewState(state, canonicalPath: canonicalPath)
    }

    func appendRawLine(
        _ line: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        // Raw protocol logging is orthogonal to the transcript batching asserted
        // by these tests; keep the burst deterministic and I/O-light.
    }

    func appendTranscript(
        _ text: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        appendCalls += 1
        if appendCalls <= failureCount {
            throw BlockingTranscriptStoreError.firstAppendFailure
        }
        try await base.appendTranscript(
            text,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func recoveredTranscript(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> String {
        recoveredTranscriptCalls += 1
        return try await base.recoveredTranscript(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func recoveredTranscriptTail(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID,
        maximumUTF8Bytes: Int
    ) async throws -> RecoveredTranscriptTail {
        recoveredTranscriptTailCalls += 1
        return try await base.recoveredTranscriptTail(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID,
            maximumUTF8Bytes: maximumUTF8Bytes
        )
    }

    func recoveredTokenUsage(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> RunTokenUsage? {
        try await base.recoveredTokenUsage(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func appendCallCount() -> Int {
        appendCalls
    }

    func recoveredTranscriptCallCount() -> Int {
        recoveredTranscriptCalls
    }

    func recoveredTranscriptTailCallCount() -> Int {
        recoveredTranscriptTailCalls
    }
}

private actor BlockingTranscriptRetryStore: RepositoryWorkspaceStoring {
    private let base: WorkspaceStore
    private var appendCalls = 0
    private var retryContinuation: CheckedContinuation<Void, Never>?

    init(base: WorkspaceStore) {
        self.base = base
    }

    func load(
        canonicalPath: String,
        defaultSettings: RepositorySettings
    ) async throws -> RepositoryRecord {
        try await base.load(canonicalPath: canonicalPath, defaultSettings: defaultSettings)
    }

    func save(_ record: RepositoryRecord) async throws {
        try await base.save(record)
    }

    func archiveActivity(_ record: RepositoryRecord) async throws {
        try await base.archiveActivity(record)
    }

    func loadViewState(canonicalPath: String) async throws -> RepositoryViewState {
        try await base.loadViewState(canonicalPath: canonicalPath)
    }

    func saveViewState(
        _ state: RepositoryViewState,
        canonicalPath: String
    ) async throws {
        try await base.saveViewState(state, canonicalPath: canonicalPath)
    }

    func appendRawLine(
        _ line: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        try await base.appendRawLine(
            line,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func appendTranscript(
        _ text: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        appendCalls += 1
        if appendCalls == 1 {
            throw BlockingTranscriptStoreError.firstAppendFailure
        }
        if appendCalls == 2 {
            await withCheckedContinuation { continuation in
                retryContinuation = continuation
            }
        }
        try await base.appendTranscript(
            text,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func recoveredTranscript(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> String {
        try await base.recoveredTranscript(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func recoveredTokenUsage(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> RunTokenUsage? {
        try await base.recoveredTokenUsage(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func releaseBlockedRetry() {
        retryContinuation?.resume()
        retryContinuation = nil
    }

    func appendCallCount() -> Int {
        appendCalls
    }
}

private enum BlockingTranscriptStoreError: Error {
    case firstAppendFailure
}

private actor BlockingFirstTranscriptStore: RepositoryWorkspaceStoring {
    private let base: WorkspaceStore
    private let firstAppendFails: Bool
    private var appendCalls = 0
    private var firstAppendIsBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(base: WorkspaceStore, firstAppendFails: Bool) {
        self.base = base
        self.firstAppendFails = firstAppendFails
    }

    func load(
        canonicalPath: String,
        defaultSettings: RepositorySettings
    ) async throws -> RepositoryRecord {
        try await base.load(canonicalPath: canonicalPath, defaultSettings: defaultSettings)
    }

    func save(_ record: RepositoryRecord) async throws {
        try await base.save(record)
    }

    func archiveActivity(_ record: RepositoryRecord) async throws {
        try await base.archiveActivity(record)
    }

    func loadViewState(canonicalPath: String) async throws -> RepositoryViewState {
        try await base.loadViewState(canonicalPath: canonicalPath)
    }

    func saveViewState(
        _ state: RepositoryViewState,
        canonicalPath: String
    ) async throws {
        try await base.saveViewState(state, canonicalPath: canonicalPath)
    }

    func appendRawLine(
        _ line: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        try await base.appendRawLine(
            line,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func appendTranscript(
        _ text: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        appendCalls += 1
        if appendCalls == 1 {
            firstAppendIsBlocked = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            if firstAppendFails {
                throw BlockingTranscriptStoreError.firstAppendFailure
            }
        }
        try await base.appendTranscript(
            text,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func recoveredTranscript(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> String {
        try await base.recoveredTranscript(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func recoveredTokenUsage(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> RunTokenUsage? {
        try await base.recoveredTokenUsage(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func waitUntilFirstAppendIsBlocked() async {
        guard !firstAppendIsBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseFirstAppend() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func appendCallCount() -> Int {
        appendCalls
    }
}

private actor AppendCompletionGateStore: RepositoryWorkspaceStoring {
    private let base: WorkspaceStore
    private var shouldBlockNextAppend = false
    private var appendIsBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(base: WorkspaceStore) {
        self.base = base
    }

    func load(
        canonicalPath: String,
        defaultSettings: RepositorySettings
    ) async throws -> RepositoryRecord {
        try await base.load(canonicalPath: canonicalPath, defaultSettings: defaultSettings)
    }

    func save(_ record: RepositoryRecord) async throws {
        try await base.save(record)
    }

    func archiveActivity(_ record: RepositoryRecord) async throws {
        try await base.archiveActivity(record)
    }

    func loadViewState(canonicalPath: String) async throws -> RepositoryViewState {
        try await base.loadViewState(canonicalPath: canonicalPath)
    }

    func saveViewState(
        _ state: RepositoryViewState,
        canonicalPath: String
    ) async throws {
        try await base.saveViewState(state, canonicalPath: canonicalPath)
    }

    func appendRawLine(
        _ line: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        try await base.appendRawLine(
            line,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func appendTranscript(
        _ text: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        try await base.appendTranscript(
            text,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        guard shouldBlockNextAppend else { return }
        shouldBlockNextAppend = false
        appendIsBlocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func recoveredTranscript(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> String {
        try await base.recoveredTranscript(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func recoveredTokenUsage(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> RunTokenUsage? {
        try await base.recoveredTokenUsage(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func blockNextAppendAfterWriting() {
        shouldBlockNextAppend = true
    }

    func waitUntilAppendIsWrittenAndBlocked() async {
        guard !appendIsBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseBlockedAppend() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor BlockingTranscriptTailStore: RepositoryWorkspaceStoring {
    private let base: WorkspaceStore
    private var shouldBlockNextTailRead = false
    private var tailReadIsBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(base: WorkspaceStore) {
        self.base = base
    }

    func load(
        canonicalPath: String,
        defaultSettings: RepositorySettings
    ) async throws -> RepositoryRecord {
        try await base.load(canonicalPath: canonicalPath, defaultSettings: defaultSettings)
    }

    func save(_ record: RepositoryRecord) async throws {
        try await base.save(record)
    }

    func archiveActivity(_ record: RepositoryRecord) async throws {
        try await base.archiveActivity(record)
    }

    func loadViewState(canonicalPath: String) async throws -> RepositoryViewState {
        try await base.loadViewState(canonicalPath: canonicalPath)
    }

    func saveViewState(
        _ state: RepositoryViewState,
        canonicalPath: String
    ) async throws {
        try await base.saveViewState(state, canonicalPath: canonicalPath)
    }

    func appendRawLine(
        _ line: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        try await base.appendRawLine(
            line,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func appendTranscript(
        _ text: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        try await base.appendTranscript(
            text,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func recoveredTranscript(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> String {
        try await base.recoveredTranscript(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func recoveredTranscriptTail(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID,
        maximumUTF8Bytes: Int
    ) async throws -> RecoveredTranscriptTail {
        let recovered = try await base.recoveredTranscriptTail(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID,
            maximumUTF8Bytes: maximumUTF8Bytes
        )
        guard shouldBlockNextTailRead else { return recovered }
        shouldBlockNextTailRead = false
        tailReadIsBlocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return recovered
    }

    func recoveredTokenUsage(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> RunTokenUsage? {
        try await base.recoveredTokenUsage(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func blockNextTailRead() {
        shouldBlockNextTailRead = true
        tailReadIsBlocked = false
    }

    func waitUntilTailReadIsBlocked() async {
        guard !tailReadIsBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseBlockedTailRead() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor DelayedBlockedRouter: HandoffRouting {
    private let delay: Duration
    private(set) var callCount = 0

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    func route(_ context: HandoffContext, settings: RelaySettings) async throws -> HandoffEnvelope {
        _ = settings
        callCount += 1
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return HandoffEnvelope(
            handoffText: context.source,
            sourceDisposition: .blocked,
            runLabel: "Blocked recovery"
        )
    }
}

private actor RecordingSummaryRouter: HandoffRouting {
    private(set) var summaryCallCount = 0

    func route(_ context: HandoffContext, settings: RelaySettings) async throws -> HandoffEnvelope {
        _ = context
        _ = settings
        return HandoffEnvelope(
            handoffText: "Unused",
            sourceDisposition: .implementationCheckpoint,
            runLabel: "Unused route"
        )
    }

    func summarizeWork(
        _ context: WorkSummaryContext,
        settings: RelaySettings
    ) async throws -> String {
        _ = context
        _ = settings
        summaryCallCount += 1
        return "Parser foundation is complete."
    }
}

private struct RejectingHandoffConfigurationValidator: HandoffConfigurationValidating {
    func validateLocal(_ settings: RelaySettings) async throws {
        _ = settings
        throw RejectedConfigurationError()
    }

    func testRemote(_ settings: RelaySettings) async throws {
        _ = settings
        throw RejectedConfigurationError()
    }
}

private struct RejectedConfigurationError: LocalizedError {
    var errorDescription: String? {
        "Fixture handoff credentials are invalid."
    }
}
