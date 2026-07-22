import AppKit
import CodenessCore
import SwiftUI

@MainActor
final class CodenessAppDelegate: NSObject, NSApplicationDelegate {
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    let applicationModel = CodenessApplicationModel()
    let commandState = RepositoryWindowCommandState()

    private var windowManager: RepositoryWindowManager?
    private var isTerminating = false
    private var terminationPanel: NSPanel?
    private weak var terminationParentWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        windowManager = RepositoryWindowManager(
            applicationModel: applicationModel,
            commandState: commandState
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningUnitTests else { return }
        Task { await applicationModel.bootstrap() }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, let windowManager else { return }
            await windowManager.loadRecentRepositories()
            windowManager.whenOpenRequestsFinish { [weak self, weak windowManager] in
                guard let self, let windowManager, windowManager.isEmpty else { return }
                windowManager.restoreOpenRepositories { [weak self, weak windowManager] in
                    guard let self, let windowManager, windowManager.isEmpty else { return }
                    openRepository()
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !Self.isRunningUnitTests else { return true }
        if let windowManager, !windowManager.isEmpty {
            windowManager.repositoryWindows.forEach { $0.showWindow(nil) }
        } else {
            openRepository()
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func openRepository() {
        windowManager?.presentRepositoryOpenPanel()
    }

    func openRecentRepository(_ url: URL) {
        windowManager?.openRepository(at: url, display: true) { [weak self] _, _, error in
            if let error {
                self?.windowManager?.forgetRecentDocument(at: url)
                self?.applicationModel.applicationError = error.localizedDescription
            }
        }
    }

    func clearRecentRepositories() {
        windowManager?.clearRecentRepositories()
    }

    func saveCurrentRepository() {
        Task { _ = await windowManager?.saveCurrentRepositoryState() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isRunningUnitTests else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        let activeCoordinators = applicationModel.activeCoordinators
        guard !activeCoordinators.isEmpty else {
            finishTermination(sender, coordinatorsToPause: [])
            return .terminateLater
        }

        presentTerminationConfirmation(sender, coordinators: activeCoordinators)
        return .terminateLater
    }

    private func presentTerminationConfirmation(
        _ sender: NSApplication,
        coordinators: [RepositoryCoordinator]
    ) {
        let names = coordinators.map { "• \($0.repositoryName) — \($0.statusMessage)" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Pause active repositories and quit?"
        alert.informativeText = "Codeness will ask each active agent to reach a coherent stopping point before quitting.\n\n\(names)"
        alert.addButton(withTitle: "Pause and Quit").toolTip =
            "Ask active agents for safe checkpoints, save every repository, and quit Codeness"
        alert.addButton(withTitle: "Cancel").toolTip =
            "Keep Codeness and every repository window open"

        guard let parent = terminationPresentationWindow() else {
            handleTerminationConfirmation(
                alert.runModal(),
                sender: sender,
                coordinators: coordinators,
                parent: nil
            )
            return
        }
        alert.beginSheetModal(for: parent) { [weak self, weak parent] response in
            self?.handleTerminationConfirmation(
                response,
                sender: sender,
                coordinators: coordinators,
                parent: parent
            )
        }
    }

    private func handleTerminationConfirmation(
        _ response: NSApplication.ModalResponse,
        sender: NSApplication,
        coordinators: [RepositoryCoordinator],
        parent: NSWindow?
    ) {
        guard response == .alertFirstButtonReturn else {
            isTerminating = false
            sender.reply(toApplicationShouldTerminate: false)
            return
        }

        let panel = makeTerminationProgressPanel(coordinators: coordinators)
        terminationPanel = panel
        terminationParentWindow = parent
        if let parent {
            parent.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
        finishTermination(sender, coordinatorsToPause: coordinators)
    }

    private func finishTermination(
        _ sender: NSApplication,
        coordinatorsToPause: [RepositoryCoordinator]
    ) {
        Task { [weak self] in
            guard let self else { return }
            guard await windowManager?.prepareForApplicationTermination() != false else {
                cancelTermination(sender, message: "Could not save the list of open repository windows.")
                return
            }

            let pauseTasks = coordinatorsToPause.map { coordinator in
                Task { @MainActor in
                    await coordinator.prepareForClose(strategy: .graceful)
                }
            }
            var failureMessages: [String] = []
            for (index, task) in pauseTasks.enumerated() {
                if case .failed(let message) = await task.value {
                    failureMessages.append("\(coordinatorsToPause[index].repositoryName): \(message)")
                }
            }
            guard failureMessages.isEmpty else {
                cancelTermination(sender, message: failureMessages.joined(separator: "\n"))
                return
            }

            guard await applicationModel.shutdown() else {
                cancelTermination(sender, message: "Could not save every repository before shutting down Codex.")
                return
            }
            dismissTerminationPanel()
            sender.reply(toApplicationShouldTerminate: true)
        }
    }

    private func cancelTermination(_ sender: NSApplication, message: String) {
        dismissTerminationPanel()
        windowManager?.cancelApplicationTermination()
        applicationModel.allCoordinators.forEach { $0.cancelClosePreparation() }
        applicationModel.applicationError = message
        isTerminating = false
        sender.reply(toApplicationShouldTerminate: false)
    }

    private func dismissTerminationPanel() {
        guard let panel = terminationPanel else { return }
        if let parent = terminationParentWindow, parent.attachedSheet === panel {
            parent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
        terminationPanel = nil
        terminationParentWindow = nil
    }

    private func terminationPresentationWindow() -> NSWindow? {
        NSApp.keyWindow
            ?? windowManager?.repositoryWindows
                .compactMap(\.window)
                .first
    }

    private func makeTerminationProgressPanel(coordinators: [RepositoryCoordinator]) -> NSPanel {
        let hostingController = NSHostingController(
            rootView: ApplicationPauseProgressView(coordinators: coordinators)
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Pausing Codeness"
        panel.contentViewController = hostingController
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct ApplicationPauseProgressView: View {
    let coordinators: [RepositoryCoordinator]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Pausing repositories before quitting…")
                    .font(.headline)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(coordinators, id: \.record.id) { coordinator in
                    HStack(spacing: 8) {
                        Image(systemName: statusSymbol(for: coordinator.pauseState))
                            .foregroundStyle(statusColor(for: coordinator.pauseState))
                            .frame(width: 16)
                        Text(coordinator.repositoryName)
                            .lineLimit(1)
                        Spacer()
                        Text(coordinator.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Interrupt Remaining Now") {
                    for coordinator in coordinators {
                        Task { await coordinator.interruptCloseWait() }
                    }
                }
                .help("Interrupt agents still reaching checkpoints so Codeness can finish quitting")
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func statusSymbol(for state: DocumentPauseState) -> String {
        switch state {
        case .paused: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "clock"
        }
    }

    private func statusColor(for state: DocumentPauseState) -> Color {
        switch state {
        case .paused: .green
        case .failed: .red
        default: .secondary
        }
    }
}
