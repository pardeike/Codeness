import Foundation

public struct TranscriptVisibility: Sendable, Equatable {
    public var reasoning: Bool
    public var actions: Bool
    public var results: Bool
    public var diagnostics: Bool

    public init(
        reasoning: Bool = true,
        actions: Bool = false,
        results: Bool = true,
        diagnostics: Bool = true
    ) {
        self.reasoning = reasoning
        self.actions = actions
        self.results = results
        self.diagnostics = diagnostics
    }

    public static let recommended = TranscriptVisibility()
    public static let all = TranscriptVisibility(actions: true)
}

public enum RunTranscriptPresentation {
    private static let markerPrefix = "\u{001E}codeness:"
    private static let markerSuffix = "\u{001F}"

    public static func storedText(for update: TranscriptUpdate) -> String {
        guard !update.text.isEmpty else { return "" }
        guard let section = update.section else { return update.text }
        return marker(for: section) + update.text
    }

    public static func storedText(_ text: String, section: TranscriptSectionKind) -> String {
        guard !text.isEmpty else { return "" }
        return marker(for: section) + text
    }

    public static func reconciledTranscript(metadata: String, appendLog: String) -> String {
        guard !appendLog.isEmpty, appendLog != metadata else { return metadata }
        guard !metadata.isEmpty else { return appendLog }
        if appendLog.hasPrefix(metadata) {
            return appendLog
        }
        if metadata.hasPrefix(appendLog) {
            return metadata
        }

        let sharedPrefixCount = zip(metadata, appendLog).prefix { $0.0 == $0.1 }.count
        // An append-only transcript for this run should share its beginning with the
        // metadata copy. If it does not, prefer the successfully decoded metadata
        // instead of joining unrelated or corrupt recovery data to it.
        guard sharedPrefixCount > 0 else { return metadata }
        let appendOnlyRemainder = String(appendLog.dropFirst(sharedPrefixCount))
        guard !appendOnlyRemainder.isEmpty, !metadata.hasSuffix(appendOnlyRemainder) else {
            return metadata
        }
        return metadata + appendOnlyRemainder
    }

    public static func text(
        for run: RunRecord,
        separatesRuns: Bool,
        visibility: TranscriptVisibility = .recommended
    ) -> String {
        if run.transcript.contains(markerPrefix) {
            return structuredText(
                run.transcript,
                separatesRuns: separatesRuns,
                visibility: visibility
            )
        }

        return legacyText(
            run.transcript,
            prompt: run.prompt,
            finalOutput: run.finalOutput,
            separatesRuns: separatesRuns,
            visibility: visibility
        )
    }

    private static func structuredText(
        _ transcript: String,
        separatesRuns: Bool,
        visibility: TranscriptVisibility
    ) -> String {
        var result = ""
        var cursor = transcript.startIndex
        var section: TranscriptSectionKind?

        while let markerRange = transcript.range(of: markerPrefix, range: cursor..<transcript.endIndex) {
            append(
                String(transcript[cursor..<markerRange.lowerBound]),
                section: section,
                separatesRuns: separatesRuns,
                visibility: visibility,
                to: &result
            )
            let nameStart = markerRange.upperBound
            guard let suffixRange = transcript.range(
                of: markerSuffix,
                range: nameStart..<transcript.endIndex
            ) else {
                result += String(transcript[markerRange.lowerBound...])
                return cleanLeadingWhitespace(result)
            }
            section = TranscriptSectionKind(rawValue: String(transcript[nameStart..<suffixRange.lowerBound]))
            cursor = suffixRange.upperBound
        }
        append(
            String(transcript[cursor...]),
            section: section,
            separatesRuns: separatesRuns,
            visibility: visibility,
            to: &result
        )
        return cleanLeadingWhitespace(result)
    }

    private static func legacyText(
        _ transcript: String,
        prompt: String,
        finalOutput: String?,
        separatesRuns: Bool,
        visibility: TranscriptVisibility
    ) -> String {
        var source = transcript
        if separatesRuns {
            let renderedPrompt = "Prompt\n\(prompt)\n\n"
            if source.hasPrefix(renderedPrompt) {
                source.removeFirst(renderedPrompt.count)
            }
        }
        if !visibility.results,
           let finalOutput,
           !finalOutput.isEmpty,
           let range = source.range(of: finalOutput, options: .backwards),
           source[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source.removeSubrange(range)
        }

        var current: TranscriptSectionKind = source.hasPrefix("Could not start turn:")
            ? .diagnostic
            : .reasoning
        var result: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line)
            if let identified = legacySection(for: value) {
                current = identified
            }
            if isVisible(current, separatesRuns: separatesRuns, visibility: visibility) {
                result.append(value)
            }
        }
        return cleanLeadingWhitespace(result.joined(separator: "\n"))
    }

    private static func legacySection(for line: String) -> TranscriptSectionKind? {
        switch line {
        case "Prompt": return .prompt
        case "Thinking", "Reasoning", "Agent", "Plan": return .reasoning
        case "Result": return .result
        case "[Applying file changes]", "[File changes: completed]": return .action
        case "[Context compacted]": return .diagnostic
        default:
            if line.hasPrefix("$ ") || line.hasPrefix("› ") { return .action }
            if line.hasPrefix("⚠ ") || line.hasPrefix("Error:") { return .diagnostic }
            return nil
        }
    }

    private static func append(
        _ text: String,
        section: TranscriptSectionKind?,
        separatesRuns: Bool,
        visibility: TranscriptVisibility,
        to result: inout String
    ) {
        guard let section else {
            result += text
            return
        }
        if isVisible(section, separatesRuns: separatesRuns, visibility: visibility) {
            result += text
        }
    }

    private static func isVisible(
        _ section: TranscriptSectionKind,
        separatesRuns: Bool,
        visibility: TranscriptVisibility
    ) -> Bool {
        switch section {
        case .prompt: !separatesRuns
        case .reasoning: visibility.reasoning
        case .action: visibility.actions
        case .result: visibility.results
        case .diagnostic: visibility.diagnostics
        }
    }

    private static func marker(for section: TranscriptSectionKind) -> String {
        markerPrefix + section.rawValue + markerSuffix
    }

    private static func cleanLeadingWhitespace(_ text: String) -> String {
        String(text.drop(while: { $0 == "\n" || $0 == "\r" }))
    }
}
