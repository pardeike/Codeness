import Foundation

public enum GitRepositoryError: LocalizedError, Sendable {
    case notDirectory(String)
    case notRepository(String)
    case gitFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notDirectory(let path): "The selected path is not a directory: \(path)"
        case .notRepository(let path): "The selected directory is not inside a Git repository: \(path)"
        case .gitFailed(let detail): "Git could not resolve the repository: \(detail)"
        }
    }
}

public actor GitRepositoryResolver {
    public init() {}

    public func canonicalWorkspace(for selectedURL: URL) throws -> URL {
        let workspaceURL = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try workspaceURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw GitRepositoryError.notDirectory(workspaceURL.path)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", workspaceURL.path, "rev-parse", "--is-inside-work-tree"]
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw GitRepositoryError.gitFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            if error.contains("not a git repository") {
                throw GitRepositoryError.notRepository(workspaceURL.path)
            }
            throw GitRepositoryError.gitFailed(error)
        }
        guard output == "true" else { throw GitRepositoryError.notRepository(workspaceURL.path) }
        return workspaceURL
    }
}
