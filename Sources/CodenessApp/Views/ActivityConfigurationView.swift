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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("What should Codeness accomplish?")
                        .font(.largeTitle.weight(.semibold))

                    ActivityTextEditor(
                        text: $goal,
                        minHeight: 240,
                        accessibilityLabel: "Goal",
                        helpText: "Describe the complete outcome, requirements, and authority granted to Codeness.",
                        placeholder: "For example: Implement the specification in Docs/Feature.md, including its validation requirements."
                    )

                    Text("Include any provider, model, cost, or session limits that Codeness must follow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let message = application.liveTeamAvailabilityMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity)
            }

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
