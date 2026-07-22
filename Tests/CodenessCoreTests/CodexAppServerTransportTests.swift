import Foundation
import Testing
@testable import CodenessCore

struct CodexAppServerTransportTests {
    @Test(.timeLimit(.minutes(1)))
    func preservesProtocolOrderAcrossManySmallStdoutWrites() async throws {
        let fixture = try TransportFixture(script: Self.chunkedServer)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        try await client.start(configuration: fixture.configuration)

        for index in 1...24 {
            let threadID = try await client.startThread(
                cwd: "/tmp",
                model: "fixture",
                developerInstructions: "fixture"
            )
            #expect(threadID == "thread-\(index)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func drainsFinalResponseAndNotificationBeforePublishingExit() async throws {
        let fixture = try TransportFixture(script: Self.exitAfterResponseServer)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        try await client.start(configuration: fixture.configuration)

        let stream = await client.events()
        let collectedEvents = Task { () -> [AppServerEvent] in
            var events: [AppServerEvent] = []
            for await event in stream {
                events.append(event)
                if case .exited = event { break }
            }
            return events
        }

        let threadID = try await client.startThread(
            cwd: "/tmp",
            model: "fixture",
            developerInstructions: "fixture"
        )
        #expect(threadID == "thread-before-exit")

        let events = await collectedEvents.value
        let notificationIndex = events.firstIndex {
            if case .notification(let method, _, _) = $0 {
                return method == "turn/completed"
            }
            return false
        }
        let exitIndex = events.firstIndex {
            if case .exited(7) = $0 { return true }
            return false
        }
        #expect(notificationIndex != nil)
        #expect(exitIndex != nil)
        if let notificationIndex, let exitIndex {
            #expect(notificationIndex < exitIndex)
        }
    }

    private static let chunkedServer = #"""
import json
import os
import sys

thread_count = 0

def emit_chunked(value):
    payload = (json.dumps(value) + "\n").encode("utf-8")
    for byte in payload:
        os.write(sys.stdout.fileno(), bytes([byte]))

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit_chunked({"id": identifier, "result": {"userAgent": "chunked-fixture"}})
    elif method == "thread/start":
        thread_count += 1
        emit_chunked({"id": identifier, "result": {"thread": {"id": "thread-" + str(thread_count)}}})
        if thread_count == 24:
            os._exit(0)
    elif identifier is not None:
        emit_chunked({"id": identifier, "result": {}})
"""#

    private static let exitAfterResponseServer = #"""
import json
import os
import sys

def emit(value):
    return (json.dumps(value) + "\n").encode("utf-8")

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        os.write(sys.stdout.fileno(), emit({"id": identifier, "result": {"userAgent": "exit-fixture"}}))
    elif method == "thread/start":
        response = emit({"id": identifier, "result": {"thread": {"id": "thread-before-exit"}}})
        notification = emit({
            "method": "turn/completed",
            "params": {
                "threadId": "thread-before-exit",
                "turn": {"id": "turn-before-exit", "items": [], "status": "completed"}
            }
        })
        os.write(sys.stdout.fileno(), response + notification)
        sys.stdout.flush()
        os._exit(7)
    elif identifier is not None:
        os.write(sys.stdout.fileno(), emit({"id": identifier, "result": {}}))
"""#
}

private struct TransportFixture {
    let scriptURL: URL

    init(script: String) throws {
        scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-transport-\(UUID().uuidString).py")
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
