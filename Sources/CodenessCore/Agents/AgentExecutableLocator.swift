import Foundation

public enum AgentExecutableError: LocalizedError, Sendable {
    case notFound(provider: String)
    case invalidExecutable(provider: String, path: String)
    case versionCheckFailed(provider: String, detail: String)
    case versionCheckTerminated(
        provider: String,
        termination: SubprocessTermination,
        detail: String
    )
    case versionTooOld(provider: String, installed: String, minimum: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let provider):
            return "\(provider) was not found. Configure its executable path in Codeness settings."
        case .invalidExecutable(let provider, let path):
            return "\(provider) is not executable at \(path)."
        case .versionCheckFailed(let provider, let detail):
            return "\(provider) could not be verified: \(detail)"
        case .versionCheckTerminated(let provider, let termination, let detail):
            let summary = termination.userFacingDescription(
                subject: provider,
                context: "while Codeness was verifying it"
            )
            return detail.isEmpty ? summary : "\(summary) \(detail)"
        case .versionTooOld(let provider, let installed, let minimum):
            return "\(provider) \(installed) is too old. Codeness requires \(minimum) or later."
        }
    }
}

public enum AgentExecutableLocator {
    public static func resolve(
        configuredPath: String,
        descriptor: AgentProviderDescriptor,
        environment: [String: String] = CodexExecutableLocator.processEnvironment()
    ) throws -> URL {
        let configuredPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredPath.isEmpty {
            let path = expandTilde(configuredPath)
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw AgentExecutableError.invalidExecutable(
                    provider: descriptor.displayName,
                    path: path
                )
            }
            return URL(fileURLWithPath: path)
        }

        var candidates: [String] = []
        let environmentKey = "\(descriptor.id.rawValue.uppercased())_BIN_PATH"
        if let override = environment[environmentKey], !override.isEmpty {
            candidates.append(expandTilde(override))
        }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                "\($0)/\(descriptor.executableName)"
            })
        }
        candidates.append(contentsOf: descriptor.executableSearchPaths.map(expandTilde))
        let uniqueCandidates = Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
        guard let path = uniqueCandidates.first(where: FileManager.default.isExecutableFile) else {
            throw AgentExecutableError.notFound(provider: descriptor.displayName)
        }
        return URL(fileURLWithPath: path)
    }

    public static func verify(
        _ executableURL: URL,
        descriptor: AgentProviderDescriptor,
        environment: [String: String] = CodexExecutableLocator.processEnvironment(),
        timeout: Duration = .seconds(5),
        maximumOutputByteCount: Int = 1 * 1_024 * 1_024
    ) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AgentExecutableError.invalidExecutable(
                provider: descriptor.displayName,
                path: executableURL.path
            )
        }

        let result: BoundedOwnedProcessResult
        do {
            result = try await BoundedOwnedProcessRunner.run(
                configuration: SupervisedProcessLaunchConfiguration(
                    executableURL: executableURL,
                    arguments: ["--version"],
                    environment: environment
                ),
                timeout: timeout,
                maximumStandardOutputByteCount: maximumOutputByteCount,
                maximumStandardErrorByteCount: maximumOutputByteCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentExecutableError.versionCheckFailed(
                provider: descriptor.displayName,
                detail: error.localizedDescription
            )
        }
        let output = String(
            decoding: result.standardOutput,
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let error = String(
            decoding: result.standardError,
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.termination.succeeded else {
            throw AgentExecutableError.versionCheckTerminated(
                provider: descriptor.displayName,
                termination: result.termination,
                detail: error.isEmpty ? output : error
            )
        }
        guard !output.isEmpty else {
            throw AgentExecutableError.versionCheckFailed(
                provider: descriptor.displayName,
                detail: error.isEmpty
                    ? "the executable returned no version information"
                    : error
            )
        }
        try validateVersion(output, descriptor: descriptor)
        return output
    }

    public static func validateVersion(
        _ versionOutput: String,
        descriptor: AgentProviderDescriptor
    ) throws {
        guard let minimum = descriptor.minimumVersion, !minimum.isEmpty else { return }
        guard let installedComponents = versionComponents(in: versionOutput),
              let minimumComponents = versionComponents(in: minimum) else {
            throw AgentExecutableError.versionCheckFailed(
                provider: descriptor.displayName,
                detail: "could not read a semantic version from “\(versionOutput)”"
            )
        }
        let width = max(installedComponents.count, minimumComponents.count)
        let installed = installedComponents + repeatElement(
            0,
            count: width - installedComponents.count
        )
        let required = minimumComponents + repeatElement(
            0,
            count: width - minimumComponents.count
        )
        if installed.lexicographicallyPrecedes(required) {
            throw AgentExecutableError.versionTooOld(
                provider: descriptor.displayName,
                installed: installedComponents.map(String.init).joined(separator: "."),
                minimum: minimum
            )
        }
    }

    private static func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func versionComponents(in text: String) -> [Int]? {
        let pattern = #"\d+(?:\.\d+)+"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range, in: text) else {
            return nil
        }
        let components = text[range].split(separator: ".").compactMap {
            Int($0)
        }
        return components.isEmpty ? nil : components
    }
}
