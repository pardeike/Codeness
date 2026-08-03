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
        try await store.appendTranscript("first\n", repositoryPath: record.canonicalPath, activityID: activity.id, runID: run.id)
        try await store.appendTranscript("second\n", repositoryPath: record.canonicalPath, activityID: activity.id, runID: run.id)

        let loaded = try await store.load(canonicalPath: record.canonicalPath)
        let transcript = try await store.recoveredTranscript(
            repositoryPath: record.canonicalPath,
            activityID: activity.id,
            runID: run.id
        )
        #expect(loaded == record)
        #expect(transcript == "first\nsecond\n")
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
                    prompt: "Implement"
                )
            ]
        )
        let record = RepositoryRecord(
            canonicalPath: "/tmp/archive-repository",
            implementerThreadID: "implementer-thread",
            reviewerThreadID: "reviewer-thread",
            activity: activity
        )

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
          "pauseAfterCurrent": false
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
        #expect(viewState.resumeAfterSystemTermination == nil)
        #expect(viewState.runSelectionWasSaved)
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
            pauseAfterCurrent: true,
            resumeAfterSystemTermination: true
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
        let destinationDirectory = await store.repositoryDirectory(canonicalPath: destinationPath)

        #expect(manifest.repositoryID == record.id)
        #expect(manifest.repositoryName == "CodenessFixture")
        #expect(manifest.originalCanonicalPath == sourcePath)
        #expect(preview.record == record)
        #expect(imported.backupURL == nil)
        #expect(imported.record == loaded)
        #expect(loaded.id == record.id)
        #expect(loaded.canonicalPath == destinationPath)
        #expect(loaded.implementerThreadID == nil)
        #expect(loaded.reviewerThreadID == nil)
        #expect(loaded.activity?.status == .paused)
        #expect(loaded.activity?.stepSessions["implement"]?.providerSessionID == nil)
        #expect(loaded.activity?.stepSessions["implement"]?.lineage == 4)
        #expect(importedViewState.windowFrame == viewState.windowFrame)
        #expect(importedViewState.resumeAfterSystemTermination == nil)
        #expect(transcript == "portable transcript\n")
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
