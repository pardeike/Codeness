import Darwin
import Dispatch
import Foundation

struct SupervisedProcessLaunchConfiguration: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
    }
}

private struct SupervisedProcessIdentity: Hashable, Sendable {
    let processIdentifier: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let userIdentifier: uid_t
}

private struct SupervisedProcessSnapshot: Sendable {
    let identity: SupervisedProcessIdentity
    let parentProcessIdentifier: pid_t
    let processGroupIdentifier: pid_t
    let status: UInt32
}

/// Tracks every process that inherits a generation-specific pipe descriptor.
///
/// Codex deliberately starts each MCP server in its own process group, so the
/// App Server's group is not a complete ownership boundary. A pipe descriptor
/// explicitly inherited by the App Server survives ordinary fork/exec child
/// launches and gives Codeness a kernel-visible ownership marker even after a
/// child changes process group, creates a session, or is reparented. Recursive
/// ancestry polling is retained as a second source and remembers children that
/// later close the marker.
private final class AppServerProcessScope: @unchecked Sendable {
    private static let maximumTrackedProcessCount = 4_096
    private static let maximumEnumeratedProcessCount = 32_768
    private static let monitorInterval = Duration.milliseconds(25)
    private static let markerSweepInterval = 10

    let markerFileDescriptor: Int32
    private let markerPipeHandle: UInt64
    private let ownerUserIdentifier = geteuid()
    private let lock = NSLock()
    private var rootIdentity: SupervisedProcessIdentity?
    private var trackedIdentities: Set<SupervisedProcessIdentity> = []
    private var trackingFailure: String?
    private var monitorTask: Task<Void, Never>?

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard unsafe pipe(&descriptors) == 0 else {
            throw Self.posixError()
        }
        markerFileDescriptor = descriptors[0]
        Darwin.close(descriptors[1])

