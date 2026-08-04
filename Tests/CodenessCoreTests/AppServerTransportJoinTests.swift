import Darwin
import Dispatch
import Foundation
import Testing
@testable import CodenessCore

@Suite(.serialized)
struct AppServerTransportJoinTests {
    @Test(.timeLimit(.minutes(1)))
    func fastExitingLeaderEitherReturnsAnOwningScopeOrCleansItsDescendant() async throws {
        let fixture = try FastExitProcessGroupFixture()
        defer { fixture.remove() }
        let probe = FastExitValidationProbe(logURL: fixture.logURL)

        let process: AppServerProcess
        do {
            process = try AppServerProcess.launch(
                configuration: fixture.configuration,
                testingBeforeProcessGroupValidation: { processIdentifier in
                    probe.waitUntilLeaderCannotBeQueried(processIdentifier)
                }
            )
        } catch {
            // Under load, the WNOWAIT ownership proof can become unavailable
            // after getpgid has already reported ESRCH. Launch must then fail
            // closed and clean the complete scope.
            #expect((error as NSError).domain == "ap.codeness.app-server.spawn")
            #expect(probe.observedLeaderExit)
            let identifiers = try fixture.processIdentifiers()
            defer { Darwin.kill(identifiers.descendant, SIGKILL) }
            try await Self.waitUntil {
                !Self.processExists(identifiers.descendant)
                    && !Self.processGroupExists(identifiers.leader)
            }
            return
        }
        defer {
            _ = process.signalOwnedProcesses(SIGKILL)
            for descriptor in [
                process.inputFileDescriptor,
                process.outputFileDescriptor,
                process.errorFileDescriptor
            ] {
                Darwin.close(descriptor)
            }
            var status: Int32 = 0
            _ = unsafe waitpid(process.processIdentifier, &status, WNOHANG)
        }
        #expect(probe.observedLeaderExit)

        let identifiers = try fixture.processIdentifiers()
        defer { Darwin.kill(identifiers.descendant, SIGKILL) }
        #expect(process.processIdentifier == identifiers.leader)
        #expect(process.processGroupIdentifier == identifiers.leader)
        #expect(identifiers.leader > 1)
        #expect(identifiers.descendant > 1)
        #expect(process.ownedProcessesExist)

        // A one-shot leader may legitimately exit after writing its response
        // but before launch validation can query its process group. The
        // returned scope must still retain and terminate a descendant that has
        // already reparented itself into another session.
        _ = process.signalOwnedProcesses(SIGKILL)
        var waitStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = unsafe waitpid(process.processIdentifier, &waitStatus, 0)
        } while waitResult == -1 && errno == EINTR
        #expect(waitResult == process.processIdentifier)
        await process.stopMonitoringOwnedProcesses()
        try await Self.waitUntil {
            !Self.processExists(identifiers.descendant)
                && !Self.processGroupExists(identifiers.leader)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func writerCloseWaitsUntilAnInFlightWriteCanNoLongerUseItsDescriptor() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(unsafe Darwin.pipe(&descriptors) == 0)
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        defer { Darwin.close(readDescriptor) }
        let flags = fcntl(writeDescriptor, F_GETFL)
        try #require(flags >= 0)
        try #require(fcntl(writeDescriptor, F_SETFL, flags | O_NONBLOCK) == 0)

        let hook = BlockingTransportHook()
        let writer = OrderedPipeWriter(
            fileDescriptor: writeDescriptor,
            generation: 1,
            writeProgressHook: { _, _ in hook.block() }
        )
        let token = UUID()
        let write = Task {
            try await writer.write(
                Data(repeating: 0x78, count: 256 * 1_024),
                token: token
            )
        }
        await hook.waitUntilEntered()

        let closeCompleted = TransportCompletionFlag()
        let close = Task {
            await writer.closeAndWait()
            await closeCompleted.markComplete()
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!(await closeCompleted.isComplete))

        hook.release()
        await close.value
        #expect(await closeCompleted.isComplete)
        await #expect(throws: (any Error).self) {
            try await write.value
        }
        #expect(fcntl(writeDescriptor, F_GETFD) == -1)
        #expect(errno == EBADF)
    }

    @Test(.timeLimit(.minutes(1)))
    func readerStopWaitsUntilTheSerialReadLoopCanNoLongerUseItsDescriptor() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(unsafe Darwin.pipe(&descriptors) == 0)
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        defer { Darwin.close(writeDescriptor) }

        let hook = BlockingTransportHook()
        let reader = BoundedPipeReader(
            fileDescriptor: readDescriptor,
            label: "ap.codeness.tests.reader-join",
            qos: .utility,
            beforeReadHook: { hook.block() }
        )
        reader.start(consume: { _ in }, reachedEOF: {})
        var byte: UInt8 = 0x78
        try #require(unsafe Darwin.write(writeDescriptor, &byte, 1) == 1)
        await hook.waitUntilEntered()

        let stopCompleted = TransportCompletionFlag()
        let stop = Task {
            await reader.stop()
            await stopCompleted.markComplete()
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!(await stopCompleted.isComplete))

        hook.release()
        await stop.value
        #expect(await stopCompleted.isComplete)
        #expect(fcntl(readDescriptor, F_GETFD) == -1)
        #expect(errno == EBADF)
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
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

private struct FastExitProcessGroupFixture: Sendable {
    let scriptURL: URL
    let logURL: URL

    init() throws {
        let identifier = UUID().uuidString
        scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-fast-exit-\(identifier).py")
        logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-fast-exit-\(identifier).log")
        let script = #"""
import os
import signal
import sys
import time

child = os.fork()
if child == 0:
    os.setsid()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(60)
    os._exit(0)

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(f"{os.getpid()}\n{child}\n")
    handle.flush()
    os.fsync(handle.fileno())
os._exit(0)
"""#
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
    }

    var configuration: SupervisedProcessLaunchConfiguration {
        SupervisedProcessLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [scriptURL.path, logURL.path],
            environment: ProcessInfo.processInfo.environment
        )
    }

    func processIdentifiers() throws -> (leader: pid_t, descendant: pid_t) {
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        let identifiers = contents
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
        try #require(identifiers.count == 2)
        return (identifiers[0], identifiers[1])
    }

    func remove() {
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: logURL)
    }
}

private final class FastExitValidationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let logURL: URL
    private var didObserveLeaderExit = false

    init(logURL: URL) {
        self.logURL = logURL
    }

    var observedLeaderExit: Bool {
        lock.withLock { didObserveLeaderExit }
    }

    func waitUntilLeaderCannotBeQueried(_ processIdentifier: pid_t) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            let hasLoggedDescendant = (
                (try? String(contentsOf: logURL, encoding: .utf8))?
                    .split(whereSeparator: \.isNewline).count ?? 0
            ) == 2
            if hasLoggedDescendant,
               getpgid(processIdentifier) == -1,
               errno == ESRCH {
                lock.withLock { didObserveLeaderExit = true }
                return
            }
            usleep(1_000)
        }
    }
}

private final class BlockingTransportHook: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func block() {
        lock.lock()
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
        releaseSemaphore.wait()
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
        releaseSemaphore.signal()
    }
}

private actor TransportCompletionFlag {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}
