import Foundation

public enum WorkspaceResolutionError: LocalizedError, Sendable {
    case notDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .notDirectory(let path): "The selected path is not a directory: \(path)"
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
        return workspaceURL
    }
}
