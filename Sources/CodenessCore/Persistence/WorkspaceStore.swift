import CryptoKit
import Darwin
import Foundation

public struct RecoveredTranscriptTail: Sendable, Equatable {
    public let text: String
    public let wasTruncated: Bool

    public init(text: String, wasTruncated: Bool) {
        self.text = text
        self.wasTruncated = wasTruncated
    }
}

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
    func recoveredTranscriptTail(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID,
        maximumUTF8Bytes: Int
    ) async throws -> RecoveredTranscriptTail
    func recoveredTokenUsage(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> RunTokenUsage?
}

public extension RepositoryWorkspaceStoring {
    func recoveredTranscriptTail(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID,
        maximumUTF8Bytes: Int
    ) async throws -> RecoveredTranscriptTail {
        let transcript = try await recoveredTranscript(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        let byteLimit = max(0, maximumUTF8Bytes)
        guard transcript.utf8.count > byteLimit else {
            return RecoveredTranscriptTail(text: transcript, wasTruncated: false)
        }
        guard byteLimit > 0 else {
            return RecoveredTranscriptTail(text: "", wasTruncated: true)
        }
        let utf8 = transcript.utf8
        var start = utf8.index(utf8.endIndex, offsetBy: -byteLimit)
        while start != utf8.endIndex, utf8[start] & 0xC0 == 0x80 {
            start = utf8.index(after: start)
        }
        return RecoveredTranscriptTail(
            text: String(decoding: utf8[start...], as: UTF8.self),
            wasTruncated: true
        )
    }

    func appendTokenUsage(
        _ usage: RunTokenUsage,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        let value = JSONValue.object([
            "method": .string("codeness/agentTokenUsage/updated"),
            "params": .object([
                "tokenUsage": .object([
                    "totalTokens": .integer(usage.totalTokens),
                    "inputTokens": .integer(usage.inputTokens),
                    "cachedInputTokens": .integer(usage.cachedInputTokens),
                    "cacheWriteInputTokens": .integer(usage.cacheWriteInputTokens),
                    "outputTokens": .integer(usage.outputTokens),
                    "reasoningOutputTokens": .integer(usage.reasoningOutputTokens)
                ])
            ])
        ])
        try await appendRawLine(
            value.encodedString(),
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }
}

public actor WorkspaceStore: RepositoryWorkspaceStoring {
    static let maximumRecoveredRawJSONLineByteCount = 32 * 1_024 * 1_024
    static let maximumPreparedAppendTargetCount = 32
    private static let rawTokenUsageNeedle = Data("tokenUsage".utf8)
    private static let newlineByte: UInt8 = 0x0A

    private struct AppendFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    let rootURL: URL
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    private let appendFileOperations: WorkspaceAppendFileOperations
    private var blockedAppendURLs: Set<URL> = []
    private var preparedAppendTargets: [URL: AppendFileIdentity] = [:]
    private var preparedAppendTargetOrder: [URL] = []

    public init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? Self.defaultRootURL()
        appendFileOperations = .live
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    init(
        rootURL: URL,
        appendFileOperations: WorkspaceAppendFileOperations
    ) {
        self.rootURL = rootURL
        self.appendFileOperations = appendFileOperations
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
        let decoded = try decoder.decode(RepositoryRecord.self, from: Data(contentsOf: url))
        let externalized = try externalizedRecord(decoded)
        if externalized != decoded {
            try durableAtomicWrite(encoder.encode(externalized), to: url)
        }
        return externalized
    }

    public func save(_ record: RepositoryRecord) throws {
        let directory = repositoryDirectory(canonicalPath: record.canonicalPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(externalizedRecord(record))
        try durableAtomicWrite(
            data,
            to: directory.appendingPathComponent("workspace.json")
        )
    }

    public func archiveActivity(_ record: RepositoryRecord) throws {
        guard let activity = record.activity else {
            throw WorkspaceStoreError.missingActivityToArchive
        }
        let directory = repositoryDirectory(canonicalPath: record.canonicalPath)
            .appendingPathComponent("activity-archives", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let externalized = try externalizedRecord(record)
        try durableStreamingArchiveWrite(
            externalized,
            to: directory.appendingPathComponent("\(activity.id.uuidString).json")
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

    public func recoveredTranscriptTail(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID,
        maximumUTF8Bytes: Int
    ) throws -> RecoveredTranscriptTail {
        let url = logURL(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID,
            suffix: "transcript.txt"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RecoveredTranscriptTail(text: "", wasTruncated: false)
        }

        let byteLimit = max(0, maximumUTF8Bytes)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize > UInt64(byteLimit) else {
            try handle.seek(toOffset: 0)
            let data = try handle.readToEnd() ?? Data()
            return RecoveredTranscriptTail(
                text: String(decoding: data, as: UTF8.self),
                wasTruncated: false
            )
        }
        guard byteLimit > 0 else {
            return RecoveredTranscriptTail(text: "", wasTruncated: true)
        }

        try handle.seek(toOffset: fileSize - UInt64(byteLimit))
        let data = try handle.read(upToCount: byteLimit) ?? Data()
        var start = data.startIndex
        while start != data.endIndex, data[start] & 0xC0 == 0x80 {
            start = data.index(after: start)
        }
        return RecoveredTranscriptTail(
            text: String(decoding: data[start...], as: UTF8.self),
            wasTruncated: true
        )
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
        var latestAgentUsage: RunTokenUsage?

        func processLine(_ line: Data) {
            guard line.range(of: Self.rawTokenUsageNeedle) != nil,
                  let event = try? decoder.decode(JSONValue.self, from: line) else { return }
            if event["method"]?.stringValue == "codeness/agentTokenUsage/updated",
               let usage = RunTokenUsage(
                    appServerValue: event["params"]?["tokenUsage"]
               ) {
                latestAgentUsage = usage
                return
            }
            guard event["method"]?.stringValue == "thread/tokenUsage/updated",
                  let usage = event["params"]?["tokenUsage"],
                  let total = RunTokenUsage(appServerValue: usage["total"]),
                  let last = RunTokenUsage(appServerValue: usage["last"]) else {
                return
            }
            if baseline == nil {
                baseline = total.subtracting(last)
            }
            latestTotal = total
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var lineBuffer = Data()
        var discardingOversizedLine = false
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            var cursor = chunk.startIndex
            while cursor != chunk.endIndex {
                let remaining = chunk[cursor..<chunk.endIndex]
                if let newline = remaining.firstIndex(of: Self.newlineByte) {
                    if !discardingOversizedLine {
                        let segment = chunk[cursor..<newline]
                        if lineBuffer.count <= Self.maximumRecoveredRawJSONLineByteCount
                            - segment.count {
                            lineBuffer.append(contentsOf: segment)
                            processLine(lineBuffer)
                        }
                    }
                    lineBuffer.removeAll(keepingCapacity: true)
                    discardingOversizedLine = false
                    cursor = chunk.index(after: newline)
                    continue
                }

                if !discardingOversizedLine {
                    if lineBuffer.count <= Self.maximumRecoveredRawJSONLineByteCount
                        - remaining.count {
                        lineBuffer.append(contentsOf: remaining)
                    } else {
                        lineBuffer.removeAll(keepingCapacity: false)
                        discardingOversizedLine = true
                    }
                }
                cursor = chunk.endIndex
            }
        }
        if !discardingOversizedLine, !lineBuffer.isEmpty {
            processLine(lineBuffer)
        }

        if let latestAgentUsage {
            return latestAgentUsage
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

    func workspaceURL(canonicalPath: String) -> URL {
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
        guard !blockedAppendURLs.contains(url) else {
            throw WorkspaceStoreError.appendOutcomeUncertain(url)
        }
        try prepareAppendTarget(at: url)
        let handle = try appendFileOperations.openForWriting(url)
        let startingOffset: UInt64
        do {
            startingOffset = try appendFileOperations.seekToEnd(handle)
        } catch {
            try? appendFileOperations.close(handle)
            throw error
        }

        let observedSize: UInt64
        do {
            observedSize = try appendFileOperations.fileSize(url)
        } catch {
            try? appendFileOperations.close(handle)
            throw error
        }
        guard startingOffset == observedSize else {
            try? appendFileOperations.close(handle)
            blockedAppendURLs.insert(url)
            throw WorkspaceStoreError.appendOutcomeUncertain(url)
        }

        let chunk = Data(text.utf8)
        var synchronized = false
        do {
            try appendFileOperations.write(handle, chunk)
            try appendFileOperations.synchronize(handle)
            synchronized = true
            try appendFileOperations.close(handle)
        } catch {
            let operationError = error
            switch try recoverAppend(
                to: url,
                originalHandle: handle,
                startingOffset: startingOffset,
                chunk: chunk,
                wasSynchronized: synchronized
            ) {
            case .committed:
                return
            case .rolledBack, .unchanged:
                throw operationError
            }
        }
    }

    private func prepareAppendTarget(at url: URL) throws {
        if let preparedIdentity = preparedAppendTargets[url],
           (try? currentAppendFileIdentity(at: url)) == preparedIdentity {
            markPreparedAppendTargetRecentlyUsed(url)
            return
        }
        removePreparedAppendTarget(url)

        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.createFile(atPath: url.path, contents: nil),
           !FileManager.default.fileExists(atPath: url.path) {
            throw WorkspaceStoreError.appendTargetCreationFailed(url)
        }

        let handle = try appendFileOperations.openForWriting(url)
        do {
            try appendFileOperations.synchronize(handle)
            try appendFileOperations.close(handle)
        } catch {
            try? appendFileOperations.close(handle)
            throw error
        }

        // The first sync commits the file entry; the remaining chain commits any
        // intermediate activity/repository directories createDirectory just made.
        try synchronizeDirectoryChain(startingAt: directoryURL)
        cachePreparedAppendTarget(
            url,
            identity: try currentAppendFileIdentity(at: url)
        )
    }

    private func currentAppendFileIdentity(at url: URL) throws -> AppendFileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return AppendFileIdentity(
            device: device.uint64Value,
            inode: inode.uint64Value
        )
    }

    private func cachePreparedAppendTarget(
        _ url: URL,
        identity: AppendFileIdentity
    ) {
        preparedAppendTargets[url] = identity
        markPreparedAppendTargetRecentlyUsed(url)
        while preparedAppendTargetOrder.count > Self.maximumPreparedAppendTargetCount {
            let evictedURL = preparedAppendTargetOrder.removeFirst()
            preparedAppendTargets.removeValue(forKey: evictedURL)
        }
    }

    private func markPreparedAppendTargetRecentlyUsed(_ url: URL) {
        preparedAppendTargetOrder.removeAll { $0 == url }
        preparedAppendTargetOrder.append(url)
    }

    private func removePreparedAppendTarget(_ url: URL) {
        preparedAppendTargets.removeValue(forKey: url)
        preparedAppendTargetOrder.removeAll { $0 == url }
    }

    /// An import can replace the complete repository directory, including every
    /// transcript inode. Drop path-scoped preparation before replacement so a
    /// failed import safely re-prepares the existing files on the next append.
    func prepareForWorkspaceDirectoryReplacement(_ directory: URL) {
        let invalidatedURLs = preparedAppendTargets.keys.filter {
            Self.isFileURL($0, inside: directory)
        }
        for url in invalidatedURLs {
            removePreparedAppendTarget(url)
        }
    }

    /// A successful import establishes a new authoritative directory. Append
    /// uncertainty belonged to the replaced files and must not poison matching
    /// activity/run paths restored from the archive.
    func workspaceDirectoryReplacementDidComplete(_ directory: URL) {
        prepareForWorkspaceDirectoryReplacement(directory)
        blockedAppendURLs = blockedAppendURLs.filter {
            !Self.isFileURL($0, inside: directory)
        }
    }

    private static func isFileURL(_ candidate: URL, inside directory: URL) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == directoryPath
            || candidatePath.hasPrefix(directoryPath + "/")
    }

    private enum AppendRecoveryDisposition {
        case committed
        case rolledBack
        case unchanged
    }

    private func recoverAppend(
        to url: URL,
        originalHandle: FileHandle,
        startingOffset: UInt64,
        chunk: Data,
        wasSynchronized: Bool
    ) throws -> AppendRecoveryDisposition {
        try? appendFileOperations.close(originalHandle)

        let currentSize: UInt64
        do {
            currentSize = try appendFileOperations.fileSize(url)
        } catch {
            blockedAppendURLs.insert(url)
            throw WorkspaceStoreError.appendOutcomeUncertain(url)
        }

        guard currentSize >= startingOffset else {
            blockedAppendURLs.insert(url)
            throw WorkspaceStoreError.appendOutcomeUncertain(url)
        }
        if currentSize == startingOffset {
            return .unchanged
        }

        let appendedData: Data
        do {
            appendedData = try appendFileOperations.readFromOffset(url, startingOffset)
        } catch {
            blockedAppendURLs.insert(url)
            throw WorkspaceStoreError.appendOutcomeUncertain(url)
        }
        guard UInt64(appendedData.count) == currentSize - startingOffset else {
            blockedAppendURLs.insert(url)
            throw WorkspaceStoreError.appendOutcomeUncertain(url)
        }

        if appendedData == chunk {
            // A successful fsync before a close failure is already a defensible
            // durability boundary. Otherwise retry fsync through a fresh descriptor.
            if wasSynchronized || synchronizeFile(at: url) {
                return .committed
            }
            if rollbackAppend(at: url, to: startingOffset) {
                return .rolledBack
            }
            blockedAppendURLs.insert(url)
            throw WorkspaceStoreError.appendOutcomeUncertain(url)
        }

        if appendedData.count < chunk.count,
           chunk.starts(with: appendedData) {
            if rollbackAppend(at: url, to: startingOffset) {
                return .rolledBack
            }
            blockedAppendURLs.insert(url)
            throw WorkspaceStoreError.appendOutcomeUncertain(url)
        }

        // A changed prefix, a shorter file, or bytes trailing the complete chunk can
        // indicate an external writer. Never truncate or retry blindly in that state.
        blockedAppendURLs.insert(url)
        throw WorkspaceStoreError.appendOutcomeUncertain(url)
    }

    private func synchronizeFile(at url: URL) -> Bool {
        guard let handle = try? appendFileOperations.openForWriting(url) else {
            return false
        }
        var synchronized = false
        do {
            try appendFileOperations.synchronize(handle)
            synchronized = true
            try appendFileOperations.close(handle)
        } catch {
            try? appendFileOperations.close(handle)
        }
        return synchronized
    }

    private func rollbackAppend(
        at url: URL,
        to startingOffset: UInt64
    ) -> Bool {
        guard let handle = try? appendFileOperations.openForWriting(url) else {
            return false
        }
        var synchronized = false
        do {
            try appendFileOperations.truncate(handle, startingOffset)
            try appendFileOperations.synchronize(handle)
            synchronized = true
            try appendFileOperations.close(handle)
        } catch {
            try? appendFileOperations.close(handle)
        }
        if !synchronized {
            synchronized = synchronizeFile(at: url)
        }
        guard synchronized,
              let recoveredSize = try? appendFileOperations.fileSize(url) else {
            return false
        }
        return recoveredSize == startingOffset
    }

    /// Moves legacy or currently hydrated transcript text into the per-run log and
    /// returns the small metadata snapshot written to `workspace.json`.
    private func externalizedRecord(_ record: RepositoryRecord) throws -> RepositoryRecord {
        guard let activity = record.activity else { return record }
        var externalized = record
        for runIndex in activity.runs.indices {
            let run = activity.runs[runIndex]
            if !run.transcript.isEmpty {
                try synchronizeTranscript(
                    run.transcript,
                    repositoryPath: record.canonicalPath,
                    activityID: activity.id,
                    runID: run.id
                )
            }
            externalized.activity?.runs[runIndex].transcript = ""
        }
        return externalized
    }

    /// Activity archives remain self-contained, but assembling every transcript in
    /// a copied record would recreate the unbounded memory spike that externalized
    /// logs are intended to prevent. Encode small metadata once and splice each
    /// authoritative transcript into its JSON string from disk in bounded chunks.
    private func durableStreamingArchiveWrite(
        _ record: RepositoryRecord,
        to destinationURL: URL
    ) throws {
        guard let activity = record.activity else {
            throw WorkspaceStoreError.missingActivityToArchive
        }

        var templateRecord = record
        var replacements: [(placeholder: Data, transcriptURL: URL)] = []
        for runIndex in activity.runs.indices {
            let run = activity.runs[runIndex]
            let marker = "__CODENESS_ARCHIVE_TRANSCRIPT_\(run.id.uuidString)_\(UUID().uuidString)__"
            templateRecord.activity?.runs[runIndex].transcript = marker
            replacements.append((
                placeholder: try encoder.encode(marker),
                transcriptURL: logURL(
                    repositoryPath: record.canonicalPath,
                    activityID: activity.id,
                    runID: run.id,
                    suffix: "transcript.txt"
                )
            ))
        }
        let template = try encoder.encode(templateRecord)

        var ranges: [Range<Data.Index>] = []
        var searchStart = template.startIndex
        for replacement in replacements {
            guard let range = template.range(
                of: replacement.placeholder,
                options: [],
                in: searchStart..<template.endIndex
            ),
            template.range(
                of: replacement.placeholder,
                options: [],
                in: range.upperBound..<template.endIndex
            ) == nil else {
                throw WorkspaceStoreError.archiveTranscriptPlaceholderInvalid(destinationURL)
            }
            ranges.append(range)
            searchStart = range.upperBound
        }

        let directoryURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).tmp.\(UUID().uuidString)"
        )
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw WorkspaceStoreError.durableWriteTemporaryFileCreationFailed(temporaryURL)
        }

        var renameCompleted = false
        defer {
            if !renameCompleted {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        let output = try appendFileOperations.openForWriting(temporaryURL)
        var archiveHasher = SHA256()
        var archiveByteCount: UInt64 = 0
        do {
            var cursor = template.startIndex
            for (index, range) in ranges.enumerated() {
                try writeArchiveChunk(
                    Data(template[cursor..<range.lowerBound]),
                    to: output,
                    hasher: &archiveHasher,
                    byteCount: &archiveByteCount
                )
                try writeArchiveChunk(
                    Data([0x22]),
                    to: output,
                    hasher: &archiveHasher,
                    byteCount: &archiveByteCount
                )
                try streamEscapedJSONStringContent(
                    from: replacements[index].transcriptURL,
                    to: output,
                    hasher: &archiveHasher,
                    byteCount: &archiveByteCount
                )
                try writeArchiveChunk(
                    Data([0x22]),
                    to: output,
                    hasher: &archiveHasher,
                    byteCount: &archiveByteCount
                )
                cursor = range.upperBound
            }
            try writeArchiveChunk(
                Data(template[cursor..<template.endIndex]),
                to: output,
                hasher: &archiveHasher,
                byteCount: &archiveByteCount
            )
            try appendFileOperations.synchronize(output)
            try appendFileOperations.close(output)
        } catch {
            try? appendFileOperations.close(output)
            throw error
        }
        let expectedDigest = archiveHasher.finalize()

        try appendFileOperations.atomicReplace(temporaryURL, destinationURL)
        renameCompleted = true
        let verification = try streamingDigest(of: destinationURL)
        guard verification.byteCount == archiveByteCount,
              verification.digest == expectedDigest else {
            throw WorkspaceStoreError.durableWriteVerificationFailed(destinationURL)
        }
        try synchronizeDirectoryChain(startingAt: directoryURL)
    }

    private func streamEscapedJSONStringContent(
        from sourceURL: URL,
        to output: FileHandle,
        hasher: inout SHA256,
        byteCount: inout UInt64
    ) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        var utf8Carry = Data()
        while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            utf8Carry.append(chunk)
            let trailingByteCount = Self.incompleteUTF8SuffixByteCount(utf8Carry)
            let prefixByteCount = utf8Carry.count - trailingByteCount
            let decoded = String(
                decoding: utf8Carry.prefix(prefixByteCount),
                as: UTF8.self
            )
            let escaped = Self.escapedJSONStringContent(decoded)
            try writeArchiveChunk(
                escaped,
                to: output,
                hasher: &hasher,
                byteCount: &byteCount
            )
            utf8Carry = Data(utf8Carry.suffix(trailingByteCount))
        }
        if !utf8Carry.isEmpty {
            try writeArchiveChunk(
                Self.escapedJSONStringContent(String(decoding: utf8Carry, as: UTF8.self)),
                to: output,
                hasher: &hasher,
                byteCount: &byteCount
            )
        }
    }

    private static func escapedJSONStringContent(_ string: String) -> Data {
        let digits = Array("0123456789abcdef".utf8)
        let bytes = string.utf8
        var escaped = Data()
        escaped.reserveCapacity(bytes.count)
        for byte in bytes {
            switch byte {
            case 0x22: escaped.append(contentsOf: [0x5C, 0x22])
            case 0x5C: escaped.append(contentsOf: [0x5C, 0x5C])
            case 0x08: escaped.append(contentsOf: [0x5C, 0x62])
            case 0x09: escaped.append(contentsOf: [0x5C, 0x74])
            case 0x0A: escaped.append(contentsOf: [0x5C, 0x6E])
            case 0x0C: escaped.append(contentsOf: [0x5C, 0x66])
            case 0x0D: escaped.append(contentsOf: [0x5C, 0x72])
            case 0x00...0x1F:
                escaped.append(contentsOf: [
                    0x5C, 0x75, 0x30, 0x30,
                    digits[Int(byte >> 4)],
                    digits[Int(byte & 0x0F)]
                ])
            default: escaped.append(byte)
            }
        }
        return escaped
    }

    private static func incompleteUTF8SuffixByteCount(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        var leadIndex = data.index(before: data.endIndex)
        var continuationCount = 0
        while data[leadIndex] & 0xC0 == 0x80, continuationCount < 3 {
            continuationCount += 1
            guard leadIndex != data.startIndex else { return 0 }
            leadIndex = data.index(before: leadIndex)
        }
        let lead = data[leadIndex]
        let expectedByteCount: Int
        switch lead {
        case 0xC2...0xDF: expectedByteCount = 2
        case 0xE0...0xEF: expectedByteCount = 3
        case 0xF0...0xF4: expectedByteCount = 4
        default: return 0
        }
        let availableByteCount = continuationCount + 1
        return availableByteCount < expectedByteCount ? availableByteCount : 0
    }

    private func writeArchiveChunk(
        _ data: Data,
        to output: FileHandle,
        hasher: inout SHA256,
        byteCount: inout UInt64
    ) throws {
        guard !data.isEmpty else { return }
        try appendFileOperations.write(output, data)
        hasher.update(data: data)
        byteCount += UInt64(data.count)
    }

    private func streamingDigest(of url: URL) throws -> (digest: SHA256.Digest, byteCount: UInt64) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        var byteCount: UInt64 = 0
        while let data = try input.read(upToCount: 64 * 1_024), !data.isEmpty {
            hasher.update(data: data)
            byteCount += UInt64(data.count)
        }
        return (hasher.finalize(), byteCount)
    }

    private func synchronizeTranscript(
        _ transcript: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) throws {
        let url = logURL(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID,
            suffix: "transcript.txt"
        )
        let appendLogData: Data
        if FileManager.default.fileExists(atPath: url.path) {
            appendLogData = try Data(contentsOf: url)
        } else {
            appendLogData = Data()
        }
        let metadataData = Data(transcript.utf8)

        // Equal bytes and an append-log extension already have an authoritative
        // canonical log. A stale append-log prefix can be replaced directly because
        // the metadata contains every byte it held. Any other relationship is a true
        // divergence: preserve the exact prior bytes before choosing metadata.
        if appendLogData == metadataData {
            try ensureExistingFileIsDurable(appendLogData, at: url)
            return
        }
        if appendLogData.starts(with: metadataData),
           String(data: appendLogData, encoding: .utf8) != nil {
            try ensureExistingFileIsDurable(appendLogData, at: url)
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !metadataData.starts(with: appendLogData), !appendLogData.isEmpty {
            try preserveDivergentTranscript(
                appendLogData,
                canonicalURL: url,
                runID: runID
            )
        }
        try durableAtomicWrite(metadataData, to: url)
    }

    private func preserveDivergentTranscript(
        _ data: Data,
        canonicalURL: URL,
        runID: UUID
    ) throws {
        let digest = Self.sha256Hex(data)
        let sidecarURL = canonicalURL.deletingLastPathComponent().appendingPathComponent(
            "\(runID.uuidString).transcript.pre-externalization.\(digest).txt"
        )
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            guard try Data(contentsOf: sidecarURL) == data else {
                throw WorkspaceStoreError.transcriptSidecarVerificationFailed(sidecarURL)
            }
            try ensureExistingFileIsDurable(data, at: sidecarURL)
            return
        }

        try durableAtomicWrite(data, to: sidecarURL)
    }

    private func durableAtomicWrite(_ data: Data, to destinationURL: URL) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).tmp.\(UUID().uuidString)"
        )
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil
        ) else {
            throw WorkspaceStoreError.durableWriteTemporaryFileCreationFailed(temporaryURL)
        }

        var renameCompleted = false
        defer {
            if !renameCompleted {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        let handle = try appendFileOperations.openForWriting(temporaryURL)
        do {
            try appendFileOperations.write(handle, data)
            try appendFileOperations.synchronize(handle)
            try appendFileOperations.close(handle)
        } catch {
            try? appendFileOperations.close(handle)
            throw error
        }

        // Once replacement begins, the pathname may refer to a new inode even if
        // atomicReplace reports an error after the rename. Never let a preparation
        // cached for the old inode admit payload into that ambiguous replacement.
        removePreparedAppendTarget(destinationURL)
        try appendFileOperations.atomicReplace(temporaryURL, destinationURL)
        renameCompleted = true
        guard try Data(contentsOf: destinationURL) == data else {
            throw WorkspaceStoreError.durableWriteVerificationFailed(destinationURL)
        }
        try synchronizeDirectoryChain(startingAt: directoryURL)
    }

    private func ensureExistingFileIsDurable(_ expectedData: Data, at url: URL) throws {
        let handle = try appendFileOperations.openForWriting(url)
        do {
            try appendFileOperations.synchronize(handle)
            try appendFileOperations.close(handle)
        } catch {
            try? appendFileOperations.close(handle)
            throw error
        }
        guard try Data(contentsOf: url) == expectedData else {
            throw WorkspaceStoreError.durableWriteVerificationFailed(url)
        }
        try synchronizeDirectoryChain(startingAt: url.deletingLastPathComponent())
    }

    private func synchronizeDirectoryChain(startingAt directory: URL) throws {
        var directoryToSynchronize = directory.standardizedFileURL
        let boundary = rootURL.deletingLastPathComponent().standardizedFileURL
        while true {
            try appendFileOperations.synchronizeDirectory(directoryToSynchronize)
            guard directoryToSynchronize != boundary else { break }
            let parent = directoryToSynchronize.deletingLastPathComponent().standardizedFileURL
            guard parent.path != directoryToSynchronize.path else { break }
            directoryToSynchronize = parent
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        let bytes = SHA256.hash(data: data).flatMap { byte in
            [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func defaultRootURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("Codeness", isDirectory: true)
    }
}

private enum WorkspaceStoreError: LocalizedError {
    case missingActivityToArchive
    case appendOutcomeUncertain(URL)
    case appendTargetCreationFailed(URL)
    case archiveTranscriptPlaceholderInvalid(URL)
    case durableWriteTemporaryFileCreationFailed(URL)
    case durableWriteVerificationFailed(URL)
    case transcriptSidecarVerificationFailed(URL)

    var errorDescription: String? {
        switch self {
        case .missingActivityToArchive:
            "There is no activity to archive."
        case .appendOutcomeUncertain(let url):
            "The append outcome for \(url.path) could not be verified safely."
        case .appendTargetCreationFailed(let url):
            "Could not create the append target at \(url.path)."
        case .archiveTranscriptPlaceholderInvalid(let url):
            "Could not construct the streaming activity archive at \(url.path)."
        case .durableWriteTemporaryFileCreationFailed(let url):
            "Could not create the durable-write temporary file at \(url.path)."
        case .durableWriteVerificationFailed(let url):
            "Could not verify the durable write at \(url.path)."
        case .transcriptSidecarVerificationFailed(let url):
            "Could not verify the preserved transcript at \(url.path)."
        }
    }
}

struct WorkspaceAppendFileOperations: @unchecked Sendable {
    var openForWriting: (URL) throws -> FileHandle = { try FileHandle(forWritingTo: $0) }
    var seekToEnd: (FileHandle) throws -> UInt64 = { try $0.seekToEnd() }
    var write: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
    var synchronize: (FileHandle) throws -> Void = {
        try $0.synchronize()
        if Darwin.fcntl($0.fileDescriptor, F_FULLFSYNC) != 0,
           errno != EINVAL,
           errno != ENOTSUP {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    var truncate: (FileHandle, UInt64) throws -> Void = { try $0.truncate(atOffset: $1) }
    var close: (FileHandle) throws -> Void = { try $0.close() }
    var fileSize: (URL) throws -> UInt64 = {
        let attributes = try FileManager.default.attributesOfItem(atPath: $0.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return size.uint64Value
    }
    var readFromOffset: (URL, UInt64) throws -> Data = { url, offset in
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.readToEnd() ?? Data()
    }
    var atomicReplace: (URL, URL) throws -> Void = { sourceURL, destinationURL in
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                unsafe Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    var synchronizeDirectory: (URL) throws -> Void = { directoryURL in
        let descriptor = unsafe Darwin.open(directoryURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if Darwin.fcntl(descriptor, F_FULLFSYNC) != 0,
           errno != EINVAL,
           errno != ENOTSUP {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static let live = WorkspaceAppendFileOperations()
}
