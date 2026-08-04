import Dispatch
import Foundation
import Testing
@testable import CodenessCore

@MainActor
struct LegacyCoordinatorLifecycleTests {
    @Test
    func closeWaitsForFirstLegacySessionAndReleasesItsPostCloseThread() async throws {
        let harness = try await makeHarness(blocking: "thread/start", occurrence: 1)
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }

        let startTask = Task {
            await harness.coordinator.startActivity(
                goal: "Close during implementer session creation",
                prompts: .builtInDefaults
            )
        }
        await harness.gate.waitUntilReached()
        let closeTask = Task {
            await harness.coordinator.prepareForClose(strategy: .immediate)
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(harness.coordinator.pauseState == .saving)
        await harness.gate.release()
        #expect(await closeTask.value == .ready)
        await startTask.value

        #expect(harness.coordinator.record.activity == nil)
        #expect(harness.coordinator.record.implementerThreadID == nil)
        #expect(await harness.gate.count(for: "thread/start") == 1)
        #expect(await harness.gate.count(for: "thread/unsubscribe") == 1)
        #expect(await harness.gate.count(for: "turn/start") == 0)
        await finishHarness(harness)
    }

    @Test
    func closeWaitsForReviewerLegacySessionAndReleasesBothAttachmentsOnce() async throws {
        let harness = try await makeHarness(blocking: "thread/start", occurrence: 2)
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }

        let startTask = Task {
            await harness.coordinator.startActivity(
                goal: "Close during reviewer session creation",
                prompts: .builtInDefaults
            )
        }
        await harness.gate.waitUntilReached()
        let closeTask = Task {
            await harness.coordinator.prepareForClose(strategy: .immediate)
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(harness.coordinator.pauseState == .saving)
        await harness.gate.release()
        #expect(await closeTask.value == .ready)
        await startTask.value

        #expect(harness.coordinator.record.activity == nil)
        #expect(harness.coordinator.record.implementerThreadID == "thread-1")
        #expect(harness.coordinator.record.reviewerThreadID == nil)
        #expect(await harness.gate.count(for: "thread/start") == 2)
        #expect(await harness.gate.count(for: "thread/unsubscribe") == 2)
        #expect(await harness.gate.count(for: "turn/start") == 0)
        await finishHarness(harness)
    }

    @Test
    func closeDuringRejectedLegacyResumeDoesNotLaunchFreshFallbackSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let canonicalPath = "/tmp/legacy-close-resume-fallback-\(UUID().uuidString)"
        let store = WorkspaceStore(rootURL: root)
        try await store.save(RepositoryRecord(
            canonicalPath: canonicalPath,
            implementerThreadID: "saved-implementer",
            reviewerThreadID: "saved-reviewer"
        ))
        let harness = try await makeHarness(
            blocking: "thread/resume",
            occurrence: 1,
            rejectsResumes: true,
            canonicalPath: canonicalPath,
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }

        let startTask = Task {
            await harness.coordinator.startActivity(
                goal: "Do not recreate sessions after close",
                prompts: .builtInDefaults
            )
        }
        await harness.gate.waitUntilReached()
        let closeTask = Task {
            await harness.coordinator.prepareForClose(strategy: .immediate)
        }
        try await Task.sleep(for: .milliseconds(50))
        await harness.gate.release()

