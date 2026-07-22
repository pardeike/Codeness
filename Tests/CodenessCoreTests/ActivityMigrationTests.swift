import Foundation
import Testing
@testable import CodenessCore

struct ActivityMigrationTests {
    @Test
    func migratesNewestLegacyTaskAndRetainsTheLegacyArchive() throws {
        let json = """
        {
          "canonicalPath": "/tmp/repository",
          "tasks": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "title": "Older task",
              "specification": "Older specification",
              "status": "completed",
              "runs": []
            },
            {
              "id": "00000000-0000-0000-0000-000000000002",
              "title": "Newest task",
              "specification": "Newest specification",
              "status": "paused",
              "runs": [],
              "pendingAction": { "fixAndContinue": {} }
            }
          ]
        }
        """

        let record = try JSONDecoder().decode(RepositoryRecord.self, from: Data(json.utf8))
        let activity = try #require(record.activity)

        #expect(activity.goal == "Newest task\n\nNewest specification")
        #expect(activity.status == .paused)
        #expect(activity.pendingAction == .fix)
        #expect(activity.prompts == .builtInDefaults)
        #expect(PromptBuilder.implementation(
            goal: activity.goal,
            template: activity.prompts.implementation
        ).contains("Newest specification"))
        #expect(PromptBuilder.review(
            goal: activity.goal,
            template: activity.prompts.review,
            implementationOutput: "Recent changes"
        ).contains("Newest specification"))
        #expect(PromptBuilder.fix(
            goal: activity.goal,
            template: activity.prompts.fix,
            reviewOutput: "Review findings"
        ).contains("Newest specification"))
        #expect(record.settings.fixer == record.settings.implementer)

        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record))
        #expect(encoded["tasks"]?.arrayValue?.count == 2)
        #expect(encoded["activity"]?["goal"]?.stringValue == "Newest task\n\nNewest specification")
        #expect(encoded["activity"]?["title"] == nil)
    }

    @Test
    func decodesLegacyPhaseNamesWithoutPersistingThemAgain() throws {
        let runKind = try JSONDecoder().decode(RunKind.self, from: Data(#""finalCloseout""#.utf8))
        let disposition = try JSONDecoder().decode(SourceDisposition.self, from: Data(#""closeoutComplete""#.utf8))

        #expect(runKind == .fix)
        #expect(disposition == .fixComplete)
        #expect(String(decoding: try JSONEncoder().encode(runKind), as: UTF8.self) == #""fix""#)
        #expect(String(decoding: try JSONEncoder().encode(disposition), as: UTF8.self) == #""fixComplete""#)
    }

    @Test
    func ignoresLegacyInMemoryRawEventLogsWithoutPersistingThemAgain() throws {
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: "thread",
            model: "gpt-test",
            effort: "medium",
            prompt: "Implement this.",
            transcript: "Result"
        )
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(run))
        var legacyObject = try #require(encoded.objectValue)
        legacyObject["rawEventLog"] = .string("{\"method\":\"turn/started\"}\n")

        let decoded = try JSONDecoder().decode(RunRecord.self, from: legacyObject.jsonValue.encodedData())
        let migrated = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded))

        #expect(decoded.transcript == "Result")
        #expect(migrated["rawEventLog"] == nil)
    }
}
