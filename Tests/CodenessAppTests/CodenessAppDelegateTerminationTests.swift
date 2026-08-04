import Foundation
import Testing
@testable import Codeness
@testable import CodenessCore

@MainActor
struct CodenessAppDelegateTerminationTests {
    @Test(.timeLimit(.minutes(1)))
    func systemTerminationEscalatesGracefulPauseWhenNoTerminalArrives() async {
        let probe = TerminationEscalationProbe()

        let result = await CodenessAppDelegate.prepareForTermination(
            systemInitiated: true,
            gracePeriod: .milliseconds(20),
            graceful: {
                await probe.gracefulPauseWaitingForTerminal()
            },
            immediate: {
                probe.stopRemainingNow()
            }
        )

        #expect(result == .ready)
        #expect(probe.actions == [.graceful, .immediate])
    }

    @Test
    func userInitiatedTerminationLeavesEscalationToVisibleProgressControl() async {
        let probe = TerminationEscalationProbe(completesGracefully: true)

        let result = await CodenessAppDelegate.prepareForTermination(
            systemInitiated: false,
            gracePeriod: .zero,
            graceful: {
                await probe.gracefulPauseWaitingForTerminal()
            },
            immediate: {
                probe.stopRemainingNow()
            }
        )

        #expect(result == .ready)
        #expect(probe.actions == [.graceful])
    }
}

@MainActor
private final class TerminationEscalationProbe {
    enum Action: Equatable {
        case graceful
        case immediate
    }

    private let completesGracefully: Bool
    private var terminalWaiter: CheckedContinuation<Void, Never>?
    private(set) var actions: [Action] = []

    init(completesGracefully: Bool = false) {
        self.completesGracefully = completesGracefully
    }

    func gracefulPauseWaitingForTerminal() async -> DocumentClosePreparationResult {
        actions.append(.graceful)
        if completesGracefully { return .ready }
        await withCheckedContinuation { continuation in
            terminalWaiter = continuation
        }
        return .ready
    }

    func stopRemainingNow() {
        actions.append(.immediate)
        let waiter = terminalWaiter
        terminalWaiter = nil
        waiter?.resume()
    }
}
