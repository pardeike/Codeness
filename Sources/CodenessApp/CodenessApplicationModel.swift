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

    private(set) var serverState: ServerState = .starting
    private(set) var models: [CodexModel] = []
    private(set) var coordinators: [String: RepositoryCoordinator] = [:]
    private(set) var currentExecutablePath = ""
    private(set) var configuredExecutablePath: String
    private(set) var promptDefaults: ActivityPrompts
    private(set) var repositoryModelDefaults: RepositoryModelDefaults
    private(set) var separatesRunTranscripts: Bool
    var applicationError: String?

    @ObservationIgnored private let appServer: CodexAppServerClient
    @ObservationIgnored private let router: any HandoffRouting
    @ObservationIgnored private let store: WorkspaceStore
    @ObservationIgnored private let resolver: GitRepositoryResolver
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var intentionalShutdown = false

    init(
        appServer: CodexAppServerClient = CodexAppServerClient(),
        router: any HandoffRouting = HandoffRouter(),
        store: WorkspaceStore = WorkspaceStore(),
        resolver: GitRepositoryResolver = GitRepositoryResolver()
    ) {
        self.appServer = appServer
        self.router = router
        self.store = store
        self.resolver = resolver
        configuredExecutablePath = UserDefaults.standard.string(forKey: "CodexExecutablePath") ?? ""
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
    }

    var isReady: Bool {
        if case .ready = serverState { return true }
        return false
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

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        let stream = await appServer.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        await startServer(configuredPath: configuredExecutablePath)
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
            initialSettings: initialSettings
        )
        coordinators[canonicalPath] = coordinator
        return coordinator
    }

    func canonicalWorkspace(for selectedURL: URL) async throws -> URL {
        try await resolver.canonicalWorkspace(for: selectedURL)
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

    @discardableResult
    func restartServer(configuredPath: String) async -> Bool {
        guard !coordinators.values.contains(where: { $0.hasActiveCodexTurn }) else {
            applicationError = "Interrupt or finish active Codex turns before restarting App Server."
            return false
        }

        let configuredPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable: URL
        let version: String
        do {
            executable = try CodexExecutableLocator.resolve(configuredPath: configuredPath)
            version = try CodexExecutableLocator.verify(executable)
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
               let previousVersion = try? CodexExecutableLocator.verify(previousExecutable) {
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
        await appServer.shutdown()
        eventTask?.cancel()
        eventTask = nil
        serverState = .stopped
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

    func setSeparatesRunTranscripts(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.separatesRunTranscriptsKey)
        separatesRunTranscripts = enabled
    }

    private func startServer(configuredPath: String) async {
        serverState = .starting
        do {
            let executable = try CodexExecutableLocator.resolve(configuredPath: configuredPath)
            let version = try CodexExecutableLocator.verify(executable)
            try await activateServer(executable: executable, version: version)
        } catch {
            serverState = .failed(error.localizedDescription)
            applicationError = error.localizedDescription
        }
    }

    private func activateServer(executable: URL, version: String) async throws {
        serverState = .starting
        try await appServer.start(configuration: CodexLaunchConfiguration(executableURL: executable))
        do {
            let availableModels = try await appServer.listModels().filter { !$0.hidden }
            currentExecutablePath = executable.path
            models = availableModels
            serverState = .ready(version)
        } catch {
            await appServer.shutdown()
            throw error
        }
    }

    private func handle(_ event: AppServerEvent) async {
        switch event {
        case .standardError(let text):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            // Codex writes recoverable tool failures and diagnostics to stderr while the
            // turn continues. Preserve them for Console diagnostics without interrupting
            // every repository window with a modal application error.
            Self.appServerLogger.debug("\(clean, privacy: .public)")
        case .exited(let status):
            guard !intentionalShutdown else { return }
            serverState = .failed("App Server exited with status \(status)")
            for coordinator in coordinators.values {
                await coordinator.appServerRestarted()
            }
        case .notification, .request:
            for coordinator in coordinators.values {
                await coordinator.handle(event)
            }
        }
    }
}
