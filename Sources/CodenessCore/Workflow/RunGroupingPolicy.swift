import Foundation

public struct RunWorkUnit: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case legacy
        case prefix
        case loop(iteration: Int)
        case postfix
    }

    public let number: Int
    public let kind: Kind
    public let runs: [RunRecord]

    public init(number: Int, kind: Kind = .legacy, runs: [RunRecord]) {
        self.number = number
        self.kind = kind
        self.runs = runs
    }

    public var id: Int { number }

    public var title: String {
        switch kind {
        case .legacy:
            "Work Unit \(number)"
        case .prefix:
            "Before Loop"
        case .loop(let iteration):
            "Cycle \(iteration)"
        case .postfix:
            "After Completion"
        }
    }
}

public enum RunGroupingPolicy {
    public static func workUnits(for runs: [RunRecord]) -> [RunWorkUnit] {
        if !runs.isEmpty, runs.allSatisfy({ $0.workflowStep != nil }) {
            return genericWorkUnits(for: runs)
        }
        return legacyWorkUnits(for: runs)
    }

    public static func loopIterationCount(for runs: [RunRecord]) -> Int {
        if !runs.isEmpty, runs.allSatisfy({ $0.workflowStep != nil }) {
            return Set(
                runs.compactMap { run -> Int? in
                    guard run.workflowStep?.section == .loop else { return nil }
                    return run.workflowStep?.loopIteration
                }
            ).count
        }
        return legacyWorkUnits(for: runs).count
    }

    private static func legacyWorkUnits(for runs: [RunRecord]) -> [RunWorkUnit] {
        var groups: [RunWorkUnit] = []
        var currentRuns: [RunRecord] = []
        var currentContainsFix = false

        func appendCurrentGroup() {
            guard !currentRuns.isEmpty else { return }
            groups.append(
                RunWorkUnit(
                    number: groups.count + 1,
                    kind: .legacy,
                    runs: currentRuns
                )
            )
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

    private static func genericWorkUnits(for runs: [RunRecord]) -> [RunWorkUnit] {
        var groups: [RunWorkUnit] = []
        var currentKind: RunWorkUnit.Kind?
        var currentRuns: [RunRecord] = []

        func appendCurrentGroup() {
            guard let currentKind, !currentRuns.isEmpty else { return }
            groups.append(
                RunWorkUnit(
                    number: groups.count + 1,
                    kind: currentKind,
                    runs: currentRuns
                )
            )
        }

        for run in runs {
            guard let snapshot = run.workflowStep else { continue }
            let kind: RunWorkUnit.Kind = switch snapshot.section {
            case .prefix:
                .prefix
            case .loop:
                .loop(iteration: snapshot.loopIteration)
            case .postfix:
                .postfix
            }
            if let currentKind, currentKind != kind {
                appendCurrentGroup()
                currentRuns = []
            }
            currentKind = kind
            currentRuns.append(run)
        }
        appendCurrentGroup()
        return groups
    }
}