        guard fcntl(markerFileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let error = Self.posixError()
            Darwin.close(markerFileDescriptor)
            throw error
        }
        guard let handle = Self.pipeHandle(
            processIdentifier: getpid(),
            fileDescriptor: markerFileDescriptor
        ) else {
            Darwin.close(markerFileDescriptor)
            throw NSError(
                domain: "ap.codeness.app-server.scope",
                code: Int(EIO),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Codeness could not create a verifiable App Server ownership marker."
                ]
            )
        }
        markerPipeHandle = handle
    }

    deinit {
        monitorTask?.cancel()
        Darwin.close(markerFileDescriptor)
    }

    func attachRoot(processIdentifier: pid_t) throws {
        guard let snapshot = Self.snapshot(processIdentifier: processIdentifier) else {
            // A one-shot executable can exec and exit between posix_spawn's
            // return and proc_pidinfo. Because an unreaped child PID cannot be
            // reused, waitid(WNOWAIT) is a safe ownership proof that preserves
            // the exit status for the execution's normal waitpid task.
            guard Self.childHasExitedWithoutReaping(processIdentifier) else {
                throw NSError(
                    domain: "ap.codeness.app-server.scope",
                    code: Int(ESRCH),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Codeness could not identify the launched App Server process."
                    ]
                )
            }
            captureOwnedProcesses(includeMarkerSweep: true)
            return
        }
        guard snapshot.identity.userIdentifier == ownerUserIdentifier else {
            throw NSError(
                domain: "ap.codeness.app-server.scope",
                code: Int(ESRCH),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Codeness could not identify the launched App Server process."
                ]
            )
        }
        guard Self.pipeHandle(
            processIdentifier: processIdentifier,
            fileDescriptor: markerFileDescriptor
        ) == markerPipeHandle else {
            if Self.childHasExitedWithoutReaping(processIdentifier) {
                lock.withLock {
                    rootIdentity = snapshot.identity
                    trackedIdentities.insert(snapshot.identity)
                }
                captureOwnedProcesses(includeMarkerSweep: true)
                return
            }
            throw NSError(
                domain: "ap.codeness.app-server.scope",
                code: Int(EIO),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The launched App Server did not inherit its ownership marker."
                ]
            )
        }
        lock.withLock {
            rootIdentity = snapshot.identity
            trackedIdentities.insert(snapshot.identity)
        }
    }

    func rootHasExitedWithoutReaping(processIdentifier: pid_t) -> Bool {
        Self.childHasExitedWithoutReaping(processIdentifier)
    }

    func startMonitoring() {
        guard lock.withLock({ monitorTask == nil }) else { return }
        captureOwnedProcesses(includeMarkerSweep: true)
        let task = Task.detached(priority: .utility) { [weak self] in
            var iteration = 0
            while !Task.isCancelled {
                self?.captureOwnedProcesses(
                    includeMarkerSweep: iteration.isMultiple(of: Self.markerSweepInterval)
                )
                iteration &+= 1
                do {
                    try await Task.sleep(for: Self.monitorInterval)
                } catch {
                    return
                }
            }
        }
        lock.withLock {
            if monitorTask == nil {
                monitorTask = task
            } else {
                task.cancel()
            }
        }
    }

    func stopMonitoring() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let task = monitorTask
            monitorTask = nil
            return task
        }
        task?.cancel()
        await task?.value
    }

    @discardableResult
    func signalOwnedProcesses(
        _ signal: Int32,
        rootProcessGroupIdentifier: pid_t
    ) -> Bool {
        captureOwnedProcesses(includeMarkerSweep: true)
        let snapshots = liveTrackedSnapshots()
        let rootIdentity = lock.withLock { self.rootIdentity }
        var succeeded = true

        // Stop independently grouped/sessioned descendants before the root.
        // This minimizes the interval in which they could be reparented before
        // receiving the same termination signal.
        for snapshot in snapshots where snapshot.identity != rootIdentity {
            succeeded = Self.signal(
                snapshot.identity,
                signal: signal
            ) && succeeded
        }

        // A group signal catches an as-yet-unobserved child that still shares
        // the root group. Only target it while a revalidated owned identity is
        // currently a member, avoiding a stale/reused process-group ID.
        if rootProcessGroupIdentifier > 1,
           rootProcessGroupIdentifier != getpgrp(),
           snapshots.contains(where: { snapshot in
               snapshot.processGroupIdentifier == rootProcessGroupIdentifier
                   && Self.snapshot(matching: snapshot.identity)?.processGroupIdentifier
                       == rootProcessGroupIdentifier
           }) {
            if Darwin.kill(-rootProcessGroupIdentifier, signal) != 0, errno != ESRCH {
                succeeded = false
            }
        }

        if let rootIdentity,
           snapshots.contains(where: { $0.identity == rootIdentity }) {
            succeeded = Self.signal(rootIdentity, signal: signal) && succeeded
        }
        return succeeded
    }

    var ownedProcessesExist: Bool {
        captureOwnedProcesses(includeMarkerSweep: true)
        return failureDescription != nil || !liveTrackedSnapshots().isEmpty
    }

    var trackedProcessesExist: Bool {
        failureDescription != nil || !liveTrackedSnapshots().isEmpty
    }

    var failureDescription: String? {
        lock.withLock { trackingFailure }
    }

    private func captureOwnedProcesses(includeMarkerSweep: Bool) {
        captureDescendants()
        if includeMarkerSweep {
            captureMarkerHolders()
        }
    }

    private func captureDescendants() {
        var queue = liveTrackedSnapshots()
        var visited = Set(queue.map(\.identity))
        var index = 0
        while index < queue.count {
            let parent = queue[index]
            index += 1
            guard let currentParent = Self.snapshot(matching: parent.identity),
                  currentParent.status != UInt32(SZOMB) else { continue }

            let children = Self.childProcessIdentifiers(
                of: parent.identity.processIdentifier,
                limit: Self.maximumTrackedProcessCount
            )
            if children.wasTruncated {
                recordFailure("the App Server descendant count exceeded the safety limit")
            }
            for childPID in children.processIdentifiers {
                guard childPID > 1,
                      childPID != getpid(),
                      let child = Self.snapshot(processIdentifier: childPID),
                      child.parentProcessIdentifier == parent.identity.processIdentifier,
                      child.identity.userIdentifier == ownerUserIdentifier,
                      child.status != UInt32(SZOMB),
                      visited.insert(child.identity).inserted else { continue }
                guard remember(child.identity) else { return }
                queue.append(child)
            }
        }
    }

    private func captureMarkerHolders() {
        let result = Self.allProcessIdentifiers(
            limit: Self.maximumEnumeratedProcessCount
        )
        if result.wasTruncated {
            recordFailure("the system process count exceeded the ownership-scan safety limit")
        }
        for processIdentifier in result.processIdentifiers
            where processIdentifier > 1 && processIdentifier != getpid() {
            guard let before = Self.snapshot(processIdentifier: processIdentifier),
                  before.identity.userIdentifier == ownerUserIdentifier,
                  before.status != UInt32(SZOMB),
                  Self.pipeHandle(
                      processIdentifier: processIdentifier,
                      fileDescriptor: markerFileDescriptor
                  ) == markerPipeHandle,
                  let after = Self.snapshot(matching: before.identity),
                  after.status != UInt32(SZOMB) else { continue }
            guard remember(after.identity) else { return }
        }
    }

    private func remember(_ identity: SupervisedProcessIdentity) -> Bool {
        lock.withLock {
            guard trackedIdentities.contains(identity)
                    || trackedIdentities.count < Self.maximumTrackedProcessCount else {
                trackingFailure =
                    "the App Server process scope exceeded the \(Self.maximumTrackedProcessCount)-process safety limit"
                return false
            }
            trackedIdentities.insert(identity)
            return true
        }
    }

    private func recordFailure(_ description: String) {
        lock.withLock {
            if trackingFailure == nil {
                trackingFailure = description
            }
        }
    }

    private func liveTrackedSnapshots() -> [SupervisedProcessSnapshot] {
        let identities = lock.withLock { trackedIdentities }
        var live: [SupervisedProcessSnapshot] = []
        var expired: [SupervisedProcessIdentity] = []
        live.reserveCapacity(identities.count)
        for identity in identities {
            guard let snapshot = Self.snapshot(matching: identity),
                  snapshot.status != UInt32(SZOMB) else {
                expired.append(identity)
                continue
            }
            live.append(snapshot)
        }
        if !expired.isEmpty {
            lock.withLock {
                trackedIdentities.subtract(expired)
            }
        }
        return live
    }

    private static func snapshot(
        matching identity: SupervisedProcessIdentity
    ) -> SupervisedProcessSnapshot? {
        guard let snapshot = snapshot(processIdentifier: identity.processIdentifier),
              snapshot.identity == identity else { return nil }
        return snapshot
    }

    private static func snapshot(
        processIdentifier: pid_t
    ) -> SupervisedProcessSnapshot? {
        var information = proc_bsdinfo()
        let byteCount = withUnsafeMutablePointer(to: &information) { pointer in
            unsafe proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        guard byteCount == MemoryLayout<proc_bsdinfo>.size,
              information.pbi_pid == UInt32(processIdentifier) else { return nil }
        return SupervisedProcessSnapshot(
            identity: SupervisedProcessIdentity(
                processIdentifier: processIdentifier,
                startSeconds: information.pbi_start_tvsec,
                startMicroseconds: information.pbi_start_tvusec,
                userIdentifier: information.pbi_uid
            ),
            parentProcessIdentifier: pid_t(information.pbi_ppid),
            processGroupIdentifier: pid_t(information.pbi_pgid),
            status: information.pbi_status
        )
    }

    private static func pipeHandle(
        processIdentifier: pid_t,
        fileDescriptor: Int32
    ) -> UInt64? {
        var information = pipe_fdinfo()
        let byteCount = withUnsafeMutablePointer(to: &information) { pointer in
            unsafe proc_pidfdinfo(
                processIdentifier,
                fileDescriptor,
                PROC_PIDFDPIPEINFO,
                pointer,
                Int32(MemoryLayout<pipe_fdinfo>.size)
            )
        }
        guard byteCount == MemoryLayout<pipe_fdinfo>.size else { return nil }
        return information.pipeinfo.pipe_handle
    }

    private static func childProcessIdentifiers(
        of parentProcessIdentifier: pid_t,
        limit: Int
    ) -> (processIdentifiers: [pid_t], wasTruncated: Bool) {
        let suggestedCount = max(16, Int(proc_listchildpids(
            parentProcessIdentifier,
            nil,
            0
        )))
        let capacity = min(suggestedCount + 16, limit)
        var identifiers = [pid_t](repeating: 0, count: capacity)
        let count = identifiers.withUnsafeMutableBytes { buffer in
            unsafe proc_listchildpids(
                parentProcessIdentifier,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard count > 0 else { return ([], false) }
        let resolvedCount = min(Int(count), identifiers.count)
        return (
            Array(identifiers.prefix(resolvedCount)).filter { $0 > 0 },
            Int(count) >= identifiers.count
        )
    }

    private static func childHasExitedWithoutReaping(
        _ processIdentifier: pid_t
    ) -> Bool {
        var information = unsafe siginfo_t()
        let result = unsafe waitid(
            P_PID,
            id_t(processIdentifier),
            &information,
            WEXITED | WNOHANG | WNOWAIT
        )
        let observedProcessIdentifier = unsafe information.si_pid
        return result == 0 && observedProcessIdentifier == processIdentifier
    }

    private static func allProcessIdentifiers(
        limit: Int
    ) -> (processIdentifiers: [pid_t], wasTruncated: Bool) {
        let suggestedCount = max(64, Int(proc_listallpids(nil, 0)))
        let capacity = min(suggestedCount + 64, limit)
        var identifiers = [pid_t](repeating: 0, count: capacity)
        let count = identifiers.withUnsafeMutableBytes { buffer in
            unsafe proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return ([], false) }
        let resolvedCount = min(Int(count), identifiers.count)
        return (
            Array(identifiers.prefix(resolvedCount)).filter { $0 > 0 },
            Int(count) >= identifiers.count
        )
    }

    private static func signal(
        _ identity: SupervisedProcessIdentity,
        signal: Int32
    ) -> Bool {
        guard identity.processIdentifier > 1,
              identity.processIdentifier != getpid(),
              snapshot(matching: identity) != nil else { return true }
        if Darwin.kill(identity.processIdentifier, signal) == 0 { return true }
        return errno == ESRCH
    }

    private static func posixError() -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: unsafe String(cString: strerror(errno))]
        )
    }
}

