import CodenessCore
import Foundation

struct RunLiveStatusPresentation: Equatable {
    enum Tone: Equatable {
        case active
        case attention
    }

    let text: String
    let showsProgress: Bool
    let systemImage: String?
    let tone: Tone

    init?(
        run: RunRecord,
        liveRunID: UUID?,
        pauseAfterCurrent: Bool,
        pausedWorkflowMessage: String? = nil
    ) {
        guard run.id == liveRunID else {
            guard let pausedWorkflowMessage,
                  !pausedWorkflowMessage.isEmpty
            else {
                return nil
            }
            text = pausedWorkflowMessage
            showsProgress = false
            systemImage = "pause.circle.fill"
            tone = .attention
            return
        }

        switch run.status {
        case .queued:
            text = "Starting"
            showsProgress = true
            systemImage = nil
            tone = .active
        case .running where pauseAfterCurrent:
            text = WorkflowTransportControl.keepRunning.pauseNotice
                ?? "Finishing this turn, then pausing"
            showsProgress = true
            systemImage = nil
            tone = .attention
        case .running:
            text = "Running"
            showsProgress = true
            systemImage = nil
            tone = .active
        case .routing:
            text = "Preparing handoff"
            showsProgress = true
            systemImage = nil
            tone = .attention
        case .awaitingApproval:
            text = "Waiting for input"
            showsProgress = false
            systemImage = "questionmark.circle.fill"
            tone = .attention
        case .paused:
            text = "Paused"
            showsProgress = false
            systemImage = "pause.circle.fill"
            tone = .attention
        case .completed, .interrupted, .failed:
            return nil
        }
    }
}
