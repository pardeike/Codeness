import Foundation
import Testing
@testable import CodenessCore

@MainActor
struct GenericCoordinatorIntegrationTests {
    @Test
    func executesConfiguredProvidersAcrossPrefixLoopAndPostfixWithSessionReuse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = ScriptedAgentProvider(id: .codex, delay: .milliseconds(10))
        let claude = ScriptedAgentProvider(id: .claude, delay: .milliseconds(10))
        let providers = AgentProviderRegistry(providers: [codex, claude])
        let router = IterationCompletingWorkflowRouter(completionIteration: 2)
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-coordinator-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: providers,
            workflowRouter: router
        )
        let workflow = fullWorkflow()

        await coordinator.load()
        await coordinator.startActivity(goal: "Exercise every configured step", workflow: workflow)
        try await waitUntil {
            coordinator.record.activity?.status == .completed
        }
        try await waitUntilReleasedSessions(from: codex, count: 2)

        let activity = try #require(coordinator.record.activity)
        #expect(activity.runs.map { $0.workflowStep?.name } == [
            "Plan",
            "Code",
            "Review",
            "Code",
            "Review",
            "Summarize"
        ])
        #expect(activity.runs.map { $0.workflowStep?.loopIteration } == [
            1, 1, 1, 2, 2, 2
        ])
        #expect(activity.runs.map { $0.agentTarget?.providerID } == [
            .codex, .claude, .codex, .claude, .codex, .claude
        ])
        #expect(activity.runs.allSatisfy { $0.status == .completed })
        #expect(activity.runs.last?.workflowHandoff?.outcome == .continueWorkflow)
        #expect(activity.stepSessions["code"]?.providerSessionID != nil)
        #expect(activity.stepSessions["review"]?.providerSessionID != nil)
        #expect(activity.stepSessions["code"]?.lineage == 1)

        let claudeSessions = await claude.sessionRequests()
        let codeRequests = claudeSessions.filter { $0.name.hasSuffix("— Code") }
        #expect(codeRequests.count == 2)
        #expect(codeRequests.first?.existingSessionID == nil)
        #expect(codeRequests.last?.existingSessionID == activity.stepSessions["code"]?.providerSessionID)
        let runs = await claude.runRequests()
        #expect(runs.contains {
            $0.target.model == "sonnet"
                && $0.target.options.speed == .fast
        })
        #expect(await router.routeCount() == 6)

        coordinator.requestWorkOverviewSummary()
        try await waitUntil {
            coordinator.workOverviewSummaryText != nil
                && !coordinator.isGeneratingWorkOverviewSummary
        }
        #expect(
            coordinator.workOverviewSummaryText
                == "### Completed\n- Generic workflow summary."
        )
        #expect(await router.summaryCount() == 1)
        #expect(await router.summaryConfigurations() == [workflow.coordinator])

        let persisted = try await WorkspaceStore(rootURL: root).load(
            canonicalPath: coordinator.record.canonicalPath
        )
        var expectedPersistedActivity = activity
        for runIndex in expectedPersistedActivity.runs.indices {
            expectedPersistedActivity.runs[runIndex].transcript = ""
            expectedPersistedActivity.runs[runIndex].prompt = ""
            expectedPersistedActivity.runs[runIndex].finalOutput = nil
            expectedPersistedActivity.runs[runIndex].externalPayload = true
        }
        if let lastIndex = expectedPersistedActivity.runs.indices.last {
            expectedPersistedActivity.runs[lastIndex].prompt = activity.runs[lastIndex].prompt
            expectedPersistedActivity.runs[lastIndex].finalOutput = activity.runs[lastIndex].finalOutput
        }
        #expect(persisted.activity == expectedPersistedActivity)
        #expect(Set(await codex.releasedSessionIDs()) == [
            "codex-session-1", "codex-session-2"
        ])
        #expect(Set(await claude.releasedSessionIDs()) == [
            "claude-session-1", "claude-session-2"
        ])

        await coordinator.startOver()
        #expect(coordinator.record.activity == nil)
        #expect(Set(await codex.releasedSessionIDs()) == [
            "codex-session-1", "codex-session-2"
        ])
        #expect(Set(await claude.releasedSessionIDs()) == [
            "claude-session-1", "claude-session-2"
        ])
    }

    @Test
    func completionDetachesRuntimeSessionEvenWhenFinalSaveFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = ScriptedAgentProvider(id: .codex, delay: .zero)
        let base = WorkspaceStore(rootURL: root)
        let store = FailingCompletedGenericStore(base: base)
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-completion-detach-debt-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: store,
            agentProviders: AgentProviderRegistry(providers: [codex]),
            workflowRouter: IterationCompletingWorkflowRouter(completionIteration: 1)
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Retry a failed completion checkpoint",
            workflow: singleStepWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.status == .completed
                && coordinator.errorMessage?.contains("final state could not be saved") == true
        }

        try await waitUntilReleasedSessions(from: codex, count: 1)
        #expect(await coordinator.flushDocumentState())
        #expect(await codex.releasedSessionIDs() == ["codex-session-1"])

        #expect(await coordinator.prepareForClose(strategy: .immediate) == .ready)
        #expect(await codex.releasedSessionIDs() == ["codex-session-1"])
        await coordinator.startOver()
        #expect(await codex.releasedSessionIDs() == ["codex-session-1"])
    }

    @Test
    func concurrentCompletionSavesShareOneInFlightSessionRelease() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseGate = SessionReleaseGate()
        let codex = ScriptedAgentProvider(
            id: .codex,
            delay: .zero,
            sessionReleaseGate: releaseGate
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-in-flight-release-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: AgentProviderRegistry(providers: [codex]),
            workflowRouter: IterationCompletingWorkflowRouter(completionIteration: 1)
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Deduplicate concurrent cleanup",
            workflow: singleStepWorkflow()
        )
        await releaseGate.waitUntilReached()
        let concurrentSave = Task { await coordinator.flushDocumentState() }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await codex.releasedSessionIDs() == ["codex-session-1"])
        await releaseGate.release()
        #expect(await concurrentSave.value)
        try await waitUntil {
            coordinator.record.activity?.status == .completed
        }
        #expect(await codex.releasedSessionIDs() == ["codex-session-1"])
    }

    @Test
    func completedSessionIDRemainsResumeMetadataAndIsNotReleasedAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalPath = "/tmp/generic-durable-detach-\(UUID().uuidString)"
        let store = WorkspaceStore(rootURL: root)
        let firstProvider = ScriptedAgentProvider(id: .codex, delay: .zero)
        let firstCoordinator = RepositoryCoordinator(
            canonicalPath: canonicalPath,
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: store,
            agentProviders: AgentProviderRegistry(providers: [firstProvider]),
            workflowRouter: IterationCompletingWorkflowRouter(completionIteration: 1)
        )

        await firstCoordinator.load()
        await firstCoordinator.startActivity(
            goal: "Preserve the completed session identifier",
            workflow: singleStepWorkflow()
        )
        try await waitUntilReleasedSessions(from: firstProvider, count: 1)
        #expect(await firstProvider.releasedSessionIDs() == ["codex-session-1"])

        let secondProvider = ScriptedAgentProvider(id: .codex, delay: .zero)
        let reopened = RepositoryCoordinator(
            canonicalPath: canonicalPath,
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: AgentProviderRegistry(providers: [secondProvider]),
            workflowRouter: IterationCompletingWorkflowRouter(completionIteration: 1)
        )
        await reopened.load()

        #expect(
            reopened.record.activity?.stepSessions["work"]?.providerSessionID
                == "codex-session-1"
        )
        #expect(await reopened.prepareForClose(strategy: .immediate) == .ready)
        #expect((await secondProvider.releasedSessionIDs()).isEmpty)
    }

    @Test
    func coldOpenIgnoresHistoricalSessionsFromAnUnavailableProvider() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalPath = "/tmp/generic-cold-close-\(UUID().uuidString)"
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let workflow = WorkflowTemplate(
            id: "historical-claude",
            name: "Historical Claude",
            summary: "Cold-close fixture",
            steps: [step("work", "Work", .loop, target)],
            coordinator: WorkflowCoordinatorConfiguration(
                target: target,
                instructions: "Route results."
            )
        )
        let historicalSessionID = "0a9d100a-c721-4c70-b6e8-bbb896753769"
        let historicalRun = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: historicalSessionID,
            turnID: "completed-execution",
            model: target.model,
            effort: "high",
            prompt: "Historical work",
            completedAt: .now,
            workflowStep: WorkflowStepSnapshot(
                step: workflow.steps[0],
                loopIteration: 1
            ),
            agentTarget: target,
            sessionLineage: 1,
            workflowHandoff: WorkflowHandoff(
                text: "Continue later.",
                outcome: .continueWorkflow,
                runLabel: "Work 1"
            )
        )
        let activity = ActivityRecord(
            goal: "Resume the historical workflow later",
            prompts: .builtInDefaults,
            status: .paused,
            runs: [historicalRun],
            workflow: workflow,
            workflowCursor: WorkflowCursor(
                section: .loop,
                stepIndex: 0,
                loopIteration: 2
            ),
            workflowResumeCheckpoint: .perform(WorkflowCursor(
                section: .loop,
                stepIndex: 0,
                loopIteration: 2
            )),
            stepSessions: [
                "work": WorkflowSessionState(
                    stepID: "work",
                    target: target,
                    providerSessionID: historicalSessionID
                )
            ]
        )
        let store = WorkspaceStore(rootURL: root)
        try await store.save(RepositoryRecord(
            canonicalPath: canonicalPath,
            activity: activity
        ))
        let coordinator = RepositoryCoordinator(
            canonicalPath: canonicalPath,
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: store,
            agentProviders: AgentProviderRegistry(),
            workflowRouter: IterationCompletingWorkflowRouter(completionIteration: 1)
        )

        await coordinator.load()

        #expect(await coordinator.prepareForClose(strategy: .immediate) == .ready)
        #expect(
            coordinator.record.activity?.stepSessions["work"]?.providerSessionID
                == historicalSessionID
        )
        #expect(coordinator.record.activity?.runs.first?.threadID == historicalSessionID)
    }

    @Test
    func loadsOnlySelectedRunPayloadAndHydratesAnotherOnSelection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalPath = "/tmp/generic-run-payloads-\(UUID().uuidString)"
        let runs = (1...3).map { sequence in
            RunRecord(
                sequence: sequence,
                role: .implementer,
                kind: .implementation,
                status: .completed,
                threadID: "session-\(sequence)",
                model: "gpt-test",
                effort: "high",
                prompt: "prompt-\(sequence)",
                finalOutput: "result-\(sequence)",
                completedAt: .now
            )
        }
        let activity = ActivityRecord(
            goal: "Keep historical payloads off the active heap",
            prompts: .builtInDefaults,
            status: .completed,
            runs: runs,
            completedAt: .now
        )
        let store = WorkspaceStore(rootURL: root)
        try await store.save(RepositoryRecord(
            canonicalPath: canonicalPath,
            activity: activity
        ))
        try await store.saveViewState(
            RepositoryViewState(selectedRunID: runs[0].id),
            canonicalPath: canonicalPath
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: canonicalPath,
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: store
        )

        await coordinator.load()

        #expect(coordinator.record.activity?.runs[0].prompt == "prompt-1")
        #expect(coordinator.record.activity?.runs[1].prompt == "")
        #expect(coordinator.record.activity?.runs[2].prompt == "")

        coordinator.selectedRunID = runs[1].id
        try await waitUntil {
            coordinator.selectedRun?.prompt == "prompt-2"
        }
        #expect(coordinator.selectedRun?.finalOutput == "result-2")
        #expect(coordinator.record.activity?.runs[0].prompt == "")
        #expect(coordinator.record.activity?.runs[2].prompt == "")
    }

    @Test
    func changingProviderModelOrModeAfterAPauseCreatesANewStepLineage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = ScriptedAgentProvider(id: .codex, delay: .milliseconds(120))
        let claude = ScriptedAgentProvider(id: .claude, delay: .milliseconds(120))
        let providers = AgentProviderRegistry(providers: [codex, claude])
        let router = IterationCompletingWorkflowRouter(completionIteration: 99)
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-lineage-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: providers,
            workflowRouter: router
        )
        let original = loopWorkflow()

        await coordinator.load()
        await coordinator.startActivity(goal: "Pause between cycles", workflow: original)
        try await waitUntil {
            coordinator.activeRun?.workflowStep?.id == "review"
                && coordinator.activeRun?.status == .running
        }
        coordinator.setPauseAfterCurrent(true)
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.workflowCursor?.loopIteration == 2
        }

        var updated = try #require(coordinator.record.activity?.workflow)
        let codeIndex = try #require(updated.steps.firstIndex { $0.id == "code" })
        updated.steps[codeIndex].target = AgentTarget(
            providerID: .claude,
            model: "opus",
            options: AgentExecutionOptions(
                effort: "max",
                mode: .plan,
                speed: .fast
            )
        )

        #expect(await coordinator.updateWorkflowPreferences(updated))
        let session = try #require(
            coordinator.record.activity?.stepSessions["code"]
        )
        #expect(session.lineage == 2)
        #expect(session.providerSessionID == nil)
        #expect(session.target == updated.steps[codeIndex].target)
        #expect(coordinator.record.activity?.stepSessions["review"]?.lineage == 1)
        let releasedCodexSessions = await codex.releasedSessionIDs()
        #expect(releasedCodexSessions == ["codex-session-1"])
    }

    @Test
    func changingInstructionsEffortAndSpeedWhilePausedPreservesTheStepLineage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = ScriptedAgentProvider(
            id: .codex,
            delay: .zero,
            failuresBeforeStart: 1
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-prompt-edit-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: AgentProviderRegistry(providers: [codex]),
            workflowRouter: IterationCompletingWorkflowRouter(completionIteration: 1)
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Edit prompts without losing context",
            workflow: singleStepWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.runs.last?.status == .failed
        }

        let previousSession = try #require(
            coordinator.record.activity?.stepSessions["work"]
        )
        var updated = try #require(coordinator.record.activity?.workflow)
        updated.steps[0].instructions = "Use the newly planned work."
        updated.steps[0].target.options.effort = "max"
        updated.steps[0].target.options.speed = .fast
        updated.coordinator.instructions = "Route the next handoff using the new policy."

        #expect(await coordinator.updateWorkflowPreferences(updated))
        #expect(coordinator.record.activity?.workflow == updated)
        let updatedSession = try #require(
            coordinator.record.activity?.stepSessions["work"]
        )
        #expect(updatedSession.lineage == previousSession.lineage)
        #expect(updatedSession.providerSessionID == previousSession.providerSessionID)
        #expect(updatedSession.target == updated.steps[0].target)
    }

    @Test
    func changingWorkflowTopologyWhilePausedIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = ScriptedAgentProvider(
            id: .codex,
            delay: .zero,
            failuresBeforeStart: 1
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-topology-edit-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: AgentProviderRegistry(providers: [codex]),
            workflowRouter: IterationCompletingWorkflowRouter(completionIteration: 1)
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Keep the active workflow shape stable",
            workflow: loopWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.runs.last?.status == .failed
        }

        let original = try #require(coordinator.record.activity?.workflow)
        var renamed = original
        renamed.steps[0].name = "Renamed"
        #expect(!(await coordinator.updateWorkflowPreferences(renamed)))

        var reordered = original
        reordered.steps.swapAt(0, 1)
        #expect(!(await coordinator.updateWorkflowPreferences(reordered)))
        #expect(coordinator.record.activity?.workflow == original)
        #expect(coordinator.errorMessage?.contains("order are frozen") == true)
    }

    @Test
    func neverStartsAProviderWhenTheQueuedGenericRunCannotBePersisted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = WorkspaceStore(rootURL: root)
        let store = FailingQueuedGenericStore(base: base)
        let codex = ScriptedAgentProvider(id: .codex, delay: .zero)
        let providers = AgentProviderRegistry(providers: [codex])
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-durability-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: store,
            agentProviders: providers,
            workflowRouter: IterationCompletingWorkflowRouter(completionIteration: 1)
        )
        let workflow = singleStepWorkflow()

        await coordinator.load()
        await coordinator.startActivity(goal: "Persist before launch", workflow: workflow)

        let activity = try #require(coordinator.record.activity)
        #expect(activity.status == .paused)
        #expect(activity.runs.isEmpty)
        #expect(activity.workflowCursor == WorkflowCursor(section: .loop, stepIndex: 0))
        #expect(activity.workflowResumeCheckpoint == .perform(
            WorkflowCursor(section: .loop, stepIndex: 0)
        ))
        #expect(await codex.startCount() == 0)
        #expect(coordinator.errorMessage?.contains("before starting it") == true)
        let persisted = try await base.load(canonicalPath: coordinator.record.canonicalPath)
        #expect(persisted.activity?.status == .paused)
        #expect(persisted.activity?.runs.isEmpty == true)
    }

    @Test
    func resumingAFailedStepUsesItsSavedPromptWithoutResumingAMissingProviderSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = ScriptedAgentProvider(
            id: .codex,
            delay: .zero,
            failuresBeforeStart: 1
        )
        let providers = AgentProviderRegistry(providers: [codex])
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-unstarted-session-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: providers,
            workflowRouter: IterationCompletingWorkflowRouter(completionIteration: 1)
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Recover without resuming a missing session",
            workflow: singleStepWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.runs.last?.status == .failed
        }

        let failedPrompt = try #require(
            coordinator.record.activity?.runs.last?.prompt
        )
        var updated = try #require(coordinator.record.activity?.workflow)
        updated.steps[0].instructions = "NEW INSTRUCTIONS FOR A LATER FRESH RUN"
        #expect(await coordinator.updateWorkflowPreferences(updated))

        await coordinator.resume()
        try await waitUntil {
            coordinator.record.activity?.status == .completed
        }

        let requests = await codex.sessionRequests()
        #expect(requests.count == 2)
        #expect(requests.map(\.existingSessionID) == [nil, nil])
        #expect(
            coordinator.record.activity?.stepSessions["work"]?.providerSessionID
                == "codex-session-2"
        )
        let recoveryPrompt = try #require(
            coordinator.record.activity?.runs.last?.prompt
        )
        #expect(recoveryPrompt.contains("PREVIOUS STEP INSTRUCTION"))
        #expect(recoveryPrompt.contains(failedPrompt))
        #expect(!recoveryPrompt.contains("NEW INSTRUCTIONS FOR A LATER FRESH RUN"))
    }

    @Test
    func changingProviderBeforeRecoveringAFailedStepUsesTheNewProviderImmediately() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = ScriptedAgentProvider(
            id: .codex,
            delay: .zero,
            failuresBeforeStart: 1
        )
        let claude = ScriptedAgentProvider(id: .claude, delay: .zero)
        let providers = AgentProviderRegistry(providers: [codex, claude])
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-provider-switch-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: providers,
            workflowRouter: IterationCompletingWorkflowRouter(completionIteration: 1)
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Switch providers before recovery",
            workflow: singleStepWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.runs.last?.status == .failed
        }

        var updated = try #require(coordinator.record.activity?.workflow)
        updated.steps[0].target = AgentTarget(
            providerID: .claude,
            model: "sonnet"
        )
        #expect(await coordinator.updateWorkflowPreferences(updated))

        await coordinator.resume()
        try await waitUntil {
            coordinator.record.activity?.status == .completed
        }

        let activity = try #require(coordinator.record.activity)
        #expect(activity.runs.map { $0.agentTarget?.providerID } == [.codex, .claude])
        #expect(activity.stepSessions["work"]?.lineage == 2)
        #expect(activity.stepSessions["work"]?.target == updated.steps[0].target)
        let claudeSessions = await claude.sessionRequests()
        #expect(claudeSessions.count == 1)
        #expect(claudeSessions[0].existingSessionID == nil)
    }

    @Test
    func restartingAFailedStepPreservesHistoryAndUsesAFreshSessionLineage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = ScriptedAgentProvider(
            id: .codex,
            delay: .zero,
            failuresBeforeStart: 1
        )
        let providers = AgentProviderRegistry(providers: [codex])
        let router = IterationCompletingWorkflowRouter(completionIteration: 1)
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-fresh-restart-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: providers,
            workflowRouter: router
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Restart the failed step cleanly",
            workflow: singleStepWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.runs.last?.status == .failed
        }

        let failedRun = try #require(coordinator.record.activity?.runs.last)
        #expect(coordinator.canRestartWorkflowStep(failedRun.id))

        var updated = try #require(coordinator.record.activity?.workflow)
        updated.steps[0].instructions = "USE THE CURRENT PLANNED WORK"
        updated.coordinator.instructions = "USE THE EDITED HANDOFF POLICY"
        #expect(await coordinator.updateWorkflowPreferences(updated))
        #expect(coordinator.record.activity?.stepSessions["work"]?.lineage == 1)
        coordinator.selectedRunID = nil
        coordinator.updateTranscriptViewport(
            for: failedRun.id,
            state: TranscriptViewportState(
                topCharacterOffset: 100,
                verticalOffset: 3,
                followsOutput: false
            )
        )

        await coordinator.restartWorkflowStep(failedRun.id)
        try await waitUntil {
            coordinator.record.activity?.status == .completed
        }
        try await waitUntilReleasedSessions(from: codex, count: 2)

        let activity = try #require(coordinator.record.activity)
        #expect(activity.runs.count == 2)
        #expect(activity.runs[0].id == failedRun.id)
        #expect(activity.runs[0].status == .failed)
        #expect(activity.runs[1].status == .completed)
        #expect(activity.runs[1].prompt.contains("FRESH STEP RESTART"))
        #expect(activity.runs[1].prompt.contains("current repository state before editing"))
        #expect(activity.runs[1].prompt.contains("USE THE CURRENT PLANNED WORK"))
        #expect(coordinator.selectedRunID == activity.runs[1].id)
        #expect(coordinator.transcriptViewport(for: activity.runs[1].id).followsOutput)
        #expect(activity.stepSessions["work"]?.lineage == 2)
        #expect(!coordinator.canRestartWorkflowStep(failedRun.id))
        #expect(
            await router.configurations().last?.instructions
                == "USE THE EDITED HANDOFF POLICY"
        )

        let sessions = await codex.sessionRequests()
        #expect(sessions.count == 2)
        #expect(sessions.map(\.existingSessionID) == [nil, nil])
        #expect(Set(await codex.releasedSessionIDs()) == [
            "codex-session-1", "codex-session-2"
        ])
    }

    @Test
    func retryingABlockedStepPreservesItsSessionInsteadOfReclassifyingItsResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = ScriptedAgentProvider(id: .codex, delay: .zero)
        let router = BlockingOnceWorkflowRouter()
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-blocked-retry-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: AgentProviderRegistry(providers: [codex]),
            workflowRouter: router
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Retry the blocked step",
            workflow: singleStepWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.runs.last?.workflowHandoff?.outcome == .blocked
        }

        let blockedRun = try #require(coordinator.record.activity?.runs.last)
        #expect(coordinator.canRestartWorkflowStep(blockedRun.id))

        await coordinator.retryWorkflowStep(blockedRun.id)
        try await waitUntil {
            coordinator.record.activity?.status == .completed
        }

        let activity = try #require(coordinator.record.activity)
        #expect(activity.runs.count == 2)
        #expect(activity.runs[0].id == blockedRun.id)
        #expect(activity.runs[0].status == .paused)
        #expect(activity.runs[0].workflowHandoff?.outcome == .blocked)
        #expect(activity.runs[1].status == .completed)
        #expect(activity.runs[1].prompt.contains("RETRY CURRENT STEP"))
        #expect(activity.runs.map(\.workflowStep?.loopIteration) == [1, 1])
        #expect(activity.stepSessions["work"]?.lineage == 1)
        #expect(await router.routeCount() == 2)

        let sessions = await codex.sessionRequests()
        #expect(sessions.count == 2)
        #expect(sessions.map(\.existingSessionID) == [nil, "codex-session-1"])
    }

    @Test
    func blockedStepRetryFallsBackSilentlyWhenSessionPreparationFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = ScriptedAgentProvider(
            id: .codex,
            delay: .zero,
            rejectsExistingSessions: true
        )
        let router = BlockingOnceWorkflowRouter()
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-blocked-prepare-fallback-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: AgentProviderRegistry(providers: [codex]),
            workflowRouter: router
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Fall back after session preparation fails",
            workflow: singleStepWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.runs.last?.workflowHandoff?.outcome == .blocked
        }

        let blockedRun = try #require(coordinator.record.activity?.runs.last)
        await coordinator.retryWorkflowStep(blockedRun.id)
        try await waitUntil {
            coordinator.record.activity?.status == .completed
                && coordinator.record.activity?.runs.count == 2
                && coordinator.record.activity?.runs.last?.status == .completed
        }
        try await waitUntilReleasedSessions(from: codex, count: 2)

        let activity = try #require(coordinator.record.activity)
        #expect(activity.runs.count == 2)
        let retryRun = try #require(activity.runs.dropFirst().first)
        #expect(retryRun.status == .completed)
        #expect(retryRun.sessionLineage == 2)
        #expect(retryRun.prompt.contains("RETRY CURRENT STEP"))
        #expect(retryRun.transcript.contains("Retrying automatically in a fresh session"))
        #expect(activity.stepSessions["work"]?.lineage == 2)

        let sessions = await codex.sessionRequests()
        #expect(
            sessions.map(\.existingSessionID)
                == [nil, "codex-session-1", nil]
        )
        let released = await codex.releasedSessionIDs()
        #expect(released.filter { $0 == "codex-session-1" }.count == 1)
        #expect(released.filter { $0 == "codex-session-2" }.count == 1)
    }

    @Test
    func blockedStepRetryFallsBackSilentlyWhenResumedRunCannotStart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = ScriptedAgentProvider(
            id: .codex,
            delay: .zero,
            resumedRunsFailBeforeStart: true
        )
        let router = BlockingOnceWorkflowRouter()
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-blocked-start-fallback-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: AgentProviderRegistry(providers: [codex]),
            workflowRouter: router
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Fall back after a resumed run cannot start",
            workflow: singleStepWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.runs.last?.workflowHandoff?.outcome == .blocked
        }

        let blockedRun = try #require(coordinator.record.activity?.runs.last)
        await coordinator.retryWorkflowStep(blockedRun.id)
        try await waitUntil {
            coordinator.record.activity?.status == .completed
                && coordinator.record.activity?.runs.count == 3
                && coordinator.record.activity?.runs.last?.status == .completed
        }
        try await waitUntilReleasedSessions(from: codex, count: 2)

        let activity = try #require(coordinator.record.activity)
        #expect(activity.runs.count == 3)
        let resumedRun = try #require(activity.runs.dropFirst().first)
        let fallbackRun = try #require(activity.runs.dropFirst(2).first)
        #expect(resumedRun.status == .failed)
        #expect(resumedRun.threadID == "codex-session-1")
        #expect(fallbackRun.status == .completed)
        #expect(fallbackRun.sessionLineage == 2)
        #expect(fallbackRun.prompt.contains("RETRY CURRENT STEP"))
        #expect(activity.stepSessions["work"]?.lineage == 2)

        let sessions = await codex.sessionRequests()
        #expect(
            sessions.map(\.existingSessionID)
                == [nil, "codex-session-1", nil]
        )
        let released = await codex.releasedSessionIDs()
        #expect(released.filter { $0 == "codex-session-1" }.count == 1)
        #expect(released.filter { $0 == "codex-session-2" }.count == 1)
    }

    @Test
    func blockedStepRetryPreservesSessionWhenResumePreparationFailsTransiently() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = ScriptedAgentProvider(
            id: .codex,
            delay: .zero,
            transientlyRejectsExistingSessions: true
        )
        let router = BlockingOnceWorkflowRouter()
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-blocked-transient-prepare-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: AgentProviderRegistry(providers: [codex]),
            workflowRouter: router
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Preserve a session through a transient preparation failure",
            workflow: singleStepWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.runs.last?.workflowHandoff?.outcome == .blocked
        }

        let blockedRun = try #require(coordinator.record.activity?.runs.last)
        await coordinator.retryWorkflowStep(blockedRun.id)
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.runs.last?.status == .failed
        }

        let activity = try #require(coordinator.record.activity)
        #expect(activity.runs.count == 2)
        let retryRun = try #require(activity.runs.dropFirst().first)
        #expect(retryRun.sessionLineage == 1)
        #expect(retryRun.threadID == "codex-session-1")
        #expect(activity.stepSessions["work"]?.lineage == 1)
        #expect(activity.stepSessions["work"]?.providerSessionID == "codex-session-1")
        #expect(!retryRun.transcript.contains("Retrying automatically"))
        #expect(await router.routeCount() == 1)

        let sessions = await codex.sessionRequests()
        #expect(sessions.map(\.existingSessionID) == [nil, "codex-session-1"])
        #expect((await codex.releasedSessionIDs()).isEmpty)
    }

    @Test
    func blockedStepRetryPreservesSessionWhenResumedRunFailsTransientlyBeforeStart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = ScriptedAgentProvider(
            id: .codex,
            delay: .zero,
            resumedRunsFailTransientlyBeforeStart: true
        )
        let router = BlockingOnceWorkflowRouter()
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-blocked-transient-start-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: AgentProviderRegistry(providers: [codex]),
            workflowRouter: router
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Preserve a session through a transient pre-start failure",
            workflow: singleStepWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.runs.last?.workflowHandoff?.outcome == .blocked
        }

        let blockedRun = try #require(coordinator.record.activity?.runs.last)
        await coordinator.retryWorkflowStep(blockedRun.id)
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.runs.last?.status == .failed
        }

        let activity = try #require(coordinator.record.activity)
        #expect(activity.runs.count == 2)
        let retryRun = try #require(activity.runs.dropFirst().first)
        #expect(retryRun.sessionLineage == 1)
        #expect(retryRun.threadID == "codex-session-1")
        #expect(activity.stepSessions["work"]?.lineage == 1)
        #expect(activity.stepSessions["work"]?.providerSessionID == "codex-session-1")
        #expect(await router.routeCount() == 1)

        let sessions = await codex.sessionRequests()
        #expect(sessions.map(\.existingSessionID) == [nil, "codex-session-1"])
        #expect((await codex.releasedSessionIDs()).isEmpty)
    }

    @Test
    func closeWaitsForInitialSessionPreparationAndReleasesThePostCloseSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preparationGate = SessionPreparationGate(blockedCall: 1)
        let codex = ScriptedAgentProvider(
            id: .codex,
            delay: .zero,
            sessionPreparationGate: preparationGate
        )
        let store = WorkspaceStore(rootURL: root)
        let canonicalPath = "/tmp/generic-close-initial-prepare-\(UUID().uuidString)"
        let coordinator = RepositoryCoordinator(
            canonicalPath: canonicalPath,
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: store,
            agentProviders: AgentProviderRegistry(providers: [codex]),
            workflowRouter: BlockingOnceWorkflowRouter()
        )

        await coordinator.load()
        let startTask = Task {
            await coordinator.startActivity(
                goal: "Close during initial preparation",
                workflow: singleStepWorkflow()
            )
        }
        await preparationGate.waitUntilReached()
        let closeTask = Task {
            await coordinator.prepareForClose(strategy: .immediate)
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(coordinator.pauseState == .saving)
        #expect((await codex.releasedSessionIDs()).isEmpty)
        await preparationGate.release()
        #expect(await closeTask.value == .ready)
        await startTask.value

        let activity = try #require(coordinator.record.activity)
        #expect(activity.status == .paused)
        #expect(activity.stepSessions["work"]?.providerSessionID == nil)
        #expect(activity.runs.last?.threadID == nil)
        #expect(await codex.startAttemptCount() == 0)
        #expect(await codex.releasedSessionIDs() == ["codex-session-1"])
        let persisted = try await store.load(canonicalPath: canonicalPath)
        #expect(persisted.activity?.stepSessions["work"]?.providerSessionID == nil)
        #expect(persisted.activity?.runs.last?.threadID == nil)
    }

    @Test
    func closeWaitsForFreshFallbackPreparationAndReleasesOnlyItsNewSessionOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preparationGate = SessionPreparationGate(blockedCall: 3)
        let codex = ScriptedAgentProvider(
            id: .codex,
            delay: .zero,
            rejectsExistingSessions: true,
            sessionPreparationGate: preparationGate
        )
        let store = WorkspaceStore(rootURL: root)
        let canonicalPath = "/tmp/generic-close-fallback-prepare-\(UUID().uuidString)"
        let coordinator = RepositoryCoordinator(
            canonicalPath: canonicalPath,
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: store,
            agentProviders: AgentProviderRegistry(providers: [codex]),
            workflowRouter: BlockingOnceWorkflowRouter()
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Close during fresh fallback preparation",
            workflow: singleStepWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.runs.last?.workflowHandoff?.outcome == .blocked
        }
        let blockedRun = try #require(coordinator.record.activity?.runs.last)
        let retryTask = Task {
            await coordinator.retryWorkflowStep(blockedRun.id)
        }
        await preparationGate.waitUntilReached()
        let closeTask = Task {
            await coordinator.prepareForClose(strategy: .immediate)
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(coordinator.pauseState == .saving)
        await preparationGate.release()
        #expect(await closeTask.value == .ready)
        await retryTask.value

        let activity = try #require(coordinator.record.activity)
        let retryRun = try #require(activity.runs.dropFirst().first)
        #expect(activity.status == .paused)
        #expect(activity.workflowResumeCheckpoint == .recoverRun(retryRun.id))
        #expect(activity.stepSessions["work"]?.providerSessionID == "codex-session-1")
        #expect(retryRun.threadID == "codex-session-1")
        #expect(await codex.startAttemptCount() == 1)
        let released = await codex.releasedSessionIDs()
        #expect(released.filter { $0 == "codex-session-1" }.count == 1)
        #expect(released.filter { $0 == "codex-session-2" }.count == 1)
        let persisted = try await store.load(canonicalPath: canonicalPath)
        #expect(persisted.activity?.stepSessions["work"]?.providerSessionID == "codex-session-1")
        #expect(persisted.activity?.runs.last?.threadID == "codex-session-1")
    }

    @Test
    func closeWaitsForAnAcceptedBlockedStartAndInterruptsBeforeReleasingItsSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = BlockingAcceptedStartProvider()
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-close-accepted-start-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: AgentProviderRegistry(providers: [provider]),
            workflowRouter: BlockingOnceWorkflowRouter()
        )

        await coordinator.load()
        let startTask = Task {
            await coordinator.startActivity(
                goal: "Close after an agent accepts the turn",
                workflow: singleStepWorkflow()
            )
        }
        await provider.waitUntilStartWasAccepted()
        let closeTask = Task {
            await coordinator.prepareForClose(strategy: .immediate)
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(coordinator.pauseState == .saving)
        #expect(await provider.interruptCallCount() == 0)
        #expect((await provider.releasedSessionIDs()).isEmpty)

        await provider.releaseStartResponse()
        #expect(await closeTask.value == .ready)
        await startTask.value

        let run = try #require(coordinator.record.activity?.runs.last)
        #expect(coordinator.record.activity?.status == .paused)
        #expect(run.status == .interrupted)
        #expect(await provider.interruptCallCount() == 1)
        #expect(await provider.releasedSessionIDs() == ["codex-session-1"])
    }

    @Test
    func backpressureTerminalPreservesFailureAndCompletesWaitingGenericClose() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BlockingFailOnceTranscriptStore(base: WorkspaceStore(rootURL: root))
        defer { Task { await store.failFirstBlockedAppend() } }
        let provider = ControllableTerminalProvider()
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-backpressure-close-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: store,
            agentProviders: AgentProviderRegistry(providers: [provider]),
            workflowRouter: BlockingOnceWorkflowRouter()
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Preserve generic transcript durability failure while closing",
            workflow: singleStepWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.runs.last?.status == .running
        }
        let run = try #require(coordinator.record.activity?.runs.last)

        let closeTask = Task {
            await coordinator.prepareForClose(strategy: .immediate)
        }
        await provider.waitUntilInterrupted()
        #expect(coordinator.pauseState == .interrupting)
        #expect(await provider.interruptCallCount() == 1)

        await provider.emit(.transcript(String(
            repeating: "g",
            count: RepositoryCoordinator.maximumPendingTranscriptUTF8Bytes
        )))
        await store.waitUntilFirstAppendIsBlocked()
        await provider.emit(.transcript("not durable"))
        for _ in 0..<10 { await Task.yield() }
        await store.failFirstBlockedAppend()
        try await waitUntil {
            coordinator.transcriptBackpressureTerminationCount == 1
        }
        let failure = try #require(
            coordinator.record.activity?.runs.last?.relayError
        )
        #expect(failure.contains("transcript output could not be persisted"))

        await provider.emit(.interrupted("provider stopped"), finish: true)

        #expect(await closeTask.value == .ready)
        #expect(coordinator.transcriptBackpressureTerminationCount == 0)
        #expect(coordinator.pendingTranscriptUTF8ByteCount(for: run.id) == 0)
        #expect(coordinator.record.activity?.runs.last?.status == .failed)
        #expect(coordinator.record.activity?.runs.last?.relayError == failure)
    }

    @Test
    func safetyInterruptFailureBlocksReplacementAndCloseUntilTerminalAndDetachment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ControllableTerminalProvider(
            interruptFailures: 10,
            sessionReleaseResults: [false, false, true]
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-safety-close-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: AgentProviderRegistry(providers: [provider]),
            workflowRouter: BlockingOnceWorkflowRouter()
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Keep the document attached until safety termination is confirmed",
            workflow: singleStepWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.runs.last?.status == .running
        }
        let activityID = try #require(coordinator.record.activity?.id)
        let interaction = AgentInteraction(
            id: "duplicate-safety-request",
            kind: .questions,
            title: "Question",
            detail: "Duplicate request",
            rawParameters: .object([:])
        )
        await provider.emit(.interaction(interaction))
        await provider.emit(.interaction(interaction))
        try await waitUntil {
            coordinator.interactionSafetyTerminationCount == 1
                && coordinator.errorMessage?.contains(
                    "Injected provider interrupt failure"
                ) == true
        }

        #expect(coordinator.record.activity?.runs.last?.status == .failed)
        #expect(coordinator.errorMessage?.contains("Injected provider interrupt failure") == true)
        #expect(!coordinator.canResume)
        #expect(!coordinator.canStartOver)
        await coordinator.resume()
        await coordinator.startOver()
        #expect(coordinator.record.activity?.id == activityID)

        let failedInterruptClose = await coordinator.prepareForClose(strategy: .immediate)
        guard case .failed(let interruptFailure) = failedInterruptClose else {
            Issue.record("Expected close to fail while provider termination is unconfirmed")
            return
        }
        #expect(interruptFailure.contains("Injected provider interrupt failure"))
        #expect((await provider.releasedSessionIDs()).isEmpty)

        await provider.emit(.interrupted("Provider stopped"), finish: true)
        try await waitUntil {
            coordinator.interactionSafetyTerminationCount == 0
        }
        #expect(coordinator.record.activity?.runs.last?.status == .failed)

        #expect(coordinator.canStartOver)
        await coordinator.startOver()
        #expect(coordinator.record.activity?.id == activityID)
        #expect(coordinator.errorMessage?.contains("Provider-session detachment was not confirmed") == true)
        #expect(await provider.releasedSessionIDs() == ["controlled-session"])

        let failedDetachClose = await coordinator.prepareForClose(strategy: .immediate)
        guard case .failed(let detachFailure) = failedDetachClose else {
            Issue.record("Expected close to surface the failed provider detachment")
            return
        }
        #expect(detachFailure.contains("could not confirm provider-session detachment"))
        #expect(await provider.releasedSessionIDs() == [
            "controlled-session",
            "controlled-session"
        ])

        #expect(await coordinator.prepareForClose(strategy: .immediate) == .ready)
        #expect(await provider.releasedSessionIDs() == [
            "controlled-session",
            "controlled-session",
            "controlled-session"
        ])
    }

    @Test
    func closePreparationPreventsFreshFallbackAfterResumedStartFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let failureGate = ResumedStartFailureGate()
        let codex = ScriptedAgentProvider(
            id: .codex,
            delay: .zero,
            resumedStartFailureGate: failureGate
        )
        let router = BlockingOnceWorkflowRouter()
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/generic-close-during-fallback-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: AgentProviderRegistry(providers: [codex]),
            workflowRouter: router
        )

        await coordinator.load()
        await coordinator.startActivity(
            goal: "Do not launch a fallback after close",
            workflow: singleStepWorkflow()
        )
        try await waitUntil {
            coordinator.record.activity?.status == .paused
                && coordinator.record.activity?.runs.last?.workflowHandoff?.outcome == .blocked
        }

        let blockedRun = try #require(coordinator.record.activity?.runs.last)
        let retryTask = Task {
            await coordinator.retryWorkflowStep(blockedRun.id)
        }
        await failureGate.waitUntilReached()

        let closeTask = Task {
            await coordinator.prepareForClose(strategy: .immediate)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.pauseState == .saving)
        await failureGate.release()
        #expect(await closeTask.value == .ready)
        await retryTask.value

        let activity = try #require(coordinator.record.activity)
        #expect(activity.status == .paused)
        #expect(activity.runs.count == 2)
        let retryRun = try #require(activity.runs.dropFirst().first)
        #expect(activity.workflowResumeCheckpoint == .recoverRun(retryRun.id))
        #expect(activity.stepSessions["work"]?.lineage == 1)
        #expect(activity.stepSessions["work"]?.providerSessionID == "codex-session-1")
        #expect(await codex.startAttemptCount() == 2)

        let sessions = await codex.sessionRequests()
        #expect(sessions.map(\.existingSessionID) == [nil, "codex-session-1"])
        #expect(await codex.releasedSessionIDs() == ["codex-session-1"])
    }

    @Test
    func closingAPausedDocumentDetachesButPreservesItsSessionForReopen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalPath = "/tmp/generic-close-reopen-\(UUID().uuidString)"
        let firstProvider = ScriptedAgentProvider(
            id: .codex,
            delay: .milliseconds(50)
        )
        let firstCoordinator = RepositoryCoordinator(
            canonicalPath: canonicalPath,
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: AgentProviderRegistry(providers: [firstProvider]),
            workflowRouter: IterationCompletingWorkflowRouter(completionIteration: 99)
        )

        await firstCoordinator.load()
        await firstCoordinator.startActivity(
            goal: "Resume the same phase after reopening",
            workflow: singleStepWorkflow()
        )
        firstCoordinator.setPauseAfterCurrent(true)
        try await waitUntil {
            firstCoordinator.record.activity?.status == .paused
                && firstCoordinator.record.activity?.workflowCursor?.loopIteration == 2
        }
        let savedSessionID = try #require(
            firstCoordinator.record.activity?.stepSessions["work"]?.providerSessionID
        )

        #expect(await firstCoordinator.prepareForClose(strategy: .immediate) == .ready)
        #expect(await firstProvider.releasedSessionIDs() == [savedSessionID])
        #expect(
            firstCoordinator.record.activity?.stepSessions["work"]?.providerSessionID
                == savedSessionID
        )
        let persisted = try await WorkspaceStore(rootURL: root).load(
            canonicalPath: canonicalPath
        )
        #expect(persisted.activity?.stepSessions["work"]?.providerSessionID == savedSessionID)

        let reopenedProvider = ScriptedAgentProvider(id: .codex, delay: .zero)
        let reopenedCoordinator = RepositoryCoordinator(
            canonicalPath: canonicalPath,
            appServer: CodexAppServerClient(),
            router: NoopLegacyRouter(),
            store: WorkspaceStore(rootURL: root),
            agentProviders: AgentProviderRegistry(providers: [reopenedProvider]),
            workflowRouter: IterationCompletingWorkflowRouter(completionIteration: 2)
        )
        await reopenedCoordinator.load()
        await reopenedCoordinator.resume()
        try await waitUntil {
            reopenedCoordinator.record.activity?.status == .completed
        }

        let reopenRequests = await reopenedProvider.sessionRequests()
        #expect(reopenRequests.first?.existingSessionID == savedSessionID)
        #expect(
            reopenedCoordinator.record.activity?.stepSessions["work"]?.providerSessionID
                == savedSessionID
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(15),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    private func waitUntilReleasedSessions(
        from provider: ScriptedAgentProvider,
        count: Int,
        timeout: Duration = .seconds(3)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await provider.releasedSessionIDs().count < count,
              clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await provider.releasedSessionIDs().count >= count)
    }

    private func fullWorkflow() -> WorkflowTemplate {
        let codex = AgentTarget(
            providerID: .codex,
            model: "gpt-test",
            options: .init(effort: "high", mode: .plan)
        )
        let claude = AgentTarget(
            providerID: .claude,
            model: "sonnet",
            options: .init(effort: "high", speed: .fast)
        )
        return WorkflowTemplate(
            id: "full",
            name: "Full",
            summary: "All sections and providers",
            steps: [
                step("plan", "Plan", .prefix, codex),
                step("code", "Code", .loop, claude),
                step("review", "Review", .loop, codex),
                step("summary", "Summarize", .postfix, claude)
            ],
            coordinator: WorkflowCoordinatorConfiguration(
                target: codex,
                instructions: "Route results."
            )
        )
    }

    private func loopWorkflow() -> WorkflowTemplate {
        let codex = AgentTarget(providerID: .codex, model: "gpt-test")
        return WorkflowTemplate(
            id: "loop",
            name: "Loop",
            summary: "Lineage test",
            steps: [
                step("code", "Code", .loop, codex),
                step("review", "Review", .loop, codex)
            ],
            coordinator: WorkflowCoordinatorConfiguration(
                target: codex,
                instructions: "Route results."
            )
        )
    }

    private func singleStepWorkflow() -> WorkflowTemplate {
        let target = AgentTarget(providerID: .codex, model: "gpt-test")
        return WorkflowTemplate(
            id: "single",
            name: "Single",
            summary: "One step",
            steps: [step("work", "Work", .loop, target)],
            coordinator: WorkflowCoordinatorConfiguration(
                target: target,
                instructions: "Route results."
            )
        )
    }

    private func step(
        _ id: String,
        _ name: String,
        _ section: WorkflowSection,
        _ target: AgentTarget
    ) -> WorkflowStep {
        WorkflowStep(
            id: id,
            name: name,
            section: section,
            instructions: "Perform \(name) for {{goal}} in cycle {{loop_iteration}}.",
            target: target
        )
    }
}

