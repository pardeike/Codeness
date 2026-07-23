import CryptoKit
import Foundation

public protocol RepositoryWorkspaceStoring: Sendable {
    func load(canonicalPath: String, defaultSettings: RepositorySettings) async throws -> RepositoryRecord
    func save(_ record: RepositoryRecord) async throws
    func archiveActivity(_ record: RepositoryRecord) async throws
    func loadViewState(canonicalPath: String) async throws -> RepositoryViewState
    func saveViewState(_ state: RepositoryViewState, canonicalPath: String) async throws
    func appendRawLine(
        _ line: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws
    func appendTranscript(
        _ text: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws
    func recoveredTranscript(repositoryPath: String, activityID: UUID, runID: UUID) async throws -> String
    func recoveredTokenUsage(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> RunTokenUsage?
}

public actor WorkspaceStore: RepositoryWorkspaceStoring {
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? Self.defaultRootURL()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    public func load(
        canonicalPath: String,
        defaultSettings: RepositorySettings = .init()
    ) throws -> RepositoryRecord {
        let url = workspaceURL(canonicalPath: canonicalPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RepositoryRecord(canonicalPath: canonicalPath, settings: defaultSettings)
        }
        return try decoder.decode(RepositoryRecord.self, from: Data(contentsOf: url))
    }

    public func save(_ record: RepositoryRecord) throws {
        let directory = repositoryDirectory(canonicalPath: record.canonicalPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(record)
        try data.write(to: directory.appendingPathComponent("workspace.json"), options: .atomic)
    }

    public func archiveActivity(_ record: RepositoryRecord) throws {
        guard let activity = record.activity else {
            throw WorkspaceStoreError.missingActivityToArchive
        }
        let directory = repositoryDirectory(canonicalPath: record.canonicalPath)
            .appendingPathComponent("activity-archives", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(record)
        try data.write(
            to: directory.appendingPathComponent("\(activity.id.uuidString).json"),
            options: .atomic
        )
    }

    public func loadViewState(canonicalPath: String) throws -> RepositoryViewState {
        let url = viewStateURL(canonicalPath: canonicalPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RepositoryViewState()
        }
        return try decoder.decode(RepositoryViewState.self, from: Data(contentsOf: url))
    }

    public func saveViewState(_ state: RepositoryViewState, canonicalPath: String) throws {
        let directory = repositoryDirectory(canonicalPath: canonicalPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(state).write(
            to: directory.appendingPathComponent("view-state.json"),
            options: .atomic
        )
    }

    public func loadOpenDocumentPaths() throws -> [String] {
        let url = rootURL.appendingPathComponent("open-documents.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([String].self, from: Data(contentsOf: url))
    }

    public func saveOpenDocumentPaths(_ paths: [String]) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try encoder.encode(paths).write(
            to: rootURL.appendingPathComponent("open-documents.json"),
            options: .atomic
        )
    }

    public func loadRecentRepositoryPaths() throws -> [String] {
        let url = rootURL.appendingPathComponent("recent-repositories.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([String].self, from: Data(contentsOf: url))
    }

    public func saveRecentRepositoryPaths(_ paths: [String]) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try encoder.encode(paths).write(
            to: rootURL.appendingPathComponent("recent-repositories.json"),
            options: .atomic
        )
    }

    public func appendRawLine(_ line: String, repositoryPath: String, activityID: UUID, runID: UUID) throws {
        try append(line + "\n", to: logURL(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID,
            suffix: "raw.jsonl"
        ))
    }

    public func appendTranscript(_ text: String, repositoryPath: String, activityID: UUID, runID: UUID) throws {
        guard !text.isEmpty else { return }
        try append(text, to: logURL(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID,
            suffix: "transcript.txt"
        ))
    }

    public func recoveredTranscript(repositoryPath: String, activityID: UUID, runID: UUID) throws -> String {
        let url = logURL(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID,
            suffix: "transcript.txt"
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    public func recoveredTokenUsage(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) throws -> RunTokenUsage? {
        let url = logURL(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID,
            suffix: "raw.jsonl"
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var baseline: RunTokenUsage?
        var latestTotal: RunTokenUsage?
        let contents = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        for line in contents.split(whereSeparator: \.isNewline) {
            guard line.contains("tokenUsage"),
                  let event = try? decoder.decode(
                    JSONValue.self,
                    from: Data(line.utf8)
                  ),
                  event["method"]?.stringValue == "thread/tokenUsage/updated",
                  let usage = event["params"]?["tokenUsage"],
                  let total = RunTokenUsage(appServerValue: usage["total"]),
                  let last = RunTokenUsage(appServerValue: usage["last"]) else {
                continue
            }
            if baseline == nil {
                baseline = total.subtracting(last)
            }
            latestTotal = total
        }

        guard let baseline, let latestTotal else { return nil }
        return latestTotal.subtracting(baseline)
    }

    public func repositoryDirectory(canonicalPath: String) -> URL {
        rootURL.appendingPathComponent(Self.pathKey(canonicalPath), isDirectory: true)
    }

    public static func pathKey(_ path: String) -> String {
        let digits = Array("0123456789abcdef".utf8)
        let bytes = SHA256.hash(data: Data(path.utf8)).flatMap { byte in
            [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func workspaceURL(canonicalPath: String) -> URL {
        repositoryDirectory(canonicalPath: canonicalPath).appendingPathComponent("workspace.json")
    }

    private func viewStateURL(canonicalPath: String) -> URL {
        repositoryDirectory(canonicalPath: canonicalPath).appendingPathComponent("view-state.json")
    }

    private func logURL(repositoryPath: String, activityID: UUID, runID: UUID, suffix: String) -> URL {
        repositoryDirectory(canonicalPath: repositoryPath)
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent(activityID.uuidString, isDirectory: true)
            .appendingPathComponent("\(runID.uuidString).\(suffix)")
    }

    private func append(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private static func defaultRootURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("Codeness", isDirectory: true)
    }
}

private enum WorkspaceStoreError: LocalizedError {
    case missingActivityToArchive

    var errorDescription: String? {
        switch self {
        case .missingActivityToArchive:
            "There is no activity to archive."
        }
    }
}
