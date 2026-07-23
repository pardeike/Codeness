import Foundation

enum WorkflowTransportControl: Equatable {
    case resume
    case pauseAfterCurrent
    case keepRunning

    var title: String {
        switch self {
        case .resume: "Resume Automatically"
        case .pauseAfterCurrent: "Pause After Current"
        case .keepRunning: "Keep Running Automatically"
        }
    }

    var systemImage: String {
        switch self {
        case .resume: "play.fill"
        case .pauseAfterCurrent: "pause.circle"
        case .keepRunning: "arrow.forward.circle"
        }
    }

    var help: String {
        switch self {
        case .resume:
            "Resume from the saved checkpoint and continue subsequent phases automatically"
        case .pauseAfterCurrent:
            "Pause the workflow after the current run reaches a safe stopping point"
        case .keepRunning:
            "Cancel the pending pause and continue automatically after this run"
        }
    }
}

struct WorkflowControlPresentation: Equatable {
    let transport: WorkflowTransportControl?
    let showsInterrupt: Bool

    init(
        canResume: Bool,
        isActivityRunning: Bool,
        pauseAfterCurrent: Bool,
        canInterrupt: Bool
    ) {
        if canResume {
            transport = .resume
        } else if isActivityRunning {
            transport = pauseAfterCurrent ? .keepRunning : .pauseAfterCurrent
        } else {
            transport = nil
        }
        showsInterrupt = canInterrupt
    }

    var isVisible: Bool {
        transport != nil || showsInterrupt
    }
}
