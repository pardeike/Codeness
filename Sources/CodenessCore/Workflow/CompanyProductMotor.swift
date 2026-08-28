import Foundation

public enum CompanyProductMotor {
    public static func decision(
        sourceResult: String,
        snapshot: LiveTeamMemberSnapshot,
        definition: LiveTeamDefinition,
        proposedCheckpoint: LiveTeamCheckpoint?,
        runs: [RunRecord]
    ) -> LiveTeamCoordinatorDecision {
        let betRuns = runs.filter {
            $0.liveTeamMember?.revision == definition.revision
        }
        let usage = fundedUsage(definition: definition, runs: betRuns)
        let productTokens = betRuns.compactMap(\.tokenUsage).reduce(RunTokenUsage.zero) {
            $0.adding($1)
        }
        let bet = definition.productBet
        let reachedTokenLimit = bet.map {
            usage.totalTokens >= $0.fundedTokenLimit
        } ?? false
        let reachedTurnLimit = bet.map {
            betRuns.count >= $0.maximumTurns
        } ?? false
        let explicitBoundary = sourceResult.localizedCaseInsensitiveContains(
            "INVESTMENT BOUNDARY: READY"
        )

        let disposition: LiveTeamCoordinatorDisposition
        let evidence: String
        if proposedCheckpoint == nil {
            disposition = .requestOversight
            evidence = "The funded product bet reached an investment decision because no assigned person remains eligible."
        } else if reachedTokenLimit {
            disposition = .requestOversight
            evidence = "The funded product bet used \(usage.totalTokens) of its \(bet?.fundedTokenLimit ?? 0) token budget, including \(productTokens.totalTokens) product-work tokens."
        } else if reachedTurnLimit {
            disposition = .requestOversight
            evidence = "The funded product bet reached its \(bet?.maximumTurns ?? 0)-turn investment boundary."
        } else if explicitBoundary {
            disposition = .requestOversight
            evidence = "The team declared its integrated demonstration ready for an investment decision."
        } else {
            disposition = .continueTeam
            evidence = "The funded product bet still has room for direct product work."
        }

        return LiveTeamCoordinatorDecision(
            handoff: handoff(from: sourceResult),
            runLabel: runLabel(from: sourceResult, fallback: snapshot.member.name),
            disposition: disposition,
            evidence: evidence,
            progressEvidence: .none,
            tokenUsage: nil
        )
    }

    public static func usage(
        for definition: LiveTeamDefinition,
        runs: [RunRecord]
    ) -> RunTokenUsage {
        fundedUsage(
            definition: definition,
            runs: runs.filter {
                $0.liveTeamMember?.revision == definition.revision
            }
        )
    }

    private static func fundedUsage(
        definition: LiveTeamDefinition,
        runs: [RunRecord]
    ) -> RunTokenUsage {
        var values = runs.compactMap(\.tokenUsage)
        if let setup = definition.setupTokenUsage {
            values.append(setup)
        }
        let people = [definition.overseerPerson].compactMap { $0 }
            + definition.members.compactMap(\.person)
            + definition.formerPeople
        values += people.compactMap { person in
            guard (person.hiredRevision ?? 1) == definition.revision else { return nil }
            return person.generationTokenUsage
        }
        return values.reduce(RunTokenUsage.zero) { $0.adding($1) }
    }

    private static func handoff(from output: String) -> String {
        let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return "The previous person returned no written result. Inspect the repository and continue the funded product bet from its durable state."
        }
        return String(clean.suffix(6_000))
    }

    private static func runLabel(from output: String, fallback: String) -> String {
        let firstUsefulLine = output.split(separator: "\n")
            .map {
                $0.trimmingCharacters(in: CharacterSet(
                    charactersIn: "#*-_ `\t"
                ))
            }
            .first { !$0.isEmpty && !$0.hasSuffix(":") }
        let label = firstUsefulLine ?? fallback
        return String(label.prefix(60))
    }
}
