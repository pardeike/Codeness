import Foundation
import Testing
@testable import Codeness
@testable import CodenessCore

@Suite(.serialized)
@MainActor
struct ProviderRestartFenceTests {
    @Test(.timeLimit(.minutes(1)))
    nonisolated func bootstrapScopesEventRoutingPauseAcrossSuccessfulStartup() async throws {
        let fixture = try HeldVersionCodexFixture()
        defer {
            fixture.releaseVersionProbe()
            fixture.remove()
        }
        let previousCodexPath = UserDefaults.standard.string(forKey: "CodexExecutablePath")
        let previousClaudePath = UserDefaults.standard.string(forKey: "ClaudeExecutablePath")
        defer {
            Self.restoreDefault(previousCodexPath, forKey: "CodexExecutablePath")
            Self.restoreDefault(previousClaudePath, forKey: "ClaudeExecutablePath")
        }
        UserDefaults.standard.set(fixture.executableURL.path, forKey: "CodexExecutablePath")
        UserDefaults.standard.set(
            "/tmp/codeness-missing-claude-\(UUID().uuidString)",
            forKey: "ClaudeExecutablePath"
        )
        let appServer = CodexAppServerClient()
        let application = await MainActor.run {
            CodenessApplicationModel(appServer: appServer)
        }

        async let bootstrap: Void = application.bootstrap()
        await Task.yield()
        do {
            try await fixture.waitForVersionProbe()
        } catch {
            fixture.releaseVersionProbe()
            await bootstrap
            let detail = await application.applicationError ?? "no application error"
            Issue.record("Held bootstrap probe was not reached: \(detail)")
            _ = await application.shutdown(prepareDocuments: false)
            _ = await OwnedSubprocessSupervisor.resumeLaunching()
            return
        }
        #expect(await appServer.testingEventRoutingIsPaused())
        fixture.releaseVersionProbe()
        await bootstrap

        #expect(!(await appServer.testingEventRoutingIsPaused()))
        if case .ready = await application.serverState {
            // Startup completed while the scoped pause protected protocol parsing.
        } else {
            Issue.record("Codex App Server should be ready after fixture bootstrap.")
        }
        #expect(await application.shutdown(prepareDocuments: false))
        #expect(await OwnedSubprocessSupervisor.resumeLaunching())
    }

    @Test(.timeLimit(.minutes(1)))
    func bootstrapReleasesEventRoutingPauseAfterStartupFailure() async throws {
        let fixture = try RestartVersionFixture()
        defer { fixture.remove() }
        let previousCodexPath = UserDefaults.standard.string(forKey: "CodexExecutablePath")
        let previousClaudePath = UserDefaults.standard.string(forKey: "ClaudeExecutablePath")
        defer {
            Self.restoreDefault(previousCodexPath, forKey: "CodexExecutablePath")
            Self.restoreDefault(previousClaudePath, forKey: "ClaudeExecutablePath")
        }
        UserDefaults.standard.set(fixture.executableURL.path, forKey: "CodexExecutablePath")
        UserDefaults.standard.set(
            "/tmp/codeness-missing-claude-\(UUID().uuidString)",
            forKey: "ClaudeExecutablePath"
        )
        let appServer = CodexAppServerClient()
        let application = CodenessApplicationModel(appServer: appServer)

        await application.bootstrap()

        #expect(!(await appServer.testingEventRoutingIsPaused()))
        if case .failed = application.serverState {
            // The fixture exits instead of serving App Server protocol.
        } else {
            Issue.record("Codex App Server startup should fail for the exit fixture.")
        }
        #expect(await application.shutdown(prepareDocuments: false))
        #expect(await OwnedSubprocessSupervisor.resumeLaunching())
    }

