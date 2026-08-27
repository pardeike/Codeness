import Foundation

public enum WorkspaceResolutionError: LocalizedError, Sendable {
    case notDirectory(String)
    case alreadyExists(String)
    case couldNotCreate(String, String)
    case gitInitializationFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .notDirectory(let path): "The selected path is not a directory: \(path)"
        case .alreadyExists(let path):
            "A file or folder already exists at \(path). Choose a new project name."
        case .couldNotCreate(let path, let reason):
            "Codeness could not create the project folder at \(path): \(reason)"
        case .gitInitializationFailed(let path, let reason):
            "Codeness could not initialize Git in \(path): \(reason)"
        }
    }
}

public actor WorkspaceResolver {
    public init() {}

    public func canonicalWorkspace(for selectedURL: URL) throws -> URL {
        let workspaceURL = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        let resourceValues = try? workspaceURL.resourceValues(forKeys: [.isDirectoryKey])
        guard resourceValues?.isDirectory == true else {
            throw WorkspaceResolutionError.notDirectory(workspaceURL.path)
        }
        try initializeGitIfNeeded(at: workspaceURL)
        return workspaceURL
    }

    public func createWorkspace(at selectedURL: URL) throws -> URL {
        let parentURL = selectedURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let workspaceURL = parentURL.appendingPathComponent(
            selectedURL.lastPathComponent,
            isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: workspaceURL.path) else {
            throw WorkspaceResolutionError.alreadyExists(workspaceURL.path)
        }
        do {
            try FileManager.default.createDirectory(
                at: workspaceURL,
                withIntermediateDirectories: false
            )
        } catch {
            throw WorkspaceResolutionError.couldNotCreate(
                workspaceURL.path,
                error.localizedDescription
            )
        }
        do {
            return try canonicalWorkspace(for: workspaceURL)
        } catch {
            try? FileManager.default.removeItem(at: workspaceURL)
            throw error
        }
    }

    private func initializeGitIfNeeded(at workspaceURL: URL) throws {
        let probe = try git(
            arguments: ["-C", workspaceURL.path, "rev-parse", "--git-dir"],
            workspacePath: workspaceURL.path
        )
        guard probe.status != 0 else { return }

        let initialization = try git(
            arguments: ["-C", workspaceURL.path, "init", "--quiet"],
            workspacePath: workspaceURL.path
        )
        guard initialization.status == 0 else {
            throw WorkspaceResolutionError.gitInitializationFailed(
                workspaceURL.path,
                initialization.output.isEmpty
                    ? "git exited with status \(initialization.status)"
                    : initialization.output
            )
        }
    }

    private func git(
        arguments: [String],
        workspacePath: String
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            throw WorkspaceResolutionError.gitInitializationFailed(
                workspacePath,
                error.localizedDescription
            )
        }
        process.waitUntilExit()
        let output = [standardOutput, standardError]
            .compactMap { try? $0.fileHandleForReading.readToEnd() }
            .compactMap { $0 }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}
