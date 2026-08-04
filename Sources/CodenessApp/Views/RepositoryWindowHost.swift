import CodenessCore
import SwiftUI

struct RepositoryWindowHost: View {
    let coordinator: RepositoryCoordinator
    let appearanceState: RepositoryWindowAppearanceState

    var body: some View {
        Group {
            if coordinator.isLoaded {
                RepositoryWindowView(
                    coordinator: coordinator,
                    appearanceState: appearanceState
                )
            } else if let error = coordinator.errorMessage {
                ContentUnavailableView {
                    Label("Could Not Load Repository", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        coordinator.clearError()
                        Task { await loadRepository() }
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Try loading this repository's saved Codeness state again")
                }
            } else {
                ProgressView("Loading repository…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .help("Codeness is loading this repository's saved activity and transcripts")
            }
        }
        .environment(\.appearsActive, appearanceState.appearsActive)
        .task(id: coordinator.record.canonicalPath) {
            await loadRepository()
        }
    }

    private func loadRepository() async {
        await coordinator.load()
    }
}