struct AppServerProcess: Sendable {
    let processIdentifier: pid_t
    let processGroupIdentifier: pid_t
    let inputFileDescriptor: Int32
    let outputFileDescriptor: Int32
    let errorFileDescriptor: Int32
    private let scope: AppServerProcessScope

    static func launch(configuration: CodexLaunchConfiguration) throws -> AppServerProcess {
        try launch(configuration: SupervisedProcessLaunchConfiguration(
            executableURL: configuration.executableURL,
            arguments: configuration.arguments,
            environment: configuration.environment
        ))
    }

    static func launch(
        configuration: SupervisedProcessLaunchConfiguration,
        testingBeforeProcessGroupValidation: (@Sendable (pid_t) -> Void)? = nil
    ) throws -> AppServerProcess {
        var standardInput = [Int32](repeating: -1, count: 2)
        var standardOutput = [Int32](repeating: -1, count: 2)
        var standardError = [Int32](repeating: -1, count: 2)
        guard unsafe pipe(&standardInput) == 0 else { throw posixError() }
        guard unsafe pipe(&standardOutput) == 0 else {
            closePair(standardInput)
            throw posixError()
        }
        guard unsafe pipe(&standardError) == 0 else {
            closePair(standardInput)
            closePair(standardOutput)
            throw posixError()
        }
        let scope: AppServerProcessScope
        do {
            // Allocate the ownership marker after the three stdio pipes. In a
            // normal GUI process this places it at descriptor 9, which stays
            // clear of both stdio and the low descriptors runtimes commonly
            // open during their own initialization.
            scope = try AppServerProcessScope()
        } catch {
            closePair(standardInput)
            closePair(standardOutput)
            closePair(standardError)
            throw error
        }

        var ownsAllDescriptors = true
        defer {
            if ownsAllDescriptors {
                closePair(standardInput)
                closePair(standardOutput)
                closePair(standardError)
            }
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let actionsResult = unsafe posix_spawn_file_actions_init(&actions)
        guard actionsResult == 0 else { throw posixError(actionsResult) }
        let attributesResult = unsafe posix_spawnattr_init(&attributes)
        guard attributesResult == 0 else {
            unsafe posix_spawn_file_actions_destroy(&actions)
            throw posixError(attributesResult)
        }
        defer {
            unsafe posix_spawn_file_actions_destroy(&actions)
            unsafe posix_spawnattr_destroy(&attributes)
        }

        if let currentDirectoryURL = configuration.currentDirectoryURL {
            let changeDirectoryResult = currentDirectoryURL.path.withCString { path in
                if #available(macOS 26.0, *) {
                    unsafe posix_spawn_file_actions_addchdir(&actions, path)
                } else {
                    unsafe posix_spawn_file_actions_addchdir_np(&actions, path)
                }
            }
            guard changeDirectoryResult == 0 else {
                throw posixError(changeDirectoryResult)
            }
        }

        let fileActions = [
            unsafe posix_spawn_file_actions_adddup2(&actions, standardInput[0], STDIN_FILENO),
            unsafe posix_spawn_file_actions_adddup2(&actions, standardOutput[1], STDOUT_FILENO),
            unsafe posix_spawn_file_actions_adddup2(&actions, standardError[1], STDERR_FILENO),
            unsafe posix_spawn_file_actions_addinherit_np(
                &actions,
                scope.markerFileDescriptor
            )
        ] + (standardInput + standardOutput + standardError).map {
            unsafe posix_spawn_file_actions_addclose(&actions, $0)
        }
        guard fileActions.allSatisfy({ $0 == 0 }) else {
            throw posixError(fileActions.first(where: { $0 != 0 }))
        }

        var defaultSignals = sigset_t()
        var signalMask = sigset_t()
        guard unsafe sigfillset(&defaultSignals) == 0,
              unsafe sigdelset(&defaultSignals, SIGKILL) == 0,
              unsafe sigdelset(&defaultSignals, SIGSTOP) == 0,
              unsafe sigemptyset(&signalMask) == 0 else {
            throw posixError()
        }
        let spawnFlags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_CLOEXEC_DEFAULT
        )
        let flagsResult = unsafe posix_spawnattr_setflags(&attributes, spawnFlags)
        let groupResult = unsafe posix_spawnattr_setpgroup(&attributes, 0)
        let defaultsResult = unsafe posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        let maskResult = unsafe posix_spawnattr_setsigmask(&attributes, &signalMask)
        guard flagsResult == 0,
              groupResult == 0,
              defaultsResult == 0,
              maskResult == 0 else {
            throw posixError(
                [flagsResult, groupResult, defaultsResult, maskResult].first(where: { $0 != 0 })
            )
        }

