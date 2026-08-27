import Darwin
import Dispatch
import Foundation
import Testing
@testable import CodenessCore

@Suite
struct AppServerIntegrationTests {
    @Test
    func appServerClientCorrelatesRequestsAndDecodesModels() async throws {
        let fixture = try FakeAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        try await client.start(configuration: fixture.configuration)

        let models = try await client.listModels()
        let threadID = try await client.startThread(
            cwd: "/tmp/repository",
            model: "gpt-5.6-sol",
            developerInstructions: "Implement"
        )
        let turnID = try await client.startTurn(
            threadID: threadID,
            prompt: "Start",
            cwd: "/tmp/repository",
            model: "gpt-5.6-sol",
            effort: "high"
        )

        #expect(models.map(\.model) == ["gpt-5.6-sol"])
        #expect(models.first?.efforts == ["high", "max"])
        #expect(threadID == "thread-1")
        #expect(turnID == "turn-1")
        await client.shutdown()
    }

    @Test
    func appServerClientCanRestartBeforeThePreviousExitCallbackArrives() async throws {
        let fixture = try FakeAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()

        try await client.start(configuration: fixture.configuration)
        await client.shutdown()
        try await client.start(configuration: fixture.configuration)
        try await Task.sleep(for: .milliseconds(100))

        let models = try await client.listModels()
        #expect(models.map(\.model) == ["gpt-5.6-sol"])
        #expect(await client.isRunning)
        await client.shutdown()
    }