private actor BlockingOnceWorkflowRouter: WorkflowHandoffRouting {
    private var calls = 0

    func route(
        _ context: WorkflowHandoffContext,
        configuration: WorkflowCoordinatorConfiguration,
        cwd: String
    ) -> WorkflowHandoff {
        _ = configuration
        _ = cwd
        calls += 1
        return WorkflowHandoff(
            text: calls == 1 ? "The step is temporarily blocked." : "The retry succeeded.",
            outcome: calls == 1 ? .blocked : .complete,
            runLabel: "\(context.sourceStep.name) \(context.sourceStep.loopIteration)"
        )
    }

    func summarizeWork(
        _ context: WorkSummaryContext,
        configuration: WorkflowCoordinatorConfiguration,
        cwd: String
    ) -> String {
        _ = context
        _ = configuration
        _ = cwd
        return "Retry summary"
    }

    func routeCount() -> Int {
        calls
    }
}

private actor ControllableTerminalProvider: AgentProviding {
    nonisolated let id: AgentProviderID = .codex

    private var continuation: AsyncStream<AgentEvent>.Continuation?
    private var interrupts = 0
    private var remainingInterruptFailures: Int
    private var sessionReleaseResults: [Bool]
    private var interruptWaiters: [CheckedContinuation<Void, Never>] = []
    private var released: [String] = []

    init(
        interruptFailures: Int = 0,
        sessionReleaseResults: [Bool] = []
    ) {
        remainingInterruptFailures = interruptFailures
        self.sessionReleaseResults = sessionReleaseResults
    }

    func prepareSession(_ request: AgentSessionRequest) -> AgentSession {
        AgentSession(providerID: id, id: "controlled-session", target: request.target)
    }

    func startRun(_ request: AgentRunRequest) -> AgentRunHandle {
        let pair = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
        continuation = pair.continuation
        let executionID = "controlled-execution"
        pair.continuation.yield(.started(executionID: executionID))
        return AgentRunHandle(
            runID: request.runID,
            providerID: id,
            sessionID: request.session.id,
            executionID: executionID,
            events: pair.stream
        )
    }

    func steer(runID: UUID, message: String) {
        _ = runID
        _ = message
    }

    func interrupt(runID: UUID) throws {
        _ = runID
        interrupts += 1
        let waiters = interruptWaiters
        interruptWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if remainingInterruptFailures > 0 {
            remainingInterruptFailures -= 1
            throw ControllableTerminalProviderError.injectedInterruptFailure
        }
    }

    func resolveInteraction(
        runID: UUID,
        interactionID: String,
        resolution: AgentInteractionResolution
    ) {
        _ = runID
        _ = interactionID
        _ = resolution
    }

    func runUtility(_ request: AgentUtilityRequest) -> AgentUtilityResult {
        _ = request
        return AgentUtilityResult(output: "{}")
    }

    func releaseSession(id: String) -> Bool {
        released.append(id)
        return sessionReleaseResults.isEmpty ? true : sessionReleaseResults.removeFirst()
    }

    func shutdown() {}

    func emit(_ event: AgentEvent, finish: Bool = false) {
        continuation?.yield(event)
        if finish {
            continuation?.finish()
            continuation = nil
        }
    }

    func interruptCallCount() -> Int {
        interrupts
    }

    func releasedSessionIDs() -> [String] {
        released
    }

    func waitUntilInterrupted() async {
        guard interrupts == 0 else { return }
        await withCheckedContinuation { continuation in
            interruptWaiters.append(continuation)
        }
    }
}

