import Foundation

public enum AppServerEvent: Sendable, Equatable {
    case notification(method: String, params: JSONValue, rawLine: String)
    case request(id: JSONValue, method: String, params: JSONValue, rawLine: String)
    case standardError(String)
    case exited(Int32)

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

public enum AppServerClientError: LocalizedError, Sendable {
    case alreadyRunning
    case notRunning
    case invalidResponse(String)
    case requestFailed(code: Int64?, message: String)
    case processExited(Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Codex App Server is already running."
        case .notRunning: "Codex App Server is not running."
        case .invalidResponse(let detail): "Codex App Server returned an invalid response: \(detail)"
        case .requestFailed(let code, let message):
            code.map { "Codex App Server request failed (\($0)): \(message)" } ?? "Codex App Server request failed: \(message)"
        case .processExited(let status): "Codex App Server exited with status \(status)."
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
