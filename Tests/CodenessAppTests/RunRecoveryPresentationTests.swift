import CodenessCore
import Testing
@testable import Codeness

struct RunRecoveryPresentationTests {
    @Test
    func interruptedLiveTeamMemberUsesItsIdentityCheckpoint() throws {
        let target = AgentTarget(providerID: .codex, model: "model")
        let member = LiveTeamMember(
            id: "deliver",
            name: "Deliver",
            instructions: "Deliver one bounded result.",
            target: target,
            runPolicy: .everyCycle,
            sessionPolicy: .ownMemory
        )
        let definition = LiveTeamDefinition(
            revision: 1,
            workingGoal: "Deliver the bounded result.",
            members: [member],
            coordinator: .init(target: target, instructions: "Route local work."),
            strategicReason: "One member is sufficient."
        )
        let snapshot = LiveTeamMemberSnapshot(
            member: member,
            workingGoal: definition.workingGoal,
            revision: 1,
            cycle: 3,
            sessionSlotID: "member:deliver"
        )
        let run = RunRecord(
            sequence: 5,
            role: .implementer,
            kind: .implementation,
            status: .interrupted,
            threadID: "session",
            model: target.model,
            effort: "high",
            prompt: member.instructions,
            relayError: "The member stopped unexpectedly.",
            liveTeamMember: snapshot
        )
        let activity = ActivityRecord(
            goal: "Board goal",
            prompts: .builtInDefaults,
            status: .paused,
            runs: [run],
            liveTeam: LiveTeamState(
                overseer: .init(target: target, instructions: "Control strategy."),
                currentDefinition: definition,
                checkpoint: .init(memberID: member.id, cycle: 3, revision: 1),
                resumeCheckpoint: .recoverRun(run.id)
            )
        )

        let presentation = try #require(
            RunRecoveryPresentation(activity: activity, run: run)
        )

