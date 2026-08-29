import Foundation

public enum CompanyCapabilityBlockKind: String, Codable, CaseIterable, Sendable {
    case professionForbidden
    case targetUnavailable
    case providerUnenforceable
    case discoveredDuringWork
}

public struct CompanyCapabilityBlock: Codable, Equatable, Sendable {
    public let kind: CompanyCapabilityBlockKind
    public let requiredCapability: CompanyCapability
    public let detail: String
    public let artifacts: [String]
    public let suggestedPositions: [CompanyPositionID]

    public init(
        kind: CompanyCapabilityBlockKind,
        requiredCapability: CompanyCapability,
        detail: String,
        artifacts: [String],
        suggestedPositions: [CompanyPositionID]
    ) {
        self.kind = kind
        self.requiredCapability = requiredCapability
        self.detail = detail
        self.artifacts = artifacts
        self.suggestedPositions = suggestedPositions
    }
}

public struct CompanyWorkReport: Codable, Equatable, Sendable {
    public let workerID: String
    public let positionID: CompanyPositionID
    public let contributionKind: CompanyContributionKind
    public let summary: String
    public let artifacts: [String]
    public let evidence: [String]
    public let decisions: [String]
    public let constraints: [String]
    public let risks: [String]
    public let capabilityBlock: CompanyCapabilityBlock?
    public let recommendedRecipientPositions: [CompanyPositionID]

    public init(
        workerID: String,
        positionID: CompanyPositionID,
        contributionKind: CompanyContributionKind,
        summary: String,
        artifacts: [String],
        evidence: [String],
        decisions: [String],
        constraints: [String],
        risks: [String],
        capabilityBlock: CompanyCapabilityBlock?,
        recommendedRecipientPositions: [CompanyPositionID]
    ) {
        self.workerID = workerID
        self.positionID = positionID
        self.contributionKind = contributionKind
        self.summary = summary
        self.artifacts = artifacts
        self.evidence = evidence
        self.decisions = decisions
        self.constraints = constraints
        self.risks = risks
        self.capabilityBlock = capabilityBlock
        self.recommendedRecipientPositions = recommendedRecipientPositions
    }

    public static func decode(
        _ output: String,
        for snapshot: LiveTeamMemberSnapshot
    ) -> CompanyWorkReport? {
        let clean = strippedCodeFence(output)
        guard let data = clean.data(using: .utf8),
              let report = try? JSONDecoder().decode(Self.self, from: data),
              report.workerID == snapshot.member.id,
              report.positionID == snapshot.member.positionID,
              let positionID = snapshot.member.positionID,
              CompanyPositionPracticeCatalog.practice(positionID)
                .allowedContributions.contains(report.contributionKind),
              !report.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return report
    }

    public static func unstructured(
        _ output: String,
        for snapshot: LiveTeamMemberSnapshot
    ) -> CompanyWorkReport {
        let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = clean.isEmpty
            ? "The worker returned no structured contribution."
            : String(clean.prefix(800))
        return CompanyWorkReport(
            workerID: snapshot.member.id,
            positionID: snapshot.member.positionID ?? .developer,
            contributionKind: .unstructured,
            summary: summary,
            artifacts: [],
            evidence: [],
            decisions: [],
            constraints: [],
            risks: ["The final response did not match the required company work-report contract."],
            capabilityBlock: nil,
            recommendedRecipientPositions: []
        )
    }

    public static func outputSchema(for snapshot: LiveTeamMemberSnapshot) -> JSONValue {
        let positionID = snapshot.member.positionID ?? .developer
        let contributionKinds = CompanyPositionPracticeCatalog.practice(positionID)
            .allowedContributions.map { JSONValue.string($0.rawValue) }
        let textArray: JSONValue = .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")])
        ])
        let positionValues = CompanyPositionID.allCases.map { JSONValue.string($0.rawValue) }
        let block: JSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array(CompanyCapabilityBlockKind.allCases.map {
                        .string($0.rawValue)
                    })
                ]),
                "requiredCapability": .object([
                    "type": .string("string"),
                    "enum": .array(CompanyCapability.allCases.map {
                        .string($0.rawValue)
                    })
                ]),
                "detail": .object(["type": .string("string")]),
                "artifacts": textArray,
                "suggestedPositions": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("string"),
                        "enum": .array(positionValues)
                    ])
                ])
            ]),
            "required": .array([
                .string("kind"), .string("requiredCapability"), .string("detail"),
                .string("artifacts"), .string("suggestedPositions")
            ])
        ])
        return .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "workerID": .object([
                    "type": .string("string"),
                    "enum": .array([.string(snapshot.member.id)])
                ]),
                "positionID": .object([
                    "type": .string("string"),
                    "enum": .array([.string(positionID.rawValue)])
                ]),
                "contributionKind": .object([
                    "type": .string("string"),
                    "enum": .array(contributionKinds)
                ]),
                "summary": .object(["type": .string("string"), "minLength": .integer(1)]),
                "artifacts": textArray,
                "evidence": textArray,
                "decisions": textArray,
                "constraints": textArray,
                "risks": textArray,
                "capabilityBlock": .object([
                    "anyOf": .array([block, .object(["type": .string("null")])])
                ]),
                "recommendedRecipientPositions": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("string"),
                        "enum": .array(positionValues)
                    ])
                ])
            ]),
            "required": .array([
                .string("workerID"), .string("positionID"), .string("contributionKind"),
                .string("summary"), .string("artifacts"), .string("evidence"),
                .string("decisions"), .string("constraints"), .string("risks"),
                .string("capabilityBlock"), .string("recommendedRecipientPositions")
            ])
        ])
    }

    public static func outputSchemaIfAssigned(
        for snapshot: LiveTeamMemberSnapshot
    ) -> JSONValue? {
        guard snapshot.member.positionID != nil,
              snapshot.member.companyAssignment != nil else { return nil }
        return outputSchema(for: snapshot)
    }

    public static func promptContract(for snapshot: LiveTeamMemberSnapshot) -> String {
        let positionID = snapshot.member.positionID ?? .developer
        let practice = CompanyPositionPracticeCatalog.practice(positionID)
        let contributions = practice.allowedContributions.map(\.rawValue).sorted()
            .joined(separator: ", ")
        return """
        WORK REPORT

        Return only the structured JSON work report requested by Codeness. Use workerID "\(snapshot.member.id)", positionID "\(positionID.rawValue)", and one of these contribution kinds: \(contributions). Keep the full result of your craft in artifacts; evidence; decisions; constraints; and risks. When separate file writing is unavailable, put complete authored work inline in those report fields; that alone is not a capability block unless the assignment explicitly requires a file artifact. If the next required effect is unavailable or belongs to another profession, fill capabilityBlock and recommend the correct position instead of doing that work yourself. Use null when there is no capability block.
        """
    }

    private static func strippedCodeFence(_ output: String) -> String {
        let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("```") else { return clean }
        var lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return clean }
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}

