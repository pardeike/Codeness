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
