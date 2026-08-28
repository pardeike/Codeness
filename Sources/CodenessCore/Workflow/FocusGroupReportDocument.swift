import Foundation

enum FocusGroupReportDocument {
    static let directoryName = "Focus Groups"

    static func write(
        _ report: LiveTeamFocusGroupReport,
        repositoryPath: String
    ) throws -> String {
        let repository = URL(
            fileURLWithPath: repositoryPath,
            isDirectory: true
        ).standardizedFileURL
        let directory = repository.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let identifier = report.id.uuidString.prefix(8).lowercased()
        let fileName = "\(formatter.string(from: report.completedAt))-\(identifier).md"
        let destination = directory.appendingPathComponent(fileName)
        try markdown(report).write(
            to: destination,
            atomically: true,
            encoding: .utf8
        )
        return "\(directoryName)/\(fileName)"
    }

    static func markdown(_ report: LiveTeamFocusGroupReport) -> String {
        let sources = report.sources.isEmpty
            ? "- No live source was available."
            : report.sources.map { source in
                let date = source.publishedAt.map { " (\(inline($0)))" } ?? ""
                return "- [\(linkLabel(source.title))](\(source.url))\(date): \(inline(source.relevance))"
            }.joined(separator: "\n")
        let participants = report.participants.isEmpty
            ? "- No simulated participant response was available."
            : report.participants.map { participant in
                """
                - **\(inline(participant.archetype))** chose **\(participant.choice.displayName)**.
                  Expected: \(inline(participant.expectation))
                  Reaction: \(inline(participant.reaction))
                """
            }.joined(separator: "\n")
        let findings = report.findings.isEmpty
            ? "- No findings were produced."
            : report.findings.map { "- \(inline($0))" }.joined(separator: "\n")
        let availability = report.failure.map {
            "\n\n## Availability\n\n\(inline($0))"
        } ?? ""

        return """
        # Focus group: \(inline(report.subject))

        This is a simulated, directional playtest. It is not statistical research or real customer validation.

        ## Test card

        - **Audience:** \(inline(report.audience))
        - **Question:** \(inline(report.question))
        - **Research basis:** \(report.researchBasis.displayName)

        ## A/B context

        - **Current product:** \(inline(report.subject))
        - **Comparison:** \(inline(report.comparison))
        - **Why this comparison:** \(inline(report.comparisonReason))

        ## Simulated panel

        \(participants)

        ## Findings

        \(findings)

        ## Verdict

        \(inline(report.verdict))

        ## Next product experiment

        \(inline(report.nextExperiment))

        ## Sources

        \(sources)

        ## Limits

        \(inline(report.limitations))\(availability)
        """
    }

    private static func inline(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func linkLabel(_ value: String) -> String {
        inline(value).replacingOccurrences(of: "]", with: "\\]")
    }
}
