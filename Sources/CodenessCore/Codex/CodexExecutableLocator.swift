import Foundation

public enum CodexExecutableError: LocalizedError, Sendable {
    case notFound
    case invalidExecutable(String)
    case versionCheckFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Codex was not found. Configure its executable path in Codeness settings."
        case .invalidExecutable(let path):
            "Codex is not executable at \(path)."
        case .versionCheckFailed(let detail):
            "Codex could not be verified: \(detail)"
        }
    }
}

public enum CodexExecutableLocator {
    public static func resolve(configuredPath: String = "") throws -> URL {
        let configuredPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredPath.isEmpty {
            let path = expandTilde(configuredPath)
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw CodexExecutableError.invalidExecutable(path)
            }
            return URL(fileURLWithPath: path)
        }

        let candidates = candidatePaths()
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexExecutableError.notFound
        }
        return URL(fileURLWithPath: path)
    }

    public static func verify(_ executableURL: URL) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexExecutableError.invalidExecutable(executableURL.path)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = processEnvironment()
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, output.contains("codex-cli") else {
            throw CodexExecutableError.versionCheckFailed(error.isEmpty ? output : error)
        }
        return output
    }

    public static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let knownPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = (knownPaths + [existingPath])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        return environment
    }

    private static func candidatePaths() -> [String] {
        var candidates: [String] = []
        if let environmentPath = ProcessInfo.processInfo.environment["CODEX_BIN_PATH"], !environmentPath.isEmpty {
            candidates.append(expandTilde(environmentPath))
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ])
        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    private static func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}
