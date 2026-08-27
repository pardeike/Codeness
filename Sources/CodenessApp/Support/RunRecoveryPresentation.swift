import CodenessCore
import Foundation

struct RunRecoveryPresentation: Equatable {
    enum Kind: Equatable {
        case stepStopped
        case handoffFailed
        case workflowPaused
        case historical
    }

    let kind: Kind
    let message: String
    let handoffText: String?
    let nextStepName: String?
    let isGenericWorkflow: Bool
    let canFinishWorkflow: Bool
    let isActionable: Bool

    init?(activity: ActivityRecord?, run: RunRecord) {
        guard let activity else { return nil }

        let message = Self.message(for: run)
        if let liveTeam = activity.liveTeam {
            let nextMemberName = liveTeam.checkpoint.flatMap {
                liveTeam.currentDefinition?.member(id: $0.memberID)?.name
            }
            switch liveTeam.resumeCheckpoint {
            case .recoverRun(let runID)? where runID == run.id:
                guard activity.status == .paused else { return nil }
                self.init(
                    kind: .stepStopped,
                    message: message,
                    handoffText: nil,
                    nextStepName: nextMemberName,
                    isGenericWorkflow: false,
                    canFinishWorkflow: false,
                    isActionable: true
                )
            case .routeCompletedRun(let runID)? where runID == run.id:
                guard activity.status == .paused else { return nil }
                guard run.relayError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                else { return nil }
                self.init(
                    kind: run.coordinatorDecision == nil ? .handoffFailed : .workflowPaused,
                    message: message,
                    handoffText: run.coordinatorDecision?.handoff,
                    nextStepName: nextMemberName,
                    isGenericWorkflow: false,
                    canFinishWorkflow: false,
                    isActionable: true
                )
            case .applyCoordinatorDecision(let runID)? where runID == run.id:
                guard activity.status == .paused,
                      let decision = run.coordinatorDecision else { return nil }
                self.init(
                    kind: .workflowPaused,
                    message: message,
                    handoffText: decision.handoff,
                    nextStepName: nextMemberName,
                    isGenericWorkflow: false,
                    canFinishWorkflow: false,
                    isActionable: true
                )
            default:
                guard run.relayError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                else { return nil }
                self.init(
                    kind: .historical,
                    message: message,
                    handoffText: nil,
                    nextStepName: nil,
                    isGenericWorkflow: false,
                    canFinishWorkflow: false,
                    isActionable: false
                )
            }
            return
        }
        if activity.workflow != nil {
            let context = Self.genericContext(activity: activity)
            switch activity.workflowResumeCheckpoint {
            case .recoverRun(let runID)? where runID == run.id:
                guard activity.status == .paused else { return nil }
                self.init(
                    kind: .stepStopped,
                    message: message,
                    handoffText: nil,
                    context: context,
                    isGenericWorkflow: true,
                    isActionable: true
                )
            case .routeCompletedRun(let runID)? where runID == run.id:
                guard activity.status == .paused else { return nil }
                guard run.relayError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                else { return nil }
                if let handoff = run.workflowHandoff {
                    self.init(
                        kind: .workflowPaused,
                        message: message,
                        handoffText: handoff.text,
                        context: context,
                        isGenericWorkflow: true,
                        isActionable: true
                    )
                } else if run.finalOutput?.isEmpty == false {
                    self.init(
                        kind: .handoffFailed,
                        message: message,
                        handoffText: nil,
                        context: context,
                        isGenericWorkflow: true,
                        isActionable: true
                    )
                } else {
                    self.init(
                        kind: .stepStopped,
                        message: message,
                        handoffText: nil,
                        context: context,
                        isGenericWorkflow: true,
                        isActionable: true
                    )
                }
            default:
                guard run.relayError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                else { return nil }
                self.init(
                    kind: .historical,
                    message: message,
                    handoffText: nil,
                    context: context,
                    isGenericWorkflow: true,
                    isActionable: false
                )
            }
            return
        }

        switch activity.resumeCheckpoint {
        case .recoverRun(let runID)? where runID == run.id:
            guard activity.status == .paused else { return nil }
            self.init(
                kind: .stepStopped,
                message: message,
                handoffText: nil,
                nextStepName: Self.legacyNextStepName(after: run.kind),
                isGenericWorkflow: false,
                canFinishWorkflow: run.kind == .fix,
                isActionable: true
            )
        case .routeCompletedRun(let runID)? where runID == run.id:
            guard activity.status == .paused else { return nil }
            guard run.relayError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else { return nil }
            if let handoff = run.handoff {
                self.init(
                    kind: .workflowPaused,
                    message: message,
                    handoffText: handoff.handoffText,
                    nextStepName: Self.legacyNextStepName(after: run.kind),
                    isGenericWorkflow: false,
                    canFinishWorkflow: run.kind == .fix,
                    isActionable: true
                )
            } else if run.finalOutput?.isEmpty == false {
                self.init(
                    kind: .handoffFailed,
                    message: message,
                    handoffText: nil,
                    nextStepName: Self.legacyNextStepName(after: run.kind),
                    isGenericWorkflow: false,
                    canFinishWorkflow: run.kind == .fix,
                    isActionable: true
                )
            } else {
                self.init(
                    kind: .stepStopped,
                    message: message,
                    handoffText: nil,
                    nextStepName: Self.legacyNextStepName(after: run.kind),
                    isGenericWorkflow: false,
                    canFinishWorkflow: run.kind == .fix,
                    isActionable: true
                )
            }
        default:
            guard run.relayError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else { return nil }
            self.init(
                kind: .historical,
                message: message,
                handoffText: nil,
                nextStepName: nil,
                isGenericWorkflow: false,
                canFinishWorkflow: false,
                isActionable: false
            )
        }
    }

