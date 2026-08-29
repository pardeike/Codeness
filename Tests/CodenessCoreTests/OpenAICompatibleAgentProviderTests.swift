import Foundation
import Testing
@testable import CodenessCore

struct OpenAICompatibleAgentProviderTests {
    @Test
    func supportsCustomDisplayNameAndLegacyConfigurationData() throws {
        let configured = OpenAICompatibleProviderConfiguration(
            endpoint: "http://localhost:1234/v1",
            apiKeyFile: "",
            apiKeyName: "",
            displayName: "Koala"
        )
        #expect(configured.displayName == "Koala")
        #expect(
            OpenAICompatibleProviderConfiguration(
                endpoint: "http://localhost:1234/v1",
                apiKeyFile: "",
                apiKeyName: "",
                displayName: "   "
            ).displayName == OpenAICompatibleProviderConfiguration.defaultDisplayName
        )

        let legacy = Data(
            #"{"endpoint":"http://localhost:1234/v1","apiKeyFile":"","apiKeyName":""}"#.utf8
        )
        let decoded = try JSONDecoder().decode(
            OpenAICompatibleProviderConfiguration.self,
            from: legacy
        )
        #expect(decoded.displayName == OpenAICompatibleProviderConfiguration.defaultDisplayName)
        #expect(
            OpenAICompatibleProviderConfiguration(
                endpoint: "http://localhost:1234/v1",
                apiKeyFile: "/keys.json",
                apiKeyName: ""
            ).validationMessage != nil
        )
        #expect(
            OpenAICompatibleProviderConfiguration(
                endpoint: "http://localhost:1234/v1",
                apiKeyFile: "",
                apiKeyName: "KEY"
            ).validationMessage != nil
        )
    }

    @Test
    func providerLaunchFenceUsesCustomDisplayName() async throws {
        let provider = OpenAICompatibleAgentProvider(
            configuration: .init(
                endpoint: "http://localhost:1234/v1",
                apiKeyFile: "",
                apiKeyName: "",
                displayName: "Koala"
            )
        )
        let registry = AgentProviderRegistry(providers: [provider])
        let fence = try await registry.fenceLaunches(for: .openAICompatible)

        do {
            _ = try await registry.fenceLaunches(for: .openAICompatible)
            Issue.record("Expected the second launch fence to be rejected")
        } catch {
            #expect(
                error.localizedDescription
                    == "Koala is restarting; new work is temporarily paused."
            )
        }
        await registry.resumeLaunches(fence)
    }

    @Test
    func normalizesEndpointSendsCompatibleRequestAndResumesConversation() async throws {
        let recorder = RequestRecorder()
        let transport = StubOpenAITransport(
            recorder: recorder,
            responses: [
                .json([
                    "choices": .array([
                        .object([
                            "message": .object([
                                "role": .string("assistant"),
                                "content": .string("First answer"),
                                "reasoning_content": .null,
                                "reasoning": .string("I checked the workspace first.")
                            ])
                        ])
                    ]),
                    "usage": .object([
                        "prompt_tokens": .integer(12),
                        "completion_tokens": .integer(5),
                        "total_tokens": .integer(17)
                    ])
                ]),
                .json([
                    "choices": .array([
                        .object([
                            "message": .object([
                                "role": .string("assistant"),
                                "content": .string("Second answer")
                            ])
                        ])
                    ]),
                    "usage": .object([
                        "prompt_tokens": .integer(20),
                        "completion_tokens": .integer(5),
                        "total_tokens": .integer(25)
                    ])
                ])
            ]
        )
        let provider = OpenAICompatibleAgentProvider(
            configuration: OpenAICompatibleProviderConfiguration(
                endpoint: "https://example.test/v1/",
                apiKeyFile: "/keys.json",
                apiKeyName: "TEST_KEY"
            ),
            transport: transport,
            keyLoader: FixedAPIKeyLoader(value: "secret")
        )
        let target = AgentTarget(
            providerID: .openAICompatible,
            model: "local-model",
            options: AgentExecutionOptions(effort: "high")
        )
        let session = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Fixture",
                cwd: FileManager.default.currentDirectoryPath,
                target: target,
                developerInstructions: "Be concise.",
                companyToolPolicy: CompanyToolPolicy(positionID: .researcher)
            )
        )

        let first = try await provider.startRun(
            AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: FileManager.default.currentDirectoryPath,
                prompt: "First prompt",
                target: target
            )
        )
        let firstEvents = await Self.collect(first.events)
        let resumedSession = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: session.id,
                name: "Fixture",
                cwd: FileManager.default.currentDirectoryPath,
                target: target,
                developerInstructions: "Be concise.",
                companyToolPolicy: CompanyToolPolicy(positionID: .researcher)
            )
        )
        let second = try await provider.startRun(
            AgentRunRequest(
                runID: UUID(),
                session: resumedSession,
                cwd: FileManager.default.currentDirectoryPath,
                prompt: "Second prompt",
                target: target
            )
        )
        _ = await Self.collect(second.events)

        #expect(firstEvents.contains {
            if case .transcript(let text) = $0 {
                return text == RunTranscriptPresentation.storedText(
                    "\n\nReasoning\nI checked the workspace first.\n",
                    section: .reasoning
                )
            }
            return false
        })
        #expect(firstEvents.contains {
            if case .transcript(let text) = $0 {
                return text == RunTranscriptPresentation.storedText(
                    "First answer",
                    section: .result
                )
            }
            return false
        })
        #expect(firstEvents.contains {
            if case .completed(let output, _, let usage) = $0 {
                return output == "First answer" && usage?.totalTokens == 17
            }
            return false
        })
        let requests = await recorder.requests
        #expect(requests.count == 2)
        let firstRequest = try #require(requests.first)
        #expect(firstRequest.url?.absoluteString == "https://example.test/v1/chat/completions")
        #expect(firstRequest.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let firstBody = try #require(firstRequest.httpBody)
        let body = try JSONDecoder().decode(JSONValue.self, from: firstBody)
        #expect(body["model"]?.stringValue == "local-model")
        #expect(body["reasoning_effort"]?.stringValue == "high")
        #expect(body["messages"]?.arrayValue?.contains {
            $0["role"]?.stringValue == "user"
                && $0["content"]?.stringValue == "First prompt"
        } == true)
        let systemContent = body["messages"]?.arrayValue?.first?[
            "content"
        ]?.stringValue ?? ""
        #expect(systemContent.contains("profession tool boundary"))
        #expect(!systemContent.contains("inspect, edit, build, and test"))
        #expect(body["tools"]?.arrayValue?.compactMap {
            $0["function"]?["name"]?.stringValue
        } == ["read", "glob", "grep"])
        let secondBody = try #require(requests[1].httpBody)
        let resumedBody = try JSONDecoder().decode(JSONValue.self, from: secondBody)
        #expect(resumedBody["messages"]?.arrayValue?.contains {
            $0["content"]?.stringValue == "First answer"
        } == true)
        #expect(resumedBody["messages"]?.arrayValue?.contains {
            $0["reasoning"]?.stringValue == "I checked the workspace first."
                && $0["reasoning_content"] == nil
        } == true)
    }

    @Test
    func executesReadOnlyToolCallsAndKeepsWritesOutOfPlanMode() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-openai-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("fixture text".utf8).write(to: directory.appendingPathComponent("note.txt"))

        let recorder = RequestRecorder()
        let transport = StubOpenAITransport(
            recorder: recorder,
            responses: [
                .json([
                    "choices": .array([
                        .object([
                            "message": .object([
                                "role": .string("assistant"),
                                "content": .null,
                                "tool_calls": .array([
                                    .object([
                                        "id": .string("call-1"),
                                        "type": .string("function"),
                                        "function": .object([
                                            "name": .string("read"),
                                            "arguments": .string("{\"filePath\":\"note.txt\"}")
                                        ])
                                    ])
                                ])
                            ])
                        ])
                    ]),
                    "usage": .object([
                        "prompt_tokens": .integer(8),
                        "completion_tokens": .integer(2),
                        "total_tokens": .integer(10)
                    ])
                ]),
                .json([
                    "choices": .array([
                        .object([
                            "message": .object([
                                "role": .string("assistant"),
                                "content": .string("The note says fixture text.")
                            ])
                        ])
                    ]),
                    "usage": .object([
                        "prompt_tokens": .integer(20),
                        "completion_tokens": .integer(5),
                        "total_tokens": .integer(25)
                    ])
                ])
            ]
        )
        let provider = OpenAICompatibleAgentProvider(
            configuration: OpenAICompatibleProviderConfiguration(
                endpoint: "http://localhost:1234/v1",
                apiKeyFile: "",
                apiKeyName: ""
            ),
            transport: transport
        )
        let target = AgentTarget(
            providerID: .openAICompatible,
            model: "local-model",
            options: AgentExecutionOptions(mode: .plan)
        )
        let session = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Plan",
                cwd: directory.path,
                target: target,
                developerInstructions: "Inspect only."
            )
        )
        let handle = try await provider.startRun(
            AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: directory.path,
                prompt: "Read note.txt",
                target: target
            )
        )
        let events = await Self.collect(handle.events)

        #expect(events.contains {
            if case .transcript(let text) = $0 {
                return text == RunTranscriptPresentation.storedText(
                    "Using read…\n",
                    section: .action
                )
            }
            return false
        })
        #expect(events.contains {
            if case .completed(let output, _, _) = $0 {
                return output.contains("fixture text")
            }
            return false
        })
        #expect(events.contains {
            if case .completed(_, _, let usage) = $0 {
                return usage?.totalTokens == 35
                    && usage?.inputTokens == 28
                    && usage?.outputTokens == 7
            }
            return false
        })
        let requests = await recorder.requests
        #expect(requests.count == 2)
        let firstBody = try #require(requests.first?.httpBody)
        let body = try JSONDecoder().decode(JSONValue.self, from: firstBody)
        let names = body["tools"]?.arrayValue?.compactMap {
            $0["function"]?["name"]?.stringValue
        } ?? []
        #expect(names == ["read", "glob", "grep"])
    }

    @Test
    func advertisesOpenCodeCoreToolsAndAllowsAbsoluteEdits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-openai-tools-\(UUID().uuidString)")
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        let externalFile = directory.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("before".utf8).write(to: externalFile)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = RequestRecorder()
        let transport = StubOpenAITransport(
            recorder: recorder,
            responses: [
                .toolCall(
                    name: "edit",
                    arguments: [
                        "filePath": .string(externalFile.path),
                        "oldString": .string("before"),
                        "newString": .string("after")
                    ]
                ),
                .answer("Edited and verified.")
            ]
        )
        let provider = OpenAICompatibleAgentProvider(
            configuration: .init(
                endpoint: "http://localhost:1234/v1",
                apiKeyFile: "",
                apiKeyName: ""
            ),
            transport: transport
        )
        let target = AgentTarget(providerID: .openAICompatible, model: "local-model")
        let session = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Tools",
                cwd: workspace.path,
                target: target,
                developerInstructions: "Use the available tools."
            )
        )
        let handle = try await provider.startRun(
            AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: workspace.path,
                prompt: "Edit the file.",
                target: target
            )
        )
        let events = await Self.collect(handle.events)

        let editedContent = try String(contentsOf: externalFile, encoding: .utf8)
        #expect(editedContent == "after")
        #expect(events.contains {
            if case .completed(let output, _, _) = $0 {
                return output == "Edited and verified."
            }
            return false
        })
        let recordedRequests = await recorder.requests
        let firstRequest = try #require(recordedRequests.first)
        let body = try JSONDecoder().decode(
            JSONValue.self,
            from: try #require(firstRequest.httpBody)
        )
        let tools = body["tools"]?.arrayValue ?? []
        #expect(tools.compactMap { $0["function"]?["name"]?.stringValue } == [
            "bash", "read", "glob", "grep", "edit", "write"
        ])
        let bash = try #require(tools.first {
            $0["function"]?["name"]?.stringValue == "bash"
        })
        #expect(
            bash["function"]?["parameters"]?["properties"]?["timeout"]?["type"]?.stringValue
                == "integer"
        )
    }

    @Test
    func bashCanRunAndVerifyWorkFromTheSelectedDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-openai-bash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = RequestRecorder()
        let provider = OpenAICompatibleAgentProvider(
            configuration: .init(
                endpoint: "http://localhost:1234/v1",
                apiKeyFile: "",
                apiKeyName: ""
            ),
            transport: StubOpenAITransport(
                recorder: recorder,
                responses: [
                    .toolCall(
                        name: "bash",
                        arguments: [
                            "command": .string("printf tool-ran > proof.txt"),
                            "timeout": .integer(10_000)
                        ]
                    ),
                    .answer("The shell command succeeded.")
                ]
            )
        )
        let target = AgentTarget(providerID: .openAICompatible, model: "local-model")
        let session = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Bash",
                cwd: directory.path,
                target: target,
                developerInstructions: "Run and verify the work."
            )
        )
        let handle = try await provider.startRun(
            AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: directory.path,
                prompt: "Create the proof file.",
                target: target
            )
        )
        let events = await Self.collect(handle.events)

        #expect(
            try String(
                contentsOf: directory.appendingPathComponent("proof.txt"),
                encoding: .utf8
            ) == "tool-ran"
        )
        #expect(events.contains {
            if case .completed(let output, _, _) = $0 {
                return output == "The shell command succeeded."
            }
            return false
        })
        let requests = await recorder.requests
        let secondBody = try JSONDecoder().decode(
            JSONValue.self,
            from: try #require(requests.last?.httpBody)
        )
        #expect(secondBody["messages"]?.arrayValue?.contains {
            $0["role"]?.stringValue == "tool"
                && $0["content"]?.stringValue?.contains("exit 0") == true
        } == true)
    }

    @Test
    func acceptsObjectValuedToolArgumentsFromCompatibleServers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-openai-object-arguments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let toolResponse = HTTPResult.json([
            "choices": .array([
                .object([
                    "message": .object([
                        "role": .string("assistant"),
                        "content": .null,
                        "tool_calls": .array([
                            .object([
                                "id": .string("object-arguments"),
                                "type": .string("function"),
                                "function": .object([
                                    "name": .string("write"),
                                    "arguments": .object([
                                        "filePath": .string("object.txt"),
                                        "content": .string("accepted")
                                    ])
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])
        let provider = OpenAICompatibleAgentProvider(
            configuration: .init(
                endpoint: "http://localhost:1234/v1",
                apiKeyFile: "",
                apiKeyName: ""
            ),
            transport: StubOpenAITransport(
                recorder: RequestRecorder(),
                responses: [toolResponse, .answer("Done")]
            )
        )
        let target = AgentTarget(providerID: .openAICompatible, model: "local-model")
        let session = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Object arguments",
                cwd: directory.path,
                target: target,
                developerInstructions: "Use tools."
            )
        )
        let handle = try await provider.startRun(
            AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: directory.path,
                prompt: "Write the file.",
                target: target
            )
        )
        _ = await Self.collect(handle.events)

        #expect(
            try String(
                contentsOf: directory.appendingPathComponent("object.txt"),
                encoding: .utf8
            ) == "accepted"
        )
    }

    @Test
    func oversizedEndpointResponseFailsAndClosesTheEventStream() async throws {
        let provider = OpenAICompatibleAgentProvider(
            configuration: .init(
                endpoint: "http://localhost:1234/v1",
                apiKeyFile: "",
                apiKeyName: "",
                displayName: "Koala"
            ),
            transport: StubOpenAITransport(
                recorder: RequestRecorder(),
                responses: [.answer(String(repeating: "x", count: 2_048))]
            ),
            maximumResponseByteCount: 512
        )
        let target = AgentTarget(providerID: .openAICompatible, model: "local-model")
        let session = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Bounded response",
                cwd: FileManager.default.currentDirectoryPath,
                target: target,
                developerInstructions: "Answer briefly."
            )
        )
        let handle = try await provider.startRun(
            AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: FileManager.default.currentDirectoryPath,
                prompt: "Answer",
                target: target
            )
        )
        let events = await Self.collect(handle.events)

        #expect(events.contains {
            if case .failed(let detail) = $0 {
                return detail.contains("Koala") && detail.contains("response-memory limit")
            }
            return false
        })
        #expect(!events.contains {
            if case .completed = $0 { return true }
            return false
        })
    }

    @Test
    func refreshingPreparedSessionReplacesSystemInstructions() async throws {
        let recorder = RequestRecorder()
        let provider = OpenAICompatibleAgentProvider(
            configuration: .init(
                endpoint: "http://localhost:1234/v1",
                apiKeyFile: "",
                apiKeyName: ""
            ),
            transport: StubOpenAITransport(
                recorder: recorder,
                responses: [.answer("Done")]
            )
        )
        let target = AgentTarget(providerID: .openAICompatible, model: "local-model")
        let first = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Instructions",
                cwd: FileManager.default.currentDirectoryPath,
                target: target,
                developerInstructions: "OLD INSTRUCTIONS"
            )
        )
        let refreshed = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: first.id,
                name: "Instructions",
                cwd: FileManager.default.currentDirectoryPath,
                target: target,
                developerInstructions: "NEW INSTRUCTIONS"
            )
        )
        let handle = try await provider.startRun(
            AgentRunRequest(
                runID: UUID(),
                session: refreshed,
                cwd: FileManager.default.currentDirectoryPath,
                prompt: "Continue",
                target: target
            )
        )
        _ = await Self.collect(handle.events)

        let recordedRequests = await recorder.requests
        let request = try #require(recordedRequests.first)
        let body = try JSONDecoder().decode(
            JSONValue.self,
            from: try #require(request.httpBody)
        )
        let system = try #require(body["messages"]?.arrayValue?.first?["content"]?.stringValue)
        #expect(system.contains("NEW INSTRUCTIONS"))
        #expect(!system.contains("OLD INSTRUCTIONS"))
    }

    @Test
    func continuesPastFormerRoundLimitWhenToolActivityIsNew() async throws {
        let recorder = RequestRecorder()
        let toolResponses = (1...40).map { index in
            HTTPResult.toolCall(
                name: "read",
                arguments: ["filePath": .string("missing-\(index).txt")],
                id: "call-\(index)"
            )
        }
        let provider = OpenAICompatibleAgentProvider(
            configuration: .init(
                endpoint: "http://localhost:1234/v1",
                apiKeyFile: "",
                apiKeyName: "",
                displayName: "Koala"
            ),
            transport: StubOpenAITransport(
                recorder: recorder,
                responses: toolResponses + [.answer("Finished after making progress.")]
            )
        )
        let target = AgentTarget(providerID: .openAICompatible, model: "local-model")
        let session = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Long run",
                cwd: FileManager.default.currentDirectoryPath,
                target: target,
                developerInstructions: "Keep making progress."
            )
        )
        let handle = try await provider.startRun(
            AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: FileManager.default.currentDirectoryPath,
                prompt: "Continue until finished.",
                target: target
            )
        )
        let events = await Self.collect(handle.events)

        let requestCount = await recorder.requests.count
        #expect(requestCount == 41)
        #expect(events.contains {
            if case .completed(let output, _, _) = $0 {
                return output == "Finished after making progress."
            }
            return false
        })
        #expect(!events.contains {
            if case .failed = $0 { return true }
            return false
        })
    }

    @Test
    func rejectsTruncatedAndReasoningOnlyFinalResponses() async throws {
        let target = AgentTarget(providerID: .openAICompatible, model: "local-model")
        let truncatedProvider = OpenAICompatibleAgentProvider(
            configuration: .init(
                endpoint: "http://localhost:1234/v1",
                apiKeyFile: "",
                apiKeyName: "",
                displayName: "Koala"
            ),
            transport: StubOpenAITransport(
                recorder: RequestRecorder(),
                responses: [
                    .json([
                        "choices": .array([
                            .object([
                                "finish_reason": .string("length"),
                                "message": .object([
                                    "role": .string("assistant"),
                                    "content": .string("Partial answer"),
                                    "thinking": .string("Still working")
                                ])
                            ])
                        ])
                    ])
                ]
            )
        )
        let truncatedSession = try await truncatedProvider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Truncated",
                cwd: FileManager.default.currentDirectoryPath,
                target: target,
                developerInstructions: "Finish the task."
            )
        )
        let truncatedHandle = try await truncatedProvider.startRun(
            AgentRunRequest(
                runID: UUID(),
                session: truncatedSession,
                cwd: FileManager.default.currentDirectoryPath,
                prompt: "Work",
                target: target
            )
        )
        let truncatedEvents = await Self.collect(truncatedHandle.events)
        #expect(truncatedEvents.contains {
            if case .transcript(let text) = $0 { return text.contains("Still working") }
            return false
        })
        #expect(truncatedEvents.contains {
            if case .failed(let detail) = $0 {
                return detail.contains("Koala") && detail.contains("output or context limit")
            }
            return false
        })

        let reasoningOnlyProvider = OpenAICompatibleAgentProvider(
            configuration: .init(
                endpoint: "http://localhost:1234/v1",
                apiKeyFile: "",
                apiKeyName: "",
                displayName: "Koala"
            ),
            transport: StubOpenAITransport(
                recorder: RequestRecorder(),
                responses: [
                    .json([
                        "choices": .array([
                            .object([
                                "message": .object([
                                    "role": .string("assistant"),
                                    "content": .null,
                                    "reasoning_content": .string("No final answer yet")
                                ])
                            ])
                        ])
                    ])
                ]
            )
        )
        let reasoningSession = try await reasoningOnlyProvider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Reasoning only",
                cwd: FileManager.default.currentDirectoryPath,
                target: target,
                developerInstructions: "Finish the task."
            )
        )
        let reasoningHandle = try await reasoningOnlyProvider.startRun(
            AgentRunRequest(
                runID: UUID(),
                session: reasoningSession,
                cwd: FileManager.default.currentDirectoryPath,
                prompt: "Work",
                target: target
            )
        )
        let reasoningEvents = await Self.collect(reasoningHandle.events)
        #expect(reasoningEvents.contains {
            if case .failed(let detail) = $0 {
                return detail.contains("ended without final answer text")
            }
            return false
        })
    }

    @Test
    func stopsAfterRepeatedToolActivity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-openai-loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("same result".utf8).write(to: directory.appendingPathComponent("note.txt"))

        let repeatedToolResponse = HTTPResult.json([
            "choices": .array([
                .object([
                    "message": .object([
                        "role": .string("assistant"),
                        "content": .null,
                        "tool_calls": .array([
                            .object([
                                "id": .string("repeat"),
                                "type": .string("function"),
                                "function": .object([
                                    "name": .string("read"),
                                    "arguments": .string("{\"filePath\":\"note.txt\"}")
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])
        let provider = OpenAICompatibleAgentProvider(
            configuration: OpenAICompatibleProviderConfiguration(
                endpoint: "http://localhost:1234/v1",
                apiKeyFile: "",
                apiKeyName: ""
            ),
            transport: StubOpenAITransport(
                recorder: RequestRecorder(),
                responses: Array(repeating: repeatedToolResponse, count: 17)
            )
        )
        let target = AgentTarget(
            providerID: .openAICompatible,
            model: "local-model"
        )
        let session = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Loop",
                cwd: directory.path,
                target: target,
                developerInstructions: "Inspect the repository."
            )
        )
        let handle = try await provider.startRun(
            AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: directory.path,
                prompt: "Read note.txt",
                target: target
            )
        )
        let events = await Self.collect(handle.events)

        #expect(events.contains {
            if case .failed(let detail) = $0 {
                return detail.contains("repeated the same tool command and output 16 times")
            }
            return false
        })
    }

    private static func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }
}

private actor RequestRecorder {
    private(set) var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        requests.append(request)
    }
}

private struct StubOpenAITransport: HTTPTransport {
    let recorder: RequestRecorder
    let responses: [HTTPResult]
    private let responseIndex: ResponseIndex

    init(recorder: RequestRecorder, responses: [HTTPResult]) {
        self.recorder = recorder
        self.responses = responses
        responseIndex = ResponseIndex()
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        await recorder.append(request)
        return await responseIndex.next(responses)
    }
}

private actor ResponseIndex {
    private var index = 0

    func next(_ responses: [HTTPResult]) -> HTTPResult {
        defer { index += 1 }
        return responses[min(index, max(0, responses.count - 1))]
    }
}

private struct FixedAPIKeyLoader: APIKeyLoading {
    let value: String

    func apiKey(file: String, name: String) async throws -> String {
        _ = file
        _ = name
        return value
    }
}

private extension HTTPResult {
    static func answer(_ content: String) -> HTTPResult {
        .json([
            "choices": .array([
                .object([
                    "message": .object([
                        "role": .string("assistant"),
                        "content": .string(content)
                    ])
                ])
            ])
        ])
    }

    static func toolCall(
        name: String,
        arguments: [String: JSONValue],
        id: String = "tool-call"
    ) -> HTTPResult {
        .json([
            "choices": .array([
                .object([
                    "finish_reason": .string("tool_calls"),
                    "message": .object([
                        "role": .string("assistant"),
                        "content": .null,
                        "tool_calls": .array([
                            .object([
                                "id": .string(id),
                                "type": .string("function"),
                                "function": .object([
                                    "name": .string(name),
                                    "arguments": .string(JSONValue.object(arguments).encodedString())
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])
    }

    static func json(_ value: [String: JSONValue]) -> HTTPResult {
        HTTPResult(
            data: try! JSONValue.object(value).encodedData(),
            statusCode: 200
        )
    }
}