    @Test
    func codexProviderMapsAppServerEventsAndResolvesDynamicFastTier() async throws {
        let fixture = try FakeAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let model = CodexModel(
            id: "gpt-5.6-sol",
            model: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            description: "Fixture",
            defaultEffort: "high",
            efforts: ["high", "max"],
            hidden: false,
            serviceTiers: [
                CodexServiceTier(
                    id: "fixture-fast-tier",
                    name: "Fast",
                    description: "Fixture dynamic tier"
                )
            ]
        )
        let provider = CodexAgentProvider(appServer: client, models: [model])
        let stream = await client.events()
        let consumer = Task {
            for await transportEvent in stream {
                await provider.receive(transportEvent.event)
            }
        }
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)
        let target = AgentTarget(
            providerID: .codex,
            model: model.model,
            options: AgentExecutionOptions(
                effort: nil,
                mode: .plan,
                speed: .fast
            )
        )
        let session = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Provider fixture",
                cwd: "/tmp/repository",
                target: target,
                developerInstructions: "Inspect without changing files."
            )
        )
        let handle = try await provider.startRun(
            AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: "/tmp/repository",
                prompt: "Review the repository.",
                target: target
            )
        )
        var events: [AgentEvent] = []
        for await event in handle.events {
            events.append(event)
        }

        #expect(events.contains {
            if case .started(let identifier) = $0 {
                return identifier == "turn-1"
            }
            return false
        })
        #expect(events.contains {
            if case .transcript(let text) = $0 {
                return text.contains("IMPLEMENTATION CHECKPOINT")
            }
            return false
        })
        #expect(events.contains {
            if case .completed(let output, let duration, _) = $0 {
                return output.contains("Changed Parser.swift") && duration == 10
            }
            return false
        })
        await provider.shutdown()
        await client.shutdown()
    }

    @Test
    func codexProviderClassifiesConfirmedMissingThreadsAsUnavailableSessions() async throws {
        let fixture = try FakeAppServerFixture(rejectsResumes: true)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        try await client.start(configuration: fixture.configuration)
        let target = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-sol"
        )

        var unavailableSession: (provider: AgentProviderID, sessionID: String)?
        do {
            _ = try await provider.prepareSession(
                AgentSessionRequest(
                    existingSessionID: "missing-thread",
                    name: "Missing provider fixture",
                    cwd: "/tmp/repository",
                    target: target,
                    developerInstructions: "Continue the workflow."
                )
            )
        } catch let error as AgentProviderError {
            if case .sessionUnavailable(let provider, let sessionID, _) = error {
                unavailableSession = (provider, sessionID)
            }
        }

        #expect(unavailableSession?.provider == .codex)
        #expect(unavailableSession?.sessionID == "missing-thread")
        await client.shutdown()
    }

    @Test
    func codexProviderResumesAnAttachedPhaseOnlyOnceAndResumesAgainAfterRestart() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        let target = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-sol",
            options: AgentExecutionOptions(effort: "high")
        )
        let request = AgentSessionRequest(
            existingSessionID: "phase-thread",
            name: "Persistent phase",
            cwd: "/tmp/repository",
            target: target,
            developerInstructions: "Continue this phase."
        )

        try await client.start(configuration: fixture.configuration)
        _ = try await provider.prepareSession(request)
        _ = try await provider.prepareSession(request)
        #expect(fixture.loggedMethods().filter { $0 == "thread/resume" }.count == 1)

        await provider.receive(.exited(SubprocessTermination(reason: .exit, status: 1)))
        _ = try await provider.prepareSession(request)
        #expect(fixture.loggedMethods().filter { $0 == "thread/resume" }.count == 2)

        await provider.shutdown()
        await client.shutdown()
        try await client.start(configuration: fixture.configuration)
        _ = try await provider.prepareSession(request)
        #expect(fixture.loggedMethods().filter { $0 == "thread/resume" }.count == 3)
        await client.shutdown()
    }

    @Test
    func codexProviderDeletesCompletedAndFailedTemporaryUtilityThreads() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        let stream = await client.events()
        let consumer = Task {
            for await transportEvent in stream {
                await provider.receive(transportEvent.event)
            }
        }
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)
        let target = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-sol",
            options: AgentExecutionOptions(effort: "high")
        )

        let completed = try await provider.runUtility(AgentUtilityRequest(
            cwd: "/tmp/repository",
            prompt: "complete",
            target: target,
            developerInstructions: "Coordinate.",
            outputSchema: .object(["type": .string("object")])
        ))
        #expect(completed.output == "utility complete")

        await #expect(throws: AgentProviderError.self) {
            _ = try await provider.runUtility(AgentUtilityRequest(
                cwd: "/tmp/repository",
                prompt: "fail",
                target: target,
                developerInstructions: "Coordinate.",
                outputSchema: .object(["type": .string("object")])
            ))
        }

        let methods = fixture.loggedMethods()
        #expect(methods.filter { $0 == "thread/start" }.count == 2)
        #expect(methods.filter { $0 == "thread/delete" }.count == 2)
        #expect(methods.filter { $0 == "thread/unsubscribe" }.isEmpty)
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func codexUtilityFailsAndCancelsWhenItRequestsUserInteraction() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        let stream = await client.events()
        let consumer = Task {
            for await transportEvent in stream {
                await provider.receive(transportEvent.event)
            }
        }
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)
        let utility = Task {
            try await provider.runUtility(AgentUtilityRequest(
                cwd: "/tmp/repository",
                prompt: "hold",
                target: AgentTarget(
                    providerID: .codex,
                    model: "gpt-5.6-sol",
                    options: AgentExecutionOptions(effort: "high")
                ),
                developerInstructions: "Coordinate.",
                outputSchema: .object(["type": .string("object")])
            ))
        }
        for _ in 0..<100 {
            if fixture.loggedMethods().contains("turn/start") { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        await provider.receive(.request(
            id: .integer(41),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("utility-1"),
                "turnId": .string("turn-1"),
                "questions": .array([])
            ]),
            rawLine: "utility interaction"
        ))

        do {
            _ = try await utility.value
            Issue.record("Expected the unattended utility interaction to fail")
        } catch {
            #expect(error.localizedDescription.contains("unattended coordinator run"))
        }
        let methods = fixture.loggedMethods()
        #expect(methods.filter { $0 == "turn/interrupt" }.count == 1)
        #expect(methods.filter { $0 == "thread/delete" }.count == 1)
        await client.shutdown()
    }

    @Test
    func codexProviderDeletesTemporaryUtilityThreadWhenRunSetupFails() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        try await client.start(configuration: fixture.configuration)

        await #expect(throws: AgentProviderError.self) {
            _ = try await provider.runUtility(AgentUtilityRequest(
                cwd: "/tmp/repository",
                prompt: "complete",
                target: AgentTarget(providerID: .codex, model: "unknown-model"),
                developerInstructions: "Coordinate.",
                outputSchema: .object(["type": .string("object")])
            ))
        }

        let methods = fixture.loggedMethods()
        #expect(methods.filter { $0 == "thread/start" }.count == 1)
        #expect(methods.filter { $0 == "turn/start" }.isEmpty)
        #expect(methods.filter { $0 == "thread/delete" }.count == 1)
        #expect(methods.filter { $0 == "thread/unsubscribe" }.isEmpty)
        await client.shutdown()
    }

    @Test
    func utilityCleanupFailureDoesNotMaskThePrimaryResultOrError() async throws {
        let fixture = try LifecycleAppServerFixture(
            rejectsUnsubscribe: true,
            deleteFailures: 1_000_000
        )
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            maximumCleanupAttemptCount: 1
        )
        let stream = await client.events()
        let consumer = Task {
            for await transportEvent in stream {
                await provider.receive(transportEvent.event)
            }
        }
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)
        let target = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-sol",
            options: AgentExecutionOptions(effort: "high")
        )

        let completed = try await provider.runUtility(AgentUtilityRequest(
            cwd: "/tmp/repository",
            prompt: "complete",
            target: target,
            developerInstructions: "Coordinate.",
            outputSchema: .object(["type": .string("object")])
        ))
        #expect(completed.output == "utility complete")

        do {
            _ = try await provider.runUtility(AgentUtilityRequest(
                cwd: "/tmp/repository",
                prompt: "fail",
                target: target,
                developerInstructions: "Coordinate.",
                outputSchema: .object(["type": .string("object")])
            ))
            Issue.record("Expected the utility turn failure")
        } catch {
            #expect(error.localizedDescription.contains("status failed"))
            #expect(error.localizedDescription.contains("injected turn failure"))
            #expect(!error.localizedDescription.contains("unsubscribe failure"))
        }

        // The second admission gets one quiescent hard-delete retry for the first
        // exhausted debt before its own utility records separate cleanup debt.
        #expect(fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.count >= 3)
        await client.shutdown()
    }

    @Test
    func cancellingUtilityInterruptsItsTurnFinishesBookkeepingAndDeletesIt() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        let stream = await client.events()
        let consumer = Task {
            for await transportEvent in stream {
                await provider.receive(transportEvent.event)
            }
        }
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)
        let task = Task {
            try await provider.runUtility(AgentUtilityRequest(
                cwd: "/tmp/repository",
                prompt: "hold",
                target: AgentTarget(
                    providerID: .codex,
                    model: "gpt-5.6-sol",
                    options: AgentExecutionOptions(effort: "high")
                ),
                developerInstructions: "Coordinate.",
                outputSchema: .object(["type": .string("object")])
            ))
        }
        for _ in 0..<100 {
            if fixture.loggedMethods().contains("turn/start") { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let methods = fixture.loggedMethods()
        #expect(methods.filter { $0 == "turn/interrupt" }.count == 1)
        #expect(methods.filter { $0 == "thread/delete" }.count == 1)
        #expect(methods.filter { $0 == "thread/unsubscribe" }.isEmpty)
        await client.shutdown()
    }

    @Test
    func codexProviderStopsBeforeRetainedUtilitiesCanGrowWithoutBound() async throws {
        let fixture = try LifecycleAppServerFixture(deleteFailures: 1_000_000)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            maximumLoadedThreadCount: 10,
            maximumRetainedUtilityThreadCount: 2
        )
        let stream = await client.events()
        let consumer = Task {
            for await transportEvent in stream {
                await provider.receive(transportEvent.event)
            }
        }
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)
        let request = AgentUtilityRequest(
            cwd: "/tmp/repository",
            prompt: "complete",
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            ),
            developerInstructions: "Coordinate.",
            outputSchema: .object(["type": .string("object")])
        )

        _ = try await provider.runUtility(request)
        _ = try await provider.runUtility(request)
        do {
            _ = try await provider.runUtility(request)
            Issue.record("Expected the retained-utility safety pause")
        } catch {
            #expect(error.localizedDescription.contains("still retaining 2"))
            #expect(error.localizedDescription.contains("stopped before creating another"))
            #expect(error.localizedDescription.contains("restart Codex App Server"))
        }
        #expect(fixture.loggedMethods().filter { $0 == "thread/start" }.count == 2)
        await client.shutdown()
    }

    @Test
    func codexProviderAutomaticallyApprovesTaggedMCPToolElicitations() async throws {
        let fixture = try MCPApprovalAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        let stream = await client.events()
        let consumer = Task {
            for await transportEvent in stream {
                await provider.receive(transportEvent.event)
            }
        }
        defer { consumer.cancel() }

        try await client.start(configuration: fixture.configuration)
        let target = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-sol",
            options: AgentExecutionOptions(effort: "high")
        )
        let session = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "MCP approval fixture",
                cwd: "/tmp/repository",
                target: target,
                developerInstructions: "Review the repository."
            )
        )
        let handle = try await provider.startRun(
            AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: "/tmp/repository",
                prompt: "Inspect an assembly.",
                target: target
            )
        )

        var events: [AgentEvent] = []
        for await event in handle.events {
            events.append(event)
        }

        #expect(!events.contains {
            if case .interaction = $0 { return true }
            return false
        })
        #expect(events.contains {
            if case .completed(let output, _, _) = $0 {
                return output == "Decompiler status inspected."
            }
            return false
        })
        await provider.shutdown()
        await client.shutdown()
    }

    @MainActor
    @Test
    func coordinatorRunsStrictImplementReviewFixGroupsUntilComplete() async throws {
        let fixture = try FakeAppServerFixture()
        defer { fixture.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = CodexAppServerClient()
        let router = SequencedTestRouter()
        let store = WorkspaceStore(rootURL: root)
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/repository",
            appServer: client,
            router: router,
            store: store,
            handoffConfigurationValidator: AcceptingHandoffConfigurationValidator()
        )
        let stream = await client.events()
        let consumer = Task {
            for await transportEvent in stream {
                await coordinator.handle(transportEvent.event)
            }
        }

        try await client.start(configuration: fixture.configuration)
        await coordinator.load()
        await coordinator.startActivity(goal: "Workflow", prompts: .builtInDefaults)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while coordinator.record.activity?.status != .completed, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let activity = try #require(coordinator.record.activity)
        #expect(activity.status == .completed)
        #expect(activity.runs.map(\.kind) == [
            .implementation,
            .review,
            .fix,
            .implementation,
            .review,
            .fix
        ])
        #expect(activity.runs.allSatisfy { $0.status == .completed })
        #expect(activity.runs.last?.handoff?.sourceDisposition == .fixComplete)
        #expect(activity.runs.map { $0.handoff?.runLabel } == [
            "Parser foundation",
            "Boundary review",
            "Boundary correction",
            "Parser completion",
            "Completion review",
            "Final verification"
        ])

        consumer.cancel()
        await client.shutdown()
    }

    @MainActor
    @Test
    func runningActivityQueuesGoalChangeAndActivatesItBeforeTheNextRun() async throws {
        let fixture = try PausingAppServerFixture()
        defer { fixture.remove() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = CodexAppServerClient()
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/repository-goal-change-\(UUID().uuidString)",
            appServer: client,
            router: SequencedTestRouter(),
            store: WorkspaceStore(rootURL: root),
            handoffConfigurationValidator: AcceptingHandoffConfigurationValidator()
        )
        let stream = await client.events()
        let consumer = Task {
            for await transportEvent in stream {
                await coordinator.handle(transportEvent.event)
            }
        }
        defer { consumer.cancel() }

        try await client.start(configuration: fixture.configuration)
        await coordinator.load()
        await coordinator.startActivity(goal: "Original goal", prompts: .builtInDefaults)

        #expect(coordinator.canAmendGoal)
        #expect(coordinator.goalAmendmentWillBeDeferred)
        #expect(await coordinator.amendGoal("Revised goal for the next boundary"))

        var activity = try #require(coordinator.record.activity)
        #expect(activity.goal == "Original goal")
        #expect(activity.pendingGoalAmendment?.revisedGoal == "Revised goal for the next boundary")
        #expect(activity.goalAmendments.isEmpty)

        #expect(await coordinator.steer("Finish the current checkpoint."))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while (coordinator.record.activity?.runs.count ?? 0) < 2, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        activity = try #require(coordinator.record.activity)
        #expect(activity.goal == "Revised goal for the next boundary")
        #expect(activity.pendingGoalAmendment == nil)
        #expect(activity.goalAmendments.last?.previousGoal == "Original goal")
        #expect(activity.goalAmendments.last?.revisedGoal == activity.goal)
        #expect(activity.runs.count == 2)
        #expect(activity.runs.last?.kind == .review)
        #expect(activity.runs.last?.prompt.contains(activity.goal) == true)
        await client.shutdown()
    }

    @MainActor
    @Test
    func gracefulDocumentPauseStopsBeforeRoutingAndPersistsTheCompletedTurn() async throws {
        let fixture = try PausingAppServerFixture()
        defer { fixture.remove() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = CodexAppServerClient()
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/repository",
            appServer: client,
            router: SequencedTestRouter(),
            store: WorkspaceStore(rootURL: root),
            handoffConfigurationValidator: AcceptingHandoffConfigurationValidator()
        )
        let stream = await client.events()
        let consumer = Task {
            for await transportEvent in stream {
                await coordinator.handle(transportEvent.event)
            }
        }
        defer { consumer.cancel() }

        try await client.start(configuration: fixture.configuration)
        await coordinator.load()
        await coordinator.startActivity(goal: "Pause recovery", prompts: .builtInDefaults)

        let result = await coordinator.prepareForClose(strategy: .graceful)
        let activity = try #require(coordinator.record.activity)
        let run = try #require(activity.runs.last)

        #expect(result == .ready)
        #expect(activity.status == .paused)
        #expect(activity.resumeCheckpoint == .routeCompletedRun(run.id))
        #expect(run.status == .routing)
        #expect(run.finalOutput == "Paused at a coherent checkpoint.")
        #expect(run.handoff == nil)
        #expect(coordinator.pauseState == .paused)
        await client.shutdown()
    }

    @MainActor
    @Test
    func eagerDocumentPausePersistsAnInterruptedRecoveryCheckpoint() async throws {
        let fixture = try PausingAppServerFixture()
        defer { fixture.remove() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = CodexAppServerClient()
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/repository",
            appServer: client,
            router: SequencedTestRouter(),
            store: WorkspaceStore(rootURL: root),
            handoffConfigurationValidator: AcceptingHandoffConfigurationValidator()
        )
        let stream = await client.events()
        let consumer = Task {
            for await transportEvent in stream {
                await coordinator.handle(transportEvent.event)
            }
        }
        defer { consumer.cancel() }

        try await client.start(configuration: fixture.configuration)
        await coordinator.load()
        await coordinator.startActivity(goal: "Pause recovery", prompts: .builtInDefaults)

        let result = await coordinator.prepareForClose(strategy: .immediate)
        let activity = try #require(coordinator.record.activity)
        let run = try #require(activity.runs.last)

        #expect(result == .ready)
        #expect(activity.status == .paused)
        #expect(activity.resumeCheckpoint == .recoverRun(run.id))
        #expect(run.status == .interrupted)
        #expect(coordinator.pauseState == .paused)
        await client.shutdown()
    }

    @MainActor
    @Test
    func doesNotStartCodexWhenTheQueuedRunCannotBeSaved() async throws {
        let fixture = try PausingAppServerFixture()
        defer { fixture.remove() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = CodexAppServerClient()
        let baseStore = WorkspaceStore(rootURL: root)
        let store = SelectiveFailingStore(
            base: baseStore,
            failurePoint: .queuedRun
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/repository-pre-save-\(UUID().uuidString)",
            appServer: client,
            router: SequencedTestRouter(),
            store: store,
            handoffConfigurationValidator: AcceptingHandoffConfigurationValidator()
        )
        let stream = await client.events()
        let consumer = Task {
            for await transportEvent in stream {
                await coordinator.handle(transportEvent.event)
            }
        }
        defer { consumer.cancel() }

        try await client.start(configuration: fixture.configuration)
        await coordinator.load()
        await coordinator.startActivity(goal: "Durable launch", prompts: .builtInDefaults)

        let activity = try #require(coordinator.record.activity)
        #expect(activity.status == .paused)
        #expect(activity.runs.isEmpty)
        #expect(activity.pendingAction == .implement)
        #expect(activity.resumeCheckpoint == .perform(.implement))
        #expect(!coordinator.hasActiveCodexTurn)
        #expect(coordinator.errorMessage?.contains("before starting Codex") == true)
        let saved = try await baseStore.load(canonicalPath: coordinator.record.canonicalPath)
        #expect(saved.activity?.status == .paused)
        #expect(saved.activity?.pendingAction == .implement)
        #expect(saved.activity?.resumeCheckpoint == .perform(.implement))
        #expect(saved.activity?.runs.isEmpty == true)
        await client.shutdown()
    }

    @MainActor
    @Test
    func activityCreationSaveFailureLeavesADurableRetryCheckpoint() async throws {
        let fixture = try PausingAppServerFixture()
        defer { fixture.remove() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = CodexAppServerClient()
        let baseStore = WorkspaceStore(rootURL: root)
        let store = SelectiveFailingStore(
            base: baseStore,
            failurePoint: .initialActivity
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/repository-initial-save-\(UUID().uuidString)",
            appServer: client,
            router: SequencedTestRouter(),
            store: store,
            handoffConfigurationValidator: AcceptingHandoffConfigurationValidator()
        )
        let stream = await client.events()
        let consumer = Task {
            for await transportEvent in stream {
                await coordinator.handle(transportEvent.event)
            }
        }
        defer { consumer.cancel() }

        try await client.start(configuration: fixture.configuration)
        await coordinator.load()
        await coordinator.startActivity(goal: "Retry activity creation", prompts: .builtInDefaults)

        let activity = try #require(coordinator.record.activity)
        #expect(activity.status == .paused)
        #expect(activity.runs.isEmpty)
        #expect(activity.pendingAction == .implement)
        #expect(activity.resumeCheckpoint == .perform(.implement))
        #expect(coordinator.canResume)
        #expect(!coordinator.hasActiveCodexTurn)
        #expect(coordinator.errorMessage?.contains("new activity") == true)

        let saved = try await baseStore.load(canonicalPath: coordinator.record.canonicalPath)
        #expect(saved.activity?.status == .paused)
        #expect(saved.activity?.pendingAction == .implement)
        #expect(saved.activity?.resumeCheckpoint == .perform(.implement))
        #expect(saved.activity?.runs.isEmpty == true)
        await client.shutdown()
    }

    @MainActor
    @Test
    func terminalCheckpointFailurePausesBeforeStartingTheRelay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repositoryPath = "/tmp/repository-terminal-save-\(UUID().uuidString)"
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .running,
            threadID: "implementer-thread",
            turnID: "turn-1",
            model: "model",
            effort: "high",
            prompt: "Implement",
            finalOutput: "Completed repository edits"
        )
        let record = RepositoryRecord(
            canonicalPath: repositoryPath,
            implementerThreadID: "implementer-thread",
            reviewerThreadID: "reviewer-thread",
            activity: ActivityRecord(
                goal: "Durable relay",
                prompts: .builtInDefaults,
                status: .paused,
                runs: [run]
            )
        )
        let baseStore = WorkspaceStore(rootURL: root)
        try await baseStore.save(record)
        let store = SelectiveFailingStore(
            base: baseStore,
            failurePoint: .terminalRouting
        )
        let router = CallCountingRouter()
        let coordinator = RepositoryCoordinator(
            canonicalPath: repositoryPath,
            appServer: CodexAppServerClient(),
            router: router,
            store: store
        )
        await coordinator.load()

        await coordinator.handle(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string("implementer-thread"),
                "turn": .object([
                    "id": .string("turn-1"),
                    "status": .string("completed"),
                    "durationMs": .integer(10),
                    "items": .array([])
                ])
            ]),
            rawLine: "completed"
        ))

        let activity = try #require(coordinator.record.activity)
        let pausedRun = try #require(activity.runs.last)
        #expect(activity.status == .paused)
        #expect(activity.resumeCheckpoint == .routeCompletedRun(run.id))
        #expect(pausedRun.status == .paused)
        #expect(pausedRun.finalOutput == "Completed repository edits")
        #expect(pausedRun.relayError?.isEmpty == false)
        #expect(coordinator.canResume)
        #expect(coordinator.errorMessage?.contains("did not start the handoff") == true)
        #expect(await router.callCount == 0)

        let saved = try await baseStore.load(canonicalPath: repositoryPath)
        #expect(saved.activity?.status == .paused)
        #expect(saved.activity?.resumeCheckpoint == .routeCompletedRun(run.id))
        #expect(saved.activity?.runs.last?.status == .paused)
    }

    @MainActor
    @Test
    func failedRepositorySettingsSaveRestoresThePersistedSettings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repositoryPath = "/tmp/repository-settings-save-\(UUID().uuidString)"
        let baseStore = WorkspaceStore(rootURL: root)
        let store = SelectiveFailingStore(
            base: baseStore,
            failurePoint: .repositorySettings(model: "unpersisted-model")
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: repositoryPath,
            appServer: CodexAppServerClient(),
            router: SequencedTestRouter(),
            store: store,
            handoffConfigurationValidator: AcceptingHandoffConfigurationValidator()
        )
        await coordinator.load()
        let original = coordinator.record.settings
        var changed = original
        changed.implementer = ModelSelection(model: "unpersisted-model", effort: "max")

        let savedSuccessfully = await coordinator.updateSettings(changed)

        #expect(!savedSuccessfully)
        #expect(coordinator.record.settings == original)
        #expect(coordinator.errorMessage?.contains("Injected workspace save failure") == true)
        let persisted = try await baseStore.load(
            canonicalPath: repositoryPath,
            defaultSettings: original
        )
        #expect(persisted.settings == original)
    }

    @MainActor
    @Test
    func failedActivityArchiveLeavesTheCurrentActivityAndSessionsIntact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repositoryPath = "/tmp/repository-start-over-failure-\(UUID().uuidString)"
        let record = RepositoryRecord(
            canonicalPath: repositoryPath,
            implementerThreadID: "old-implementer-thread",
            reviewerThreadID: "old-reviewer-thread",
            activity: ActivityRecord(
                goal: "Keep this activity",
                prompts: .builtInDefaults,
                status: .paused,
                runs: [
                    RunRecord(
                        sequence: 1,
                        role: .implementer,
                        kind: .implementation,
                        status: .interrupted,
                        threadID: "old-implementer-thread",
                        turnID: "old-turn",
                        model: "model",
                        effort: "high",
                        prompt: "Implement"
                    )
                ]
            )
        )
        let baseStore = WorkspaceStore(rootURL: root)
        try await baseStore.save(record)
        let coordinator = RepositoryCoordinator(
            canonicalPath: repositoryPath,
            appServer: CodexAppServerClient(),
            router: SequencedTestRouter(),
            store: SelectiveFailingStore(base: baseStore, failurePoint: .archiveActivity)
        )
        await coordinator.load()
        let beforeReset = coordinator.record
        #expect(coordinator.canStartOver)

        await coordinator.startOver()

        #expect(coordinator.record == beforeReset)
        #expect(coordinator.record.activityDraft == nil)
        #expect(coordinator.record.implementerThreadID == "old-implementer-thread")
        #expect(coordinator.record.reviewerThreadID == "old-reviewer-thread")
        #expect(coordinator.canStartOver)
        #expect(coordinator.errorMessage?.contains("Could not start over") == true)
        #expect(coordinator.errorMessage?.contains("Injected workspace save failure") == true)
        #expect(try await baseStore.load(canonicalPath: repositoryPath) == beforeReset)
    }

    @MainActor
    @Test
    func keepsAcceptedTurnActiveWhenItsRunningCheckpointCannotBeSaved() async throws {
        let fixture = try PausingAppServerFixture()
        defer { fixture.remove() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = CodexAppServerClient()
        let store = SelectiveFailingStore(
            base: WorkspaceStore(rootURL: root),
            failurePoint: .runningRun
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/repository-post-save-\(UUID().uuidString)",
            appServer: client,
            router: SequencedTestRouter(),
            store: store,
            handoffConfigurationValidator: AcceptingHandoffConfigurationValidator()
        )
        let stream = await client.events()
        let consumer = Task {
            for await transportEvent in stream {
                await coordinator.handle(transportEvent.event)
            }
        }
        defer { consumer.cancel() }

        try await client.start(configuration: fixture.configuration)
        await coordinator.load()
        await coordinator.startActivity(goal: "Live launch", prompts: .builtInDefaults)

        #expect(coordinator.record.activity?.status == .running)
        #expect(coordinator.record.activity?.runs.last?.status == .running)
        #expect(coordinator.record.activity?.runs.last?.turnID == "turn-1")
        #expect(coordinator.hasActiveCodexTurn)
        #expect(coordinator.errorMessage?.contains("turn started") == true)

        let closeResult = await coordinator.prepareForClose(strategy: .immediate)
        #expect(closeResult == .ready)
        #expect(coordinator.record.activity?.runs.last?.status == .interrupted)
        await client.shutdown()
    }
}