        #expect(presentation.kind == .stepStopped)
        #expect(presentation.nextStepName == member.name)
        #expect(presentation.message == "The member stopped unexpectedly.")
        #expect(!presentation.isGenericWorkflow)
        #expect(!presentation.canFinishWorkflow)
        #expect(presentation.isActionable)
    }

    @Test
    func pausedLiveTeamCoordinatorDecisionShowsItsHandoff() throws {
        let target = AgentTarget(providerID: .codex, model: "model")
        let member = LiveTeamMember(
            id: "review",
            name: "Review",
            instructions: "Review independently.",
            target: target,
            runPolicy: .everyCycle,
            sessionPolicy: .freshEveryRun
        )
        let definition = LiveTeamDefinition(
            revision: 2,
            workingGoal: "Validate the current result.",
            members: [member],
            coordinator: .init(target: target, instructions: "Route local work."),
            strategicReason: "Independent review is required."
        )
        let snapshot = LiveTeamMemberSnapshot(
            member: member,
            workingGoal: definition.workingGoal,
            revision: 2,
            cycle: 4,
            sessionSlotID: "fresh:review:test"
        )
        let decision = LiveTeamCoordinatorDecision(
            handoff: "Inspect the reproducible failure before continuing.",
            runLabel: "Blocked review",
            disposition: .pause,
            evidence: "The acceptance test failed."
        )
        let run = RunRecord(
            sequence: 8,
            role: .reviewer,
            kind: .review,
            status: .paused,
            threadID: "session",
            model: target.model,
            effort: "high",
            prompt: member.instructions,
            relayError: decision.evidence,
            liveTeamMember: snapshot,
            coordinatorDecision: decision
        )
        let activity = ActivityRecord(
            goal: "Board goal",
            prompts: .builtInDefaults,
            status: .paused,
            runs: [run],
            liveTeam: LiveTeamState(
                overseer: .init(target: target, instructions: "Control strategy."),
                currentDefinition: definition,
                checkpoint: .init(memberID: member.id, cycle: 4, revision: 2),
                resumeCheckpoint: .applyCoordinatorDecision(run.id)
            )
        )

        let presentation = try #require(
            RunRecoveryPresentation(activity: activity, run: run)
        )

        #expect(presentation.kind == .workflowPaused)
        #expect(presentation.handoffText == decision.handoff)
        #expect(presentation.nextStepName == member.name)
        #expect(presentation.isActionable)
    }

    @Test
    func failedCurrentStepShowsOnlyStepRecovery() throws {
        let workflow = workflow()
        let run = run(
            step: workflow.steps[0],
            status: .failed,
            relayError: "Provider limit reached"
        )
        let activity = activity(
            workflow: workflow,
            cursor: WorkflowCursor(section: .loop, stepIndex: 0),
            run: run,
            checkpoint: .recoverRun(run.id)
        )

        let presentation = try #require(
            RunRecoveryPresentation(activity: activity, run: run)
        )

        #expect(presentation.kind == .stepStopped)
        #expect(presentation.message == "Provider limit reached")
        #expect(presentation.handoffText == nil)
        #expect(presentation.nextStepName == "Review")
        #expect(!presentation.canFinishWorkflow)
        #expect(presentation.isActionable)
    }

    @Test
    func completedStepWithRoutingErrorShowsHandoffRetry() throws {
        let workflow = workflow()
        let run = run(
            step: workflow.steps[0],
            status: .paused,
            finalOutput: "Implemented the active slice.",
            relayError: "Coordinator unavailable"
        )
        let activity = activity(
            workflow: workflow,
            cursor: WorkflowCursor(section: .loop, stepIndex: 0),
            run: run,
            checkpoint: .routeCompletedRun(run.id)
        )

        let presentation = try #require(
            RunRecoveryPresentation(activity: activity, run: run)
        )

        #expect(presentation.kind == .handoffFailed)
        #expect(presentation.nextStepName == "Review")
        #expect(!presentation.canFinishWorkflow)
        #expect(presentation.isActionable)
    }

    @Test
    func coordinatorPauseUsesItsFilteredHandoffAtTheLoopDecision() throws {
        let workflow = workflow()
        var run = run(
            step: workflow.steps[1],
            status: .paused,
            finalOutput: "Long raw review output",
            relayError: "The step reported that the workflow is blocked."
        )
        run.workflowHandoff = WorkflowHandoff(
            text: "The active slice is blocked by a reproducible compiler failure.",
            outcome: .blocked,
            runLabel: "Blocked review"
        )
        let activity = activity(
            workflow: workflow,
            cursor: WorkflowCursor(section: .loop, stepIndex: 1),
            run: run,
            checkpoint: .routeCompletedRun(run.id)
        )

        let presentation = try #require(
            RunRecoveryPresentation(activity: activity, run: run)
        )

        #expect(presentation.kind == .workflowPaused)
        #expect(
            presentation.handoffText
                == "The active slice is blocked by a reproducible compiler failure."
        )
        #expect(presentation.nextStepName == "Code")
        #expect(presentation.canFinishWorkflow)
        #expect(presentation.isActionable)
    }

    @Test
    func oldFailedRunIsInformationalInsteadOfActionable() throws {
        let workflow = workflow()
        let oldRun = run(
            step: workflow.steps[0],
            status: .failed,
            relayError: "Old provider failure"
        )
        let currentRun = run(
            step: workflow.steps[1],
            status: .failed,
            relayError: "Current provider failure"
        )
        var activity = activity(
            workflow: workflow,
            cursor: WorkflowCursor(section: .loop, stepIndex: 1),
            run: currentRun,
            checkpoint: .recoverRun(currentRun.id)
        )
        activity.runs.insert(oldRun, at: 0)

        let presentation = try #require(
            RunRecoveryPresentation(activity: activity, run: oldRun)
        )

        #expect(presentation.kind == .historical)
        #expect(!presentation.isActionable)
    }

    @Test
    func safePausedRoutingCheckpointKeepsTheGlobalResumeControl() {
        let workflow = workflow()
        let run = run(
            step: workflow.steps[0],
            status: .routing,
            finalOutput: "Ready to route"
        )
        let activity = activity(
            workflow: workflow,
            cursor: WorkflowCursor(section: .loop, stepIndex: 0),
            run: run,
            checkpoint: .routeCompletedRun(run.id)
        )

        #expect(RunRecoveryPresentation(activity: activity, run: run) == nil)
    }

    @Test
    func runningStepDoesNotExposeItsDurableRecoveryCheckpoint() {
        let workflow = workflow()
        let run = run(
            step: workflow.steps[0],
            status: .running
        )
        var activity = activity(
            workflow: workflow,
            cursor: WorkflowCursor(section: .loop, stepIndex: 0),
            run: run,
            checkpoint: .recoverRun(run.id)
        )
        activity.status = .running

        #expect(RunRecoveryPresentation(activity: activity, run: run) == nil)
    }

    private func activity(
        workflow: WorkflowTemplate,
        cursor: WorkflowCursor,
        run: RunRecord,
        checkpoint: WorkflowResumeCheckpoint
    ) -> ActivityRecord {
        ActivityRecord(
            goal: "Exercise recovery presentation",
            prompts: .builtInDefaults,
            status: .paused,
            runs: [run],
            workflow: workflow,
            workflowCursor: cursor,
            workflowResumeCheckpoint: checkpoint
        )
    }

    private func run(
        step: WorkflowStep,
        status: RunStatus,
        finalOutput: String? = nil,
        relayError: String? = nil
    ) -> RunRecord {
        RunRecord(
            sequence: 1,
            role: step.target.options.mode == .plan ? .reviewer : .implementer,
            kind: step.target.options.mode == .plan ? .review : .implementation,
            status: status,
            threadID: nil,
            model: step.target.model,
            effort: step.target.options.effort ?? "high",
            prompt: step.instructions,
            finalOutput: finalOutput,
            relayError: relayError,
            workflowStep: WorkflowStepSnapshot(step: step, loopIteration: 1),
            agentTarget: step.target,
            sessionLineage: 1
        )
    }

    private func workflow() -> WorkflowTemplate {
        let codeTarget = AgentTarget(providerID: .codex, model: "model")
        let reviewTarget = AgentTarget(
            providerID: .codex,
            model: "model",
            options: AgentExecutionOptions(mode: .plan)
        )
        return WorkflowTemplate(
            id: "recovery",
            name: "Recovery",
            summary: "",
            steps: [
                WorkflowStep(
                    id: "code",
                    name: "Code",
                    section: .loop,
                    instructions: "Implement the active slice.",
                    target: codeTarget
                ),
                WorkflowStep(
                    id: "review",
                    name: "Review",
                    section: .loop,
                    instructions: "Review the active slice.",
                    target: reviewTarget
                )
            ],
            coordinator: WorkflowCoordinatorConfiguration(
                target: reviewTarget,
                instructions: "Prepare the next step."
            )
        )
    }
}
