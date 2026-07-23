import CodenessCore
import SwiftUI

struct GoalAmendmentSheet: View {
    let coordinator: RepositoryCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var revisedGoal: String
    @State private var isSaving = false

    init(coordinator: RepositoryCoordinator) {
        self.coordinator = coordinator
        _revisedGoal = State(initialValue: coordinator.activity?.goal ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Amend Goal")
                .font(.title2.weight(.semibold))
            Text("The revised Goal is supplied to subsequent Implement, Review, and Fix turns. Codeness keeps the previous text and timestamp in the activity history.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ActivityTextEditor(
                text: $revisedGoal,
                minHeight: 260,
                accessibilityLabel: "Revised Goal",
                helpText: "Revise THE GOAL used by subsequent workflow phases."
            )

            if let amendments = coordinator.activity?.goalAmendments, !amendments.isEmpty {
                Text("\(amendments.count) earlier goal amendment\(amendments.count == 1 ? "" : "s") recorded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Amendment") {
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
                            == coordinator.activity?.goal
                )
            }
        }
        .padding(20)
        .frame(width: 680, height: 470)
    }
}
