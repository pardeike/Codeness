import Darwin
import Foundation
import Testing
@testable import CodenessCore

struct ClaudeAgentProviderTests {
    @Test
    func streamsRunsResumesSessionsAndMapsApprovalsQuestionsPlanAndFastMode() async throws {
        let fixture = try ClaudeCLIFixture()
        defer { fixture.remove() }
        let discoveredModels = try await OwnedSubprocessSupervisorTestLease.withLease {
            try await ClaudeExecutableInspector.models(
                executableURL: fixture.executableURL,
                environment: fixture.environment
            )
        }
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
                ]),
                allowsWebResearch: true
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
        #expect(utilityArguments.contains("WebSearch,WebFetch"))
        #expect(!utilityArguments.contains("Read"))
        #expect(!utilityArguments.contains("Bash"))
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

    @Test
    func reportsConfirmedMissingResumedSessionsBeforeStarted() async throws {
        let fixture = try ClaudeCLIFixture(missingOnResume: true)
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: "missing-claude-session",
                name: "Missing Claude fixture",
                cwd: fixture.directory.path,
                target: target,
                developerInstructions: "Continue the workflow."
            )
        )
        let events = try await run(
            provider: provider,
            session: session,
            target: target,
            cwd: fixture.directory.path
        )

        #expect(events.contains {
            if case .sessionUnavailable(let detail) = $0 {
                return detail.contains("No conversation found with session ID")
            }
            return false
        })
        #expect(!events.contains {
            if case .started = $0 { return true }
            return false
        })
        await provider.shutdown()
    }

    @Test
    func translatesSignalTerminationForLiveRuns() async throws {
        let fixture = try ClaudeCLIFixture(terminateOnRun: true)
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Terminated Claude fixture",
                cwd: fixture.directory.path,
                target: target,
                developerInstructions: "Continue the workflow."
            )
        )
        let events = try await run(
            provider: provider,
            session: session,
            target: target,
            cwd: fixture.directory.path
        )

        #expect(events.contains {
            if case .failed(let detail) = $0 {
                return detail == "Claude was stopped."
            }
            return false
        })
        #expect(!events.contains {
            if case .failed(let detail) = $0 {
                return detail.contains("15") || detail.contains("status")
            }
            return false
        })
        await provider.shutdown()
    }

    @Test
    func rejectsConcurrentRunsOnTheSamePersistentSession() async throws {
        let fixture = try ClaudeCLIFixture()
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(
            AgentSessionRequest(
                existingSessionID: nil,
                name: "Concurrent Claude fixture",
                cwd: fixture.directory.path,
                target: target,
                developerInstructions: "Continue the workflow."
            )
        )
        let firstHandle = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: fixture.directory.path,
            prompt: "Hold the persistent session open.",
            target: target
        ))

        await #expect(throws: AgentProviderError.self) {
            try await provider.startRun(AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: fixture.directory.path,
                prompt: "This concurrent turn must be rejected.",
                target: target
            ))
        }
        #expect(await provider.activeRunCount() == 1)

        await provider.shutdown()
        for await _ in firstHandle.events {}
    }

    @Test
    func enforcesTheConfiguredActiveProcessSafetyLimit() async throws {
        let fixture = try ClaudeCLIFixture()
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            maximumActiveProcessCount: 1
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        var sessions: [AgentSession] = []
        for index in 0..<2 {
            sessions.append(try await provider.prepareSession(
                AgentSessionRequest(
                    existingSessionID: nil,
                    name: "Limited Claude fixture \(index)",
                    cwd: fixture.directory.path,
                    target: target,
                    developerInstructions: "Continue the workflow."
                )
            ))
        }
        let firstHandle = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: sessions[0],
            cwd: fixture.directory.path,
            prompt: "Hold the only process slot.",
            target: target
        ))

        await #expect(throws: AgentProviderError.self) {
            try await provider.startRun(AgentRunRequest(
                runID: UUID(),
                session: sessions[1],
                cwd: fixture.directory.path,
                prompt: "Exceed the configured process limit.",
                target: target
            ))
        }
        #expect(await provider.activeRunCount() == 1)

        await provider.shutdown()
        for await _ in firstHandle.events {}
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingUtilityTerminatesAndForgetsItsClaudeProcess() async throws {
        let fixture = try ClaudeCLIFixture(hangUtility: true)
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment
        )
        let task = Task {
            try await provider.runUtility(AgentUtilityRequest(
                cwd: fixture.directory.path,
                prompt: "Wait until this utility is cancelled.",
                target: AgentTarget(providerID: .claude, model: "sonnet"),
                developerInstructions: "Coordinate without changing files.",
                outputSchema: .object(["type": .string("object")])
            ))
        }
        let clock = ContinuousClock()
        let launchDeadline = clock.now.advanced(by: .seconds(2))
        while await provider.activeRunCount() == 0, clock.now < launchDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await provider.activeRunCount() == 1)

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        let cleanupDeadline = clock.now.advanced(by: .seconds(2))
        while await provider.activeRunCount() != 0, clock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await provider.activeRunCount() == 0)
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func stubbornUtilityTreeRetainsItsSlotUntilLeaderAndChildAreGone() async throws {
        let fixture = try ClaudeCLIFixture(
            hangUtility: true,
            stubbornProcessTree: true
        )
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            maximumActiveProcessCount: 1,
            terminalExitGrace: .milliseconds(25),
            terminationGrace: .milliseconds(150),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )
        let utility = Task {
            try await provider.runUtility(AgentUtilityRequest(
                cwd: fixture.directory.path,
                prompt: "Remain alive until cancelled.",
                target: AgentTarget(providerID: .claude, model: "sonnet"),
                developerInstructions: "Coordinate without changing files.",
                outputSchema: .object(["type": .string("object")])
            ))
        }
        let process = try await waitForProcesses(fixture, count: 1).first
        let launched = try #require(process)
        let child = try #require(launched.child)

        utility.cancel()
        try await Task.sleep(for: .milliseconds(40))
        #expect(await provider.activeRunCount() == 1)
        #expect(Self.processExists(launched.leader))
        #expect(Self.processExists(child))
        #expect(Self.processGroupExists(launched.group))

        await #expect(throws: CancellationError.self) {
            try await utility.value
        }
        try await waitForProcessTreeToDisappear(launched)
        #expect(await provider.activeRunCount() == 0)

        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Post-cleanup slot fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))
        _ = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: fixture.directory.path,
            prompt: "The verified slot can be reused.",
            target: target
        ))
        #expect(try await waitForProcesses(fixture, count: 2).count == 2)
        await provider.shutdown()
        let second = try #require(try fixture.processRecords().last)
        try await waitForProcessTreeToDisappear(second)
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppedStdinWriterTimesOutAndKillsTheIsolatedProcessGroup() async throws {
        let fixture = try ClaudeCLIFixture(stopBeforeReadingInput: true)
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            terminalExitGrace: .milliseconds(20),
            terminationGrace: .milliseconds(60),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .milliseconds(80)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Stopped stdin fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))

        let launch = Task {
            try await provider.startRun(AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: fixture.directory.path,
                prompt: String(repeating: "p", count: 2 * 1_024 * 1_024),
                target: target
            ))
        }

        let process = try #require(try await waitForProcesses(fixture, count: 1).first)
        await #expect(throws: (any Error).self) {
            _ = try await launch.value
        }
        try await waitForProcessTreeToDisappear(process)
        #expect(await provider.activeRunCount() == 0)
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func resultThenHangBlocksPersistentSessionReuseUntilVerifiedCleanup() async throws {
        let fixture = try ClaudeCLIFixture(
            stubbornProcessTree: true,
            resultThenHang: true
        )
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            terminalExitGrace: .milliseconds(120),
            terminationGrace: .milliseconds(120),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Result then hang fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))
        let firstHandle = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: fixture.directory.path,
            prompt: "Return a result and then refuse to exit.",
            target: target
        ))
        var firstCompleted = false
        for await event in firstHandle.events {
            if case .completed = event { firstCompleted = true }
        }
        #expect(firstCompleted)
        let firstProcess = try #require(try await waitForProcesses(fixture, count: 1).first)

        let secondStart = Task {
            try await provider.startRun(AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: fixture.directory.path,
                prompt: "Reuse only after the preceding process tree is gone.",
                target: target
            ))
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect((try fixture.processRecords()).count == 1)
        #expect(Self.processGroupExists(firstProcess.group))

        _ = try await secondStart.value
        #expect(try await waitForProcesses(fixture, count: 2).count == 2)
        try await waitForProcessTreeToDisappear(firstProcess)
        #expect(await provider.activeRunCount() == 1)

        await provider.shutdown()
        let secondProcess = try #require(try fixture.processRecords().last)
        try await waitForProcessTreeToDisappear(secondProcess)
    }

    @Test(.timeLimit(.minutes(1)))
    func abandonedEventConsumerTriggersBoundedBackpressureTeardown() async throws {
        let fixture = try ClaudeCLIFixture(
            stubbornProcessTree: true,
            floodOutput: true
        )
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            eventBufferCapacity: 2,
            maximumEventBufferRetainedBytes: 1_024,
            terminalExitGrace: .milliseconds(20),
            terminationGrace: .milliseconds(60),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Backpressure fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))
        let handle = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: fixture.directory.path,
            prompt: "Flood the bounded event consumer.",
            target: target
        ))
        let process = try #require(try await waitForProcesses(fixture, count: 1).first)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while await provider.activeRunCount() != 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await provider.activeRunCount() == 0)
        try await waitForProcessTreeToDisappear(process)

        var events: [AgentEvent] = []
        for await event in handle.events { events.append(event) }
        #expect(events.contains {
            if case .failed(let detail) = $0 {
                return detail.contains("could retain")
                    || detail.contains("unbounded memory growth")
            }
            return false
        })
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func exactThirtyTwoMiBJSONLineIsAcceptedWhenNewlineArrivesLater() async throws {
        let exactLimit = 32 * 1_024 * 1_024
        let fixture = try ClaudeCLIFixture(outputLineByteCount: exactLimit)
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            terminalExitGrace: .milliseconds(20),
            terminationGrace: .milliseconds(60),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Exact output line fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))
        _ = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: fixture.directory.path,
            prompt: "Emit the exact bounded line.",
            target: target
        ))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            let sent = (try? fixture.records())?.contains {
                $0["kind"]?.stringValue == "output_line_sent"
            } == true
            if sent { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await provider.activeRunCount() == 1)
        await provider.shutdown()
        let process = try #require(try fixture.processRecords().first)
        try await waitForProcessTreeToDisappear(process)
    }

    @Test(.timeLimit(.minutes(1)))
    func JSONLineOneBytePastThirtyTwoMiBFailsClosedAndTearsDown() async throws {
        let fixture = try ClaudeCLIFixture(
            outputLineByteCount: 32 * 1_024 * 1_024 + 1
        )
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            terminalExitGrace: .milliseconds(20),
            terminationGrace: .milliseconds(60),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Oversized output line fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))
        let handle = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: fixture.directory.path,
            prompt: "Exceed the bounded line by one byte.",
            target: target
        ))
        let process = try #require(try await waitForProcesses(fixture, count: 1).first)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while await provider.activeRunCount() != 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await provider.activeRunCount() == 0)
        try await waitForProcessTreeToDisappear(process)
        var events: [AgentEvent] = []
        for await event in handle.events { events.append(event) }
        #expect(events.contains {
            if case .failed(let detail) = $0 {
                return detail.contains("32 MiB safety limit")
            }
            return false
        })
        await provider.shutdown()
    }

    @Test
    func stdinDeadlineTreatsAnAlreadyCompletedWriteAsSuccess() {
        #expect(ClaudeAgentProvider.stdinWriteCompletedAtDeadline(.completed))
        #expect(!ClaudeAgentProvider.stdinWriteCompletedAtDeadline(.cancelledBeforeWrite))
        #expect(!ClaudeAgentProvider.stdinWriteCompletedAtDeadline(.writing))
        #expect(!ClaudeAgentProvider.stdinWriteCompletedAtDeadline(.failedAfterPartialWrite))
        #expect(!ClaudeAgentProvider.stdinWriteCompletedAtDeadline(.unknown))
    }

    @Test(.timeLimit(.minutes(1)))
    func ignoredInterruptEscalatesAndRemovesTheIsolatedProcessGroup() async throws {
        let fixture = try ClaudeCLIFixture(stubbornProcessTree: true)
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            outputDrainGrace: .seconds(2),
            terminationGrace: .milliseconds(60),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1),
            interruptGrace: .milliseconds(150)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Ignored interrupt fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))
        let runID = UUID()
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: fixture.directory.path,
            prompt: "Ignore the interrupt while keeping the process tree alive.",
            target: target
        ))
        let eventsTask = Task {
            var events: [AgentEvent] = []
            for await event in handle.events { events.append(event) }
            return events
        }
        let process = try #require(try await waitForProcesses(fixture, count: 1).first)

        let interruptStartedAt = ContinuousClock().now
        for attempt in 0..<3 {
            try await provider.interrupt(runID: runID)
            if attempt < 2 {
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        let events = await eventsTask.value

        #expect(events.contains {
            if case .interrupted(let detail) = $0 {
                return detail?.contains("did not stop") == true
            }
            return false
        })
        #expect(interruptStartedAt.duration(to: ContinuousClock().now) < .milliseconds(260))
        try await waitForProcessTreeToDisappear(process)
        try await waitForActiveRuns(provider, count: 0)
        #expect(await provider.activeRunCount() == 0)
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func interruptExitRaceDoesNotRetainCompletedWatchdogs() async throws {
        let fixture = try ClaudeCLIFixture(terminateOnInterrupt: true)
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            outputDrainGrace: .seconds(1),
            terminationGrace: .milliseconds(20),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1),
            interruptGrace: .milliseconds(100)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")

        for index in 0..<10 {
            let session = try await provider.prepareSession(AgentSessionRequest(
                existingSessionID: nil,
                name: "Interrupt exit race \(index)",
                cwd: fixture.directory.path,
                target: target,
                developerInstructions: "Continue the workflow."
            ))
            let runID = UUID()
            let handle = try await provider.startRun(AgentRunRequest(
                runID: runID,
                session: session,
                cwd: fixture.directory.path,
                prompt: "Exit while accepting this interrupt.",
                target: target
            ))
            let eventsTask = Task {
                for await _ in handle.events {}
            }
            try await provider.interrupt(runID: runID)
            await eventsTask.value
            #expect(await provider.releaseSession(id: session.id))
            #expect(await provider.activeRunCount() == 0)
            #expect(await provider.interruptWatchdogCount() == 0)
        }
        #expect(await provider.interruptWatchdogCount() == 0)
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func leaderExitWaitsForLargeMultiChunkResultToDrain() async throws {
        let resultByteCount = 2 * 1_024 * 1_024
        let fixture = try ClaudeCLIFixture(
            exitingResultByteCount: resultByteCount
        )
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            maximumEventBufferRetainedBytes: 4 * 1_024 * 1_024,
            terminalExitGrace: .zero,
            outputDrainGrace: .seconds(5),
            terminationGrace: .milliseconds(20),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Large exit result fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))
        let handle = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: fixture.directory.path,
            prompt: "Write a large result and exit immediately.",
            target: target
        ))

        var completedOutput: String?
        for await event in handle.events {
            if case .completed(let output, _, _) = event {
                completedOutput = output
            }
        }

        #expect(completedOutput?.utf8.count == resultByteCount)
        #expect(completedOutput?.allSatisfy { $0 == "r" } == true)
        #expect(await provider.activeRunCount() == 0)
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func unresolvedInteractionFloodFailsClosedWhileConsumerDrains() async throws {
        let fixture = try ClaudeCLIFixture(
            stubbornProcessTree: true,
            unresolvedInteractionCount: 80
        )
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            eventBufferCapacity: 256,
            maximumEventBufferRetainedBytes: 4 * 1_024 * 1_024,
            outputDrainGrace: .seconds(2),
            terminationGrace: .milliseconds(60),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Interaction flood fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))
        let handle = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: fixture.directory.path,
            prompt: "Emit unresolved permission requests.",
            target: target
        ))
        let process = try #require(try await waitForProcesses(fixture, count: 1).first)

        var interactionCount = 0
        var failure: String?
        for await event in handle.events {
            if case .interaction = event { interactionCount += 1 }
            if case .failed(let detail) = event { failure = detail }
        }

        #expect(interactionCount == 64)
        #expect(failure?.contains("too many unresolved permission requests") == true)
        try await waitForProcessTreeToDisappear(process)
        try await waitForActiveRuns(provider, count: 0)
        #expect(await provider.activeRunCount() == 0)
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func duplicateUnresolvedInteractionIDFailsClosedWithoutHiddenReplacement() async throws {
        let fixture = try ClaudeCLIFixture(
            stubbornProcessTree: true,
            duplicateInteractionID: true
        )
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            outputDrainGrace: .seconds(2),
            terminationGrace: .milliseconds(60),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Duplicate interaction fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))
        let handle = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: fixture.directory.path,
            prompt: "Reuse an unresolved interaction identifier.",
            target: target
        ))
        let process = try #require(try await waitForProcesses(fixture, count: 1).first)

        var interactionTitles: [String] = []
        var failure: String?
        for await event in handle.events {
            if case .interaction(let interaction) = event {
                interactionTitles.append(interaction.title)
            }
            if case .failed(let detail) = event { failure = detail }
        }

        #expect(interactionTitles == ["Approve Bash"])
        #expect(failure?.contains("reused an unresolved permission request identifier") == true)
        try await waitForProcessTreeToDisappear(process)
        try await waitForActiveRuns(provider, count: 0)
        #expect(await provider.activeRunCount() == 0)
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func terminalReleaseWaitsForVerifiedCleanupAndRemovesSessionConfiguration() async throws {
        let fixture = try ClaudeCLIFixture(
            stubbornProcessTree: true,
            resultThenHang: true
        )
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            terminalExitGrace: .milliseconds(150),
            outputDrainGrace: .seconds(2),
            terminationGrace: .milliseconds(80),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Terminal release fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Retained only until verified release."
        ))
        let handle = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: fixture.directory.path,
            prompt: "Return a terminal result before process cleanup.",
            target: target
        ))
        let process = try #require(try await waitForProcesses(fixture, count: 1).first)
        var completed = false
        for await event in handle.events {
            if case .completed = event {
                completed = true
                break
            }
        }
        #expect(completed)

        #expect(await provider.releaseSession(id: session.id))
        #expect(await provider.preparedSessionCount() == 0)
        #expect(await provider.activeRunCount() == 0)
        try await waitForProcessTreeToDisappear(process)
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func reprepareDuringTerminalReleasePreservesTheReplacementConfiguration() async throws {
        let fixture = try ClaudeCLIFixture(
            stubbornProcessTree: true,
            resultThenHang: true
        )
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            terminalExitGrace: .milliseconds(250),
            outputDrainGrace: .seconds(2),
            terminationGrace: .milliseconds(80),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Original configuration",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Original instructions"
        ))
        let handle = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: fixture.directory.path,
            prompt: "Return a result before replacement.",
            target: target
        ))
        for await event in handle.events {
            if case .completed = event { break }
        }

        let release = Task { await provider.releaseSession(id: session.id) }
        try await Task.sleep(for: .milliseconds(30))
        _ = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: session.id,
            name: "Replacement configuration",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Replacement instructions"
        ))
        #expect(await release.value)

        let snapshot = try #require(
            await provider.sessionConfigurationSnapshot(id: session.id)
        )
        #expect(snapshot.name == "Replacement configuration")
        #expect(snapshot.developerInstructions == "Replacement instructions")
        #expect(await provider.preparedSessionCount() == 1)
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func reprepareDuringBlockedStartDoesNotGetOverwrittenByOldLaunchWriteback() async throws {
        let fixture = try ClaudeCLIFixture(delayBeforeInputMilliseconds: 250)
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            outputDrainGrace: .seconds(2),
            terminationGrace: .milliseconds(60),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(2)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let original = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Original launch configuration",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Original launch instructions"
        ))
        let start = Task {
            try await provider.startRun(AgentRunRequest(
                runID: UUID(),
                session: original,
                cwd: fixture.directory.path,
                prompt: String(repeating: "p", count: 2 * 1_024 * 1_024),
                target: target
            ))
        }
        _ = try #require(try await waitForProcesses(fixture, count: 1).first)
        _ = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: original.id,
            name: "Replacement during launch",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Replacement launch instructions"
        ))
        _ = try await start.value

        let snapshot = try #require(
            await provider.sessionConfigurationSnapshot(id: original.id)
        )
        #expect(snapshot.name == "Replacement during launch")
        #expect(snapshot.developerInstructions == "Replacement launch instructions")
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentInteractionResolutionWritesExactlyOneResponse() async throws {
        let fixture = try ClaudeCLIFixture()
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            outputDrainGrace: .seconds(2),
            terminationGrace: .milliseconds(60),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Concurrent resolution fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))
        let runID = UUID()
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: fixture.directory.path,
            prompt: "Request approval once.",
            target: target
        ))
        let eventsTask = Task {
            for await _ in handle.events {}
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while await provider.pendingInteractionCount(runID: runID) != 1,
              clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await provider.pendingInteractionCount(runID: runID) == 1)
        let resolution = AgentInteractionResolution.decision(
            .object(["behavior": .string("allow")])
        )
        let first = Task {
            try await provider.resolveInteraction(
                runID: runID,
                interactionID: "permission-command",
                resolution: resolution
            )
        }
        let second = Task {
            try await provider.resolveInteraction(
                runID: runID,
                interactionID: "permission-command",
                resolution: resolution
            )
        }
        var successfulResolutions = 0
        if (try? await first.value) != nil { successfulResolutions += 1 }
        if (try? await second.value) != nil { successfulResolutions += 1 }
        #expect(successfulResolutions == 1)
        await eventsTask.value

        let responseCount = try fixture.records().filter { record in
            record["kind"]?.stringValue == "input"
                && record["value"]?["type"]?.stringValue == "control_response"
                && record["value"]?["response"]?["request_id"]?.stringValue
                    == "permission-command"
        }.count
        #expect(responseCount == 1)
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownRejectsALaunchAlreadyBlockedOnStdinAndLeavesNoRun() async throws {
        let fixture = try ClaudeCLIFixture(delayBeforeInputMilliseconds: 500)
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            outputDrainGrace: .seconds(2),
            terminationGrace: .milliseconds(60),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(2)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Shutdown admission fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))
        let start = Task {
            try await provider.startRun(AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: fixture.directory.path,
                prompt: String(repeating: "p", count: 2 * 1_024 * 1_024),
                target: target
            ))
        }
        let process = try #require(try await waitForProcesses(fixture, count: 1).first)

        await provider.shutdown()
        await #expect(throws: (any Error).self) {
            _ = try await start.value
        }
        try await waitForProcessTreeToDisappear(process)
        #expect(await provider.activeRunCount() == 0)
        await #expect(throws: (any Error).self) {
            _ = try await provider.startRun(AgentRunRequest(
                runID: UUID(),
                session: session,
                cwd: fixture.directory.path,
                prompt: "Must stay rejected after shutdown.",
                target: target
            ))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownReportsUnverifiedCleanupAndRetainsTheOwnedProcessForRetry() async throws {
        let fixture = try ClaudeCLIFixture(
            stubbornProcessTree: true,
            resultThenHang: true
        )
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            terminalExitGrace: .milliseconds(20),
            outputDrainGrace: .seconds(2),
            terminationGrace: .milliseconds(60),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )
        await provider.forceTeardownFailureForTesting(
            "Injected cleanup verification failure."
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Verified shutdown fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))
        let handle = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: fixture.directory.path,
            prompt: "Return a result, then retain the process for cleanup retry.",
            target: target
        ))
        for await _ in handle.events {}
        let process = try #require(try await waitForProcesses(fixture, count: 1).first)

        #expect(!(await provider.shutdownAndVerify()))
        #expect(await provider.activeRunCount() == 1)
        #expect(Self.processExists(process.leader))

        await provider.forceTeardownFailureForTesting(nil)
        #expect(await provider.shutdownAndVerify())
        try await waitForProcessTreeToDisappear(process)
        #expect(await provider.activeRunCount() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func utilityCancellationDuringVerifiedCleanupCannotReturnStaleSuccess() async throws {
        let fixture = try ClaudeCLIFixture(
            stubbornProcessTree: true,
            resultThenHang: true
        )
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            terminalExitGrace: .milliseconds(500),
            outputDrainGrace: .seconds(2),
            terminationGrace: .milliseconds(80),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )
        let task = Task {
            try await provider.runUtility(AgentUtilityRequest(
                cwd: fixture.directory.path,
                prompt: "Return a result, then remain alive during cleanup.",
                target: AgentTarget(providerID: .claude, model: "sonnet"),
                developerInstructions: "Coordinate without edits.",
                outputSchema: .object(["type": .string("object")])
            ))
        }
        _ = try #require(try await waitForProcesses(fixture, count: 1).first)
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await provider.activeRunCount() == 0)
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func utilityInteractionFailsInsteadOfWaitingWithoutAConsumer() async throws {
        let fixture = try ClaudeCLIFixture(unresolvedInteractionCount: 1)
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            outputDrainGrace: .seconds(2),
            terminationGrace: .milliseconds(60),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )

        do {
            _ = try await provider.runUtility(AgentUtilityRequest(
                cwd: fixture.directory.path,
                prompt: "Request input that an unattended utility cannot answer.",
                target: AgentTarget(providerID: .claude, model: "sonnet"),
                developerInstructions: "Coordinate without edits.",
                outputSchema: .object(["type": .string("object")])
            ))
            Issue.record("Expected the unattended utility interaction to fail")
        } catch {
            #expect(error.localizedDescription.contains("unattended coordinator run"))
        }
        #expect(await provider.activeRunCount() == 0)
        await provider.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func stderrTailIsBoundedByUTF8BytesForPathologicalCombiningMarks() async throws {
        let fixture = try ClaudeCLIFixture(stderrCombiningChunkCount: 100)
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment,
            eventBufferCapacity: 256,
            maximumEventBufferRetainedBytes: 4 * 1_024 * 1_024,
            outputDrainGrace: .seconds(2),
            terminationGrace: .milliseconds(60),
            killVerificationGrace: .seconds(2),
            stdinWriteTimeout: .seconds(1)
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Stderr byte-bound fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))
        let runID = UUID()
        let handle = try await provider.startRun(AgentRunRequest(
            runID: runID,
            session: session,
            cwd: fixture.directory.path,
            prompt: "Emit pathological stderr.",
            target: target
        ))
        let eventsTask = Task {
            for await _ in handle.events {}
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let sent = (try? fixture.records())?.contains {
                $0["kind"]?.stringValue == "stderr_combining_sent"
            } == true
            if sent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect((await provider.stderrTailByteCount(runID: runID) ?? 0) <= 4_000)
        await provider.shutdown()
        await eventsTask.value
    }

    @Test(.timeLimit(.minutes(1)))
    func overflowingClaudeUsageSaturatesInsteadOfTrapping() async throws {
        let fixture = try ClaudeCLIFixture(overflowUsage: true)
        defer { fixture.remove() }
        let provider = ClaudeAgentProvider(
            executableURL: fixture.executableURL,
            environment: fixture.environment
        )
        let target = AgentTarget(providerID: .claude, model: "sonnet")
        let session = try await provider.prepareSession(AgentSessionRequest(
            existingSessionID: nil,
            name: "Overflow usage fixture",
            cwd: fixture.directory.path,
            target: target,
            developerInstructions: "Continue the workflow."
        ))
        let handle = try await provider.startRun(AgentRunRequest(
            runID: UUID(),
            session: session,
            cwd: fixture.directory.path,
            prompt: "Return maximum token counters.",
            target: target
        ))
        var usage: RunTokenUsage?
        for await event in handle.events {
            if case .completed(_, _, let completedUsage) = event {
                usage = completedUsage
            }
        }
        #expect(usage?.totalTokens == Int64.max)
        #expect(usage?.inputTokens == Int64.max)
        #expect(usage?.outputTokens == Int64.max)
        await provider.shutdown()
    }

    private func waitForProcesses(
        _ fixture: ClaudeCLIFixture,
        count: Int
    ) async throws -> [ClaudeFixtureProcess] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let records = (try? fixture.processRecords()) ?? []
            if records.count >= count { return records }
            try await Task.sleep(for: .milliseconds(10))
        }
        return (try? fixture.processRecords()) ?? []
    }

    private func waitForActiveRuns(
        _ provider: ClaudeAgentProvider,
        count: Int
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while await provider.activeRunCount() != count, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForProcessTreeToDisappear(
        _ process: ClaudeFixtureProcess
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline,
              Self.processExists(process.leader)
                || process.child.map(Self.processExists) == true
                || Self.processGroupExists(process.group) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!Self.processExists(process.leader))
        if let child = process.child {
            #expect(!Self.processExists(child))
        }
        #expect(!Self.processGroupExists(process.group))
    }

    private static func processExists(_ processIdentifier: pid_t) -> Bool {
        if Darwin.kill(processIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func processGroupExists(_ processGroupIdentifier: pid_t) -> Bool {
        if Darwin.kill(-processGroupIdentifier, 0) == 0 { return true }
        return errno == EPERM
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
    let missingOnResume: Bool
    let terminateOnRun: Bool
    let hangUtility: Bool
    let stubbornProcessTree: Bool
    let stopBeforeReadingInput: Bool
    let resultThenHang: Bool
    let floodOutput: Bool
    let outputLineByteCount: Int?
    let exitingResultByteCount: Int?
    let unresolvedInteractionCount: Int?
    let terminateOnInterrupt: Bool
    let duplicateInteractionID: Bool
    let delayBeforeInputMilliseconds: Int?
    let stderrCombiningChunkCount: Int?
    let overflowUsage: Bool

    var environment: [String: String] {
        var environment = CodexExecutableLocator.processEnvironment()
        environment["CLAUDE_FIXTURE_LOG"] = logURL.path
        if missingOnResume {
            environment["CLAUDE_FIXTURE_MISSING_ON_RESUME"] = "1"
        }
        if terminateOnRun {
            environment["CLAUDE_FIXTURE_TERMINATE_ON_RUN"] = "1"
        }
        if hangUtility {
            environment["CLAUDE_FIXTURE_HANG_UTILITY"] = "1"
        }
        if stubbornProcessTree {
            environment["CLAUDE_FIXTURE_STUBBORN_TREE"] = "1"
        }
        if stopBeforeReadingInput {
            environment["CLAUDE_FIXTURE_STOP_BEFORE_INPUT"] = "1"
        }
        if resultThenHang {
            environment["CLAUDE_FIXTURE_RESULT_THEN_HANG"] = "1"
        }
        if floodOutput {
            environment["CLAUDE_FIXTURE_FLOOD_OUTPUT"] = "1"
        }
        if let outputLineByteCount {
            environment["CLAUDE_FIXTURE_OUTPUT_LINE_BYTES"] = String(outputLineByteCount)
        }
        if let exitingResultByteCount {
            environment["CLAUDE_FIXTURE_EXITING_RESULT_BYTES"] = String(
                exitingResultByteCount
            )
        }
        if let unresolvedInteractionCount {
            environment["CLAUDE_FIXTURE_UNRESOLVED_INTERACTIONS"] = String(
                unresolvedInteractionCount
            )
        }
        if terminateOnInterrupt {
            environment["CLAUDE_FIXTURE_TERMINATE_ON_INTERRUPT"] = "1"
        }
        if duplicateInteractionID {
            environment["CLAUDE_FIXTURE_DUPLICATE_INTERACTION_ID"] = "1"
        }
        if let delayBeforeInputMilliseconds {
            environment["CLAUDE_FIXTURE_INPUT_DELAY_MS"] = String(
                delayBeforeInputMilliseconds
            )
        }
        if let stderrCombiningChunkCount {
            environment["CLAUDE_FIXTURE_STDERR_COMBINING_CHUNKS"] = String(
                stderrCombiningChunkCount
            )
        }
        if overflowUsage {
            environment["CLAUDE_FIXTURE_OVERFLOW_USAGE"] = "1"
        }
        return environment
    }

    init(
        missingOnResume: Bool = false,
        terminateOnRun: Bool = false,
        hangUtility: Bool = false,
        stubbornProcessTree: Bool = false,
        stopBeforeReadingInput: Bool = false,
        resultThenHang: Bool = false,
        floodOutput: Bool = false,
        outputLineByteCount: Int? = nil,
        exitingResultByteCount: Int? = nil,
        unresolvedInteractionCount: Int? = nil,
        terminateOnInterrupt: Bool = false,
        duplicateInteractionID: Bool = false,
        delayBeforeInputMilliseconds: Int? = nil,
        stderrCombiningChunkCount: Int? = nil,
        overflowUsage: Bool = false
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codeness-claude-fixture-\(UUID().uuidString)",
                isDirectory: true
            )
        self.missingOnResume = missingOnResume
        self.terminateOnRun = terminateOnRun
        self.hangUtility = hangUtility
        self.stubbornProcessTree = stubbornProcessTree
        self.stopBeforeReadingInput = stopBeforeReadingInput
        self.resultThenHang = resultThenHang
        self.floodOutput = floodOutput
        self.outputLineByteCount = outputLineByteCount
        self.exitingResultByteCount = exitingResultByteCount
        self.unresolvedInteractionCount = unresolvedInteractionCount
        self.terminateOnInterrupt = terminateOnInterrupt
        self.duplicateInteractionID = duplicateInteractionID
        self.delayBeforeInputMilliseconds = delayBeforeInputMilliseconds
        self.stderrCombiningChunkCount = stderrCombiningChunkCount
        self.overflowUsage = overflowUsage
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

    func processRecords() throws -> [ClaudeFixtureProcess] {
        try records().compactMap { record in
            guard record["kind"]?.stringValue == "process",
                  let pid = record["pid"]?.integerValue,
                  let group = record["pgid"]?.integerValue else { return nil }
            return ClaudeFixtureProcess(
                leader: pid_t(pid),
                group: pid_t(group),
                child: record["child_pid"]?.integerValue.map(pid_t.init)
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let script = #"""
#!/usr/bin/python3
import json
import os
import signal
import subprocess
import sys
import time

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

child = None
if os.environ.get("CLAUDE_FIXTURE_STUBBORN_TREE") == "1":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen([
        sys.executable,
        "-c",
        "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
    ])
log({
    "kind": "process",
    "pid": os.getpid(),
    "pgid": os.getpgrp(),
    "child_pid": child.pid if child is not None else None
})
if os.environ.get("CLAUDE_FIXTURE_STOP_BEFORE_INPUT") == "1":
    os.kill(os.getpid(), signal.SIGSTOP)
if os.environ.get("CLAUDE_FIXTURE_INPUT_DELAY_MS"):
    time.sleep(int(os.environ["CLAUDE_FIXTURE_INPUT_DELAY_MS"]) / 1000.0)

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
        elif request.get("subtype") == "interrupt":
            if os.environ.get("CLAUDE_FIXTURE_TERMINATE_ON_INTERRUPT") == "1":
                os.kill(os.getpid(), signal.SIGTERM)
                break
    elif value.get("type") == "user":
        session_id = value.get("session_id", "")
        if os.environ.get("CLAUDE_FIXTURE_TERMINATE_ON_RUN") == "1":
            os.kill(os.getpid(), signal.SIGTERM)
            break
        if is_resume and os.environ.get("CLAUDE_FIXTURE_MISSING_ON_RESUME") == "1":
            emit({
                "type": "result",
                "subtype": "error",
                "is_error": True,
                "errors": [
                    "No conversation found with session ID: " + session_id
                ]
            })
            break
        emit({"type": "system", "subtype": "init", "session_id": session_id})
        emit({"type": "system", "subtype": "status", "status": "requesting"})
        if os.environ.get("CLAUDE_FIXTURE_OVERFLOW_USAGE") == "1":
            emit({
                "type": "result",
                "subtype": "success",
                "is_error": False,
                "duration_ms": 1,
                "result": "Overflow usage result",
                "usage": {
                    "input_tokens": 9223372036854775807,
                    "cache_read_input_tokens": 1,
                    "cache_creation_input_tokens": 1,
                    "output_tokens": 9223372036854775807
                }
            })
            break
        if os.environ.get("CLAUDE_FIXTURE_STDERR_COMBINING_CHUNKS"):
            chunk_count = int(os.environ["CLAUDE_FIXTURE_STDERR_COMBINING_CHUNKS"])
            for _ in range(chunk_count):
                sys.stderr.write("a" + ("\u0301" * 4096))
                sys.stderr.flush()
            log({"kind": "stderr_combining_sent", "count": chunk_count})
            while True:
                time.sleep(1)
        if os.environ.get("CLAUDE_FIXTURE_EXITING_RESULT_BYTES"):
            result_byte_count = int(os.environ["CLAUDE_FIXTURE_EXITING_RESULT_BYTES"])
            emit({
                "type": "result",
                "subtype": "success",
                "is_error": False,
                "duration_ms": 1,
                "result": "r" * result_byte_count
            })
            break
        if os.environ.get("CLAUDE_FIXTURE_UNRESOLVED_INTERACTIONS"):
            interaction_count = int(
                os.environ["CLAUDE_FIXTURE_UNRESOLVED_INTERACTIONS"]
            )
            for index in range(interaction_count):
                emit({
                    "type": "control_request",
                    "request_id": "unresolved-" + str(index),
                    "request": {
                        "subtype": "can_use_tool",
                        "tool_name": "Bash",
                        "tool_use_id": "tool-" + str(index),
                        "input": {"command": "x" * 1024}
                    }
                })
            while True:
                time.sleep(1)
        if os.environ.get("CLAUDE_FIXTURE_DUPLICATE_INTERACTION_ID") == "1":
            for tool_name in ["Bash", "Write"]:
                emit({
                    "type": "control_request",
                    "request_id": "duplicate-request",
                    "request": {
                        "subtype": "can_use_tool",
                        "tool_name": tool_name,
                        "tool_use_id": "tool-" + tool_name.lower(),
                        "input": {"command": tool_name}
                    }
                })
            while True:
                time.sleep(1)
        if os.environ.get("CLAUDE_FIXTURE_OUTPUT_LINE_BYTES"):
            target_bytes = int(os.environ["CLAUDE_FIXTURE_OUTPUT_LINE_BYTES"])
            prefix = '{"type":"keep_alive","padding":"'
            suffix = '"}'
            padding_count = target_bytes - len(prefix) - len(suffix)
            sys.stdout.write(prefix + ("x" * padding_count) + suffix)
            sys.stdout.flush()
            time.sleep(0.05)
            sys.stdout.write("\n")
            sys.stdout.flush()
            log({"kind": "output_line_sent", "byte_count": target_bytes})
            while True:
                time.sleep(1)
        if os.environ.get("CLAUDE_FIXTURE_RESULT_THEN_HANG") == "1":
            emit({
                "type": "result",
                "subtype": "success",
                "is_error": False,
                "duration_ms": 1,
                "result": "Result before stubborn teardown"
            })
            while True:
                time.sleep(1)
        if os.environ.get("CLAUDE_FIXTURE_FLOOD_OUTPUT") == "1":
            for index in range(256):
                emit({
                    "type": "stream_event",
                    "event": {
                        "type": "content_block_delta",
                        "delta": {
                            "type": "text_delta",
                            "text": ("f" * 4096) + str(index)
                        }
                    }
                })
            while True:
                time.sleep(1)
        if is_utility:
            if os.environ.get("CLAUDE_FIXTURE_HANG_UTILITY") == "1":
                while True:
                    time.sleep(1)
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

private struct ClaudeFixtureProcess: Equatable {
    let leader: pid_t
    let group: pid_t
    let child: pid_t?
}
