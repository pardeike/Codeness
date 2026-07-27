import Testing
@testable import CodenessCore

struct RunGroupingPolicyTests {
    @Test
    func retryAttemptsRemainInTheirOriginalWorkUnit() {
        let runs = [
            run(1, .implementation, .interrupted),
            run(2, .implementation, .completed),
            run(3, .review, .completed),
            run(4, .fix, .completed),
            run(5, .implementation, .completed),
            run(6, .review, .interrupted),
            run(7, .review, .completed),
            run(8, .fix, .completed)
        ]

        let groups = RunGroupingPolicy.workUnits(for: runs)

        #expect(groups.map(\.number) == [1, 2])
        #expect(groups.map { $0.runs.map(\.sequence) } == [[1, 2, 3, 4], [5, 6, 7, 8]])
        #expect(groups.map { $0.runs.map(\.kind) } == [
            [.implementation, .implementation, .review, .fix],
            [.implementation, .review, .review, .fix]
        ])
        #expect(groups.map(\.title) == ["Work Unit 1", "Work Unit 2"])
        #expect(RunGroupingPolicy.loopIterationCount(for: runs) == 2)
    }

    @Test
    func genericRunsGroupByPrefixLoopIterationAndPostfix() {
        let runs = [
            genericRun(1, step: "plan", name: "Plan", section: .prefix, iteration: 1),
            genericRun(2, step: "code", name: "Code", section: .loop, iteration: 1),
            genericRun(3, step: "review", name: "Review", section: .loop, iteration: 1),
            genericRun(4, step: "review", name: "Review", section: .loop, iteration: 1),
            genericRun(5, step: "code", name: "Code", section: .loop, iteration: 2),
            genericRun(6, step: "review", name: "Review", section: .loop, iteration: 2),
            genericRun(7, step: "summarize", name: "Summarize", section: .postfix, iteration: 2)
        ]

        let groups = RunGroupingPolicy.workUnits(for: runs)

        #expect(groups.map(\.title) == [
            "Before Loop",
            "Cycle 1",
            "Cycle 2",
            "After Completion"
        ])
        #expect(groups.map { $0.runs.map(\.sequence) } == [
            [1],
            [2, 3, 4],
            [5, 6],
            [7]
        ])
        #expect(RunGroupingPolicy.loopIterationCount(for: runs) == 2)
    }

    private func run(_ sequence: Int, _ kind: RunKind, _ status: RunStatus) -> RunRecord {
        RunRecord(
            sequence: sequence,
            role: kind == .review ? .reviewer : .implementer,
            kind: kind,
            status: status,
            threadID: kind == .review ? "reviewer" : "implementer",
            model: "model",
            effort: "high",
            prompt: kind.displayName
        )
    }

    private func genericRun(
        _ sequence: Int,
        step: String,
        name: String,
        section: WorkflowSection,
        iteration: Int
    ) -> RunRecord {
        RunRecord(
            sequence: sequence,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: step,
            model: "model",
            effort: "high",
            prompt: name,
            workflowStep: WorkflowStepSnapshot(
                step: WorkflowStep(
                    id: step,
                    name: name,
                    section: section,
                    instructions: "Do the step.",
                    target: AgentTarget(providerID: .codex, model: "model")
                ),
                loopIteration: iteration
            )
        )
    }
}
