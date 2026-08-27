import CodenessCore
import Testing
@testable import Codeness

struct WorkflowControlPresentationTests {
    @Test
    func transportControlsUseCompactTextLabels() {
        #expect(WorkflowTransportControl.resume.buttonTitle == "Resume")
        #expect(WorkflowTransportControl.pauseAfterCurrent.buttonTitle == "Pause")
        #expect(WorkflowTransportControl.keepRunning.buttonTitle == "Continue")
        #expect(WorkflowTransportControl.resume.emphasis == .proceed)
        #expect(WorkflowTransportControl.pauseAfterCurrent.emphasis == .caution)
        #expect(WorkflowTransportControl.keepRunning.emphasis == .proceed)
        #expect(
            WorkflowTransportControl.keepRunning.pauseNotice
                == "Finishing this turn, then pausing"
        )
        #expect(WorkflowImmediateControl.stopCurrentStep.buttonTitle == "Stop Now")
    }

    @Test
    func pausedResumableActivityShowsPlay() {
        let presentation = WorkflowControlPresentation(
            canResume: true,
            isActivityRunning: false,
            pauseAfterCurrent: false,
            canInterrupt: false
        )

        #expect(presentation.transport == .resume)
        #expect(presentation.immediateControl == nil)
        #expect(presentation.isVisible)
    }

    @Test
    func runningActivityTogglesBetweenPauseAndKeepRunning() {
        let automatic = WorkflowControlPresentation(
            canResume: false,
            isActivityRunning: true,
            pauseAfterCurrent: false,
            canInterrupt: false
        )
        let pauseArmed = WorkflowControlPresentation(
            canResume: false,
            isActivityRunning: true,
            pauseAfterCurrent: true,
            canInterrupt: false
        )

        #expect(automatic.transport == .pauseAfterCurrent)
        #expect(pauseArmed.transport == .keepRunning)
    }

    @Test
    func stopNowAppearsBesideRunningTransport() {
        let presentation = WorkflowControlPresentation(
            canResume: false,
            isActivityRunning: true,
            pauseAfterCurrent: false,
            canInterrupt: true
        )

        #expect(presentation.transport == .pauseAfterCurrent)
        #expect(presentation.immediateControl == .stopCurrentStep)
        #expect(presentation.isVisible)
    }

    @Test
    func inactiveActivityHasNoWorkflowFooter() {
        let presentation = WorkflowControlPresentation(
            canResume: false,
            isActivityRunning: false,
            pauseAfterCurrent: false,
            canInterrupt: false
        )

        #expect(presentation.transport == nil)
        #expect(presentation.immediateControl == nil)
        #expect(!presentation.isVisible)
    }

    @Test
    func completedActivityHasNoWorkflowFooter() {
        let presentation = WorkflowControlPresentation(
            canResume: false,
            isActivityRunning: false,
            pauseAfterCurrent: false,
            canInterrupt: false
        )

        #expect(presentation.transport == nil)
        #expect(presentation.immediateControl == nil)
        #expect(!presentation.isVisible)
    }

    @Test
    func interruptedRunStatusIsPresentedAsStopped() {
        #expect(RunStatus.interrupted.displayName == "Stopped")
        #expect(RunStatus.awaitingApproval.displayName == "Waiting for Input")
    }
}
