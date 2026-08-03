import AppleArchive
import Foundation
import System

public struct WorkspaceTransferManifest: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let exportedAt: Date
    public let sourceAppVersion: String
    public let sourceAppBuild: String
    public let repositoryID: UUID
    public let repositoryName: String
    public let originalCanonicalPath: String

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        exportedAt: Date = .now,
        sourceAppVersion: String,
        sourceAppBuild: String,
        repositoryID: UUID,
        repositoryName: String,
        originalCanonicalPath: String
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.sourceAppVersion = sourceAppVersion
        self.sourceAppBuild = sourceAppBuild
        self.repositoryID = repositoryID
        self.repositoryName = repositoryName
        self.originalCanonicalPath = originalCanonicalPath
    }
}

public struct WorkspaceTransferPreview: Sendable, Equatable {
    public let manifest: WorkspaceTransferManifest
    public let record: RepositoryRecord

    public init(manifest: WorkspaceTransferManifest, record: RepositoryRecord) {
        self.manifest = manifest
        self.record = record
    }
}

public struct WorkspaceImportResult: Sendable, Equatable {
    public let manifest: WorkspaceTransferManifest
    public let record: RepositoryRecord
    public let backupURL: URL?

    public init(
        manifest: WorkspaceTransferManifest,
        record: RepositoryRecord,
        backupURL: URL?
    ) {
        self.manifest = manifest
        self.record = record
        self.backupURL = backupURL
    }
}

public enum WorkspaceTransferError: LocalizedError, Sendable, Equatable {
    case missingWorkspace(String)
    case unsupportedFormat(Int)
    case invalidArchive(String)
    case destinationExists(String)
    case archiveOperationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingWorkspace(let path):
            "No saved Codeness workspace exists for \(path)."
        case .unsupportedFormat(let version):
            "This Codeness workspace uses unsupported transfer format version \(version)."
        case .invalidArchive(let detail):
            "This is not a valid Codeness workspace: \(detail)"
        case .destinationExists(let path):
            "Codeness state already exists for \(path)."
        case .archiveOperationFailed(let detail):
            "The Codeness workspace archive could not be processed: \(detail)"
        }
    }
}

extension WorkspaceStore {
    public func hasStoredWorkspace(canonicalPath: String) -> Bool {
        FileManager.default.fileExists(atPath: workspaceURL(canonicalPath: canonicalPath).path)
    }

    public func storedWorkspacePreview(canonicalPath: String) throws -> RepositoryRecord? {
        guard hasStoredWorkspace(canonicalPath: canonicalPath) else { return nil }
        return try decoder.decode(
            RepositoryRecord.self,
            from: Data(contentsOf: workspaceURL(canonicalPath: canonicalPath))
        )
    }

    @discardableResult
    public func exportWorkspace(
        canonicalPath: String,
        sourceAppVersion: String,
        sourceAppBuild: String,
        to destinationURL: URL
    ) throws -> WorkspaceTransferManifest {
        let sourceDirectory = repositoryDirectory(canonicalPath: canonicalPath)
        guard FileManager.default.fileExists(
            atPath: sourceDirectory.appendingPathComponent("workspace.json").path
        ) else {
            throw WorkspaceTransferError.missingWorkspace(canonicalPath)
        }

        let record = try decoder.decode(
            RepositoryRecord.self,
            from: Data(contentsOf: sourceDirectory.appendingPathComponent("workspace.json"))
        )
        let manifest = WorkspaceTransferManifest(
            sourceAppVersion: sourceAppVersion,
            sourceAppBuild: sourceAppBuild,
            repositoryID: record.id,
            repositoryName: URL(fileURLWithPath: canonicalPath, isDirectory: true).lastPathComponent,
            originalCanonicalPath: canonicalPath
        )
        try WorkspaceTransferArchive.write(
            sourceDirectory: sourceDirectory,
            manifest: manifest,
            destinationURL: destinationURL,
            encoder: encoder
        )
        return manifest
    }

    public func inspectWorkspaceTransfer(at sourceURL: URL) throws -> WorkspaceTransferPreview {
        let extracted = try WorkspaceTransferArchive.extract(
            sourceURL: sourceURL,
            decoder: decoder
        )
        defer { try? FileManager.default.removeItem(at: extracted.temporaryDirectory) }
        return WorkspaceTransferPreview(manifest: extracted.manifest, record: extracted.record)
    }