        let argumentStrings = [configuration.executableURL.path] + configuration.arguments
        let environmentStrings = configuration.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let arguments = try unsafe makeCStringArray(argumentStrings)
        let environment = try unsafe makeCStringArray(environmentStrings)
        defer {
            unsafe freeCStringArray(arguments)
            unsafe freeCStringArray(environment)
        }

        var mutableArguments = unsafe arguments
        var mutableEnvironment = unsafe environment
        var processIdentifier: pid_t = 0
        let spawnResult = configuration.executableURL.path.withCString { executablePath in
            unsafe posix_spawn(
                &processIdentifier,
                executablePath,
                &actions,
                &attributes,
                &mutableArguments,
                &mutableEnvironment
            )
        }
        guard spawnResult == 0 else { throw posixError(spawnResult) }

        do {
            try scope.attachRoot(processIdentifier: processIdentifier)
        } catch {
            killLaunchScopeAndReap(
                processIdentifier: processIdentifier,
                scope: scope
            )
            throw error
        }

        Darwin.close(standardInput[0])
        Darwin.close(standardOutput[1])
        Darwin.close(standardError[1])
        standardInput[0] = -1
        standardOutput[1] = -1
        standardError[1] = -1

        testingBeforeProcessGroupValidation?(processIdentifier)
        let processGroupIdentifier = getpgid(processIdentifier)
        let exitedBeforeGroupValidation = processGroupIdentifier == -1
            && scope.rootHasExitedWithoutReaping(processIdentifier: processIdentifier)
        let verifiedProcessGroupIdentifier = exitedBeforeGroupValidation
            ? processIdentifier
            : processGroupIdentifier
        guard verifiedProcessGroupIdentifier == processIdentifier,
              verifiedProcessGroupIdentifier > 1,
              verifiedProcessGroupIdentifier != getpgrp() else {
            // POSIX_SPAWN_SETPGROUP with pgroup 0 makes the new leader's PID
            // its process-group ID. If the leader forks and exits before this
            // validation, getpgid(leader) can already report ESRCH while a
            // same-group descendant remains alive. The leader is still our
            // unreaped child, so its PID cannot be reused here: target that
            // known group before reaping the leader, then also target the
            // leader directly for validation failures where it is still live.
            killLaunchScopeAndReap(
                processIdentifier: processIdentifier,
                scope: scope
            )
            throw NSError(
                domain: "ap.codeness.app-server.spawn",
                code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: "The Codex App Server did not enter its isolated process group."]
            )
        }

        for descriptor in [standardInput[1], standardOutput[0], standardError[0]] {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                let error = posixError()
                killAndReap(
                    processIdentifier: processIdentifier,
                    processGroupIdentifier: processGroupIdentifier,
                    scope: scope
                )
                throw error
            }
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                let error = posixError()
                killAndReap(
                    processIdentifier: processIdentifier,
                    processGroupIdentifier: processGroupIdentifier,
                    scope: scope
                )
                throw error
            }
        }
        guard fcntl(standardInput[1], F_SETNOSIGPIPE, 1) == 0 else {
            let error = posixError()
            killAndReap(
                processIdentifier: processIdentifier,
                processGroupIdentifier: processGroupIdentifier,
                scope: scope
            )
            throw error
        }
        ownsAllDescriptors = false
        let result = AppServerProcess(
            processIdentifier: processIdentifier,
            processGroupIdentifier: verifiedProcessGroupIdentifier,
            inputFileDescriptor: standardInput[1],
            outputFileDescriptor: standardOutput[0],
            errorFileDescriptor: standardError[0],
            scope: scope
        )
        result.startMonitoringOwnedProcesses()
        return result
    }

    @discardableResult
    func signalOwnedProcesses(_ signal: Int32) -> Bool {
        scope.signalOwnedProcesses(
            signal,
            rootProcessGroupIdentifier: processGroupIdentifier
        )
    }

    // Claude's stdio provider shares this transport primitive. Keep its
    // group-oriented spelling while applying the full ownership scope.
    @discardableResult
    func signalGroup(_ signal: Int32) -> Bool {
        signalOwnedProcesses(signal)
    }

    var ownedProcessesExist: Bool {
        scope.ownedProcessesExist
    }

    var groupExists: Bool {
        ownedProcessesExist
    }

    var trackedProcessesExist: Bool {
        scope.trackedProcessesExist
    }

    var scopeFailureDescription: String? {
        scope.failureDescription
    }

    func startMonitoringOwnedProcesses() {
        scope.startMonitoring()
    }

    func stopMonitoringOwnedProcesses() async {
        await scope.stopMonitoring()
    }

    private static func closePair(_ pair: [Int32]) {
        pair.filter { $0 >= 0 }.forEach { Darwin.close($0) }
    }

    private static func killAndReap(
        processIdentifier: pid_t,
        processGroupIdentifier: pid_t,
        scope: AppServerProcessScope
    ) {
        _ = scope.signalOwnedProcesses(
            SIGKILL,
            rootProcessGroupIdentifier: processGroupIdentifier
        )
        Darwin.kill(processIdentifier, SIGKILL)
        var status: Int32 = 0
        while unsafe waitpid(processIdentifier, &status, 0) == -1, errno == EINTR {}
        for _ in 0..<20 where scope.ownedProcessesExist {
            _ = scope.signalOwnedProcesses(
                SIGKILL,
                rootProcessGroupIdentifier: processGroupIdentifier
            )
            usleep(10_000)
        }
    }

    private static func killLaunchScopeAndReap(
        processIdentifier: pid_t,
        scope: AppServerProcessScope
    ) {
        killAndReap(
            processIdentifier: processIdentifier,
            processGroupIdentifier: processIdentifier,
            scope: scope
        )
    }

    private static func posixError(_ code: Int32? = nil) -> NSError {
        let resolvedCode = code ?? errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(resolvedCode),
            userInfo: [NSLocalizedDescriptionKey: unsafe String(cString: strerror(resolvedCode))]
        )
    }

    private static func makeCStringArray(
        _ strings: [String]
    ) throws -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = unsafe []
        unsafe result.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let copy = unsafe strdup(string) else {
                unsafe freeCStringArray(result)
                throw posixError(ENOMEM)
            }
            unsafe result.append(copy)
        }
        unsafe result.append(nil)
        return unsafe result
    }

    private static func freeCStringArray(_ strings: [UnsafeMutablePointer<CChar>?]) {
        for unsafe pointer in unsafe strings {
            if let pointer = unsafe pointer {
                unsafe free(pointer)
            }
        }
    }
}