        #expect(await closeTask.value == .ready)
        await startTask.value
        #expect(await harness.gate.count(for: "thread/resume") == 1)
        #expect(await harness.gate.count(for: "thread/start") == 0)
        #expect(await harness.gate.count(for: "thread/unsubscribe") == 0)
        #expect(harness.coordinator.record.implementerThreadID == "saved-implementer")
        #expect(harness.coordinator.record.reviewerThreadID == "saved-reviewer")
        await finishHarness(harness)
    }

    @Test
    func rejectedLegacyResumesReplaceIDsWithoutDetachingUnattachedHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let canonicalPath = "/tmp/legacy-resume-replacement-\(UUID().uuidString)"
        let store = WorkspaceStore(rootURL: root)
        try await store.save(RepositoryRecord(
            canonicalPath: canonicalPath,
            implementerThreadID: "saved-implementer",
            reviewerThreadID: "saved-reviewer"
        ))
        let harness = try await makeHarness(
            blocking: "never",
            occurrence: 1,
            rejectsResumes: true,
            canonicalPath: canonicalPath,
            store: store
        )
        defer { try? FileManager.default.removeItem(at: root) }
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }

        await harness.coordinator.startActivity(
            goal: "Replace unavailable legacy sessions",
            prompts: .builtInDefaults
        )

        #expect(await harness.gate.count(for: "thread/resume") == 2)
        #expect(await harness.gate.count(for: "thread/start") == 2)
        #expect(await harness.gate.count(for: "thread/unsubscribe") == 0)
        #expect(harness.coordinator.record.implementerThreadID == "thread-1")
        #expect(harness.coordinator.record.reviewerThreadID == "thread-2")
        let persisted = try await store.load(canonicalPath: canonicalPath)
        #expect(persisted.implementerThreadID == "thread-1")
        #expect(persisted.reviewerThreadID == "thread-2")
        await finishHarness(harness)
    }

    @Test
    func closeWaitsForAcceptedLegacyTurnBeforeInterruptingAndDetaching() async throws {
        let harness = try await makeHarness(blocking: "turn/start", occurrence: 1)
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }
        let events = await harness.client.events()
        let consumer = Task {
            for await transportEvent in events {
                await harness.coordinator.handle(transportEvent.event)
            }
        }
        defer { consumer.cancel() }

        let startTask = Task {
            await harness.coordinator.startActivity(
                goal: "Close after the first turn is accepted",
                prompts: .builtInDefaults
            )
        }
        await harness.gate.waitUntilReached()
        let closeTask = Task {
            await harness.coordinator.prepareForClose(strategy: .immediate)
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(harness.coordinator.pauseState == .saving)
        #expect(await harness.gate.count(for: "turn/interrupt") == 0)
        await harness.gate.release()
        #expect(await closeTask.value == .ready)
        await startTask.value

        #expect(await harness.gate.count(for: "turn/start") == 1)
        #expect(await harness.gate.count(for: "turn/interrupt") == 1)
        #expect(await harness.gate.count(for: "thread/unsubscribe") == 2)
        #expect(harness.coordinator.record.activity?.status == .paused)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .interrupted)
        await finishHarness(harness)
    }

    @Test(.timeLimit(.minutes(1)))
    func acknowledgedLegacyCloseWithoutTerminalContainsGenerationAndCompletesClose() async throws {
        let harness = try await makeHarness(
            blocking: "never",
            occurrence: 1,
            interruptEmitsTerminal: false,
            legacyInterruptionTerminalTimeout: .milliseconds(40)
        )
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }

        await harness.coordinator.startActivity(
            goal: "Contain an acknowledged close without a terminal",
            prompts: .builtInDefaults
        )
        let run = try #require(harness.coordinator.record.activity?.runs.last)
        let implementerThreadID = harness.coordinator.record.implementerThreadID
        let reviewerThreadID = harness.coordinator.record.reviewerThreadID
        #expect(run.status == .running)

        let closeTask = Task {
            await harness.coordinator.prepareForClose(strategy: .immediate)
        }
        try await waitUntil {
            harness.coordinator.legacyInterruptionWatchdogCount == 1
        }

        #expect(await closeTask.value == .ready)
        #expect(!(await harness.client.isRunning))
        #expect(harness.coordinator.legacyInterruptionDebtCount == 0)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)
        #expect(
            harness.coordinator.record.activity?.runs.last?.relayError?
                .contains("exact matching turn/completed") == true
        )
        #expect(harness.coordinator.record.implementerThreadID == implementerThreadID)
        #expect(harness.coordinator.record.reviewerThreadID == reviewerThreadID)
        #expect(await harness.gate.count(for: "thread/unsubscribe") == 0)
        await finishHarness(harness)
    }

    @Test(.timeLimit(.minutes(1)))
    func legacyThreadClosedBeforeMatchingTerminalContainsGeneration() async throws {
        let harness = try await makeHarness(
            blocking: "never",
            occurrence: 1,
            interruptEmitsTerminal: false,
            legacyInterruptionTerminalTimeout: .seconds(5)
        )
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }

        await harness.coordinator.startActivity(
            goal: "Reject thread closure as proof of turn termination",
            prompts: .builtInDefaults
        )
        let run = try #require(harness.coordinator.record.activity?.runs.last)
        let threadID = try #require(run.threadID)
        let implementerThreadID = harness.coordinator.record.implementerThreadID
        let reviewerThreadID = harness.coordinator.record.reviewerThreadID
        let closeTask = Task {
            await harness.coordinator.prepareForClose(strategy: .immediate)
        }
        try await waitUntil {
            harness.coordinator.legacyInterruptionWatchdogCount == 1
        }

        await harness.coordinator.handle(.notification(
            method: "thread/closed",
            params: .object(["threadId": .string(threadID)]),
            rawLine: "thread closed before exact terminal"
        ))

        #expect(await closeTask.value == .ready)
        #expect(!(await harness.client.isRunning))
        #expect(harness.coordinator.legacyInterruptionDebtCount == 0)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)
        #expect(
            harness.coordinator.record.activity?.runs.last?.relayError?
                .contains("thread closure alone cannot prove") == true
        )
        #expect(harness.coordinator.record.implementerThreadID == implementerThreadID)
        #expect(harness.coordinator.record.reviewerThreadID == reviewerThreadID)
        await finishHarness(harness)
    }

    @Test(.timeLimit(.minutes(1)))
    func legacyThreadClosedBeforeInterruptAcknowledgementStillContainsGeneration() async throws {
        let harness = try await makeHarness(
            blocking: "turn/interrupt",
            occurrence: 1,
            interruptEmitsTerminal: false,
            legacyInterruptionTerminalTimeout: .seconds(5)
        )
        defer { harness.fixture.remove() }
        defer { Task { await harness.gate.release() } }
        defer { Task { await harness.client.shutdown() } }

        await harness.coordinator.startActivity(
            goal: "Reject thread closure racing the interrupt acknowledgement",
            prompts: .builtInDefaults
        )
        let run = try #require(harness.coordinator.record.activity?.runs.last)
        let threadID = try #require(run.threadID)
        let closeTask = Task {
            await harness.coordinator.prepareForClose(strategy: .immediate)
        }
        await harness.gate.waitUntilReached()

        #expect(harness.coordinator.legacyInterruptionDebtCount == 1)
        #expect(harness.coordinator.legacyInterruptionWatchdogCount == 0)
        await harness.coordinator.handle(.notification(
            method: "thread/closed",
            params: .object(["threadId": .string(threadID)]),
            rawLine: "thread closed before interrupt acknowledgement"
        ))
        await harness.gate.release()

        #expect(await closeTask.value == .ready)
        #expect(!(await harness.client.isRunning))
        #expect(harness.coordinator.legacyInterruptionDebtCount == 0)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)
        #expect(
            harness.coordinator.record.activity?.runs.last?.relayError?
                .contains("thread closure alone cannot prove") == true
        )
        await finishHarness(harness)
    }

    @Test(.timeLimit(.minutes(1)))
    func legacyThreadClosureAfterLostInterruptResponseContainsGeneration() async throws {
        let harness = try await makeHarness(
            blocking: "never",
            occurrence: 1,
            interruptEmitsTerminal: false,
            interruptWithholdsResponse: true,
            controlRequestTimeout: .milliseconds(60),
            legacyInterruptionMaximumAttemptCount: 3,
            legacyInterruptionRetryDelay: .seconds(5),
            legacyInterruptionTerminalTimeout: .seconds(5)
        )
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }

        await harness.coordinator.startActivity(
            goal: "Retain an interruption whose response was lost",
            prompts: .builtInDefaults
        )
        let run = try #require(harness.coordinator.record.activity?.runs.last)
        let threadID = try #require(run.threadID)

        await harness.coordinator.interrupt()

        #expect(await harness.gate.count(for: "turn/interrupt") == 1)
        #expect(harness.coordinator.legacyInterruptionDebtCount == 1)
        #expect(harness.coordinator.legacyInterruptionWatchdogCount == 0)

        await harness.coordinator.handle(.notification(
            method: "thread/closed",
            params: .object(["threadId": .string(threadID)]),
            rawLine: "thread closed after interrupt response was lost"
        ))

        #expect(!(await harness.client.isRunning))
        #expect(harness.coordinator.legacyInterruptionDebtCount == 0)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)
        #expect(
            harness.coordinator.record.activity?.runs.last?.relayError?
                .contains("thread closure alone cannot prove") == true
        )
        await finishHarness(harness)
    }

    @Test(.timeLimit(.minutes(1)))
    func exactLegacyTerminalBeforeLostInterruptResponseDoesNotRecreateDebt() async throws {
        let harness = try await makeHarness(
            blocking: "never",
            occurrence: 1,
            interruptEmitsTerminal: true,
            interruptWithholdsResponse: true,
            controlRequestTimeout: .milliseconds(100),
            legacyInterruptionMaximumAttemptCount: 2,
            legacyInterruptionRetryDelay: .milliseconds(20),
            legacyInterruptionTerminalTimeout: .milliseconds(100)
        )
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }
        let events = await harness.client.events()
        let consumer = Task {
            for await transportEvent in events {
                await harness.coordinator.handle(transportEvent.event)
            }
        }
        defer { consumer.cancel() }

        await harness.coordinator.startActivity(
            goal: "Accept the exact terminal before a lost interrupt response",
            prompts: .builtInDefaults
        )
        await harness.coordinator.interrupt()

        try await waitUntil {
            harness.coordinator.legacyInterruptionDebtCount == 0
        }
        #expect(await harness.gate.count(for: "turn/interrupt") == 1)
        #expect(harness.coordinator.legacyInterruptionWatchdogCount == 0)
        #expect(!harness.coordinator.protocolContainmentIsActive)
        await finishHarness(harness)
    }

    @Test(.timeLimit(.minutes(1)))
    func exhaustedLegacyInterruptRetriesContainGeneration() async throws {
        let harness = try await makeHarness(
            blocking: "never",
            occurrence: 1,
            interruptEmitsTerminal: false,
            interruptFailures: 100,
            legacyInterruptionMaximumAttemptCount: 2,
            legacyInterruptionRetryDelay: .milliseconds(20),
            legacyInterruptionTerminalTimeout: .seconds(5)
        )
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }
        await harness.coordinator.startActivity(
            goal: "Contain repeatedly failed interruption requests",
            prompts: .builtInDefaults
        )
        let implementerThreadID = harness.coordinator.record.implementerThreadID
        let reviewerThreadID = harness.coordinator.record.reviewerThreadID
        await harness.coordinator.interrupt()

        // Failure state and interruption-debt removal are installed before the
        // bounded process termination await. The containment fence is released
        // only after that process boundary has been confirmed.
        try await waitUntil {
            harness.coordinator.legacyInterruptionDebtCount == 0
                && harness.coordinator.record.activity?.runs.last?.status == .failed
                && !harness.coordinator.protocolContainmentIsActive
        }
        #expect(await harness.gate.count(for: "turn/interrupt") == 2)
        #expect(!(await harness.client.isRunning))
        #expect(
            harness.coordinator.record.activity?.runs.last?.relayError?
                .contains("after 2 attempts") == true
        )
        #expect(harness.coordinator.record.implementerThreadID == implementerThreadID)
        #expect(harness.coordinator.record.reviewerThreadID == reviewerThreadID)
        await finishHarness(harness)
    }

    @Test(.timeLimit(.minutes(1)))
    func matchingLegacyTerminalCancelsInterruptionWatchdog() async throws {
        let harness = try await makeHarness(
            blocking: "never",
            occurrence: 1,
            interruptEmitsTerminal: false,
            legacyInterruptionTerminalTimeout: .milliseconds(80)
        )
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }

        await harness.coordinator.startActivity(
            goal: "Accept only the exact terminal for an interrupted turn",
            prompts: .builtInDefaults
        )
        let run = try #require(harness.coordinator.record.activity?.runs.last)
        let threadID = try #require(run.threadID)
        let turnID = try #require(run.turnID)
        let implementerThreadID = harness.coordinator.record.implementerThreadID
        let reviewerThreadID = harness.coordinator.record.reviewerThreadID
        let closeTask = Task {
            await harness.coordinator.prepareForClose(strategy: .immediate)
        }
        try await waitUntil {
            harness.coordinator.legacyInterruptionWatchdogCount == 1
        }

        await harness.coordinator.handle(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turn": .object([
                    "id": .string(turnID),
                    "items": .array([]),
                    "status": .string("interrupted")
                ])
            ]),
            rawLine: "exact terminal after interrupt acknowledgement"
        ))

        #expect(await closeTask.value == .ready)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await harness.client.isRunning)
        #expect(harness.coordinator.legacyInterruptionDebtCount == 0)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .interrupted)
        #expect(harness.coordinator.record.implementerThreadID == implementerThreadID)
        #expect(harness.coordinator.record.reviewerThreadID == reviewerThreadID)
        // This case deliberately proves that the acknowledged terminal keeps the
        // generation alive. Complete its shutdown before returning so an
        // unstructured deferred teardown cannot overlap the next test's launch.
        await finishHarness(harness)
    }

    @Test
    func legacyStartResponseMismatchFailsAndCancelsTheAcceptedTurn() async throws {
        let harness = try await makeHarness(
            blocking: "never",
            occurrence: 1,
            preResponseStartedTurnID: "notification-only-turn"
        )
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }
        let events = await harness.client.events()
        let consumer = Task {
            for await transportEvent in events {
                await harness.coordinator.handle(transportEvent.event)
            }
        }
        defer { consumer.cancel() }

        await harness.coordinator.startActivity(
            goal: "Reject ambiguous legacy turn identity",
            prompts: .builtInDefaults
        )
        try await waitUntil {
            harness.coordinator.record.activity?.runs.last?.status == .failed
        }

        let run = try #require(harness.coordinator.record.activity?.runs.last)
        #expect(run.turnID == nil)
        #expect(run.relayError?.contains("ambiguous execution") == true)
        #expect(harness.coordinator.record.activity?.status == .paused)
        #expect(await harness.gate.count(for: "turn/interrupt") == 0)
        #expect(!(await harness.client.isRunning))
        await finishHarness(harness)
    }

    @Test
    func postResponseLegacyStartedMismatchTerminatesTheAppServerGeneration() async throws {
        let harness = try await makeHarness(blocking: "never", occurrence: 1)
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }
        let events = await harness.client.events()
        let consumer = Task {
            for await transportEvent in events {
                await harness.coordinator.handle(transportEvent.event)
            }
        }
        defer { consumer.cancel() }

        await harness.coordinator.startActivity(
            goal: "Reject a post-response ambiguous legacy turn identity",
            prompts: .builtInDefaults
        )
        try await waitUntil {
            harness.coordinator.record.activity?.runs.last?.status == .running
        }
        let threadID = try #require(
            harness.coordinator.record.activity?.runs.last?.threadID
        )
        await harness.coordinator.handle(.notification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "turn": .object([
                    "id": .string("unexpected-notification-turn"),
                    "items": .array([]),
                    "status": .string("inProgress")
                ])
            ]),
            rawLine: "unexpected post-response started"
        ))

        let run = try #require(harness.coordinator.record.activity?.runs.last)
        #expect(run.status == .failed)
        #expect(run.relayError?.contains("ambiguous execution") == true)
        #expect(!(await harness.client.isRunning))
        await finishHarness(harness)
    }

    @Test(.timeLimit(.minutes(1)))
    func ambiguousLegacyTerminalCannotReleaseContainmentWhenCleanupIsUnconfirmed() async throws {
        let readGate = LegacyProtocolOutputReadGate()
        defer { readGate.release() }
        let harness = try await makeHarness(
            blocking: "never",
            occurrence: 1,
            outputReadGate: readGate
        )
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }
        let transportEvents = await harness.client.events()

        await harness.coordinator.startActivity(
            goal: "Keep ambiguous legacy generation contained",
            prompts: .builtInDefaults
        )
        try await waitUntil {
            harness.coordinator.record.activity?.runs.last?.status == .running
        }
        let run = try #require(harness.coordinator.record.activity?.runs.last)
        let threadID = try #require(run.threadID)
        let acceptedTurnID = try #require(run.turnID)

        readGate.arm()
        let mismatch = Task {
            await harness.coordinator.handle(.notification(
                method: "turn/started",
                params: .object([
                    "threadId": .string(threadID),
                    "turn": .object([
                        "id": .string("ambiguous-legacy-turn"),
                        "items": .array([]),
                        "status": .string("inProgress")
                    ])
                ]),
                rawLine: "ambiguous started while cleanup blocks"
            ))
        }
        await readGate.waitUntilEntered()

        await harness.coordinator.handle(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turn": .object([
                    "id": .string(acceptedTurnID),
                    "items": .array([]),
                    "status": .string("completed")
                ])
            ]),
            rawLine: "plausible terminal during containment"
        ))
        #expect(harness.coordinator.protocolContainmentIsActive)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)
        #expect(!harness.coordinator.canResume)
        #expect(!harness.coordinator.canStartOver)
        let closeResult = await harness.coordinator.prepareForClose(strategy: .immediate)
        guard case .failed(let closeDetail) = closeResult else {
            Issue.record("Expected close to fail while generation containment is unconfirmed")
            readGate.release()
            await mismatch.value
            return
        }
        #expect(closeDetail.contains("termination is confirmed"))

        // The transport's bounded cleanup wait now returns false. The gate must
        // remain generation-scoped; a second candidate terminal cannot clear it.
        await mismatch.value
        #expect(harness.coordinator.protocolContainmentIsActive)
        #expect(
            harness.coordinator.errorMessage?.contains("could not confirm") == true
        )
        await harness.coordinator.handle(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turn": .object([
                    "id": .string("ambiguous-legacy-turn"),
                    "items": .array([]),
                    "status": .string("completed")
                ])
            ]),
            rawLine: "second candidate terminal after cleanup timeout"
        ))
        #expect(harness.coordinator.protocolContainmentIsActive)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)

        readGate.release()
        for await transportEvent in transportEvents {
            await harness.coordinator.handle(transportEvent.event)
            if case .exited = transportEvent.event { break }
        }
        #expect(!harness.coordinator.protocolContainmentIsActive)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)
        #expect(!(await harness.client.isRunning))
        await finishHarness(harness)
    }

    @Test
    func safetyInterruptFailureBlocksLegacyReplacementAndCloseUntilTerminalAndDetachment() async throws {
        let harness = try await makeHarness(
            blocking: "never",
            occurrence: 1,
            interruptEmitsTerminal: false,
            interruptFailures: 10,
            unsubscribeFailures: 1,
            legacyInterruptionMaximumAttemptCount: 100,
            legacyInterruptionRetryDelay: .seconds(5)
        )
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }
        let events = await harness.client.events()
        let consumer = Task {
            for await transportEvent in events {
                await harness.coordinator.handle(transportEvent.event)
            }
        }
        defer { consumer.cancel() }

        await harness.coordinator.startActivity(
            goal: "Keep a legacy document attached until safety termination is confirmed",
            prompts: .builtInDefaults
        )
        try await waitUntil {
            harness.coordinator.record.activity?.runs.last?.status == .running
        }
        let activityID = try #require(harness.coordinator.record.activity?.id)
        let run = try #require(harness.coordinator.record.activity?.runs.last)
        let threadID = try #require(run.threadID)
        let turnID = try #require(run.turnID)
        let duplicateRequest: AppServerEvent = .request(
            id: .integer(812),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "questions": .array([])
            ]),
            rawLine: "duplicate safety request"
        )
        await harness.coordinator.handle(duplicateRequest)
        await harness.coordinator.handle(duplicateRequest)

        #expect(harness.coordinator.interactionSafetyTerminationCount == 1)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)
        #expect(harness.coordinator.errorMessage?.contains("injected legacy interrupt failure") == true)
        #expect(!harness.coordinator.canResume)
        #expect(!harness.coordinator.canStartOver)
        await harness.coordinator.resume()
        await harness.coordinator.startOver()
        #expect(harness.coordinator.record.activity?.id == activityID)

        let failedInterruptClose = await harness.coordinator.prepareForClose(strategy: .immediate)
        guard case .failed(let interruptFailure) = failedInterruptClose else {
            Issue.record("Expected legacy close to fail while termination is unconfirmed")
            return
        }
        #expect(interruptFailure.contains("injected legacy interrupt failure"))
        #expect(await harness.gate.count(for: "thread/unsubscribe") == 0)

        await harness.coordinator.handle(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turn": .object([
                    "id": .string(turnID),
                    "items": .array([]),
                    "status": .string("interrupted")
                ])
            ]),
            rawLine: "manual safety terminal"
        ))
        #expect(harness.coordinator.interactionSafetyTerminationCount == 0)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)

        let failedDetachClose = await harness.coordinator.prepareForClose(strategy: .immediate)
        guard case .failed(let detachFailure) = failedDetachClose else {
            Issue.record("Expected legacy close to surface failed session detachment")
            return
        }
        #expect(detachFailure.contains("could not confirm provider-session detachment"))
        #expect(await harness.gate.count(for: "thread/unsubscribe") == 2)

        #expect(await harness.coordinator.prepareForClose(strategy: .immediate) == .ready)
        #expect(await harness.gate.count(for: "thread/unsubscribe") == 3)
        await finishHarness(harness)
    }

    @Test(.timeLimit(.minutes(1)))
    func acknowledgedInteractionSafetyStopWithoutTerminalContainsGeneration() async throws {
        let harness = try await makeHarness(
            blocking: "never",
            occurrence: 1,
            interruptEmitsTerminal: false,
            legacyInterruptionTerminalTimeout: .milliseconds(200)
        )
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }

        await harness.coordinator.startActivity(
            goal: "Contain an interaction safety stop without a terminal",
            prompts: .builtInDefaults
        )
        let run = try #require(harness.coordinator.record.activity?.runs.last)
        let threadID = try #require(run.threadID)
        let turnID = try #require(run.turnID)
        let implementerThreadID = harness.coordinator.record.implementerThreadID
        let reviewerThreadID = harness.coordinator.record.reviewerThreadID
        let duplicateRequest: AppServerEvent = .request(
            id: .integer(913),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "questions": .array([])
            ]),
            rawLine: "duplicate interaction safety request"
        )

        await harness.coordinator.handle(duplicateRequest)
        await harness.coordinator.handle(duplicateRequest)
        let safetyFailure = try #require(
            harness.coordinator.record.activity?.runs.last?.relayError
        )
        #expect(safetyFailure.contains("reused an unresolved interaction identifier"))
        #expect(harness.coordinator.interactionSafetyTerminationCount == 1)
        #expect(harness.coordinator.legacyInterruptionDebtCount == 1)
        #expect(harness.coordinator.legacyInterruptionWatchdogCount == 1)

        try await waitUntil {
            harness.coordinator.interactionSafetyTerminationCount == 0
                && harness.coordinator.legacyInterruptionDebtCount == 0
        }

        #expect(!(await harness.client.isRunning))
        #expect(harness.coordinator.interactionSafetyTerminationCount == 0)
        #expect(harness.coordinator.legacyInterruptionDebtCount == 0)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)
        #expect(harness.coordinator.record.activity?.runs.last?.relayError == safetyFailure)
        #expect(harness.coordinator.errorMessage?.contains("exact matching turn/completed") == true)
        #expect(harness.coordinator.record.implementerThreadID == implementerThreadID)
        #expect(harness.coordinator.record.reviewerThreadID == reviewerThreadID)
        await finishHarness(harness)
    }

    @Test
    func backpressureServerRestartPreservesFailureAndCompletesWaitingClose() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = BlockingFailOnceTranscriptStore(base: WorkspaceStore(rootURL: root))
        defer { Task { await store.failFirstBlockedAppend() } }
        let harness = try await makeHarness(
            blocking: "never",
            occurrence: 1,
            store: store,
            interruptEmitsTerminal: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }
        let events = await harness.client.events()
        let consumer = Task {
            for await transportEvent in events {
                await harness.coordinator.handle(transportEvent.event)
            }
        }
        defer { consumer.cancel() }

        await harness.coordinator.startActivity(
            goal: "Preserve a transcript durability failure while closing",
            prompts: .builtInDefaults
        )
        try await waitUntil {
            harness.coordinator.record.activity?.runs.last?.status == .running
        }
        let run = try #require(harness.coordinator.record.activity?.runs.last)
        let threadID = try #require(run.threadID)
        let turnID = try #require(run.turnID)

        // Drive the terminal under test directly. The client-level event
        // stream is needed to establish the run, but leaving its consumer live
        // would let an unrelated transport event race this coordinator seam.
        consumer.cancel()
        await consumer.value

        let closeTask = Task {
            await harness.coordinator.prepareForClose(strategy: .immediate)
        }
        try await waitUntil {
            harness.coordinator.pauseState == .interrupting
        }

        let overflowingDelta = Task {
            await harness.coordinator.handle(.notification(
                method: "item/agentMessage/delta",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "itemId": .string("backpressure-item"),
                    "delta": .string(String(
                        repeating: "b",
                        count: RepositoryCoordinator.maximumPendingTranscriptUTF8Bytes + 1
                    ))
                ]),
                rawLine: "overflowing delta"
            ))
        }
        await store.waitUntilFirstAppendIsBlocked()
        await store.failFirstBlockedAppend()
        await overflowingDelta.value

        #expect(harness.coordinator.pauseState == .interrupting)
        let failure = try #require(
            harness.coordinator.record.activity?.runs.last?.relayError
        )
        #expect(failure.contains("transcript output could not be persisted"))

        // A definitive App Server exit/restart proves the old turn cannot still
        // mutate the repository even when no per-turn terminal survived stdout.
        await harness.coordinator.appServerRestarted()

        #expect(await closeTask.value == .ready)
        #expect(harness.coordinator.transcriptBackpressureTerminationCount == 0)
        #expect(harness.coordinator.pendingTranscriptUTF8ByteCount(for: run.id) == 0)
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)
        #expect(harness.coordinator.record.activity?.runs.last?.relayError == failure)
        await finishHarness(harness)
    }

    @Test(.timeLimit(.minutes(1)))
    func acknowledgedBackpressureStopWithoutTerminalContainsGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = BlockingFailOnceTranscriptStore(base: WorkspaceStore(rootURL: root))
        defer { Task { await store.failFirstBlockedAppend() } }
        let harness = try await makeHarness(
            blocking: "never",
            occurrence: 1,
            store: store,
            interruptEmitsTerminal: false,
            legacyInterruptionTerminalTimeout: .milliseconds(200)
        )
        defer { try? FileManager.default.removeItem(at: root) }
        defer { harness.fixture.remove() }
        defer { Task { await harness.client.shutdown() } }

        await harness.coordinator.startActivity(
            goal: "Contain a transcript backpressure stop without a terminal",
            prompts: .builtInDefaults
        )
        let run = try #require(harness.coordinator.record.activity?.runs.last)
        let threadID = try #require(run.threadID)
        let turnID = try #require(run.turnID)
        let implementerThreadID = harness.coordinator.record.implementerThreadID
        let reviewerThreadID = harness.coordinator.record.reviewerThreadID
        let overflowingDelta = Task {
            await harness.coordinator.handle(.notification(
                method: "item/agentMessage/delta",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "itemId": .string("bounded-backpressure-item"),
                    "delta": .string(String(
                        repeating: "b",
                        count: RepositoryCoordinator.maximumPendingTranscriptUTF8Bytes + 1
                    ))
                ]),
                rawLine: "overflowing delta without terminal"
            ))
        }
        await store.waitUntilFirstAppendIsBlocked()
        await store.failFirstBlockedAppend()
        await overflowingDelta.value

        let failure = try #require(
            harness.coordinator.record.activity?.runs.last?.relayError
        )
        #expect(failure.contains("transcript output could not be persisted"))
        #expect(harness.coordinator.transcriptBackpressureTerminationCount == 1)
        #expect(harness.coordinator.legacyInterruptionDebtCount == 1)
        #expect(harness.coordinator.legacyInterruptionWatchdogCount == 1)

        try await waitUntil {
            harness.coordinator.transcriptBackpressureTerminationCount == 0
                && harness.coordinator.legacyInterruptionDebtCount == 0
        }

        #expect(!(await harness.client.isRunning))
        #expect(harness.coordinator.transcriptBackpressureTerminationCount == 0)
        #expect(harness.coordinator.legacyInterruptionDebtCount == 0)
        #expect(
            harness.coordinator.pendingTranscriptUTF8ByteCount(for: run.id)
                <= RepositoryCoordinator.maximumPendingTranscriptUTF8Bytes
        )
        #expect(harness.coordinator.record.activity?.runs.last?.status == .failed)
        #expect(harness.coordinator.record.activity?.runs.last?.relayError == failure)
        #expect(harness.coordinator.record.implementerThreadID == implementerThreadID)
        #expect(harness.coordinator.record.reviewerThreadID == reviewerThreadID)
        await finishHarness(harness)
    }

    @Test
    func closeOrExportWaitsForInitialRecoveryAndCancelKeepsDocumentLoaded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let canonicalPath = "/tmp/legacy-blocked-load-\(UUID().uuidString)"
        let base = WorkspaceStore(rootURL: root)
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .queued,
            threadID: nil,
            model: "gpt-5.6-sol",
            effort: "high",
            prompt: "Recover me"
        )
        try await base.save(RepositoryRecord(
            canonicalPath: canonicalPath,
            activity: ActivityRecord(
                goal: "Load before exporting",
                prompts: .builtInDefaults,
                runs: [run],
                pendingAction: .implement,
                resumeCheckpoint: .recoverRun(run.id)
            )
        ))
        let store = BlockingInitialRecoveryStore(base: base)
        let coordinator = RepositoryCoordinator(
            canonicalPath: canonicalPath,
            appServer: CodexAppServerClient(),
            router: LegacyNoopRouter(),
            store: store,
            handoffConfigurationValidator: LegacyAcceptingValidator()
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let loadTask = Task { await coordinator.load() }
        await store.waitUntilRecoveryReached()
        var joinedLoadReturned = false
        let joinedLoadTask = Task {
            await coordinator.load()
            joinedLoadReturned = true
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!joinedLoadReturned)
        let closeTask = Task {
            await coordinator.prepareForClose(strategy: .immediate)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.pauseState == .saving)

        await store.releaseRecovery()
        await loadTask.value
        await joinedLoadTask.value
        #expect(joinedLoadReturned)
        #expect(await closeTask.value == .ready)
        #expect(coordinator.isLoaded)
        #expect(coordinator.record.activity?.status == .paused)
        #expect(coordinator.record.activity?.runs.last?.status == .interrupted)

        // Export uses close preparation and then cancels it while the window stays
        // mounted. The completed load must remain usable without a second `.task`.
        coordinator.cancelClosePreparation()
        #expect(coordinator.isLoaded)
        #expect(coordinator.pauseState == .idle)
    }

    private func finishHarness(_ harness: Harness) async {
        // Every successful test must finish subprocess cleanup inside its own
        // lifetime. A fire-and-forget deferred shutdown can otherwise overlap
        // the test runner's next fixture launch and let that new child be hit by
        // an unrelated SIGTERM during initialization.
        #expect(await harness.client.shutdown())
    }

    private struct Harness {
        let coordinator: RepositoryCoordinator
        let client: CodexAppServerClient
        let gate: LegacyRequestGate
        let fixture: LegacyLifecycleAppServerFixture
    }

    private func makeHarness(
        blocking method: String,
        occurrence: Int,
        rejectsResumes: Bool = false,
        canonicalPath: String = "/tmp/legacy-close-lifecycle-\(UUID().uuidString)",
        store: (any RepositoryWorkspaceStoring)? = nil,
        interruptEmitsTerminal: Bool = true,
        interruptFailures: Int = 0,
        unsubscribeFailures: Int = 0,
        preResponseStartedTurnID: String? = nil,
        interruptWithholdsResponse: Bool = false,
        outputReadGate: LegacyProtocolOutputReadGate? = nil,
        controlRequestTimeout: Duration = .seconds(5),
        legacyInterruptionMaximumAttemptCount: Int = 3,
        legacyInterruptionRetryDelay: Duration = .milliseconds(250),
        legacyInterruptionTerminalTimeout: Duration = .seconds(2)
    ) async throws -> Harness {
        let gate = LegacyRequestGate(method: method, occurrence: occurrence)
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { method in
                await gate.observe(method)
            },
            controlRequestTimeout: controlRequestTimeout,
            terminationGrace: .milliseconds(50),
            outputDrainGrace: .milliseconds(100),
            testingBeforeOutputReadHook: {
                outputReadGate?.blockIfArmed()
            }
        )
        let fixture = try LegacyLifecycleAppServerFixture(
            rejectsResumes: rejectsResumes,
            interruptEmitsTerminal: interruptEmitsTerminal,
            interruptFailures: interruptFailures,
            unsubscribeFailures: unsubscribeFailures,
            preResponseStartedTurnID: preResponseStartedTurnID,
            interruptWithholdsResponse: interruptWithholdsResponse
        )
        try await client.start(configuration: fixture.configuration)
        let workspaceStore = store ?? WorkspaceStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: canonicalPath,
            appServer: client,
            router: LegacyNoopRouter(),
            store: workspaceStore,
            handoffConfigurationValidator: LegacyAcceptingValidator(),
            legacyInterruptionMaximumAttemptCount: legacyInterruptionMaximumAttemptCount,
            legacyInterruptionRetryDelay: legacyInterruptionRetryDelay,
            legacyInterruptionTerminalTimeout: legacyInterruptionTerminalTimeout
        )
        await coordinator.load()
        return Harness(coordinator: coordinator, client: client, gate: gate, fixture: fixture)
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

}