@Suite(.serialized)
struct CodexProviderReliabilityTests {
    @Test(.timeLimit(.minutes(1)))
    func abandonedRunEventConsumerFailsClosedWithoutBlockingTheProvider() async throws {
        let fixture = try LifecycleAppServerFixture(interruptEmitsTerminal: false)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            interruptionTerminalTimeout: .milliseconds(50),
            eventBufferCapacity: 1
        )
        let transportEvents = await client.events()
        let transportDrain = Task {
            for await _ in transportEvents {}
        }
        defer { transportDrain.cancel() }
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let runTarget = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-sol",
            options: AgentExecutionOptions(effort: "high")
        )
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: runTarget
        ))
        let executionID = try #require(handle.executionID)

        await provider.receive(.notification(
            method: "turn/started",
            params: .object([
                "threadId": .string(session.id),
                "turn": .object([
                    "id": .string(executionID),
                    "items": .array([]),
                    "status": .string("inProgress")
                ])
            ]),
            rawLine: "started"
        ))

        let transcriptProbe = ProviderReceiveProbe()
        let transcriptReceive = Task {
            await provider.receive(.notification(
                method: "item/agentMessage/delta",
                params: .object([
                    "threadId": .string(session.id),
                    "turnId": .string(executionID),
                    "itemId": .string("item-1"),
                    "delta": .string("buffered transcript")
                ]),
                rawLine: "transcript"
            ))
            await transcriptProbe.markCompleted()
        }
        try await Self.waitUntilAsync(timeout: .seconds(1)) {
            await transcriptProbe.completed
        }
        #expect(await transcriptProbe.completed)

        var iterator = handle.events.makeAsyncIterator()
        #expect(await iterator.next() == .started(executionID: executionID))
        await transcriptReceive.value
        guard case .failed(let detail) = await iterator.next() else {
            Issue.record("Expected an explicit bounded-event failure")
            await provider.shutdown()
            await client.shutdown()
            return
        }
        #expect(detail.contains("event consumer stopped draining"))
        #expect(await iterator.next() == nil)
        try await Self.waitUntilAsync(timeout: .seconds(1)) {
            await provider.runEventSnapshot(runID: runID) == nil
        }
        #expect(fixture.loggedMethods().filter { $0 == "turn/interrupt" }.count == 1)
        #expect(!(await client.isRunning))

        await provider.releaseSession(id: session.id)
        #expect(fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func overflowingRunCannotStallAnotherRunOrLaterRPCs() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client, eventBufferCapacity: 1)
        let transportEvents = await client.events()
        let transportDrain = Task {
            for await _ in transportEvents {}
        }
        defer { transportDrain.cancel() }
        try await client.start(configuration: fixture.configuration)
        let target = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-sol",
            options: AgentExecutionOptions(effort: "high")
        )
        let firstSession = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let secondSession = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let firstRunID = UUID()
        let secondRunID = UUID()
        let first = try await provider.startRun(AgentRunRequest(
            runID: firstRunID,
            session: firstSession,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: target
        ))
        let second = try await provider.startRun(AgentRunRequest(
            runID: secondRunID,
            session: secondSession,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: target
        ))
        let firstExecutionID = try #require(first.executionID)
        let secondExecutionID = try #require(second.executionID)
        await provider.receive(Self.startedEvent(
            sessionID: firstSession.id,
            executionID: firstExecutionID
        ))

        let serialPumpCompleted = ProviderReceiveProbe()
        let serialPump = Task {
            await provider.receive(.notification(
                method: "item/agentMessage/delta",
                params: .object([
                    "threadId": .string(firstSession.id),
                    "turnId": .string(firstExecutionID),
                    "itemId": .string("overflowing-item"),
                    "delta": .string("cannot block the next run")
                ]),
                rawLine: "overflow"
            ))
            await provider.receive(Self.startedEvent(
                sessionID: secondSession.id,
                executionID: secondExecutionID
            ))
            await serialPumpCompleted.markCompleted()
        }
        try await Self.waitUntilAsync(timeout: .seconds(1)) {
            await serialPumpCompleted.completed
        }
        await serialPump.value

        var secondIterator = second.events.makeAsyncIterator()
        #expect(await secondIterator.next() == .started(executionID: secondExecutionID))
        let loaded = try await client.loadedThreadIDs()
        #expect(loaded.contains(firstSession.id))
        #expect(loaded.contains(secondSession.id))
        await provider.shutdown()
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func terminalEventOverflowRemovesRunStateWithoutInterruptingAnEndedTurn() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client, eventBufferCapacity: 1)
        let transportEvents = await client.events()
        let transportDrain = Task {
            for await _ in transportEvents {}
        }
        defer { transportDrain.cancel() }
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            )
        ))
        let executionID = try #require(handle.executionID)
        await provider.receive(Self.startedEvent(
            sessionID: session.id,
            executionID: executionID
        ))
        await provider.receive(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(session.id),
                "turn": .object([
                    "id": .string(executionID),
                    "items": .array([]),
                    "status": .string("interrupted")
                ])
            ]),
            rawLine: "terminal"
        ))

        #expect(await provider.runEventSnapshot(runID: runID) == nil)
        #expect(fixture.loggedMethods().filter { $0 == "turn/interrupt" }.isEmpty)
        var iterator = handle.events.makeAsyncIterator()
        #expect(await iterator.next() == .started(executionID: executionID))
        #expect(await iterator.next() == .interrupted(nil))
        #expect(await iterator.next() == nil)
        await provider.shutdown()
        await client.shutdown()
    }

    @Test
    func terminalDeliveryPrecedesSessionReleaseWithoutExposingAnActiveRunRace() async throws {
        let fixture = try LifecycleAppServerFixture(unloadsOnUnsubscribe: true)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            )
        ))
        let executionID = try #require(handle.executionID)
        await provider.receive(Self.startedEvent(
            sessionID: session.id,
            executionID: executionID
        ))

        let consumer = Task { () -> (AgentEvent?, Bool) in
            var iterator = handle.events.makeAsyncIterator()
            _ = await iterator.next()
            let terminal = await iterator.next()
            let released = await provider.releaseSession(id: session.id)
            return (terminal, released)
        }
        await provider.receive(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(session.id),
                "turn": .object([
                    "id": .string(executionID),
                    "items": .array([]),
                    "status": .string("interrupted")
                ])
            ]),
            rawLine: "terminal"
        ))
        let result = await consumer.value
        #expect(result.0 == .interrupted(nil))
        #expect(result.1)
        #expect(fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.count == 1)
        #expect(fixture.loggedMethods().filter { $0 == "thread/delete" }.isEmpty)
        await client.shutdown()
    }

    @Test
    func delayedStartAndTerminalFromFinishedRunCannotBindPendingReplacementOnSameSession() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let secondStartGate = RequestRegistrationGate(
            blockedMethod: "turn/start",
            blockedOccurrence: 2
        )
        let client = CodexAppServerClient(testingRequestRegistrationHook: { method in
            await secondStartGate.blockIfNeeded(method: method)
        })
        let provider = CodexAgentProvider(appServer: client)
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let target = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-sol",
            options: AgentExecutionOptions(effort: "high")
        )

        let firstRunID = UUID()
        let first = try await provider.startRun(AgentRunRequest(
            runID: firstRunID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: target
        ))
        let firstExecutionID = try #require(first.executionID)
        await provider.receive(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(session.id),
                "turn": .object([
                    "id": .string(firstExecutionID),
                    "items": .array([]),
                    "status": .string("interrupted")
                ])
            ]),
            rawLine: "first terminal"
        ))
        #expect(await provider.runEventSnapshot(runID: firstRunID) == nil)

        let secondRunID = UUID()
        let secondStart = Task {
            try await provider.startRun(AgentRunRequest(
                runID: secondRunID,
                session: session,
                cwd: "/tmp/repository",
                prompt: "hold",
                target: target
            ))
        }
        await secondStartGate.waitUntilReached()

        // B is registered but its start request has not received a response.
        // A's retired execution must not bind merely because B still has a nil
        // execution ID on this persistent phase session.
        await provider.receive(Self.startedEvent(
            sessionID: session.id,
            executionID: firstExecutionID
        ))
        await provider.receive(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(session.id),
                "turn": .object([
                    "id": .string(firstExecutionID),
                    "items": .array([]),
                    "status": .string("interrupted")
                ])
            ]),
            rawLine: "delayed first terminal before replacement response"
        ))
        #expect(await provider.runEventSnapshot(runID: secondRunID) != nil)

        await secondStartGate.release()
        let second = try await secondStart.value
        let secondExecutionID = try #require(second.executionID)
        await provider.receive(Self.startedEvent(
            sessionID: session.id,
            executionID: secondExecutionID
        ))

        // The old execution mapping was removed when run A finished. This
        // delayed duplicate must not fall back through the persistent session
        // and terminate the now-active run B.
        await provider.receive(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(session.id),
                "turn": .object([
                    "id": .string(firstExecutionID),
                    "items": .array([]),
                    "status": .string("interrupted")
                ])
            ]),
            rawLine: "delayed first terminal"
        ))
        #expect(await provider.runEventSnapshot(runID: secondRunID) != nil)

        await provider.receive(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(session.id),
                "turn": .object([
                    "id": .string(secondExecutionID),
                    "items": .array([]),
                    "status": .string("interrupted")
                ])
            ]),
            rawLine: "second terminal"
        ))
        var iterator = second.events.makeAsyncIterator()
        #expect(await iterator.next() == .started(executionID: secondExecutionID))
        #expect(await iterator.next() == .interrupted(nil))
        #expect(await iterator.next() == nil)
        await client.shutdown()
    }

    @Test
    func preResponseStartedIdentityMismatchFailsAndCancelsTheAcceptedTurn() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let startGate = RequestRegistrationGate(blockedMethod: "turn/start")
        let client = CodexAppServerClient(testingRequestRegistrationHook: { method in
            await startGate.blockIfNeeded(method: method)
        })
        let provider = CodexAgentProvider(appServer: client)
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let start = Task {
            try await provider.startRun(AgentRunRequest(
                runID: runID,
                session: session,
                cwd: "/tmp/repository",
                prompt: "hold",
                target: AgentTarget(
                    providerID: .codex,
                    model: "gpt-5.6-sol",
                    options: AgentExecutionOptions(effort: "high")
                )
            ))
        }
        await startGate.waitUntilReached()
        await provider.receive(Self.startedEvent(
            sessionID: session.id,
            executionID: "notification-only-turn"
        ))
        await startGate.release()

        do {
            _ = try await start.value
            Issue.record("Expected mismatched start identities to fail")
        } catch {
            #expect(error.localizedDescription.contains("ambiguous execution"))
        }
        #expect(await provider.runEventSnapshot(runID: runID) == nil)
        #expect(fixture.loggedMethods().filter { $0 == "turn/interrupt" }.isEmpty)
        #expect(!(await client.isRunning))
    }

    @Test
    func postResponseStartedIdentityMismatchTerminatesTheAppServerGeneration() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        _ = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            )
        ))

        await provider.receive(Self.startedEvent(
            sessionID: session.id,
            executionID: "unexpected-notification-turn"
        ))

        #expect(await provider.runEventSnapshot(runID: runID) == nil)
        #expect(!(await client.isRunning))
    }

    @Test(.timeLimit(.minutes(1)))
    func ambiguousTerminalCannotReleaseProviderContainmentWhenCleanupIsUnconfirmed() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let readGate = ProviderProtocolOutputReadGate()
        defer { readGate.release() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            terminationGrace: .milliseconds(50),
            outputDrainGrace: .milliseconds(100),
            testingBeforeOutputReadHook: { readGate.blockIfArmed() }
        )
        defer { Task { await client.shutdown() } }
        let provider = CodexAgentProvider(appServer: client)
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            )
        ))
        let acceptedExecutionID = try #require(handle.executionID)

        readGate.arm()
        let mismatch = Task {
            await provider.receive(Self.startedEvent(
                sessionID: session.id,
                executionID: "ambiguous-execution"
            ))
        }
        await readGate.waitUntilEntered()

        // This terminal is plausible for the accepted ID, but turn identity is
        // already ambiguous. It must not release ownership while process cleanup
        // is suspended.
        await provider.receive(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(session.id),
                "turn": .object([
                    "id": .string(acceptedExecutionID),
                    "items": .array([]),
                    "status": .string("completed")
                ])
            ]),
            rawLine: "terminal during protocol containment"
        ))
        #expect(await provider.runEventSnapshot(runID: runID) != nil)
        #expect(await provider.releaseSession(id: session.id) == false)
        do {
            _ = try await provider.prepareSession(Self.sessionRequest(
                existingSessionID: session.id
            ))
            Issue.record("Expected replacement admission to remain fenced")
        } catch {
            #expect(error.localizedDescription.contains("ambiguous execution"))
        }

        // The bounded transport wait expires while the output-reader join is
        // intentionally held. A false cleanup result must preserve the distinct
        // generation debt rather than degrading into an ordinary turn tombstone.
        await mismatch.value
        #expect(await provider.runEventSnapshot(runID: runID) != nil)
        #expect(
            await provider.cleanupDebtSnapshot().protocolContainment?
                .contains("could not confirm") == true
        )
        await provider.receive(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(session.id),
                "turn": .object([
                    "id": .string("ambiguous-execution"),
                    "items": .array([]),
                    "status": .string("completed")
                ])
            ]),
            rawLine: "second terminal after cleanup timeout"
        ))
        #expect(await provider.runEventSnapshot(runID: runID) != nil)

        // Verified provider shutdown is also a definitive process boundary. It
        // may suppress the transport's exit event, so the provider explicitly
        // clears containment only after App Server shutdown returns true. The
        // first bounded attempt is still held and must preserve the gate; a
        // later verified retry succeeds without depending on an exit event.
        #expect(await provider.shutdownAndVerify() == false)
        #expect(await provider.cleanupDebtSnapshot().protocolContainment != nil)
        let verifiedShutdown = Task {
            await provider.shutdownAndVerify()
        }
        try await Task.sleep(for: .milliseconds(50))
        readGate.release()
        #expect(await verifiedShutdown.value)
        #expect(await provider.cleanupDebtSnapshot().protocolContainment == nil)
        #expect(await provider.runEventSnapshot(runID: runID) == nil)
        #expect(!(await client.isRunning))
    }

    @Test
    func unexpectedThreadCloseTerminatesEveryNormalActiveRun() async throws {
        let fixture = try LifecycleAppServerFixture(unloadsOnUnsubscribe: true)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            )
        ))
        let executionID = try #require(handle.executionID)
        await provider.receive(Self.startedEvent(
            sessionID: session.id,
            executionID: executionID
        ))
        await provider.receive(.notification(
            method: "thread/closed",
            params: .object(["threadId": .string(session.id)]),
            rawLine: "closed"
        ))

        var iterator = handle.events.makeAsyncIterator()
        #expect(await iterator.next() == .started(executionID: executionID))
        guard case .sessionUnavailable(let detail) = await iterator.next() else {
            Issue.record("Expected the unexpected close to terminate the active run")
            return
        }
        #expect(detail.contains("closed the active thread"))
        #expect(await iterator.next() == nil)
        #expect(await provider.runEventSnapshot(runID: runID) == nil)
        #expect(await provider.releaseSession(id: session.id))
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func persistentSessionRejectsASecondConcurrentRun() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        let transportEvents = await client.events()
        let transportDrain = Task {
            for await _ in transportEvents {}
        }
        defer { transportDrain.cancel() }
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let target = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-sol",
            options: AgentExecutionOptions(effort: "high")
        )
        _ = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: target
        ))

        await #expect(throws: AgentProviderError.self) {
            _ = try await provider.startRun(AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: "/tmp/repository",
                prompt: "hold",
                target: target
            ))
        }
        #expect(fixture.loggedMethods().filter { $0 == "turn/start" }.count == 1)
        await provider.shutdown()
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func completedDeltaItemsDoNotAccumulateInRunState() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client, eventBufferCapacity: 16)
        let transportEvents = await client.events()
        let transportDrain = Task {
            for await _ in transportEvents {}
        }
        defer { transportDrain.cancel() }
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            )
        ))
        let executionID = try #require(handle.executionID)
        let runEventDrain = Task {
            for await _ in handle.events {}
        }

        for index in 0..<1_000 {
            let itemID = "completed-item-\(index)"
            await provider.receive(.notification(
                method: "item/agentMessage/delta",
                params: .object([
                    "threadId": .string(session.id),
                    "turnId": .string(executionID),
                    "itemId": .string(itemID),
                    "delta": .string("x")
                ]),
                rawLine: "delta"
            ))
            await provider.receive(.notification(
                method: "item/completed",
                params: .object([
                    "threadId": .string(session.id),
                    "turnId": .string(executionID),
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

        #expect(await provider.runEventSnapshot(runID: runID)?.itemsWithDeltas.isEmpty == true)
        await provider.shutdown()
        await runEventDrain.value
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingRunEventConsumerWaitsForTheAuthoritativeTerminal() async throws {
        let fixture = try LifecycleAppServerFixture(interruptEmitsTerminal: false)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        let transportEvents = await client.events()
        let transportDrain = Task {
            for await _ in transportEvents {}
        }
        defer { transportDrain.cancel() }
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            )
        ))
        let consumer = Task {
            for await _ in handle.events {}
        }
        try await Task.sleep(for: .milliseconds(20))
        consumer.cancel()
        await consumer.value

        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "turn/interrupt" }.count == 1
        }
        #expect(await provider.runEventSnapshot(runID: runID) != nil)
        #expect(await provider.cleanupDebtSnapshot().interruptedRuns[runID] != nil)
        #expect(fixture.loggedMethods().filter { $0 == "thread/delete" }.isEmpty)
        #expect(fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.isEmpty)

        let executionID = try #require(handle.executionID)
        await provider.receive(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(session.id),
                "turn": .object([
                    "id": .string(executionID),
                    "items": .array([]),
                    "status": .string("interrupted")
                ])
            ]),
            rawLine: "authoritative interrupted terminal"
        ))

        #expect(await provider.runEventSnapshot(runID: runID) == nil)
        #expect(await provider.cleanupDebtSnapshot().interruptedRuns.isEmpty)
        #expect(fixture.loggedMethods().filter { $0 == "turn/interrupt" }.count == 1)
        await provider.shutdown()
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func acknowledgedInterruptWithoutATerminalContainsTheWholeGeneration() async throws {
        let fixture = try LifecycleAppServerFixture(interruptEmitsTerminal: false)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            interruptionTerminalTimeout: .milliseconds(50)
        )
        let transportEvents = await client.events()
        let transportDrain = Task {
            for await _ in transportEvents {}
        }
        defer { transportDrain.cancel() }
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            )
        ))
        let executionID = try #require(handle.executionID)
        await provider.receive(Self.startedEvent(
            sessionID: session.id,
            executionID: executionID
        ))

        try await provider.interrupt(runID: runID)
        #expect(await provider.runEventSnapshot(runID: runID) != nil)
        #expect(await provider.cleanupDebtSnapshot().interruptedRuns[runID] != nil)

        try await Self.waitUntilAsync(timeout: .seconds(2)) {
            let clientStopped = !(await client.isRunning)
            let runEnded = await provider.runEventSnapshot(runID: runID) == nil
            return clientStopped && runEnded
        }
        #expect(fixture.loggedMethods().filter { $0 == "turn/interrupt" }.count == 1)
        #expect(fixture.loggedMethods().filter { $0 == "thread/delete" }.isEmpty)
        #expect(fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.isEmpty)
        #expect(await provider.cleanupDebtSnapshot().protocolContainment == nil)

        var iterator = handle.events.makeAsyncIterator()
        #expect(await iterator.next() == .started(executionID: executionID))
        guard case .failed(let detail) = await iterator.next() else {
            Issue.record("Expected generation-containment failure")
            return
        }
        #expect(detail.contains("did not emit the authoritative turn/completed"))
        #expect(await iterator.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func threadClosureCannotReplaceTheTerminalForAnInterruptedTurn() async throws {
        let fixture = try LifecycleAppServerFixture(interruptEmitsTerminal: false)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            interruptionTerminalTimeout: .seconds(5)
        )
        let transportEvents = await client.events()
        let transportDrain = Task {
            for await _ in transportEvents {}
        }
        defer { transportDrain.cancel() }
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            )
        ))
        let executionID = try #require(handle.executionID)
        await provider.receive(Self.startedEvent(
            sessionID: session.id,
            executionID: executionID
        ))
        try await provider.interrupt(runID: runID)

        await provider.receive(.notification(
            method: "thread/closed",
            params: .object(["threadId": .string(session.id)]),
            rawLine: "thread closed without turn terminal"
        ))

        #expect(!(await client.isRunning))
        #expect(await provider.runEventSnapshot(runID: runID) == nil)
        #expect(fixture.loggedMethods().filter { $0 == "thread/delete" }.isEmpty)
        #expect(fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.isEmpty)
        var iterator = handle.events.makeAsyncIterator()
        #expect(await iterator.next() == .started(executionID: executionID))
        guard case .failed(let detail) = await iterator.next() else {
            Issue.record("Expected thread-closure containment failure")
            return
        }
        #expect(detail.contains("thread closure alone cannot prove"))
        #expect(await iterator.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func threadClosureBeforeManualInterruptAcknowledgementContainsGeneration() async throws {
        let fixture = try LifecycleAppServerFixture(interruptEmitsTerminal: false)
        defer { fixture.remove() }
        let gate = RequestRegistrationGate(blockedMethod: "turn/interrupt")
        let client = CodexAppServerClient(testingRequestRegistrationHook: { method in
            await gate.blockIfNeeded(method: method)
        })
        let provider = CodexAgentProvider(
            appServer: client,
            interruptionTerminalTimeout: .seconds(5)
        )
        let transportEvents = await client.events()
        let transportDrain = Task {
            for await _ in transportEvents {}
        }
        defer { transportDrain.cancel() }
        defer { Task { await gate.release() } }
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            )
        ))
        let executionID = try #require(handle.executionID)
        await provider.receive(Self.startedEvent(
            sessionID: session.id,
            executionID: executionID
        ))

        let interruption = Task {
            try await provider.interrupt(runID: runID)
        }
        await gate.waitUntilReached()
        #expect(await provider.cleanupDebtSnapshot().interruptedRuns[runID] != nil)
        #expect(fixture.loggedMethods().filter { $0 == "turn/interrupt" }.isEmpty)

        await provider.receive(.notification(
            method: "thread/closed",
            params: .object(["threadId": .string(session.id)]),
            rawLine: "thread closed before manual interrupt acknowledgement"
        ))
        await gate.release()

        do {
            try await interruption.value
            Issue.record("Expected the interrupted request to fail after generation containment")
        } catch {
            // The request was fenced behind the old process generation.
        }
        #expect(!(await client.isRunning))
        #expect(await provider.runEventSnapshot(runID: runID) == nil)
        #expect(fixture.loggedMethods().filter { $0 == "thread/delete" }.isEmpty)
        #expect(fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.isEmpty)
        var iterator = handle.events.makeAsyncIterator()
        #expect(await iterator.next() == .started(executionID: executionID))
        guard case .failed(let detail) = await iterator.next() else {
            Issue.record("Expected pre-acknowledgement containment failure")
            return
        }
        #expect(detail.contains("thread closure alone cannot prove"))
        #expect(await iterator.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func threadClosureBeforeUtilityCancellationAcknowledgementContainsGeneration() async throws {
        let fixture = try LifecycleAppServerFixture(interruptEmitsTerminal: false)
        defer { fixture.remove() }
        let gate = RequestRegistrationGate(blockedMethod: "turn/interrupt")
        let client = CodexAppServerClient(testingRequestRegistrationHook: { method in
            await gate.blockIfNeeded(method: method)
        })
        let provider = CodexAgentProvider(
            appServer: client,
            interruptionTerminalTimeout: .seconds(5)
        )
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        defer { Task { await gate.release() } }
        try await client.start(configuration: fixture.configuration)

        let utility = Task {
            try await provider.runUtility(Self.utilityRequest(prompt: "hold"))
        }
        try await Self.waitUntil {
            fixture.loggedMethods().contains("turn/start")
        }
        let utilitySessionID = try #require(try await client.loadedThreadIDs().first)
        utility.cancel()
        await gate.waitUntilReached()
        #expect(await provider.cleanupDebtSnapshot().interruptedRuns.count == 1)
        #expect(fixture.loggedMethods().filter { $0 == "turn/interrupt" }.isEmpty)

        await provider.receive(.notification(
            method: "thread/closed",
            params: .object(["threadId": .string(utilitySessionID)]),
            rawLine: "thread closed before utility cancellation acknowledgement"
        ))
        await gate.release()

        await #expect(throws: CancellationError.self) {
            _ = try await utility.value
        }
        #expect(!(await client.isRunning))
        #expect(fixture.loggedMethods().filter { $0 == "thread/delete" }.isEmpty)
        #expect(fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.isEmpty)
        #expect(await provider.cleanupDebtSnapshot().protocolContainment == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func failedAutomaticMCPResponseRetainsCancellationDebtInsteadOfOrphaningRun() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            maximumCleanupAttemptCount: 1
        )
        let transportEvents = await client.events()
        let transportDrain = Task {
            for await _ in transportEvents {}
        }
        defer { transportDrain.cancel() }
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            )
        ))
        let executionID = try #require(handle.executionID)
        await client.shutdown()

        await provider.receive(.request(
            id: .integer(77),
            method: "mcpServer/elicitation/request",
            params: .object([
                "threadId": .string(session.id),
                "turnId": .string(executionID),
                "_meta": .object([
                    "codex_approval_kind": .string("mcp_tool_call")
                ])
            ]),
            rawLine: "automatic MCP approval"
        ))

        var iterator = handle.events.makeAsyncIterator()
        guard case .failed(let detail) = await iterator.next() else {
            Issue.record("Expected the response-delivery failure")
            await provider.shutdown()
            return
        }
        #expect(detail.contains("Could not automatically approve"))
        try await Self.waitUntilAsync(timeout: .seconds(1)) {
            await provider.cleanupDebtSnapshot().interruptedRuns[runID] != nil
        }
        #expect(await provider.runEventSnapshot(runID: runID) != nil)
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownCannotDeadlockBehindAFullAbandonedRunBuffer() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client, eventBufferCapacity: 1)
        let transportEvents = await client.events()
        let transportDrain = Task {
            for await _ in transportEvents {}
        }
        defer { transportDrain.cancel() }
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let target = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-sol",
            options: AgentExecutionOptions(effort: "high")
        )
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: target
        ))
        let executionID = try #require(handle.executionID)
        await provider.receive(.notification(
            method: "turn/started",
            params: .object([
                "threadId": .string(session.id),
                "turn": .object(["id": .string(executionID)])
            ]),
            rawLine: "started"
        ))

        let completion = ProviderReceiveProbe()
        let shutdown = Task {
            await provider.shutdown()
            await completion.markCompleted()
        }
        defer { shutdown.cancel() }
        try await Self.waitUntilAsync(timeout: .seconds(1)) {
            await completion.completed
        }

        var iterator = handle.events.makeAsyncIterator()
        #expect(await iterator.next() == .started(executionID: executionID))
        #expect(await iterator.next() == .failed("Codex stopped."))
        #expect(await iterator.next() == nil)
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func processExitCannotDeadlockBehindAFullAbandonedRunBuffer() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client, eventBufferCapacity: 1)
        let transportEvents = await client.events()
        let transportDrain = Task {
            for await _ in transportEvents {}
        }
        defer { transportDrain.cancel() }
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let target = AgentTarget(
            providerID: .codex,
            model: "gpt-5.6-sol",
            options: AgentExecutionOptions(effort: "high")
        )
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: target
        ))
        let executionID = try #require(handle.executionID)
        await provider.receive(.notification(
            method: "turn/started",
            params: .object([
                "threadId": .string(session.id),
                "turn": .object(["id": .string(executionID)])
            ]),
            rawLine: "started"
        ))

        let completion = ProviderReceiveProbe()
        let exitHandling = Task {
            await provider.receive(.exited(
                SubprocessTermination(reason: .uncaughtSignal, status: SIGSEGV)
            ))
            await completion.markCompleted()
        }
        defer { exitHandling.cancel() }
        try await Self.waitUntilAsync(timeout: .seconds(1)) {
            await completion.completed
        }

        var iterator = handle.events.makeAsyncIterator()
        #expect(await iterator.next() == .started(executionID: executionID))
        #expect(await iterator.next() == .failed("Codex App Server crashed."))
        #expect(await iterator.next() == nil)
        await client.shutdown()
    }

    @Test
    func concurrentPreparationResumesTheSamePersistentSessionOnlyOnce() async throws {
        let fixture = try LifecycleAppServerFixture(resumeDelayMilliseconds: 100)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        try await client.start(configuration: fixture.configuration)

        let request = Self.sessionRequest(existingSessionID: "phase-thread")
        let outcomes = await Self.concurrentPreparationOutcomes(
            provider: provider,
            request: request,
            count: 2
        )

        #expect(outcomes.filter { $0.hasPrefix("success:") }.count == 2)
        #expect(fixture.loggedMethods().filter { $0 == "thread/resume" }.count == 1)
        await client.shutdown()
    }

    @Test
    func concurrentAdmissionsCannotExceedTheLoadedThreadLimit() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            maximumLoadedThreadCount: 1
        )
        try await client.start(configuration: fixture.configuration)

        let outcomes = await Self.concurrentPreparationOutcomes(
            provider: provider,
            request: Self.sessionRequest(existingSessionID: nil),
            count: 2
        )

        #expect(outcomes.filter { $0.hasPrefix("success:") }.count == 1)
        #expect(outcomes.filter { $0.contains("loaded or reserved") }.count == 1)
        #expect(fixture.loggedMethods().filter { $0 == "thread/start" }.count == 1)
        await client.shutdown()
    }

    @Test
    func concurrentUtilityAdmissionsCannotExceedTheRetainedUtilityLimit() async throws {
        let fixture = try LifecycleAppServerFixture(deleteFailures: 1_000_000)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            maximumLoadedThreadCount: 10,
            maximumRetainedUtilityThreadCount: 1
        )
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        let outcomes = await withTaskGroup(
            of: String.self,
            returning: [String].self
        ) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        let result = try await provider.runUtility(
                            Self.utilityRequest(prompt: "complete")
                        )
                        return "success:\(result.output)"
                    } catch {
                        return "failure:\(error.localizedDescription)"
                    }
                }
            }
            var outcomes: [String] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }

        #expect(outcomes.filter { $0.hasPrefix("success:") }.count == 1)
        #expect(outcomes.filter { $0.contains("still retaining 1") }.count == 1)
        #expect(fixture.loggedMethods().filter { $0 == "thread/start" }.count == 1)
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func defaultUtilityBudgetAllowsTwentyRetainedThreadsAndReservesTheTotalBudget() async throws {
        let fixture = try LifecycleAppServerFixture(deleteFailures: 1_000_000)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        for _ in 1...20 {
            let result = try await provider.runUtility(Self.utilityRequest(prompt: "complete"))
            #expect(result.output == "utility complete")
        }

        do {
            _ = try await provider.runUtility(Self.utilityRequest(prompt: "complete"))
            Issue.record("Expected the twenty-thread utility budget to stop another utility")
        } catch {
            #expect(error.localizedDescription.contains("still retaining 20"))
        }

        for _ in 1...4 {
            _ = try await provider.prepareSession(Self.sessionRequest(existingSessionID: nil))
        }
        do {
            _ = try await provider.prepareSession(Self.sessionRequest(existingSessionID: nil))
            Issue.record("Expected the total loaded-thread budget to remain 24")
        } catch {
            #expect(error.localizedDescription.contains("24 loaded or reserved"))
        }

        #expect(fixture.loggedMethods().filter { $0 == "thread/start" }.count == 24)
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func maximumPersistentWorkflowSessionBudgetLeavesRoomForCoordinatorUtility() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        var persistentSessions: [AgentSession] = []
        for _ in 0..<CodexAgentProvider.maximumPersistentWorkflowSessionCount {
            persistentSessions.append(try await provider.prepareSession(
                Self.sessionRequest(existingSessionID: nil)
            ))
        }
        #expect(
            try await client.loadedThreadIDs().count
                == CodexAgentProvider.maximumPersistentWorkflowSessionCount
        )

        let routed = try await provider.runUtility(
            Self.utilityRequest(prompt: "complete")
        )

        #expect(routed.output == "utility complete")
        #expect(
            Set(try await client.loadedThreadIDs())
                == Set(persistentSessions.map(\.id))
        )
        let methods = fixture.loggedMethods()
        #expect(
            methods.filter { $0 == "thread/start" }.count
                == CodexAgentProvider.maximumLoadedThreadBudget
        )
        #expect(methods.filter { $0 == "thread/delete" }.count == 1)
        #expect(methods.filter { $0 == "thread/unsubscribe" }.isEmpty)
        await client.shutdown()
    }

    @Test
    func cleanupRetryPolicyIsDeterministicJitteredExponentialAndBounded() {
        let policy = CodexCleanupRetryPolicy(
            maximumAttemptCount: 8,
            baseDelay: .milliseconds(100),
            maximumDelay: .seconds(2)
        )
        let delays = (1...8).map {
            policy.delay(afterAttempt: $0, resourceKey: "utility-alpha")
        }

        #expect(policy.maximumAttemptCount == 8)
        #expect(delays == (1...8).map {
            policy.delay(afterAttempt: $0, resourceKey: "utility-alpha")
        })
        #expect(delays[0] < delays[1])
        #expect(delays[1] < delays[2])
        #expect(delays[2] < delays[3])
        #expect(delays.allSatisfy { $0 <= .seconds(2) })
        #expect(
            policy.delay(afterAttempt: 1, resourceKey: "utility-alpha")
                != policy.delay(afterAttempt: 1, resourceKey: "utility-beta")
        )
    }

    @Test
    func admissionFailsClosedWhenLoadedThreadsCannotBeInspected() async throws {
        let fixture = try LifecycleAppServerFixture(rejectsLoadedList: true)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        try await client.start(configuration: fixture.configuration)

        do {
            _ = try await provider.prepareSession(Self.sessionRequest(existingSessionID: nil))
            Issue.record("Expected loaded-thread admission to fail closed")
        } catch {
            #expect(error.localizedDescription.contains("could not verify"))
            #expect(error.localizedDescription.contains("stopped before admitting"))
        }
        #expect(fixture.loggedMethods().filter { $0 == "thread/start" }.isEmpty)
        await client.shutdown()
    }

    @Test
    func controlRequestDeadlineRetiresLateResponsesWithoutPoisoningLaterRequests() async throws {
        let fixture = try LifecycleAppServerFixture(loadedListDelayMilliseconds: 150)
        defer { fixture.remove() }
        let client = CodexAppServerClient(controlRequestTimeout: .milliseconds(30))
        let recorder = StandardErrorRecorder()
        let events = await client.events()
        let consumer = Task {
            for await transportEvent in events {
                if case .standardError(let detail) = transportEvent.event {
                    await recorder.append(detail)
                }
            }
        }
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        do {
            _ = try await client.loadedThreadIDs()
            Issue.record("Expected the control request to time out")
        } catch let error as AppServerClientError {
            guard case .requestTimedOut(let method) = error else {
                Issue.record("Unexpected App Server error: \(error.localizedDescription)")
                await client.shutdown()
                return
            }
            #expect(method == "thread/loaded/list")
        }

        try await Task.sleep(for: .milliseconds(180))
        #expect(try await client.loadedThreadIDs().isEmpty)
        #expect(await recorder.values().allSatisfy {
            !$0.contains("Unrecognized App Server message")
        })
        await client.shutdown()
    }

    @Test
    func cancellingAControlRequestReturnsBeforeItsLateResponse() async throws {
        let fixture = try LifecycleAppServerFixture(loadedListDelayMilliseconds: 350)
        defer { fixture.remove() }
        let client = CodexAppServerClient(controlRequestTimeout: .seconds(2))
        try await client.start(configuration: fixture.configuration)

        let request = Task { try await client.loadedThreadIDs() }
        try await Self.waitUntil {
            fixture.loggedMethods().contains("thread/loaded/list")
        }
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(clock.now - cancelledAt < .milliseconds(200))
        } catch {
            Issue.record("Unexpected cancellation error: \(error.localizedDescription)")
        }

        try await Task.sleep(for: .milliseconds(380))
        #expect(try await client.loadedThreadIDs().isEmpty)
        await client.shutdown()
    }

    @Test
    func cancellationBeforeRequestRegistrationNeverWritesTheRequest() async throws {
        let fixture = try LifecycleAppServerFixture()
        defer { fixture.remove() }
        let gate = RequestRegistrationGate(blockedMethod: "thread/loaded/list")
        let client = CodexAppServerClient(testingRequestRegistrationHook: { method in
            await gate.blockIfNeeded(method: method)
        })
        try await client.start(configuration: fixture.configuration)

        let request = Task { try await client.loadedThreadIDs() }
        await gate.waitUntilReached()
        request.cancel()
        await gate.release()

        do {
            _ = try await request.value
            Issue.record("Expected cancellation before the request was written")
        } catch is CancellationError {
            // Expected: no outcome-sensitive request exists until the pipe write.
        } catch {
            Issue.record("Unexpected cancellation error: \(error.localizedDescription)")
        }
        #expect(fixture.loggedMethods().filter { $0 == "thread/loaded/list" }.isEmpty)
        #expect(await client.isRunning)
        await client.shutdown()
    }

    @Test
    func cancelledAcceptedThreadStartsAndResumesAreUnsubscribed() async throws {
        let fixture = try LifecycleAppServerFixture(
            threadStartDelayMilliseconds: 150,
            resumeDelayMilliseconds: 150,
            unloadsOnUnsubscribe: true
        )
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        try await client.start(configuration: fixture.configuration)

        let fresh = Task {
            try await provider.prepareSession(Self.sessionRequest(existingSessionID: nil))
        }
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "thread/start" }.count == 1
        }
        fresh.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await fresh.value
        }
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.count >= 1
        }

        let resumed = Task {
            try await provider.prepareSession(Self.sessionRequest(existingSessionID: "phase-thread"))
        }
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "thread/resume" }.count == 1
        }
        resumed.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await resumed.value
        }
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.count >= 2
        }

        #expect(try await client.loadedThreadIDs().isEmpty)
        #expect(fixture.loggedMethods().filter { $0 == "thread/delete" }.isEmpty)
        #expect(fixture.loggedMethods().filter { $0 == "thread/name/set" }.isEmpty)
        await client.shutdown()
    }

    @Test
    func reprepareWaitsForFullyWrittenUnsubscribeOutcomeBeforeResumingSession() async throws {
        let fixture = try LifecycleAppServerFixture(
            unsubscribeDelayMilliseconds: 180,
            unloadsOnUnsubscribe: true
        )
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )

        let release = Task { await provider.releaseSession(id: session.id) }
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.count == 1
        }
        let reprepare = Task {
            try await provider.prepareSession(
                Self.sessionRequest(existingSessionID: session.id)
            )
        }
        try await Task.sleep(for: .milliseconds(60))
        #expect(fixture.loggedMethods().filter { $0 == "thread/resume" }.isEmpty)

        #expect(await release.value)
        let resumed = try await reprepare.value
        #expect(resumed.id == session.id)
        let methods = fixture.loggedMethods()
        let unsubscribeIndex = try #require(methods.firstIndex(of: "thread/unsubscribe"))
        let resumeIndex = try #require(methods.firstIndex(of: "thread/resume"))
        #expect(unsubscribeIndex < resumeIndex)
        #expect(Set(try await client.loadedThreadIDs()) == Set([session.id]))
        await client.shutdown()
    }

    @Test
    func cancelledAcceptedUtilityThreadStartIsDeletedBeforeAnyTurnStarts() async throws {
        let fixture = try LifecycleAppServerFixture(
            threadStartDelayMilliseconds: 150,
            unloadsOnUnsubscribe: true
        )
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        try await client.start(configuration: fixture.configuration)

        let utility = Task {
            try await provider.runUtility(Self.utilityRequest(prompt: "hold"))
        }
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "thread/start" }.count == 1
        }
        utility.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await utility.value
        }
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "thread/delete" }.count == 1
        }

        #expect(fixture.loggedMethods().filter { $0 == "turn/start" }.isEmpty)
        #expect(try await client.loadedThreadIDs().isEmpty)
        let debt = await provider.cleanupDebtSnapshot()
        #expect(debt.interruptedRuns.isEmpty)
        #expect(debt.deleteThreads.isEmpty)
        #expect(debt.unsubscribeThreads.isEmpty)
        await client.shutdown()
    }

    @Test
    func cancelledAcceptedUtilityTurnIsInterruptedBeforeItsThreadIsDeleted() async throws {
        let fixture = try LifecycleAppServerFixture(
            turnStartDelayMilliseconds: 150,
            unloadsOnUnsubscribe: true
        )
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        let utility = Task {
            try await provider.runUtility(Self.utilityRequest(prompt: "hold"))
        }
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "turn/start" }.count == 1
        }
        utility.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await utility.value
        }
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "turn/interrupt" }.count == 1
                && fixture.loggedMethods().filter { $0 == "thread/delete" }.count == 1
        }

        #expect(try await client.loadedThreadIDs().isEmpty)
        let debt = await provider.cleanupDebtSnapshot()
        #expect(debt.interruptedRuns.isEmpty)
        #expect(debt.deleteThreads.isEmpty)
        #expect(debt.unsubscribeThreads.isEmpty)
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func mutatingRequestDeadlineTerminatesPublishesExitAndAllowsRestart() async throws {
        let fixture = try LifecycleAppServerFixture(turnStartDelayMilliseconds: 250)
        defer { fixture.remove() }
        let client = CodexAppServerClient(requestTimeout: .milliseconds(100))
        let events = await client.events()
        let exit = Task { () -> SubprocessTermination? in
            for await transportEvent in events {
                if case .exited(let termination) = transportEvent.event {
                    return termination
                }
            }
            return nil
        }
        try await client.start(configuration: fixture.configuration)
        let threadID = try await client.startThread(
            cwd: "/tmp/repository",
            model: "gpt-5.6-sol",
            developerInstructions: "Coordinate."
        )

        do {
            _ = try await client.startTurn(
                threadID: threadID,
                prompt: "hold",
                cwd: "/tmp/repository",
                model: "gpt-5.6-sol",
                effort: "high"
            )
            Issue.record("Expected the accepted turn/start request to time out")
        } catch let error as AppServerClientError {
            guard case .requestTimedOut(let method) = error else {
                Issue.record("Unexpected App Server error: \(error.localizedDescription)")
                return
            }
            #expect(method == "turn/start")
        }

        let termination = await exit.value
        #expect(termination?.reason == .uncaughtSignal)
        #expect(termination?.status == SIGTERM)
        #expect(!(await client.isRunning))

        try await client.start(configuration: fixture.configuration)
        #expect(await client.isRunning)
        await client.shutdown()
    }

    @Test
    func utilityCancellationRetriesInterruptBeforeDetachingTheThread() async throws {
        let fixture = try LifecycleAppServerFixture(interruptFailures: 1)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            maximumCleanupAttemptCount: 2,
            cleanupRetryDelay: .milliseconds(20)
        )
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        let utility = Task { try await provider.runUtility(Self.utilityRequest(prompt: "hold")) }
        try await Self.waitUntil { fixture.loggedMethods().contains("turn/start") }
        utility.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await utility.value
        }
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "turn/interrupt" }.count == 2
                && fixture.loggedMethods().filter { $0 == "thread/delete" }.count == 1
        }

        let debt = await provider.cleanupDebtSnapshot()
        #expect(debt.interruptedRuns.isEmpty)
        #expect(debt.deleteThreads.isEmpty)
        #expect(debt.unsubscribeThreads.isEmpty)
        await client.shutdown()
    }

    @Test
    func failedUtilityInterruptContainsGenerationAfterBoundedRetries() async throws {
        let fixture = try LifecycleAppServerFixture(interruptFailures: 100)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            maximumCleanupAttemptCount: 2,
            cleanupRetryDelay: .milliseconds(20)
        )
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        let utility = Task { try await provider.runUtility(Self.utilityRequest(prompt: "hold")) }
        try await Self.waitUntil { fixture.loggedMethods().contains("turn/start") }
        utility.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await utility.value
        }
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "turn/interrupt" }.count == 2
        }

        let debt = await provider.cleanupDebtSnapshot()
        #expect(debt.interruptedRuns.isEmpty)
        #expect(debt.protocolContainment == nil)
        #expect(!(await client.isRunning))
        #expect(fixture.loggedMethods().filter { $0 == "thread/delete" }.isEmpty)
        #expect(fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func freshUtilityCanRunAfterInterruptionExhaustionAndGenerationRestart() async throws {
        let fixture = try LifecycleAppServerFixture(
            interruptFailures: 1,
            unloadsOnUnsubscribe: true
        )
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            maximumCleanupAttemptCount: 1,
            cleanupRetryDelay: .milliseconds(1)
        )
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        let cancelledUtility = Task {
            try await provider.runUtility(Self.utilityRequest(prompt: "hold"))
        }
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "turn/start" }.count == 1
        }
        cancelledUtility.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledUtility.value
        }
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "turn/interrupt" }.count == 1
        }
        try await Self.waitUntilAsync {
            !(await client.isRunning)
        }
        #expect(await provider.cleanupDebtSnapshot().interruptedRuns.isEmpty)
        #expect(fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.isEmpty)

        try await client.start(configuration: fixture.configuration)
        let recovered = try await provider.runUtility(Self.utilityRequest(prompt: "complete"))

        let methods = fixture.loggedMethods()
        #expect(recovered.output == "utility complete")
        #expect(methods.filter { $0 == "turn/interrupt" }.count == 1)
        #expect(methods.filter { $0 == "thread/start" }.count == 2)
        // Admission after restart first reconciles the utility thread retained
        // across the generation boundary, then deletes the fresh utility.
        #expect(methods.filter { $0 == "thread/delete" }.count == 2)
        #expect(await provider.cleanupDebtSnapshot().interruptedRuns.isEmpty)
        #expect(try await client.loadedThreadIDs().isEmpty)

        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func manualInterruptFailureContainsGenerationWhenRetriesAreExhausted() async throws {
        let fixture = try LifecycleAppServerFixture(interruptFailures: 100)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            maximumCleanupAttemptCount: 1,
            cleanupRetryDelay: .milliseconds(1)
        )
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let runID = UUID()
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp/repository",
            prompt: "hold",
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            )
        ))
        let executionID = try #require(handle.executionID)
        var iterator = handle.events.makeAsyncIterator()
        #expect(await iterator.next() == .started(executionID: executionID))
        do {
            try await provider.interrupt(runID: runID)
            Issue.record("Expected the injected interrupt failure")
        } catch {
            #expect(error.localizedDescription.contains("injected interrupt failure"))
        }

        #expect(!(await client.isRunning))
        #expect(await provider.runEventSnapshot(runID: runID) == nil)
        #expect(await provider.cleanupDebtSnapshot().interruptedRuns.isEmpty)
        #expect(await provider.cleanupDebtSnapshot().protocolContainment == nil)
        #expect(fixture.loggedMethods().filter { $0 == "turn/interrupt" }.count == 1)
        #expect(fixture.loggedMethods().filter { $0 == "thread/start" }.count == 1)
        #expect(fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.isEmpty)
        guard case .failed(let detail) = await iterator.next() else {
            Issue.record("Expected generation-containment failure")
            return
        }
        #expect(detail.contains("after 1 attempt"))
        #expect(await iterator.next() == nil)
    }

    @Test
    func utilityDeleteFallbackRetriesUnsubscribeWithoutMaskingThePrimaryResult() async throws {
        let fixture = try LifecycleAppServerFixture(
            unsubscribeFailures: 1,
            deleteFailures: 100
        )
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            maximumCleanupAttemptCount: 2,
            cleanupRetryDelay: .milliseconds(20)
        )
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        let result = try await provider.runUtility(Self.utilityRequest(prompt: "complete"))
        #expect(result.output == "utility complete")
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.count >= 2
        }
        let debt = await provider.cleanupDebtSnapshot()
        #expect(debt.deleteThreads.count == 1)
        #expect(debt.unsubscribeThreads.isEmpty)
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedUtilitiesCleanBackgroundTerminalsBeforeDeletingTemporaryThreads() async throws {
        let utilityCount = 24
        let fixture = try LifecycleAppServerFixture(
            backgroundTerminalCount: 2,
            rejectsReleaseWithBackgroundTerminals: true
        )
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        for _ in 0..<utilityCount {
            let result = try await provider.runUtility(
                Self.utilityRequest(prompt: "complete")
            )
            #expect(result.output == "utility complete")
        }

        let methods = fixture.loggedMethods()
        let cleanIndices = methods.indices.filter {
            methods[$0] == "thread/backgroundTerminals/clean"
        }
        let listIndices = methods.indices.filter {
            methods[$0] == "thread/backgroundTerminals/list"
        }
        let deleteIndices = methods.indices.filter { methods[$0] == "thread/delete" }
        #expect(cleanIndices.count == utilityCount)
        #expect(listIndices.count == utilityCount)
        #expect(deleteIndices.count == utilityCount)
        for index in 0..<utilityCount {
            #expect(cleanIndices[index] < listIndices[index])
            #expect(listIndices[index] < deleteIndices[index])
        }
        #expect(try await client.loadedThreadIDs().isEmpty)
        #expect(await provider.cleanupDebtSnapshot().deleteThreads.isEmpty)
        #expect(await client.isRunning)
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func completedPhaseSessionRemainsPersistentUntilExplicitRelease() async throws {
        let fixture = try LifecycleAppServerFixture(backgroundTerminalCount: 2)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )
        let handle = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: "/tmp/repository",
            prompt: "complete",
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            )
        ))

        var terminal: AgentEvent?
        for await event in handle.events {
            if case .completed = event { terminal = event }
        }
        guard case .completed(let output, _, _) = terminal else {
            Issue.record("Expected the phase turn to complete")
            return
        }
        #expect(output == "utility complete")
        #expect(Set(try await client.loadedThreadIDs()) == Set([session.id]))
        var methods = fixture.loggedMethods()
        #expect(methods.filter { $0 == "thread/backgroundTerminals/clean" }.isEmpty)
        #expect(methods.filter { $0 == "thread/backgroundTerminals/list" }.isEmpty)
        #expect(methods.filter { $0 == "thread/delete" }.isEmpty)
        #expect(methods.filter { $0 == "thread/unsubscribe" }.isEmpty)

        #expect(await provider.releaseSession(id: session.id))
        methods = fixture.loggedMethods()
        #expect(methods.filter { $0 == "thread/backgroundTerminals/clean" }.count == 1)
        #expect(methods.filter { $0 == "thread/backgroundTerminals/list" }.count == 1)
        #expect(methods.filter { $0 == "thread/unsubscribe" }.count == 1)
        #expect(methods.filter { $0 == "thread/delete" }.isEmpty)
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func nonemptyBackgroundTerminalVerificationContainsTheWholeGeneration() async throws {
        let fixture = try LifecycleAppServerFixture(
            backgroundTerminalCount: 1,
            backgroundTerminalsSurviveClean: true,
            rejectsReleaseWithBackgroundTerminals: true
        )
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            backgroundTerminalCleanupTimeout: .milliseconds(50)
        )
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        let result = try await provider.runUtility(
            Self.utilityRequest(prompt: "complete")
        )
        #expect(result.output == "utility complete")
        try await Self.waitUntilAsync(timeout: .seconds(2)) {
            !(await client.isRunning)
        }

        let methods = fixture.loggedMethods()
        #expect(methods.filter { $0 == "thread/backgroundTerminals/clean" }.count == 1)
        #expect(methods.filter { $0 == "thread/backgroundTerminals/list" }.count >= 2)
        #expect(methods.filter { $0 == "thread/delete" }.isEmpty)
        #expect(methods.filter { $0 == "thread/unsubscribe" }.isEmpty)
        #expect(await provider.cleanupDebtSnapshot().protocolContainment == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func failedBackgroundTerminalCleanupContainsBeforeThreadRelease() async throws {
        let fixture = try LifecycleAppServerFixture(
            backgroundTerminalCleanFailures: 1
        )
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(appServer: client)
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        let result = try await provider.runUtility(
            Self.utilityRequest(prompt: "complete")
        )
        #expect(result.output == "utility complete")
        #expect(!(await client.isRunning))

        let methods = fixture.loggedMethods()
        #expect(methods.filter { $0 == "thread/backgroundTerminals/clean" }.count == 1)
        #expect(methods.filter { $0 == "thread/backgroundTerminals/list" }.isEmpty)
        #expect(methods.filter { $0 == "thread/delete" }.isEmpty)
        #expect(methods.filter { $0 == "thread/unsubscribe" }.isEmpty)
        #expect(await provider.cleanupDebtSnapshot().protocolContainment == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func oversizedUtilityEventCancelsBeforeItsTemporaryPersistedThreadIsDeleted() async throws {
        let fixture = try LifecycleAppServerFixture(
            utilityOutputByteCount: 4 * 1_024,
            unloadsOnUnsubscribe: true
        )
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            maximumCleanupAttemptCount: 1,
            maximumEventBufferRetainedBytes: 1_024
        )
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        do {
            _ = try await provider.runUtility(Self.utilityRequest(prompt: "complete"))
            Issue.record("Expected the oversized utility event to fail closed")
        } catch {
            #expect(error.localizedDescription.contains("event consumer stopped draining"))
        }

        let methods = fixture.loggedMethods()
        let interruptIndex = try #require(methods.firstIndex(of: "turn/interrupt"))
        let deleteIndex = try #require(methods.firstIndex(of: "thread/delete"))
        #expect(interruptIndex < deleteIndex)
        #expect(await provider.cleanupDebtSnapshot().interruptedRuns.isEmpty)
        #expect(try await client.loadedThreadIDs().isEmpty)
        await client.shutdown()
    }

    @Test
    func releaseSessionReportsFalseUntilUnsubscribeIsConfirmed() async throws {
        let fixture = try LifecycleAppServerFixture(unsubscribeFailures: 1)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            maximumCleanupAttemptCount: 1
        )
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)
        let session = try await provider.prepareSession(
            Self.sessionRequest(existingSessionID: nil)
        )

        #expect(await provider.releaseSession(id: session.id) == false)
        #expect(await provider.cleanupDebtSnapshot().unsubscribeThreads.count == 1)
        #expect(await provider.releaseSession(id: session.id))
        #expect(await provider.cleanupDebtSnapshot().unsubscribeThreads.isEmpty)
        #expect(fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.count == 2)
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func exhaustedOverloadDebtIsRetriedAtTheNextAdmissionAndRecovers() async throws {
        let fixture = try LifecycleAppServerFixture(
            unsubscribeFailures: 8,
            deleteFailures: 8,
            unloadsOnUnsubscribe: true
        )
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            maximumRetainedUtilityThreadCount: 1,
            cleanupRetryDelay: .milliseconds(1)
        )
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        _ = try await provider.runUtility(Self.utilityRequest(prompt: "complete"))
        try await Self.waitUntil {
            fixture.loggedMethods().filter { $0 == "thread/delete" }.count >= 8
                && fixture.loggedMethods().filter { $0 == "thread/unsubscribe" }.count >= 8
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await provider.cleanupDebtSnapshot().deleteThreads.count == 1)

        let recovered = try await provider.runUtility(Self.utilityRequest(prompt: "complete"))
        #expect(recovered.output == "utility complete")
        #expect(fixture.loggedMethods().filter { $0 == "thread/delete" }.count >= 10)
        #expect(fixture.loggedMethods().filter { $0 == "thread/start" }.count == 2)
        #expect(await provider.cleanupDebtSnapshot().deleteThreads.isEmpty)
        #expect(await provider.cleanupDebtSnapshot().unsubscribeThreads.isEmpty)
        #expect(try await client.loadedThreadIDs().isEmpty)
        await client.shutdown()
    }

    @Test
    func threadClosedNotificationClearsUnsubscribeDebtButPreservesDeleteDebt() async throws {
        let fixture = try LifecycleAppServerFixture(
            unsubscribeFailures: 100,
            deleteFailures: 100
        )
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        let provider = CodexAgentProvider(
            appServer: client,
            maximumCleanupAttemptCount: 1
        )
        let consumer = await Self.consume(client: client, provider: provider)
        defer { consumer.cancel() }
        try await client.start(configuration: fixture.configuration)

        _ = try await provider.runUtility(Self.utilityRequest(prompt: "complete"))
        #expect(await provider.cleanupDebtSnapshot().deleteThreads.count == 1)
        #expect(await provider.cleanupDebtSnapshot().unsubscribeThreads.count == 1)
        await provider.receive(.notification(
            method: "thread/closed",
            params: .object(["threadId": .string("utility-1")]),
            rawLine: "closed"
        ))
        #expect(await provider.cleanupDebtSnapshot().deleteThreads.count == 1)
        #expect(await provider.cleanupDebtSnapshot().unsubscribeThreads.isEmpty)
        await client.shutdown()
    }

    private static func sessionRequest(existingSessionID: String?) -> AgentSessionRequest {
        AgentSessionRequest(
            existingSessionID: existingSessionID,
            name: "Reliability phase",
            cwd: "/tmp/repository",
            target: AgentTarget(providerID: .codex, model: "gpt-5.6-sol"),
            developerInstructions: "Continue this phase."
        )
    }

    private static func startedEvent(
        sessionID: String,
        executionID: String
    ) -> AppServerEvent {
        .notification(
            method: "turn/started",
            params: .object([
                "threadId": .string(sessionID),
                "turn": .object([
                    "id": .string(executionID),
                    "items": .array([]),
                    "status": .string("inProgress")
                ])
            ]),
            rawLine: "started"
        )
    }

    private static func utilityRequest(prompt: String) -> AgentUtilityRequest {
        AgentUtilityRequest(
            cwd: "/tmp/repository",
            prompt: prompt,
            target: AgentTarget(
                providerID: .codex,
                model: "gpt-5.6-sol",
                options: AgentExecutionOptions(effort: "high")
            ),
            developerInstructions: "Coordinate.",
            outputSchema: .object(["type": .string("object")])
        )
    }

    private static func concurrentPreparationOutcomes(
        provider: CodexAgentProvider,
        request: AgentSessionRequest,
        count: Int
    ) async -> [String] {
        await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<count {
                group.addTask {
                    do {
                        let session = try await provider.prepareSession(request)
                        return "success:\(session.id)"
                    } catch {
                        return "failure:\(error.localizedDescription)"
                    }
                }
            }
            var outcomes: [String] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    private static func consume(
        client: CodexAppServerClient,
        provider: CodexAgentProvider
    ) async -> Task<Void, Never> {
        let stream = await client.events()
        return Task {
            for await transportEvent in stream {
                await provider.receive(transportEvent.event)
            }
        }
    }

    private static func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    private static func waitUntilAsync(
        timeout: Duration = .seconds(10),
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }
}

