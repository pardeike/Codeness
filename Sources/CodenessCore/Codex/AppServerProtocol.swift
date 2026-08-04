import Foundation

public enum AppServerEvent: Sendable, Equatable {
    case notification(method: String, params: JSONValue, rawLine: String)
    case request(id: JSONValue, method: String, params: JSONValue, rawLine: String)
    case standardError(String)
    case exited(SubprocessTermination)

    public var threadID: String? {
        switch self {
        case .notification(_, let params, _), .request(_, _, let params, _):
            params["threadId"]?.stringValue
        case .standardError, .exited:
            nil
        }
    }

    public var turnID: String? {
        switch self {
        case .notification(_, let params, _), .request(_, _, let params, _):
            params["turnId"]?.stringValue ?? params["turn"]?["id"]?.stringValue
        case .standardError, .exited:
            nil
        }
    }

    public var rawLine: String? {
        switch self {
        case .notification(_, _, let rawLine), .request(_, _, _, let rawLine): rawLine
        case .standardError, .exited: nil
        }
    }
}

/// An App Server event tagged at transport admission with the isolated process
/// generation that produced it. Consumers must retain this envelope through
/// dispatch so a queued event from a stopped generation cannot mutate state
/// belonging to a replacement process.
public struct AppServerTransportEvent: Sendable, Equatable {
    public let generation: Int64
    public let event: AppServerEvent

    public init(generation: Int64, event: AppServerEvent) {
        self.generation = generation
        self.event = event
    }
}

public struct AppServerEventRoutingPause: Sendable, Hashable {
    let identifier: UUID

    init(identifier: UUID) {
        self.identifier = identifier
    }
}

public enum AppServerClientError: LocalizedError, Sendable {
    case alreadyRunning
    case notRunning
    case invalidResponse(String)
    case requestFailed(code: Int64?, message: String)
    case requestTimedOut(method: String)
    case processExited(SubprocessTermination)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Codex App Server is already running."
        case .notRunning: "Codex App Server is not running."
        case .invalidResponse(let detail): "Codex App Server returned an invalid response: \(detail)"
        case .requestFailed(let code, let message):
            code.map { "Codex App Server request failed (\($0)): \(message)" } ?? "Codex App Server request failed: \(message)"
        case .requestTimedOut(let method):
            "Codex App Server did not respond to \(method) before the request deadline."
        case .processExited(let termination):
            termination.userFacingDescription(subject: "Codex App Server")
        }
    }
}

public struct CodexLaunchConfiguration: Sendable, Equatable {
    public static let codenessAppServerArguments = [
        "-c", "shell_environment_policy.inherit=all",
        "-c", "shell_environment_policy.experimental_use_profile=true",
        "app-server", "--stdio"
    ]

    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]

    public init(
        executableURL: URL,
        arguments: [String] = CodexLaunchConfiguration.codenessAppServerArguments,
        environment: [String: String] = CodexExecutableLocator.processEnvironment()
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }
}
