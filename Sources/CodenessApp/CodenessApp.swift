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
                        Button(url.lastPathComponent) {
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
    }
}
