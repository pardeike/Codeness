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
            for await transportEvent in stream {
                let event = transportEvent.event
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
            if case .exited(let termination) = $0 {
                return termination == SubprocessTermination(
                    reason: .exit,
                    status: 7
                )
            }
            return false
        }
        #expect(notificationIndex != nil)
        #expect(exitIndex != nil)
        if let notificationIndex, let exitIndex {
            #expect(notificationIndex < exitIndex)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func preservesSignalTerminationForFriendlyPresentation() async throws {
        let fixture = try TransportFixture(script: Self.terminatedServer)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        try await client.start(configuration: fixture.configuration)

        let stream = await client.events()
        let terminationTask = Task { () -> SubprocessTermination? in
            for await transportEvent in stream {
                let event = transportEvent.event
                if case .exited(let termination) = event {
                    return termination
                }
            }
            return nil
        }

        let threadID = try await client.startThread(
            cwd: "/tmp",
            model: "fixture",
            developerInstructions: "fixture"
        )
        #expect(threadID == "thread-before-signal")

        let termination = await terminationTask.value
        #expect(termination?.reason == .uncaughtSignal)
        #expect(termination?.status == 15)
        #expect(
            termination?.userFacingDescription(subject: "Codex App Server")
                == "Codex App Server was stopped."
        )
    }

    @Test
    func sendsExperimentalCapabilityAndNativePlanParameters() async throws {
        let fixture = try TransportFixture(script: Self.planParameterServer)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        try await client.start(configuration: fixture.configuration)

        let threadID = try await client.startThread(
            cwd: "/tmp",
            model: "fixture",
            developerInstructions: "Plan only.",
            ephemeral: true,
            readOnly: true,
            approvalPolicy: "never",
            configuration: .object([
                "web_search": .string("live"),
                "tools": .object([
                    "web_search": .object([
                        "context_size": .string("medium")
                    ])
                ])
            ])
        )
        try await client.resumeThread(
            id: threadID,
            cwd: "/tmp",
            model: "fixture",
            developerInstructions: "Resume plan.",
            approvalPolicy: "never"
        )
        let turnID = try await client.startTurn(
            threadID: threadID,
            prompt: "Plan.",
            cwd: "/tmp",
            model: "fixture",
            effort: "high",
            mode: .plan,
            serviceTier: "dynamic-fast",
            outputSchema: .object(["type": .string("object")]),
            approvalPolicy: "never"
        )

        #expect(threadID == "thread-plan")
        #expect(turnID == "turn-plan")
        await client.shutdown()
    }

    @Test
    func loadedThreadIDsExhaustsEveryPaginationPage() async throws {
        let fixture = try TransportFixture(script: Self.paginatedLoadedThreadsServer)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        try await client.start(configuration: fixture.configuration)

        let identifiers = try await client.loadedThreadIDs()
        #expect(identifiers == Set(["thread-a", "thread-b", "thread-c"]))
        await client.shutdown()
    }

    @Test
    func loadedThreadIDsRejectsARepeatedPaginationCursor() async throws {
        let fixture = try TransportFixture(script: Self.repeatedLoadedThreadsCursorServer)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        try await client.start(configuration: fixture.configuration)

        do {
            _ = try await client.loadedThreadIDs()
            Issue.record("Expected repeated pagination cursor rejection")
        } catch {
            #expect(error.localizedDescription.contains("repeated a pagination cursor"))
        }
        await client.shutdown()
    }

    @Test
    func loadedThreadIDsRejectsAnOversizedAccumulatedResult() async throws {
        let fixture = try TransportFixture(script: Self.oversizedLoadedThreadsServer)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        try await client.start(configuration: fixture.configuration)

        do {
            _ = try await client.loadedThreadIDs()
            Issue.record("Expected loaded-thread identifier limit rejection")
        } catch {
            #expect(error.localizedDescription.contains("4096-identifier safety limit"))
        }
        await client.shutdown()
    }

    @Test
    func cleansAndListsBackgroundTerminalIdentifiersUsingTheCurrentProtocol() async throws {
        let fixture = try TransportFixture(script: Self.backgroundTerminalsServer)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        try await client.start(configuration: fixture.configuration)

        try await client.cleanBackgroundTerminals(threadID: "thread-background")
        let identifiers = try await client.backgroundTerminalIDs(
            threadID: "thread-background"
        )

        #expect(identifiers == Set(["process-1", "process-2"]))
        await client.shutdown()
    }

    @Test
    func backgroundTerminalIdentifiersRejectMalformedTerminalObjects() async throws {
        let fixture = try TransportFixture(
            script: Self.malformedBackgroundTerminalsServer
        )
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        try await client.start(configuration: fixture.configuration)

        do {
            _ = try await client.backgroundTerminalIDs(threadID: "thread-background")
            Issue.record("Expected malformed background-terminal rejection")
        } catch {
            #expect(error.localizedDescription.contains("invalid terminal"))
        }
        await client.shutdown()
    }

    @Test
    func deleteThreadRejectsAMalformedSuccessAcknowledgement() async throws {
        let fixture = try TransportFixture(script: Self.malformedThreadDeleteServer)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        try await client.start(configuration: fixture.configuration)

        do {
            try await client.deleteThread(id: "thread-delete")
            Issue.record("Expected malformed thread/delete acknowledgement rejection")
        } catch {
            #expect(error.localizedDescription.contains("empty object"))
        }
        await client.shutdown()
    }

    @Test
    func listModelsRejectsARepeatedPaginationCursor() async throws {
        let fixture = try TransportFixture(script: Self.repeatedModelsCursorServer)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        try await client.start(configuration: fixture.configuration)

        do {
            _ = try await client.listModels()
            Issue.record("Expected repeated model pagination cursor rejection")
        } catch {
            #expect(error.localizedDescription.contains("repeated a pagination cursor"))
        }
        await client.shutdown()
    }

    @Test
    func listModelsRejectsAnOversizedAccumulatedResult() async throws {
        let fixture = try TransportFixture(script: Self.oversizedModelsServer)
        defer { fixture.remove() }
        let client = CodexAppServerClient()
        try await client.start(configuration: fixture.configuration)

        do {
            _ = try await client.listModels()
            Issue.record("Expected model limit rejection")
        } catch {
            #expect(error.localizedDescription.contains("4096-model safety limit"))
        }
        await client.shutdown()
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

    private static let terminatedServer = #"""
import json
import os
import signal
import sys

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit({"id": identifier, "result": {"userAgent": "terminated-fixture"}})
    elif method == "thread/start":
        emit({"id": identifier, "result": {"thread": {"id": "thread-before-signal"}}})
        os.kill(os.getpid(), signal.SIGTERM)
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
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

    private static let planParameterServer = #"""
import json
import sys

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        assert message["params"]["capabilities"]["experimentalApi"] is True
        assert message["params"]["capabilities"]["mcpServerOpenaiFormElicitation"] is True
        emit({"id": identifier, "result": {"userAgent": "parameter-fixture"}})
    elif method == "thread/start":
        params = message["params"]
        assert params["ephemeral"] is True
        assert params["sandbox"] == "read-only"
        assert params["approvalPolicy"] == "never"
        assert params["config"] == {
            "web_search": "live",
            "tools": {"web_search": {"context_size": "medium"}}
        }
        emit({"id": identifier, "result": {"thread": {"id": "thread-plan"}}})
    elif method == "thread/resume":
        params = message["params"]
        assert params["threadId"] == "thread-plan"
        assert params["approvalPolicy"] == "never"
        emit({"id": identifier, "result": {"thread": {"id": "thread-plan"}}})
    elif method == "turn/start":
        params = message["params"]
        assert params["collaborationMode"] == {
            "mode": "plan",
            "settings": {
                "model": "fixture",
                "reasoning_effort": "high",
                "developer_instructions": None
            }
        }
        assert params["sandboxPolicy"] == {
            "type": "readOnly",
            "networkAccess": False
        }
        assert params["serviceTier"] == "dynamic-fast"
        assert params["outputSchema"] == {"type": "object"}
        assert params["approvalPolicy"] == "never"
        emit({
            "id": identifier,
            "result": {
                "turn": {
                    "id": "turn-plan",
                    "items": [],
                    "status": "inProgress"
                }
            }
        })
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#

    private static let paginatedLoadedThreadsServer = #"""
import json
import sys

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit({"id": identifier, "result": {"userAgent": "pagination-fixture"}})
    elif method == "thread/loaded/list":
        cursor = message.get("params", {}).get("cursor")
        if cursor is None:
            emit({"id": identifier, "result": {"data": ["thread-a", "thread-b"], "nextCursor": "page-2"}})
        elif cursor == "page-2":
            emit({"id": identifier, "result": {"data": ["thread-c"], "nextCursor": None}})
        else:
            emit({"id": identifier, "error": {"code": -32000, "message": "unexpected cursor"}})
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#

    private static let backgroundTerminalsServer = #"""
import json
import sys

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit({"id": identifier, "result": {"userAgent": "background-terminal-fixture"}})
    elif method == "thread/backgroundTerminals/clean":
        assert message.get("params") == {"threadId": "thread-background"}
        emit({"id": identifier, "result": {}})
    elif method == "thread/backgroundTerminals/list":
        params = message.get("params")
        assert params.get("threadId") == "thread-background"
        assert params.get("limit") == 256
        cursor = params.get("cursor")
        if cursor is None:
            emit({"id": identifier, "result": {"data": [{
                "processId": "process-1",
                "itemId": "item-1",
                "command": "sleep 1",
                "cwd": "/tmp",
                "osPid": 123,
                "rssKb": 456,
                "cpuPercent": 1.25
            }], "nextCursor": "terminal-page-2"}})
        elif cursor == "terminal-page-2":
            emit({"id": identifier, "result": {"data": [{
                "processId": "process-2",
                "itemId": "item-2",
                "command": "sleep 2",
                "cwd": "/tmp",
                "osPid": None,
                "rssKb": None,
                "cpuPercent": None
            }], "nextCursor": None}})
        else:
            emit({"id": identifier, "error": {"code": -32000, "message": "unexpected cursor"}})
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#

    private static let malformedBackgroundTerminalsServer = #"""
import json
import sys

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit({"id": identifier, "result": {"userAgent": "background-terminal-fixture"}})
    elif method == "thread/backgroundTerminals/list":
        emit({"id": identifier, "result": {"data": [{
            "processId": "process-1",
            "itemId": "item-1",
            "command": "sleep 1"
        }]}})
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#

    private static let malformedThreadDeleteServer = #"""
import json
import sys

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit({"id": identifier, "result": {"userAgent": "thread-delete-fixture"}})
    elif method == "thread/delete":
        emit({"id": identifier, "result": None})
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#

    private static let repeatedLoadedThreadsCursorServer = #"""
import json
import sys

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit({"id": identifier, "result": {"userAgent": "repeated-cursor-fixture"}})
    elif method == "thread/loaded/list":
        cursor = message.get("params", {}).get("cursor")
        data = ["thread-a"] if cursor is None else ["thread-b"]
        emit({"id": identifier, "result": {"data": data, "nextCursor": "stuck"}})
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#

    private static let oversizedLoadedThreadsServer = #"""
import json
import sys

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit({"id": identifier, "result": {"userAgent": "oversized-loaded-fixture"}})
    elif method == "thread/loaded/list":
        emit({"id": identifier, "result": {"data": ["thread-" + str(index) for index in range(4097)]}})
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#

    private static let repeatedModelsCursorServer = #"""
import json
import sys

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

def model(identifier):
    return {
        "id": identifier,
        "model": identifier,
        "displayName": identifier,
        "description": "Fixture",
        "defaultReasoningEffort": "high",
        "supportedReasoningEfforts": [
            {"reasoningEffort": "high", "description": "High"}
        ],
        "hidden": False,
        "isDefault": False
    }

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit({"id": identifier, "result": {"userAgent": "repeated-model-cursor-fixture"}})
    elif method == "model/list":
        cursor = message.get("params", {}).get("cursor")
        data = [model("model-a")] if cursor is None else [model("model-b")]
        emit({"id": identifier, "result": {"data": data, "nextCursor": "stuck"}})
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#

    private static let oversizedModelsServer = #"""
import json
import sys

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

def model(identifier):
    return {
        "id": identifier,
        "model": identifier,
        "displayName": identifier,
        "description": "Fixture",
        "defaultReasoningEffort": "high",
        "supportedReasoningEfforts": [
            {"reasoningEffort": "high", "description": "High"}
        ],
        "hidden": False,
        "isDefault": False
    }

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit({"id": identifier, "result": {"userAgent": "oversized-models-fixture"}})
    elif method == "model/list":
        emit({"id": identifier, "result": {"data": [model("model-" + str(index)) for index in range(4097)]}})
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
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
