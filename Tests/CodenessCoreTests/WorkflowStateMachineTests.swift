import Testing
@testable import CodenessCore

struct WorkflowStateMachineTests {
    @Test
    func alwaysRunsReviewAndFixAfterImplementation() {
        #expect(
            WorkflowStateMachine.decision(
                after: .implementation,
                disposition: .implementationCheckpoint,
                implementationClaimedComplete: false
            ) == .continueWith(.review)
        )
        #expect(
            WorkflowStateMachine.decision(
                after: .implementation,
                disposition: .implementationComplete,
                implementationClaimedComplete: true
            ) == .continueWith(.review)
        )
        #expect(
            WorkflowStateMachine.decision(
                after: .review,
                disposition: .reviewComplete,
                implementationClaimedComplete: false
            ) == .continueWith(.fix)
        )
    }

    @Test
    func startsNextWorkUnitOnlyAfterCheckpointFixes() {
        let decision = WorkflowStateMachine.decision(
            after: .fix,
            disposition: .fixComplete,
            implementationClaimedComplete: false
        )
        #expect(decision == .continueWith(.implement))
    }

    @Test
    func completesOnlyAfterFixingACompletedImplementation() {
        let decision = WorkflowStateMachine.decision(
            after: .fix,
            disposition: .fixComplete,
            implementationClaimedComplete: true
        )
        #expect(decision == .continueWith(.complete))
    }

    @Test(arguments: [SourceDisposition.blocked, .failed, .unclear])
    func pausesOnNonActionableState(_ disposition: SourceDisposition) {
        guard case .pause = WorkflowStateMachine.decision(
            after: .implementation,
            disposition: disposition,
            implementationClaimedComplete: false
        ) else {
            Issue.record("Expected workflow to pause")
            return
        }
    }

    @Test
    func rejectsAReviewDispositionAfterFixes() {
        guard case .pause = WorkflowStateMachine.decision(
            after: .fix,
            disposition: .reviewComplete,
            implementationClaimedComplete: false
        ) else {
            Issue.record("Expected invalid phase classification to pause")
            return
        }
    }
}