    private init(
        kind: Kind,
        message: String,
        handoffText: String?,
        context: GenericContext,
        isGenericWorkflow: Bool,
        isActionable: Bool
    ) {
        self.init(
            kind: kind,
            message: message,
            handoffText: handoffText,
            nextStepName: context.nextStepName,
            isGenericWorkflow: isGenericWorkflow,
            canFinishWorkflow: context.isLoopDecision,
            isActionable: isActionable
        )
    }

    private init(
        kind: Kind,
        message: String,
        handoffText: String?,
        nextStepName: String?,
        isGenericWorkflow: Bool,
        canFinishWorkflow: Bool,
        isActionable: Bool
    ) {
        self.kind = kind
        self.message = message
        self.handoffText = handoffText
        self.nextStepName = nextStepName
        self.isGenericWorkflow = isGenericWorkflow
        self.canFinishWorkflow = canFinishWorkflow
        self.isActionable = isActionable
    }

    private struct GenericContext {
        let nextStepName: String?
        let isLoopDecision: Bool
    }

    private static func genericContext(activity: ActivityRecord) -> GenericContext {
        guard let workflow = activity.workflow,
              let cursor = activity.workflowCursor else {
            return GenericContext(nextStepName: nil, isLoopDecision: false)
        }
        let transition = GenericWorkflowStateMachine.transition(
            after: cursor,
            outcome: .continueWorkflow,
            in: workflow
        )
        let nextStepName: String? = switch transition {
        case .run(let nextCursor):
            GenericWorkflowStateMachine.step(at: nextCursor, in: workflow)?.name
        case .complete, .pause:
            nil
        }
        return GenericContext(
            nextStepName: nextStepName,
            isLoopDecision: GenericWorkflowStateMachine.isLoopDecision(cursor, in: workflow)
        )
    }

    private static func legacyNextStepName(after kind: RunKind) -> String? {
        switch kind {
        case .implementation: "Review"
        case .review: "Fix"
        case .fix: "Implement"
        }
    }

    private static func message(for run: RunRecord) -> String {
        if let error = run.relayError?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            return error
        }
        switch run.status {
        case .interrupted:
            return "The turn was stopped before it finished."
        case .failed:
            return "The turn did not finish."
        default:
            return "The activity needs attention before it can continue."
        }
    }
}
