import CodenessCore
import SwiftUI

struct ActivityConfigurationView: View {
    let coordinator: RepositoryCoordinator

    @Environment(CodenessApplicationModel.self) private var application
    @State private var goal: String

    init(
        coordinator: RepositoryCoordinator,
        suggestedGoal: String
    ) {
        self.coordinator = coordinator
        _goal = State(initialValue: suggestedGoal)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Goal")
                    .font(.title2.weight(.semibold))

                ActivityTextEditor(
                    text: $goal,
                    minHeight: 240,
                    accessibilityLabel: "Goal",
                    helpText: "Describe the result Codeness should accomplish.",
                    placeholder: "Describe the result you want."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let message = application.liveTeamAvailabilityMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            HStack {
                Spacer()
                if coordinator.isStartingActivity {
                    ProgressView()
                        .controlSize(.small)
                        .help("Codeness is preparing the work")
                }
                Button("Start") {
                    Task { await coordinator.startActivity(goal: goal) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Save the goal and prepare the work")
                .disabled(
                    goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !coordinator.canStartActivity
                        || !application.canStartLiveTeamActivity
                )
            }
            .padding(14)
        }
        .onChange(of: goal) { _, _ in
            coordinator.updateActivityDraft(goal: goal)
        }
    }

}
