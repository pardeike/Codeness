import CodenessCore
import SwiftUI

struct ActivityConfigurationView: View {
    let coordinator: RepositoryCoordinator

    @Environment(CodenessApplicationModel.self) private var application
    @State private var goal: String
    @State private var prompts: ActivityPrompts
    @State private var showsAdvancedPrompts = false
    @State private var isTestingHandoff = false
    @State private var handoffTestMessage: String?
    @State private var handoffTestSucceeded = false

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

                    GroupBox("Models") {
                        HStack {
                            Text(modelSummary)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }

                    DisclosureGroup(isExpanded: $showsAdvancedPrompts) {
                        PromptTemplateFields(prompts: $prompts)
                            .padding(.top, 14)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Advanced Prompt Templates")
                                .font(.headline)
                            Text("The supplied defaults are ready for normal activities.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

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
                if let handoffTestMessage {
                    Label(
                        handoffTestMessage,
                        systemImage: handoffTestSucceeded
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(handoffTestSucceeded ? .green : .red)
                    .lineLimit(2)
                } else {
                    Text("The Goal can be amended later whenever the workflow is paused.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Test Handoff") {
                    Task { await testHandoffConfiguration() }
                }
                .disabled(isTestingHandoff)
                .help("Verify handoff credentials and model access before starting an implementation turn")
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

    private var modelSummary: String {
        let settings = coordinator.record.settings
        let phases = [
            ("Implement", displayName(for: settings.implementer.model)),
            ("Review", displayName(for: settings.reviewer.model)),
            ("Fix", displayName(for: settings.fixer.model))
        ]
        var groups: [(model: String, phases: [String])] = []
        for (phase, model) in phases {
            if let index = groups.firstIndex(where: { $0.model == model }) {
                groups[index].phases.append(phase)
            } else {
                groups.append((model, [phase]))
            }
        }
        return groups.map { group in
            "\(joinedPhases(group.phases)): \(group.model)"
        }
        .joined(separator: " · ")
    }

    private func joinedPhases(_ phases: [String]) -> String {
        guard let last = phases.last else { return "" }
        if phases.count == 1 { return last }
        if phases.count == 2 { return phases.joined(separator: " and ") }
        return phases.dropLast().joined(separator: ", ") + ", and " + last
    }

    private func displayName(for identifier: String) -> String {
        application.models.first(where: { $0.model == identifier })?.displayName ?? identifier
    }

    private func testHandoffConfiguration() async {
        isTestingHandoff = true
        defer { isTestingHandoff = false }
        do {
            try await coordinator.testHandoffConfiguration(coordinator.record.settings.relay)
            handoffTestSucceeded = true
            handoffTestMessage = "Handoff configuration verified"
        } catch {
            handoffTestSucceeded = false
            handoffTestMessage = error.localizedDescription
        }
    }
}
