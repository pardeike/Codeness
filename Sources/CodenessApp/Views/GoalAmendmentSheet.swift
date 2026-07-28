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
            Text("Amend Goal")
                .font(.title2.weight(.semibold))
            Text(amendmentExplanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ActivityTextEditor(
                text: $revisedGoal,
                minHeight: 260,
                accessibilityLabel: "Revised Goal",
                helpText: "Revise THE GOAL used by subsequent workflow phases."
            )

            if coordinator.hasPendingGoalAmendment {
                Label(
                    "A goal change is already queued; saving replaces that queued revision.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let amendments = coordinator.activity?.goalAmendments, !amendments.isEmpty {
                Text(
                    "\(amendments.count) earlier goal amendment"
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
            return "The active turn keeps the Goal it started with. Codeness queues this revision, activates it at the earliest durable boundary, and uses it for the next handoff or workflow step. The previous text and activation time remain in the activity history."
        }
        if coordinator.activity?.status == .completed {
            return "This activity is complete, so the revised Goal will be prefilled when you choose Start Over. Codeness keeps the previous text and timestamp in the archived activity history."
        }
        return "The revised Goal takes effect immediately and is supplied to subsequent workflow steps. Codeness keeps the previous text and timestamp in the activity history."
    }

    private var saveButtonTitle: String {
        coordinator.goalAmendmentWillBeDeferred ? "Queue Goal Change" : "Save Amendment"
    }
}
