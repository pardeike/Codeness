import Foundation

enum WorkSummaryPrompt {
    static let cacheVersion = "bounded-compact-markdown-v2"

    // Codex App Server rejects a single text input above 1,048,576 characters.
    // Leave room for JSON-RPC framing and future prompt instructions.
    static let maximumPromptCharacters = 900_000
    static let maximumUserPromptCharacters = 750_000

    private static let maximumCoordinatorInstructionsCharacters = 32_000
    private static let maximumGoalCharacters = 16_000
    private static let maximumHandoffTextCharacters = 1_500

    static let system = """
    Write the “Work so far” section of a software-workflow dashboard. Use only the supplied goal and handoffs. Reconcile older statements with later handoffs and report the net current state instead of retelling the chronology. Do not invent repository facts.

    The summary string must contain compact Markdown only:
    - Use these level-three headings when applicable, in this order: `### Completed`, `### Current state`, `### Remaining`.
    - Put one to four short bullet points under each heading.
    - Never return prose paragraphs or a single wall of text.
    - Keep the entire summary at or below 120 words and each bullet at or below 20 words.
    - Prefer direct, terse wording. Omit introductions, repeated goal text, and superseded implementation details.
    - Omit `Remaining` when the handoffs contain no unfinished work or material risk.
    - Do not add a separate “Work so far” title.
    """

    static let outputSchema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([.string("summary")]),
        "properties": .object([
            "summary": .object([
                "type": .string("string"),
                "minLength": .integer(1)
            ])
        ])
    ])

    static func user(
        _ context: WorkSummaryContext,
        maximumCharacters: Int = maximumUserPromptCharacters
    ) -> String {
        guard maximumCharacters > 0 else { return "" }
        let scaffold = "GOAL\n\n"
        let handoffHeading = "\n\nHANDOFFS IN CHRONOLOGICAL ORDER\n\n"
        let goalBudget = min(
            maximumGoalCharacters,
            max(0, maximumCharacters - scaffold.count - handoffHeading.count)
        )
        let goal = abbreviated(context.goal, maximumCharacters: goalBudget)
        let prefix = scaffold + goal + handoffHeading
        let handoffBudget = max(0, maximumCharacters - prefix.count)
        let handoffs = formattedHandoffs(
            context.handoffs,
            maximumCharacters: handoffBudget
        )
        return prefix + handoffs
    }

    static func utilityPrompt(
        _ context: WorkSummaryContext,
        coordinatorInstructions: String
    ) -> String {
        let coordinatorInstructions = abbreviated(
            coordinatorInstructions,
            maximumCharacters: maximumCoordinatorInstructionsCharacters
        )
        let prefix = """
        \(coordinatorInstructions)

        \(system)

        Return the result as the structured object described by the output schema.

        """
        let userBudget = min(
            maximumUserPromptCharacters,
            max(0, maximumPromptCharacters - prefix.count)
        )
        return prefix + user(context, maximumCharacters: userBudget)
    }

    private static func formattedHandoffs(
        _ handoffs: [WorkSummaryHandoff],
        maximumCharacters: Int
    ) -> String {
        guard !handoffs.isEmpty, maximumCharacters > 0 else { return "" }

        let prefixes = handoffs.map { handoff in
            """
            ### \(handoff.sequence). \(handoff.kind.displayName) — \(handoff.label)
            Disposition: \(handoff.disposition.displayName)

            """
        }
        let separatorsLength = max(0, handoffs.count - 1) * 2
        let metadataLength = prefixes.reduce(separatorsLength) { $0 + $1.count }
        guard metadataLength <= maximumCharacters else {
            let metadata = prefixes.joined(separator: "\n\n")
            return abbreviated(metadata, maximumCharacters: maximumCharacters)
        }

        let textBudget = min(
            maximumHandoffTextCharacters,
            (maximumCharacters - metadataLength) / handoffs.count
        )
        return zip(prefixes, handoffs).map { prefix, handoff in
            prefix + abbreviated(handoff.text, maximumCharacters: textBudget)
        }
        .joined(separator: "\n\n")
    }

    private static func abbreviated(_ text: String, maximumCharacters: Int) -> String {
        guard maximumCharacters > 0 else { return "" }
        let characterCount = text.count
        guard characterCount > maximumCharacters else { return text }

        let marker = "\n[… characters omitted …]\n"
        guard marker.count < maximumCharacters else {
            return String(text.prefix(maximumCharacters))
        }
        let retainedCharacters = maximumCharacters - marker.count
        let prefixLength = (retainedCharacters + 1) / 2
        let suffixLength = retainedCharacters / 2
        return String(text.prefix(prefixLength))
            + marker
            + String(text.suffix(suffixLength))
    }

    static func decodeUtilityOutput(_ output: String) throws -> String {
        struct Payload: Decodable {
            let summary: String
        }

        var clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```"), clean.hasSuffix("```") {
            var lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 3 {
                lines.removeFirst()
                lines.removeLast()
                clean = lines.joined(separator: "\n")
            }
        }

        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(clean.utf8))
            let summary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else {
                throw HandoffRouterError.invalidWorkSummary(
                    "summary must contain information."
                )
            }
            return summary
        } catch let error as HandoffRouterError {
            throw error
        } catch {
            throw HandoffRouterError.invalidWorkSummary(error.localizedDescription)
        }
    }
}