final class OrderedPipeWriter: @unchecked Sendable {
    enum CancellationDisposition: Sendable {
        case cancelledBeforeWrite
        case writing
        case completed
        case failedAfterPartialWrite
        case unknown
    }

    private enum Phase {
        case queued
        case writing
        case completed
        case cancelled
        case failedAfterPartialWrite
    }

    private let fileDescriptor: Int32
    private let queue: DispatchQueue
    private let writeProgressHook: (@Sendable (_ messageByteCount: Int, _ byteCount: Int) -> Void)?
    private let lock = NSLock()
    private var isClosed = false
    private var closeCompleted = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var phases: [UUID: Phase] = [:]
    private var retainedByteCounts: [UUID: Int] = [:]
    private var retainedByteCount = 0
    private var cancelledBeforeAdmission: Set<UUID> = []
    private static let maximumQueuedWriteCount = 64
    private static let maximumMessageByteCount = 8 * 1_024 * 1_024
    private static let maximumRetainedByteCount = 12 * 1_024 * 1_024

    init(
        fileDescriptor: Int32,
        generation: Int64,
        writeProgressHook: (@Sendable (Int, Int) -> Void)? = nil
    ) {
        self.fileDescriptor = fileDescriptor
        self.writeProgressHook = writeProgressHook
        queue = DispatchQueue(
            label: "ap.codeness.app-server.stdin.\(generation)",
            qos: .userInitiated
        )
    }

