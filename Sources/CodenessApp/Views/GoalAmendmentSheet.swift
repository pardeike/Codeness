import CodenessCore
import SwiftUI

struct GoalAmendmentSheet: View {
    let coordinator: RepositoryCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var revisedGoal: String
    @State private var isSaving = false

    init(coordinator: RepositoryCoordinator) {
        self.coordinator = coordinator
        _revisedGoal = State(initialValue: coordinator.goalForAmendment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Goal")
                .font(.title2.weight(.semibold))
            Text(amendmentExplanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ActivityTextEditor(
                text: $revisedGoal,
                minHeight: 260,
                accessibilityLabel: "Goal",
                helpText: "Edit the goal Codeness uses for subsequent work."
            )

            if coordinator.hasPendingGoalAmendment {
                Label(
                    "A goal change is already queued; saving replaces it.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let amendments = coordinator.activity?.goalAmendments, !amendments.isEmpty {
                Text(
                    "\(amendments.count) earlier goal change"
                        + "\(amendments.count == 1 ? "" : "s") recorded"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(saveButtonTitle) {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        if await coordinator.amendGoal(revisedGoal) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isSaving
                        || revisedGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || revisedGoal.trimmingCharacters(in: .whitespacesAndNewlines)
                            == coordinator.goalForAmendment
                )
            }
        }
        .padding(20)
        .frame(width: 680, height: 470)
    }

    private var amendmentExplanation: String {
        if coordinator.goalAmendmentWillBeDeferred {
            return "The active turn keeps its current assignment. Codeness applies this goal change between turns, then adjusts the working goal and agents. The previous text and activation time remain in the activity history."
        }
        if coordinator.activity?.status == .completed {
            return "This activity is complete, so the changed goal will be prefilled when you choose Start Over. Codeness keeps the previous text and timestamp in the archived activity history."
        }
        return "The changed goal takes effect immediately, and Codeness reviews the current strategy against it. The previous text and timestamp remain in the activity history."
    }

    private var saveButtonTitle: String {
        coordinator.goalAmendmentWillBeDeferred ? "Queue Goal Change" : "Save Goal"
    }
}
