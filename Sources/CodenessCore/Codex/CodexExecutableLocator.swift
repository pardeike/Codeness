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
    private static let loginShellEnvironment = loadLoginShellEnvironment(
        baseEnvironment: ProcessInfo.processInfo.environment
    )

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
        processEnvironment(
            baseEnvironment: ProcessInfo.processInfo.environment,
            loginShellEnvironment: loginShellEnvironment
        )
    }

    static func processEnvironment(
        baseEnvironment: [String: String],
        loginShellEnvironment: [String: String]?
    ) -> [String: String] {
        var environment = loginShellEnvironment ?? [:]
        for key in ["PWD", "OLDPWD", "SHLVL", "_"] {
            environment.removeValue(forKey: key)
        }
        environment.merge(baseEnvironment) { _, processValue in processValue }

        let knownPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let pathSources: [String]
        if let loginPath = loginShellEnvironment?["PATH"], !loginPath.isEmpty {
            pathSources = [loginPath, baseEnvironment["PATH"] ?? ""]
                + knownPaths
        } else {
            pathSources = knownPaths + [baseEnvironment["PATH"] ?? ""]
        }
        environment["PATH"] = uniquePathComponents(pathSources)
            .joined(separator: ":")
        return environment
    }

    private static func loadLoginShellEnvironment(
        baseEnvironment: [String: String]
    ) -> [String: String]? {
        let configuredShell = baseEnvironment["SHELL"] ?? ""
        let shellPath = FileManager.default.isExecutableFile(atPath: configuredShell)
            ? configuredShell
            : "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shellPath) else {
            return nil
        }

        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = [
            "-lc",
            #"/usr/bin/printf '\000CODENESS_ENV\000'; /usr/bin/env -0"#
        ]
        process.environment = baseEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return parseLoginShellEnvironment(data)
        } catch {
            return nil
        }
    }

    private static func parseLoginShellEnvironment(
        _ data: Data
    ) -> [String: String]? {
        let marker = Data([0])
            + Data("CODENESS_ENV".utf8)
            + Data([0])
        guard let markerRange = data.range(of: marker) else { return nil }

        var environment: [String: String] = [:]
        for entry in data[markerRange.upperBound...].split(separator: 0) {
            guard let separator = entry.firstIndex(of: 61) else { continue }
            let key = String(decoding: entry[..<separator], as: UTF8.self)
            guard !key.isEmpty else { continue }
            environment[key] = String(
                decoding: entry[entry.index(after: separator)...],
                as: UTF8.self
            )
        }
        return environment.isEmpty ? nil : environment
    }

    private static func uniquePathComponents(
        _ sources: [String]
    ) -> [String] {
        var seen: Set<String> = []
        return sources
            .flatMap { $0.split(separator: ":").map(String.init) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
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