    func write(_ data: Data, token: UUID) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                guard !isClosed else {
                    lock.unlock()
                    continuation.resume(throwing: AppServerClientError.notRunning)
                    return
                }
                guard cancelledBeforeAdmission.remove(token) == nil else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard phases.count < Self.maximumQueuedWriteCount else {
                    lock.unlock()
                    continuation.resume(throwing: AppServerClientError.invalidResponse(
                        "the App Server stdin write queue reached its safety limit"
                    ))
                    return
                }
                guard data.count <= Self.maximumMessageByteCount,
                      retainedByteCount <= Self.maximumRetainedByteCount - data.count else {
                    lock.unlock()
                    continuation.resume(throwing: AppServerClientError.invalidResponse(
                        "the App Server stdin write queue reached its byte safety limit"
                    ))
                    return
                }
                phases[token] = .queued
                retainedByteCounts[token] = data.count
                retainedByteCount += data.count
                lock.unlock()

                queue.async { [self] in
                    performWrite(data, token: token, continuation: continuation)
                }
            }
        }, onCancel: {
            _ = self.cancel(token: token)
        })
    }

    @discardableResult
    func cancel(token: UUID) -> CancellationDisposition {
        lock.lock()
        defer { lock.unlock() }
        guard let phase = phases[token] else {
            cancelledBeforeAdmission.insert(token)
            return .cancelledBeforeWrite
        }
        switch phase {
        case .queued:
            phases[token] = .cancelled
            return .cancelledBeforeWrite
        case .writing:
            phases[token] = .cancelled
            return .writing
        case .completed:
            return .completed
        case .failedAfterPartialWrite:
            return .failedAfterPartialWrite
        case .cancelled:
            return .cancelledBeforeWrite
        }
    }

    func forget(token: UUID) {
        lock.lock()
        phases.removeValue(forKey: token)
        releaseRetainedBytesLocked(token: token)
        cancelledBeforeAdmission.remove(token)
        lock.unlock()
    }

    var testingCancellationTombstoneCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelledBeforeAdmission.count
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        // Closing a descriptor from another thread while write/poll is in
        // flight can let the OS recycle the descriptor for a new generation
        // before this queue observes closure. Put the close behind every
        // admitted write so stale work cannot reach a recycled stdin.
        queue.async { [self] in finishCloseOnQueue() }
    }

    func closeAndWait() async {
        close()
        await withCheckedContinuation { continuation in
            lock.lock()
            if closeCompleted {
                lock.unlock()
                continuation.resume()
            } else {
                closeWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func performWrite(
        _ data: Data,
        token: UUID,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        lock.lock()
        guard !isClosed else {
            phases.removeValue(forKey: token)
            releaseRetainedBytesLocked(token: token)
            lock.unlock()
            continuation.resume(throwing: AppServerClientError.notRunning)
            return
        }
        guard phases[token] != .cancelled else {
            phases.removeValue(forKey: token)
            releaseRetainedBytesLocked(token: token)
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        phases[token] = .writing
        lock.unlock()

        var wroteAnyBytes = false
        do {
            try unsafe data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    try checkWritable(token: token)
                    let count = unsafe Darwin.write(
                        fileDescriptor,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if count > 0 {
                        wroteAnyBytes = true
                        offset += count
                        writeProgressHook?(rawBuffer.count, count)
                        continue
                    }
                    if count == -1, errno == EINTR { continue }
                    if count == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
                        _ = unsafe Darwin.poll(&descriptor, 1, 20)
                        continue
                    }
                    throw Self.posixError()
                }
            }
            lock.lock()
            phases[token] = .completed
            releaseRetainedBytesLocked(token: token)
            lock.unlock()
            continuation.resume()
        } catch {
            lock.lock()
            if wroteAnyBytes {
                phases[token] = .failedAfterPartialWrite
            } else {
                phases.removeValue(forKey: token)
            }
            releaseRetainedBytesLocked(token: token)
            lock.unlock()
            continuation.resume(throwing: error)
        }
    }

    private func checkWritable(token: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { throw AppServerClientError.notRunning }
        guard phases[token] != .cancelled else { throw CancellationError() }
    }

    private func releaseRetainedBytesLocked(token: UUID) {
        guard let byteCount = retainedByteCounts.removeValue(forKey: token) else { return }
        retainedByteCount -= byteCount
    }

    private func finishCloseOnQueue() {
        Darwin.close(fileDescriptor)
        lock.lock()
        closeCompleted = true
        let waiters = closeWaiters
        closeWaiters.removeAll(keepingCapacity: false)
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    private static func posixError() -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: unsafe String(cString: strerror(errno))]
        )
    }
}

