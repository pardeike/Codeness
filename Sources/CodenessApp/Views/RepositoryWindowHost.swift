import CodenessCore
import SwiftUI

struct RepositoryWindowHost: View {
    let coordinator: RepositoryCoordinator

    var body: some View {
        Group {
            if coordinator.isLoaded {
                RepositoryWindowView(coordinator: coordinator)
            } else if let error = coordinator.errorMessage {
                ContentUnavailableView {
                    Label("Could Not Load Repository", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        coordinator.clearError()
                        Task { await coordinator.load() }
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
        .task(id: coordinator.record.canonicalPath) {
            await coordinator.load()
        }
    }
}
