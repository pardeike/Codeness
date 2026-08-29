import Foundation

public enum CompanyProductMotor {
    public static let minimumProductTurns = 6

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
        let fundingTokens = usage.effectiveFundingTokens
        let productFundingTokens = productTokens.effectiveFundingTokens
        let bet = definition.productBet
        let reachedTokenLimit = bet.map {
            fundingTokens >= $0.fundedTokenLimit
        } ?? false
        let turnLimit = bet.map {
            max($0.maximumTurns, minimumProductTurns)
        }
        let reachedTurnLimit = turnLimit.map {
            betRuns.count >= $0
        } ?? false
        let explicitBoundary = sourceResult.localizedCaseInsensitiveContains(
            "INVESTMENT BOUNDARY: READY"
        )
        let completedRunway = betRuns.count >= minimumProductTurns
        let report = CompanyWorkReport.decode(sourceResult, for: snapshot)
            ?? CompanyWorkReport.unstructured(sourceResult, for: snapshot)
        let recipientPositionID = proposedCheckpoint.flatMap {
            definition.member(id: $0.memberID)?.positionID
        }
        let packet = CompanyHandoffPacket(
            report: report,
            recipientPositionID: recipientPositionID
        )

        let disposition: LiveTeamCoordinatorDisposition
        let evidence: String
        if let block = report.capabilityBlock {
            disposition = .requestOversight
            evidence = "The assigned profession reported a \(block.kind.rawValue) capability block for \(block.requiredCapability.rawValue). The CEO must change staffing, target, or scope."
        } else if proposedCheckpoint == nil {
            disposition = .requestOversight
            evidence = "The funded product bet reached an investment decision because no assigned person remains eligible."
        } else if reachedTokenLimit && completedRunway {
            disposition = .requestOversight
            evidence = "The funded product bet used \(fundingTokens) of its \(bet?.fundedTokenLimit ?? 0) effective funding-token budget, including \(productFundingTokens) product-work funding tokens."
        } else if reachedTurnLimit {
            disposition = .requestOversight
            evidence = "The funded product bet reached its \(turnLimit ?? 0)-turn investment boundary."
        } else if explicitBoundary && completedRunway {
            disposition = .requestOversight
            evidence = "The team declared its integrated demonstration ready for an investment decision."
        } else {
            disposition = .continueTeam
            evidence = "The funded product bet still has room for direct product work."
        }

        return LiveTeamCoordinatorDecision(
            handoff: packet.rendered,
            runLabel: runLabel(from: report.summary, fallback: snapshot.member.name),
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