private actor ProviderReceiveProbe {
    private(set) var completed = false

    func markCompleted() {
        completed = true
    }
}

private actor RequestRegistrationGate {
    private let blockedMethod: String
    private let blockedOccurrence: Int
    private var matchingCallCount = 0
    private var reached = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(blockedMethod: String, blockedOccurrence: Int = 1) {
        self.blockedMethod = blockedMethod
        self.blockedOccurrence = blockedOccurrence
    }

    func blockIfNeeded(method: String) async {
        guard method == blockedMethod else { return }
        matchingCallCount += 1
        guard matchingCallCount == blockedOccurrence else { return }
        reached = true
        let waiters = reachedWaiters
        reachedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { continuation in
            reachedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class ProviderProtocolOutputReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func blockIfArmed() {
        lock.lock()
        guard armed else {
            lock.unlock()
            return
        }
        armed = false
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        let shouldBlock = !released
        lock.unlock()
        waiters.forEach { $0.resume() }
        if shouldBlock {
            releaseSemaphore.wait()
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if entered {
                lock.unlock()
                continuation.resume()
            } else {
                enteredWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        releaseSemaphore.signal()
    }
}

private actor StandardErrorRecorder {
    private var recorded: [String] = []

    func append(_ value: String) {
        recorded.append(value)
    }

    func values() -> [String] {
        recorded
    }
}

private enum SaveFailurePoint: Sendable {
    case initialActivity
    case queuedRun
    case runningRun
    case terminalRouting
    case repositorySettings(model: String)
    case archiveActivity
}

private struct InjectedStoreError: LocalizedError {
    var errorDescription: String? { "Injected workspace save failure" }
}

private actor SelectiveFailingStore: RepositoryWorkspaceStoring {
    private let base: WorkspaceStore
    private let failurePoint: SaveFailurePoint
    private var hasFailed = false

    init(base: WorkspaceStore, failurePoint: SaveFailurePoint) {
        self.base = base
        self.failurePoint = failurePoint
    }

    func load(canonicalPath: String, defaultSettings: RepositorySettings) async throws -> RepositoryRecord {
        try await base.load(canonicalPath: canonicalPath, defaultSettings: defaultSettings)
    }

    func save(_ record: RepositoryRecord) async throws {
        if !hasFailed {
            let status = record.activity?.runs.last?.status
            let shouldFail = switch failurePoint {
            case .initialActivity:
                record.activity?.status == .running && record.activity?.runs.isEmpty == true
            case .queuedRun:
                status == .queued
            case .runningRun:
                status == .running
            case .terminalRouting:
                status == .routing && record.activity?.runs.last?.finalOutput?.isEmpty == false
            case .repositorySettings(let model):
                record.settings.implementer.model == model
            case .archiveActivity:
                false
            }
            if shouldFail {
                hasFailed = true
                throw InjectedStoreError()
            }
        }
        try await base.save(record)
    }

    func archiveActivity(_ record: RepositoryRecord) async throws {
        if !hasFailed, case .archiveActivity = failurePoint {
            hasFailed = true
            throw InjectedStoreError()
        }
        try await base.archiveActivity(record)
    }

    func loadViewState(canonicalPath: String) async throws -> RepositoryViewState {
        try await base.loadViewState(canonicalPath: canonicalPath)
    }

    func saveViewState(_ state: RepositoryViewState, canonicalPath: String) async throws {
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

private actor CallCountingRouter: HandoffRouting {
    private(set) var callCount = 0

    func route(_ context: HandoffContext, settings: RelaySettings) async throws -> HandoffEnvelope {
        _ = settings
        callCount += 1
        return HandoffEnvelope(
            handoffText: context.source,
            sourceDisposition: .implementationCheckpoint,
            runLabel: "Unexpected route"
        )
    }
}

private actor SequencedTestRouter: HandoffRouting {
    private var labelIndex = 0

    func route(_ context: HandoffContext, settings: RelaySettings) async throws -> HandoffEnvelope {
        let disposition: SourceDisposition
        switch context.runKind {
        case .implementation:
            disposition = context.source.contains("IMPLEMENTATION COMPLETE")
                ? .implementationComplete
                : .implementationCheckpoint
        case .review:
            disposition = .reviewComplete
        case .fix:
            disposition = labelIndex < 5 ? .fixCheckpoint : .fixComplete
        }
        let labels = [
            "Parser foundation",
            "Boundary review",
            "Boundary correction",
            "Parser completion",
            "Completion review",
            "Final verification"
        ]
        let label = labels[labelIndex]
        labelIndex += 1
        return HandoffEnvelope(
            handoffText: context.source,
            sourceDisposition: disposition,
            runLabel: label
        )
    }
}

private struct AcceptingHandoffConfigurationValidator: HandoffConfigurationValidating {
    func validateLocal(_ settings: RelaySettings) async throws {
        _ = settings
    }

    func testRemote(_ settings: RelaySettings) async throws {
        _ = settings
    }
}

private struct LifecycleAppServerFixture: Sendable {
    let scriptURL: URL
    let logURL: URL
    let unsubscribeFailures: Int
    let deleteFailures: Int
    let unsubscribeDelayMilliseconds: Int
    let interruptFailures: Int
    let interruptEmitsTerminal: Bool
    let rejectsLoadedList: Bool
    let loadedListDelayMilliseconds: Int
    let threadStartDelayMilliseconds: Int
    let resumeDelayMilliseconds: Int
    let turnStartDelayMilliseconds: Int
    let utilityOutputByteCount: Int
    let unloadsOnUnsubscribe: Bool
    let backgroundTerminalCount: Int
    let backgroundTerminalCleanFailures: Int
    let backgroundTerminalsSurviveClean: Bool
    let rejectsReleaseWithBackgroundTerminals: Bool

    var configuration: CodexLaunchConfiguration {
        var arguments = [
            scriptURL.path,
            logURL.path,
            "--unsubscribe-failures=\(unsubscribeFailures)",
            "--delete-failures=\(deleteFailures)",
            "--unsubscribe-delay-ms=\(unsubscribeDelayMilliseconds)",
            "--interrupt-failures=\(interruptFailures)",
            "--loaded-list-delay-ms=\(loadedListDelayMilliseconds)",
            "--thread-start-delay-ms=\(threadStartDelayMilliseconds)",
            "--resume-delay-ms=\(resumeDelayMilliseconds)",
            "--turn-start-delay-ms=\(turnStartDelayMilliseconds)",
            "--utility-output-bytes=\(utilityOutputByteCount)",
            "--background-terminal-count=\(backgroundTerminalCount)",
            "--background-clean-failures=\(backgroundTerminalCleanFailures)"
        ]
        if rejectsLoadedList { arguments.append("--reject-loaded-list") }
        if unloadsOnUnsubscribe { arguments.append("--unload-on-unsubscribe") }
        if !interruptEmitsTerminal { arguments.append("--interrupt-without-terminal") }
        if backgroundTerminalsSurviveClean {
            arguments.append("--background-terminals-survive-clean")
        }
        if rejectsReleaseWithBackgroundTerminals {
            arguments.append("--reject-release-with-background-terminals")
        }
        return CodexLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: arguments
        )
    }

    init(
        rejectsUnsubscribe: Bool = false,
        unsubscribeFailures: Int = 0,
        deleteFailures: Int = 0,
        unsubscribeDelayMilliseconds: Int = 0,
        interruptFailures: Int = 0,
        interruptEmitsTerminal: Bool = true,
        rejectsLoadedList: Bool = false,
        loadedListDelayMilliseconds: Int = 0,
        threadStartDelayMilliseconds: Int = 0,
        resumeDelayMilliseconds: Int = 0,
        turnStartDelayMilliseconds: Int = 0,
        utilityOutputByteCount: Int = 0,
        unloadsOnUnsubscribe: Bool = false,
        backgroundTerminalCount: Int = 0,
        backgroundTerminalCleanFailures: Int = 0,
        backgroundTerminalsSurviveClean: Bool = false,
        rejectsReleaseWithBackgroundTerminals: Bool = false
    ) throws {
        let identifier = UUID().uuidString
        scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-lifecycle-\(identifier).py")
        logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-lifecycle-\(identifier).log")
        self.unsubscribeFailures = rejectsUnsubscribe ? 1_000_000 : unsubscribeFailures
        self.deleteFailures = deleteFailures
        self.unsubscribeDelayMilliseconds = unsubscribeDelayMilliseconds
        self.interruptFailures = interruptFailures
        self.interruptEmitsTerminal = interruptEmitsTerminal
        self.rejectsLoadedList = rejectsLoadedList
        self.loadedListDelayMilliseconds = loadedListDelayMilliseconds
        self.threadStartDelayMilliseconds = threadStartDelayMilliseconds
        self.resumeDelayMilliseconds = resumeDelayMilliseconds
        self.turnStartDelayMilliseconds = turnStartDelayMilliseconds
        self.utilityOutputByteCount = utilityOutputByteCount
        self.unloadsOnUnsubscribe = unloadsOnUnsubscribe
        self.backgroundTerminalCount = backgroundTerminalCount
        self.backgroundTerminalCleanFailures = backgroundTerminalCleanFailures
        self.backgroundTerminalsSurviveClean = backgroundTerminalsSurviveClean
        self.rejectsReleaseWithBackgroundTerminals = rejectsReleaseWithBackgroundTerminals
        try Data(Self.script.utf8).write(to: scriptURL, options: .atomic)
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }

    func loggedMethods() -> [String] {
        guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return contents.split(whereSeparator: \.isNewline).map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: logURL)
    }

    private static let script = #"""
import json
import sys
import time

log_path = sys.argv[1]
arguments = sys.argv[2:]
def option(prefix, default=0):
    for argument in arguments:
        if argument.startswith(prefix):
            return int(argument.split("=", 1)[1])
    return default

unsubscribe_failures = option("--unsubscribe-failures=")
delete_failures = option("--delete-failures=")
unsubscribe_delay_ms = option("--unsubscribe-delay-ms=")
interrupt_failures = option("--interrupt-failures=")
interrupt_emits_terminal = "--interrupt-without-terminal" not in arguments
loaded_list_delay_ms = option("--loaded-list-delay-ms=")
thread_start_delay_ms = option("--thread-start-delay-ms=")
resume_delay_ms = option("--resume-delay-ms=")
turn_start_delay_ms = option("--turn-start-delay-ms=")
utility_output_bytes = option("--utility-output-bytes=")
background_terminal_count = option("--background-terminal-count=")
background_clean_failures = option("--background-clean-failures=")
reject_loaded_list = "--reject-loaded-list" in arguments
unload_on_unsubscribe = "--unload-on-unsubscribe" in arguments
background_terminals_survive_clean = "--background-terminals-survive-clean" in arguments
reject_release_with_background_terminals = "--reject-release-with-background-terminals" in arguments
loaded = set()
background_terminals = {}
thread_count = 0
turn_count = 0
unsubscribe_count = 0
delete_count = 0
interrupt_count = 0
background_clean_count = 0

def log(method):
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(method + "\n")
        handle.flush()

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

def seed_background_terminals(thread_id, turn_id):
    background_terminals[thread_id] = [
        {
            "processId": "process-" + turn_id + "-" + str(index),
            "itemId": "terminal-" + turn_id + "-" + str(index),
            "command": "sleep 3600",
            "cwd": "/tmp/repository"
        }
        for index in range(background_terminal_count)
    ]

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method not in ("initialize", "initialized"):
        log(method or "response")
    if method == "initialize":
        emit({"id": identifier, "result": {"userAgent": "lifecycle-fixture"}})
    elif method == "thread/loaded/list":
        if loaded_list_delay_ms > 0:
            time.sleep(loaded_list_delay_ms / 1000.0)
            loaded_list_delay_ms = 0
        if reject_loaded_list:
            emit({"id": identifier, "error": {"code": -32000, "message": "injected loaded-list failure"}})
        else:
            emit({"id": identifier, "result": {"data": sorted(loaded)}})
    elif method == "thread/start":
        thread_count += 1
        thread_id = "utility-" + str(thread_count)
        loaded.add(thread_id)
        if thread_start_delay_ms > 0:
            time.sleep(thread_start_delay_ms / 1000.0)
        emit({"id": identifier, "result": {"thread": {"id": thread_id}}})
    elif method == "thread/resume":
        thread_id = message["params"]["threadId"]
        loaded.add(thread_id)
        if resume_delay_ms > 0:
            time.sleep(resume_delay_ms / 1000.0)
        emit({"id": identifier, "result": {"thread": {"id": thread_id}}})
    elif method == "thread/backgroundTerminals/clean":
        background_clean_count += 1
        thread_id = message["params"]["threadId"]
        if background_clean_count <= background_clean_failures:
            emit({"id": identifier, "error": {"code": -32000, "message": "injected background-terminal cleanup failure"}})
        else:
            if not background_terminals_survive_clean:
                background_terminals[thread_id] = []
            emit({"id": identifier, "result": {}})
    elif method == "thread/backgroundTerminals/list":
        thread_id = message["params"]["threadId"]
        emit({"id": identifier, "result": {"data": background_terminals.get(thread_id, []), "nextCursor": None}})
    elif method == "thread/name/set":
        emit({"id": identifier, "result": {}})
    elif method == "turn/start":
        turn_count += 1
        thread_id = message["params"]["threadId"]
        turn_id = "turn-" + str(turn_count)
        prompt = message["params"]["input"][0]["text"]
        should_fail = prompt == "fail"
        if turn_start_delay_ms > 0:
            time.sleep(turn_start_delay_ms / 1000.0)
        emit({"id": identifier, "result": {"turn": {"id": turn_id, "items": [], "status": "inProgress"}}})
        emit({"method": "turn/started", "params": {"threadId": thread_id, "turn": {"id": turn_id, "items": [], "status": "inProgress"}}})
        if prompt == "hold":
            continue
        elif should_fail:
            seed_background_terminals(thread_id, turn_id)
            emit({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "items": [], "status": "failed", "error": {"message": "injected turn failure"}}}})
        else:
            text = "x" * utility_output_bytes if utility_output_bytes > 0 else "utility complete"
            item = {"id": "item-" + str(turn_count), "type": "agentMessage", "phase": "final_answer", "text": text}
            emit({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": item}})
            seed_background_terminals(thread_id, turn_id)
            emit({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "items": [item], "status": "completed"}}})
    elif method == "thread/unsubscribe":
        unsubscribe_count += 1
        if unsubscribe_delay_ms > 0:
            time.sleep(unsubscribe_delay_ms / 1000.0)
        thread_id = message["params"]["threadId"]
        if reject_release_with_background_terminals and background_terminals.get(thread_id):
            emit({"id": identifier, "error": {"code": -32000, "message": "background terminals still running"}})
        elif unsubscribe_count <= unsubscribe_failures:
            emit({"id": identifier, "error": {"code": -32000, "message": "injected unsubscribe failure"}})
        else:
            if unload_on_unsubscribe:
                loaded.discard(thread_id)
            emit({"id": identifier, "result": {"status": "unsubscribed"}})
    elif method == "thread/delete":
        delete_count += 1
        thread_id = message["params"]["threadId"]
        if reject_release_with_background_terminals and background_terminals.get(thread_id):
            emit({"id": identifier, "error": {"code": -32000, "message": "background terminals still running"}})
        elif delete_count <= delete_failures:
            emit({"id": identifier, "error": {"code": -32000, "message": "injected delete failure"}})
        else:
            loaded.discard(thread_id)
            background_terminals.pop(thread_id, None)
            emit({"id": identifier, "result": {}})
    elif method == "turn/interrupt":
        interrupt_count += 1
        if interrupt_count <= interrupt_failures:
            emit({"id": identifier, "error": {"code": -32000, "message": "injected interrupt failure"}})
        else:
            emit({"id": identifier, "result": {}})
            if interrupt_emits_terminal:
                thread_id = message["params"]["threadId"]
                turn_id = message["params"]["turnId"]
                seed_background_terminals(thread_id, turn_id)
                emit({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "items": [], "status": "interrupted"}}})
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#
}

