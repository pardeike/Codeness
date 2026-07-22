import AppKit
import CodenessCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class RepositoryWindowCommandState {
    fileprivate(set) var recentURLs: [URL] = []
}

@MainActor
final class RepositoryWindowManager {
    private let applicationModel: CodenessApplicationModel
    private let commandState: RepositoryWindowCommandState
    private var windowControllers: [String: RepositoryWindowController] = [:]
    private var repositoryOpenPanel: NSOpenPanel?
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
        openPanel.title = "Open Git Workspace"
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
                existing.showWindow(nil)
                existing.window?.makeKeyAndOrderFront(nil)
            }
            await rememberRecentRepository(workspaceURL)
            return (existing, true)
        }

        let windowController = makeWindowController(for: workspaceURL)
        windowControllers[path] = windowController
        if display {
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
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
        let controller = NSApp.keyWindow?.windowController as? RepositoryWindowController
            ?? repositoryWindows.first(where: { $0.window?.isMainWindow == true })
            ?? (repositoryWindows.count == 1 ? repositoryWindows.first : nil)
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

    private func makeWindowController(for repositoryURL: URL) -> RepositoryWindowController {
        let canonicalPath = repositoryURL.path
        let coordinator = applicationModel.coordinator(for: canonicalPath)
        let rootView = RepositoryWindowHost(coordinator: coordinator)
            .environment(applicationModel)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_260, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 1_260, height: 820))
        window.minSize = NSSize(width: 840, height: 560)
        window.title = "\(repositoryURL.lastPathComponent) — Codeness"
        window.titleVisibility = .hidden
        window.identifier = NSUserInterfaceItemIdentifier(
            "repository-\(WorkspaceStore.pathKey(canonicalPath))"
        )
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.center()
        stagger(window, relativeTo: windowControllers.values.compactMap(\.window))

        let controller = RepositoryWindowController(
            window: window,
            coordinator: coordinator,
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
    private let onClose: @MainActor (RepositoryWindowController) -> Void
    private var bypassCloseGuard = false
    private var didClose = false
    private var isPresentingCloseAlert = false
    private var isApplyingRestoredFrame = false
    private var pausePanel: NSPanel?
    private var restorationTask: Task<Void, Never>?

    init(
        window: NSWindow,
        coordinator: RepositoryCoordinator,
        onClose: @escaping @MainActor (RepositoryWindowController) -> Void
    ) {
        self.coordinator = coordinator
        self.onClose = onClose
        super.init(window: window)
        window.delegate = self
        restorationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await removeDefaultSidebarToolbarItemWhenAvailable()
            while !coordinator.isLoaded, !Task.isCancelled {
                if coordinator.errorMessage != nil { return }
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard !Task.isCancelled else { return }
            restoreWindowFrame()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("RepositoryWindowController does not support coder initialization")
    }

    deinit {
        restorationTask?.cancel()
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

    func windowDidEndLiveResize(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        removeDefaultSidebarToolbarItem()
    }

    func windowDidUpdate(_ notification: Notification) {
        removeDefaultSidebarToolbarItem()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        restorationTask?.cancel()
        coordinator.documentDidClose()
        onClose(self)
    }

    private func removeDefaultSidebarToolbarItemWhenAvailable() async {
        for attempt in 0..<8 where !Task.isCancelled {
            await Task.yield()
            removeDefaultSidebarToolbarItem()
            if attempt < 7 {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private func removeDefaultSidebarToolbarItem() {
        guard let toolbar = window?.toolbar else { return }
        for index in toolbar.items.indices.reversed()
        where toolbar.items[index].itemIdentifier == .toggleSidebar
            || toolbar.items[index].itemIdentifier == Self.swiftUISidebarToggleItemIdentifier {
            toolbar.removeItem(at: index)
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

    private func restoreWindowFrame() {
        guard let window,
              let storedFrame = coordinator.viewState.windowFrame else { return }
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
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        isApplyingRestoredFrame = false
    }

    private func saveWindowFrame() {
        guard !isApplyingRestoredFrame,
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
            Text("You can wait for a coherent stopping point or interrupt the current turn immediately. The window closes only after its resume state is saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Interrupt Now") {
                    Task { await coordinator.interruptCloseWait() }
                }
                .help("Interrupt the active turn immediately so its resume state can be saved")
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
