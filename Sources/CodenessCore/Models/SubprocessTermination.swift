import Darwin
import Foundation

public struct SubprocessTermination: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case exit
        case uncaughtSignal
    }

    public let reason: Reason
    public let status: Int32

    public init(reason: Reason, status: Int32) {
        self.reason = reason
        self.status = status
    }

    public init(process: Process) {
        reason = switch process.terminationReason {
        case .exit: .exit
        case .uncaughtSignal: .uncaughtSignal
        @unknown default: .exit
        }
        status = process.terminationStatus
    }

    public var succeeded: Bool {
        reason == .exit && status == 0
    }

    public func userFacingDescription(
        subject: String,
        context: String? = nil
    ) -> String {
        let action: String
        switch reason {
        case .exit:
            action = status == 0 ? "stopped" : "stopped unexpectedly"
        case .uncaughtSignal:
            action = switch status {
            case SIGTERM: "was stopped"
            case SIGINT: "was interrupted"
            case SIGKILL: "was forcibly stopped"
            case SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP:
                "crashed"
            case SIGPIPE:
                "lost its connection and stopped"
            default:
                "stopped unexpectedly"
            }
        }
        let contextSuffix = context.map { " \($0)" } ?? ""
        return "\(subject) \(action)\(contextSuffix)."
    }

    public func diagnosticDescription(subject: String) -> String {
        switch reason {
        case .exit:
            "\(subject) exited with status \(status)."
        case .uncaughtSignal:
            if let signalName {
                "\(subject) was terminated by signal \(status) (\(signalName))."
            } else {
                "\(subject) was terminated by signal \(status)."
            }
        }
    }

    private var signalName: String? {
        switch status {
        case SIGHUP: "SIGHUP"
        case SIGINT: "SIGINT"
        case SIGQUIT: "SIGQUIT"
        case SIGILL: "SIGILL"
        case SIGTRAP: "SIGTRAP"
        case SIGABRT: "SIGABRT"
        case SIGEMT: "SIGEMT"
        case SIGFPE: "SIGFPE"
        case SIGKILL: "SIGKILL"
        case SIGBUS: "SIGBUS"
        case SIGSEGV: "SIGSEGV"
        case SIGSYS: "SIGSYS"
        case SIGPIPE: "SIGPIPE"
        case SIGALRM: "SIGALRM"
        case SIGTERM: "SIGTERM"
        default: nil
        }
    }
}