private struct FakeAppServerFixture: Sendable {
    let scriptURL: URL
    let rejectsResumes: Bool

    var configuration: CodexLaunchConfiguration {
        CodexLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [scriptURL.path] + (rejectsResumes ? ["--reject-resume"] : [])
        )
    }

    init(rejectsResumes: Bool = false) throws {
        scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-fake-app-server-\(UUID().uuidString).py")
        self.rejectsResumes = rejectsResumes
        try Data(Self.script.utf8).write(to: scriptURL, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: scriptURL)
    }

    private static let script = #"""
import json
import sys

reject_resumes = "--reject-resume" in sys.argv[1:]
thread_count = 0
turn_count = 0
loaded = set()
outputs = [
    "IMPLEMENTATION CHECKPOINT. Changed Parser.swift and tests pass.",
    "Review complete. Fix the boundary check in Parser.swift:42.",
    "FIXES COMPLETE. Corrected Parser.swift:42 and tests pass.",
    "IMPLEMENTATION COMPLETE. Added the remaining parser behavior.",
    "Review complete. No material findings.",
    "FIXES COMPLETE. Verified the final repository state."
]

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit({"id": identifier, "result": {"codexHome": "/tmp", "platformFamily": "unix", "platformOs": "macos", "userAgent": "fake"}})
    elif method == "model/list":
        emit({"id": identifier, "result": {"data": [{"id": "gpt-5.6-sol", "model": "gpt-5.6-sol", "displayName": "GPT-5.6 Sol", "description": "Fixture", "defaultReasoningEffort": "high", "supportedReasoningEfforts": [{"reasoningEffort": "high", "description": "High"}, {"reasoningEffort": "max", "description": "Max"}], "hidden": False, "isDefault": True}], "nextCursor": None}})
    elif method == "thread/loaded/list":
        emit({"id": identifier, "result": {"data": sorted(loaded)}})
    elif method == "thread/start":
        thread_count += 1
        thread_id = "thread-" + str(thread_count)
        loaded.add(thread_id)
        emit({"id": identifier, "result": {"thread": {"id": thread_id}}})
    elif method == "thread/resume":
        if reject_resumes:
            emit({"id": identifier, "error": {"code": -32600, "message": "no rollout found for thread id " + message["params"]["threadId"]}})
        else:
            loaded.add(message["params"]["threadId"])
            emit({"id": identifier, "result": {"thread": {"id": message["params"]["threadId"]}}})
    elif method == "thread/name/set":
        emit({"id": identifier, "result": {}})
    elif method == "turn/start":
        turn_count += 1
        turn_id = "turn-" + str(turn_count)
        item_id = "item-" + str(turn_count)
        thread_id = message["params"]["threadId"]
        text = outputs[turn_count - 1]
        item = {"id": item_id, "type": "agentMessage", "phase": "final_answer", "text": text}
        emit({"id": identifier, "result": {"turn": {"id": turn_id, "items": [], "status": "inProgress"}}})
        emit({"method": "turn/started", "params": {"threadId": thread_id, "turn": {"id": turn_id, "items": [], "status": "inProgress"}}})
        emit({"method": "item/started", "params": {"threadId": thread_id, "turnId": turn_id, "startedAtMs": 1, "item": item}})
        emit({"method": "item/agentMessage/delta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": item_id, "delta": text}})
        emit({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "completedAtMs": 2, "item": item}})
        emit({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "items": [item], "status": "completed", "durationMs": 10}}})
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#
}