private enum ControllableTerminalProviderError: LocalizedError {
    case injectedInterruptFailure

    var errorDescription: String? {
        "Injected provider interrupt failure"
    }
}

private actor ScriptedAgentProvider: AgentProviding {
    nonisolated let id: AgentProviderID

    private let delay: Duration
    private let failuresBeforeStart: Int
    private let rejectsExistingSessions: Bool
    private let transientlyRejectsExistingSessions: Bool
    private let resumedRunsFailBeforeStart: Bool
    private let resumedRunsFailTransientlyBeforeStart: Bool
    private let resumedStartFailureGate: ResumedStartFailureGate?
    private let sessionPreparationGate: SessionPreparationGate?
    private let sessionReleaseGate: SessionReleaseGate?
    private var sessionReleaseResults: [Bool]
    private var prepared: [AgentSessionRequest] = []
    private var started: [AgentRunRequest] = []
    private var resumedSessionIDs: Set<String> = []
    private var sessionCounter = 0
    private var startAttempts = 0
    private var released: [String] = []

    init(
        id: AgentProviderID,
        delay: Duration,
        failuresBeforeStart: Int = 0,
        rejectsExistingSessions: Bool = false,
        transientlyRejectsExistingSessions: Bool = false,
        resumedRunsFailBeforeStart: Bool = false,
        resumedRunsFailTransientlyBeforeStart: Bool = false,
        resumedStartFailureGate: ResumedStartFailureGate? = nil,
        sessionPreparationGate: SessionPreparationGate? = nil,
        sessionReleaseGate: SessionReleaseGate? = nil,
        sessionReleaseResults: [Bool] = []
    ) {
        self.id = id
        self.delay = delay
        self.failuresBeforeStart = failuresBeforeStart
        self.rejectsExistingSessions = rejectsExistingSessions
        self.transientlyRejectsExistingSessions = transientlyRejectsExistingSessions
        self.resumedRunsFailBeforeStart = resumedRunsFailBeforeStart
        self.resumedRunsFailTransientlyBeforeStart = resumedRunsFailTransientlyBeforeStart
        self.resumedStartFailureGate = resumedStartFailureGate
        self.sessionPreparationGate = sessionPreparationGate
        self.sessionReleaseGate = sessionReleaseGate
        self.sessionReleaseResults = sessionReleaseResults
    }

    func prepareSession(_ request: AgentSessionRequest) async throws -> AgentSession {
        prepared.append(request)
        if let sessionPreparationGate {
            await sessionPreparationGate.blockIfNeeded(call: prepared.count)
        }
        let sessionID: String
        if let existing = request.existingSessionID {
            if transientlyRejectsExistingSessions {
                throw AgentProviderError.unavailable(
                    id,
                    "Injected transient transport failure"
                )
            }
            if rejectsExistingSessions {
                throw AgentProviderError.sessionUnavailable(
                    provider: id,
                    sessionID: existing,
                    detail: "Injected missing session"
                )
            }
            sessionID = existing
            resumedSessionIDs.insert(existing)
        } else {
            sessionCounter += 1
            sessionID = "\(id.rawValue)-session-\(sessionCounter)"
        }
        return AgentSession(providerID: id, id: sessionID, target: request.target)
    }

    func startRun(_ request: AgentRunRequest) async throws -> AgentRunHandle {
        startAttempts += 1
        if startAttempts <= failuresBeforeStart {
            throw AgentProviderError.processExited(
                provider: id,
                termination: SubprocessTermination(reason: .exit, status: 1),
                detail: "Injected pre-start failure"
            )
        }
        let resumedExistingSession = resumedSessionIDs.remove(request.session.id) != nil
        if resumedExistingSession, let resumedStartFailureGate {
            await resumedStartFailureGate.blockUntilReleased()
            throw AgentProviderError.sessionUnavailable(
                provider: id,
                sessionID: request.session.id,
                detail: "Injected missing resumed session"
            )
        }
        started.append(request)
        if resumedRunsFailBeforeStart, resumedExistingSession {
            let pair = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
            Task {
                pair.continuation.yield(
                    .sessionUnavailable("Injected missing resumed session")
                )
                pair.continuation.finish()
            }
            return AgentRunHandle(
                runID: request.runID,
                providerID: id,
                sessionID: request.session.id,
                executionID: nil,
                events: pair.stream
            )
        }
        if resumedRunsFailTransientlyBeforeStart, resumedExistingSession {
            let pair = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
            Task {
                pair.continuation.yield(.failed("Injected transient transport failure"))
                pair.continuation.finish()
            }
            return AgentRunHandle(
                runID: request.runID,
                providerID: id,
                sessionID: request.session.id,
                executionID: nil,
                events: pair.stream
            )
        }
        let pair = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
        let executionID = "\(id.rawValue)-execution-\(started.count)"
        let delay = delay
        Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            pair.continuation.yield(.started(executionID: executionID))
            pair.continuation.yield(.transcript("Provider \(id.rawValue) completed the step."))
            pair.continuation.yield(.tokenUsage(
                RunTokenUsage(totalTokens: 20, inputTokens: 15, outputTokens: 5)
            ))
            pair.continuation.yield(
                .completed(
                    output: "Completed \(request.target.model).",
                    durationMilliseconds: 10,
                    tokenUsage: RunTokenUsage(
                        totalTokens: 20,
                        inputTokens: 15,
                        outputTokens: 5
                    )
                )
            )
            pair.continuation.finish()
        }
        return AgentRunHandle(
            runID: request.runID,
            providerID: id,
            sessionID: request.session.id,
            executionID: executionID,
            events: pair.stream
        )
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

    func runUtility(_ request: AgentUtilityRequest) -> AgentUtilityResult {
        _ = request
        return AgentUtilityResult(
            output: """
            {"handoffText":"Continue.","outcome":"continueWorkflow","runLabel":"Step"}
            """
        )
    }

    func releaseSession(id: String) async -> Bool {
        released.append(id)
        await sessionReleaseGate?.blockIfNeeded(call: released.count)
        return sessionReleaseResults.isEmpty ? true : sessionReleaseResults.removeFirst()
    }

    func shutdown() {}

    func sessionRequests() -> [AgentSessionRequest] {
        prepared
    }

    func runRequests() -> [AgentRunRequest] {
        started
    }

    func startCount() -> Int {
        started.count
    }

    func startAttemptCount() -> Int {
        startAttempts
    }

    func releasedSessionIDs() -> [String] {
        released
    }
}

