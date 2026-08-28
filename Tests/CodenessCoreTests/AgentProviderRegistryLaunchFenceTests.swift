import Foundation
import Testing
@testable import CodenessCore

struct AgentProviderRegistryLaunchFenceTests {
    @Test
    func everyProviderCallReceivesTheHumanVoiceAndCharacterContract() async throws {
        let provider = LaunchRecordingAgentProvider()
        let registry = AgentProviderRegistry(providers: [provider])

        _ = try await registry.prepareSession(Self.sessionRequest)
        _ = try await registry.runUtility(Self.utilityRequest)

        let requests = await provider.capturedRequests()
        let sessionInstructions = try #require(requests.session?.developerInstructions)
        let utilityInstructions = try #require(requests.utility?.developerInstructions)
        for instructions in [sessionInstructions, utilityInstructions] {
            #expect(instructions.contains("Fixture"))
            #expect(instructions.contains("HUMAN VOICE AND CHARACTER"))
            #expect(instructions.contains("Stay in character"))
            #expect(instructions.contains("use I for their judgments"))
            #expect(instructions.contains("status-ticker language"))
            #expect(instructions.contains("Exact output schemas remain binding"))
        }
    }

    @Test
    func launchFenceRejectsEveryDirectAdmissionWithoutCallingProvider() async throws {
        let provider = LaunchRecordingAgentProvider()
        let registry = AgentProviderRegistry(providers: [provider])
        let fence = try await registry.fenceLaunches(for: .codex)

        await #expect(throws: AgentProviderError.self) {
            _ = try await registry.prepareSession(Self.sessionRequest)
        }
        await #expect(throws: AgentProviderError.self) {
            _ = try await registry.startRun(Self.runRequest)
        }
        await #expect(throws: AgentProviderError.self) {
            _ = try await registry.runUtility(Self.utilityRequest)
        }
        #expect(await provider.launchCounts() == .init())

        await registry.resumeLaunches(fence)
        _ = try await registry.prepareSession(Self.sessionRequest)
        _ = try await registry.startRun(Self.runRequest)
        _ = try await registry.runUtility(Self.utilityRequest)
        #expect(await provider.launchCounts() == .init(
            preparedSessions: 1,
            startedRuns: 1,
            utilities: 1
        ))
    }

    @Test
    func launchFenceDrainsAnAdmissionThatCrossedBoundaryBeforeRejectingNewWork() async throws {
        let gate = ProviderLaunchGate()
        let provider = LaunchRecordingAgentProvider(prepareGate: gate)
        let registry = AgentProviderRegistry(providers: [provider])

        let admittedPreparation = Task {
            try await registry.prepareSession(Self.sessionRequest)
        }
        await gate.waitUntilEntered()
        let fence = try await registry.fenceLaunches(for: .codex)
        let drainTask = Task {
            await registry.waitForLaunchesToDrain(fence, timeout: .seconds(1))
        }
        while await registry.acceptsLaunches(for: .codex) {
            await Task.yield()
        }

        await #expect(throws: AgentProviderError.self) {
            _ = try await registry.startRun(Self.runRequest)
        }
        #expect(await provider.launchCounts().startedRuns == 0)

        await gate.release()
        _ = try await admittedPreparation.value
        #expect(await drainTask.value)
        #expect(!(await registry.acceptsLaunches(for: .codex)))
        await registry.resumeLaunches(fence)
        #expect(await registry.acceptsLaunches(for: .codex))
    }

    private static let target = AgentTarget(providerID: .codex, model: "fixture")
    private static let session = AgentSession(
        providerID: .codex,
        id: "fixture-session",
        target: target
    )
    private static let sessionRequest = AgentSessionRequest(
        existingSessionID: nil,
        name: "Fixture",
        cwd: "/tmp",
        target: target,
        developerInstructions: "Fixture"
    )
    private static let runRequest = AgentRunRequest(
        runID: UUID(),
        session: session,
        cwd: "/tmp",
        prompt: "Run",
        target: target
    )
    private static let utilityRequest = AgentUtilityRequest(
        cwd: "/tmp",
        prompt: "Summarize",
        target: target,
        developerInstructions: "Fixture",
        outputSchema: .object([:])
    )
}

private struct ProviderLaunchCounts: Sendable, Equatable {
    var preparedSessions = 0
    var startedRuns = 0
    var utilities = 0
}

private actor LaunchRecordingAgentProvider: AgentProviding {
    nonisolated let id = AgentProviderID.codex
    private let prepareGate: ProviderLaunchGate?
    private var counts = ProviderLaunchCounts()
    private var capturedSessionRequest: AgentSessionRequest?
    private var capturedUtilityRequest: AgentUtilityRequest?

    init(prepareGate: ProviderLaunchGate? = nil) {
        self.prepareGate = prepareGate
    }

    func prepareSession(_ request: AgentSessionRequest) async -> AgentSession {
        counts.preparedSessions += 1
        capturedSessionRequest = request
        await prepareGate?.pause()
        return AgentSession(
            providerID: id,
            id: "fixture-session",
            target: request.target
        )
    }

    func startRun(_ request: AgentRunRequest) -> AgentRunHandle {
        counts.startedRuns += 1
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
        counts.utilities += 1
        capturedUtilityRequest = request
        return AgentUtilityResult(output: "fixture")
    }

    func shutdown() {}

    func launchCounts() -> ProviderLaunchCounts {
        counts
    }

    func capturedRequests() -> (
        session: AgentSessionRequest?,
        utility: AgentUtilityRequest?
    ) {
        (capturedSessionRequest, capturedUtilityRequest)
    }
}

private actor ProviderLaunchGate {
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