private struct MCPApprovalAppServerFixture: Sendable {
    let scriptURL: URL

    var configuration: CodexLaunchConfiguration {
        CodexLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [scriptURL.path]
        )
    }

    init() throws {
        scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-mcp-approval-\(UUID().uuidString).py")
        try Data(Self.script.utf8).write(to: scriptURL, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: scriptURL)
    }

    private static let script = #"""
import json
import sys

thread_id = "thread-mcp"
turn_id = "turn-mcp"

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        assert message["params"]["capabilities"]["mcpServerOpenaiFormElicitation"] is True
        emit({"id": identifier, "result": {"userAgent": "mcp-approval-fixture"}})
    elif method == "thread/loaded/list":
        emit({"id": identifier, "result": {"data": []}})
    elif method == "thread/start":
        assert message["params"]["approvalPolicy"] == "never"
        emit({"id": identifier, "result": {"thread": {"id": thread_id}}})
    elif method == "thread/name/set":
        emit({"id": identifier, "result": {}})
    elif method == "turn/start":
        assert message["params"]["approvalPolicy"] == "never"
        emit({"id": identifier, "result": {"turn": {"id": turn_id, "items": [], "status": "inProgress"}}})
        emit({"method": "turn/started", "params": {"threadId": thread_id, "turn": {"id": turn_id, "items": [], "status": "inProgress"}}})
        emit({
            "id": "approval-1",
            "method": "mcpServer/elicitation/request",
            "params": {
                "_meta": {
                    "codex_approval_kind": "mcp_tool_call",
                    "persist": ["session", "always"]
                },
                "message": 'Allow the decompiler MCP server to run tool "status"?',
                "mode": "form",
                "requestedSchema": {"properties": {}, "type": "object"},
                "serverName": "decompiler",
                "threadId": thread_id,
                "turnId": turn_id
            }
        })
    elif identifier == "approval-1":
        assert message["result"] == {"action": "accept", "content": {}}
        text = "Decompiler status inspected."
        item = {"id": "item-mcp", "type": "agentMessage", "phase": "final_answer", "text": text}
        emit({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": item}})
        emit({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "items": [item], "status": "completed"}}})
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#
}

