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
}