    @Test(.timeLimit(.minutes(1)))
    nonisolated func heldVersionProbeRejectsCoordinatorLaunchAndCoalescesRepeatedRetry() async throws {
        let fixture = try HeldVersionCodexFixture()
        defer {
            fixture.releaseVersionProbe()
            fixture.remove()
        }
        let previousPath = UserDefaults.standard.string(forKey: "CodexExecutablePath")
        defer {
            if let previousPath {
                UserDefaults.standard.set(previousPath, forKey: "CodexExecutablePath")
            } else {
                UserDefaults.standard.removeObject(forKey: "CodexExecutablePath")
            }
        }
        let storeRoot = fixture.directoryURL.appendingPathComponent("store")
        let repositoryURL = fixture.directoryURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(
            at: repositoryURL,
            withIntermediateDirectories: true
        )
        let appServer = CodexAppServerClient()
        let application = await MainActor.run {
            CodenessApplicationModel(
                appServer: appServer,
                store: WorkspaceStore(rootURL: storeRoot)
            )
        }
        async let firstRetry = application.restartServer(
            configuredPath: fixture.executableURL.path
        )
        await Task.yield()
        do {
            try await fixture.waitForVersionProbe()
        } catch {
            fixture.releaseVersionProbe()
            let result = await firstRetry
            let detail = await application.applicationError ?? "no application error"
            Issue.record("Held restart probe was not reached (result \(result)): \(detail)")
            _ = await application.shutdown(prepareDocuments: false)
            _ = await OwnedSubprocessSupervisor.resumeLaunching()
            return
        }

        let coordinator = await application.coordinator(for: repositoryURL.path)
        await coordinator.load()
        await coordinator.startActivity(
            goal: "Prove restart admission",
            workflow: await Self.singleStepCodexWorkflow
        )
        let coordinatorStatus = await coordinator.activeRun?.status
        let recordedStatus = await coordinator.record.activity?.runs.last?.status
        let coordinatorError = await coordinator.errorMessage
        // A rejected terminal run is retained in the activity record but is no
        // longer exposed as active work.
        #expect(coordinatorStatus == nil)
        #expect(recordedStatus == .failed)
        #expect(coordinatorError?.contains("Codex is restarting") == true)
        #expect(try fixture.invocations() == ["version"])

        async let secondRetry = application.restartServer(
            configuredPath: fixture.executableURL.path
        )
        fixture.releaseVersionProbe()

        #expect(await firstRetry)
        #expect(await secondRetry)
        try await fixture.waitForInvocationCount(2)
        #expect(try fixture.invocations() == ["version", "server"])
        #expect(!(await appServer.testingEventRoutingIsPaused()))
        #expect(await application.shutdown(prepareDocuments: false))
        #expect(await OwnedSubprocessSupervisor.resumeLaunching())
    }

