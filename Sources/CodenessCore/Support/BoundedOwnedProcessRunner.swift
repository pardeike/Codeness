import Darwin
import Dispatch
import Foundation

public enum OwnedSubprocessSupervisor {
    /// Stops every short-lived executable probe that is still owned by
    /// Codeness. A false result retains the ownership scope for a later retry.
    @discardableResult
    public static func shutdownAll() async -> Bool {
        await BoundedOwnedProcessRegistry.shared.shutdownAll()
    }

    /// Reopens the short-lived probe launch gate after an application Quit was
    /// canceled. Previously issued lifecycle tokens remain invalid in the app.
    @discardableResult
    public static func resumeLaunching() async -> Bool {
        await BoundedOwnedProcessRegistry.shared.resumeLaunching()
    }
}

struct BoundedOwnedProcessResult: Sendable {
    let termination: SubprocessTermination
    let standardOutput: Data
    let standardError: Data
}

enum BoundedOwnedProcessError: LocalizedError, Sendable {
    case timedOut(Duration)
    case outputLimit(stream: String, maximumByteCount: Int)
    case cleanupUnverified

    var errorDescription: String? {
        switch self {
        case .timedOut(let timeout):
            "The executable did not finish within \(timeout)."
        case .outputLimit(let stream, let maximumByteCount):
            "The executable's \(stream) exceeded the \(maximumByteCount)-byte safety limit."
        case .cleanupUnverified:
            "Codeness could not verify that every process started by the executable probe stopped."
        }
    }
}

enum BoundedOwnedProcessRunner {
    static func run(
        configuration: SupervisedProcessLaunchConfiguration,
        standardInput: Data? = nil,
        timeout: Duration = .seconds(5),
        maximumStandardOutputByteCount: Int = 4 * 1_024 * 1_024,
        maximumStandardErrorByteCount: Int = 4 * 1_024 * 1_024,
        testingAfterRegistration: (@Sendable () async -> Void)? = nil,
        testingCleanupResultOverride: (@Sendable (Int) -> Bool?)? = nil
    ) async throws -> BoundedOwnedProcessResult {
        let (identifier, execution) = try await BoundedOwnedProcessRegistry.shared
            .launchAndRegister(
            configuration: configuration,
            maximumStandardOutputByteCount: maximumStandardOutputByteCount,
            maximumStandardErrorByteCount: maximumStandardErrorByteCount,
            testingCleanupResultOverride: testingCleanupResultOverride
        )
        await testingAfterRegistration?()
        await execution.ensureStarted()

        do {
            let result = try await execution.run(
                standardInput: standardInput,
                timeout: timeout
            )
            guard await execution.shutdown() else {
                throw BoundedOwnedProcessError.cleanupUnverified
            }
            await BoundedOwnedProcessRegistry.shared.remove(identifier: identifier)
            return result
        } catch {
            let cleaned = await execution.shutdown()
            if cleaned {
                await BoundedOwnedProcessRegistry.shared.remove(identifier: identifier)
            }
            if !cleaned {
                throw BoundedOwnedProcessError.cleanupUnverified
            }
            throw error
        }
    }
}

