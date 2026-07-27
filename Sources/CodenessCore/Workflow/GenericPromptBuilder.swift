import Foundation

public enum GenericPromptBuilder {
    public static let goalPlaceholder = "{{goal}}"
    public static let previousOutputPlaceholder = "{{previous_output}}"
    public static let loopIterationPlaceholder = "{{loop_iteration}}"

    public static func stepPrompt(
        goal: String,
        workflow: WorkflowTemplate,
        step: WorkflowStep,
        cursor: WorkflowCursor,
        previousHandoff: WorkflowHandoff?
    ) -> String {
        var instructions = step.instructions
            .replacingOccurrences(of: goalPlaceholder, with: goal)
            .replacingOccurrences(
                of: loopIterationPlaceholder,
                with: String(cursor.loopIteration)
            )
        let priorText = previousHandoff?.text ?? ""
        let usedPreviousPlaceholder = instructions.contains(previousOutputPlaceholder)
        instructions = instructions.replacingOccurrences(
            of: previousOutputPlaceholder,
            with: priorText
        )

        var sections = [
            """
            THE GOAL

            \(goal)
            """,
            """
            WORKFLOW

            \(workflow.name)
            """,
            """
            CURRENT STEP

            \(step.name) · \(step.section.displayName) · loop \(cursor.loopIteration)

            \(instructions)
            """
        ]
        if !usedPreviousPlaceholder, !priorText.isEmpty {
            sections.append(
                """
                PREVIOUS STEP HANDOFF

                \(priorText)
                """
            )
        }
        return sections.joined(separator: "\n\n")
    }

    public static func sessionInstructions(
        workflow: WorkflowTemplate,
        step: WorkflowStep
    ) -> String {
        """
        You are the \(step.name) step in Codeness workflow “\(workflow.name)”. \
        Follow the current step instruction and the full goal supplied in each turn. \
        Finish each turn with a clear factual result for the next configured step.
        """
    }
}
