import Foundation

enum WorkSummaryPrompt {
    static let cacheVersion = "compact-markdown-v1"

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

    static func user(_ context: WorkSummaryContext) -> String {
        let handoffs = context.handoffs.map { handoff in
            """
            ### \(handoff.sequence). \(handoff.kind.displayName) — \(handoff.label)
            Disposition: \(handoff.disposition.displayName)

            \(handoff.text)
            """
        }
        return """
        GOAL

        \(context.goal)

        HANDOFFS IN CHRONOLOGICAL ORDER

        \(handoffs.joined(separator: "\n\n"))
        """
    }

    static func utilityPrompt(
        _ context: WorkSummaryContext,
        coordinatorInstructions: String
    ) -> String {
        """
        \(coordinatorInstructions)

        \(system)

        Return the result as the structured object described by the output schema.

        \(user(context))
        """
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
