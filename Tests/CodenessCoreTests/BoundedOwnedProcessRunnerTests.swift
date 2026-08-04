import Darwin
import Foundation
import Testing
@testable import CodenessCore

@Suite(.serialized)
struct BoundedOwnedProcessRunnerTests {
    @Test(.timeLimit(.minutes(1)))
    func repeatedlyOwnsAndReapsImmediateExitProcesses() async throws {
        try await OwnedSubprocessSupervisorTestLease.withLease {
            let configuration = SupervisedProcessLaunchConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                environment: ProcessInfo.processInfo.environment
            )

            for _ in 0..<128 {
                let result = try await BoundedOwnedProcessRunner.run(
                    configuration: configuration,
                    timeout: .seconds(1)
                )
                #expect(result.termination.succeeded)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func drainsBothPipesConcurrentlyAndEnforcesTheirIndependentLimits() async throws {
        try await OwnedSubprocessSupervisorTestLease.withLease {
            let fixture = try OwnedProcessFixture(script: #"""
#!/usr/bin/python3
import os
os.write(1, b"o" * 131072)
os.write(2, b"e" * 131072)
"""#)
            defer { fixture.remove() }

            do {
                _ = try await BoundedOwnedProcessRunner.run(
                    configuration: fixture.configuration,
                    timeout: .seconds(2),
                    maximumStandardOutputByteCount: 32 * 1_024,
                    maximumStandardErrorByteCount: 32 * 1_024
                )
                Issue.record("Expected a bounded-output failure")
            } catch {
                #expect(error.localizedDescription.contains("safety limit"))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutRemovesASeparateSessionDescendantThatIgnoresTerm() async throws {
        try await OwnedSubprocessSupervisorTestLease.withLease {
            let fixture = try OwnedProcessFixture(script: #"""
#!/usr/bin/python3
import os
import signal
import time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = os.fork()
if child == 0:
    os.setsid()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(60)
    os._exit(0)
with open(os.environ["CODENESS_PID_FILE"], "w") as file:
    file.write(f"{os.getpid()} {child}\n")
    file.flush()
while True:
    time.sleep(1)
"""#)
            defer { fixture.remove() }

            do {
                _ = try await BoundedOwnedProcessRunner.run(
                    configuration: fixture.configuration,
                    timeout: .seconds(1)
                )
                Issue.record("Expected a timeout")
            } catch {
                #expect(error.localizedDescription.contains("did not finish"))
            }

            let identifiers = try await fixture.waitForProcessIdentifiers(count: 2)
            try await Self.waitUntil {
                identifiers.allSatisfy { !Self.processExists($0) }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func quitFenceOwnsAProcessRegisteredAtTheLaunchBoundary() async throws {
        try await OwnedSubprocessSupervisorTestLease.withLease {
            #expect(await Self.restoreProbeLaunching())
            let fixture = try OwnedProcessFixture(script: #"""
#!/bin/sh
trap '' TERM
/bin/echo "$$" > "$CODENESS_PID_FILE"
while :; do /bin/sleep 1; done
"""#)
            defer { fixture.remove() }
            do {
                let gate = OwnedProcessRegistrationGate()
                let run = Task {
                    try await BoundedOwnedProcessRunner.run(
                        configuration: fixture.configuration,
                        timeout: .seconds(30),
                        testingAfterRegistration: { await gate.enter() }
                    )
                }

                await gate.waitUntilEntered()
                let identifier = try #require(
                    try await fixture.waitForProcessIdentifiers(count: 1).first
                )
                #expect(Self.processExists(identifier))

                #expect(await OwnedSubprocessSupervisor.shutdownAll())
                gate.release()
                _ = await run.result
                try await Self.waitUntil { !Self.processExists(identifier) }

                do {
                    _ = try await BoundedOwnedProcessRunner.run(
                        configuration: fixture.configuration,
                        timeout: .milliseconds(50)
                    )
                    Issue.record("The Quit fence must reject a later launch")
                } catch {
                    #expect(error is CancellationError)
                }
                #expect(await Self.restoreProbeLaunching())
            } catch {
                _ = await Self.restoreProbeLaunching()
                throw error
            }
        }
    }

    private static func processExists(_ processIdentifier: pid_t) -> Bool {
        if Darwin.kill(processIdentifier, 0) == 0 { return true }
        return errno != ESRCH
    }

    private static func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }

    private static func restoreProbeLaunching() async -> Bool {
        for _ in 0..<3 {
            if await OwnedSubprocessSupervisor.resumeLaunching() { return true }
            _ = await OwnedSubprocessSupervisor.shutdownAll()
        }
        return await OwnedSubprocessSupervisor.resumeLaunching()
    }
}

/// The application lifecycle serializes environment preparation against Quit
/// with its launch lease. These tests exercise the same global probe registry
/// from otherwise independent Swift Testing suites, so mirror that production
/// exclusion when one test deliberately closes the process-launch gate.
/// Every Core test that starts a `BoundedOwnedProcessRunner` must hold this
/// lease so that the gate-mutating test cannot terminate an unrelated probe.
enum OwnedSubprocessSupervisorTestLease {
    private static let mutex = OwnedSubprocessSupervisorTestMutex()

    static func withLease<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        await mutex.acquire()
        do {
            let value = try await operation()
            await mutex.release()
            return value
        } catch {
            await mutex.release()
            throw error
        }
    }
}

private actor OwnedSubprocessSupervisorTestMutex {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}

private actor OwnedProcessRegistrationGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    nonisolated func release() {
        Task { await releaseAll() }
    }

    private func releaseAll() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private struct OwnedProcessFixture {
    let directory: URL
    let executableURL: URL
    let processIdentifierFile: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codeness-owned-process-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        executableURL = directory.appendingPathComponent("fixture")
        processIdentifierFile = directory.appendingPathComponent("pids")
        try Data(script.utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    var configuration: SupervisedProcessLaunchConfiguration {
        var environment = ProcessInfo.processInfo.environment
        environment["CODENESS_PID_FILE"] = processIdentifierFile.path
        return SupervisedProcessLaunchConfiguration(
            executableURL: executableURL,
            arguments: [],
            environment: environment,
            currentDirectoryURL: directory
        )
    }

    func waitForProcessIdentifiers(count: Int) async throws -> [pid_t] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let text = try? String(contentsOf: processIdentifierFile, encoding: .utf8) {
                let identifiers = text.split(whereSeparator: \.isWhitespace).compactMap {
                    pid_t($0)
                }
                if identifiers.count >= count {
                    return Array(identifiers.prefix(count))
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
