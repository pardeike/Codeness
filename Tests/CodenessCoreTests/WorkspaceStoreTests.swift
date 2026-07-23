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
            pauseAfterCurrent: true
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
}