private actor BoundedOwnedProcessRegistry {
    static let shared = BoundedOwnedProcessRegistry()

    private var executions: [UUID: BoundedOwnedProcessExecution] = [:]
    private var acceptsLaunches = true

    func launchAndRegister(
        configuration: SupervisedProcessLaunchConfiguration,
        maximumStandardOutputByteCount: Int,
        maximumStandardErrorByteCount: Int,
        testingCleanupResultOverride: (@Sendable (Int) -> Bool?)?
    ) throws -> (UUID, BoundedOwnedProcessExecution) {
        guard acceptsLaunches else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        // This synchronous spawn and registration happen under one actor turn.
        // shutdownAll cannot observe an empty registry after the child exists.
        let process = try AppServerProcess.launch(configuration: configuration)
        let identifier = UUID()
        let execution = BoundedOwnedProcessExecution(
            process: process,
            identifier: identifier,
            maximumStandardOutputByteCount: maximumStandardOutputByteCount,
            maximumStandardErrorByteCount: maximumStandardErrorByteCount,
            testingCleanupResultOverride: testingCleanupResultOverride
        )
        executions[identifier] = execution
        return (identifier, execution)
    }

    func remove(identifier: UUID) {
        executions.removeValue(forKey: identifier)
    }

    func shutdownAll() async -> Bool {
        acceptsLaunches = false
        var verified = true
        let snapshot = executions
        for (identifier, execution) in snapshot {
            if await execution.shutdown() {
                executions.removeValue(forKey: identifier)
            } else {
                verified = false
            }
        }
        return verified
    }

    func resumeLaunching() -> Bool {
        guard executions.isEmpty else {
            acceptsLaunches = false
            return false
        }
        acceptsLaunches = true
        return true
    }
}