    public func importWorkspace(
        from sourceURL: URL,
        to canonicalPath: String,
        sourceAppVersion: String,
        sourceAppBuild: String,
        replacingExisting: Bool
    ) throws -> WorkspaceImportResult {
        let extracted = try WorkspaceTransferArchive.extract(
            sourceURL: sourceURL,
            decoder: decoder
        )
        defer { try? FileManager.default.removeItem(at: extracted.temporaryDirectory) }

        let destinationDirectory = repositoryDirectory(canonicalPath: canonicalPath)
        let destinationDirectoryExists = FileManager.default.fileExists(
            atPath: destinationDirectory.path
        )
        let destinationWorkspaceExists = FileManager.default.fileExists(
            atPath: destinationDirectory.appendingPathComponent("workspace.json").path
        )
        if destinationWorkspaceExists, !replacingExisting {
            throw WorkspaceTransferError.destinationExists(canonicalPath)
        }

        let relocatedRecord = extracted.record.relocatedForImport(to: canonicalPath)
        let importedWorkspaceURL = extracted.workspaceDirectory
            .appendingPathComponent("workspace.json")
        try encoder.encode(relocatedRecord).write(to: importedWorkspaceURL, options: .atomic)

        let importedViewStateURL = extracted.workspaceDirectory
            .appendingPathComponent("view-state.json")
        if FileManager.default.fileExists(atPath: importedViewStateURL.path) {
            var viewState = try decoder.decode(
                RepositoryViewState.self,
                from: Data(contentsOf: importedViewStateURL)
            )
            viewState.resumeAfterSystemTermination = nil
            try encoder.encode(viewState).write(to: importedViewStateURL, options: .atomic)
        }

        let backupURL: URL?
        if destinationWorkspaceExists {
            backupURL = try backupWorkspace(
                canonicalPath: canonicalPath,
                sourceAppVersion: sourceAppVersion,
                sourceAppBuild: sourceAppBuild
            )
        } else {
            backupURL = nil
        }

        do {
            try Self.installWorkspaceDirectory(
                importedWorkspaceDirectory: extracted.workspaceDirectory,
                destinationDirectory: destinationDirectory,
                replacingExisting: destinationDirectoryExists
            )
        } catch {
            throw WorkspaceTransferError.archiveOperationFailed(error.localizedDescription)
        }

        return WorkspaceImportResult(
            manifest: extracted.manifest,
            record: relocatedRecord,
            backupURL: backupURL
        )
    }

