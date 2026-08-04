import Foundation
import Testing
@testable import Codeness
@testable import CodenessCore

@Suite(.serialized)
@MainActor
struct CodenessApplicationShutdownTests {
    @Test
    func restartClaudeRetainsTheOldProviderWhenCleanupCannotBeVerified() async throws {
        let fixture = try ClaudeVersionFixture()
        defer { fixture.remove() }
        let provider = ShutdownControllableAgentProvider(shutdownResult: false)
        let application = CodenessApplicationModel(initialClaudeProvider: provider)

        #expect(!(await application.restartClaude(
            configuredPath: fixture.executableURL.path
        )))
        #expect(await provider.shutdownCount() == 1)
        #expect(
            application.applicationError?.contains(
                "could not verify that every Claude and MCP process stopped"
            ) == true
        )
        if case .failed(let detail) = application.claudeState {
            #expect(detail.contains("Starting a replacement is blocked"))
        } else {
            Issue.record("Claude should remain failed closed after unverified cleanup.")
        }

        // A later application shutdown must still reach the same provider. If
        // restart had unregistered or replaced it, this count would remain one.
        #expect(!(await application.shutdown(prepareDocuments: false)))
        #expect(await provider.shutdownCount() == 2)
    }

    @Test
    func applicationShutdownIsCanceledWhenProviderCleanupCannotBeVerified() async {
        let provider = ShutdownControllableAgentProvider(shutdownResult: false)
        let application = CodenessApplicationModel(initialClaudeProvider: provider)

        #expect(!(await application.shutdown(prepareDocuments: false)))
        #expect(await provider.shutdownCount() == 1)
        #expect(
            application.applicationError?.contains(
                "Quit was canceled to avoid leaving an orphan"
            ) == true
        )
        #expect(application.serverState == .stopped)
        if case .failed = application.claudeState {
            // The component whose teardown was not confirmed remains failed.
        } else {
            Issue.record("Claude should remain failed closed.")
        }
    }

    @Test
    func canceledQuitMarksClaudeStoppedWhenOnlyAppServerCleanupFails() async {
        let provider = ShutdownControllableAgentProvider(shutdownResult: true)
        let application = CodenessApplicationModel(
            initialClaudeProvider: provider,
            testingAppServerShutdown: { false }
        )

        #expect(!(await application.shutdown(prepareDocuments: false)))
        #expect(await provider.shutdownCount() == 1)
        #expect(application.claudeState == .stopped)
        if case .failed(let detail) = application.serverState {
            #expect(detail.contains("could not verify"))
        } else {
            Issue.record("Codex should remain failed closed.")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func canceledQuitPermanentlyInvalidatesACodexRestartSuspendedAtCleanup() async throws {
        let gate = AsyncShutdownGate()
        let claudeProvider = ShutdownControllableAgentProvider(shutdownResult: false)
        let fixture = try VersionedCodexFixture()
        defer { fixture.remove() }
        let application = CodenessApplicationModel(
            initialClaudeProvider: claudeProvider,
            testingCodexShutdownAndVerify: { await gate.waitAndReturnTrue() }
        )

        let restart = Task {
            await application.restartServer(configuredPath: fixture.executableURL.path)
        }
        await gate.waitUntilEntered()
        let quit = Task { await application.shutdown(prepareDocuments: false) }
        gate.release()

        #expect(!(await restart.value))
        #expect(!(await quit.value))
        let invocations = try fixture.invocations()
        #expect(invocations == ["--version"])
    }

    @Test(.timeLimit(.minutes(1)))
    func retainedProbeCleanupDebtRefusesResumeAndRepeatedVersionProbes() async throws {
        let fixture = try VersionedCodexFixture()
        defer { fixture.remove() }
        let cleanup = ProbeCleanupResultSwitch()
        await Self.createProbeCleanupDebt(fixture: fixture, cleanup: cleanup)

        #expect(!(await OwnedSubprocessSupervisor.shutdownAll()))
        #expect(!(await OwnedSubprocessSupervisor.resumeLaunching()))
        for _ in 0..<2 {
            await #expect(throws: CancellationError.self) {
                _ = try await CodexExecutableLocator.verify(fixture.executableURL)
            }
        }
        #expect(try fixture.invocations() == ["--version"])

        cleanup.allowCleanup()
        #expect(await OwnedSubprocessSupervisor.shutdownAll())
        #expect(await OwnedSubprocessSupervisor.resumeLaunching())
    }

    @Test(.timeLimit(.minutes(1)))
    func failedProbeCleanupKeepsRestartsFencedAfterCanceledQuit() async throws {
        let fixture = try VersionedCodexFixture()
        defer { fixture.remove() }
        let cleanup = ProbeCleanupResultSwitch()
        await Self.createProbeCleanupDebt(fixture: fixture, cleanup: cleanup)
        let application = CodenessApplicationModel()

        #expect(!(await application.shutdown(prepareDocuments: false)))
        #expect(
            application.applicationError?.contains("executable-check process stopped") == true
        )
        #expect(!(await OwnedSubprocessSupervisor.resumeLaunching()))
        for _ in 0..<2 {
            #expect(!(await application.restartServer(
                configuredPath: fixture.executableURL.path
            )))
        }
        #expect(try fixture.invocations() == ["--version"])

        cleanup.allowCleanup()
        #expect(await OwnedSubprocessSupervisor.shutdownAll())
        #expect(await OwnedSubprocessSupervisor.resumeLaunching())
    }

    @Test(.timeLimit(.minutes(1)))
    func preparationFailureCannotReopenAProbeGateWithCleanupDebt() async throws {
        let fixture = try VersionedCodexFixture()
        defer { fixture.remove() }
        let cleanup = ProbeCleanupResultSwitch()
        await Self.createProbeCleanupDebt(fixture: fixture, cleanup: cleanup)
        let application = CodenessApplicationModel(
            testingDocumentPreparationResult: false
        )

        #expect(!(await application.shutdown()))
        #expect(
            application.applicationError?.contains("executable-check process stopped") == true
        )
        #expect(!(await OwnedSubprocessSupervisor.resumeLaunching()))
        #expect(!(await application.restartServer(
            configuredPath: fixture.executableURL.path
        )))
        #expect(try fixture.invocations() == ["--version"])

        cleanup.allowCleanup()
        #expect(await OwnedSubprocessSupervisor.shutdownAll())
        #expect(await OwnedSubprocessSupervisor.resumeLaunching())
    }

    private static func createProbeCleanupDebt(
        fixture: VersionedCodexFixture,
        cleanup: ProbeCleanupResultSwitch
    ) async {
        #expect(await OwnedSubprocessSupervisor.resumeLaunching())
        do {
            _ = try await BoundedOwnedProcessRunner.run(
                configuration: fixture.configuration,
                timeout: .seconds(2),
                testingCleanupResultOverride: { attempt in
                    cleanup.resultOverride(attempt: attempt)
                }
            )
            Issue.record("Expected injected cleanup verification debt")
        } catch {
            #expect(error.localizedDescription.contains("could not verify"))
        }
    }
}

