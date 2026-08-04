import AppKit
import CodenessCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class RepositoryWindowCommandState {
    fileprivate(set) var recentURLs: [URL] = []
    fileprivate(set) var currentCoordinator: RepositoryCoordinator?
    fileprivate(set) var isWorkspaceTransferInProgress = false
    private(set) var steerFocusRequest = 0
    private(set) var steerFocusTargetPath: String?
    private(set) var goalAmendmentRequest = 0
    private(set) var goalAmendmentTargetPath: String?
    private(set) var startOverRequest = 0
    private(set) var startOverTargetPath: String?

    func requestSteerFocus() {
        steerFocusTargetPath = currentCoordinator?.record.canonicalPath
        steerFocusRequest &+= 1
    }

    func requestGoalAmendment() {
        goalAmendmentTargetPath = currentCoordinator?.record.canonicalPath
        goalAmendmentRequest &+= 1
    }

    func requestStartOver() {
        startOverTargetPath = currentCoordinator?.record.canonicalPath
        startOverRequest &+= 1
    }
}

@MainActor
@Observable
final class RepositoryWindowAppearanceState {
    private(set) var appearsActive = false

    func update(applicationIsActive: Bool, windowIsKey: Bool) {
        appearsActive = applicationIsActive && windowIsKey
    }

    func update(for window: NSWindow?) {
        update(
            applicationIsActive: NSApplication.shared.isActive,
            windowIsKey: window?.isKeyWindow == true
        )
    }

}

@MainActor
final class RepositoryWindowManager {
    private let applicationModel: CodenessApplicationModel
    private let commandState: RepositoryWindowCommandState
    private var windowControllers: [String: RepositoryWindowController] = [:]
    private var repositoryOpenPanel: NSOpenPanel?
    private var workspaceImportPanel: NSOpenPanel?
    private var workspaceExportPanel: NSSavePanel?
    private var workspaceLocationPanel: NSOpenPanel?
    private var workspaceTransferProgressPanel: NSPanel?
    private weak var workspaceTransferProgressParent: NSWindow?
    private var pendingOpenRequestCount = 0
    private var openRequestCompletionHandlers: [() -> Void] = []
    private var isApplicationTerminating = false

    init(applicationModel: CodenessApplicationModel, commandState: RepositoryWindowCommandState) {
        self.applicationModel = applicationModel
        self.commandState = commandState
    }

    var repositoryWindows: [RepositoryWindowController] {
        windowControllers.values.sorted {
            $0.coordinator.repositoryName.localizedStandardCompare($1.coordinator.repositoryName) == .orderedAscending
        }
    }

    var isEmpty: Bool {
        windowControllers.isEmpty
    }

    func presentRepositoryOpenPanel() {
        guard repositoryOpenPanel == nil else {
            repositoryOpenPanel?.makeKeyAndOrderFront(nil)
            return
        }

        let openPanel = NSOpenPanel()
        openPanel.title = "Open Workspace"
        openPanel.prompt = "Open"
        openPanel.message = "Choose the exact folder Codeness should use as its workspace."
        openPanel.allowedContentTypes = [.folder]
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = false
        openPanel.resolvesAliases = true

        repositoryOpenPanel = openPanel

        openPanel.begin { [weak self, weak openPanel] response in
            guard let self, let openPanel else { return }
            repositoryOpenPanel = nil

            guard response == .OK, let selectedURL = openPanel.url else { return }
            openRepository(at: selectedURL, display: true) { [weak self] _, _, error in
                if let error {
                    self?.presentError(error)
                }
            }
        }
    }

    func presentWorkspaceImportPanel() {
        guard !commandState.isWorkspaceTransferInProgress else { return }
        guard workspaceImportPanel == nil else {
            workspaceImportPanel?.makeKeyAndOrderFront(nil)
            return
        }

        let openPanel = NSOpenPanel()
        openPanel.title = "Import Codeness Workspace"
        openPanel.prompt = "Import"
        openPanel.message = "Choose a portable Codeness workspace file."
        openPanel.allowedContentTypes = [.codenessWorkspace]
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false
        openPanel.resolvesAliases = true
        workspaceImportPanel = openPanel

        openPanel.begin { [weak self, weak openPanel] response in
            guard let self, let openPanel else { return }
            workspaceImportPanel = nil
            guard response == .OK, let selectedURL = openPanel.url else { return }
            openWorkspaceTransfer(at: selectedURL)
        }
    }