final class BoundedPipeReader: @unchecked Sendable {
    private static let chunkSize = 64 * 1_024

    private let fileDescriptor: Int32
    private let queue: DispatchQueue
    private let beforeReadHook: (@Sendable () -> Void)?
    private let chunks = BoundedAsyncChannel<Data>(capacity: 4)
    private let lock = NSLock()
    private var stopped = false
    private var stopCompleted = false
    private var consumerCancellationRequested = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var consumerTask: Task<Void, Never>?

    init(
        fileDescriptor: Int32,
        label: String,
        qos: DispatchQoS,
        beforeReadHook: (@Sendable () -> Void)? = nil
    ) {
        self.fileDescriptor = fileDescriptor
        self.beforeReadHook = beforeReadHook
        queue = DispatchQueue(label: label, qos: qos)
    }

    func start(
        consume: @escaping @Sendable (Data) async -> Void,
        reachedEOF: @escaping @Sendable () async -> Void
    ) {
        let stream = chunks.stream()
        let task = Task {
            for await data in stream {
                guard !Task.isCancelled else { return }
                await consume(data)
            }
            guard !Task.isCancelled else { return }
            await reachedEOF()
        }
        lock.lock()
        consumerTask = task
        lock.unlock()

        queue.async { [self] in readLoop() }
    }