    private func backupWorkspace(
        canonicalPath: String,
        sourceAppVersion: String,
        sourceAppBuild: String
    ) throws -> URL {
        let backupDirectory = rootURL.appendingPathComponent("Import Backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )
        let repositoryName = URL(fileURLWithPath: canonicalPath, isDirectory: true)
            .lastPathComponent
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = backupDirectory
            .appendingPathComponent("\(repositoryName)-\(timestamp)-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("codeness")
        try exportWorkspace(
            canonicalPath: canonicalPath,
            sourceAppVersion: sourceAppVersion,
            sourceAppBuild: sourceAppBuild,
            to: backupURL
        )
        return backupURL
    }

    private static func installWorkspaceDirectory(
        importedWorkspaceDirectory: URL,
        destinationDirectory: URL,
        replacingExisting: Bool
    ) throws {
        let fileManager = FileManager.default
        let parent = destinationDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stagedDirectory = parent.appendingPathComponent(
            ".\(destinationDirectory.lastPathComponent).import-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagedDirectory) }
        try fileManager.copyItem(at: importedWorkspaceDirectory, to: stagedDirectory)

        if replacingExisting {
            _ = try fileManager.replaceItemAt(
                destinationDirectory,
                withItemAt: stagedDirectory,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagedDirectory, to: destinationDirectory)
        }
    }
}

private enum WorkspaceTransferArchive {
    struct ExtractedWorkspace {
        let temporaryDirectory: URL
        let workspaceDirectory: URL
        let manifest: WorkspaceTransferManifest
        let record: RepositoryRecord
    }

    private static let archivedTopLevelNames = [
        "workspace.json",
        "view-state.json",
        "activity",
        "activity-archives"
    ]

    static func write(
        sourceDirectory: URL,
        manifest: WorkspaceTransferManifest,
        destinationURL: URL,
        encoder: JSONEncoder
    ) throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "CodenessExport-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        let stagedWorkspace = temporaryDirectory.appendingPathComponent(
            "workspace",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagedWorkspace, withIntermediateDirectories: true)
        try encoder.encode(manifest).write(
            to: temporaryDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        for name in archivedTopLevelNames {
            let source = sourceDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try copyPortableItem(
                from: source,
                to: stagedWorkspace.appendingPathComponent(name)
            )
        }

        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryArchive = parent.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).export-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: temporaryArchive) }
        do {
            try encodeDirectory(temporaryDirectory, to: temporaryArchive)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryArchive,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryArchive, to: destinationURL)
            }
        } catch let error as WorkspaceTransferError {
            throw error
        } catch {
            throw WorkspaceTransferError.archiveOperationFailed(error.localizedDescription)
        }
    }

    static func extract(sourceURL: URL, decoder: JSONDecoder) throws -> ExtractedWorkspace {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "CodenessImport-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            try decodeArchive(sourceURL, to: temporaryDirectory)
            let manifestURL = temporaryDirectory.appendingPathComponent("manifest.json")
            let workspaceDirectory = temporaryDirectory.appendingPathComponent(
                "workspace",
                isDirectory: true
            )
            let workspaceURL = workspaceDirectory.appendingPathComponent("workspace.json")
            guard fileManager.fileExists(atPath: manifestURL.path),
                  fileManager.fileExists(atPath: workspaceURL.path) else {
                throw WorkspaceTransferError.invalidArchive(
                    "manifest.json or workspace/workspace.json is missing"
                )
            }
            let manifest = try decoder.decode(
                WorkspaceTransferManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            guard manifest.formatVersion == WorkspaceTransferManifest.currentFormatVersion else {
                throw WorkspaceTransferError.unsupportedFormat(manifest.formatVersion)
            }
            let record = try decoder.decode(
                RepositoryRecord.self,
                from: Data(contentsOf: workspaceURL)
            )
            guard manifest.repositoryID == record.id else {
                throw WorkspaceTransferError.invalidArchive(
                    "the manifest and workspace identify different repositories"
                )
            }
            guard manifest.originalCanonicalPath == record.canonicalPath else {
                throw WorkspaceTransferError.invalidArchive(
                    "the manifest and workspace contain different original paths"
                )
            }
            return ExtractedWorkspace(
                temporaryDirectory: temporaryDirectory,
                workspaceDirectory: workspaceDirectory,
                manifest: manifest,
                record: record
            )
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            if let transferError = error as? WorkspaceTransferError {
                throw transferError
            }
            throw WorkspaceTransferError.invalidArchive(error.localizedDescription)
        }
    }

    private static func copyPortableItem(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let values = try source.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isSymbolicLink != true else {
            throw WorkspaceTransferError.invalidArchive(
                "saved state contains an unsupported symbolic link at \(source.lastPathComponent)"
            )
        }
        if values.isDirectory == true {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) where child.lastPathComponent != ".DS_Store" {
                try copyPortableItem(
                    from: child,
                    to: destination.appendingPathComponent(child.lastPathComponent)
                )
            }
            return
        }
        guard values.isRegularFile == true else {
            throw WorkspaceTransferError.invalidArchive(
                "saved state contains an unsupported filesystem item at \(source.lastPathComponent)"
            )
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func encodeDirectory(_ sourceURL: URL, to destinationURL: URL) throws {
        guard let keySet = ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD,MTM") else {
            throw WorkspaceTransferError.archiveOperationFailed(
                "AppleArchive could not create its header key set"
            )
        }
        try ArchiveByteStream.withFileStream(
            path: FilePath(destinationURL.path),
            mode: .writeOnly,
            options: [.create, .truncate],
            permissions: FilePermissions(rawValue: 0o644)
        ) { fileStream in
            guard let compressionStream = ArchiveByteStream.compressionStream(
                using: .lzfse,
                writingTo: fileStream
            ) else {
                throw WorkspaceTransferError.archiveOperationFailed(
                    "AppleArchive could not create a compression stream"
                )
            }
            defer { try? compressionStream.close() }
            try ArchiveStream.withEncodeStream(writingTo: compressionStream) { encodeStream in
                try encodeStream.writeDirectoryContents(
                    archiveFrom: FilePath(sourceURL.path),
                    keySet: keySet
                )
            }
        }
    }

    private static func decodeArchive(_ sourceURL: URL, to destinationURL: URL) throws {
        var rejectedPath: String?
        let filter: ArchiveHeader.EntryFilter = { message, path, data in
            guard message == .extractBegin else { return .ok }
            let candidate = path.string
            guard isAllowedArchivePath(path),
                  case .header(let header) = data,
                  header.entryType == .directory || header.entryType == .regularFile else {
                rejectedPath = candidate
                return .cancel
            }
            return .ok
        }

        do {
            try ArchiveByteStream.withFileStream(
                path: FilePath(sourceURL.path),
                mode: .readOnly,
                options: [],
                permissions: FilePermissions(rawValue: 0o644)
            ) { fileStream in
                guard let decompressionStream = ArchiveByteStream.decompressionStream(
                    readingFrom: fileStream
                ) else {
                    throw WorkspaceTransferError.invalidArchive(
                        "AppleArchive could not create a decompression stream"
                    )
                }
                defer { try? decompressionStream.close() }
                try ArchiveStream.withDecodeStream(readingFrom: decompressionStream) { decodeStream in
                    try ArchiveStream.withExtractStream(
                        extractingTo: FilePath(destinationURL.path),
                        selectUsing: filter
                    ) { extractStream in
                        _ = try ArchiveStream.process(
                            readingFrom: decodeStream,
                            writingTo: extractStream
                        )
                    }
                }
            }
        } catch {
            if let rejectedPath {
                throw WorkspaceTransferError.invalidArchive(
                    "the archive contains an unsupported entry at \(rejectedPath)"
                )
            }
            throw error
        }
        if let rejectedPath {
            throw WorkspaceTransferError.invalidArchive(
                "the archive contains an unsupported entry at \(rejectedPath)"
            )
        }
    }

    private static func isAllowedArchivePath(_ path: FilePath) -> Bool {
        guard path.isRelative, path.isLexicallyNormal else { return false }
        let value = path.string
        if value.isEmpty || value == "." {
            return true
        }
        if value == "manifest.json" || value == "workspace" {
            return true
        }
        if value == "workspace/workspace.json" || value == "workspace/view-state.json" {
            return true
        }
        return value == "workspace/activity"
            || value.hasPrefix("workspace/activity/")
            || value == "workspace/activity-archives"
            || value.hasPrefix("workspace/activity-archives/")
    }
}
