import Testing
@testable import Codeness

struct WorkflowControlPresentationTests {
    @Test
    func pausedResumableActivityShowsPlay() {
        let presentation = WorkflowControlPresentation(
            canResume: true,
            isActivityRunning: false,
            pauseAfterCurrent: false,
            canInterrupt: false
        )

        #expect(presentation.transport == .resume)
        #expect(!presentation.showsInterrupt)
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
    func interruptAppearsBesideRunningTransport() {
        let presentation = WorkflowControlPresentation(
            canResume: false,
            isActivityRunning: true,
            pauseAfterCurrent: false,
            canInterrupt: true
        )

        #expect(presentation.transport == .pauseAfterCurrent)
        #expect(presentation.showsInterrupt)
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
        #expect(!presentation.showsInterrupt)
        #expect(!presentation.isVisible)
    }
}
