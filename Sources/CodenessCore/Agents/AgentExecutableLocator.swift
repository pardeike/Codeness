import Foundation

public enum AgentExecutableError: LocalizedError, Sendable {
    case notFound(provider: String)
    case invalidExecutable(provider: String, path: String)
    case versionCheckFailed(provider: String, detail: String)
    case versionTooOld(provider: String, installed: String, minimum: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let provider):
            "\(provider) was not found. Configure its executable path in Codeness settings."
        case .invalidExecutable(let provider, let path):
            "\(provider) is not executable at \(path)."
        case .versionCheckFailed(let provider, let detail):
            "\(provider) could not be verified: \(detail)"
        case .versionTooOld(let provider, let installed, let minimum):
            "\(provider) \(installed) is too old. Codeness requires \(minimum) or later."
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
        environment: [String: String] = CodexExecutableLocator.processEnvironment()
    ) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AgentExecutableError.invalidExecutable(
                provider: descriptor.displayName,
                path: executableURL.path
            )
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let error = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !output.isEmpty else {
            throw AgentExecutableError.versionCheckFailed(
                provider: descriptor.displayName,
                detail: error.isEmpty ? output : error
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
