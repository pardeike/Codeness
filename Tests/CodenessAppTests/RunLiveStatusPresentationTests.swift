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

        #expect(presentation.text == "Finishing this turn, then pausing")
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

    @Test
    func workerBriefShowsOperationalPromptWithoutPersonaPreparation() throws {
        let member = LiveTeamMember(
            id: "direction",
            name: "Choose Product Direction",
            instructions: "Compare three product concepts and commit to a direction.",
            target: AgentTarget(providerID: .codex, model: "model"),
            runPolicy: .once,
            sessionPolicy: .ownMemory,
            positionID: .designer,
            companyAssignment: CompanyAssignmentContract(
                contributionKind: .productDesign,
                requiredCapabilities: [.workspaceRead],
                acceptanceEvidence: "Three concepts are comparable and one decision is justified.",
                dependencyContributionKinds: [],
                stopCondition: "Stop when the direction is decision-ready."
            )
        )
        let snapshot = LiveTeamMemberSnapshot(
            member: member,
            workingGoal: "Find the strongest product direction.",
            revision: 1,
            cycle: 1,
            sessionSlotID: "member:direction"
        )
        let prompt = """
        WHO YOU ARE

        A long generated biography that must stay hidden.

        HANDOFF

        Research found two underserved audience needs.

        FUNDED PRODUCT BET

        Compare product directions.
        """
        let presentation = try #require(
            WorkerBriefPresentation(snapshot: snapshot, prompt: prompt)
        )

        #expect(presentation.goal == "Find the strongest product direction.")
        #expect(presentation.assignment.contains("Compare three product concepts"))
        #expect(presentation.handoff == "Research found two underserved audience needs.")
        #expect(!presentation.handoff.contains("generated biography"))
        #expect(!presentation.handoff.contains("WHO YOU ARE"))
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
