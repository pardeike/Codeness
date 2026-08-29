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
        let decodedReport = CompanyWorkReport.decode(sourceResult, for: snapshot)
        let report = decodedReport
            ?? CompanyWorkReport.unstructured(sourceResult, for: snapshot)
        let recipient = proposedCheckpoint.flatMap {
            definition.member(id: $0.memberID)
        }
        let packet = CompanyHandoffPacket(
            report: report,
            recipientPositionID: recipient?.positionID,
            recipientAssignment: recipient?.companyAssignment
        )
        let handoff = dependencyHandoff(
            currentPacket: packet,
            recipient: recipient,
            revision: definition.revision,
            runs: betRuns
        )

        let disposition: LiveTeamCoordinatorDisposition
        let evidence: String
        if decodedReport == nil && snapshot.member.companyAssignment != nil {
            disposition = .requestOversight
            evidence = "The assigned profession did not return the required structured work-report contract. The CEO must retry, change the target, or revise the assignment."
        } else if let block = report.capabilityBlock {
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
            handoff: handoff,
            runLabel: runLabel(from: report.summary, fallback: snapshot.member.name),
            disposition: disposition,
            evidence: evidence,
            progressEvidence: .none,
            tokenUsage: nil
        )
    }

    private static func dependencyHandoff(
        currentPacket: CompanyHandoffPacket,
        recipient: LiveTeamMember?,
        revision: Int,
        runs: [RunRecord]
    ) -> String {
        guard let dependencies = recipient?.companyAssignment?.dependencyContributionKinds else {
            return currentPacket.rendered
        }
        let maximumCharacters = 6_000
        let priorHeading = "PRIOR ACCEPTED DEPENDENCY EVIDENCE\n"
        let currentHeading = "\n\nCURRENT CONTRIBUTION\n"
        let priorBudget = 1_800
        var remainingPriorCharacters = priorBudget
        var priorPackets: [String] = []
        let priorCount = dependencies.filter {
            $0 != currentPacket.report.contributionKind
        }.count
        for contribution in dependencies
            where contribution != currentPacket.report.contributionKind {
            guard remainingPriorCharacters > 0,
                  let run = runs.reversed().first(where: {
                      $0.status == .completed
                          && $0.liveTeamMember?.revision == revision
                          && $0.liveTeamMember?.member.companyAssignment?.contributionKind
                              == contribution
                          && $0.coordinatorDecision?.disposition == .continueTeam
                  }),
                  let storedPacket = run.coordinatorDecision?.handoff else { continue }
            let packet: String
            if let output = run.finalOutput,
               let snapshot = run.liveTeamMember,
               let report = CompanyWorkReport.decode(output, for: snapshot) {
                packet = CompanyHandoffPacket(
                    report: report,
                    recipientPositionID: recipient?.positionID,
                    recipientAssignment: recipient?.companyAssignment
                ).rendered
            } else {
                packet = storedPacket
            }
            let fairShare = max(
                1,
                remainingPriorCharacters / max(priorCount - priorPackets.count, 1)
            )
            let bounded = boundedText(
                packet,
                limit: min(fairShare, remainingPriorCharacters)
            )
            priorPackets.append(bounded)
            remainingPriorCharacters -= bounded.count
        }
        guard !priorPackets.isEmpty else { return currentPacket.rendered }
        let prior = priorPackets.joined(separator: "\n\n")
        let currentBudget = max(
            0,
            maximumCharacters - priorHeading.count - prior.count - currentHeading.count
        )
        return priorHeading + prior + currentHeading
            + boundedText(currentPacket.rendered, limit: currentBudget)
    }

    private static func boundedText(_ value: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard value.count > limit else { return value }
        let marker = " ... [truncated]"
        guard limit > marker.count else { return String(value.prefix(limit)) }
        return String(value.prefix(limit - marker.count)) + marker
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
