import Darwin
import Foundation
import Testing
@testable import CodenessCore

@Suite(.serialized)
struct CodexAppServerSupervisionTests {
    @Test(.timeLimit(.minutes(1)))
    func blockedLargeWritesRespectByteDeadlineAndShutdownBounds() async throws {
        let fixture = try SupervisionFixture(script: Self.stopsReadingAfterInitialize)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            requestTimeout: .milliseconds(180),
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(120),
            eventCapacity: 1
        )
        try await client.start(configuration: fixture.configuration)
        let identifiers = try #require(await client.testingProcessIdentifiers())
        let large = String(repeating: "x", count: 7 * 1_024 * 1_024)

        let first = Task {
            try await client.startThread(
                cwd: "/tmp",
                model: "fixture",
                developerInstructions: large
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let second = Task {
            try await client.startThread(
                cwd: "/tmp",
                model: "fixture",
                developerInstructions: large
            )
        }

        let secondError = await Self.errorDescription(from: second)
        #expect(secondError.contains("byte safety limit"))
        let firstError = await Self.errorDescription(from: first)
        #expect(firstError.contains("request deadline"))

        #expect(await client.shutdown())
        #expect(!(await client.isRunning))
        #expect(!Self.processExists(identifiers.process))
        #expect(!Self.processGroupExists(identifiers.group))
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownEscalatesIgnoredTermAndRemovesSeparatelyGroupedExecDescendant() async throws {
        let fixture = try SupervisionFixture(script: Self.ignoresTermWithDescendant)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(150)
        )
        try await client.start(configuration: fixture.configuration)
        let pids = try await fixture.waitForPIDs(count: 2)
        #expect(getpgid(pids[0]) == pids[0])
        #expect(getpgid(pids[1]) == pids[1])
        #expect(pids[0] != pids[1])

        let clock = ContinuousClock()
        let started = clock.now
        #expect(await client.shutdown())

        #expect(clock.now - started < .seconds(2))
        #expect(!(await client.isRunning))
        #expect(pids.allSatisfy { !Self.processExists($0) })
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownRetryRescansAfterTheFirstEscalationWindowAndLateChildExit() async throws {
        let fixture = try SupervisionFixture(script: Self.lateExitingDetachedDescendant)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(150),
            testingTerminationSignalPermission: { attempt in attempt > 1 }
        )
        try await client.start(configuration: fixture.configuration)
        let child = try #require(try await fixture.waitForPIDs(count: 1).first)
        try await Self.waitUntil {
            await client.testingHasObservedProcessTermination()
        }

        #expect(!(await client.shutdown()))
        #expect(await client.isRunning)
        #expect(Self.processExists(child))

        try await Self.waitUntil(timeout: .seconds(4)) {
            !Self.processExists(child)
        }
        #expect(await client.shutdown())
        #expect(!(await client.isRunning))
    }

    @Test(.timeLimit(.minutes(1)))
    func inheritedStdoutCannotDelayExitOrRestart() async throws {
        let fixture = try SupervisionFixture(script: Self.parentExitsWhileDescendantHoldsStdout)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(150),
            eventCapacity: 1
        )
        let stream = await client.events()
        let firstGenerationEvents = Task { () -> [AppServerEvent] in
            var result: [AppServerEvent] = []
            for await transportEvent in stream {
                result.append(transportEvent.event)
                if case .exited = transportEvent.event { return result }
            }
            return result
        }
        try await client.start(configuration: fixture.configuration)

        let threadID = try await client.startThread(
            cwd: "/tmp",
            model: "fixture",
            developerInstructions: "exit"
        )
        #expect(threadID == "thread-before-exit")
        try await Self.waitUntil { !(await client.isRunning) }
        let descendant = try #require(try await fixture.waitForPIDs(count: 1).first)
        try await Self.waitUntil { !Self.processExists(descendant) }

        let collected = await firstGenerationEvents.value
        let notification = collected.firstIndex {
            if case .notification(let method, _, _) = $0 { method == "turn/completed" } else { false }
        }
        let exit = collected.firstIndex {
            if case .exited = $0 { true } else { false }
        }
        #expect(notification != nil && exit != nil)
        if let notification, let exit { #expect(notification < exit) }

        // Draining generation N and its inherited descriptor must leave no
        // process or channel ownership that can interfere with N+1.
        for _ in 0..<3 {
            try await client.start(configuration: fixture.configuration)
            let restartedIdentifiers = try #require(await client.testingProcessIdentifiers())
            #expect(await client.isRunning)
            await client.shutdown()
            #expect(!Self.processExists(restartedIdentifiers.process))
            #expect(!Self.processGroupExists(restartedIdentifiers.group))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func responseAlreadyInStdoutWinsAfterWaitpidObservesLeaderExit() async throws {
        let fixture = try SupervisionFixture(script: Self.respondsThenImmediatelyExits)
        defer { fixture.remove() }
        let readGate = ArmedOutputReadGate()
        defer { readGate.release() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .seconds(2),
            eventCapacity: 4,
            testingBeforeOutputReadHook: { readGate.blockIfArmed() }
        )
        try await client.start(configuration: fixture.configuration)
        readGate.arm()

        let request = Task {
            try await client.startThread(
                cwd: "/tmp",
                model: "fixture",
                developerInstructions: "exit after response"
            )
        }
        await readGate.waitUntilEntered()
        try await Self.waitUntil {
            await client.testingHasObservedProcessTermination()
        }

        readGate.release()
        #expect(try await request.value == "thread-before-exit")
        try await Self.waitUntil { !(await client.isRunning) }
    }

    @Test(.timeLimit(.minutes(1)))
    func restartRemainsBlockedUntilEveryProcessClearStepCompletes() async throws {
        let fixture = try SupervisionFixture(script: Self.respondsThenImmediatelyExits)
        defer { fixture.remove() }
        let clearGate = AsyncClearCompletionGate()
        defer { Task { await clearGate.release() } }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(150),
            testingBeforeProcessClearCompletionHook: { generation in
                await clearGate.pause(generation: generation)
            }
        )
        try await client.start(configuration: fixture.configuration)

        let exitingRequest = Task {
            try await client.startThread(
                cwd: "/tmp",
                model: "fixture",
                developerInstructions: "exit"
            )
        }
        await clearGate.waitUntilEntered()

        #expect(await client.isRunning)
        do {
            try await client.start(configuration: fixture.configuration)
            Issue.record("Expected restart to remain blocked during process clearing")
        } catch {
            #expect(error.localizedDescription.contains("already running"))
        }

        await clearGate.release()
        #expect(try await exitingRequest.value == "thread-before-exit")
        try await Self.waitUntil { !(await client.isRunning) }

        try await client.start(configuration: fixture.configuration)
        #expect(await client.isRunning)
        #expect(await client.shutdown())
    }

    @Test(.timeLimit(.minutes(1)))
    func replacementPurgesSaturatedOldGenerationBeforeNotificationAndInitializeResponse() async throws {
        let fixture = try SupervisionFixture(script: Self.notificationBeforeReplacementResponse)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            requestTimeout: .seconds(2),
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(120),
            eventCapacity: 1
        )

        try await client.start(configuration: fixture.configuration)
        try await Self.waitUntil {
            await client.testingBufferedEventCount() == 1
        }
        #expect(await client.shutdown())

        // Generation two emits a notification before its initialize response.
        // Purging generation one's full queue must let stdout parsing reach the
        // response without waiting for an AppModel consumer.
        try await client.start(configuration: fixture.configuration)
        #expect(await client.isRunning)
        let events = await client.events()
        var iterator = events.makeAsyncIterator()
        let replacementEvent = await iterator.next()
        #expect(replacementEvent?.generation == 2)
        if case .notification(let method, _, _)? = replacementEvent?.event {
            #expect(method == "replacement/ready")
        } else {
            Issue.record("Expected the replacement notification")
        }
        #expect(await client.shutdown())
    }

