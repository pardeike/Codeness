import AppKit
import CodenessCore
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class CodenessApplicationModel {
    private static let promptDefaultsKey = "ActivityPromptDefaults"
    private static let repositoryModelDefaultsKey = "RepositoryModelDefaults"
    private static let separatesRunTranscriptsKey = "SeparatesRunTranscripts"
    private static let transcriptVisibilityKey = "TranscriptVisibility"
    private static let customWorkflowTemplatesKey = "CustomWorkflowTemplates"
    private static let defaultWorkflowTemplateIDKey = "DefaultWorkflowTemplateID"
    private static let claudeExecutablePathKey = "ClaudeExecutablePath"
    private static let appServerLogger = Logger(subsystem: "ap.codeness", category: "CodexAppServer")
    private static let appServerCleanupFailure =
        "Codeness could not verify that every Codex App Server and MCP process stopped. Restart Codeness before starting or restarting Codex."
    private static let claudeRestartCleanupFailure =
        "Codeness could not verify that every Claude and MCP process stopped. Starting a replacement is blocked to prevent overlapping orphan processes. Try restarting Claude again; if it still fails, end the remaining Claude process in Activity Monitor first."
    private static let providerQuitCleanupFailure =
        "Codeness could not verify that every Claude and MCP process stopped, so Quit was canceled to avoid leaving an orphan. Try Quit again; if it still fails, end the remaining Claude process in Activity Monitor and quit again."
    private static let probeQuitCleanupFailure =
        "Codeness could not verify that every executable-check process stopped, so Quit was canceled to avoid leaving an orphan. Try Quit again."
    private static let providerLaunchDrainFailure =
        "Codeness paused new provider work, but an already-admitted launch did not finish within the bounded restart window. The current provider was left running and new launches remain paused. Retry after the active work settles."

    private struct LifecycleLease: Equatable {
        let identifier: UUID
        let generation: UInt64
    }

    private struct PendingProviderRestart {
        let identifier: UUID
        let task: Task<Bool, Never>
    }

    private enum ProviderRestartOutcome {
        case succeeded
        case oldProviderUntouched
        case restoredCoherently
        case failedClosed

        var succeeded: Bool {
            if case .succeeded = self { return true }
            return false
        }
    }

    enum ServerState: Equatable {
        case starting
        case ready(String)
        case failed(String)
        case stopped

        var label: String {
            switch self {
            case .starting: "Starting Codex App Server…"
            case .ready(let version): version
            case .failed(let detail): "Codex unavailable: \(detail)"
            case .stopped: "Codex App Server stopped"
            }
        }
    }

    enum ProviderState: Equatable {
        case starting
        case ready(String)
        case failed(String)
        case stopped

        var label: String {
            switch self {
            case .starting: "Starting…"
            case .ready(let version): version
            case .failed(let detail): "Unavailable: \(detail)"
            case .stopped: "Stopped"
            }
        }

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    private(set) var serverState: ServerState = .starting
    private(set) var models: [CodexModel] = []
    private(set) var coordinators: [String: RepositoryCoordinator] = [:]
    private(set) var currentExecutablePath = ""
    private(set) var configuredExecutablePath: String
    private(set) var claudeState: ProviderState = .starting
    private(set) var currentClaudeExecutablePath = ""
    private(set) var configuredClaudeExecutablePath: String
    private(set) var providerCatalog: AgentProviderCatalog
    private(set) var claudeModels: [AgentModelDescriptor]
    private(set) var builtInWorkflowCatalog: WorkflowCatalog
    private(set) var workflowCatalog: WorkflowCatalog
    private(set) var promptDefaults: ActivityPrompts
    private(set) var repositoryModelDefaults: RepositoryModelDefaults
    private(set) var separatesRunTranscripts: Bool
    private(set) var transcriptVisibility: TranscriptVisibility
    private(set) var pendingProviderRestarts: Set<AgentProviderID> = []
    private(set) var retainedProviderLaunchFences: Set<AgentProviderID> = []
    var applicationError: String?

    @ObservationIgnored private let appServer: CodexAppServerClient
    @ObservationIgnored private let router: any HandoffRouting
    @ObservationIgnored private let store: WorkspaceStore
    @ObservationIgnored private let resolver: WorkspaceResolver
    @ObservationIgnored private let codexProvider: CodexAgentProvider
    @ObservationIgnored private var claudeProvider: (any AgentProviding)?
    @ObservationIgnored private let agentProviders: AgentProviderRegistry
    @ObservationIgnored private let workflowRouter: AgentWorkflowHandoffRouter
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var intentionalShutdown = false
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored private var shutdownFenced = false
    @ObservationIgnored private var activeLifecycleLease: LifecycleLease?
    @ObservationIgnored private var activeLifecycleCancellation: (() -> Void)?
    @ObservationIgnored private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var providerRestartTasks: [
        AgentProviderID: PendingProviderRestart
    ] = [:]
    @ObservationIgnored private var retainedProviderLaunchFenceTokens: [
        AgentProviderID: AgentProviderRegistry.LaunchFence
    ] = [:]
    @ObservationIgnored private var retainedEventRoutingPauses: [
        AgentProviderID: AppServerEventRoutingPause
    ] = [:]
    @ObservationIgnored private let appServerShutdown: @Sendable () async -> Bool
    @ObservationIgnored private let codexShutdownAndVerify: @Sendable () async -> Bool
    @ObservationIgnored private let testingDocumentPreparationResult: Bool?
    @ObservationIgnored private let providerLaunchDrainTimeout: Duration

    init(
        appServer: CodexAppServerClient = CodexAppServerClient(),
        router: any HandoffRouting = HandoffRouter(),
        store: WorkspaceStore = WorkspaceStore(),
        resolver: WorkspaceResolver = WorkspaceResolver(),
        testingCodexProvider: CodexAgentProvider? = nil,
        initialClaudeProvider: (any AgentProviding)? = nil,
        testingAppServerShutdown: (@Sendable () async -> Bool)? = nil,
        testingCodexShutdownAndVerify: (@Sendable () async -> Bool)? = nil,
        testingDocumentPreparationResult: Bool? = nil,
        testingProviderLaunchDrainTimeout: Duration = .seconds(2)
    ) {
        let loadedProviderCatalog: AgentProviderCatalog
        let loadedWorkflowCatalog: WorkflowCatalog
        var catalogError: String?
        do {
            loadedProviderCatalog = try WorkflowCatalogLoader.loadBundledProviderCatalog()
        } catch {
            loadedProviderCatalog = AgentProviderCatalog(schemaVersion: 1, providers: [])
            catalogError = error.localizedDescription
        }
        do {
            loadedWorkflowCatalog = try WorkflowCatalogLoader.loadBundledWorkflowCatalog()
        } catch {
            loadedWorkflowCatalog = WorkflowCatalog(
                schemaVersion: 1,
                defaultTemplateID: "",
                templates: []
            )
            catalogError = [catalogError, error.localizedDescription]
                .compactMap { $0 }
                .joined(separator: "\n")
        }

        self.appServer = appServer
        appServerShutdown = testingAppServerShutdown ?? { await appServer.shutdown() }
        self.router = router
        self.store = store
        self.resolver = resolver
        providerCatalog = loadedProviderCatalog
        claudeModels = loadedProviderCatalog.provider(.claude)?.knownModels ?? []
        builtInWorkflowCatalog = loadedWorkflowCatalog
        let codexProvider = testingCodexProvider
            ?? CodexAgentProvider(appServer: appServer)
        self.codexProvider = codexProvider
        codexShutdownAndVerify = testingCodexShutdownAndVerify
            ?? { await codexProvider.shutdownAndVerify() }
        self.testingDocumentPreparationResult = testingDocumentPreparationResult
        providerLaunchDrainTimeout = max(.zero, testingProviderLaunchDrainTimeout)
        var providers: [any AgentProviding] = [codexProvider]
        if let initialClaudeProvider {
            providers.append(initialClaudeProvider)
        }
        let agentProviders = AgentProviderRegistry(providers: providers)
        self.agentProviders = agentProviders
        claudeProvider = initialClaudeProvider
        workflowRouter = AgentWorkflowHandoffRouter(providers: agentProviders)
        configuredExecutablePath = UserDefaults.standard.string(forKey: "CodexExecutablePath") ?? ""
        configuredClaudeExecutablePath = UserDefaults.standard.string(
            forKey: Self.claudeExecutablePathKey
        ) ?? ""
        let customTemplates: [WorkflowTemplate]
        if let data = UserDefaults.standard.data(forKey: Self.customWorkflowTemplatesKey),
           let saved = try? JSONDecoder().decode([WorkflowTemplate].self, from: data) {
            customTemplates = saved.filter { $0.validationMessage == nil }
        } else {
            customTemplates = []
        }
        let mergedTemplates = Self.mergedWorkflowTemplates(
            builtIns: loadedWorkflowCatalog.templates,
            custom: customTemplates
        )
        let savedDefaultID = UserDefaults.standard.string(
            forKey: Self.defaultWorkflowTemplateIDKey
        )
        let defaultID = savedDefaultID.flatMap { id in
            mergedTemplates.contains(where: { $0.id == id }) ? id : nil
        } ?? loadedWorkflowCatalog.defaultTemplateID
        workflowCatalog = WorkflowCatalog(
            schemaVersion: 1,
            defaultTemplateID: defaultID,
            templates: mergedTemplates
        )
        if let data = UserDefaults.standard.data(forKey: Self.promptDefaultsKey),
           let savedPrompts = try? JSONDecoder().decode(ActivityPrompts.self, from: data),
           savedPrompts.validationMessage == nil {
            promptDefaults = savedPrompts
        } else {
            promptDefaults = .builtInDefaults
        }
        if let data = UserDefaults.standard.data(forKey: Self.repositoryModelDefaultsKey),
           let savedDefaults = try? JSONDecoder().decode(RepositoryModelDefaults.self, from: data) {
            repositoryModelDefaults = savedDefaults
        } else {
            repositoryModelDefaults = .builtInDefaults
        }
        if UserDefaults.standard.object(forKey: Self.separatesRunTranscriptsKey) == nil {
            separatesRunTranscripts = true
        } else {
            separatesRunTranscripts = UserDefaults.standard.bool(forKey: Self.separatesRunTranscriptsKey)
        }
        if let data = UserDefaults.standard.data(forKey: Self.transcriptVisibilityKey),
           let savedVisibility = try? JSONDecoder().decode(TranscriptVisibility.self, from: data) {
            transcriptVisibility = savedVisibility
        } else {
            transcriptVisibility = .recommended
        }
        applicationError = catalogError
    }

    var isReady: Bool {
        if case .ready = serverState { return true }
        return false
    }

    func isProviderReady(_ providerID: AgentProviderID) -> Bool {
        switch providerID {
        case .codex:
            return isReady
        case .claude:
            return claudeState.isReady
        default:
            return false
        }
    }

    func canRun(_ workflow: WorkflowTemplate) -> Bool {
        let providerIDs = Set(
            workflow.steps.map(\.target.providerID)
                + [workflow.coordinator.target.providerID]
        )
        return !providerIDs.isEmpty
            && providerIDs.allSatisfy(isProviderReady)
            && providerIDs.isDisjoint(with: pendingProviderRestarts)
            && providerIDs.isDisjoint(with: retainedProviderLaunchFences)
            && workflowCompatibilityMessage(workflow) == nil
    }

    func isProviderRestartPending(_ providerID: AgentProviderID) -> Bool {
        pendingProviderRestarts.contains(providerID)
    }

    func agentProviderRegistryForTesting() -> AgentProviderRegistry {
        agentProviders
    }

    func workflowCompatibilityMessage(_ workflow: WorkflowTemplate) -> String? {
        for step in workflow.steps {
            if let message = targetCompatibilityMessage(step.target) {
                return "\(step.name): \(message)"
            }
        }
        if let message = targetCompatibilityMessage(workflow.coordinator.target) {
            return "Coordinator: \(message)"
        }
        return nil
    }

    func targetCompatibilityMessage(_ target: AgentTarget) -> String? {
        guard let provider = providerCatalog.provider(target.providerID) else {
            return "The \(target.providerID.rawValue) provider is not supported."
        }
        let model = models(for: target.providerID).first { $0.id == target.model }
        if let effort = target.options.effort?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !effort.isEmpty,
           let model,
           !model.supportedEfforts.contains(effort) {
            return "\(model.displayName) does not advertise \(effort) effort."
        }
        if target.options.mode == .plan,
           !(model?.supportsPlanMode ?? provider.supportsPlanMode) {
            return "\(provider.displayName) does not advertise Plan mode for \(target.model)."
        }
        if target.options.speed == .fast,
           target.providerID == .codex,
           model == nil {
            return "Codex Fast requires a model advertised by the running Codex CLI."
        }
        if target.options.speed == .fast,
           !(model?.supportsFastMode ?? provider.supportsFastMode) {
            return "\(provider.displayName) does not advertise Fast mode for \(target.model)."
        }
        return nil
    }

    func models(for providerID: AgentProviderID) -> [AgentModelDescriptor] {
        switch providerID {
        case .codex:
            return models.map(AgentModelDescriptor.init(codexModel:))
        case .claude:
            return claudeModels
        default:
            return providerCatalog.provider(providerID)?.knownModels ?? []
        }
    }

    func providerName(_ providerID: AgentProviderID) -> String {
        providerCatalog.provider(providerID)?.displayName ?? providerID.rawValue.capitalized
    }

    func isExecutableConfigurationActive(_ configuredPath: String) -> Bool {
        guard isReady,
              let resolved = try? CodexExecutableLocator.resolve(configuredPath: configuredPath) else {
            return false
        }
        let expectedPath = resolved.resolvingSymlinksInPath().standardizedFileURL.path
        let runningPath = URL(fileURLWithPath: currentExecutablePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        return expectedPath == runningPath
    }

    func isClaudeExecutableConfigurationActive(_ configuredPath: String) -> Bool {
        guard claudeState.isReady,
              let descriptor = providerCatalog.provider(.claude),
              let resolved = try? AgentExecutableLocator.resolve(
                configuredPath: configuredPath,
                descriptor: descriptor
              ) else {
            return false
        }
        let expectedPath = resolved.resolvingSymlinksInPath().standardizedFileURL.path
        let runningPath = URL(fileURLWithPath: currentClaudeExecutablePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        return expectedPath == runningPath
    }

    func bootstrap() async {
        guard !didBootstrap,
              let lease = await acquireLifecycleLease() else { return }
        // The event consumer shares this lifecycle lease and therefore cannot
        // route startup notifications until bootstrap finishes. Use bounded,
        // nonblocking admission during that deliberate pause so initialization
        // responses can never deadlock behind a saturated notification backlog.
        let eventRoutingPause = await appServer.pauseEventRouting()
        let operation = Task { @MainActor [weak self] in
            await self?.performBootstrap(lease: lease)
        }
        activeLifecycleCancellation = { operation.cancel() }
        await operation.value
        await appServer.resumeEventRouting(eventRoutingPause)
        finishLifecycleOperation(lease)
    }

    private func performBootstrap(lease: LifecycleLease) async {
        guard lifecycleIsCurrent(lease) else { return }
        didBootstrap = true
        let catalogError = applicationError
        let stream = await appServer.events()
        guard lifecycleIsCurrent(lease) else { return }
        eventTask = Task { [weak self] in
            for await transportEvent in stream {
                guard let self else { return }
                await self.route(transportEvent)
            }
        }
        await startServer(configuredPath: configuredExecutablePath, lease: lease)
        guard lifecycleIsCurrent(lease) else { return }
        await startClaude(configuredPath: configuredClaudeExecutablePath, lease: lease)
        guard lifecycleIsCurrent(lease) else { return }
        if catalogError == nil, !isReady, !claudeState.isReady {
            applicationError = [
                "No supported agent CLI is currently available.",
                "Codex: \(serverState.label)",
                "Claude: \(claudeState.label)"
            ].joined(separator: "\n")
        }
    }

    func coordinator(for canonicalPath: String) -> RepositoryCoordinator {
        if let coordinator = coordinators[canonicalPath] {
            return coordinator
        }
        let initialSettings = repositoryModelDefaults.applying(to: RepositorySettings())
        let coordinator = RepositoryCoordinator(
            canonicalPath: canonicalPath,
            appServer: appServer,
            router: router,
            store: store,
            initialSettings: initialSettings,
            agentProviders: agentProviders,
            workflowRouter: workflowRouter
        )
        coordinators[canonicalPath] = coordinator
        return coordinator
    }

    func canonicalWorkspace(for selectedURL: URL) async throws -> URL {
        try await resolver.canonicalWorkspace(for: selectedURL)
    }

    func storedWindowFrame(for canonicalPath: String) async -> StoredWindowFrame? {
        guard let viewState = try? await store.loadViewState(canonicalPath: canonicalPath) else {
            return nil
        }
        return viewState.windowFrame
    }

    func storedWorkspacePreview(canonicalPath: String) async throws -> RepositoryRecord? {
        try await store.storedWorkspacePreview(canonicalPath: canonicalPath)
    }

    func inspectWorkspaceTransfer(at sourceURL: URL) async throws -> WorkspaceTransferPreview {
        try await store.inspectWorkspaceTransfer(at: sourceURL)
    }

    @discardableResult
    func exportWorkspace(canonicalPath: String, to destinationURL: URL) async throws
        -> WorkspaceTransferManifest {
        try await store.exportWorkspace(
            canonicalPath: canonicalPath,
            sourceAppVersion: WorkspaceTransferBundleInfo.version,
            sourceAppBuild: WorkspaceTransferBundleInfo.build,
            to: destinationURL
        )
    }

    func importWorkspace(
        from sourceURL: URL,
        to canonicalPath: String,
        replacingExisting: Bool
    ) async throws -> WorkspaceImportResult {
        try await store.importWorkspace(
            from: sourceURL,
            to: canonicalPath,
            sourceAppVersion: WorkspaceTransferBundleInfo.version,
            sourceAppBuild: WorkspaceTransferBundleInfo.build,
            replacingExisting: replacingExisting
        )
    }

    func releaseCoordinator(_ coordinator: RepositoryCoordinator) {
        let path = coordinator.record.canonicalPath
        guard coordinators[path] === coordinator else { return }
        coordinators.removeValue(forKey: path)
    }

    var activeCoordinators: [RepositoryCoordinator] {
        coordinators.values
            .filter(\.requiresCloseConfirmation)
            .sorted { $0.repositoryName.localizedStandardCompare($1.repositoryName) == .orderedAscending }
    }

    var allCoordinators: [RepositoryCoordinator] {
        coordinators.values.sorted {
            $0.repositoryName.localizedStandardCompare($1.repositoryName) == .orderedAscending
        }
    }

    func loadOpenDocumentPaths() async throws -> [String] {
        let storedPaths = try await store.loadOpenDocumentPaths()
        if let legacyPaths = UserDefaults.standard.stringArray(forKey: "OpenRepositoryDocumentPaths") {
            if storedPaths.isEmpty, !legacyPaths.isEmpty {
                try await store.saveOpenDocumentPaths(legacyPaths)
                UserDefaults.standard.removeObject(forKey: "OpenRepositoryDocumentPaths")
                return legacyPaths
            }
            UserDefaults.standard.removeObject(forKey: "OpenRepositoryDocumentPaths")
        }
        return storedPaths
    }

    func saveOpenDocumentPaths(_ paths: [String]) async throws {
        try await store.saveOpenDocumentPaths(paths)
        UserDefaults.standard.removeObject(forKey: "OpenRepositoryDocumentPaths")
    }

    func loadRecentRepositoryPaths() async throws -> [String] {
        try await store.loadRecentRepositoryPaths()
    }

    func saveRecentRepositoryPaths(_ paths: [String]) async throws {
        try await store.saveRecentRepositoryPaths(paths)
    }

    func resumeAfterSystemTerminationIfNeeded(_ coordinator: RepositoryCoordinator) async {
        guard coordinator.isLoaded else { return }
        let shouldResume = await coordinator.consumeResumeAfterSystemTerminationRequest()
        guard shouldResume else { return }
        if let workflow = coordinator.record.activity?.workflow {
            guard canRun(workflow) else { return }
        } else {
            guard isReady else { return }
        }
        await coordinator.resume()
    }

    @discardableResult
    func restartServer(configuredPath: String) async -> Bool {
        if let pending = providerRestartTasks[.codex] {
            return await pending.task.value
        }
        let identifier = UUID()
        // This observable UI gate is established synchronously, before the
        // first suspension in this call. Registry admission below is the
        // authoritative enforcement boundary for launches that bypass UI.
        pendingProviderRestarts.insert(.codex)
        let task = Task { @MainActor [weak self] in
            await self?.executeRestartServer(configuredPath: configuredPath) ?? false
        }
        providerRestartTasks[.codex] = PendingProviderRestart(
            identifier: identifier,
            task: task
        )
        let result = await task.value
        if providerRestartTasks[.codex]?.identifier == identifier {
            providerRestartTasks.removeValue(forKey: .codex)
            pendingProviderRestarts.remove(.codex)
        }
        return result
    }

    private func executeRestartServer(configuredPath: String) async -> Bool {
        guard let lease = await acquireLifecycleLease() else {
            applicationError = "Codeness is shutting down; Codex cannot be restarted."
            return false
        }
        let operation = Task { @MainActor [weak self] in
            await self?.performRestartServer(
                configuredPath: configuredPath,
                lease: lease
            ) ?? false
        }
        activeLifecycleCancellation = { operation.cancel() }
        let result = await operation.value
        finishLifecycleOperation(lease)
        return result
    }

    private func performRestartServer(
        configuredPath: String,
        lease: LifecycleLease
    ) async -> Bool {
        guard lifecycleIsCurrent(lease) else { return false }
        guard !coordinators.values.contains(where: {
            $0.hasActiveWork(for: .codex)
        }) else {
            applicationError = "Finish active Codex turns or coordinator work before restarting App Server."
            return false
        }
        let launchFence: AgentProviderRegistry.LaunchFence
        let acquiredFreshFence: Bool
        if let retainedFence = retainedProviderLaunchFenceTokens[.codex] {
            launchFence = retainedFence
            acquiredFreshFence = false
        } else {
            do {
                launchFence = try await agentProviders.fenceLaunches(for: .codex)
                acquiredFreshFence = true
            } catch {
                guard lifecycleIsCurrent(lease) else { return false }
                applicationError = error.localizedDescription
                return false
            }
        }
        guard await agentProviders.waitForLaunchesToDrain(
            launchFence,
            timeout: providerLaunchDrainTimeout
        ) else {
            retainedProviderLaunchFenceTokens[.codex] = launchFence
            retainedProviderLaunchFences.insert(.codex)
            if lifecycleIsCurrent(lease) {
                applicationError = Self.providerLaunchDrainFailure
                serverState = .failed(Self.providerLaunchDrainFailure)
            }
            return false
        }
        let outcome = await performRestartServerWhileLaunchesFenced(
            configuredPath: configuredPath,
            lease: lease
        )
        await finishProviderRestart(
            providerID: .codex,
            outcome: outcome,
            launchFence: launchFence,
            acquiredFreshFence: acquiredFreshFence,
            lifecycleRemainsCurrent: lifecycleIsCurrent(lease)
        )
        return outcome.succeeded
    }

    private func performRestartServerWhileLaunchesFenced(
        configuredPath: String,
        lease: LifecycleLease
    ) async -> ProviderRestartOutcome {
        guard lifecycleIsCurrent(lease) else { return .oldProviderUntouched }
        guard !coordinators.values.contains(where: {
            $0.hasActiveWork(for: .codex)
        }) else {
            applicationError = "Finish active Codex turns or coordinator work before restarting App Server."
            return .oldProviderUntouched
        }

        let configuredPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable: URL
        let version: String
        do {
            try await CodexExecutableLocator.prepareProcessEnvironment()
            try requireCurrentLifecycle(lease)
            executable = try CodexExecutableLocator.resolve(configuredPath: configuredPath)
            version = try await CodexExecutableLocator.verify(executable)
            try requireCurrentLifecycle(lease)
            if let descriptor = providerCatalog.provider(.codex) {
                try AgentExecutableLocator.validateVersion(version, descriptor: descriptor)
            }
        } catch {
            guard lifecycleIsCurrent(lease) else { return .oldProviderUntouched }
            applicationError = error.localizedDescription
            return .oldProviderUntouched
        }

        let previousConfiguredPath = UserDefaults.standard.string(forKey: "CodexExecutablePath") ?? ""
        guard lifecycleIsCurrent(lease) else { return .oldProviderUntouched }
        if retainedEventRoutingPauses[.codex] == nil {
            retainedEventRoutingPauses[.codex] = await appServer.pauseEventRouting()
        }
        guard lifecycleIsCurrent(lease) else { return .failedClosed }
        intentionalShutdown = true
        let oldServerStopped = await codexShutdownAndVerify()
        guard oldServerStopped else {
            if lifecycleIsCurrent(lease) {
                applicationError = Self.appServerCleanupFailure
                serverState = .failed(Self.appServerCleanupFailure)
                intentionalShutdown = false
            }
            return .failedClosed
        }
        guard lifecycleIsCurrent(lease) else { return .failedClosed }
        for coordinator in coordinators.values {
            await coordinator.appServerRestarted()
            guard lifecycleIsCurrent(lease) else { return .failedClosed }
        }
        do {
            try await activateServer(
                executable: executable,
                version: version,
                lease: lease
            )
            try requireCurrentLifecycle(lease)
            UserDefaults.standard.set(configuredPath, forKey: "CodexExecutablePath")
            configuredExecutablePath = configuredPath
            intentionalShutdown = false
            return .succeeded
        } catch {
            guard lifecycleIsCurrent(lease) else { return .failedClosed }
            let requestedError = error.localizedDescription
            var restoredPreviousServer = false
            if let previousExecutable = try? CodexExecutableLocator.resolve(configuredPath: previousConfiguredPath),
               let previousVersion = try? await CodexExecutableLocator.verify(previousExecutable),
               lifecycleIsCurrent(lease),
               Self.isSupportedCodexVersion(previousVersion, catalog: providerCatalog) {
                do {
                    try await activateServer(
                        executable: previousExecutable,
                        version: previousVersion,
                        lease: lease
                    )
                    try requireCurrentLifecycle(lease)
                    restoredPreviousServer = true
                } catch {
                    // The requested error remains the actionable settings failure.
                }
            }
            guard lifecycleIsCurrent(lease) else { return .failedClosed }
            if !restoredPreviousServer {
                currentExecutablePath = ""
                models = []
                serverState = .failed(requestedError)
            }
            applicationError = "Could not restart Codex with the requested executable: \(requestedError)"
            intentionalShutdown = false
            return restoredPreviousServer ? .restoredCoherently : .failedClosed
        }
    }

    @discardableResult
    func restartClaude(configuredPath: String) async -> Bool {
        if let pending = providerRestartTasks[.claude] {
            return await pending.task.value
        }
        let identifier = UUID()
        pendingProviderRestarts.insert(.claude)
        let task = Task { @MainActor [weak self] in
            await self?.executeRestartClaude(configuredPath: configuredPath) ?? false
        }
        providerRestartTasks[.claude] = PendingProviderRestart(
            identifier: identifier,
            task: task
        )
        let result = await task.value
        if providerRestartTasks[.claude]?.identifier == identifier {
            providerRestartTasks.removeValue(forKey: .claude)
            pendingProviderRestarts.remove(.claude)
        }
        return result
    }

    private func executeRestartClaude(configuredPath: String) async -> Bool {
        guard let lease = await acquireLifecycleLease() else {
            applicationError = "Codeness is shutting down; Claude cannot be restarted."
            return false
        }
        let operation = Task { @MainActor [weak self] in
            await self?.performRestartClaude(
                configuredPath: configuredPath,
                lease: lease
            ) ?? false
        }
        activeLifecycleCancellation = { operation.cancel() }
        let result = await operation.value
        finishLifecycleOperation(lease)
        return result
    }

    private func performRestartClaude(
        configuredPath: String,
        lease: LifecycleLease
    ) async -> Bool {
        guard lifecycleIsCurrent(lease) else { return false }
        guard !coordinators.values.contains(where: {
            $0.hasActiveWork(for: .claude)
        }) else {
            applicationError = "Finish active Claude turns or coordinator work before restarting Claude."
            return false
        }
        let launchFence: AgentProviderRegistry.LaunchFence
        let acquiredFreshFence: Bool
        if let retainedFence = retainedProviderLaunchFenceTokens[.claude] {
            launchFence = retainedFence
            acquiredFreshFence = false
        } else {
            do {
                launchFence = try await agentProviders.fenceLaunches(for: .claude)
                acquiredFreshFence = true
            } catch {
                guard lifecycleIsCurrent(lease) else { return false }
                applicationError = error.localizedDescription
                return false
            }
        }
        guard await agentProviders.waitForLaunchesToDrain(
            launchFence,
            timeout: providerLaunchDrainTimeout
        ) else {
            retainedProviderLaunchFenceTokens[.claude] = launchFence
            retainedProviderLaunchFences.insert(.claude)
            if lifecycleIsCurrent(lease) {
                applicationError = Self.providerLaunchDrainFailure
                claudeState = .failed(Self.providerLaunchDrainFailure)
            }
            return false
        }
        let outcome = await performRestartClaudeWhileLaunchesFenced(
            configuredPath: configuredPath,
            lease: lease
        )
        await finishProviderRestart(
            providerID: .claude,
            outcome: outcome,
            launchFence: launchFence,
            acquiredFreshFence: acquiredFreshFence,
            lifecycleRemainsCurrent: lifecycleIsCurrent(lease)
        )
        return outcome.succeeded
    }

    private func performRestartClaudeWhileLaunchesFenced(
        configuredPath: String,
        lease: LifecycleLease
    ) async -> ProviderRestartOutcome {
        guard lifecycleIsCurrent(lease) else { return .oldProviderUntouched }
        guard !coordinators.values.contains(where: {
            $0.hasActiveWork(for: .claude)
        }) else {
            applicationError = "Finish active Claude turns or coordinator work before restarting Claude."
            return .oldProviderUntouched
        }
        guard let descriptor = providerCatalog.provider(.claude) else {
            applicationError = "The Claude provider is missing from AgentProviders.json."
            return .oldProviderUntouched
        }
        let cleanPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousPath = UserDefaults.standard.string(forKey: Self.claudeExecutablePathKey) ?? ""
        let executable: URL
        let version: String
        do {
            // Validate the replacement completely before pausing App Server
            // routing or disturbing the healthy provider. A bad settings path
            // is an ordinary refusal, not a cleanup failure.
            try await CodexExecutableLocator.prepareProcessEnvironment()
            try requireCurrentLifecycle(lease)
            executable = try AgentExecutableLocator.resolve(
                configuredPath: cleanPath,
                descriptor: descriptor
            )
            version = try await AgentExecutableLocator.verify(
                executable,
                descriptor: descriptor
            )
            try requireCurrentLifecycle(lease)
        } catch {
            guard lifecycleIsCurrent(lease) else { return .oldProviderUntouched }
            applicationError = error.localizedDescription
            return .oldProviderUntouched
        }

        let oldProviderStopped = await claudeProvider?.shutdownAndVerify() ?? true
        guard oldProviderStopped else {
            if lifecycleIsCurrent(lease) {
                applicationError = Self.claudeRestartCleanupFailure
                claudeState = .failed(Self.claudeRestartCleanupFailure)
            }
            return .failedClosed
        }
        guard lifecycleIsCurrent(lease) else { return .failedClosed }
        for coordinator in coordinators.values {
            coordinator.providerRestarted(.claude)
        }
        await agentProviders.unregister(.claude)
        guard lifecycleIsCurrent(lease) else { return .failedClosed }
        claudeProvider = nil
        do {
            try await activateClaude(
                executable: executable,
                version: version,
                lease: lease
            )
            try requireCurrentLifecycle(lease)
            UserDefaults.standard.set(cleanPath, forKey: Self.claudeExecutablePathKey)
            configuredClaudeExecutablePath = cleanPath
            return .succeeded
        } catch {
            guard lifecycleIsCurrent(lease) else { return .failedClosed }
            let requestedError = error.localizedDescription
            var restoredPreviousProvider = false
            if let previousExecutable = try? AgentExecutableLocator.resolve(
                configuredPath: previousPath,
                descriptor: descriptor
            ), let previousVersion = try? await AgentExecutableLocator.verify(
                previousExecutable,
                descriptor: descriptor
            ), lifecycleIsCurrent(lease) {
                do {
                    try await activateClaude(
                        executable: previousExecutable,
                        version: previousVersion,
                        lease: lease
                    )
                    try requireCurrentLifecycle(lease)
                    restoredPreviousProvider = true
                } catch {
                    // Keep the requested failure as the actionable settings error.
                }
            } else {
                currentClaudeExecutablePath = ""
                claudeState = .failed(requestedError)
            }
            guard lifecycleIsCurrent(lease) else { return .failedClosed }
            if !restoredPreviousProvider {
                currentClaudeExecutablePath = ""
                claudeState = .failed(requestedError)
            }
            applicationError = "Could not restart Claude with the requested executable: \(requestedError)"
            return restoredPreviousProvider ? .restoredCoherently : .failedClosed
        }
    }

    private func finishProviderRestart(
        providerID: AgentProviderID,
        outcome: ProviderRestartOutcome,
        launchFence: AgentProviderRegistry.LaunchFence,
        acquiredFreshFence: Bool,
        lifecycleRemainsCurrent: Bool
    ) async {
        let mayResume: Bool
        switch outcome {
        case .succeeded, .restoredCoherently:
            mayResume = true
        case .oldProviderUntouched:
            // An early refusal proves coherence only when this attempt created
            // the fence. A fence retained from a prior failed cleanup remains
            // authoritative until a later activation or rollback succeeds.
            mayResume = acquiredFreshFence && lifecycleRemainsCurrent
        case .failedClosed:
            mayResume = false
        }
        if mayResume {
            if let routingPause = retainedEventRoutingPauses.removeValue(forKey: providerID) {
                // Reopen App Server event delivery before provider launches so
                // a newly admitted run cannot race a still-paused consumer.
                await appServer.resumeEventRouting(routingPause)
            }
            await agentProviders.resumeLaunches(launchFence)
            retainedProviderLaunchFenceTokens.removeValue(forKey: providerID)
            retainedProviderLaunchFences.remove(providerID)
        } else {
            retainedProviderLaunchFenceTokens[providerID] = launchFence
            retainedProviderLaunchFences.insert(providerID)
        }
    }

    func shutdown(prepareDocuments: Bool = true) async -> Bool {
        // Fence launches synchronously before the first suspension. Incrementing
        // the generation makes every in-flight lease permanently stale, even if
        // this Quit is later canceled and the gate reopens.
        lifecycleGeneration &+= 1
        shutdownFenced = true
        activeLifecycleCancellation?()
        intentionalShutdown = true
        if prepareDocuments {
            if testingDocumentPreparationResult == false {
                return await cancelShutdownAfterPreparationFailure(
                    "Could not prepare every repository for Quit."
                )
            }
            for coordinator in coordinators.values {
                let result = await coordinator.prepareForClose(strategy: .immediate)
                guard case .ready = result else {
                    let detail: String
                    if case .failed(let message) = result {
                        detail = "\(coordinator.repositoryName): \(message)"
                    } else {
                        detail = "\(coordinator.repositoryName): Could not prepare this repository for Quit."
                    }
                    return await cancelShutdownAfterPreparationFailure(detail)
                }
            }
        }

        let probesStopped = await OwnedSubprocessSupervisor.shutdownAll()
        activeLifecycleCancellation?()
        await waitForLifecycleOperationToFinish()

        var providerReport = await agentProviders.shutdownReport()
        let appServerStopped = await appServerShutdown()
        if providerReport[.codex] == false, appServerStopped {
            await codexProvider.appServerCleanupConfirmed()
            providerReport[.codex] = await codexProvider.shutdownAndVerify()
        }
        let codexStopped = (providerReport[.codex] ?? true) && appServerStopped
        let claudeStopped = providerReport[.claude] ?? true
        let providersStopped = providerReport.values.allSatisfy { $0 }
        guard providersStopped, appServerStopped, probesStopped else {
            var failures: [String] = []
            if !claudeStopped {
                failures.append(Self.providerQuitCleanupFailure)
                claudeState = .failed(Self.providerQuitCleanupFailure)
            } else {
                claudeState = .stopped
                currentClaudeExecutablePath = ""
            }
            if !codexStopped {
                failures.append(Self.appServerCleanupFailure)
                serverState = .failed(Self.appServerCleanupFailure)
            } else {
                serverState = .stopped
                currentExecutablePath = ""
                models = []
                await codexProvider.updateModels([])
                for coordinator in coordinators.values {
                    await coordinator.appServerRestarted()
                }
            }
            if !probesStopped {
                failures.append(Self.probeQuitCleanupFailure)
            }
            applicationError = failures.joined(separator: "\n")
            var resumedProbeLaunching = false
            if probesStopped {
                resumedProbeLaunching = await OwnedSubprocessSupervisor.resumeLaunching()
            }
            if !resumedProbeLaunching {
                if !failures.contains(Self.probeQuitCleanupFailure) {
                    failures.append(Self.probeQuitCleanupFailure)
                    applicationError = failures.joined(separator: "\n")
                }
            } else {
                shutdownFenced = false
            }
            intentionalShutdown = false
            return false
        }
        eventTask?.cancel()
        eventTask = nil
        serverState = .stopped
        claudeState = .stopped
        return true
    }

    func clearError() {
        applicationError = nil
    }

    func updatePromptDefaults(_ prompts: ActivityPrompts) {
        if let validationMessage = prompts.validationMessage {
            applicationError = validationMessage
            return
        }
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(prompts), forKey: Self.promptDefaultsKey)
            promptDefaults = prompts
        } catch {
            applicationError = "Could not save prompt defaults: \(error.localizedDescription)"
        }
    }

    func updateRepositoryModelDefaults(_ defaults: RepositoryModelDefaults) {
        do {
            UserDefaults.standard.set(
                try JSONEncoder().encode(defaults),
                forKey: Self.repositoryModelDefaultsKey
            )
            repositoryModelDefaults = defaults
        } catch {
            applicationError = "Could not save model defaults: \(error.localizedDescription)"
        }
    }

    func updateWorkflowCatalog(_ catalog: WorkflowCatalog) {
        guard catalog.schemaVersion == 1,
              !catalog.templates.isEmpty,
              catalog.templates.contains(where: { $0.id == catalog.defaultTemplateID }),
              catalog.templates.allSatisfy({ $0.validationMessage == nil }) else {
            applicationError = "The workflows are invalid."
            return
        }
        let custom = catalog.templates.filter { template in
            builtInWorkflowCatalog.template(id: template.id) != template
        }
        do {
            UserDefaults.standard.set(
                try JSONEncoder().encode(custom),
                forKey: Self.customWorkflowTemplatesKey
            )
            UserDefaults.standard.set(
                catalog.defaultTemplateID,
                forKey: Self.defaultWorkflowTemplateIDKey
            )
            workflowCatalog = WorkflowCatalog(
                schemaVersion: 1,
                defaultTemplateID: catalog.defaultTemplateID,
                templates: Self.mergedWorkflowTemplates(
                    builtIns: builtInWorkflowCatalog.templates,
                    custom: custom
                )
            )
        } catch {
            applicationError = "Could not save workflows: \(error.localizedDescription)"
        }
    }

    func restoreBuiltInWorkflowCatalog() {
        UserDefaults.standard.removeObject(forKey: Self.customWorkflowTemplatesKey)
        UserDefaults.standard.removeObject(forKey: Self.defaultWorkflowTemplateIDKey)
        workflowCatalog = builtInWorkflowCatalog
    }

    func setSeparatesRunTranscripts(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.separatesRunTranscriptsKey)
        separatesRunTranscripts = enabled
    }

    func setTranscriptVisibility(_ visibility: TranscriptVisibility) {
        do {
            UserDefaults.standard.set(
                try JSONEncoder().encode(visibility),
                forKey: Self.transcriptVisibilityKey
            )
            transcriptVisibility = visibility
        } catch {
            applicationError = "Could not save transcript visibility: \(error.localizedDescription)"
        }
    }

    private func startServer(
        configuredPath: String,
        lease: LifecycleLease
    ) async {
        guard lifecycleIsCurrent(lease) else { return }
        serverState = .starting
        do {
            try await CodexExecutableLocator.prepareProcessEnvironment()
            try requireCurrentLifecycle(lease)
            let executable = try CodexExecutableLocator.resolve(configuredPath: configuredPath)
            let version = try await CodexExecutableLocator.verify(executable)
            try requireCurrentLifecycle(lease)
            if let descriptor = providerCatalog.provider(.codex) {
                try AgentExecutableLocator.validateVersion(version, descriptor: descriptor)
            }
            try await activateServer(
                executable: executable,
                version: version,
                lease: lease
            )
        } catch {
            guard lifecycleIsCurrent(lease) else { return }
            serverState = .failed(error.localizedDescription)
        }
    }

    private func startClaude(
        configuredPath: String,
        lease: LifecycleLease
    ) async {
        guard lifecycleIsCurrent(lease) else { return }
        claudeState = .starting
        guard let descriptor = providerCatalog.provider(.claude) else {
            claudeState = .failed("Provider metadata is missing.")
            return
        }
        do {
            try await CodexExecutableLocator.prepareProcessEnvironment()
            try requireCurrentLifecycle(lease)
            let executable = try AgentExecutableLocator.resolve(
                configuredPath: configuredPath,
                descriptor: descriptor
            )
            let version = try await AgentExecutableLocator.verify(
                executable,
                descriptor: descriptor
            )
            try requireCurrentLifecycle(lease)
            try await activateClaude(
                executable: executable,
                version: version,
                lease: lease
            )
        } catch {
            guard lifecycleIsCurrent(lease) else { return }
            currentClaudeExecutablePath = ""
            claudeState = .failed(error.localizedDescription)
        }
    }

    private func activateClaude(
        executable: URL,
        version: String,
        lease: LifecycleLease
    ) async throws {
        try requireCurrentLifecycle(lease)
        let discoveredModels = try await ClaudeExecutableInspector.models(
            executableURL: executable
        )
        try requireCurrentLifecycle(lease)
        let provider = ClaudeAgentProvider(executableURL: executable)
        await agentProviders.register(provider)
        try requireCurrentLifecycle(lease)
        claudeProvider = provider
        claudeModels = discoveredModels
        currentClaudeExecutablePath = executable.path
        claudeState = .ready(version)
    }

    private func activateServer(
        executable: URL,
        version: String,
        lease: LifecycleLease
    ) async throws {
        try requireCurrentLifecycle(lease)
        serverState = .starting
        try await appServer.start(configuration: CodexLaunchConfiguration(executableURL: executable))
        do {
            try requireCurrentLifecycle(lease)
            let availableModels = try await appServer.listModels().filter { !$0.hidden }
            try requireCurrentLifecycle(lease)
            await codexProvider.updateModels(availableModels)
            try requireCurrentLifecycle(lease)
            currentExecutablePath = executable.path
            models = availableModels
            serverState = .ready(version)
        } catch {
            let startupError = error.localizedDescription
            guard await appServer.shutdown() else {
                throw AppServerActivationCleanupError(startupError: startupError)
            }
            throw error
        }
    }

    /// Routes one transport event under the same lifecycle lease used by
    /// bootstrap and settings restarts. Keeping the envelope through this
    /// boundary prevents a queued event from generation N from reaching the
    /// provider after a restart has already started generation N+1.
    func route(_ transportEvent: AppServerTransportEvent) async {
        guard let lease = await acquireLifecycleLease() else { return }
        let operation = Task { @MainActor [weak self] in
            await self?.handle(transportEvent, lease: lease)
        }
        activeLifecycleCancellation = { operation.cancel() }
        await operation.value
        finishLifecycleOperation(lease)
    }

    private func handle(
        _ transportEvent: AppServerTransportEvent,
        lease: LifecycleLease
    ) async {
        guard lifecycleIsCurrent(lease),
              await appServer.isLatestGeneration(transportEvent.generation),
              lifecycleIsCurrent(lease) else { return }
        let event = transportEvent.event
        await codexProvider.receive(event)
        guard lifecycleIsCurrent(lease) else { return }
        switch event {
        case .standardError(let text):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            // Codex writes recoverable tool failures and diagnostics to stderr while the
            // turn continues. Preserve them for Console diagnostics without interrupting
            // every repository window with a modal application error.
            Self.appServerLogger.debug("\(clean, privacy: .public)")
        case .exited(let termination):
            guard !intentionalShutdown else { return }
            Self.appServerLogger.error(
                "\(termination.diagnosticDescription(subject: "Codex App Server"), privacy: .public)"
            )
            serverState = .failed(
                termination.userFacingDescription(subject: "Codex App Server")
            )
            for coordinator in coordinators.values {
                await coordinator.appServerRestarted()
            }
        case .notification, .request:
            if let coordinator = coordinators.values.first(where: {
                $0.acceptsCodexEvent(event)
            }) {
                await coordinator.handle(event)
            }
        }
    }

    private func acquireLifecycleLease() async -> LifecycleLease? {
        while activeLifecycleLease != nil {
            await withCheckedContinuation { continuation in
                lifecycleWaiters.append(continuation)
            }
            guard !shutdownFenced else { return nil }
        }
        guard !shutdownFenced else { return nil }
        let lease = LifecycleLease(
            identifier: UUID(),
            generation: lifecycleGeneration
        )
        activeLifecycleLease = lease
        return lease
    }

    private func finishLifecycleOperation(_ lease: LifecycleLease) {
        guard activeLifecycleLease == lease else { return }
        activeLifecycleLease = nil
        activeLifecycleCancellation = nil
        let waiters = lifecycleWaiters
        lifecycleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForLifecycleOperationToFinish() async {
        while activeLifecycleLease != nil {
            await withCheckedContinuation { continuation in
                lifecycleWaiters.append(continuation)
            }
        }
    }

    private func cancelShutdownAfterPreparationFailure(_ detail: String) async -> Bool {
        applicationError = detail
        let probesStopped = await OwnedSubprocessSupervisor.shutdownAll()
        await waitForLifecycleOperationToFinish()
        var resumedProbeLaunching = false
        if probesStopped {
            resumedProbeLaunching = await OwnedSubprocessSupervisor.resumeLaunching()
        }
        if resumedProbeLaunching {
            shutdownFenced = false
        } else {
            applicationError = "\(detail)\n\(Self.probeQuitCleanupFailure)"
        }
        intentionalShutdown = false
        return false
    }

    private func lifecycleIsCurrent(_ lease: LifecycleLease) -> Bool {
        !shutdownFenced
            && !Task.isCancelled
            && lifecycleGeneration == lease.generation
            && activeLifecycleLease == lease
    }

    private func requireCurrentLifecycle(_ lease: LifecycleLease) throws {
        guard lifecycleIsCurrent(lease) else { throw CancellationError() }
    }

    private static func mergedWorkflowTemplates(
        builtIns: [WorkflowTemplate],
        custom: [WorkflowTemplate]
    ) -> [WorkflowTemplate] {
        var result = builtIns
        for template in custom {
            if let index = result.firstIndex(where: { $0.id == template.id }) {
                result[index] = template
            } else {
                result.append(template)
            }
        }
        return result
    }

    private static func isSupportedCodexVersion(
        _ version: String,
        catalog: AgentProviderCatalog
    ) -> Bool {
        guard let descriptor = catalog.provider(.codex) else { return true }
        return (try? AgentExecutableLocator.validateVersion(
            version,
            descriptor: descriptor
        )) != nil
    }
}

private struct AppServerActivationCleanupError: LocalizedError {
    let startupError: String

    var errorDescription: String? {
        "Codex startup failed: \(startupError) Codeness could not verify that every Codex App Server and MCP process stopped. Restart Codeness before trying again."
    }
}