public struct CompanyHandoffPacket: Equatable, Sendable {
    public let report: CompanyWorkReport
    public let recipientPositionID: CompanyPositionID?
    public let recipientAssignment: CompanyAssignmentContract?

    public init(
        report: CompanyWorkReport,
        recipientPositionID: CompanyPositionID?,
        recipientAssignment: CompanyAssignmentContract?
    ) {
        self.report = report
        self.recipientPositionID = recipientPositionID
        self.recipientAssignment = recipientAssignment
    }

    public var rendered: String {
        let recipient = recipientPositionID.map {
            CompanyPositionCatalog.position($0).title
        } ?? "CEO"
        let subscribed = recipientPositionID.map {
            CompanyPositionPracticeCatalog.practice($0)
                .subscribedContributions.contains(report.contributionKind)
        } ?? true
        let requiredByAssignment = recipientAssignment.map {
            $0.contributionKind == report.contributionKind
                || $0.dependencyContributionKinds.contains(report.contributionKind)
        } ?? true
        let continuesOwnContribution = recipientAssignment?.contributionKind
            == report.contributionKind
        let relevantDetail = (subscribed || continuesOwnContribution)
            && requiredByAssignment
        var result = ""
        appendSection("HANDOFF PACKET", to: &result)
        appendSection(
            "From: \(CompanyPositionCatalog.position(report.positionID).title) [\(report.workerID)]",
            to: &result
        )
        appendSection("For: \(recipient)", to: &result)
        appendSection("Contribution: \(report.contributionKind.rawValue)", to: &result)
        if relevantDetail || report.contributionKind == .unstructured {
            appendSection("Summary:", to: &result)
            appendText(" ", to: &result)
            appendText(report.summary, to: &result)
            append(report.decisions, label: "Decisions", to: &result)
        } else {
            appendSection(
                "Summary: This contribution is outside the recipient's subscribed assignment dependencies.",
                to: &result
            )
        }
        if requiredByAssignment || report.contributionKind == .unstructured {
            append(report.artifacts, label: "Artifacts", to: &result)
            append(report.evidence, label: "Evidence", to: &result)
            append(report.constraints, label: "Constraints", to: &result)
            append(report.risks, label: "Risks", to: &result)
        }
        if let block = report.capabilityBlock {
            appendSection(
                "CAPABILITY BLOCK: \(block.kind.rawValue) / \(block.requiredCapability.rawValue) /",
                to: &result
            )
            appendText(" ", to: &result)
            appendText(block.detail, to: &result)
            append(block.artifacts, label: "Block artifacts", to: &result)
            let suggestions = block.suggestedPositions.map {
                CompanyPositionCatalog.position($0).title
            }
            append(suggestions, label: "Suggested professions", to: &result)
        }
        return result
    }

    private func append(_ values: [String], label: String, to result: inout String) {
        guard !values.isEmpty else { return }
        appendSection("\(label):", to: &result)
        for (index, value) in values.enumerated() {
            appendText(index == 0 ? " " : " | ", to: &result)
            appendText(value, to: &result)
        }
    }

    private func appendSection(_ value: String, to result: inout String) {
        if !result.isEmpty {
            appendText("\n", to: &result)
        }
        appendText(value, to: &result)
    }

    private func appendText(_ value: String, to result: inout String) {
        let remaining = 6_000 - result.count
        guard remaining > 0 else { return }
        result.append(contentsOf: value.prefix(remaining))
    }
}
