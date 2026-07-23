import Foundation

public enum PromptBuilder {
    public static let implementerInstructions = """
    You are the persistent implementer session in a supervised two-session workflow. Work in the current repository. Codeness will alternate between two distinct kinds of turns in this same session: implementation turns and review-fix turns.

    During an implementation turn, implement one coherent, review-sized work unit and stop. During a fix turn, address the supplied review findings and stop without beginning another work unit. Follow the current turn prompt exactly. Report changed areas, important files and symbols, verification and outcomes, failures, limitations, and remaining work. Use the explicit completion phrase requested by the prompt so the workflow can classify the turn conservatively.
    """

    public static let reviewerInstructions = """
    You are the persistent reviewer in a supervised two-session workflow. Review through ordinary Codex turns, not review mode. Inspect the actual current repository and do not modify files.

    Review only when Codeness supplies a review prompt. Assess the latest implementation work and its integration with prior work. You may re-raise a material earlier finding if it remains present. Consolidate every material finding because the implementer receives exactly one fix turn for each review. If there are no material findings, say so explicitly instead of inventing work.
    """

    public static func implementation(goal: String, template: String) -> String {
        render(template, goal: goal)
    }

    public static func review(goal: String, template: String, implementationOutput: String) -> String {
        render(template, goal: goal)
            .replacingOccurrences(
                of: ActivityPrompts.implementationOutputPlaceholder,
                with: implementationOutput
            )
    }

    public static func fix(goal: String, template: String, reviewOutput: String) -> String {
        let prompt = render(template, goal: goal)
            .replacingOccurrences(of: ActivityPrompts.reviewOutputPlaceholder, with: reviewOutput)
        return """
        \(prompt)

        End your final response with exactly one of these sentences:
        - The whole goal is complete.
        - More implementation work remains.

        Use the first sentence only if the review findings are addressed and the entire goal is now complete. Otherwise use the second sentence.
        """
    }

    private static func render(_ template: String, goal: String) -> String {
        return """
        THE GOAL
        <goal>
        \(goal)
        </goal>

        \(template)
        """
    }
}

public enum RelayPromptBuilder {
    public static func systemPrompt(for context: HandoffContext) -> String {
        let recipient = context.recipient?.displayName ?? "Task history"
        return """
        Act as a conservative editorial relay between two coding sessions.

        Sender: \(context.sender.displayName)
        Recipient: \(recipient)
        Workflow phase: \(context.runKind.displayName)
        Recipient's next task: \(context.recipientPurpose)

        Select the parts of SOURCE that the recipient needs for that next task. Keep retained content as close to the source wording and order as possible. Prefer deleting irrelevant text over rewriting relevant text. Do not aggressively summarize. There is no target length, percentage, or compression ratio.

        Do not add technical conclusions, findings, fixes, facts, or confidence that the source did not contain. Preserve exact identifiers, paths, commands, test outcomes, errors, caveats, uncertainty, completion claims, and actionable review findings. Remove only clearly recipient-irrelevant material such as greetings, repeated process narration, duplicated conclusions, or commentary with no bearing on the recipient's next action. If unsure whether something is relevant, retain it.

        \(relevanceGuidance(for: context))
        \(classificationGuidance(for: context.runKind))

        Classify only the state explicitly supported by the source. Return unclear rather than guessing. Derive a factual noun-phrase run label of at most 48 characters that identifies the concrete work or findings. The label must not be only a generic phase name such as Implement, Review, Fix, Implementation, or Closeout.
        """
    }

    public static func userPrompt(for context: HandoffContext) -> String {
        """
        SOURCE
        <source>
        \(context.source)
        </source>
        """
    }

    private static func relevanceGuidance(for context: HandoffContext) -> String {
        if context.sender == .implementer, context.recipient == .reviewer {
            return "Retain what changed, affected files and symbols, design decisions, tests and results, failures, limitations, unresolved work, and whether this is a checkpoint or claimed completion."
        }
        if context.sender == .reviewer, context.recipient == .implementer {
            return "Retain every material finding, severity or priority, evidence, affected locations, expected correction, verification gaps, and explicit no-findings conclusions."
        }
        if context.runKind == .fix {
            return "Retain the fixes applied, affected files and symbols, verification performed, failures, remaining risks, whether the review findings were fully addressed, and the explicit whole-goal completion verdict."
        }
        return "Retain the final change summary, verification performed, failures, remaining risks, and completion state."
    }

    private static func classificationGuidance(for runKind: RunKind) -> String {
        switch runKind {
        case .implementation:
            return "For a successful source, classify implementationCheckpoint when more implementation work remains, or implementationComplete only when the source explicitly claims the whole activity is implemented."
        case .review:
            return "For a completed review, classify reviewComplete whether it contains findings or explicitly reports no material findings."
        case .fix:
            return "Classify fixCheckpoint when the source explicitly says that more implementation or review work remains, or that the whole activity is not complete. Classify fixComplete only when the source explicitly reports both that the review findings were addressed (or there were no actionable fixes) and that the whole goal is complete. If the source does not explicitly resolve both questions, classify unclear."
        }
    }
}