    @Test(.timeLimit(.minutes(1)))
    func notificationsBeyondCapacityBeforeInitializeResponseFailClosedWithoutDeadlock() async throws {
        let fixture = try SupervisionFixture(script: Self.overflowsBeforeInitializeResponse)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            requestTimeout: .seconds(5),
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(120),
            eventCapacity: 1
        )
        let routingPause = await client.pauseEventRouting()
        #expect(await client.testingEventRoutingIsPaused())

        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await client.start(configuration: fixture.configuration)
            Issue.record("Expected bounded event overflow to contain initialization")
        } catch {
            #expect(error.localizedDescription.contains("produced events faster"))
        }
        #expect(clock.now - started < .seconds(2))
        #expect(!(await client.isRunning))
        await client.resumeEventRouting(routingPause)
        #expect(!(await client.testingEventRoutingIsPaused()))
    }

    @Test(.timeLimit(.minutes(1)))
    func oversizedUnterminatedJSONFailsClosedExplicitly() async throws {
        let fixture = try SupervisionFixture(script: Self.oversizedUnterminatedOutput)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(150),
            eventCapacity: 4
        )
        let stream = await client.events()
        let events = Task { () -> [AppServerEvent] in
            var result: [AppServerEvent] = []
            for await transportEvent in stream {
                let event = transportEvent.event
                result.append(event)
                if case .exited = event { return result }
            }
            return result
        }
        try await client.start(configuration: fixture.configuration)
        _ = try await client.startThread(
            cwd: "/tmp",
            model: "fixture",
            developerInstructions: "oversized"
        )

        let collected = await events.value
        #expect(collected.contains {
            if case .standardError(let detail) = $0 {
                detail.contains("larger than the 33554432-byte transport limit")
            } else { false }
        })
        #expect(collected.contains { if case .exited = $0 { true } else { false } })
        #expect(!(await client.isRunning))
    }

    @Test(.timeLimit(.minutes(1)))
    func blockedEventConsumerBackpressuresWithoutTerminatingHealthyGeneration() async throws {
        let fixture = try SupervisionFixture(script: Self.highVolumeNotifications)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(120),
            eventCapacity: 1
        )
        try await client.start(configuration: fixture.configuration)
        _ = try await client.startThread(
            cwd: "/tmp",
            model: "fixture",
            developerInstructions: "flood"
        )

        try await Self.waitUntil {
            await client.testingBufferedEventCount() == 1
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.lastCounter() < 10_000)
        #expect(await client.isRunning)
        #expect(await client.shutdown())
        #expect(!(await client.isRunning))
    }

    @Test(.timeLimit(.minutes(1)))
    func productionCapacityBurstBackpressuresAndDrainsWithoutDataLoss() async throws {
        let fixture = try SupervisionFixture(script: Self.productionCapacityBurst)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(120)
        )
        try await client.start(configuration: fixture.configuration)
        _ = try await client.startThread(
            cwd: "/tmp",
            model: "fixture",
            developerInstructions: "bounded production burst"
        )

        try await Self.waitUntil {
            await client.testingBufferedEventCount() == 64
        }
        #expect(await client.isRunning)

        let events = await client.events()
        var notificationCount = 0
        for await transportEvent in events {
            guard case .notification(let method, _, _) = transportEvent.event,
                  method == "item/agentMessage/delta" else { continue }
            notificationCount += 1
            try await Task.sleep(for: .milliseconds(2))
            if notificationCount == 80 { break }
        }
        #expect(notificationCount == 80)
        #expect(await client.isRunning)
        #expect(await client.shutdown())
    }

    @Test(.timeLimit(.minutes(1)))
    func closedChildStdinReportsFailureWithoutSIGPIPEKillingTheHost() async throws {
        let fixture = try SupervisionFixture(script: Self.closesStdinBeforeInitializeResponse)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(120)
        )

        do {
            try await client.start(configuration: fixture.configuration)
            Issue.record("Expected initialized notification write to fail")
            await client.shutdown()
        } catch {
            #expect(
                error.localizedDescription.contains("Broken pipe")
                    || error.localizedDescription.contains("not running")
            )
        }
        #expect(!(await client.isRunning))
    }

    @Test(.timeLimit(.minutes(1)))
    func liveProcessClosingStdoutIsTerminatedAndDoesNotBlockRestart() async throws {
        let fixture = try SupervisionFixture(script: Self.closesStdoutThenHangs)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(120),
            eventCapacity: 4
        )
        let stream = await client.events()
        let exitEvents = Task { () -> [AppServerEvent] in
            var result: [AppServerEvent] = []
            for await transportEvent in stream {
                let event = transportEvent.event
                result.append(event)
                if case .exited = event { return result }
            }
            return result
        }
        try await client.start(configuration: fixture.configuration)
        let identifiers = try #require(await client.testingProcessIdentifiers())

        let collected = await exitEvents.value
        #expect(collected.contains {
            if case .standardError(let detail) = $0 {
                detail.contains("closed stdout while its process was still running")
            } else { false }
        })
        #expect(collected.contains { if case .exited = $0 { true } else { false } })
        #expect(!(await client.isRunning))
        #expect(!Self.processExists(identifiers.process))
        #expect(!Self.processGroupExists(identifiers.group))

        try await client.start(configuration: fixture.configuration)
        try await Self.waitUntil { !(await client.isRunning) }
    }

    @Test(.timeLimit(.minutes(1)))
    func completedWritesThatLaterTimeOutDoNotAccumulateCancellationTombstones() async throws {
        let fixture = try SupervisionFixture(script: Self.readsRequestsWithoutResponding)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            requestTimeout: .milliseconds(30),
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(120)
        )
        try await client.start(configuration: fixture.configuration)

        for index in 0..<12 {
            do {
                _ = try await client.readThread(id: "missing-\(index)")
                Issue.record("Expected thread/read to time out")
            } catch {
                #expect(error.localizedDescription.contains("request deadline"))
            }
        }

        #expect(await client.testingCancellationTombstoneCount() == 0)
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingAPartiallyWrittenDirectResponseTerminatesTheGeneration() async throws {
        let fixture = try SupervisionFixture(script: Self.requestsResponseThenStopsReading)
        defer { fixture.remove() }
        let writeProgress = WriteProgressGate()
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(120),
            eventCapacity: 4,
            testingWriteProgressHook: { messageByteCount, byteCount in
                guard messageByteCount > 1_048_576 else { return }
                Task { await writeProgress.record(byteCount: byteCount) }
            }
        )
        let stream = await client.events()
        let request = Task { () -> JSONValue? in
            for await transportEvent in stream {
                let event = transportEvent.event
                if case .request(let id, let method, _, _) = event,
                   method == "fixture/respond" {
                    return id
                }
            }
            return nil
        }
        try await client.start(configuration: fixture.configuration)
        let identifiers = try #require(await client.testingProcessIdentifiers())
        let requestID = try #require(await request.value)

        let response = Task {
            try await client.respond(
                to: requestID,
                result: .string(String(repeating: "r", count: 7 * 1_024 * 1_024))
            )
        }
        await writeProgress.waitForBytes()
        response.cancel()
        await #expect(throws: CancellationError.self) {
            try await response.value
        }
        try await Self.waitUntil { !(await client.isRunning) }
        #expect(!Self.processExists(identifiers.process))
        #expect(!Self.processGroupExists(identifiers.group))

        // Restart immediately after the cancelled partial write. If the old
        // writer were still running on a recycled descriptor, it could inject
        // the remainder into this generation's stdin and corrupt initialize.
        try await client.start(configuration: fixture.configuration)
        #expect(await client.isRunning)
        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func directResponseDeadlineTerminatesAPartiallyWrittenGeneration() async throws {
        let fixture = try SupervisionFixture(script: Self.requestsResponseThenStopsReading)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            testingRequestRegistrationHook: { _ in },
            terminationGrace: .milliseconds(60),
            outputDrainGrace: .milliseconds(120),
            eventCapacity: 4,
            directWriteTimeout: .milliseconds(80)
        )
        let stream = await client.events()
        let request = Task { () -> JSONValue? in
            for await transportEvent in stream {
                let event = transportEvent.event
                if case .request(let id, let method, _, _) = event,
                   method == "fixture/respond" {
                    return id
                }
            }
            return nil
        }
        try await client.start(configuration: fixture.configuration)
        let identifiers = try #require(await client.testingProcessIdentifiers())
        let requestID = try #require(await request.value)

        do {
            try await client.respond(
                to: requestID,
                result: .string(String(repeating: "r", count: 7 * 1_024 * 1_024))
            )
            Issue.record("Expected the direct response write to reach its deadline")
        } catch {
            #expect(error.localizedDescription.contains("direct message write"))
            #expect(error.localizedDescription.contains("request deadline"))
        }
        try await Self.waitUntil { !(await client.isRunning) }
        #expect(!Self.processExists(identifiers.process))
        #expect(!Self.processGroupExists(identifiers.group))
    }

    private static func errorDescription(
        from task: Task<String, any Error>
    ) async -> String {
        do {
            _ = try await task.value
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    private static func processExists(_ processIdentifier: pid_t) -> Bool {
        if Darwin.kill(processIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func processGroupExists(_ processGroupIdentifier: pid_t) -> Bool {
        if Darwin.kill(-processGroupIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition())
    }

    private static let commonPrelude = #"""
import json
import os
import signal
import subprocess
import sys
import time

log_path = sys.argv[1]

def emit(value):
    os.write(sys.stdout.fileno(), (json.dumps(value) + "\n").encode("utf-8"))

def log(value):
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(str(value) + "\n")
        handle.flush()
"""#

    private static let stopsReadingAfterInitialize = commonPrelude + "\n" + #"""
for line in sys.stdin:
    message = json.loads(line)
    if message.get("method") == "initialize":
        emit({"id": message["id"], "result": {"userAgent": "blocked-stdin"}})
    elif message.get("method") == "initialized":
        while True:
            time.sleep(1)
"""#

    private static let ignoresTermWithDescendant = commonPrelude + "\n" + #"""
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = subprocess.Popen([
    sys.executable,
    "-c",
    "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
], start_new_session=True, close_fds=False)
log(os.getpid())
log(child.pid)
for line in sys.stdin:
    message = json.loads(line)
    if message.get("method") == "initialize":
        emit({"id": message["id"], "result": {"userAgent": "ignore-term"}})
"""#

    private static let lateExitingDetachedDescendant = commonPrelude + "\n" + #"""
child = subprocess.Popen([
    sys.executable,
    "-c",
    "import os,signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
    "open(sys.argv[1], 'a', encoding='utf-8').write(str(os.getpid()) + '\\n'); "
    "time.sleep(3)",
    log_path
], start_new_session=True, close_fds=False)
ready_deadline = time.monotonic() + 2
while os.path.getsize(log_path) == 0 and time.monotonic() < ready_deadline:
    time.sleep(0.01)
if os.path.getsize(log_path) == 0:
    sys.exit(80)
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        emit({"id": message["id"], "result": {"userAgent": "late-child-exit"}})
    elif method == "initialized":
        os._exit(0)
"""#

    private static let parentExitsWhileDescendantHoldsStdout = commonPrelude + "\n" + #"""
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        emit({"id": message["id"], "result": {"userAgent": "inherited-stdout"}})
    elif method == "thread/start":
        emit({"id": message["id"], "result": {"thread": {"id": "thread-before-exit"}}})
        emit({"method": "turn/completed", "params": {"threadId": "thread-before-exit", "turn": {"id": "turn-1", "items": [], "status": "completed"}}})
        child = os.fork()
        if child == 0:
            os.setsid()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(60)
            os._exit(0)
        log(child)
        os._exit(7)
"""#

    private static let respondsThenImmediatelyExits = commonPrelude + "\n" + #"""
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        emit({"id": message["id"], "result": {"userAgent": "response-exit-race"}})
    elif method == "thread/start":
        emit({"id": message["id"], "result": {"thread": {"id": "thread-before-exit"}}})
        os._exit(7)
"""#

    private static let oversizedUnterminatedOutput = commonPrelude + "\n" + #"""
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        emit({"id": message["id"], "result": {"userAgent": "oversized"}})
    elif method == "thread/start":
        emit({"id": message["id"], "result": {"thread": {"id": "oversized-thread"}}})
        chunk = b"x" * (64 * 1024)
        for _ in range(513):
            os.write(sys.stdout.fileno(), chunk)
        time.sleep(60)
"""#

    private static let highVolumeNotifications = commonPrelude + "\n" + #"""
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        emit({"id": message["id"], "result": {"userAgent": "flood"}})
    elif method == "thread/start":
        emit({"id": message["id"], "result": {"thread": {"id": "flood-thread"}}})
        payload = "x" * 16384
        for index in range(10000):
            emit({"method": "item/agentMessage/delta", "params": {"threadId": "flood-thread", "turnId": "turn", "delta": payload}})
            log(index + 1)
"""#

    private static let productionCapacityBurst = commonPrelude + "\n" + #"""
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        emit({"id": message["id"], "result": {"userAgent": "production-capacity"}})
    elif method == "thread/start":
        emit({"id": message["id"], "result": {"thread": {"id": "burst-thread"}}})
        for index in range(80):
            emit({"method": "item/agentMessage/delta", "params": {
                "threadId": "burst-thread",
                "turnId": "burst-turn",
                "delta": "x"
            }})
        while True:
            time.sleep(1)
"""#

    private static let closesStdinBeforeInitializeResponse = commonPrelude + "\n" + #"""
line = sys.stdin.readline()
message = json.loads(line)
os.close(sys.stdin.fileno())
emit({"id": message["id"], "result": {"userAgent": "closed-stdin"}})
time.sleep(60)
"""#

    private static let closesStdoutThenHangs = commonPrelude + "\n" + #"""
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        emit({"id": message["id"], "result": {"userAgent": "closed-stdout"}})
    elif method == "initialized":
        os.close(sys.stdout.fileno())
        while True:
            time.sleep(1)
"""#

    private static let requestsResponseThenStopsReading = commonPrelude + "\n" + #"""
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        emit({"id": message["id"], "result": {"userAgent": "direct-response"}})
    elif method == "initialized":
        emit({"id": "fixture-request", "method": "fixture/respond", "params": {}})
        while True:
            time.sleep(1)
"""#

    private static let readsRequestsWithoutResponding = commonPrelude + "\n" + #"""
for line in sys.stdin:
    message = json.loads(line)
    if message.get("method") == "initialize":
        emit({"id": message["id"], "result": {"userAgent": "timeout-tombstones"}})
"""#

    private static let notificationBeforeReplacementResponse = commonPrelude + "\n" + #"""
try:
    with open(log_path, "r", encoding="utf-8") as handle:
        generation = int(handle.read().strip() or "0") + 1
except Exception:
    generation = 1
with open(log_path, "w", encoding="utf-8") as handle:
    handle.write(str(generation))
    handle.flush()

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        if generation == 2:
            emit({"method": "replacement/ready", "params": {"generation": 2}})
        emit({"id": identifier, "result": {"userAgent": "generation-purge"}})
    elif method == "initialized" and generation == 1:
        emit({"method": "old/buffered", "params": {"generation": 1}})
"""#

    private static let overflowsBeforeInitializeResponse = commonPrelude + "\n" + #"""
for line in sys.stdin:
    message = json.loads(line)
    if message.get("method") == "initialize":
        for index in range(3):
            emit({"method": "startup/noise", "params": {"index": index}})
        emit({"id": message["id"], "result": {"userAgent": "overflow"}})
"""#
}

private actor WriteProgressGate {
    private var didWrite = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(byteCount: Int) {
        guard byteCount > 0, !didWrite else { return }
        didWrite = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }

    func waitForBytes() async {
        if didWrite { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor AsyncClearCompletionGate {
    private var enteredGeneration: Int64?
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause(generation: Int64) async {
        enteredGeneration = generation
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if enteredGeneration != nil { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class ArmedOutputReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func arm() {
        lock.withLock { armed = true }
    }

    func blockIfArmed() {
        let shouldBlock = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false
            entered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return !released
        }
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
        let shouldSignal = lock.withLock { () -> Bool in
            guard !released else { return false }
            released = true
            return true
        }
        if shouldSignal {
            releaseSemaphore.signal()
        }
    }
}

private struct SupervisionFixture: Sendable {
    let scriptURL: URL
    let logURL: URL

    init(script: String) throws {
        let identifier = UUID().uuidString
        scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-supervision-\(identifier).py")
        logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-supervision-\(identifier).log")
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }

    var configuration: CodexLaunchConfiguration {
        CodexLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [scriptURL.path, logURL.path]
        )
    }

    func lastCounter() -> Int {
        Int(loggedIntegers().last ?? 0)
    }

    func waitForPIDs(count: Int) async throws -> [pid_t] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while loggedIntegers().count < count, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = Array(loggedIntegers().prefix(count))
        try #require(result.count == count)
        return result
    }

    func remove() {
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: logURL)
    }

    private func loggedIntegers() -> [Int32] {
        guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return contents.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }
}
