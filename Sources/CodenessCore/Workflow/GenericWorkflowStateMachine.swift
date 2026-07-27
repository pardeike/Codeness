import Foundation

public enum GenericWorkflowTransition: Sendable, Equatable {
    case run(WorkflowCursor)
    case complete
    case pause(String)
}

public enum GenericWorkflowStateMachine {
    public static func initialCursor(for workflow: WorkflowTemplate) -> WorkflowCursor? {
        if !workflow.steps(in: .prefix).isEmpty {
            return WorkflowCursor(section: .prefix, stepIndex: 0)
        }
        if !workflow.steps(in: .loop).isEmpty {
            return WorkflowCursor(section: .loop, stepIndex: 0)
        }
        if !workflow.steps(in: .postfix).isEmpty {
            return WorkflowCursor(section: .postfix, stepIndex: 0)
        }
        return nil
    }

    public static func step(
        at cursor: WorkflowCursor,
        in workflow: WorkflowTemplate
    ) -> WorkflowStep? {
        let steps = workflow.steps(in: cursor.section)
        guard steps.indices.contains(cursor.stepIndex) else { return nil }
        return steps[cursor.stepIndex]
    }

    public static func isLoopDecision(
        _ cursor: WorkflowCursor,
        in workflow: WorkflowTemplate
    ) -> Bool {
        guard cursor.section == .loop else { return false }
        return cursor.stepIndex == workflow.steps(in: .loop).count - 1
    }

    public static func transition(
        after cursor: WorkflowCursor,
        outcome: WorkflowOutcome,
        in workflow: WorkflowTemplate
    ) -> GenericWorkflowTransition {
        switch outcome {
        case .blocked:
            return .pause("The step reported that the workflow is blocked.")
        case .failed:
            return .pause("The step reported a failure.")
        case .unclear:
            return .pause("The coordinator could not determine how the workflow should continue.")
        case .continueWorkflow, .complete:
            break
        }

        switch cursor.section {
        case .prefix:
            let prefix = workflow.steps(in: .prefix)
            if cursor.stepIndex + 1 < prefix.count {
                return .run(
                    WorkflowCursor(
                        section: .prefix,
                        stepIndex: cursor.stepIndex + 1,
                        loopIteration: cursor.loopIteration
                    )
                )
            }
            if !workflow.steps(in: .loop).isEmpty {
                return .run(
                    WorkflowCursor(
                        section: .loop,
                        stepIndex: 0,
                        loopIteration: cursor.loopIteration
                    )
                )
            }
            return firstPostfixOrComplete(cursor: cursor, workflow: workflow)

        case .loop:
            let loop = workflow.steps(in: .loop)
            if cursor.stepIndex + 1 < loop.count {
                return .run(
                    WorkflowCursor(
                        section: .loop,
                        stepIndex: cursor.stepIndex + 1,
                        loopIteration: cursor.loopIteration
                    )
                )
            }
            if outcome == .complete {
                return firstPostfixOrComplete(cursor: cursor, workflow: workflow)
            }
            return .run(
                WorkflowCursor(
                    section: .loop,
                    stepIndex: 0,
                    loopIteration: cursor.loopIteration + 1
                )
            )

        case .postfix:
            let postfix = workflow.steps(in: .postfix)
            if cursor.stepIndex + 1 < postfix.count {
                return .run(
                    WorkflowCursor(
                        section: .postfix,
                        stepIndex: cursor.stepIndex + 1,
                        loopIteration: cursor.loopIteration
                    )
                )
            }
            return .complete
        }
    }

    private static func firstPostfixOrComplete(
        cursor: WorkflowCursor,
        workflow: WorkflowTemplate
    ) -> GenericWorkflowTransition {
        guard !workflow.steps(in: .postfix).isEmpty else { return .complete }
        return .run(
            WorkflowCursor(
                section: .postfix,
                stepIndex: 0,
                loopIteration: cursor.loopIteration
            )
        )
    }
}
