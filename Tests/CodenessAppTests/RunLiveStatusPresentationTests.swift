import CodenessCore
import Foundation
import Testing
@testable import Codeness

struct RunLiveStatusPresentationTests {
    @Test
    func runningLiveRunShowsProgressEvenWithoutTranscriptOutput() throws {
        let run = run(status: .running)

        let presentation = try #require(
            RunLiveStatusPresentation(
                run: run,
                liveRunID: run.id,
                pauseAfterCurrent: false
            )
        )

        #expect(presentation.text == "Running")
        #expect(presentation.showsProgress)
        #expect(presentation.tone == .active)
    }

    @Test
    func armedPauseReplacesRunningTextWithThePendingState() throws {
        let run = run(status: .running)

        let presentation = try #require(
            RunLiveStatusPresentation(
                run: run,
                liveRunID: run.id,
                pauseAfterCurrent: true
            )
        )

        #expect(presentation.text == "Finishing this step, then pausing")
        #expect(presentation.showsProgress)
        #expect(presentation.tone == .attention)
    }

    @Test(arguments: [
        (RunStatus.queued, "Starting", true),
        (RunStatus.routing, "Preparing handoff", true),
        (RunStatus.awaitingApproval, "Waiting for input", false),
        (RunStatus.paused, "Paused", false),
    ])
    func representsOtherLiveStates(
        status: RunStatus,
        text: String,
        showsProgress: Bool
    ) throws {
        let run = run(status: status)

        let presentation = try #require(
            RunLiveStatusPresentation(
                run: run,
                liveRunID: run.id,
                pauseAfterCurrent: false
            )
        )

        #expect(presentation.text == text)
        #expect(presentation.showsProgress == showsProgress)
    }

    @Test
    func historicalSelectionHasNoLiveStatus() {
        let run = run(status: .running)

        #expect(
            RunLiveStatusPresentation(
                run: run,
                liveRunID: UUID(),
                pauseAfterCurrent: false
            ) == nil
        )
    }

    @Test
    func pausedWorkflowAppearsOnTheLatestCompletedRun() throws {
        let run = run(status: .completed)

        let presentation = try #require(
            RunLiveStatusPresentation(
                run: run,
                liveRunID: nil,
                pauseAfterCurrent: false,
                pausedWorkflowMessage: "Paused before Code"
            )
        )

        #expect(presentation.text == "Paused before Code")
        #expect(!presentation.showsProgress)
        #expect(presentation.systemImage == "pause.circle.fill")
        #expect(presentation.tone == .attention)
    }

    private func run(status: RunStatus) -> RunRecord {
        RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: status,
            threadID: nil,
            model: "model",
            effort: "high",
            prompt: "Implement the active slice."
        )
    }
}
