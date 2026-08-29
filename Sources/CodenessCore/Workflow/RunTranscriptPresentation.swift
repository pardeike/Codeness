import Foundation

public struct TranscriptVisibility: Codable, Sendable, Equatable {
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

public enum RunDetailPresentation: String, Codable, Sendable, CaseIterable {
    case split
    case transcript
    case result

    public var displayName: String {
        switch self {
        case .split: "Split"
        case .transcript: "Transcript"
        case .result: "Result"
        }
    }
}

public struct TranscriptTextRange: Sendable, Equatable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct PresentedTranscript: Sendable, Equatable {
    public let text: String
    public let steeringRanges: [TranscriptTextRange]

    public init(text: String, steeringRanges: [TranscriptTextRange] = []) {
        self.text = text
        self.steeringRanges = steeringRanges
    }
}

public enum RunTranscriptPresentation {
    private static let markerPrefix = "\u{001E}codeness:"
    private static let markerSuffix = "\u{001F}"
    private static let transientClaudeStatus = "Claude status: requesting"

    public static func storedText(for update: TranscriptUpdate) -> String {
        guard !update.text.isEmpty else { return "" }
        guard let section = update.section else { return update.text }
        return marker(for: section) + update.text
    }

    public static func storedText(_ text: String, section: TranscriptSectionKind) -> String {
        guard !text.isEmpty else { return "" }
        return marker(for: section) + text
    }

    public static func storedSteeringMessage(_ message: String) -> String {
        let visibleMessage = message
            .replacingOccurrences(of: "\u{001E}", with: "␞")
            .replacingOccurrences(of: "\u{001F}", with: "␟")
        return storedText("\n\nYou steered\n\(visibleMessage)\n", section: .steering)
            + storedText("\n", section: .reasoning)
    }

    public static func reconciledTranscript(metadata: String, appendLog: String) -> String {
        guard appendLog != metadata else { return metadata }
        if appendLog.hasPrefix(metadata) {
            return appendLog
        }
        if metadata.hasPrefix(appendLog) {
            return metadata
        }

        // Prefix relationships are the only safe automatic recovery case. A gap,
        // truncation, or malformed fragment cannot be merged without inventing an
        // ordering, so the successfully decoded metadata remains canonical.
        return metadata
    }

    public static func text(
        for run: RunRecord,
        separatesRuns: Bool,
        visibility: TranscriptVisibility = .recommended
    ) -> String {
        content(
            for: run,
            separatesRuns: separatesRuns,
            visibility: visibility
        ).text
    }

    public static func content(
        for run: RunRecord,
        separatesRuns: Bool,
        visibility: TranscriptVisibility = .recommended
    ) -> PresentedTranscript {
        if run.transcript.contains(markerPrefix) {
            return structuredContent(
                run.transcript,
                companyMember: run.liveTeamMember,
                separatesRuns: separatesRuns,
                visibility: visibility
            )
        }

        return PresentedTranscript(
            text: legacyText(
                run.transcript,
                prompt: run.prompt,
                finalOutput: run.finalOutput,
                separatesRuns: separatesRuns,
                visibility: visibility
            )
        )
    }

    private static func structuredContent(
        _ transcript: String,
        companyMember: LiveTeamMemberSnapshot?,
        separatesRuns: Bool,
        visibility: TranscriptVisibility
    ) -> PresentedTranscript {
        var result = PresentedTranscriptBuilder()
        var cursor = transcript.startIndex
        var section: TranscriptSectionKind?

        while let markerRange = transcript.range(of: markerPrefix, range: cursor..<transcript.endIndex) {
            append(
                String(transcript[cursor..<markerRange.lowerBound]),
                section: section,
                companyMember: companyMember,
                separatesRuns: separatesRuns,
                visibility: visibility,
                to: &result
            )
            let nameStart = markerRange.upperBound
            guard let suffixRange = transcript.range(
                of: markerSuffix,
                range: nameStart..<transcript.endIndex
            ) else {
                result.append(
                    String(transcript[markerRange.lowerBound...]),
                    isSteering: section == .steering
                )
                return result.presentation
            }
            section = TranscriptSectionKind(rawValue: String(transcript[nameStart..<suffixRange.lowerBound]))
            cursor = suffixRange.upperBound
        }
        append(
            String(transcript[cursor...]),
            section: section,
            companyMember: companyMember,
            separatesRuns: separatesRuns,
            visibility: visibility,
            to: &result
        )
        return result.presentation
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
        return cleanPresentedText(result.joined(separator: "\n"))
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
        companyMember: LiveTeamMemberSnapshot?,
        separatesRuns: Bool,
        visibility: TranscriptVisibility,
        to result: inout PresentedTranscriptBuilder
    ) {
        guard let section else {
            result.append(text, isSteering: false)
            return
        }
        if (section == .reasoning || section == .result),
           let companyMember,
           CompanyWorkReport.decode(text, for: companyMember) != nil {
            return
        }
        if isVisible(section, separatesRuns: separatesRuns, visibility: visibility) {
            result.append(text, isSteering: section == .steering)
        } else if section == .action,
                  !visibility.actions,
                  visibility.reasoning,
                  let recovered = legacyClaudeTextAfterAction(in: text) {
            result.append(recovered, isSteering: false)
        }
    }

    private static func legacyClaudeTextAfterAction(in text: String) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let toolLine = lines.firstIndex(where: { $0.hasPrefix("› ") }) else {
            return nil
        }
        lines.remove(at: toolLine)
        let recovered = lines.joined(separator: "\n")
        return recovered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : recovered
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
        case .steering: true
        }
    }

    private static func marker(for section: TranscriptSectionKind) -> String {
        markerPrefix + section.rawValue + markerSuffix
    }

    private static func cleanLeadingWhitespace(_ text: String) -> String {
        String(text.drop(while: { $0 == "\n" || $0 == "\r" }))
    }

    private static func cleanPresentedText(_ text: String) -> String {
        cleanLeadingWhitespace(
            text.replacingOccurrences(of: transientClaudeStatus, with: "")
        )
    }
}

private struct PresentedTranscriptBuilder {
    private(set) var text = ""
    private(set) var steeringRanges: [TranscriptTextRange] = []
    private var utf16Count = 0

    mutating func append(_ value: String, isSteering: Bool) {
        var rendered = value.replacingOccurrences(
            of: "Claude status: requesting",
            with: ""
        )
        if text.isEmpty {
            rendered = String(rendered.drop(while: { $0 == "\n" || $0 == "\r" }))
        }
        guard !rendered.isEmpty else { return }

        let location = utf16Count
        text += rendered
        utf16Count += rendered.utf16.count
        guard isSteering else { return }

        let utf16 = Array(rendered.utf16)
        let leading = utf16.prefix(while: { $0 == 10 || $0 == 13 }).count
        let trailing = utf16.reversed().prefix(while: { $0 == 10 || $0 == 13 }).count
        let length = utf16.count - leading - trailing
        guard length > 0 else { return }
        steeringRanges.append(TranscriptTextRange(
            location: location + leading,
            length: length
        ))
    }

    var presentation: PresentedTranscript {
        PresentedTranscript(text: text, steeringRanges: steeringRanges)
    }
}
