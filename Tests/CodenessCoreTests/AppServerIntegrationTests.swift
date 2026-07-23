import Foundation
import Testing
@testable import CodenessCore

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
            store: store
        )
        let stream = await client.events()
        let consumer = Task {
            for await event in stream {
                await coordinator.handle(event)
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
            store: WorkspaceStore(rootURL: root)
        )
        let stream = await client.events()
        let consumer = Task {
            for await event in stream {
                await coordinator.handle(event)
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
            store: WorkspaceStore(rootURL: root)
        )
        let stream = await client.events()
        let consumer = Task {
            for await event in stream {
                await coordinator.handle(event)
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
            store: store
        )
        let stream = await client.events()
        let consumer = Task {
            for await event in stream {
                await coordinator.handle(event)
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
            store: store
        )
        let stream = await client.events()
        let consumer = Task {
            for await event in stream {
                await coordinator.handle(event)
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
            store: store
        )
        let stream = await client.events()
        let consumer = Task {
            for await event in stream {
                await coordinator.handle(event)
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
            disposition = .fixComplete
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

private struct FakeAppServerFixture: Sendable {
    let scriptURL: URL

    var configuration: CodexLaunchConfiguration {
        CodexLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [scriptURL.path]
        )
    }

    init() throws {
        scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-fake-app-server-\(UUID().uuidString).py")
        try Data(Self.script.utf8).write(to: scriptURL, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: scriptURL)
    }

    private static let script = #"""
import json
import sys

thread_count = 0
turn_count = 0
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
    elif method == "thread/start":
        thread_count += 1
        emit({"id": identifier, "result": {"thread": {"id": "thread-" + str(thread_count)}}})
    elif method == "thread/resume":
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
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#
}