    @Test(.timeLimit(.minutes(1)))
    func unverifiedCodexCleanupRetainsDirectRegistryAdmissionFence() async throws {
        let fixture = try RestartVersionFixture()
        defer { fixture.remove() }
        let appServer = CodexAppServerClient()
        let application = CodenessApplicationModel(
            appServer: appServer,
            testingCodexShutdownAndVerify: { false }
        )

        #expect(!(await application.restartServer(
            configuredPath: fixture.executableURL.path
        )))
        let registry = application.agentProviderRegistryForTesting()
        #expect(!(await registry.acceptsLaunches(for: .codex)))
        #expect(await appServer.testingEventRoutingIsPaused())

        do {
            _ = try await registry.startRun(Self.runRequest(providerID: .codex))
            Issue.record("Expected failed-closed Codex restart to reject direct launch")
        } catch {
            #expect(error.localizedDescription.contains("Codex is restarting"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func unverifiedClaudeCleanupRetainsFenceBeforeProviderCanLaunch() async throws {
        let fixture = try RestartVersionFixture(versionOutput: "claude 2.1.220")
        defer { fixture.remove() }
        let provider = FailedClosedLaunchRecordingProvider()
        let application = CodenessApplicationModel(initialClaudeProvider: provider)

        #expect(!(await application.restartClaude(
            configuredPath: fixture.executableURL.path
        )))
        let registry = application.agentProviderRegistryForTesting()
        #expect(!(await registry.acceptsLaunches(for: .claude)))
        do {
            _ = try await registry.startRun(Self.runRequest(providerID: .claude))
            Issue.record("Expected failed-closed Claude restart to reject direct launch")
        } catch {
            #expect(error.localizedDescription.contains("Claude is restarting"))
        }
        #expect(await provider.startCount() == 0)
    }

    @Test
    func validationFailureReopensFreshFenceBecauseOldProviderWasUntouched() async {
        let appServer = CodexAppServerClient()
        let application = CodenessApplicationModel(appServer: appServer)

        #expect(!(await application.restartServer(
            configuredPath: "/tmp/codeness-missing-codex-\(UUID().uuidString)"
        )))

        let registry = application.agentProviderRegistryForTesting()
        #expect(await registry.acceptsLaunches(for: .codex))
        #expect(!(await appServer.testingEventRoutingIsPaused()))
    }

    @Test(.timeLimit(.minutes(1)))
    func hungUtilityCannotMakeSettingsRestartWaitWithoutBound() async throws {
        let gate = HungUtilityGate()
        let provider = HungUtilityAgentProvider(gate: gate)
        let application = CodenessApplicationModel(
            initialClaudeProvider: provider,
            testingProviderLaunchDrainTimeout: .milliseconds(30)
        )
        let registry = application.agentProviderRegistryForTesting()
        let utility = Task {
            try await registry.runUtility(Self.utilityRequest(providerID: .claude))
        }
        await gate.waitUntilEntered()

        let clock = ContinuousClock()
        let started = clock.now
        #expect(!(await application.restartClaude(configuredPath: "/not-reached")))
        #expect(clock.now - started < .seconds(1))
        #expect(
            application.applicationError?.contains("already-admitted launch") == true
        )
        #expect(await provider.shutdownCount() == 0)
        #expect(!(await registry.acceptsLaunches(for: .claude)))

        await gate.release()
        _ = try await utility.value
    }

    @Test(.timeLimit(.minutes(1)))
    func quitCancellationUnwindsRestartWaitingForLaunchDrain() async throws {
        let gate = HungUtilityGate()
        let provider = HungUtilityAgentProvider(gate: gate)
        let application = CodenessApplicationModel(
            initialClaudeProvider: provider,
            testingProviderLaunchDrainTimeout: .seconds(30)
        )
        let registry = application.agentProviderRegistryForTesting()
        let utility = Task {
            try await registry.runUtility(Self.utilityRequest(providerID: .claude))
        }
        await gate.waitUntilEntered()
        let restart = Task {
            await application.restartClaude(configuredPath: "/not-reached")
        }
        while await registry.acceptsLaunches(for: .claude) {
            await Task.yield()
        }

        let clock = ContinuousClock()
        let started = clock.now
        #expect(await application.shutdown(prepareDocuments: false))
        #expect(await OwnedSubprocessSupervisor.resumeLaunching())
        #expect(clock.now - started < .seconds(1))
        #expect(!(await restart.value))

        await gate.release()
        _ = try await utility.value
    }

    private static func runRequest(providerID: AgentProviderID) -> AgentRunRequest {
        let target = AgentTarget(providerID: providerID, model: "fixture")
        return AgentRunRequest(
            runID: UUID(),
            session: AgentSession(
                providerID: providerID,
                id: "fixture-session",
                target: target
            ),
            cwd: "/tmp",
            prompt: "Fixture",
            target: target
        )
    }

    private static func utilityRequest(
        providerID: AgentProviderID
    ) -> AgentUtilityRequest {
        AgentUtilityRequest(
            cwd: "/tmp",
            prompt: "Fixture",
            target: AgentTarget(providerID: providerID, model: "fixture"),
            developerInstructions: "Fixture",
            outputSchema: .object([:])
        )
    }

    private nonisolated static func restoreDefault(_ value: String?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static let singleStepCodexWorkflow = WorkflowTemplate(
        id: "restart-admission",
        name: "Restart Admission",
        summary: "Fixture",
        steps: [WorkflowStep(
            id: "run",
            name: "Run",
            section: .loop,
            instructions: "Run the fixture.",
            target: AgentTarget(providerID: .codex, model: "gpt-5.6-sol")
        )],
        coordinator: WorkflowCoordinatorConfiguration(
            target: AgentTarget(providerID: .codex, model: "gpt-5.6-sol"),
            instructions: "Complete after the fixture."
        )
    )
}

private actor FailedClosedLaunchRecordingProvider: AgentProviding {
    nonisolated let id = AgentProviderID.claude
    private var starts = 0

    func prepareSession(_ request: AgentSessionRequest) throws -> AgentSession {
        AgentSession(providerID: id, id: "fixture-session", target: request.target)
    }

    func startRun(_ request: AgentRunRequest) -> AgentRunHandle {
        starts += 1
        return AgentRunHandle(
            runID: request.runID,
            providerID: id,
            sessionID: request.session.id,
            executionID: "fixture-execution",
            events: AsyncStream { $0.finish() }
        )
    }

    func steer(runID: UUID, message: String) {}
    func interrupt(runID: UUID) {}
    func resolveInteraction(
        runID: UUID,
        interactionID: String,
        resolution: AgentInteractionResolution
    ) {}
    func runUtility(_ request: AgentUtilityRequest) -> AgentUtilityResult {
        AgentUtilityResult(output: "fixture")
    }
    func shutdown() {}
    func shutdownAndVerify() -> Bool { false }
    func startCount() -> Int { starts }
}

