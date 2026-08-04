import Foundation
import Testing
@testable import Codeness
@testable import CodenessCore

@MainActor
struct AppServerGenerationRoutingTests {
    @Test(.timeLimit(.minutes(1)))
    func queuedOldGenerationEventsCannotMutateReplacementProviderState() async throws {
        let fixture = try GenerationRoutingFixture()
        defer { fixture.remove() }
        let appServer = CodexAppServerClient()

        // Establish generation N, clear it, and start replacement N+1 before
        // routing any of N's deliberately held event envelopes.
        try await appServer.start(configuration: fixture.configuration)
        #expect(await appServer.shutdown())
        try await appServer.start(configuration: fixture.configuration)
        #expect(await appServer.isLatestGeneration(2))

        let provider = CodexAgentProvider(
            appServer: appServer,
            models: [CodexModel(
                id: "fixture",
                model: "fixture",
                displayName: "Fixture",
                description: "Fixture",
                defaultEffort: "high",
                efforts: ["high"],
                hidden: false
            )]
        )
        let application = CodenessApplicationModel(
            appServer: appServer,
            testingCodexProvider: provider
        )
        let target = AgentTarget(providerID: .codex, model: "fixture")
        let session = AgentSession(
            providerID: .codex,
            id: "replacement-session",
            target: target
        )
        let runID = UUID()
        _ = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: "/tmp",
            prompt: "Keep the replacement run alive",
            target: target
        ))
        #expect(await provider.runEventSnapshot(runID: runID) != nil)

        let oldGenerationEvents: [AppServerEvent] = [
            .request(
                id: .string("old-request"),
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string(session.id),
                    "turnId": .string("replacement-turn")
                ]),
                rawLine: "old request"
            ),
            .notification(
                method: "turn/completed",
                params: .object([
                    "threadId": .string(session.id),
                    "turn": .object([
                        "id": .string("replacement-turn"),
                        "items": .array([]),
                        "status": .string("completed")
                    ])
                ]),
                rawLine: "old notification"
            ),
            .standardError("old generation diagnostic"),
            .exited(SubprocessTermination(reason: .exit, status: 9))
        ]

        for event in oldGenerationEvents {
            await application.route(AppServerTransportEvent(
                generation: 1,
                event: event
            ))
            #expect(await provider.runEventSnapshot(runID: runID) != nil)
            #expect(application.serverState == .starting)
        }

        #expect(await appServer.isRunning)
        #expect(await appServer.shutdown())
    }
}

private struct GenerationRoutingFixture {
    let scriptURL: URL

    init() throws {
        scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codeness-generation-routing-\(UUID().uuidString).py"
        )
        let script = #"""
import json
import os
import sys

def emit(value):
    os.write(sys.stdout.fileno(), (json.dumps(value) + "\n").encode("utf-8"))

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit({"id": identifier, "result": {"userAgent": "generation-routing"}})
    elif method == "turn/start":
        emit({"id": identifier, "result": {"turn": {
            "id": "replacement-turn",
            "items": [],
            "status": "inProgress"
        }}})
"""#
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
    }

    var configuration: CodexLaunchConfiguration {
        CodexLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [scriptURL.path]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: scriptURL)
    }
}