    func stop(cancelConsumer: Bool = true) async {
        let (shouldStartStop, taskToCancel) = prepareStop(
            cancelConsumer: cancelConsumer
        )

        taskToCancel?.cancel()
        if shouldStartStop {
            // A read loop waiting for channel capacity is released here. The
            // serial-queue close below is a join barrier: it cannot run until
            // readLoop has returned, so restart cannot recycle this descriptor
            // while stale code is still capable of reading from it.
            await chunks.cancel()
            queue.async { [self] in finishStopOnQueue() }
        }
        await waitForStopCompletion()
    }

    private func prepareStop(
        cancelConsumer: Bool
    ) -> (shouldStartStop: Bool, taskToCancel: Task<Void, Never>?) {
        lock.lock()
        let shouldStartStop = !stopped
        stopped = true
        let taskToCancel: Task<Void, Never>?
        if cancelConsumer, !consumerCancellationRequested {
            consumerCancellationRequested = true
            taskToCancel = consumerTask
        } else {
            taskToCancel = nil
        }
        lock.unlock()
        return (shouldStartStop, taskToCancel)
    }

    private func readLoop() {
        var bytes = [UInt8](repeating: 0, count: Self.chunkSize)
        while !isStopped {
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = unsafe Darwin.poll(&descriptor, 1, 50)
            if pollResult == -1, errno == EINTR { continue }
            if pollResult == -1 { break }
            if pollResult == 0 { continue }

            beforeReadHook?()
            let count = unsafe Darwin.read(fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                let data = unsafe Data(bytes: bytes, count: count)
                let admitted = DispatchSemaphore(value: 0)
                Task {
                    _ = await chunks.send(data)
                    admitted.signal()
                }
                admitted.wait()
                continue
            }
            if count == -1, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            break
        }
        Task { await chunks.finish() }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func waitForStopCompletion() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stopCompleted {
                lock.unlock()
                continuation.resume()
            } else {
                stopWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func finishStopOnQueue() {
        Darwin.close(fileDescriptor)
        lock.lock()
        stopCompleted = true
        consumerTask = nil
        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: false)
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}
