import Foundation

public enum CodexExecutableError: LocalizedError, Sendable {
    case notFound
    case invalidExecutable(String)
    case versionCheckFailed(String)
    case versionCheckTerminated(
        termination: SubprocessTermination,
        detail: String
    )

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "Codex was not found. Configure its executable path in Codeness settings."
        case .invalidExecutable(let path):
            return "Codex is not executable at \(path)."
        case .versionCheckFailed(let detail):
            return "Codex could not be verified: \(detail)"
        case .versionCheckTerminated(let termination, let detail):
            let summary = termination.userFacingDescription(
                subject: "Codex",
                context: "while Codeness was verifying it"
            )
            return detail.isEmpty ? summary : "\(summary) \(detail)"
        }
    }
}

public enum CodexExecutableLocator {
    private static let processEnvironmentCache = ProcessEnvironmentCache()
    private static let loginShellLoader = LoginShellEnvironmentLoader()

    public static func resolve(configuredPath: String = "") throws -> URL {
        let configuredPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredPath.isEmpty {
            let path = expandTilde(configuredPath)
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw CodexExecutableError.invalidExecutable(path)
            }
            return URL(fileURLWithPath: path)
        }

        let candidates = candidatePaths(environment: processEnvironment())
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexExecutableError.notFound
        }
        return URL(fileURLWithPath: path)
    }

    public static func verify(
        _ executableURL: URL,
        timeout: Duration = .seconds(5),
        maximumOutputByteCount: Int = 1 * 1_024 * 1_024
    ) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexExecutableError.invalidExecutable(executableURL.path)
        }

        let result: BoundedOwnedProcessResult
        do {
            result = try await BoundedOwnedProcessRunner.run(
                configuration: SupervisedProcessLaunchConfiguration(
                    executableURL: executableURL,
                    arguments: ["--version"],
                    environment: processEnvironment()
                ),
                timeout: timeout,
                maximumStandardOutputByteCount: maximumOutputByteCount,
                maximumStandardErrorByteCount: maximumOutputByteCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexExecutableError.versionCheckFailed(error.localizedDescription)
        }
        let output = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let error = String(decoding: result.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.termination.succeeded else {
            throw CodexExecutableError.versionCheckTerminated(
                termination: result.termination,
                detail: error.isEmpty ? output : error
            )
        }
        guard output.contains("codex-cli") else {
            throw CodexExecutableError.versionCheckFailed(error.isEmpty ? output : error)
        }
        return output
    }

    public static func processEnvironment() -> [String: String] {
        processEnvironment(
            baseEnvironment: ProcessInfo.processInfo.environment,
            loginShellEnvironment: processEnvironmentCache.value
        )
    }

    /// Loads the user's login-shell environment through the same bounded,
    /// descendant-owned runner used for executable verification. App lifecycle
    /// code invokes this while holding its launch lease; cancellation therefore
    /// cannot leave an untracked shell or cache a partial environment.
    public static func prepareProcessEnvironment() async throws {
        let environment = try await loginShellLoader.load(
            baseEnvironment: ProcessInfo.processInfo.environment
        )
        processEnvironmentCache.store(environment)
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

    private static func uniquePathComponents(
        _ sources: [String]
    ) -> [String] {
        var seen: Set<String> = []
        return sources
            .flatMap { $0.split(separator: ":").map(String.init) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func candidatePaths(environment: [String: String]) -> [String] {
        var candidates: [String] = []
        if let environmentPath = environment["CODEX_BIN_PATH"], !environmentPath.isEmpty {
            candidates.append(expandTilde(environmentPath))
        }
        if let path = environment["PATH"] {
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

private final class ProcessEnvironmentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: [String: String]?

    var value: [String: String]? {
        lock.withLock { storedValue }
    }

    func store(_ value: [String: String]?) {
        lock.withLock { storedValue = value }
    }
}

actor LoginShellEnvironmentLoader {
    private struct InFlightLoad {
        let identifier: UUID
        let task: Task<[String: String]?, any Error>
    }

    private var cachedEnvironment: [String: String]?
    private var inFlightLoad: InFlightLoad?

    func load(baseEnvironment: [String: String]) async throws -> [String: String]? {
        if let cachedEnvironment { return cachedEnvironment }
        if let inFlightLoad {
            return try await Self.value(
                of: inFlightLoad.task
            )
        }
        let identifier = UUID()
        let task = Task {
            try await Self.loadFresh(baseEnvironment: baseEnvironment)
        }
        inFlightLoad = InFlightLoad(identifier: identifier, task: task)
        do {
            let environment = try await Self.value(of: task)
            if inFlightLoad?.identifier == identifier {
                inFlightLoad = nil
                if let environment {
                    cachedEnvironment = environment
                }
            }
            return environment
        } catch {
            if inFlightLoad?.identifier == identifier {
                inFlightLoad = nil
            }
            throw error
        }
    }

    private nonisolated static func value(
        of task: Task<[String: String]?, any Error>
    ) async throws -> [String: String]? {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func loadFresh(
        baseEnvironment: [String: String]
    ) async throws -> [String: String]? {
        let configuredShell = baseEnvironment["SHELL"] ?? ""
        let shellPath = FileManager.default.isExecutableFile(atPath: configuredShell)
            ? configuredShell
            : "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shellPath) else { return nil }

        do {
            let sentinel = "CODENESS_ENV_\(UUID().uuidString)"
            let result = try await BoundedOwnedProcessRunner.run(
                configuration: SupervisedProcessLaunchConfiguration(
                    executableURL: URL(fileURLWithPath: shellPath),
                    arguments: [
                        "-lic",
                        "/usr/bin/printf '\\000\(sentinel)\\000'; /usr/bin/env -0"
                    ],
                    environment: baseEnvironment
                ),
                timeout: .seconds(5),
                maximumStandardOutputByteCount: 4 * 1_024 * 1_024,
                maximumStandardErrorByteCount: 1 * 1_024 * 1_024
            )
            try Task.checkCancellation()
            guard result.termination.succeeded else { return nil }
            // Cache only a fully parsed success. Timeout, nonzero exit, or
            // malformed/contaminated output remains retryable from Settings.
            return parse(result.standardOutput, sentinel: sentinel)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // A malformed shell profile must not make Codeness unusable. The
            // base process environment plus known executable paths remains the
            // deterministic fallback.
            return nil
        }
    }

    private nonisolated static func parse(
        _ data: Data,
        sentinel: String
    ) -> [String: String]? {
        let marker = Data([0]) + Data(sentinel.utf8) + Data([0])
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
}
