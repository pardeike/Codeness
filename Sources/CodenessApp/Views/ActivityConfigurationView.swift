import CodenessCore
import SwiftUI

struct ActivityConfigurationView: View {
    let coordinator: RepositoryCoordinator

    @Environment(CodenessApplicationModel.self) private var application
    @State private var goal: String
    @State private var workflow: WorkflowTemplate
    @State private var showsWorkflowEditor = false

    init(
        coordinator: RepositoryCoordinator,
        suggestedGoal: String,
        suggestedWorkflow: WorkflowTemplate
    ) {
        self.coordinator = coordinator
        _goal = State(initialValue: suggestedGoal)
        _workflow = State(initialValue: suggestedWorkflow)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Configure Activity")
                            .font(.largeTitle.weight(.semibold))
                        Text("Choose a reusable workflow, then adjust any step, agent, model, mode, or speed for this activity.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Goal")
                            .font(.headline)
                        Text("Describe the intended outcome, point the agents to a specification, or combine both. Codeness supplies this full text to every configured step.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ActivityTextEditor(
                            text: $goal,
                            minHeight: 140,
                            accessibilityLabel: "Goal",
                            helpText: "Edit the full goal supplied to every workflow step.",
                            placeholder: "For example: Implement the specification in Docs/Feature.md, including its test requirements."
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Workflow")
                            .font(.headline)
                        Picker("Workflow", selection: workflowSelection) {
                            ForEach(application.workflowCatalog.templates) { template in
                                Text(template.name).tag(template.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 420, alignment: .leading)
                        Text(workflow.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(workflowSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    DisclosureGroup(isExpanded: $showsWorkflowEditor) {
                        WorkflowTemplateFields(workflow: $workflow)
                            .padding(.top, 14)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Customize This Workflow")
                                .font(.headline)
                            Text("Changes here belong only to this activity draft. Edit the global library in Codeness Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let validationMessage = workflow.validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if let compatibilityMessage =
                        application.workflowCompatibilityMessage(workflow) {
                        Label(
                            compatibilityMessage,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    } else if !application.canRun(workflow) {
                        Label(
                            unavailableProvidersMessage,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity)
            }

            Divider()
            HStack {
                Text("The goal and future step targets remain editable whenever the workflow is paused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if coordinator.isStartingActivity {
                    ProgressView()
                        .controlSize(.small)
                        .help("Codeness is starting the first configured step")
                }
                Button("Start") {
                    Task {
                        await coordinator.startActivity(goal: goal, workflow: workflow)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Start this activity and run its first configured step")
                .disabled(
                    goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || workflow.validationMessage != nil
                        || application.workflowCompatibilityMessage(workflow) != nil
                        || !coordinator.canStartActivity
                        || !application.canRun(workflow)
                )
            }
            .padding(14)
        }
        .onChange(of: goal) { _, _ in
            coordinator.updateActivityDraft(goal: goal, workflow: workflow)
        }
        .onChange(of: workflow) { _, _ in
            coordinator.updateActivityDraft(goal: goal, workflow: workflow)
        }
    }

    private var workflowSelection: Binding<String> {
        Binding(
            get: { workflow.id },
            set: { identifier in
                guard let selected = application.workflowCatalog.template(id: identifier) else {
                    return
                }
                workflow = selected
            }
        )
    }

    private var workflowSummary: String {
        WorkflowSection.allCases.compactMap { section -> String? in
            let steps = workflow.steps(in: section)
            guard !steps.isEmpty else { return nil }
            let names = steps.map(\.name).joined(separator: " → ")
            return "\(section.displayName): \(names)"
        }
        .joined(separator: " · ")
    }

    private var unavailableProvidersMessage: String {
        let identifiers = Set(
            workflow.steps.map(\.target.providerID)
                + [workflow.coordinator.target.providerID]
        )
        let names = identifiers
            .filter { !application.isProviderReady($0) }
            .map(application.providerName)
            .sorted()
            .joined(separator: ", ")
        return "\(names.isEmpty ? "A required provider" : names) must be configured before this workflow can start."
    }
}