private actor ResumedStartFailureGate {
    private var reached = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func blockUntilReleased() async {
        reached = true
        let waiters = reachedWaiters
        reachedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { continuation in
            reachedWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor SessionPreparationGate {
    private let blockedCall: Int
    private var reached = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(blockedCall: Int) {
        self.blockedCall = blockedCall
    }

    func blockIfNeeded(call: Int) async {
        guard call == blockedCall else { return }
        reached = true
        let waiters = reachedWaiters
        reachedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { continuation in
            reachedWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor SessionReleaseGate {
    private var reached = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func blockIfNeeded(call: Int) async {
        guard call == 1 else { return }
        reached = true
        let waiters = reachedWaiters
        reachedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { continuation in
            reachedWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor BlockingAcceptedStartProvider: AgentProviding {
    nonisolated let id = AgentProviderID.codex

    private var startWasAccepted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var startReleaseContinuation: CheckedContinuation<Void, Never>?
    private var runContinuations: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]
    private var interruptCalls = 0
    private var releasedSessions: [String] = []

    func prepareSession(_ request: AgentSessionRequest) -> AgentSession {
        AgentSession(
            providerID: id,
            id: request.existingSessionID ?? "codex-session-1",
            target: request.target
        )
    }

    func startRun(_ request: AgentRunRequest) async -> AgentRunHandle {
        let pair = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
        runContinuations[request.runID] = pair.continuation
        startWasAccepted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            startReleaseContinuation = continuation
        }
        return AgentRunHandle(
            runID: request.runID,
            providerID: id,
            sessionID: request.session.id,
            executionID: "accepted-execution-1",
            events: pair.stream
        )
    }

    func steer(runID: UUID, message: String) {
        _ = runID
        _ = message
    }

    func interrupt(runID: UUID) {
        interruptCalls += 1
        if let continuation = runContinuations.removeValue(forKey: runID) {
            continuation.yield(.interrupted(nil))
            continuation.finish()
        }
    }

    func resolveInteraction(
        runID: UUID,
        interactionID: String,
        resolution: AgentInteractionResolution
    ) {
        _ = runID
        _ = interactionID
        _ = resolution
    }

    func runUtility(_ request: AgentUtilityRequest) throws -> AgentUtilityResult {
        throw AgentProviderError.unavailable(id, "Utilities are not used by this fixture.")
    }

    func releaseSession(id: String) -> Bool {
        releasedSessions.append(id)
        return true
    }

    func shutdown() {
        for continuation in runContinuations.values {
            continuation.finish()
        }
        runContinuations.removeAll()
    }

    func waitUntilStartWasAccepted() async {
        guard !startWasAccepted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseStartResponse() {
        startReleaseContinuation?.resume()
        startReleaseContinuation = nil
    }

    func interruptCallCount() -> Int {
        interruptCalls
    }

    func releasedSessionIDs() -> [String] {
        releasedSessions
    }
}

private actor IterationCompletingWorkflowRouter: WorkflowHandoffRouting {
    private let completionIteration: Int
    private var calls: [WorkflowHandoffContext] = []
    private var routeConfigurations: [WorkflowCoordinatorConfiguration] = []
    private var summaryCalls: [WorkflowCoordinatorConfiguration] = []

    init(completionIteration: Int) {
        self.completionIteration = completionIteration
    }

    func route(
        _ context: WorkflowHandoffContext,
        configuration: WorkflowCoordinatorConfiguration,
        cwd: String
    ) -> WorkflowHandoff {
        _ = cwd
        calls.append(context)
        routeConfigurations.append(configuration)
        let outcome: WorkflowOutcome = context.makesLoopDecision
            && context.sourceStep.loopIteration >= completionIteration
            ? .complete
            : .continueWorkflow
        return WorkflowHandoff(
            text: "\(context.sourceStep.name) completed.",
            outcome: outcome,
            runLabel: "\(context.sourceStep.name) \(context.sourceStep.loopIteration)"
        )
    }

    func routeCount() -> Int {
        calls.count
    }

    func configurations() -> [WorkflowCoordinatorConfiguration] {
        routeConfigurations
    }

    func summarizeWork(
        _ context: WorkSummaryContext,
        configuration: WorkflowCoordinatorConfiguration,
        cwd: String
    ) -> String {
        _ = context
        _ = cwd
        summaryCalls.append(configuration)
        return "### Completed\n- Generic workflow summary."
    }

    func summaryCount() -> Int {
        summaryCalls.count
    }

    func summaryConfigurations() -> [WorkflowCoordinatorConfiguration] {
        summaryCalls
    }
}

private actor NoopLegacyRouter: HandoffRouting {
    func route(
        _ context: HandoffContext,
        settings: RelaySettings
    ) -> HandoffEnvelope {
        _ = context
        _ = settings
        return HandoffEnvelope(
            handoffText: "Unused",
            sourceDisposition: .unclear,
            runLabel: "Unused"
        )
    }
}

private actor FailingCompletedGenericStore: RepositoryWorkspaceStoring {
    private let base: WorkspaceStore
    private var hasFailed = false

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
        if !hasFailed, record.activity?.status == .completed {
            hasFailed = true
            throw GenericStoreFailure()
        }
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
}

private actor FailingQueuedGenericStore: RepositoryWorkspaceStoring {
    private let base: WorkspaceStore
    private var hasFailed = false

    init(base: WorkspaceStore) {
        self.base = base
    }

    func load(
        canonicalPath: String,
        defaultSettings: RepositorySettings
    ) async throws -> RepositoryRecord {
        try await base.load(
            canonicalPath: canonicalPath,
            defaultSettings: defaultSettings
        )
    }

    func save(_ record: RepositoryRecord) async throws {
        if !hasFailed, record.activity?.runs.last?.status == .queued {
            hasFailed = true
            throw GenericStoreFailure()
        }
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
}

private struct GenericStoreFailure: LocalizedError {
    var errorDescription: String? { "Injected generic queued-save failure" }
}
