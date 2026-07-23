import Foundation

public enum WorkflowDecision: Sendable, Equatable {
    case continueWith(PendingAction)
    case pause(String)
}

public enum WorkflowStateMachine {
    public static func decision(
        after kind: RunKind,
        disposition: SourceDisposition
    ) -> WorkflowDecision {
        switch disposition {
        case .blocked:
            return .pause("The session reported that it is blocked.")
        case .failed:
            return .pause("The session reported a failure.")
        case .unclear:
            return .pause("The relay could not determine the source session's completion state.")
        default:
            break
        }

        switch (kind, disposition) {
        case (.implementation, .implementationCheckpoint), (.implementation, .implementationComplete):
            return .continueWith(.review)
        case (.review, .reviewComplete):
            return .continueWith(.fix)
        case (.fix, .fixCheckpoint):
            return .continueWith(.implement)
        case (.fix, .fixComplete):
            return .continueWith(.complete)
        default:
            return .pause("The relay state \(disposition.displayName) is not valid after \(kind.displayName).")
        }
    }
}
