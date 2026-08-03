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
    var applicationError: String?

    @ObservationIgnored private let appServer: CodexAppServerClient
    @ObservationIgnored private let router: any HandoffRouting
    @ObservationIgnored private let store: WorkspaceStore
    @ObservationIgnored private let resolver: WorkspaceResolver
    @ObservationIgnored private let codexProvider: CodexAgentProvider
    @ObservationIgnored private var claudeProvider: ClaudeAgentProvider?
    @ObservationIgnored private let agentProviders: AgentProviderRegistry
    @ObservationIgnored private let workflowRouter: AgentWorkflowHandoffRouter
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var intentionalShutdown = false

    init(
        appServer: CodexAppServerClient = CodexAppServerClient(),
        router: any HandoffRouting = HandoffRouter(),
        store: WorkspaceStore = WorkspaceStore(),
        resolver: WorkspaceResolver = WorkspaceResolver()
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
        self.router = router
        self.store = store
        self.resolver = resolver
        providerCatalog = loadedProviderCatalog
        claudeModels = loadedProviderCatalog.provider(.claude)?.knownModels ?? []
        builtInWorkflowCatalog = loadedWorkflowCatalog
        let codexProvider = CodexAgentProvider(appServer: appServer)
        self.codexProvider = codexProvider
        let agentProviders = AgentProviderRegistry(providers: [codexProvider])
        self.agentProviders = agentProviders
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
            && workflowCompatibilityMessage(workflow) == nil
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
        guard !didBootstrap else { return }
        didBootstrap = true
        let catalogError = applicationError
        let stream = await appServer.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        await startServer(configuredPath: configuredExecutablePath)
        await startClaude(configuredPath: configuredClaudeExecutablePath)
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
        guard !coordinators.values.contains(where: {
            $0.hasActiveWork(for: .codex)
        }) else {
            applicationError = "Finish active Codex turns or coordinator work before restarting App Server."
            return false
        }

        let configuredPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable: URL
        let version: String
        do {
            executable = try CodexExecutableLocator.resolve(configuredPath: configuredPath)
            version = try CodexExecutableLocator.verify(executable)
            if let descriptor = providerCatalog.provider(.codex) {
                try AgentExecutableLocator.validateVersion(version, descriptor: descriptor)
            }
        } catch {
            applicationError = error.localizedDescription
            return false
        }

        let previousConfiguredPath = UserDefaults.standard.string(forKey: "CodexExecutablePath") ?? ""
        intentionalShutdown = true
        await appServer.shutdown()
        for coordinator in coordinators.values {
            await coordinator.appServerRestarted()
        }
        do {
            try await activateServer(executable: executable, version: version)
            UserDefaults.standard.set(configuredPath, forKey: "CodexExecutablePath")
            configuredExecutablePath = configuredPath
            intentionalShutdown = false
            return true
        } catch {
            let requestedError = error.localizedDescription
            var restoredPreviousServer = false
            if let previousExecutable = try? CodexExecutableLocator.resolve(configuredPath: previousConfiguredPath),
               let previousVersion = try? CodexExecutableLocator.verify(previousExecutable),
               Self.isSupportedCodexVersion(previousVersion, catalog: providerCatalog) {
                do {
                    try await activateServer(executable: previousExecutable, version: previousVersion)
                    restoredPreviousServer = true
                } catch {
                    // The requested error remains the actionable settings failure.
                }
            }
            if !restoredPreviousServer {
                currentExecutablePath = ""
                models = []
                serverState = .failed(requestedError)
            }
            applicationError = "Could not restart Codex with the requested executable: \(requestedError)"
            intentionalShutdown = false
            return false
        }
    }

    @discardableResult
    func restartClaude(configuredPath: String) async -> Bool {
        guard !coordinators.values.contains(where: {
            $0.hasActiveWork(for: .claude)
        }) else {
            applicationError = "Finish active Claude turns or coordinator work before restarting Claude."
            return false
        }
        guard let descriptor = providerCatalog.provider(.claude) else {
            applicationError = "The Claude provider is missing from AgentProviders.json."
            return false
        }
        let cleanPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousPath = UserDefaults.standard.string(forKey: Self.claudeExecutablePathKey) ?? ""
        await claudeProvider?.shutdown()
        await agentProviders.unregister(.claude)
        claudeProvider = nil
        do {
            let executable = try AgentExecutableLocator.resolve(
                configuredPath: cleanPath,
                descriptor: descriptor
            )
            let version = try AgentExecutableLocator.verify(executable, descriptor: descriptor)
            await activateClaude(executable: executable, version: version)
            UserDefaults.standard.set(cleanPath, forKey: Self.claudeExecutablePathKey)
            configuredClaudeExecutablePath = cleanPath
            return true
        } catch {
            let requestedError = error.localizedDescription
            if let previousExecutable = try? AgentExecutableLocator.resolve(
                configuredPath: previousPath,
                descriptor: descriptor
            ), let previousVersion = try? AgentExecutableLocator.verify(
                previousExecutable,
                descriptor: descriptor
            ) {
                await activateClaude(
                    executable: previousExecutable,
                    version: previousVersion
                )
            } else {
                currentClaudeExecutablePath = ""
                claudeState = .failed(requestedError)
            }
            applicationError = "Could not restart Claude with the requested executable: \(requestedError)"
            return false
        }
    }

    func shutdown(prepareDocuments: Bool = true) async -> Bool {
        intentionalShutdown = true
        if prepareDocuments {
            for coordinator in coordinators.values {
                let result = await coordinator.prepareForClose(strategy: .immediate)
                guard result == .ready else {
                    intentionalShutdown = false
                    return false
                }
            }
        }
        await agentProviders.shutdown()
        await appServer.shutdown()
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

    private func startServer(configuredPath: String) async {
        serverState = .starting
        do {
            let executable = try CodexExecutableLocator.resolve(configuredPath: configuredPath)
            let version = try CodexExecutableLocator.verify(executable)
            if let descriptor = providerCatalog.provider(.codex) {
                try AgentExecutableLocator.validateVersion(version, descriptor: descriptor)
            }
            try await activateServer(executable: executable, version: version)
        } catch {
            serverState = .failed(error.localizedDescription)
        }
    }

    private func startClaude(configuredPath: String) async {
        claudeState = .starting
        guard let descriptor = providerCatalog.provider(.claude) else {
            claudeState = .failed("Provider metadata is missing.")
            return
        }
        do {
            let executable = try AgentExecutableLocator.resolve(
                configuredPath: configuredPath,
                descriptor: descriptor
            )
            let version = try AgentExecutableLocator.verify(executable, descriptor: descriptor)
            await activateClaude(executable: executable, version: version)
        } catch {
            currentClaudeExecutablePath = ""
            claudeState = .failed(error.localizedDescription)
        }
    }

    private func activateClaude(executable: URL, version: String) async {
        let discoveredModels = await Task.detached {
            try? ClaudeExecutableInspector.models(executableURL: executable)
        }.value
        let provider = ClaudeAgentProvider(executableURL: executable)
        await agentProviders.register(provider)
        claudeProvider = provider
        if let discoveredModels, !discoveredModels.isEmpty {
            claudeModels = discoveredModels
        } else {
            claudeModels = providerCatalog.provider(.claude)?.knownModels ?? []
        }
        currentClaudeExecutablePath = executable.path
        claudeState = .ready(version)
    }

    private func activateServer(executable: URL, version: String) async throws {
        serverState = .starting
        try await appServer.start(configuration: CodexLaunchConfiguration(executableURL: executable))
        do {
            let availableModels = try await appServer.listModels().filter { !$0.hidden }
            currentExecutablePath = executable.path
            models = availableModels
            await codexProvider.updateModels(availableModels)
            serverState = .ready(version)
        } catch {
            await appServer.shutdown()
            throw error
        }
    }

    private func handle(_ event: AppServerEvent) async {
        await codexProvider.receive(event)
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
