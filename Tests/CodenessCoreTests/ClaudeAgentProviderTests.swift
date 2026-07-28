import Foundation
import Testing
@testable import CodenessCore

struct ClaudeAgentProviderTests {
    @Test
    func streamsRunsResumesSessionsAndMapsApprovalsQuestionsPlanAndFastMode() async throws {
        let fixture = try ClaudeCLIFixture()
        defer { fixture.remove() }
        let discoveredModels = try ClaudeExecutableInspector.models(
            executableURL: fixture.executableURL,
            environment: fixture.environment
        )
        #expect(discoveredModels.map(\.id) == ["opus", "sonnet"])
        #expect(discoveredModels.first?.supportsFastMode == true)
        #expect(
            discoveredModels.last?.supportedEfforts
                == ["low", "medium", "high"]
        )
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment
        )
        let target = AgentTarget(
            providerID: .claude,
            model: "sonnet",
            options: AgentExecutionOptions(
                effort: "high",
                mode: .plan,
                speed: .fast
            )
        )
        let firstSession = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Fixture — Review",
                cwd: fixture.directory.path,
                target: target,
                developerInstructions: "Review the repository carefully."
            )
        )
        let firstEvents = try await run(
            provider: provider,
            session: firstSession,
            target: target,
            cwd: fixture.directory.path
        )
        let standardTarget = AgentTarget(
            providerID: .claude,
            model: "sonnet",
            options: AgentExecutionOptions(
                effort: "high",
                mode: .standard,
                speed: .fast
            )
        )
        let resumedSession = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: firstSession.id,
                name: "Fixture — Review",
                cwd: fixture.directory.path,
                target: standardTarget,
                developerInstructions: "Review the repository carefully."
            )
        )
        let resumedEvents = try await run(
            provider: provider,
            session: resumedSession,
            target: standardTarget,
            cwd: fixture.directory.path
        )
        let utilityTarget = AgentTarget(
            providerID: .claude,
            model: "opus",
            options: AgentExecutionOptions(
                effort: "low",
                mode: .plan,
                speed: .fast
            )
        )
        let utilityResult = try await provider.runUtility(
            AgentUtilityRequest(
                cwd: fixture.directory.path,
                prompt: "Return the structured coordinator result.",
                target: utilityTarget,
                developerInstructions: "Coordinate without changing files.",
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "outcome": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("outcome")])
                ])
            )
        )
        try await Task.sleep(for: .milliseconds(100))

        #expect(firstSession.id == resumedSession.id)
        #expect(firstEvents.contains {
            if case .started(let executionID) = $0 {
                return executionID == firstSession.id
            }
            return false
        })
        #expect(firstEvents.contains {
            if case .interaction(let interaction) = $0 {
                return interaction.kind == .approval
                    && interaction.decisions.map(\.id).contains("allow")
            }
            return false
        })
        let firstTranscript = firstEvents.compactMap { event -> String? in
            guard case .transcript(let text) = event else { return nil }
            return text
        }.joined()
        let presentedTranscript = RunTranscriptPresentation.text(
            for: RunRecord(
                sequence: 1,
                role: .implementer,
                kind: .implementation,
                status: .completed,
                threadID: firstSession.id,
                model: target.model,
                effort: "high",
                prompt: "Run the configured review step.",
                transcript: firstTranscript
            ),
            separatesRuns: true
        )
        #expect(presentedTranscript.contains("Narrative after tool."))
        #expect(!presentedTranscript.contains("› Bash"))
        #expect(!firstEvents.contains {
            if case .diagnostic(let text) = $0 {
                return text.contains("Claude status:")
            }
            return false
        })
        #expect(resumedEvents.contains {
            if case .interaction(let interaction) = $0 {
                return interaction.kind == .questions
                    && interaction.questions.first?.question == "Choose a path"
            }
            return false
        })
        #expect(resumedEvents.contains {
            if case .completed(let output, let duration, let usage) = $0 {
                return output == "Claude fixture complete"
                    && duration == 12
                    && usage?.totalTokens == 18
                    && usage?.inputTokens == 14
            }
            return false
        })
        let utilityOutput = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(utilityResult.output.utf8)
        )
        #expect(utilityOutput["outcome"]?.stringValue == "continueWorkflow")

        let records = try fixture.records()
        let argumentLists: [[String]] = records.compactMap { record -> [String]? in
            guard record["kind"]?.stringValue == "arguments" else { return nil }
            return record["values"]?.arrayValue?.compactMap { $0.stringValue }
        }
        let runArgumentLists = argumentLists.filter { $0.contains("--name") }
        #expect(runArgumentLists.count == 3)
        let firstArguments = try #require(runArgumentLists.first)
        let secondArguments = runArgumentLists[1]
        let utilityArguments = try #require(runArgumentLists.last)
        #expect(firstArguments.contains("--model"))
        #expect(firstArguments.contains("sonnet"))
        #expect(firstArguments.contains("--effort"))
        #expect(firstArguments.contains("high"))
        #expect(firstArguments.contains("--permission-mode"))
        #expect(firstArguments.contains("plan"))
        #expect(firstArguments.contains("--allow-dangerously-skip-permissions"))
        #expect(firstArguments.contains("--permission-prompt-tool"))
        #expect(firstArguments.contains("stdio"))
        #expect(firstArguments.contains { $0.hasPrefix("--session-id=") })
        #expect(secondArguments.contains { $0 == "--resume=\(firstSession.id)" })
        let standardPermissionIndex = try #require(
            secondArguments.firstIndex(of: "--permission-mode")
        )
        #expect(secondArguments[standardPermissionIndex + 1] == "bypassPermissions")
        #expect(secondArguments.contains("--allow-dangerously-skip-permissions"))
        #expect(utilityArguments.contains("--no-session-persistence"))
        #expect(utilityArguments.contains("--json-schema"))
        #expect(utilityArguments.contains("--tools"))
        #expect(utilityArguments.contains(""))
        #expect(!utilityArguments.contains("--allow-dangerously-skip-permissions"))
        let utilityPermissionIndex = try #require(
            utilityArguments.firstIndex(of: "--permission-mode")
        )
        #expect(utilityArguments[utilityPermissionIndex + 1] == "dontAsk")
        let settingsIndex = try #require(
            firstArguments.firstIndex(of: "--settings")
        )
        let settings = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(firstArguments[settingsIndex + 1].utf8)
        )
        #expect(settings["fastMode"]?.boolValue == true)
        #expect(records.filter {
            $0["kind"]?.stringValue == "arguments"
        }.allSatisfy {
            $0["entrypoint"]?.stringValue == "cli"
        })

        let inputs = records.compactMap { record -> JSONValue? in
            guard record["kind"]?.stringValue == "input" else { return nil }
            return record["value"]
        }
        let userInputs = inputs.filter { $0["type"]?.stringValue == "user" }
        #expect(userInputs.count == 3)
        #expect(userInputs.prefix(2).allSatisfy {
            $0["session_id"]?.stringValue == firstSession.id
        })
        #expect(userInputs.last?["session_id"]?.stringValue != firstSession.id)
        let responses = inputs.filter {
            $0["type"]?.stringValue == "control_response"
                && $0["response"]?["request_id"]?.stringValue?.hasPrefix("permission-") == true
        }
        #expect(responses.count == 2)
        #expect(responses.allSatisfy {
            $0["response"]?["response"]?["toolUseID"]?.stringValue == "tool-1"
        })
        #expect(
            responses.last?["response"]?["response"]?["updatedInput"]?["answers"]?[
                "Choose a path"
            ]?.stringValue == "Path A"
        )
        await provider.shutdown()
    }

    private func run(
        provider: ClaudeAgentProvider,
        session: AgentSession,
        target: AgentTarget,
        cwd: String
    ) async throws -> [AgentEvent] {
        let runID = UUID()
        let handle = try await provider.startRun(
            AgentRunRequest(
                runID: runID,
                session: session,
                cwd: cwd,
                prompt: "Run the configured review step.",
                target: target
            )
        )
        var events: [AgentEvent] = []
        for await event in handle.events {
            events.append(event)
            guard case .interaction(let interaction) = event else { continue }
            switch interaction.kind {
            case .approval:
                let allow = try #require(
                    interaction.decisions.first { $0.id == "allow" }
                )
                try await provider.resolveInteraction(
                    runID: runID,
                    interactionID: interaction.id,
                    resolution: .decision(allow.payload)
                )
            case .questions:
                try await provider.resolveInteraction(
                    runID: runID,
                    interactionID: interaction.id,
                    resolution: .answers(["question-1": ["Path A"]])
                )
            case .dialog:
                try await provider.resolveInteraction(
                    runID: runID,
                    interactionID: interaction.id,
                    resolution: .raw(.object(["behavior": .string("completed")]))
                )
            }
        }
        return events
    }
}