private actor BlockingInitialRecoveryStore: RepositoryWorkspaceStoring {
    private let base: WorkspaceStore
    private var didReachRecovery = false
    private var recoveryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(base: WorkspaceStore) {
        self.base = base
    }

    func load(
        canonicalPath: String,
        defaultSettings: RepositorySettings
    ) async throws -> RepositoryRecord {
        try await base.load(
            canonicalPath: canonicalPath,
            defaultSettings: defaultSettings
        )
    }

    func save(_ record: RepositoryRecord) async throws {
        try await base.save(record)
    }

    func archiveActivity(_ record: RepositoryRecord) async throws {
        try await base.archiveActivity(record)
    }

    func loadViewState(canonicalPath: String) async throws -> RepositoryViewState {
        try await base.loadViewState(canonicalPath: canonicalPath)
    }

    func saveViewState(
        _ state: RepositoryViewState,
        canonicalPath: String
    ) async throws {
        try await base.saveViewState(state, canonicalPath: canonicalPath)
    }

    func appendRawLine(
        _ line: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        try await base.appendRawLine(
            line,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func appendTranscript(
        _ text: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        try await base.appendTranscript(
            text,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func recoveredTranscript(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> String {
        try await base.recoveredTranscript(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func recoveredTranscriptTail(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID,
        maximumUTF8Bytes: Int
    ) async throws -> RecoveredTranscriptTail {
        try await base.recoveredTranscriptTail(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID,
            maximumUTF8Bytes: maximumUTF8Bytes
        )
    }

    func recoveredTokenUsage(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> RunTokenUsage? {
        didReachRecovery = true
        let waiters = recoveryWaiters
        recoveryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return try await base.recoveredTokenUsage(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func waitUntilRecoveryReached() async {
        guard !didReachRecovery else { return }
        await withCheckedContinuation { continuation in
            recoveryWaiters.append(continuation)
        }
    }

    func releaseRecovery() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

actor BlockingFailOnceTranscriptStore: RepositoryWorkspaceStoring {
    private let base: WorkspaceStore
    private var appendCallCount = 0
    private var firstAppendIsBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(base: WorkspaceStore) {
        self.base = base
    }

    func load(
        canonicalPath: String,
        defaultSettings: RepositorySettings
    ) async throws -> RepositoryRecord {
        try await base.load(
            canonicalPath: canonicalPath,
            defaultSettings: defaultSettings
        )
    }

    func save(_ record: RepositoryRecord) async throws {
        try await base.save(record)
    }

    func archiveActivity(_ record: RepositoryRecord) async throws {
        try await base.archiveActivity(record)
    }

    func loadViewState(canonicalPath: String) async throws -> RepositoryViewState {
        try await base.loadViewState(canonicalPath: canonicalPath)
    }

    func saveViewState(
        _ state: RepositoryViewState,
        canonicalPath: String
    ) async throws {
        try await base.saveViewState(state, canonicalPath: canonicalPath)
    }

    func appendRawLine(
        _ line: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        try await base.appendRawLine(
            line,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func appendTranscript(
        _ text: String,
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws {
        appendCallCount += 1
        if appendCallCount == 1 {
            firstAppendIsBlocked = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            throw BlockingFailOnceTranscriptStoreError.firstAppendFailure
        }
        try await base.appendTranscript(
            text,
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func recoveredTranscript(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> String {
        try await base.recoveredTranscript(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func recoveredTokenUsage(
        repositoryPath: String,
        activityID: UUID,
        runID: UUID
    ) async throws -> RunTokenUsage? {
        try await base.recoveredTokenUsage(
            repositoryPath: repositoryPath,
            activityID: activityID,
            runID: runID
        )
    }

    func waitUntilFirstAppendIsBlocked() async {
        guard !firstAppendIsBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func failFirstBlockedAppend() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

}

private enum BlockingFailOnceTranscriptStoreError: Error {
    case firstAppendFailure
}

private actor LegacyRequestGate {
    private let blockedMethod: String
    private let blockedOccurrence: Int
    private var counts: [String: Int] = [:]
    private var reached = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(method: String, occurrence: Int) {
        blockedMethod = method
        blockedOccurrence = occurrence
    }

    func observe(_ method: String) async {
        counts[method, default: 0] += 1
        guard method == blockedMethod,
              counts[method] == blockedOccurrence else { return }
        reached = true
        let waiters = reachedWaiters
        reachedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { continuation in
            reachedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func count(for method: String) -> Int {
        counts[method, default: 0]
    }
}

private final class LegacyProtocolOutputReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func blockIfArmed() {
        lock.lock()
        guard armed else {
            lock.unlock()
            return
        }
        armed = false
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        let shouldBlock = !released
        lock.unlock()
        waiters.forEach { $0.resume() }
        if shouldBlock {
            releaseSemaphore.wait()
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if entered {
                lock.unlock()
                continuation.resume()
            } else {
                enteredWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        releaseSemaphore.signal()
    }
}

private struct LegacyNoopRouter: HandoffRouting {
    func route(_ context: HandoffContext, settings: RelaySettings) async throws -> HandoffEnvelope {
        _ = context
        _ = settings
        return HandoffEnvelope(
            handoffText: "Unused",
            sourceDisposition: .unclear,
            runLabel: "Unused"
        )
    }
}

private struct LegacyAcceptingValidator: HandoffConfigurationValidating {
    func validateLocal(_ settings: RelaySettings) async throws { _ = settings }
    func testRemote(_ settings: RelaySettings) async throws { _ = settings }
}

private struct LegacyLifecycleAppServerFixture: Sendable {
    let scriptURL: URL
    let rejectsResumes: Bool
    let interruptEmitsTerminal: Bool
    let interruptFailures: Int
    let unsubscribeFailures: Int
    let preResponseStartedTurnID: String?
    let interruptWithholdsResponse: Bool

    var configuration: CodexLaunchConfiguration {
        var arguments = [scriptURL.path]
        if rejectsResumes { arguments.append("--reject-resumes") }
        if !interruptEmitsTerminal { arguments.append("--interrupt-without-terminal") }
        arguments.append("--interrupt-failures=\(interruptFailures)")
        arguments.append("--unsubscribe-failures=\(unsubscribeFailures)")
        if interruptWithholdsResponse {
            arguments.append("--interrupt-withholds-response")
        }
        if let preResponseStartedTurnID {
            arguments.append("--pre-response-started=\(preResponseStartedTurnID)")
        }
        return CodexLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: arguments
        )
    }

    init(
        rejectsResumes: Bool,
        interruptEmitsTerminal: Bool = true,
        interruptFailures: Int = 0,
        unsubscribeFailures: Int = 0,
        preResponseStartedTurnID: String? = nil,
        interruptWithholdsResponse: Bool = false
    ) throws {
        self.rejectsResumes = rejectsResumes
        self.interruptEmitsTerminal = interruptEmitsTerminal
        self.interruptFailures = interruptFailures
        self.unsubscribeFailures = unsubscribeFailures
        self.preResponseStartedTurnID = preResponseStartedTurnID
        self.interruptWithholdsResponse = interruptWithholdsResponse
        scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-legacy-lifecycle-\(UUID().uuidString).py")
        try Data(Self.script.utf8).write(to: scriptURL, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: scriptURL)
    }

    private static let script = #"""
import json
import sys
import time

reject_resumes = "--reject-resumes" in sys.argv[1:]
interrupt_emits_terminal = "--interrupt-without-terminal" not in sys.argv[1:]
def option(prefix):
    for argument in sys.argv[1:]:
        if argument.startswith(prefix):
            return int(argument[len(prefix):])
    return 0
def string_option(prefix):
    for argument in sys.argv[1:]:
        if argument.startswith(prefix):
            return argument[len(prefix):]
    return None
interrupt_failures = option("--interrupt-failures=")
unsubscribe_failures = option("--unsubscribe-failures=")
pre_response_started = string_option("--pre-response-started=")
interrupt_withholds_response = "--interrupt-withholds-response" in sys.argv[1:]
thread_count = 0
turn_count = 0
interrupt_count = 0
unsubscribe_count = 0

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit({"id": identifier, "result": {"userAgent": "legacy-lifecycle-fixture"}})
    elif method == "thread/loaded/list":
        emit({"id": identifier, "result": {"data": []}})
    elif method == "thread/start":
        thread_count += 1
        emit({"id": identifier, "result": {"thread": {"id": "thread-" + str(thread_count)}}})
    elif method == "thread/resume":
        if reject_resumes:
            emit({"id": identifier, "error": {"code": -32600, "message": "no rollout found"}})
        else:
            emit({"id": identifier, "result": {"thread": {"id": message["params"]["threadId"]}}})
    elif method == "turn/start":
        turn_count += 1
        thread_id = message["params"]["threadId"]
        turn_id = "turn-" + str(turn_count)
        if pre_response_started:
            emit({"method": "turn/started", "params": {"threadId": thread_id, "turn": {"id": pre_response_started, "items": [], "status": "inProgress"}}})
            time.sleep(0.1)
        emit({"id": identifier, "result": {"turn": {"id": turn_id, "items": [], "status": "inProgress"}}})
        if not pre_response_started:
            emit({"method": "turn/started", "params": {"threadId": thread_id, "turn": {"id": turn_id, "items": [], "status": "inProgress"}}})
    elif method == "turn/interrupt":
        interrupt_count += 1
        if interrupt_count <= interrupt_failures:
            emit({"id": identifier, "error": {"code": -32000, "message": "injected legacy interrupt failure"}})
            continue
        thread_id = message["params"]["threadId"]
        turn_id = message["params"]["turnId"]
        if interrupt_withholds_response:
            if interrupt_emits_terminal:
                emit({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "items": [], "status": "interrupted"}}})
        else:
            emit({"id": identifier, "result": {}})
            if interrupt_emits_terminal:
                emit({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "items": [], "status": "interrupted"}}})
    elif method == "thread/unsubscribe":
        unsubscribe_count += 1
        if unsubscribe_count <= unsubscribe_failures:
            emit({"id": identifier, "error": {"code": -32000, "message": "injected legacy unsubscribe failure"}})
        else:
            emit({"id": identifier, "result": {"status": "unsubscribed"}})
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#
}
