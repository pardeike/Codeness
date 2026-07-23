import Foundation
import Testing
@testable import CodenessCore

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
    func systemTerminationArmsAndConsumesOnlySafeAutomaticResumeCheckpoints() async throws {
        let completedRun = run(status: .routing, finalOutput: "Completed repository edits")
        let safeHarness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: completedRun,
            resumeCheckpoint: .routeCompletedRun(completedRun.id)
        ))
        defer { safeHarness.remove() }

        #expect(await safeHarness.coordinator.armResumeAfterSystemTerminationIfSafe())
        #expect(safeHarness.coordinator.viewState.resumeAfterSystemTermination == true)
        let persistedArmedState = try await WorkspaceStore(rootURL: safeHarness.root)
            .loadViewState(canonicalPath: safeHarness.coordinator.record.canonicalPath)
        #expect(persistedArmedState.resumeAfterSystemTermination == true)
        #expect(await safeHarness.coordinator.consumeResumeAfterSystemTerminationRequest())
        #expect(safeHarness.coordinator.viewState.resumeAfterSystemTermination == nil)
        let persistedConsumedState = try await WorkspaceStore(rootURL: safeHarness.root)
            .loadViewState(canonicalPath: safeHarness.coordinator.record.canonicalPath)
        #expect(persistedConsumedState.resumeAfterSystemTermination == nil)
        #expect(!(await safeHarness.coordinator.consumeResumeAfterSystemTerminationRequest()))

        let queuedRun = run(status: .completed, finalOutput: "Ready for review")
        let performHarness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: queuedRun,
            resumeCheckpoint: .perform(.review)
        ))
        defer { performHarness.remove() }

        #expect(await performHarness.coordinator.armResumeAfterSystemTerminationIfSafe())

        let interruptedRun = run(status: .interrupted)
        let recoveryHarness = try await CoordinatorHarness(record: repositoryRecord(
            activityStatus: .paused,
            run: interruptedRun,
            resumeCheckpoint: .recoverRun(interruptedRun.id)
        ))
        defer { recoveryHarness.remove() }

        #expect(!(await recoveryHarness.coordinator.armResumeAfterSystemTerminationIfSafe()))
        #expect(recoveryHarness.coordinator.viewState.resumeAfterSystemTermination == nil)
    }

    @Test
    func staleSystemTerminationRequestIsConsumedWithoutResumingRecovery() async throws {
        let interruptedRun = run(status: .interrupted)
        let harness = try await CoordinatorHarness(
            record: repositoryRecord(
                activityStatus: .paused,
                run: interruptedRun,
                resumeCheckpoint: .recoverRun(interruptedRun.id)
            ),
            viewState: RepositoryViewState(resumeAfterSystemTermination: true)
        )
        defer { harness.remove() }

        #expect(!(await harness.coordinator.consumeResumeAfterSystemTerminationRequest()))
        #expect(harness.coordinator.viewState.resumeAfterSystemTermination == nil)
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
    }

    @Test
    func routingRecoveryRetriesTheHandoffWithoutReplayingThePass() async throws {
        let router = DelayedBlockedRouter(delay: .milliseconds(10))
        let harness = try await CoordinatorHarness(
            record: repositoryRecord(
                activityStatus: .running,
                run: run(status: .routing, finalOutput: "Completed repository edits")
            ),
            router: router
        )
        defer { harness.remove() }

        #expect(harness.coordinator.record.activity?.status == .paused)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .routing)
        #expect(harness.coordinator.canResume)
        let routingRunID = try #require(harness.coordinator.record.activity?.runs.last?.id)
        #expect(harness.coordinator.record.activity?.resumeCheckpoint == .routeCompletedRun(routingRunID))

        await harness.coordinator.resume()
        await waitUntil { harness.coordinator.record.activity?.runs.last?.relayError != nil }

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
        try await store.save(record)
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
        try await store.save(record)
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
            implementerThreadID: "old-implementer-thread",
            reviewerThreadID: "old-reviewer-thread",
            settings: settings,
            activity: ActivityRecord(
                goal: "Rebuild the parser from Docs/Parser.md",
                prompts: prompts,
                status: .paused,
                runs: [savedRun]
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
        #expect(persistedArchive == archivedRecord)

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
