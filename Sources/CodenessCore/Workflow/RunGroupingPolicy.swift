import Foundation

public struct RunWorkUnit: Sendable, Equatable, Identifiable {
    public let number: Int
    public let runs: [RunRecord]

    public init(number: Int, runs: [RunRecord]) {
        self.number = number
        self.runs = runs
    }

    public var id: Int { number }
}

public enum RunGroupingPolicy {
    public static func workUnits(for runs: [RunRecord]) -> [RunWorkUnit] {
        var groups: [RunWorkUnit] = []
        var currentRuns: [RunRecord] = []
        var currentContainsFix = false

        func appendCurrentGroup() {
            guard !currentRuns.isEmpty else { return }
            groups.append(RunWorkUnit(number: groups.count + 1, runs: currentRuns))
        }

        for run in runs {
            if run.kind == .implementation, currentContainsFix {
                appendCurrentGroup()
                currentRuns = []
                currentContainsFix = false
            }
            currentRuns.append(run)
            if run.kind == .fix {
                currentContainsFix = true
            }
        }
        appendCurrentGroup()
        return groups
    }
}