private struct ClaudeVersionFixture {
    let directory: URL
    let executableURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codeness-claude-version-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        executableURL = directory.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          /bin/echo "claude 2.1.220"
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
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor AsyncShutdownGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitAndReturnTrue() async -> Bool {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return true
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    nonisolated func release() {
        Task { await releaseAll() }
    }

    private func releaseAll() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private struct VersionedCodexFixture {
    let directory: URL
    let executableURL: URL
    private let invocationFile: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codeness-versioned-codex-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        executableURL = directory.appendingPathComponent("codex")
        invocationFile = directory.appendingPathComponent("invocations")
        let script = """
        #!/bin/sh
        /bin/echo "$*" >> "\(invocationFile.path)"
        if [ "$1" = "--version" ]; then
          /bin/echo "codex-cli 0.146.0"
          exit 0
        fi
        exit 97
        """
        try Data(script.utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    func invocations() throws -> [String] {
        try String(contentsOf: invocationFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    var configuration: SupervisedProcessLaunchConfiguration {
        SupervisedProcessLaunchConfiguration(
            executableURL: executableURL,
            arguments: ["--version"],
            environment: ProcessInfo.processInfo.environment,
            currentDirectoryURL: directory
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ProbeCleanupResultSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var cleanupIsAllowed = false

    func resultOverride(attempt: Int) -> Bool? {
        _ = attempt
        return lock.withLock { cleanupIsAllowed ? nil : false }
    }

    func allowCleanup() {
        lock.withLock { cleanupIsAllowed = true }
    }
}

private actor ShutdownControllableAgentProvider: AgentProviding {
    nonisolated let id = AgentProviderID.claude
    private let shutdownResult: Bool
    private var shutdowns = 0

    init(shutdownResult: Bool) {
        self.shutdownResult = shutdownResult
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

    func runUtility(_ request: AgentUtilityRequest) throws -> AgentUtilityResult {
        throw AgentProviderError.unavailable(id, request.cwd)
    }

    func shutdown() {}

    func shutdownAndVerify() -> Bool {
        shutdowns += 1
        return shutdownResult
    }

    func shutdownCount() -> Int {
        shutdowns
    }
}
