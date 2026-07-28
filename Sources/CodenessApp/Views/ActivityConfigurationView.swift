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
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Configure Activity")
                            .font(.largeTitle.weight(.semibold))
                        Text("Define the outcome and choose how Codeness should work through it.")
                            .foregroundStyle(.secondary)
                    }

                    goalSection

                    workflowSection

                    validationNotice
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
        .sheet(isPresented: $showsWorkflowEditor) {
            WorkflowEditorSheet(
                title: "Customize Activity Workflow",
                subtitle: "Changes apply only to this activity. Reusable workflows in Codeness Settings are not modified.",
                confirmationTitle: "Use Workflow",
                confirmationHelp: "Use this customized workflow for the activity",
                workflow: workflow
            ) { updatedWorkflow in
                workflow = updatedWorkflow
            }
            .environment(application)
        }
        .onChange(of: goal) { _, _ in
            coordinator.updateActivityDraft(goal: goal, workflow: workflow)
        }
        .onChange(of: workflow) { _, _ in
            coordinator.updateActivityDraft(goal: goal, workflow: workflow)
        }
    }

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(
                "Goal",
                description: "Describe the outcome or point to a specification. Every workflow step receives this text."
            )
            ActivityTextEditor(
                text: $goal,
                minHeight: 160,
                accessibilityLabel: "Goal",
                helpText: "Edit the full goal supplied to every workflow step.",
                placeholder: "For example: Implement the specification in Docs/Feature.md, including its test requirements."
            )
        }
    }

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(
                "Workflow",
                description: "Choose a reusable workflow or customize a private copy for this activity."
            )

            HStack(spacing: 10) {
                Picker("Workflow", selection: workflowSelection) {
                    ForEach(application.workflowCatalog.templates) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                .labelsHidden()
                .frame(width: 250, alignment: .leading)

                Button("Customize…") {
                    showsWorkflowEditor = true
                }
                .buttonStyle(.bordered)
                .help("Edit this activity's workflow in the workflow editor")

                if isWorkflowCustomized {
                    Button("Reset") {
                        restoreSelectedWorkflow()
                    }
                    .help("Discard activity-only changes and restore the selected reusable workflow")
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(workflow.summary)
                    .foregroundStyle(.secondary)
                ForEach(workflowComposition, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(row.steps)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var validationNotice: some View {
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

    private func sectionHeading(
        _ title: String,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var isWorkflowCustomized: Bool {
        guard let reusableWorkflow = application.workflowCatalog.template(id: workflow.id) else {
            return true
        }
        return reusableWorkflow != workflow
    }

    private var workflowComposition: [(label: String, steps: String)] {
        WorkflowSection.allCases.compactMap { section -> String? in
            let steps = workflow.steps(in: section)
            guard !steps.isEmpty else { return nil }
            return steps.map(\.name).joined(separator: " → ")
        }
        .enumerated()
        .map { index, steps in
            let populatedSections = WorkflowSection.allCases.filter {
                !workflow.steps(in: $0).isEmpty
            }
            return (
                label: populatedSections[index].displayName,
                steps: steps
            )
        }
    }

    private func restoreSelectedWorkflow() {
        guard let reusableWorkflow = application.workflowCatalog.template(id: workflow.id) else {
            return
        }
        workflow = reusableWorkflow
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