private actor HungUtilityAgentProvider: AgentProviding {
    nonisolated let id = AgentProviderID.claude
    private let gate: HungUtilityGate
    private var shutdowns = 0

    init(gate: HungUtilityGate) {
        self.gate = gate
    }

    func prepareSession(_ request: AgentSessionRequest) throws -> AgentSession {
        AgentSession(providerID: id, id: "fixture-session", target: request.target)
    }
    func startRun(_ request: AgentRunRequest) throws -> AgentRunHandle {
        throw AgentProviderError.missingRun(request.runID)
    }
    func steer(runID: UUID, message: String) {}
    func interrupt(runID: UUID) {}
    func resolveInteraction(
        runID: UUID,
        interactionID: String,
        resolution: AgentInteractionResolution
    ) {}
    func runUtility(_ request: AgentUtilityRequest) async -> AgentUtilityResult {
        await gate.pause()
        return AgentUtilityResult(output: "fixture")
    }
    func shutdown() {}
    func shutdownAndVerify() -> Bool {
        shutdowns += 1
        return true
    }
    func shutdownCount() -> Int { shutdowns }
}

private actor HungUtilityGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private struct RestartVersionFixture {
    let directoryURL: URL
    let executableURL: URL

    init(versionOutput: String = "codex-cli 0.146.0") throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codeness-restart-version-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        executableURL = directoryURL.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          /bin/echo "\(versionOutput)"
          exit 0
        fi
        exit 99
        """
        try Data(script.utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct HeldVersionCodexFixture {
    let directoryURL: URL
    let executableURL: URL
    private let invocationURL: URL
    private let versionMarkerURL: URL
    private let versionReleaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codeness-held-version-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        executableURL = directoryURL.appendingPathComponent("codex")
        invocationURL = directoryURL.appendingPathComponent("invocations")
        versionMarkerURL = directoryURL.appendingPathComponent("version-entered")
        versionReleaseURL = directoryURL.appendingPathComponent("version-release")
        let invocation = Self.pythonString(invocationURL.path)
        let marker = Self.pythonString(versionMarkerURL.path)
        let release = Self.pythonString(versionReleaseURL.path)
        let script = """
        #!/usr/bin/python3
        import json
        import os
        import sys
        import time

        invocation_path = \(invocation)
        marker_path = \(marker)
        release_path = \(release)

        def log(value):
            with open(invocation_path, "a", encoding="utf-8") as handle:
                handle.write(value + "\\n")
                handle.flush()

        if sys.argv[1:] == ["--version"]:
            log("version")
            open(marker_path, "w", encoding="utf-8").close()
            while not os.path.exists(release_path):
                time.sleep(0.01)
            print("codex-cli 0.146.0")
            sys.exit(0)

        log("server")

        def emit(value):
            os.write(sys.stdout.fileno(), (json.dumps(value) + "\\n").encode("utf-8"))

        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            identifier = message.get("id")
            if method == "initialize":
                emit({"id": identifier, "result": {"userAgent": "held-version"}})
            elif method == "model/list":
                emit({"id": identifier, "result": {"data": [{
                    "id": "gpt-5.6-sol",
                    "model": "gpt-5.6-sol",
                    "displayName": "GPT-5.6 Sol",
                    "description": "Fixture",
                    "defaultReasoningEffort": "high",
                    "supportedReasoningEfforts": [{
                        "reasoningEffort": "high",
                        "description": "High"
                    }],
                    "hidden": False,
                    "isDefault": True
                }], "nextCursor": None}})
        """
        try Data(script.utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    func waitForVersionProbe() async throws {
        let clock = ContinuousClock()
        // A cold launch can first spend the full bounded login-shell window
        // preparing GUI PATH state before it invokes `codex --version`.
        let deadline = clock.now.advanced(by: .seconds(12))
        while !FileManager.default.fileExists(atPath: versionMarkerURL.path),
              clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: versionMarkerURL.path))
    }

    func waitForInvocationCount(_ count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(12))
        while (try invocations()).count < count, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require((try invocations()).count >= count)
    }

    func releaseVersionProbe() {
        _ = FileManager.default.createFile(
            atPath: versionReleaseURL.path,
            contents: Data()
        )
    }

    func invocations() throws -> [String] {
        guard FileManager.default.fileExists(atPath: invocationURL.path) else { return [] }
        return try String(contentsOf: invocationURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private static func pythonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        // JSON's optional `\/` spelling is not an escape in a Python string
        // literal; preserve POSIX paths verbatim in the generated fixture.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try? encoder.encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
