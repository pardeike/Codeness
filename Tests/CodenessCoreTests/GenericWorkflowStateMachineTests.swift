import Testing
@testable import CodenessCore

struct GenericWorkflowStateMachineTests {
    @Test
    func traversesPrefixThenRepeatsTheCompleteLoopThenRunsPostfix() throws {
        let workflow = workflow()
        var cursor = try #require(
            GenericWorkflowStateMachine.initialCursor(for: workflow)
        )
        #expect(stepName(cursor, workflow) == "Plan")

        cursor = try next(after: cursor, outcome: .continueWorkflow, workflow: workflow)
        #expect(stepName(cursor, workflow) == "Prepare")
        cursor = try next(after: cursor, outcome: .continueWorkflow, workflow: workflow)
        #expect(stepName(cursor, workflow) == "Code")
        cursor = try next(after: cursor, outcome: .continueWorkflow, workflow: workflow)
        #expect(stepName(cursor, workflow) == "Review")
        #expect(GenericWorkflowStateMachine.isLoopDecision(cursor, in: workflow))

        cursor = try next(after: cursor, outcome: .continueWorkflow, workflow: workflow)
        #expect(stepName(cursor, workflow) == "Code")
        #expect(cursor.loopIteration == 2)
        cursor = try next(after: cursor, outcome: .continueWorkflow, workflow: workflow)
        #expect(stepName(cursor, workflow) == "Review")
        cursor = try next(after: cursor, outcome: .complete, workflow: workflow)
        #expect(stepName(cursor, workflow) == "Summarize")
        #expect(cursor.loopIteration == 2)
        cursor = try next(after: cursor, outcome: .continueWorkflow, workflow: workflow)
        #expect(stepName(cursor, workflow) == "Notify")
        #expect(
            GenericWorkflowStateMachine.transition(
                after: cursor,
                outcome: .continueWorkflow,
                in: workflow
            ) == .complete
        )
    }

    @Test
    func completionBeforeTheLoopDecisionDoesNotSkipConfiguredSteps() throws {
        let workflow = workflow()
        let cursor = WorkflowCursor(section: .loop, stepIndex: 0)

        let next = try next(after: cursor, outcome: .complete, workflow: workflow)

        #expect(stepName(next, workflow) == "Review")
    }

    @Test(arguments: [
        WorkflowOutcome.blocked,
        .failed,
        .unclear
    ])
    func pausesOnNonActionableOutcomes(_ outcome: WorkflowOutcome) {
        let workflow = workflow()
        let transition = GenericWorkflowStateMachine.transition(
            after: WorkflowCursor(section: .loop, stepIndex: 0),
            outcome: outcome,
            in: workflow
        )

        guard case .pause(let reason) = transition else {
            Issue.record("Expected a pause transition")
            return
        }
        #expect(!reason.isEmpty)
    }

    private func next(
        after cursor: WorkflowCursor,
        outcome: WorkflowOutcome,
        workflow: WorkflowTemplate
    ) throws -> WorkflowCursor {
        guard case .run(let next) = GenericWorkflowStateMachine.transition(
            after: cursor,
            outcome: outcome,
            in: workflow
        ) else {
            Issue.record("Expected another configured step")
            throw TestFailure()
        }
        return next
    }

    private func stepName(
        _ cursor: WorkflowCursor,
        _ workflow: WorkflowTemplate
    ) -> String? {
        GenericWorkflowStateMachine.step(at: cursor, in: workflow)?.name
    }

    private func workflow() -> WorkflowTemplate {
        let target = AgentTarget(providerID: .codex, model: "model")
        return WorkflowTemplate(
            id: "full",
            name: "Full",
            summary: "All sections",
            steps: [
                step("plan", "Plan", .prefix, target),
                step("prepare", "Prepare", .prefix, target),
                step("code", "Code", .loop, target),
                step("review", "Review", .loop, target),
                step("summarize", "Summarize", .postfix, target),
                step("notify", "Notify", .postfix, target)
            ],
            coordinator: WorkflowCoordinatorConfiguration(
                target: target,
                instructions: "Route each result."
            )
        )
    }

    private func step(
        _ id: String,
        _ name: String,
        _ section: WorkflowSection,
        _ target: AgentTarget
    ) -> WorkflowStep {
        WorkflowStep(
            id: id,
            name: name,
            section: section,
            instructions: "Run \(name).",
            target: target
        )
    }
}

private struct TestFailure: Error {}
