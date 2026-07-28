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

    var buttonTitle: String {
        switch self {
        case .resume: "Resume"
        case .pauseAfterCurrent: "Pause"
        case .keepRunning: "Continue"
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

    var emphasis: Emphasis {
        switch self {
        case .pauseAfterCurrent: .caution
        case .resume, .keepRunning: .proceed
        }
    }

    var pauseNotice: String? {
        self == .keepRunning
            ? "Finishing this step, then pausing"
            : nil
    }

    enum Emphasis: Equatable {
        case caution
        case proceed
    }
}

enum WorkflowImmediateControl: Equatable {
    case stopCurrentStep

    var buttonTitle: String {
        "Stop Now"
    }

    var menuTitle: String {
        "Stop Current Step"
    }

    var accessibilityLabel: String {
        "Stop Current Step Now"
    }

    var help: String {
        "Stop the current agent now. You can resume or restart this step afterward."
    }
}

struct WorkflowControlPresentation: Equatable {
    let transport: WorkflowTransportControl?
    let immediateControl: WorkflowImmediateControl?

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
        immediateControl = canInterrupt ? .stopCurrentStep : nil
    }

    var isVisible: Bool {
        transport != nil || immediateControl != nil
    }
}