private actor BoundedOwnedProcessExecution {
    private enum Completion {
        case pending
        case failed(BoundedOwnedProcessError)
        case finished(BoundedOwnedProcessResult)
    }

    private let process: AppServerProcess
    private let identifier: UUID
    private let maximumStandardOutputByteCount: Int
    private let maximumStandardErrorByteCount: Int
    private let writer: OrderedPipeWriter
    private let outputReader: BoundedPipeReader
    private let errorReader: BoundedPipeReader
    private let testingCleanupResultOverride: (@Sendable (Int) -> Bool?)?
    private var standardOutput = Data()
    private var standardError = Data()
    private var outputReachedEOF = false
    private var errorReachedEOF = false
    private var termination: SubprocessTermination?
    private var failure: BoundedOwnedProcessError?
    private var waitTask: Task<Void, Never>?
    private var cleanupTask: Task<Bool, Never>?
    private var cleanupAttempt = 0
    private var started = false

    init(
        process: AppServerProcess,
        identifier: UUID,
        maximumStandardOutputByteCount: Int,
        maximumStandardErrorByteCount: Int,
        testingCleanupResultOverride: (@Sendable (Int) -> Bool?)?
    ) {
        self.process = process
        self.identifier = identifier
        self.maximumStandardOutputByteCount = max(1, maximumStandardOutputByteCount)
        self.maximumStandardErrorByteCount = max(1, maximumStandardErrorByteCount)
        self.testingCleanupResultOverride = testingCleanupResultOverride
        writer = OrderedPipeWriter(
            fileDescriptor: process.inputFileDescriptor,
            generation: Int64(bitPattern: identifier.stableUInt64)
        )
        outputReader = BoundedPipeReader(
            fileDescriptor: process.outputFileDescriptor,
            label: "ap.codeness.probe.stdout.\(identifier.uuidString)",
            qos: .userInitiated
        )
        errorReader = BoundedPipeReader(
            fileDescriptor: process.errorFileDescriptor,
            label: "ap.codeness.probe.stderr.\(identifier.uuidString)",
            qos: .utility
        )
    }

    func ensureStarted() {
        guard !started else { return }
        started = true
        outputReader.start(
            consume: { [weak self] data in
                await self?.appendStandardOutput(data)
            },
            reachedEOF: { [weak self] in
                await self?.markOutputEOF()
            }
        )
        errorReader.start(
            consume: { [weak self] data in
                await self?.appendStandardError(data)
            },
            reachedEOF: { [weak self] in
                await self?.markErrorEOF()
            }
        )
        let process = process
        waitTask = Task.detached(priority: .utility) { [weak self] in
            var waitStatus: Int32 = 0
            var result: pid_t
            while true {
                result = unsafe waitpid(process.processIdentifier, &waitStatus, 0)
                if result == -1, errno == EINTR { continue }
                break
            }
            let termination: SubprocessTermination
            if result == process.processIdentifier {
                let signal = waitStatus & 0x7F
                termination = signal == 0
                    ? SubprocessTermination(
                        reason: .exit,
                        status: (waitStatus >> 8) & 0xFF
                    )
                    : SubprocessTermination(reason: .uncaughtSignal, status: signal)
            } else {
                termination = SubprocessTermination(reason: .exit, status: -1)
            }
            await self?.recordTermination(termination)
        }
    }

    func run(standardInput: Data?, timeout: Duration) async throws
        -> BoundedOwnedProcessResult {
        ensureStarted()
        do {
            if let standardInput, !standardInput.isEmpty {
                let token = UUID()
                defer { writer.forget(token: token) }
                try await writer.write(standardInput, token: token)
            }
            writer.close()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                try Task.checkCancellation()
                switch completion {
                case .pending:
                    try await Task.sleep(for: .milliseconds(10))
                case .failed(let error):
                    throw error
                case .finished(let result):
                    return result
                }
            }
            throw BoundedOwnedProcessError.timedOut(timeout)
        } catch {
            writer.close()
            throw error
        }
    }

    func shutdown() async -> Bool {
        ensureStarted()
        if let cleanupTask {
            return await cleanupTask.value
        }
        cleanupAttempt &+= 1
        let cleanupAttempt = cleanupAttempt
        let testingCleanupResultOverride = testingCleanupResultOverride
        let task = Task { [weak self] in
            guard await self?.performShutdown() == true else { return false }
            return testingCleanupResultOverride?(cleanupAttempt) ?? true
        }
        cleanupTask = task
        let verified = await task.value
        if !verified {
            cleanupTask = nil
        }
        return verified
    }

    private func performShutdown() async -> Bool {
        writer.close()
        _ = process.signalOwnedProcesses(SIGTERM)
        if process.ownedProcessesExist {
            try? await Task.sleep(for: .milliseconds(100))
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .milliseconds(750))
            repeat {
                _ = process.signalOwnedProcesses(SIGKILL)
                let sweepDeadline = min(
                    deadline,
                    clock.now.advanced(by: .milliseconds(100))
                )
                while process.trackedProcessesExist, clock.now < sweepDeadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            } while process.ownedProcessesExist && clock.now < deadline
        }
        guard !process.ownedProcessesExist else { return false }

        let clock = ContinuousClock()
        let reapDeadline = clock.now.advanced(by: .milliseconds(500))
        while termination == nil, clock.now < reapDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard termination != nil else { return false }

        await outputReader.stop(cancelConsumer: true)
        await errorReader.stop(cancelConsumer: true)
        await writer.closeAndWait()
        await process.stopMonitoringOwnedProcesses()
        waitTask?.cancel()
        waitTask = nil
        return true
    }

    private var completion: Completion {
        if let failure { return .failed(failure) }
        guard let termination, outputReachedEOF, errorReachedEOF else {
            return .pending
        }
        return .finished(BoundedOwnedProcessResult(
            termination: termination,
            standardOutput: standardOutput,
            standardError: standardError
        ))
    }

    private func appendStandardOutput(_ data: Data) {
        guard failure == nil else { return }
        guard data.count <= maximumStandardOutputByteCount - standardOutput.count else {
            failure = .outputLimit(
                stream: "standard output",
                maximumByteCount: maximumStandardOutputByteCount
            )
            return
        }
        standardOutput.append(data)
    }

    private func appendStandardError(_ data: Data) {
        guard failure == nil else { return }
        guard data.count <= maximumStandardErrorByteCount - standardError.count else {
            failure = .outputLimit(
                stream: "standard error",
                maximumByteCount: maximumStandardErrorByteCount
            )
            return
        }
        standardError.append(data)
    }

    private func markOutputEOF() {
        outputReachedEOF = true
    }

    private func markErrorEOF() {
        errorReachedEOF = true
    }

    private func recordTermination(_ termination: SubprocessTermination) {
        self.termination = termination
    }
}

private extension UUID {
    var stableUInt64: UInt64 {
        uuidString.utf8.reduce(14_695_981_039_346_656_037) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
