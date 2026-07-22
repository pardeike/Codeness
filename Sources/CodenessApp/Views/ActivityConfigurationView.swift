import CodenessCore
import SwiftUI

struct ActivityConfigurationView: View {
    let coordinator: RepositoryCoordinator

    @Environment(CodenessApplicationModel.self) private var application
    @State private var goal: String
    @State private var prompts: ActivityPrompts

    init(
        coordinator: RepositoryCoordinator,
        suggestedGoal: String,
        suggestedPrompts: ActivityPrompts
    ) {
        self.coordinator = coordinator
        _goal = State(initialValue: suggestedGoal)
        _prompts = State(initialValue: suggestedPrompts)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Configure Activity")
                            .font(.largeTitle.weight(.semibold))
                        Text("Set the goal and phase prompts for this repository. Starting creates a fresh implementer/reviewer session pair.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Goal")
                            .font(.headline)
                        Text("Describe the intended outcome, point the agents to a specification file or folder, add direct instructions, or combine all three. Codeness supplies this entire text to every phase as THE GOAL.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ActivityTextEditor(
                            text: $goal,
                            minHeight: 140,
                            accessibilityLabel: "Goal",
                            helpText: "Edit THE GOAL supplied to the Implement, Review, and Fix phases.",
                            placeholder: "For example: Implement the specification in Docs/Feature.md, including its test requirements."
                        )
                    }

                    PromptTemplateFields(prompts: $prompts)

                    if let validationMessage = prompts.validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity)
            }

            Divider()
            HStack {
                Text("The Goal and prompts become read-only when the activity starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if coordinator.isStartingActivity {
                    ProgressView()
                        .controlSize(.small)
                        .help("Codeness is starting the first Implement pass")
                }
                Button("Start") {
                    Task {
                        await coordinator.startActivity(goal: goal, prompts: prompts)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Start this activity and begin its first Implement pass")
                .disabled(
                    goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || prompts.validationMessage != nil
                        || !coordinator.canStartActivity
                        || !application.isReady
                )
            }
            .padding(14)
        }
        .onChange(of: goal) { _, _ in
            coordinator.updateActivityDraft(goal: goal, prompts: prompts)
        }
        .onChange(of: prompts) { _, _ in
            coordinator.updateActivityDraft(goal: goal, prompts: prompts)
        }
    }
}
