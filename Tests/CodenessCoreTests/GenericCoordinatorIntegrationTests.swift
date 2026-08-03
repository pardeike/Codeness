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
        #expect(persisted.activity == activity)
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

        let closeResult = await coordinator.prepareForClose(strategy: .immediate)
        #expect(closeResult == .ready)
        await failureGate.release()
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

private actor ScriptedAgentProvider: AgentProviding {
    nonisolated let id: AgentProviderID

    private let delay: Duration
    private let failuresBeforeStart: Int
    private let rejectsExistingSessions: Bool
    private let transientlyRejectsExistingSessions: Bool
    private let resumedRunsFailBeforeStart: Bool
    private let resumedRunsFailTransientlyBeforeStart: Bool
    private let resumedStartFailureGate: ResumedStartFailureGate?
    private var prepared: [AgentSessionRequest] = []
    private var started: [AgentRunRequest] = []
    private var resumedSessionIDs: Set<String> = []
    private var sessionCounter = 0
    private var startAttempts = 0

    init(
        id: AgentProviderID,
        delay: Duration,
        failuresBeforeStart: Int = 0,
        rejectsExistingSessions: Bool = false,
        transientlyRejectsExistingSessions: Bool = false,
        resumedRunsFailBeforeStart: Bool = false,
        resumedRunsFailTransientlyBeforeStart: Bool = false,
        resumedStartFailureGate: ResumedStartFailureGate? = nil
    ) {
        self.id = id
        self.delay = delay
        self.failuresBeforeStart = failuresBeforeStart
        self.rejectsExistingSessions = rejectsExistingSessions
        self.transientlyRejectsExistingSessions = transientlyRejectsExistingSessions
        self.resumedRunsFailBeforeStart = resumedRunsFailBeforeStart
        self.resumedRunsFailTransientlyBeforeStart = resumedRunsFailTransientlyBeforeStart
        self.resumedStartFailureGate = resumedStartFailureGate
    }

    func prepareSession(_ request: AgentSessionRequest) throws -> AgentSession {
        prepared.append(request)
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