    func presentWorkspaceExportPanel() {
        guard !commandState.isWorkspaceTransferInProgress,
              let controller = currentRepositoryWindowController else { return }
        guard workspaceExportPanel == nil else {
            workspaceExportPanel?.makeKeyAndOrderFront(nil)
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Export Codeness Workspace"
        savePanel.prompt = "Export"
        savePanel.message = "Save a portable snapshot of Codeness history and checkpoints."
        savePanel.allowedContentTypes = [.codenessWorkspace]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.nameFieldStringValue = controller.coordinator.repositoryName
            .appendingFileExtensionIfNeeded("codeness")
        workspaceExportPanel = savePanel

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak savePanel] response in
            guard let self, let savePanel else { return }
            workspaceExportPanel = nil
            guard response == .OK, let destinationURL = savePanel.url else { return }
            beginWorkspaceExport(from: controller, to: destinationURL)
        }
        if let parent = controller.window {
            savePanel.beginSheetModal(for: parent, completionHandler: completion)
        } else {
            savePanel.begin(completionHandler: completion)
        }
    }

    func openWorkspaceTransfer(at sourceURL: URL) {
        guard !commandState.isWorkspaceTransferInProgress else {
            applicationModel.applicationError = "Another workspace import or export is already in progress."
            return
        }
        beginOpenRequest()
        commandState.isWorkspaceTransferInProgress = true
        NSApp.activate()
        Task { [weak self] in
            guard let self else { return }
            defer {
                commandState.isWorkspaceTransferInProgress = false
                finishOpenRequest()
            }
            do {
                try await importWorkspaceInteractively(from: sourceURL)
            } catch is CancellationError {
                // Cancelling repository selection or replacement is not an error.
            } catch {
                presentError(error)
            }
        }
    }

    private var currentRepositoryWindowController: RepositoryWindowController? {
        NSApp.keyWindow?.windowController as? RepositoryWindowController
            ?? repositoryWindows.first(where: { $0.window?.isMainWindow == true })
            ?? (repositoryWindows.count == 1 ? repositoryWindows.first : nil)
    }

    private func beginWorkspaceExport(
        from controller: RepositoryWindowController,
        to destinationURL: URL
    ) {
        guard !commandState.isWorkspaceTransferInProgress else { return }
        commandState.isWorkspaceTransferInProgress = true
        presentWorkspaceTransferProgress(
            for: controller.coordinator,
            title: "Exporting \(controller.coordinator.repositoryName)",
            message: "Pausing at a coherent checkpoint before creating the portable copy…",
            parent: controller.window
        )
        Task { [weak self] in
            guard let self else { return }
            defer {
                dismissWorkspaceTransferProgress()
                controller.coordinator.cancelClosePreparation()
                commandState.isWorkspaceTransferInProgress = false
            }
            do {
                try await exportWorkspace(from: controller, to: destinationURL)
            } catch {
                presentError(error)
            }
        }
    }

    @discardableResult
    func exportWorkspace(
        from controller: RepositoryWindowController,
        to destinationURL: URL
    ) async throws -> WorkspaceTransferManifest {
        switch await controller.coordinator.prepareForClose(strategy: .graceful) {
        case .ready:
            return try await applicationModel.exportWorkspace(
                canonicalPath: controller.coordinator.record.canonicalPath,
                to: destinationURL
            )
        case .failed(let message):
            throw RepositoryWorkspaceTransferError.pauseFailed(message)
        }
    }

    private func importWorkspaceInteractively(from sourceURL: URL) async throws {
        let preview = try await applicationModel.inspectWorkspaceTransfer(at: sourceURL)
        let selectedRepositoryURL: URL
        if let originalURL = try await existingOriginalRepositoryURL(for: preview) {
            selectedRepositoryURL = originalURL
        } else {
            guard let locatedURL = await locateRepository(for: preview) else {
                throw CancellationError()
            }
            selectedRepositoryURL = try await applicationModel.canonicalWorkspace(for: locatedURL)
        }

        let canonicalPath = selectedRepositoryURL.path
        let existingRecord = try await applicationModel.storedWorkspacePreview(
            canonicalPath: canonicalPath
        )
        if let existingRecord {
            guard await confirmReplacement(
                archived: preview.record,
                existing: existingRecord,
                repositoryURL: selectedRepositoryURL
            ) else {
                throw CancellationError()
            }
        }

        let existingController = windowControllers[canonicalPath]
        if let existingController {
            presentWorkspaceTransferProgress(
                for: existingController.coordinator,
                title: "Importing \(preview.manifest.repositoryName)",
                message: "Pausing the open workspace before replacing its Codeness state…",
                parent: existingController.window
            )
            let preparation = await existingController.coordinator.prepareForClose(
                strategy: .graceful
            )
            dismissWorkspaceTransferProgress()
            guard case .ready = preparation else {
                if case .failed(let message) = preparation {
                    throw RepositoryWorkspaceTransferError.pauseFailed(message)
                }
                throw RepositoryWorkspaceTransferError.pauseFailed(
                    "The open workspace could not be paused."
                )
            }
            existingController.closeAfterWorkspaceTransferPreparation()
            await Task.yield()
        }

        let result: WorkspaceImportResult
        do {
            result = try await applicationModel.importWorkspace(
                from: sourceURL,
                to: canonicalPath,
                replacingExisting: existingRecord != nil
            )
        } catch {
            if existingController != nil {
                _ = try? await openRepository(at: selectedRepositoryURL, display: true)
            }
            throw error
        }

        let opened = try await openRepository(at: selectedRepositoryURL, display: true).controller
        if let backupURL = result.backupURL {
            presentImportBackupConfirmation(backupURL, parent: opened.window)
        }
    }

    private func existingOriginalRepositoryURL(
        for preview: WorkspaceTransferPreview
    ) async throws -> URL? {
        let originalURL = URL(
            fileURLWithPath: preview.manifest.originalCanonicalPath,
            isDirectory: true
        )
        guard let values = try? originalURL.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            return nil
        }
        return try await applicationModel.canonicalWorkspace(for: originalURL)
    }

    private func locateRepository(for preview: WorkspaceTransferPreview) async -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.title = "Locate \(preview.manifest.repositoryName)"
        openPanel.prompt = "Use Workspace"
        openPanel.message = "Choose this repository’s folder on this Mac. The repository itself is not included in the transfer file."
        openPanel.allowedContentTypes = [.folder]
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = false
        openPanel.resolvesAliases = true
        workspaceLocationPanel = openPanel
        return await withCheckedContinuation { continuation in
            openPanel.begin { [weak self, weak openPanel] response in
                self?.workspaceLocationPanel = nil
                continuation.resume(returning: response == .OK ? openPanel?.url : nil)
            }
        }
    }

    private func confirmReplacement(
        archived: RepositoryRecord,
        existing: RepositoryRecord,
        repositoryURL: URL
    ) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace Codeness state for \(repositoryURL.lastPathComponent)?"
        alert.informativeText = """
        Imported: \(workspaceSummary(archived))
        On this Mac: \(workspaceSummary(existing))

        Codeness will export the existing state to Import Backups before replacing it. The repository folder is not modified.
        """
        alert.addButton(withTitle: "Back Up and Replace").toolTip =
            "Create a portable backup of the existing Codeness state, then import this workspace"
        alert.addButton(withTitle: "Cancel").toolTip =
            "Keep the existing Codeness state unchanged"
        return await runAlert(alert, parent: windowControllers[repositoryURL.path]?.window)
            == .alertFirstButtonReturn
    }

    private func workspaceSummary(_ record: RepositoryRecord) -> String {
        let goal = record.activity?.goal ?? "No activity"
        let status = record.activity?.status.rawValue.capitalized ?? "Ready"
        let date = DateFormatter.localizedString(
            from: record.updatedAt,
            dateStyle: .medium,
            timeStyle: .short
        )
        return "\(goal) — \(status), updated \(date)"
    }

    private func runAlert(_ alert: NSAlert, parent: NSWindow?) async -> NSApplication.ModalResponse {
        guard let parent else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: parent) { response in
                continuation.resume(returning: response)
            }
        }
    }

    private func presentImportBackupConfirmation(_ backupURL: URL, parent: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Workspace Imported"
        alert.informativeText = "The previous Codeness state was backed up to:\n\n\(backupURL.abbreviatedPath)"
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Reveal Backup")
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertSecondButtonReturn else { return }
            NSWorkspace.shared.activateFileViewerSelecting([backupURL])
        }
        if let parent {
            alert.beginSheetModal(for: parent, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func presentWorkspaceTransferProgress(
        for coordinator: RepositoryCoordinator,
        title: String,
        message: String,
        parent: NSWindow?
    ) {
        let hostingController = NSHostingController(
            rootView: WorkspaceTransferProgressView(
                coordinator: coordinator,
                message: message
            )
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 170),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.contentViewController = hostingController
        panel.isReleasedWhenClosed = false
        workspaceTransferProgressPanel = panel
        workspaceTransferProgressParent = parent
        if let parent {
            parent.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func dismissWorkspaceTransferProgress() {
        guard let panel = workspaceTransferProgressPanel else { return }
        if let parent = workspaceTransferProgressParent, parent.attachedSheet === panel {
            parent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
        workspaceTransferProgressPanel = nil
        workspaceTransferProgressParent = nil
    }

    func openRepository(
        at url: URL,
        display: Bool,
        completionHandler: @escaping (RepositoryWindowController?, Bool, (any Error)?) -> Void
    ) {
        Task {
            do {
                let result = try await openRepository(at: url, display: display)
                completionHandler(result.controller, result.wasAlreadyOpen, nil)
            } catch {
                completionHandler(nil, false, error)
            }
        }
    }

    func openRepository(
        at url: URL,
        display: Bool
    ) async throws -> (controller: RepositoryWindowController, wasAlreadyOpen: Bool) {
        beginOpenRequest()
        defer { finishOpenRequest() }

        let workspaceURL = try await applicationModel.canonicalWorkspace(for: url)
        let path = workspaceURL.path
        if let existing = windowControllers[path] {
            if display {
                existing.present()
            }
            await rememberRecentRepository(workspaceURL)
            return (existing, true)
        }

        let initialWindowFrame = await applicationModel.storedWindowFrame(for: path)
        // Loading the tiny view-state file yields the MainActor. Recheck so two
        // concurrent open requests cannot create duplicate windows for one path.
        if let existing = windowControllers[path] {
            if display {
                existing.present()
            }
            await rememberRecentRepository(workspaceURL)
            return (existing, true)
        }

        let windowController = makeWindowController(
            for: workspaceURL,
            initialWindowFrame: initialWindowFrame
        )
        windowControllers[path] = windowController
        if display {
            windowController.present()
        }
        await rememberRecentRepository(workspaceURL)
        persistOpenRepositories()
        return (windowController, false)
    }

    func loadRecentRepositories() async {
        do {
            let paths = try await applicationModel.loadRecentRepositoryPaths()
            commandState.recentURLs = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } catch {
            presentError(error)
        }
    }

    func clearRecentRepositories() {
        commandState.recentURLs = []
        Task {
            do {
                try await applicationModel.saveRecentRepositoryPaths([])
            } catch {
                presentError(error)
            }
        }
    }

    func saveCurrentRepositoryState() async -> Bool {
        let controller = currentRepositoryWindowController
        guard let controller else { return false }
        return await controller.coordinator.flushDocumentState()
    }

    func forgetRecentDocument(at url: URL) {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        commandState.recentURLs.removeAll {
            $0.standardizedFileURL.resolvingSymlinksInPath() == canonicalURL
        }
        let paths = commandState.recentURLs.map(\.path)
        Task {
            do {
                try await applicationModel.saveRecentRepositoryPaths(paths)
            } catch {
                presentError(error)
            }
        }
    }

    func whenOpenRequestsFinish(_ completionHandler: @escaping () -> Void) {
        guard pendingOpenRequestCount > 0 else {
            completionHandler()
            return
        }
        openRequestCompletionHandlers.append(completionHandler)
    }

    func restoreOpenRepositories(completionHandler: @escaping () -> Void) {
        Task {
            do {
                let paths = try await applicationModel.loadOpenDocumentPaths()
                restoreOpenRepositories(
                    ArraySlice(paths.map { URL(fileURLWithPath: $0, isDirectory: true) }),
                    completionHandler: completionHandler
                )
            } catch {
                presentError(error)
                completionHandler()
            }
        }
    }

    func prepareForApplicationTermination() async -> Bool {
        let paths = windowControllers.keys.sorted()
        do {
            try await applicationModel.saveOpenDocumentPaths(paths)
        } catch {
            presentError(error)
            return false
        }
        isApplicationTerminating = true
        return true
    }

    func cancelApplicationTermination() {
        isApplicationTerminating = false
    }

    private func beginOpenRequest() {
        pendingOpenRequestCount += 1
    }

    private func finishOpenRequest() {
        pendingOpenRequestCount -= 1
        guard pendingOpenRequestCount == 0 else { return }
        let handlers = openRequestCompletionHandlers
        openRequestCompletionHandlers.removeAll()
        handlers.forEach { $0() }
    }

    private func restoreOpenRepositories(
        _ remainingURLs: ArraySlice<URL>,
        completionHandler: @escaping () -> Void
    ) {
        guard let url = remainingURLs.first else {
            completionHandler()
            return
        }
        openRepository(at: url, display: true) { [weak self] _, _, error in
            guard let self else {
                completionHandler()
                return
            }
            if let error {
                forgetRecentDocument(at: url)
                presentError(error)
            }
            restoreOpenRepositories(remainingURLs.dropFirst(), completionHandler: completionHandler)
        }
    }

    private func makeWindowController(
        for repositoryURL: URL,
        initialWindowFrame: StoredWindowFrame?
    ) -> RepositoryWindowController {
        let canonicalPath = repositoryURL.path
        let coordinator = applicationModel.coordinator(for: canonicalPath)
        let appearanceState = RepositoryWindowAppearanceState()
        let rootView = RepositoryWindowHost(
            coordinator: coordinator,
            appearanceState: appearanceState
        )
            .environment(applicationModel)
            .environment(commandState)
        let hostingController = NSHostingController(rootView: rootView)
        // RepositoryWindowController owns this window's size policy. In particular,
        // SwiftUI must not replace NSWindow.minSize with the current sidebar width
        // plus the detail's fitting width, because that prevents the sidebar from
        // yielding when the user continues to narrow the window.
        hostingController.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: RepositoryWindowMetrics.defaultContentSize
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.setContentSize(RepositoryWindowMetrics.defaultContentSize)
        window.minSize = RepositoryWindowMetrics.minimumWindowSize
        window.title = repositoryURL.lastPathComponent
        window.subtitle = repositoryURL.deletingLastPathComponent().abbreviatedPath
        window.representedURL = repositoryURL
        window.titleVisibility = .visible
        window.identifier = NSUserInterfaceItemIdentifier(
            "repository-\(WorkspaceStore.pathKey(canonicalPath))"
        )
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        if initialWindowFrame == nil {
            window.center()
            stagger(window, relativeTo: windowControllers.values.compactMap(\.window))
        }

        let controller = RepositoryWindowController(
            window: window,
            coordinator: coordinator,
            initialWindowFrame: initialWindowFrame,
            commandState: commandState,
            appearanceState: appearanceState,
            onClose: { [weak self] closedController in
                self?.repositoryWindowDidClose(closedController)
            }
        )
        controller.shouldCascadeWindows = false
        return controller
    }

    private func repositoryWindowDidClose(_ controller: RepositoryWindowController) {
        let path = controller.coordinator.record.canonicalPath
        guard windowControllers[path] === controller else { return }
        windowControllers.removeValue(forKey: path)
        applicationModel.releaseCoordinator(controller.coordinator)
        persistOpenRepositories()
    }

    private func rememberRecentRepository(_ url: URL) async {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        commandState.recentURLs.removeAll {
            $0.standardizedFileURL.resolvingSymlinksInPath() == canonicalURL
        }
        commandState.recentURLs.insert(canonicalURL, at: 0)
        if commandState.recentURLs.count > 20 {
            commandState.recentURLs.removeLast(commandState.recentURLs.count - 20)
        }
        do {
            try await applicationModel.saveRecentRepositoryPaths(commandState.recentURLs.map(\.path))
        } catch {
            presentError(error)
        }
    }

    private func persistOpenRepositories() {
        guard !isApplicationTerminating else { return }
        let paths = windowControllers.keys.sorted()
        Task {
            do {
                try await applicationModel.saveOpenDocumentPaths(paths)
            } catch {
                presentError(error)
            }
        }
    }

    private func stagger(_ window: NSWindow, relativeTo existingWindows: [NSWindow]) {
        guard !existingWindows.isEmpty, let visibleFrame = window.screen?.visibleFrame else { return }

        let minimumX = visibleFrame.minX
        let maximumX = max(minimumX, visibleFrame.maxX - window.frame.width)
        let centeredX = window.frame.minX
        let existingOrigins = existingWindows.map(\.frame.minX)
        let step: CGFloat = 28

        for distance in 1 ... max(1, existingWindows.count + 1) {
            for direction: CGFloat in [1, -1] {
                let proposedX = centeredX + (CGFloat(distance) * step * direction)
                let candidateX = min(max(proposedX, minimumX), maximumX)
                guard !existingOrigins.contains(where: { abs($0 - candidateX) < 1 }) else { continue }
                window.setFrameOrigin(NSPoint(x: candidateX, y: window.frame.minY))
                return
            }
        }
    }

    private func presentError(_ error: any Error) {
        applicationModel.applicationError = error.localizedDescription
    }
}

@MainActor
final class RepositoryWindowController: NSWindowController, NSWindowDelegate {
    // NavigationSplitView currently installs this SwiftUI-specific item on
    // macOS 27 instead of AppKit's standard `.toggleSidebar` item.
    private static let swiftUISidebarToggleItemIdentifier = NSToolbarItem.Identifier(
        "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
    )

    let coordinator: RepositoryCoordinator
    private let commandState: RepositoryWindowCommandState
    private let appearanceState: RepositoryWindowAppearanceState
    private let onClose: @MainActor (RepositoryWindowController) -> Void
    private var bypassCloseGuard = false
    private var didClose = false
    private var isPresentingCloseAlert = false
    private var isApplyingRestoredFrame = false
    private var isAwaitingInitialFrameRestoration = true
    private var pausePanel: NSPanel?
    private var loadCompletionTask: Task<Void, Never>?

    init(
        window: NSWindow,
        coordinator: RepositoryCoordinator,
        initialWindowFrame: StoredWindowFrame? = nil,
        commandState: RepositoryWindowCommandState,
        appearanceState: RepositoryWindowAppearanceState = RepositoryWindowAppearanceState(),
        onClose: @escaping @MainActor (RepositoryWindowController) -> Void
    ) {
        self.coordinator = coordinator
        self.commandState = commandState
        self.appearanceState = appearanceState
        self.onClose = onClose
        super.init(window: window)
        restoreWindowFrame(initialWindowFrame, display: false)
        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationActivationDidChange),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationActivationDidChange),
            name: NSApplication.didResignActiveNotification,
            object: NSApplication.shared
        )
        appearanceState.update(for: window)
        loadCompletionTask = Task { @MainActor [weak self] in
            while !coordinator.isLoaded, !Task.isCancelled {
                if coordinator.errorMessage != nil {
                    guard let self else { return }
                    isAwaitingInitialFrameRestoration = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard !Task.isCancelled, let self else { return }
            isAwaitingInitialFrameRestoration = false
            saveWindowFrame()
            await hideDefaultSidebarToolbarItemWhenAvailable()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("RepositoryWindowController does not support coder initialization")
    }

    deinit {
        loadCompletionTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func closeAfterWorkspaceTransferPreparation() {
        bypassCloseGuard = true
        window?.close()
    }

    func present() {
        // The hosting controller is created before its window becomes key. Seed
        // the appearance from the presentation we are about to perform so the
        // first visible frame does not inherit SwiftUI's inactive startup tint.
        NSApplication.shared.activate()
        appearanceState.update(applicationIsActive: true, windowIsKey: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !bypassCloseGuard else { return true }
        guard !isPresentingCloseAlert else { return false }

        guard coordinator.requiresCloseConfirmation else {
            isPresentingCloseAlert = true
            Task { [weak self] in
                guard let self else { return }
                let result = await coordinator.prepareForClose(strategy: .immediate)
                isPresentingCloseAlert = false
                guard result == .ready else { return }
                bypassCloseGuard = true
                window?.close()
            }
            return false
        }

        isPresentingCloseAlert = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Codeness is still working"
        alert.informativeText = "Codeness will ask the active agent to reach a coherent stopping point, save a resumable checkpoint, and then close this repository."
        alert.addButton(withTitle: "Pause and Close").toolTip =
            "Ask the active agent for a safe checkpoint, save this repository, and close its window"
        alert.addButton(withTitle: "Keep Window Open").toolTip =
            "Cancel closing and leave this repository window active"
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                isPresentingCloseAlert = false
                return
            }
            beginPauseAndClose(from: sender)
        }
        return false
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        enforceMinimumWindowSize(on: sender)
        yieldSidebarIfNeeded(in: sender, forProposedFrameSize: frameSize)
        return frameSize
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        enforceMinimumWindowSize()
        saveWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        enforceMinimumWindowSize()
        saveWindowFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        enforceMinimumWindowSize()
        commandState.currentCoordinator = coordinator
        appearanceState.update(applicationIsActive: true, windowIsKey: true)
        hideDefaultSidebarToolbarItem()
    }

    func windowDidResignKey(_ notification: Notification) {
        appearanceState.update(for: window)
    }

    @objc private func applicationActivationDidChange(_ notification: Notification) {
        appearanceState.update(for: window)
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        loadCompletionTask?.cancel()
        if commandState.currentCoordinator === coordinator {
            commandState.currentCoordinator = nil
        }
        coordinator.documentDidClose()
        onClose(self)
    }

    private func hideDefaultSidebarToolbarItemWhenAvailable() async {
        for attempt in 0..<8 where !Task.isCancelled {
            await Task.yield()
            hideDefaultSidebarToolbarItem()
            if attempt < 7 {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private func hideDefaultSidebarToolbarItem() {
        guard let toolbar = window?.toolbar else { return }
        Self.hideSystemSidebarToolbarItems(in: toolbar.items)
    }

    static func hideSystemSidebarToolbarItems(in items: [NSToolbarItem]) {
        for item in items
        where item is NSTrackingSeparatorToolbarItem
            || item.itemIdentifier == .toggleSidebar
            || item.itemIdentifier == .sidebarTrackingSeparator
            || item.itemIdentifier == Self.swiftUISidebarToggleItemIdentifier {
            item.isHidden = true
        }
    }

    private func beginPauseAndClose(from parentWindow: NSWindow) {
        let panel = makePausePanel(title: "Pausing \(coordinator.repositoryName)")
        pausePanel = panel
        parentWindow.beginSheet(panel)
        Task { [weak self] in
            guard let self else { return }
            let result = await coordinator.prepareForClose(strategy: .graceful)
            if parentWindow.attachedSheet === panel {
                parentWindow.endSheet(panel)
            }
            pausePanel = nil
            isPresentingCloseAlert = false
            guard result == .ready else { return }
            bypassCloseGuard = true
            window?.close()
        }
    }

    private func makePausePanel(title: String) -> NSPanel {
        let hostingController = NSHostingController(
            rootView: RepositoryPauseProgressView(coordinator: coordinator)
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 190),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.contentViewController = hostingController
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func restoreWindowFrame(_ storedFrame: StoredWindowFrame?, display: Bool) {
        guard let window, let storedFrame else { return }
        enforceMinimumWindowSize(on: window)
        let preferredScreen = NSScreen.screens.first {
            $0.localizedName == storedFrame.displayIdentifier
        } ?? window.screen ?? NSScreen.main
        guard let screen = preferredScreen else { return }

        let visible = screen.visibleFrame
        let width = min(max(CGFloat(storedFrame.width), window.minSize.width), visible.width)
        let height = min(max(CGFloat(storedFrame.height), window.minSize.height), visible.height)
        let x = min(max(CGFloat(storedFrame.x), visible.minX), visible.maxX - width)
        let y = min(max(CGFloat(storedFrame.y), visible.minY), visible.maxY - height)
        isApplyingRestoredFrame = true
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: display)
        isApplyingRestoredFrame = false
    }

    private func enforceMinimumWindowSize(on candidate: NSWindow? = nil) {
        guard let window = candidate ?? window else { return }
        let minimumFrameSize = RepositoryWindowMetrics.minimumWindowSize
        let minimumContentSize = window.contentRect(
            forFrameRect: NSRect(origin: .zero, size: minimumFrameSize)
        ).size
        if window.contentMinSize != minimumContentSize {
            window.contentMinSize = minimumContentSize
        }
        if window.minSize != minimumFrameSize {
            window.minSize = minimumFrameSize
        }
    }

    private func yieldSidebarIfNeeded(
        in window: NSWindow,
        forProposedFrameSize frameSize: NSSize
    ) {
        guard frameSize.width < window.frame.width - 0.5,
              let contentView = window.contentView,
              let splitView = findNavigationSplitView(in: contentView),
              splitView.arrangedSubviews.count >= 2 else { return }

        let proposedContentWidth = window.contentRect(
            forFrameRect: NSRect(origin: .zero, size: frameSize)
        ).width
        let widthOutsideSplitView = max(0, contentView.bounds.width - splitView.frame.width)
        let proposedSplitWidth = max(0, proposedContentWidth - widthOutsideSplitView)
        let occupiedWidth = splitView.arrangedSubviews.reduce(CGFloat.zero) {
            $0 + $1.frame.width
        }
        // NavigationSplitView uses an underlaying full-width detail wrapper, so
        // its arranged widths intentionally overlap. Its divider does not consume
        // horizontal layout space. Plain NSSplitViews use the remaining gap.
        let dividerWidth = occupiedWidth > splitView.bounds.width + 0.5
            ? 0
            : max(0, splitView.bounds.width - occupiedWidth)
        let sidebar = splitView.arrangedSubviews[0]
        let proposedSidebarWidth = RepositoryWindowMetrics.sidebarWidth(
            currentWidth: sidebar.frame.width,
            forProposedSplitWidth: proposedSplitWidth,
            dividerWidth: dividerWidth
        )

        guard proposedSidebarWidth < sidebar.frame.width - 0.5 else { return }
        splitView.setPosition(proposedSidebarWidth, ofDividerAt: 0)
    }

    private func findNavigationSplitView(in view: NSView) -> NSSplitView? {
        if let splitView = view as? NSSplitView,
           splitView.isVertical,
           splitView.arrangedSubviews.count >= 2 {
            return splitView
        }
        for subview in view.subviews {
            if let splitView = findNavigationSplitView(in: subview) {
                return splitView
            }
        }
        return nil
    }

    private func saveWindowFrame() {
        guard !isApplyingRestoredFrame,
              !isAwaitingInitialFrameRestoration,
              coordinator.isLoaded,
              let window else { return }
        let frame = window.frame
        coordinator.updateWindowFrame(StoredWindowFrame(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height,
            displayIdentifier: window.screen?.localizedName
        ))
    }
}

private struct RepositoryPauseProgressView: View {
    @Bindable var coordinator: RepositoryCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text(coordinator.statusMessage)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("You can wait for a coherent stopping point or stop the current step immediately. The window closes only after its resume state is saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Stop Now") {
                    Task { await coordinator.interruptCloseWait() }
                }
                .help("Stop the current step immediately so its resume state can be saved")
                .disabled(
                    coordinator.pauseState != .requestingCheckpoint
                        && coordinator.pauseState != .waitingForTurn
                )
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct WorkspaceTransferProgressView: View {
    @Bindable var coordinator: RepositoryCoordinator
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(coordinator.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Spacer()
                Button("Stop Current Step Now") {
                    Task { await coordinator.interruptCloseWait() }
                }
                .help("Stop the current step immediately so the portable copy can be created")
                .disabled(
                    coordinator.pauseState != .requestingCheckpoint
                        && coordinator.pauseState != .waitingForTurn
                )
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private enum RepositoryWorkspaceTransferError: LocalizedError {
    case pauseFailed(String)

    var errorDescription: String? {
        switch self {
        case .pauseFailed(let message):
            "The workspace could not be prepared for transfer: \(message)"
        }
    }
}

private extension String {
    func appendingFileExtensionIfNeeded(_ fileExtension: String) -> String {
        let suffix = ".\(fileExtension)"
        return lowercased().hasSuffix(suffix.lowercased()) ? self : self + suffix
    }
}
