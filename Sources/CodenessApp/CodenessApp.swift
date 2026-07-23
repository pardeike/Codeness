import AppKit
import CodenessCore
import SwiftUI

@main
struct CodenessApp: App {
    @NSApplicationDelegateAdaptor(CodenessAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Codeness", id: "lifecycle") {
            EmptyView()
        }
        .defaultLaunchBehavior(.suppressed)
        .commands {
            RepositoryWindowCommands(appDelegate: appDelegate, state: appDelegate.commandState)
        }

        Settings {
            ApplicationSettingsView(application: appDelegate.applicationModel)
        }
    }
}

private struct RepositoryWindowCommands: Commands {
    let appDelegate: CodenessAppDelegate
    let state: RepositoryWindowCommandState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") {
                appDelegate.openRepository()
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Choose a repository folder and open it in a Codeness window")

            Menu("Open Recent") {
                if state.recentURLs.isEmpty {
                    Text("No Recent Repositories")
                } else {
                    ForEach(state.recentURLs, id: \.path) { url in
                        Button(url.repositoryMenuTitle) {
                            appDelegate.openRecentRepository(url)
                        }
                        .help(url.path)
                    }
                    Divider()
                    Button("Clear Menu") {
                        appDelegate.clearRecentRepositories()
                    }
                    .help("Remove every repository from the Open Recent menu")
                }
            }
            .help("Open a recently used repository")

            Divider()
            Button("Close") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: .command)
            .help("Close the active repository window")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                appDelegate.saveCurrentRepository()
            }
            .keyboardShortcut("s", modifiers: .command)
            .help("Persist the active repository's Codeness state")
        }

        CommandGroup(replacing: .printItem) {
            EmptyView()
        }

        CommandMenu("Repository") {
            Button("Copy Repository Path") {
                guard let path = state.currentCoordinator?.record.canonicalPath else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            .disabled(state.currentCoordinator == nil)

            Button("Reveal Repository in Finder") {
                guard let path = state.currentCoordinator?.record.canonicalPath else { return }
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: path, isDirectory: true)
                ])
            }
            .disabled(state.currentCoordinator == nil)

            Divider()

            Button("Amend Goal…") {
                state.requestGoalAmendment()
            }
            .disabled(state.currentCoordinator?.canAmendGoal != true)
        }

        CommandMenu("Workflow") {
            Button(resumeOrPauseTitle) {
                guard let coordinator = state.currentCoordinator else { return }
                if coordinator.canResume {
                    Task { await coordinator.resume() }
                } else if coordinator.activeActivity != nil {
                    coordinator.setPauseAfterCurrent(!coordinator.pauseAfterCurrent)
                }
            }
            .keyboardShortcut(.space, modifiers: [.command, .option])
            .disabled(!canResumeOrPause)

            Button("Steer Active Turn…") {
                state.requestSteerFocus()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(state.currentCoordinator?.canInterrupt != true)

            Button("Interrupt Active Turn") {
                guard let coordinator = state.currentCoordinator else { return }
                Task { await coordinator.interrupt() }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(state.currentCoordinator?.canInterrupt != true)

            Divider()

            Button("Jump to Live Run") {
                state.currentCoordinator?.selectLiveRun()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(!canJumpToLive)

            Divider()

            Button("Start Over…") {
                state.requestStartOver()
            }
            .disabled(state.currentCoordinator?.canStartOver != true)
        }
    }

    private var canResumeOrPause: Bool {
        guard let coordinator = state.currentCoordinator else { return false }
        return coordinator.canResume || coordinator.activeActivity != nil
    }

    private var resumeOrPauseTitle: String {
        guard let coordinator = state.currentCoordinator else { return "Resume Automatically" }
        if coordinator.canResume {
            return "Resume Automatically"
        }
        return coordinator.pauseAfterCurrent ? "Keep Running Automatically" : "Pause After Current"
    }

    private var canJumpToLive: Bool {
        guard let coordinator = state.currentCoordinator,
              let liveRunID = coordinator.liveRunID else { return false }
        return coordinator.selectedRunID != liveRunID
    }
}