private struct ClaudeCLIFixture {
    let directory: URL
    let executableURL: URL
    let logURL: URL

    var environment: [String: String] {
        var environment = CodexExecutableLocator.processEnvironment()
        environment["CLAUDE_FIXTURE_LOG"] = logURL.path
        return environment
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codeness-claude-fixture-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        executableURL = directory.appendingPathComponent("claude")
        logURL = directory.appendingPathComponent("events.jsonl")
        try Data(Self.script.utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    func records() throws -> [JSONValue] {
        let contents = String(
            decoding: try Data(contentsOf: logURL),
            as: UTF8.self
        )
        return try contents.split(whereSeparator: \.isNewline).map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let script = #"""
#!/usr/bin/python3
import json
import os
import sys

log_path = os.environ["CLAUDE_FIXTURE_LOG"]
is_resume = any(value.startswith("--resume=") for value in sys.argv[1:])
is_utility = "--no-session-persistence" in sys.argv[1:]

def log(value):
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(value) + "\n")

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

log({
    "kind": "arguments",
    "values": sys.argv[1:],
    "entrypoint": os.environ.get("CLAUDE_CODE_ENTRYPOINT")
})

for line in sys.stdin:
    value = json.loads(line)
    log({"kind": "input", "value": value})
    if value.get("type") == "control_request":
        request = value.get("request", {})
        if request.get("subtype") == "initialize":
            emit({
                "type": "control_response",
                "response": {
                    "subtype": "success",
                    "request_id": value["request_id"],
                    "response": {
                        "commands": [],
                        "models": [
                            {
                                "value": "opus",
                                "resolvedModel": "claude-opus-test",
                                "displayName": "Opus",
                                "description": "Fixture Opus",
                                "supportedEffortLevels": [
                                    "low", "medium", "high", "max"
                                ],
                                "supportsFastMode": True
                            },
                            {
                                "value": "sonnet",
                                "resolvedModel": "claude-sonnet-test",
                                "displayName": "Sonnet",
                                "description": "Fixture Sonnet",
                                "supportedEffortLevels": [
                                    "low", "medium", "high"
                                ],
                                "supportsFastMode": False
                            }
                        ]
                    }
                }
            })
    elif value.get("type") == "user":
        session_id = value.get("session_id", "")
        emit({"type": "system", "subtype": "init", "session_id": session_id})
        emit({"type": "system", "subtype": "status", "status": "requesting"})
        if is_utility:
            emit({
                "type": "result",
                "subtype": "success",
                "is_error": False,
                "duration_ms": 4,
                "structured_output": {"outcome": "continueWorkflow"},
                "usage": {
                    "input_tokens": 3,
                    "cache_read_input_tokens": 0,
                    "cache_creation_input_tokens": 0,
                    "output_tokens": 2
                }
            })
            break
        emit({
            "type": "stream_event",
            "event": {
                "type": "content_block_delta",
                "delta": {"type": "text_delta", "text": "Reviewing fixture."}
            }
        })
        if is_resume:
            emit({
                "type": "control_request",
                "request_id": "permission-question",
                "request": {
                    "subtype": "can_use_tool",
                    "tool_name": "AskUserQuestion",
                    "tool_use_id": "tool-1",
                    "input": {
                        "questions": [{
                            "header": "Path",
                            "question": "Choose a path",
                            "options": [
                                {"label": "Path A", "description": "Use A"},
                                {"label": "Path B", "description": "Use B"}
                            ],
                            "multiSelect": False
                        }]
                    }
                }
            })
        else:
            emit({
                "type": "stream_event",
                "event": {
                    "type": "content_block_start",
                    "content_block": {"type": "tool_use", "name": "Bash"}
                }
            })
            emit({
                "type": "control_request",
                "request_id": "permission-command",
                "request": {
                    "subtype": "can_use_tool",
                    "tool_name": "Bash",
                    "tool_use_id": "tool-1",
                    "input": {"command": "true"},
                    "decision_reason": "Exercise approval mapping."
                }
            })
    elif value.get("type") == "control_response":
        request_id = value.get("response", {}).get("request_id", "")
        if request_id.startswith("permission-"):
            emit({"type": "system", "subtype": "status", "status": "requesting"})
            emit({
                "type": "stream_event",
                "event": {
                    "type": "content_block_delta",
                    "delta": {
                        "type": "text_delta",
                        "text": "Narrative after tool."
                    }
                }
            })
            emit({
                "type": "assistant",
                "message": {
                    "content": [{"type": "text", "text": "Claude fixture complete"}],
                    "usage": {
                        "input_tokens": 10,
                        "cache_read_input_tokens": 3,
                        "cache_creation_input_tokens": 1,
                        "output_tokens": 4
                    }
                }
            })
            emit({
                "type": "result",
                "subtype": "success",
                "is_error": False,
                "duration_ms": 12,
                "result": "Claude fixture complete",
                "usage": {
                    "input_tokens": 10,
                    "cache_read_input_tokens": 3,
                    "cache_creation_input_tokens": 1,
                    "output_tokens": 4
                }
            })
            break
"""#
}