private struct PausingAppServerFixture: Sendable {
    let scriptURL: URL

    var configuration: CodexLaunchConfiguration {
        CodexLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [scriptURL.path]
        )
    }

    init() throws {
        scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-pausing-app-server-" + UUID().uuidString + ".py")
        try Data(Self.script.utf8).write(to: scriptURL, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: scriptURL)
    }

    private static let script = #"""
import json
import sys

thread_count = 0
active_thread = None
active_turn = None

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

def complete(status, text=None):
    global active_thread, active_turn
    items = []
    if text is not None:
        item = {"id": "final-item", "type": "agentMessage", "phase": "final_answer", "text": text}
        items = [item]
        emit({"method": "item/completed", "params": {"threadId": active_thread, "turnId": active_turn, "completedAtMs": 2, "item": item}})
    emit({"method": "turn/completed", "params": {"threadId": active_thread, "turn": {"id": active_turn, "items": items, "status": status, "durationMs": 10}}})
    active_thread = None
    active_turn = None

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit({"id": identifier, "result": {"codexHome": "/tmp", "platformFamily": "unix", "platformOs": "macos", "userAgent": "fake"}})
    elif method == "thread/start":
        thread_count += 1
        emit({"id": identifier, "result": {"thread": {"id": "thread-" + str(thread_count)}}})
    elif method == "thread/resume":
        emit({"id": identifier, "result": {"thread": {"id": message["params"]["threadId"]}}})
    elif method == "thread/name/set":
        emit({"id": identifier, "result": {}})
    elif method == "turn/start":
        active_thread = message["params"]["threadId"]
        active_turn = "turn-1"
        emit({"id": identifier, "result": {"turn": {"id": active_turn, "items": [], "status": "inProgress"}}})
        emit({"method": "turn/started", "params": {"threadId": active_thread, "turn": {"id": active_turn, "items": [], "status": "inProgress"}}})
    elif method == "turn/steer":
        emit({"id": identifier, "result": {}})
        complete("completed", "Paused at a coherent checkpoint.")
    elif method == "turn/interrupt":
        emit({"id": identifier, "result": {}})
        complete("interrupted")
    elif method == "thread/unsubscribe":
        emit({"id": identifier, "result": {"status": "unsubscribed"}})
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#
}
