import Testing
@testable import CodenessCore

struct WorkflowStateMachineTests {
    @Test
    func alwaysRunsReviewAndFixAfterImplementation() {
        #expect(
            WorkflowStateMachine.decision(
                after: .implementation,
                disposition: .implementationCheckpoint
            ) == .continueWith(.review)
        )
        #expect(
            WorkflowStateMachine.decision(
                after: .implementation,
                disposition: .implementationComplete
            ) == .continueWith(.review)
        )
        #expect(
            WorkflowStateMachine.decision(
                after: .review,
                disposition: .reviewComplete
            ) == .continueWith(.fix)
        )
    }

    @Test
    func startsNextWorkUnitWhenFixesExplicitlyLeaveWorkRemaining() {
        let decision = WorkflowStateMachine.decision(
            after: .fix,
            disposition: .fixCheckpoint
        )
        #expect(decision == .continueWith(.implement))
    }

    @Test
    func completesOnlyWhenTheFinalFixConfirmsTheWholeGoal() {
        let decision = WorkflowStateMachine.decision(
            after: .fix,
            disposition: .fixComplete
        )
        #expect(decision == .continueWith(.complete))
    }

    @Test(arguments: [SourceDisposition.blocked, .failed, .unclear])
    func pausesOnNonActionableState(_ disposition: SourceDisposition) {
        guard case .pause = WorkflowStateMachine.decision(
            after: .implementation,
            disposition: disposition
        ) else {
            Issue.record("Expected workflow to pause")
            return
        }
    }

    @Test
    func rejectsAReviewDispositionAfterFixes() {
        guard case .pause = WorkflowStateMachine.decision(
            after: .fix,
            disposition: .reviewComplete
        ) else {
            Issue.record("Expected invalid phase classification to pause")
            return
        }
    }
}
