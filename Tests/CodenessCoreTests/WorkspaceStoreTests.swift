import CryptoKit
import Foundation
import Testing
@testable import CodenessCore

struct WorkspaceStoreTests {
    @Test
    func atomicallyPersistsMetadataAndAppendOnlyTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .running,
            threadID: "thread",
            model: "gpt-5.6-sol",
            effort: "high",
            prompt: "Implement"
        )
        let activity = ActivityRecord(goal: "Activity", prompts: .builtInDefaults, runs: [run])
        let record = RepositoryRecord(canonicalPath: "/tmp/repository", activity: activity)

        try await store.save(record)
        let repositoryDirectory = await store.repositoryDirectory(
            canonicalPath: record.canonicalPath
        )
        let payloadURL = repositoryDirectory
            .appendingPathComponent("activity/\(activity.id.uuidString)")
            .appendingPathComponent("\(run.id.uuidString).payload.json")
        #expect(FileManager.default.fileExists(atPath: payloadURL.path))
        try await store.appendTranscript("first\n", repositoryPath: record.canonicalPath, activityID: activity.id, runID: run.id)
        try await store.appendTranscript("second\n", repositoryPath: record.canonicalPath, activityID: activity.id, runID: run.id)

        let loaded = try await store.load(canonicalPath: record.canonicalPath)
        let transcript = try await store.recoveredTranscript(
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: run.id
        )
        let payload = try await store.recoveredRunPayload(
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: run.id
        )
        #expect(loaded.activity?.runs.first?.prompt == "Implement")
        #expect(loaded.activity?.runs.first?.externalPayload == true)
        #expect(payload == RunPayload(prompt: "Implement", finalOutput: nil))
        #expect(transcript == "first\nsecond\n")
    }

    @Test
    func newAppendTargetDirectorySyncFailureAdmitsNoPayloadAndRetriesOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let repositoryPath = "/tmp/new-target-preparation-\(UUID().uuidString)"
        let activityID = UUID()
        let runID = UUID()
        faults.arm(.directorySynchronizeFailures(1))

        await #expect(throws: InjectedAppendFailure.self) {
            try await store.appendTranscript(
                "first acknowledged chunk\n",
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            )
        }
        #expect(faults.writeCount() == 0)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ).isEmpty
        )

        try await store.appendTranscript(
            "first acknowledged chunk\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        #expect(faults.writeCount() == 1)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == "first acknowledged chunk\n"
        )
    }

    @Test
    func existingAppendTargetIsPreparedBeforeAStoresFirstPayloadAdmission() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repositoryPath = "/tmp/existing-target-preparation-\(UUID().uuidString)"
        let activityID = UUID()
        let runID = UUID()
        let initialStore = WorkspaceStore(rootURL: root)
        try await initialStore.appendTranscript(
            "existing chunk\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )

        let faults = AppendFileFaults()
        let reopenedStore = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        faults.arm(.directorySynchronizeFailures(1))
        await #expect(throws: InjectedAppendFailure.self) {
            try await reopenedStore.appendTranscript(
                "later chunk\n",
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            )
        }
        #expect(faults.writeCount() == 0)
        #expect(
            try await reopenedStore.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == "existing chunk\n"
        )

        try await reopenedStore.appendTranscript(
            "later chunk\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        #expect(faults.writeCount() == 1)
        #expect(
            try await reopenedStore.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == "existing chunk\nlater chunk\n"
        )
    }

    @Test
    func preparedAppendTargetsAreBoundedAndEvictedTargetsArePreparedAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let repositoryPath = "/tmp/bounded-append-preparation-\(UUID().uuidString)"
        let activityID = UUID()
        let runIDs = (0...WorkspaceStore.maximumPreparedAppendTargetCount).map { _ in UUID() }

        for runID in runIDs {
            try await store.appendTranscript(
                "initial\n",
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            )
        }

        let writesBeforeRevisit = faults.writeCount()
        faults.arm(.directorySynchronizeFailures(1))
        await #expect(throws: InjectedAppendFailure.self) {
            try await store.appendTranscript(
                "revisited\n",
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runIDs[0]
            )
        }
        #expect(faults.writeCount() == writesBeforeRevisit)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runIDs[0]
            ) == "initial\n"
        )

        try await store.appendTranscript(
            "revisited\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runIDs[0]
        )
        #expect(faults.writeCount() == writesBeforeRevisit + 1)
    }

    @Test
    func externallyReplacedAppendTargetIsPreparedAgainBeforeAppending() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let repositoryPath = "/tmp/replaced-append-target-\(UUID().uuidString)"
        let activityID = UUID()
        let runID = UUID()
        try await store.appendTranscript(
            "original\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )

        let repositoryDirectory = await store.repositoryDirectory(
            canonicalPath: repositoryPath
        )
        let transcriptURL = repositoryDirectory
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent(activityID.uuidString, isDirectory: true)
            .appendingPathComponent("\(runID.uuidString).transcript.txt")
        let replacementURL = transcriptURL
            .deletingLastPathComponent()
            .appendingPathComponent("replacement-\(UUID().uuidString).txt")
        try Data("external replacement\n".utf8).write(to: replacementURL)
        let originalInode = try #require(
            FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.systemFileNumber]
                as? NSNumber
        )
        let replacementInode = try #require(
            FileManager.default.attributesOfItem(atPath: replacementURL.path)[.systemFileNumber]
                as? NSNumber
        )
        #expect(originalInode != replacementInode)
        try FileManager.default.removeItem(at: transcriptURL)
        try FileManager.default.moveItem(at: replacementURL, to: transcriptURL)

        let writesBeforeRevisit = faults.writeCount()
        faults.arm(.directorySynchronizeFailures(1))
        await #expect(throws: InjectedAppendFailure.self) {
            try await store.appendTranscript(
                "continued\n",
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            )
        }
        #expect(faults.writeCount() == writesBeforeRevisit)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == "external replacement\n"
        )

        try await store.appendTranscript(
            "continued\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        #expect(faults.writeCount() == writesBeforeRevisit + 1)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == "external replacement\ncontinued\n"
        )
    }

    @Test
    func externallyDeletedAppendTargetIsRecreatedAndPreparedAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let repositoryPath = "/tmp/deleted-append-target-\(UUID().uuidString)"
        let activityID = UUID()
        let runID = UUID()
        try await store.appendTranscript(
            "removed externally\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )

        let transcriptURL = await store.repositoryDirectory(canonicalPath: repositoryPath)
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent(activityID.uuidString, isDirectory: true)
            .appendingPathComponent("\(runID.uuidString).transcript.txt")
        try FileManager.default.removeItem(at: transcriptURL)

        let writesBeforeRevisit = faults.writeCount()
        faults.arm(.directorySynchronizeFailures(1))
        await #expect(throws: InjectedAppendFailure.self) {
            try await store.appendTranscript(
                "recreated\n",
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            )
        }
        #expect(faults.writeCount() == writesBeforeRevisit)
        #expect(FileManager.default.fileExists(atPath: transcriptURL.path))
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ).isEmpty
        )

        try await store.appendTranscript(
            "recreated\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        #expect(faults.writeCount() == writesBeforeRevisit + 1)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == "recreated\n"
        )
    }

    @Test
    func firstAppendAfterAtomicTranscriptMigrationPreparesBeforeAdmittingSuffix() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = "durably migrated prefix\n"
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .running,
            threadID: "thread",
            model: "model",
            effort: "high",
            prompt: "Implement",
            transcript: transcript
        )
        let activity = ActivityRecord(
            goal: "Post-migration append",
            prompts: .builtInDefaults,
            runs: [run]
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/post-migration-append-\(UUID().uuidString)",
            activity: activity
        )
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        try await store.save(record)
        let writesBeforeAppend = faults.writeCount()
        faults.arm(.directorySynchronizeFailures(1))
        await #expect(throws: InjectedAppendFailure.self) {
            try await store.appendTranscript(
                "new suffix\n",
                repositoryPath: record.canonicalPath,
                activityID: activity.id,
                runID: run.id
            )
        }
        #expect(faults.writeCount() == writesBeforeAppend)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: record.canonicalPath,
                activityID: activity.id,
                runID: run.id
            ) == transcript
        )

        try await store.appendTranscript(
            "new suffix\n",
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: run.id
        )
        #expect(faults.writeCount() == writesBeforeAppend + 1)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: record.canonicalPath,
                activityID: activity.id,
                runID: run.id
            ) == transcript + "new suffix\n"
        )
    }

    @Test
    func failedPostRenameDirectorySyncInvalidatesPriorAppendPreparation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let repositoryPath = "/tmp/post-rename-preparation-\(UUID().uuidString)"
        let activityID = UUID()
        let runID = UUID()
        let original = "prepared prefix\n"
        let replacement = original + "migrated suffix\n"
        try await store.appendTranscript(
            original,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        let run = RunRecord(
            id: runID,
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .running,
            threadID: "thread",
            model: "model",
            effort: "high",
            prompt: "Implement",
            transcript: replacement
        )
        let activity = ActivityRecord(
            id: activityID,
            goal: "Post-rename append",
            prompts: .builtInDefaults,
            runs: [run]
        )
        let record = RepositoryRecord(
            canonicalPath: repositoryPath,
            activity: activity
        )

        faults.arm(.directorySynchronizeFailures(1))
        await #expect(throws: InjectedAppendFailure.self) {
            try await store.save(record)
        }
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == replacement
        )

        let writesBeforeAppend = faults.writeCount()
        faults.arm(.directorySynchronizeFailures(1))
        await #expect(throws: InjectedAppendFailure.self) {
            try await store.appendTranscript(
                "post-rename chunk\n",
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            )
        }
        #expect(faults.writeCount() == writesBeforeAppend)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == replacement
        )

        try await store.appendTranscript(
            "post-rename chunk\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        #expect(faults.writeCount() == writesBeforeAppend + 1)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == replacement + "post-rename chunk\n"
        )
    }

    @Test
    func synchronizeFailureAfterAFullWriteRecoversAsOneCommittedAppend() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let repositoryPath = "/tmp/synchronize-recovery-\(UUID().uuidString)"
        let activityID = UUID()
        let runID = UUID()
        try await store.appendTranscript(
            "existing prefix\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        let writesBeforeFault = faults.writeCount()
        faults.arm(.synchronizeFailures(1))

        try await store.appendTranscript(
            "committed once\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )

        #expect(faults.writeCount() == writesBeforeFault + 1)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == "existing prefix\ncommitted once\n"
        )
    }

    @Test
    func closeFailureAfterSynchronizedWriteRemainsOneCommittedAppend() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let repositoryPath = "/tmp/close-recovery-\(UUID().uuidString)"
        let activityID = UUID()
        let runID = UUID()
        try await store.appendTranscript(
            "existing prefix\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        let writesBeforeFault = faults.writeCount()
        faults.arm(.closeFailures(1))

        try await store.appendTranscript(
            "durably synchronized\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )

        #expect(faults.writeCount() == writesBeforeFault + 1)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == "existing prefix\ndurably synchronized\n"
        )
    }

    @Test
    func unconfirmedFullWriteRollsBackBeforeThrowingSoRetryCannotDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let repositoryPath = "/tmp/full-write-rollback-\(UUID().uuidString)"
        let activityID = UUID()
        let runID = UUID()
        try await store.appendTranscript(
            "existing prefix\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        let writesBeforeFault = faults.writeCount()
        faults.arm(.synchronizeFailures(2))

        await #expect(throws: InjectedAppendFailure.self) {
            try await store.appendTranscript(
                "retryable chunk\n",
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            )
        }
        #expect(faults.writeCount() == writesBeforeFault + 1)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == "existing prefix\n"
        )

        try await store.appendTranscript(
            "retryable chunk\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        #expect(faults.writeCount() == writesBeforeFault + 2)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == "existing prefix\nretryable chunk\n"
        )
    }

    @Test
    func partialWriteRollsBackBeforeThrowingSoRetryCannotDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let repositoryPath = "/tmp/partial-write-rollback-\(UUID().uuidString)"
        let activityID = UUID()
        let runID = UUID()
        try await store.appendTranscript(
            "existing\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        faults.arm(.partialWrite(5))

        await #expect(throws: InjectedAppendFailure.self) {
            try await store.appendTranscript(
                "complete chunk\n",
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            )
        }
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == "existing\n"
        )

        try await store.appendTranscript(
            "complete chunk\n",
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == "existing\ncomplete chunk\n"
        )
    }

    @Test
    func unexpectedTrailingBytesFailClosedAndBlockBlindRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let repositoryPath = "/tmp/ambiguous-write-\(UUID().uuidString)"
        let activityID = UUID()
        let runID = UUID()
        faults.arm(.unexpectedTrailingBytes(Data("external".utf8)))

        await #expect(throws: (any Error).self) {
            try await store.appendTranscript(
                "requested\n",
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            )
        }
        let outcomeAfterFailure = try await store.recoveredTranscript(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        await #expect(throws: (any Error).self) {
            try await store.appendTranscript(
                "requested\n",
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            )
        }
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == outcomeAfterFailure
        )
        #expect(outcomeAfterFailure == "requested\nexternal")
    }

    @Test
    func workspaceMetadataExternalizesLargeRunTextWithoutLosingIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let transcript = "unique transcript payload\n" + String(repeating: "detail\n", count: 500)
        let prompt = "unique prompt payload\n" + String(repeating: "instruction\n", count: 500)
        let finalOutput = "unique final payload\n" + String(repeating: "result\n", count: 500)
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: "thread",
            model: "gpt-5.6-sol",
            effort: "high",
            prompt: prompt,
            transcript: transcript,
            finalOutput: finalOutput
        )
        let activity = ActivityRecord(
            goal: "Externalize transcript",
            prompts: .builtInDefaults,
            status: .completed,
            runs: [run]
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/externalized-transcript-\(UUID().uuidString)",
            activity: activity
        )

        try await store.save(record)

        let directory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        let workspaceText = try String(
            contentsOf: directory.appendingPathComponent("workspace.json"),
            encoding: .utf8
        )
        let loaded = try await store.load(canonicalPath: record.canonicalPath)
        let recovered = try await store.recoveredTranscript(
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: run.id
        )
        let recoveredPayload = try await store.recoveredRunPayload(
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: run.id
        )

        #expect(!workspaceText.contains("unique transcript payload"))
        #expect(!workspaceText.contains("unique prompt payload"))
        #expect(!workspaceText.contains("unique final payload"))
        #expect(loaded.activity?.runs.first?.transcript == "")
        #expect(loaded.activity?.runs.first?.prompt == prompt)
        #expect(loaded.activity?.runs.first?.finalOutput == finalOutput)
        #expect(loaded.activity?.runs.first?.externalPayload == true)
        #expect(recovered == transcript)
        #expect(recoveredPayload == RunPayload(
            prompt: prompt,
            finalOutput: finalOutput
        ))
    }

    @Test
    func loadingALegacyWorkspaceDurablyMigratesEmbeddedTranscriptText() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: "thread",
            model: "model",
            effort: "high",
            prompt: "Implement",
            transcript: "legacy prefix\nnew metadata\n"
        )
        let activity = ActivityRecord(
            goal: "Migrate",
            prompts: .builtInDefaults,
            status: .completed,
            runs: [run]
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/legacy-transcript-\(UUID().uuidString)",
            activity: activity
        )
        let directory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        try JSONEncoder().encode(record).write(to: workspaceURL, options: .atomic)
        try await store.appendTranscript(
            "legacy prefix\n",
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: run.id
        )

        let loaded = try await store.load(canonicalPath: record.canonicalPath)
        let migratedWorkspace = try String(contentsOf: workspaceURL, encoding: .utf8)
        let recovered = try await store.recoveredTranscript(
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: run.id
        )

        #expect(loaded.activity?.runs.first?.transcript == "")
        #expect(!migratedWorkspace.contains("new metadata"))
        #expect(recovered == "legacy prefix\nnew metadata\n")
    }

    @Test
    func divergentLegacyTranscriptPreservesExactLogBeforeChoosingMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let prefix = "Reasoning\nFirst update.\n"
        let sharedTail = "Shared final output.\n"
        let metadata = prefix + "Metadata-only diagnostic.\n" + sharedTail
        let appendLog = prefix + sharedTail
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: "thread",
            model: "model",
            effort: "high",
            prompt: "Implement",
            transcript: metadata
        )
        let activity = ActivityRecord(
            goal: "Migrate divergent history",
            prompts: .builtInDefaults,
            status: .completed,
            runs: [run]
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/divergent-transcript-\(UUID().uuidString)",
            activity: activity
        )
        let directory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(
            to: directory.appendingPathComponent("workspace.json"),
            options: .atomic
        )
        try await store.appendTranscript(
            appendLog,
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: run.id
        )

        let firstLoad = try await store.load(canonicalPath: record.canonicalPath)
        let activityDirectory = directory
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent(activity.id.uuidString, isDirectory: true)
        let digest = sha256Hex(Data(appendLog.utf8))
        let sidecarURL = activityDirectory.appendingPathComponent(
            "\(run.id.uuidString).transcript.pre-externalization.\(digest).txt"
        )
        let canonicalURL = activityDirectory.appendingPathComponent(
            "\(run.id.uuidString).transcript.txt"
        )

        #expect(firstLoad.activity?.runs.first?.transcript == "")
        #expect(try Data(contentsOf: sidecarURL) == Data(appendLog.utf8))
        #expect(try Data(contentsOf: canonicalURL) == Data(metadata.utf8))

        let secondLoad = try await store.load(canonicalPath: record.canonicalPath)
        let sidecars = try FileManager.default.contentsOfDirectory(
            at: activityDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".transcript.pre-externalization.") }
        #expect(secondLoad.activity?.runs.first?.transcript == "")
        #expect(sidecars.map(\.lastPathComponent) == [sidecarURL.lastPathComponent])
        #expect(try Data(contentsOf: sidecarURL) == Data(appendLog.utf8))
        #expect(try Data(contentsOf: canonicalURL) == Data(metadata.utf8))
    }

    @Test
    func malformedTruncatedTranscriptIsBackedUpByteForByteBeforeMigration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let metadata = "Reasoning\nComplete metadata transcript.\n"
        let malformedBytes = Data(Array("Reasoning\ntruncated ".utf8) + [0xFF, 0xFE, 0x00])
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: "thread",
            model: "model",
            effort: "high",
            prompt: "Implement",
            transcript: metadata
        )
        let activity = ActivityRecord(
            goal: "Migrate malformed history",
            prompts: .builtInDefaults,
            status: .completed,
            runs: [run]
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/malformed-transcript-\(UUID().uuidString)",
            activity: activity
        )
        let directory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        let activityDirectory = directory
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent(activity.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(record).write(
            to: directory.appendingPathComponent("workspace.json"),
            options: .atomic
        )
        let canonicalURL = activityDirectory.appendingPathComponent(
            "\(run.id.uuidString).transcript.txt"
        )
        try malformedBytes.write(to: canonicalURL)

        _ = try await store.load(canonicalPath: record.canonicalPath)

        let sidecarURL = activityDirectory.appendingPathComponent(
            "\(run.id.uuidString).transcript.pre-externalization.\(sha256Hex(malformedBytes)).txt"
        )
        #expect(try Data(contentsOf: sidecarURL) == malformedBytes)
        #expect(try Data(contentsOf: canonicalURL) == Data(metadata.utf8))
    }

    @Test
    func invalidUTF8SuffixIsNotAcceptedAsAnAppendLogExtension() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let metadata = "Valid transcript prefix.\n"
        var invalidExtension = Data(metadata.utf8)
        invalidExtension.append(contentsOf: [0xF0, 0x28, 0x8C, 0x28])
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: "thread",
            model: "model",
            effort: "high",
            prompt: "Implement",
            transcript: metadata
        )
        let activity = ActivityRecord(
            goal: "Reject malformed extension",
            prompts: .builtInDefaults,
            status: .completed,
            runs: [run]
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/invalid-extension-\(UUID().uuidString)",
            activity: activity
        )
        let directory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        let activityDirectory = directory
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent(activity.id.uuidString, isDirectory: true)
        let canonicalURL = activityDirectory.appendingPathComponent(
            "\(run.id.uuidString).transcript.txt"
        )
        try FileManager.default.createDirectory(
            at: activityDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(record).write(to: workspaceURL)
        try invalidExtension.write(to: canonicalURL)

        let loaded = try await store.load(canonicalPath: record.canonicalPath)

        let sidecarURL = activityDirectory.appendingPathComponent(
            "\(run.id.uuidString).transcript.pre-externalization.\(sha256Hex(invalidExtension)).txt"
        )
        #expect(loaded.activity?.runs.first?.transcript == "")
        #expect(try Data(contentsOf: sidecarURL) == invalidExtension)
        #expect(try Data(contentsOf: canonicalURL) == Data(metadata.utf8))
    }

    @Test
    func failedSidecarRenameOutcomeCannotAdvanceCanonicalOrStripWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let metadata = "Metadata transcript.\n"
        let appendLog = "Divergent append log.\n"
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: "thread",
            model: "model",
            effort: "high",
            prompt: "Implement",
            transcript: metadata
        )
        let activity = ActivityRecord(
            goal: "Sidecar ordering",
            prompts: .builtInDefaults,
            status: .completed,
            runs: [run]
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/sidecar-ordering-\(UUID().uuidString)",
            activity: activity
        )
        let directory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: workspaceURL)
        try await store.appendTranscript(
            appendLog,
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: run.id
        )
        let activityDirectory = directory
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent(activity.id.uuidString, isDirectory: true)
        let canonicalURL = activityDirectory.appendingPathComponent(
            "\(run.id.uuidString).transcript.txt"
        )
        let sidecarURL = activityDirectory.appendingPathComponent(
            "\(run.id.uuidString).transcript.pre-externalization.\(sha256Hex(Data(appendLog.utf8))).txt"
        )
        faults.arm(.atomicReplaceAfterRename(destinationName: sidecarURL.lastPathComponent))

        await #expect(throws: InjectedAppendFailure.self) {
            _ = try await store.load(canonicalPath: record.canonicalPath)
        }

        let workspaceAfterFailure = try JSONDecoder().decode(
            RepositoryRecord.self,
            from: Data(contentsOf: workspaceURL)
        )
        #expect(workspaceAfterFailure.activity?.runs.first?.transcript == metadata)
        #expect(try Data(contentsOf: sidecarURL) == Data(appendLog.utf8))
        #expect(try Data(contentsOf: canonicalURL) == Data(appendLog.utf8))

        let recovered = try await store.load(canonicalPath: record.canonicalPath)
        #expect(recovered.activity?.runs.first?.transcript == "")
        #expect(try Data(contentsOf: sidecarURL) == Data(appendLog.utf8))
        #expect(try Data(contentsOf: canonicalURL) == Data(metadata.utf8))
    }

    @Test
    func failedCanonicalRenameOutcomeCannotStripWorkspaceBeforeLogRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let metadata = "Canonical metadata transcript.\n"
        let appendLog = "Divergent old transcript.\n"
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: "thread",
            model: "model",
            effort: "high",
            prompt: "Implement",
            transcript: metadata
        )
        let activity = ActivityRecord(
            goal: "Canonical ordering",
            prompts: .builtInDefaults,
            status: .completed,
            runs: [run]
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/canonical-ordering-\(UUID().uuidString)",
            activity: activity
        )
        let directory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: workspaceURL)
        try await store.appendTranscript(
            appendLog,
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: run.id
        )
        let activityDirectory = directory
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent(activity.id.uuidString, isDirectory: true)
        let canonicalURL = activityDirectory.appendingPathComponent(
            "\(run.id.uuidString).transcript.txt"
        )
        let sidecarURL = activityDirectory.appendingPathComponent(
            "\(run.id.uuidString).transcript.pre-externalization.\(sha256Hex(Data(appendLog.utf8))).txt"
        )
        faults.arm(.atomicReplaceAfterRename(destinationName: canonicalURL.lastPathComponent))

        await #expect(throws: InjectedAppendFailure.self) {
            _ = try await store.load(canonicalPath: record.canonicalPath)
        }

        let workspaceAfterFailure = try JSONDecoder().decode(
            RepositoryRecord.self,
            from: Data(contentsOf: workspaceURL)
        )
        #expect(workspaceAfterFailure.activity?.runs.first?.transcript == metadata)
        #expect(try Data(contentsOf: sidecarURL) == Data(appendLog.utf8))
        #expect(try Data(contentsOf: canonicalURL) == Data(metadata.utf8))

        let recovered = try await store.load(canonicalPath: record.canonicalPath)
        let workspaceAfterRecovery = try JSONDecoder().decode(
            RepositoryRecord.self,
            from: Data(contentsOf: workspaceURL)
        )
        #expect(recovered.activity?.runs.first?.transcript == "")
        #expect(workspaceAfterRecovery.activity?.runs.first?.transcript == "")
        #expect(try Data(contentsOf: sidecarURL) == Data(appendLog.utf8))
        #expect(try Data(contentsOf: canonicalURL) == Data(metadata.utf8))
    }

    @Test
    func workspaceRenameFailureLeavesEmbeddedMetadataUntilLogsAreDurable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let metadata = "Transcript that must remain recoverable.\n"
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: "thread",
            model: "model",
            effort: "high",
            prompt: "Implement",
            transcript: metadata
        )
        let activity = ActivityRecord(
            goal: "Workspace ordering",
            prompts: .builtInDefaults,
            status: .completed,
            runs: [run]
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/workspace-ordering-\(UUID().uuidString)",
            activity: activity
        )
        let directory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: workspaceURL)
        faults.arm(.atomicReplaceBeforeRename(destinationName: workspaceURL.lastPathComponent))

        await #expect(throws: InjectedAppendFailure.self) {
            _ = try await store.load(canonicalPath: record.canonicalPath)
        }

        let workspaceAfterFailure = try JSONDecoder().decode(
            RepositoryRecord.self,
            from: Data(contentsOf: workspaceURL)
        )
        let transcriptAfterFailure = try await store.recoveredTranscript(
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: run.id
        )
        #expect(workspaceAfterFailure.activity?.runs.first?.transcript == metadata)
        #expect(transcriptAfterFailure == metadata)

        let recovered = try await store.load(canonicalPath: record.canonicalPath)
        let workspaceAfterRecovery = try JSONDecoder().decode(
            RepositoryRecord.self,
            from: Data(contentsOf: workspaceURL)
        )
        #expect(recovered.activity?.runs.first?.transcript == "")
        #expect(workspaceAfterRecovery.activity?.runs.first?.transcript == "")
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: record.canonicalPath,
                activityID: activity.id,
                runID: run.id
            ) == metadata
        )
    }

    @Test
    func directorySynchronizationFailureLeavesEmbeddedMetadataForRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let metadata = "Transcript awaiting directory durability.\n"
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: "thread",
            model: "model",
            effort: "high",
            prompt: "Implement",
            transcript: metadata
        )
        let activity = ActivityRecord(
            goal: "Directory synchronization ordering",
            prompts: .builtInDefaults,
            status: .completed,
            runs: [run]
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/directory-sync-ordering-\(UUID().uuidString)",
            activity: activity
        )
        let directory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: workspaceURL)
        faults.arm(.directorySynchronizeFailures(1))

        await #expect(throws: InjectedAppendFailure.self) {
            _ = try await store.load(canonicalPath: record.canonicalPath)
        }

        let workspaceAfterFailure = try JSONDecoder().decode(
            RepositoryRecord.self,
            from: Data(contentsOf: workspaceURL)
        )
        #expect(workspaceAfterFailure.activity?.runs.first?.transcript == metadata)
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: record.canonicalPath,
                activityID: activity.id,
                runID: run.id
            ) == metadata
        )

        let recovered = try await store.load(canonicalPath: record.canonicalPath)
        #expect(recovered.activity?.runs.first?.transcript == "")
        #expect(
            try await store.recoveredTranscript(
                repositoryPath: record.canonicalPath,
                activityID: activity.id,
                runID: run.id
            ) == metadata
        )
    }

    @Test
    func recoversPerRunTokenUsageFromCumulativeThreadCounters() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let repositoryPath = "/tmp/token-repository"
        let activityID = UUID()
        let runID = UUID()
        let events = [
            tokenUsageEvent(
                total: usage(total: 5_100, input: 5_000, cached: 4_000, output: 100, reasoning: 20),
                last: usage(total: 100, input: 90, cached: 80, output: 10, reasoning: 2)
            ),
            tokenUsageEvent(
                total: usage(total: 5_600, input: 5_480, cached: 4_400, output: 120, reasoning: 25),
                last: usage(total: 500, input: 480, cached: 400, output: 20, reasoning: 5)
            ),
            tokenUsageEvent(
                total: usage(total: 5_600, input: 5_480, cached: 4_400, output: 120, reasoning: 25),
                last: usage(total: 500, input: 480, cached: 400, output: 20, reasoning: 5)
            )
        ]
        for event in events {
            try await store.appendRawLine(
                event,
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            )
        }

        let recovered = try #require(try await store.recoveredTokenUsage(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        ))

        #expect(recovered.totalTokens == 600)
        #expect(recovered.inputTokens == 570)
        #expect(recovered.cachedInputTokens == 480)
        #expect(recovered.outputTokens == 30)
        #expect(recovered.reasoningOutputTokens == 7)
    }

    @Test
    func recoversLatestProviderNeutralTokenUsageCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let repositoryPath = "/tmp/generic-token-repository"
        let activityID = UUID()
        let runID = UUID()
        let first = RunTokenUsage(
            totalTokens: 120,
            inputTokens: 100,
            cachedInputTokens: 30,
            outputTokens: 20
        )
        let latest = RunTokenUsage(
            totalTokens: 260,
            inputTokens: 220,
            cachedInputTokens: 80,
            cacheWriteInputTokens: 10,
            outputTokens: 40,
            reasoningOutputTokens: 5
        )

        try await store.appendTokenUsage(
            first,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        try await store.appendTokenUsage(
            latest,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )

        #expect(
            try await store.recoveredTokenUsage(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == latest
        )
    }

    @Test
    func tokenRecoverySkipsOversizedLineAndIgnoresIncompleteTail() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let repositoryPath = "/tmp/bounded-token-recovery-\(UUID().uuidString)"
        let activityID = UUID()
        let runID = UUID()
        let logDirectory = root
            .appendingPathComponent(WorkspaceStore.pathKey(repositoryPath), isDirectory: true)
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent(activityID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
        let rawLog = logDirectory.appendingPathComponent("\(runID.uuidString).raw.jsonl")
        #expect(FileManager.default.createFile(atPath: rawLog.path, contents: nil))
        let oversized = try FileHandle(forWritingTo: rawLog)
        try oversized.truncate(
            atOffset: UInt64(WorkspaceStore.maximumRecoveredRawJSONLineByteCount + 1_024)
        )
        try oversized.seekToEnd()
        try oversized.write(contentsOf: Data([0x0A]))
        try oversized.close()

        let expected = RunTokenUsage(
            totalTokens: 321,
            inputTokens: 280,
            cachedInputTokens: 120,
            cacheWriteInputTokens: 7,
            outputTokens: 41,
            reasoningOutputTokens: 9
        )
        try await store.appendTokenUsage(
            expected,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
        let incomplete = try FileHandle(forWritingTo: rawLog)
        try incomplete.seekToEnd()
        try incomplete.write(contentsOf: Data("{\"method\":\"thread/tokenUsage/updated\"".utf8))
        try incomplete.close()

        #expect(
            try await store.recoveredTokenUsage(
                repositoryPath: repositoryPath,
                activityID: activityID,
                runID: runID
            ) == expected
        )
    }

    @Test
    func archivesTheCompleteActivityRecordUnderApplicationSupport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let activity = ActivityRecord(
            goal: "Preserve this configuration",
            prompts: .builtInDefaults,
            status: .paused,
            runs: [
                RunRecord(
                    sequence: 1,
                    role: .implementer,
                    kind: .implementation,
                    status: .interrupted,
                    threadID: "implementer-thread",
                    model: "implement-model",
                    effort: "high",
                    prompt: "Implement",
                    transcript: "Archived transcript\n"
                )
            ]
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/archive-repository",
            implementerThreadID: "implementer-thread",
            reviewerThreadID: "reviewer-thread",
            activity: activity
        )

        try await store.save(record)
        let externalized = try await store.load(canonicalPath: record.canonicalPath)
        try await store.archiveActivity(externalized)

        let directory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        let archiveURL = directory
            .appendingPathComponent("activity-archives", isDirectory: true)
            .appendingPathComponent("\(activity.id.uuidString).json")
        let archived = try JSONDecoder().decode(
            RepositoryRecord.self,
            from: Data(contentsOf: archiveURL)
        )
        #expect(archived == record)
    }

    @Test
    func streamingActivityArchivePreservesLargeEscapedTranscript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let transcript = String(repeating: "A", count: 70_000)
            + "\"quoted\" \\ slash / tab\t nul\u{0} emoji 🧪\n"
            + String(repeating: "tail\n", count: 20_000)
        let activity = ActivityRecord(
            goal: "Archive without hydrating every transcript",
            prompts: .builtInDefaults,
            status: .completed,
            runs: [
                RunRecord(
                    sequence: 1,
                    role: .implementer,
                    kind: .implementation,
                    status: .completed,
                    threadID: "thread",
                    model: "gpt-5.6-sol",
                    effort: "high",
                    prompt: "Implement",
                    transcript: transcript
                )
            ]
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/streaming-archive-\(UUID().uuidString)",
            activity: activity
        )

        try await store.save(record)
        let externalized = try await store.load(canonicalPath: record.canonicalPath)
        try await store.archiveActivity(externalized)

        let directory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        let archiveURL = directory
            .appendingPathComponent("activity-archives", isDirectory: true)
            .appendingPathComponent("\(activity.id.uuidString).json")
        let archived = try JSONDecoder().decode(
            RepositoryRecord.self,
            from: Data(contentsOf: archiveURL)
        )
        #expect(archived.activity?.runs.first?.transcript == transcript)
    }

    @Test
    func archiveDirectorySyncFailureStopsResetBoundaryAndCanBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let activity = ActivityRecord(
            goal: "Require a durable archive",
            prompts: .builtInDefaults,
            status: .completed
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/durable-archive-\(UUID().uuidString)",
            activity: activity
        )
        try await store.save(record)

        faults.arm(.directorySynchronizeFailures(1))
        await #expect(throws: InjectedAppendFailure.self) {
            try await store.archiveActivity(record)
        }
        try await store.archiveActivity(record)

        let directory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        let archiveURL = directory
            .appendingPathComponent("activity-archives", isDirectory: true)
            .appendingPathComponent("\(activity.id.uuidString).json")
        let archived = try JSONDecoder().decode(
            RepositoryRecord.self,
            from: Data(contentsOf: archiveURL)
        )
        #expect(archived == record)
    }

    @Test
    func firstMetadataAndArchiveWritesSynchronizeNewParentDirectoryChain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("State", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let activity = ActivityRecord(
            goal: "Synchronize every new directory entry",
            prompts: .builtInDefaults,
            status: .completed
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/new-parent-sync-\(UUID().uuidString)",
            activity: activity
        )
        let repositoryDirectory = await store.repositoryDirectory(
            canonicalPath: record.canonicalPath
        ).standardizedFileURL

        try await store.save(record)
        let metadataSyncs = faults.synchronizedDirectoryPaths()
        #expect(metadataSyncs.contains(repositoryDirectory.path))
        #expect(metadataSyncs.contains(root.standardizedFileURL.path))
        #expect(metadataSyncs.contains(root.deletingLastPathComponent().standardizedFileURL.path))

        faults.clearSynchronizedDirectoryPaths()
        try await store.archiveActivity(record)
        let archiveDirectory = repositoryDirectory
            .appendingPathComponent("activity-archives", isDirectory: true)
            .standardizedFileURL
        let archiveSyncs = faults.synchronizedDirectoryPaths()
        #expect(archiveSyncs.contains(archiveDirectory.path))
        #expect(archiveSyncs.contains(repositoryDirectory.path))
        #expect(archiveSyncs.contains(root.standardizedFileURL.path))
    }

    @Test
    func repositoryKeysAreStableAndPathSpecific() {
        #expect(WorkspaceStore.pathKey("/a") == WorkspaceStore.pathKey("/a"))
        #expect(WorkspaceStore.pathKey("/a") != WorkspaceStore.pathKey("/b"))
        #expect(WorkspaceStore.pathKey("/a").count == 64)
    }

    @Test
    func persistsDocumentViewStateAndOpenDocumentRegistry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let runID = UUID()
        let state = RepositoryViewState(
            selectedRunID: runID,
            transcriptViewports: [
                runID: TranscriptViewportState(
                    topCharacterOffset: 412,
                    verticalOffset: 7.5,
                    followsOutput: false
                )
            ],
            windowFrame: StoredWindowFrame(
                x: 100,
                y: 200,
                width: 1_200,
                height: 800,
                displayIdentifier: "Studio Display"
            ),
            sidebarWidth: 365,
            sidebarVisible: true,
            pauseAfterCurrent: true,
            detailSplitFraction: 0.63,
            workOverviewSummary: WorkOverviewSummaryCache(
                sourceSignature: "summary-source",
                text: "Completed the parser foundation.",
                generatedAt: Date(timeIntervalSince1970: 1_000)
            )
        )

        try await store.saveViewState(state, canonicalPath: "/tmp/repository")
        try await store.saveOpenDocumentPaths(["/tmp/one", "/tmp/two"])

        #expect(try await store.loadViewState(canonicalPath: "/tmp/repository") == state)
        #expect(try await store.loadOpenDocumentPaths() == ["/tmp/one", "/tmp/two"])
    }

    @Test
    func decodesPreAmendmentActivitiesAndPrePresentationViewState() throws {
        let activity = ActivityRecord(
            goal: "Legacy goal",
            prompts: .builtInDefaults,
            status: .paused,
            goalAmendments: [
                GoalAmendment(previousGoal: "Earlier", revisedGoal: "Legacy goal")
            ]
        )
        let encodedActivity = try JSONEncoder().encode(activity)
        var activityObject = try #require(
            JSONSerialization.jsonObject(with: encodedActivity) as? [String: Any]
        )
        activityObject.removeValue(forKey: "goalAmendments")
        activityObject.removeValue(forKey: "pendingGoalAmendment")
        let legacyActivity = try JSONDecoder().decode(
            ActivityRecord.self,
            from: JSONSerialization.data(withJSONObject: activityObject)
        )

        let legacyViewState = """
        {
          "schemaVersion": 1,
          "selectedRunID": null,
          "transcriptViewports": [],
          "sidebarVisible": true,
          "pauseAfterCurrent": false,
          "resumeAfterSystemTermination": true
        }
        """
        let viewState = try JSONDecoder().decode(
            RepositoryViewState.self,
            from: Data(legacyViewState.utf8)
        )

        #expect(legacyActivity.goal == "Legacy goal")
        #expect(legacyActivity.goalAmendments.isEmpty)
        #expect(legacyActivity.pendingGoalAmendment == nil)
        #expect(viewState.detailPresentation == nil)
        #expect(viewState.detailSplitFraction == nil)
        #expect(viewState.workOverviewSummary == nil)
        #expect(viewState.runSelectionWasSaved)
        #expect(!String(decoding: try JSONEncoder().encode(viewState), as: UTF8.self)
            .contains("resumeAfterSystemTermination"))
    }

    @Test
    func decodesRunRecordsSavedBeforeTokenUsageWasPersisted() throws {
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: "thread",
            model: "model",
            effort: "high",
            prompt: "Implement"
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any]
        )
        object.removeValue(forKey: "tokenUsage")

        let decoded = try JSONDecoder().decode(
            RunRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.tokenUsage == nil)
    }

    @Test
    func corruptViewStateDoesNotAffectWorkspaceMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let record = RepositoryRecord(canonicalPath: "/tmp/repository")
        try await store.save(record)
        let directory = await store.repositoryDirectory(canonicalPath: record.canonicalPath)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("view-state.json"))

        await #expect(throws: (any Error).self) {
            _ = try await store.loadViewState(canonicalPath: record.canonicalPath)
        }
        #expect(try await store.load(canonicalPath: record.canonicalPath) == record)
    }

    @Test
    func newWorkspaceUsesProvidedModelDefaultsWithoutReplacingOtherSettings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let defaults = RepositoryModelDefaults(
            implementer: .init(model: "implement-model", effort: "medium"),
            reviewer: .init(model: "review-model", effort: "max"),
            fixer: .init(model: "fix-model", effort: "high"),
            handoff: .init(model: "handoff-model", effort: "low")
        )
        let base = RepositorySettings(
            relay: RelaySettings(apiKeyFile: "/keys.json", apiKeyName: "KEY")
        )
        let expected = defaults.applying(to: base)

        let loaded = try await store.load(
            canonicalPath: "/tmp/new-repository",
            defaultSettings: expected
        )

        #expect(loaded.settings == expected)
        #expect(loaded.settings.relay.apiKeyFile == "/keys.json")
        #expect(loaded.settings.relay.apiKeyName == "KEY")
    }

    @Test
    func persistedWorkspaceSettingsWinOverChangedGlobalDefaults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let originalSettings = RepositorySettings(
            implementer: .init(model: "saved-implementer", effort: "high"),
            reviewer: .init(model: "saved-reviewer", effort: "max"),
            fixer: .init(model: "saved-fixer", effort: "medium")
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/existing-repository",
            settings: originalSettings
        )
        try await store.save(record)
        let changedDefaults = RepositorySettings(
            implementer: .init(model: "new-default", effort: "low")
        )

        let loaded = try await store.load(
            canonicalPath: record.canonicalPath,
            defaultSettings: changedDefaults
        )

        #expect(loaded == record)
        #expect(loaded.settings == originalSettings)
    }

    @Test
    func workspaceTransferRelocatesPortableHistoryAndStartsWithFreshSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodenessTransferTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let sourcePath = "/Volumes/First Mac/Code/CodenessFixture"
        let destinationPath = "/Users/test/Code/CodenessFixture"
        let archiveURL = root.appendingPathComponent("Fixture.codeness")
        let target = AgentTarget(providerID: .codex, model: "gpt-5.6-sol")
        let workflow = WorkflowTemplate(
            id: "transfer-workflow",
            name: "Transfer workflow",
            summary: "Exercises portable session state",
            steps: [
                WorkflowStep(
                    id: "implement",
                    name: "Implement",
                    section: .loop,
                    instructions: "Implement the goal.",
                    target: target
                )
            ],
            coordinator: WorkflowCoordinatorConfiguration(
                target: target,
                instructions: "Coordinate the work."
            )
        )
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .interrupted,
            threadID: nil,
            model: target.model,
            effort: "high",
            prompt: "Implement",
            workflowStep: WorkflowStepSnapshot(step: workflow.steps[0], loopIteration: 1),
            agentTarget: target,
            sessionLineage: 3
        )
        let activity = ActivityRecord(
            goal: "Continue this work on another Mac",
            prompts: .builtInDefaults,
            status: .running,
            runs: [run],
            workflow: workflow,
            workflowCursor: WorkflowCursor(section: .loop, stepIndex: 0),
            workflowResumeCheckpoint: .recoverRun(run.id),
            stepSessions: [
                "implement": WorkflowSessionState(
                    stepID: "implement",
                    lineage: 3,
                    target: target,
                    providerSessionID: "provider-session-on-first-mac"
                )
            ]
        )
        let record = RepositoryRecord(
            canonicalPath: sourcePath,
            implementerThreadID: "legacy-implementer-thread",
            reviewerThreadID: "legacy-reviewer-thread",
            activity: activity
        )
        let viewState = RepositoryViewState(
            selectedRunID: run.id,
            windowFrame: StoredWindowFrame(x: 40, y: 50, width: 1_100, height: 720),
            sidebarWidth: 340,
            pauseAfterCurrent: true
        )

        try await store.save(record)
        try await store.saveViewState(viewState, canonicalPath: sourcePath)
        try await store.appendTranscript(
            "portable transcript\n",
            repositoryPath: sourcePath,
            activityID: activity.id,
            runID: run.id
        )
        try await store.archiveActivity(record)
        let sourceDirectory = await store.repositoryDirectory(canonicalPath: sourcePath)
        try Data("must not leave this Mac".utf8).write(
            to: sourceDirectory.appendingPathComponent("unrelated-private-state.json")
        )

        let manifest = try await store.exportWorkspace(
            canonicalPath: sourcePath,
            sourceAppVersion: "1.2.3",
            sourceAppBuild: "456",
            to: archiveURL
        )
        let preview = try await store.inspectWorkspaceTransfer(at: archiveURL)
        let imported = try await store.importWorkspace(
            from: archiveURL,
            to: destinationPath,
            sourceAppVersion: "1.2.4",
            sourceAppBuild: "457",
            replacingExisting: false
        )
        let loaded = try await store.load(canonicalPath: destinationPath)
        let importedViewState = try await store.loadViewState(canonicalPath: destinationPath)
        let transcript = try await store.recoveredTranscript(
            repositoryPath: destinationPath,
            activityID: activity.id,
            runID: run.id
        )
        let runPayload = try await store.recoveredRunPayload(
            repositoryPath: destinationPath,
            activityID: activity.id,
            runID: run.id
        )
        let destinationDirectory = await store.repositoryDirectory(canonicalPath: destinationPath)

        #expect(manifest.repositoryID == record.id)
        #expect(manifest.repositoryName == "CodenessFixture")
        #expect(manifest.originalCanonicalPath == sourcePath)
        #expect(preview.record.id == record.id)
        #expect(preview.record.activity?.runs.first?.externalPayload == true)
        #expect(preview.record.activity?.runs.first?.prompt == "")
        #expect(imported.backupURL == nil)
        #expect(imported.record.id == loaded.id)
        #expect(imported.record.activity?.runs.first?.prompt == "")
        #expect(loaded.activity?.runs.first?.prompt == "Implement")
        #expect(loaded.id == record.id)
        #expect(loaded.canonicalPath == destinationPath)
        #expect(loaded.implementerThreadID == nil)
        #expect(loaded.reviewerThreadID == nil)
        #expect(loaded.activity?.status == .paused)
        #expect(loaded.activity?.stepSessions["implement"]?.providerSessionID == nil)
        #expect(loaded.activity?.stepSessions["implement"]?.lineage == 4)
        #expect(importedViewState.windowFrame == viewState.windowFrame)
        #expect(transcript == "portable transcript\n")
        #expect(runPayload == RunPayload(prompt: "Implement", finalOutput: nil))
        #expect(FileManager.default.fileExists(
            atPath: destinationDirectory
                .appendingPathComponent("activity-archives/\(activity.id.uuidString).json")
                .path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: destinationDirectory
                .appendingPathComponent("unrelated-private-state.json")
                .path
        ))
    }

    @Test
    func workspaceImportBacksUpAndAtomicallyReplacesExistingState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodenessReplacementTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let sourcePath = "/tmp/portable-source"
        let destinationPath = "/tmp/existing-destination"
        let archiveURL = root.appendingPathComponent("Replacement.codeness")
        let source = RepositoryRecord(
            canonicalPath: sourcePath,
            activity: ActivityRecord(
                goal: "Imported goal",
                prompts: .builtInDefaults,
                status: .paused
            )
        )
        let existing = RepositoryRecord(
            canonicalPath: destinationPath,
            activity: ActivityRecord(
                goal: "Existing goal",
                prompts: .builtInDefaults,
                status: .paused
            )
        )
        try await store.save(source)
        try await store.exportWorkspace(
            canonicalPath: sourcePath,
            sourceAppVersion: "1",
            sourceAppBuild: "1",
            to: archiveURL
        )
        try await store.save(existing)

        await #expect(throws: WorkspaceTransferError.destinationExists(destinationPath)) {
            try await store.importWorkspace(
                from: archiveURL,
                to: destinationPath,
                sourceAppVersion: "2",
                sourceAppBuild: "2",
                replacingExisting: false
            )
        }

        let imported = try await store.importWorkspace(
            from: archiveURL,
            to: destinationPath,
            sourceAppVersion: "2",
            sourceAppBuild: "2",
            replacingExisting: true
        )
        let backupURL = try #require(imported.backupURL)
        let backup = try await store.inspectWorkspaceTransfer(at: backupURL)
        let loaded = try await store.load(canonicalPath: destinationPath)

        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(backup.record == existing)
        #expect(backup.manifest.originalCanonicalPath == destinationPath)
        #expect(loaded.id == source.id)
        #expect(loaded.canonicalPath == destinationPath)
        #expect(loaded.activity?.goal == "Imported goal")
    }

    @Test
    func workspaceImportClearsReplacedTranscriptAppendDebt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodenessImportAppendDebtTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = AppendFileFaults()
        let store = WorkspaceStore(
            rootURL: root,
            appendFileOperations: faults.operations
        )
        let sourcePath = "/tmp/import-append-debt-source-\(UUID().uuidString)"
        let destinationPath = "/tmp/import-append-debt-destination-\(UUID().uuidString)"
        let archiveURL = root.appendingPathComponent("AppendDebtReplacement.codeness")
        let activityID = UUID()
        let runID = UUID()

        func record(path: String, goal: String) -> RepositoryRecord {
            let run = RunRecord(
                id: runID,
                sequence: 1,
                role: .implementer,
                kind: .implementation,
                status: .interrupted,
                threadID: "thread",
                model: "gpt-5.6-sol",
                effort: "high",
                prompt: "Continue"
            )
            return RepositoryRecord(
                canonicalPath: path,
                activity: ActivityRecord(
                    id: activityID,
                    goal: goal,
                    prompts: .builtInDefaults,
                    status: .paused,
                    runs: [run]
                )
            )
        }

        try await store.save(record(path: sourcePath, goal: "Imported"))
        try await store.appendTranscript(
            "imported\n",
            repositoryPath: sourcePath,
            activityID: activityID,
            runID: runID
        )
        try await store.exportWorkspace(
            canonicalPath: sourcePath,
            sourceAppVersion: "1",
            sourceAppBuild: "1",
            to: archiveURL
        )

        try await store.save(record(path: destinationPath, goal: "Replaced"))
        faults.arm(.unexpectedTrailingBytes(Data("external".utf8)))
        await #expect(throws: (any Error).self) {
            try await store.appendTranscript(
                "ambiguous\n",
                repositoryPath: destinationPath,
                activityID: activityID,
                runID: runID
            )
        }
        await #expect(throws: (any Error).self) {
            try await store.appendTranscript(
                "must remain blocked\n",
                repositoryPath: destinationPath,
                activityID: activityID,
                runID: runID
            )
        }

        _ = try await store.importWorkspace(
            from: archiveURL,
            to: destinationPath,
            sourceAppVersion: "2",
            sourceAppBuild: "2",
            replacingExisting: true
        )
        try await store.appendTranscript(
            "continued\n",
            repositoryPath: destinationPath,
            activityID: activityID,
            runID: runID
        )

        #expect(
            try await store.recoveredTranscript(
                repositoryPath: destinationPath,
                activityID: activityID,
                runID: runID
            ) == "imported\ncontinued\n"
        )
    }

    @Test
    func workspaceTransferRejectsCorruptArchives() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodenessCorruptTransferTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("Corrupt.codeness")
        try Data("not an AppleArchive".utf8).write(to: archiveURL)
        let store = WorkspaceStore(rootURL: root.appendingPathComponent("State"))

        await #expect(throws: (any Error).self) {
            try await store.inspectWorkspaceTransfer(at: archiveURL)
        }
    }

    @Test
    func relocatedLegacyActivityIsPausedAndRecreatesItsProviderSessions() {
        let source = RepositoryRecord(
            canonicalPath: "/tmp/source",
            implementerThreadID: "implementer-thread",
            reviewerThreadID: "reviewer-thread",
            activity: ActivityRecord(
                goal: "Legacy activity",
                prompts: .builtInDefaults,
                status: .running,
                pendingAction: .review
            )
        )

        let relocated = source.relocatedForImport(to: "/tmp/destination")

        #expect(relocated.canonicalPath == "/tmp/destination")
        #expect(relocated.activity?.status == .paused)
        #expect(relocated.implementerThreadID == nil)
        #expect(relocated.reviewerThreadID == nil)
        #expect(relocated.requiresFreshProviderSessions)
    }

    private func sha256Hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        let bytes = SHA256.hash(data: data).flatMap { byte in
            [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func usage(
        total: Int64,
        input: Int64,
        cached: Int64,
        output: Int64,
        reasoning: Int64
    ) -> [String: Int64] {
        [
            "totalTokens": total,
            "inputTokens": input,
            "cachedInputTokens": cached,
            "cacheWriteInputTokens": 0,
            "outputTokens": output,
            "reasoningOutputTokens": reasoning
        ]
    }

    private func tokenUsageEvent(
        total: [String: Int64],
        last: [String: Int64]
    ) -> String {
        let object: [String: Any] = [
            "method": "thread/tokenUsage/updated",
            "params": [
                "threadId": "thread",
                "turnId": "turn",
                "tokenUsage": [
                    "total": total,
                    "last": last,
                    "modelContextWindow": 258_400
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

private enum InjectedAppendFailure: Error {
    case write
    case synchronize
    case close
    case atomicReplace
}

private final class AppendFileFaults: @unchecked Sendable {
    enum Fault {
        case synchronizeFailures(Int)
        case closeFailures(Int)
        case partialWrite(Int)
        case unexpectedTrailingBytes(Data)
        case atomicReplaceBeforeRename(destinationName: String)
        case atomicReplaceAfterRename(destinationName: String)
        case directorySynchronizeFailures(Int)
    }

    private let lock = NSLock()
    private var fault: Fault?
    private var writeInvocationCount = 0
    private var synchronizedDirectories: [String] = []

    var operations: WorkspaceAppendFileOperations {
        var operations = WorkspaceAppendFileOperations.live
        operations.write = { [self] handle, data in
            switch consumeWriteFault() {
            case .partialWrite(let count):
                try handle.write(contentsOf: Data(data.prefix(count)))
                throw InjectedAppendFailure.write
            case .unexpectedTrailingBytes(let trailingBytes):
                var unexpected = data
                unexpected.append(trailingBytes)
                try handle.write(contentsOf: unexpected)
                throw InjectedAppendFailure.write
            case nil:
                try handle.write(contentsOf: data)
            case .synchronizeFailures,
                 .closeFailures,
                 .atomicReplaceBeforeRename,
                 .atomicReplaceAfterRename,
                 .directorySynchronizeFailures:
                preconditionFailure("Non-write fault consumed by write operation")
            }
        }
        operations.synchronize = { [self] handle in
            if consumeCountedFault(for: .synchronize) {
                throw InjectedAppendFailure.synchronize
            }
            try handle.synchronize()
        }
        operations.close = { [self] handle in
            if consumeCountedFault(for: .close) {
                throw InjectedAppendFailure.close
            }
            try handle.close()
        }
        let liveAtomicReplace = WorkspaceAppendFileOperations.live.atomicReplace
        operations.atomicReplace = { [self] sourceURL, destinationURL in
            switch consumeAtomicReplaceFault(destinationName: destinationURL.lastPathComponent) {
            case .before:
                throw InjectedAppendFailure.atomicReplace
            case .after:
                try liveAtomicReplace(sourceURL, destinationURL)
                throw InjectedAppendFailure.atomicReplace
            case nil:
                try liveAtomicReplace(sourceURL, destinationURL)
            }
        }
        let liveSynchronizeDirectory = WorkspaceAppendFileOperations.live.synchronizeDirectory
        operations.synchronizeDirectory = { [self] directoryURL in
            recordSynchronizedDirectory(directoryURL)
            if consumeDirectorySynchronizeFault() {
                throw InjectedAppendFailure.synchronize
            }
            try liveSynchronizeDirectory(directoryURL)
        }
        return operations
    }

    func arm(_ fault: Fault) {
        lock.lock()
        defer { lock.unlock() }
        precondition(self.fault == nil)
        self.fault = fault
    }

    func writeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return writeInvocationCount
    }

    func synchronizedDirectoryPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return synchronizedDirectories
    }

    func clearSynchronizedDirectoryPaths() {
        lock.lock()
        synchronizedDirectories.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private enum CountedFaultKind {
        case synchronize
        case close
    }

    private enum AtomicReplaceFaultTiming {
        case before
        case after
    }

    private func consumeCountedFault(for kind: CountedFaultKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch (kind, fault) {
        case (.synchronize, .synchronizeFailures(let remaining)),
             (.close, .closeFailures(let remaining)):
            fault = remaining > 1 ? countedFault(kind, remaining: remaining - 1) : nil
            return true
        default:
            return false
        }
    }

    private func countedFault(_ kind: CountedFaultKind, remaining: Int) -> Fault {
        switch kind {
        case .synchronize:
            .synchronizeFailures(remaining)
        case .close:
            .closeFailures(remaining)
        }
    }

    private func consumeWriteFault() -> Fault? {
        lock.lock()
        defer { lock.unlock() }
        writeInvocationCount += 1
        switch fault {
        case .partialWrite, .unexpectedTrailingBytes:
            defer { fault = nil }
            return fault
        case .synchronizeFailures,
             .closeFailures,
             .atomicReplaceBeforeRename,
             .atomicReplaceAfterRename,
             .directorySynchronizeFailures,
             nil:
            return nil
        }
    }

    private func consumeAtomicReplaceFault(
        destinationName: String
    ) -> AtomicReplaceFaultTiming? {
        lock.lock()
        defer { lock.unlock() }
        switch fault {
        case .atomicReplaceBeforeRename(let expectedName)
            where expectedName == destinationName:
            fault = nil
            return .before
        case .atomicReplaceAfterRename(let expectedName)
            where expectedName == destinationName:
            fault = nil
            return .after
        default:
            return nil
        }
    }

    private func consumeDirectorySynchronizeFault() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .directorySynchronizeFailures(let remaining) = fault else {
            return false
        }
        fault = remaining > 1 ? .directorySynchronizeFailures(remaining - 1) : nil
        return true
    }

    private func recordSynchronizedDirectory(_ url: URL) {
        lock.lock()
        synchronizedDirectories.append(url.standardizedFileURL.path)
        lock.unlock()
    }
}
