import CodenessCore
import SwiftUI

struct WorkflowTemplateFields: View {
    @Binding var workflow: WorkflowTemplate
    var allowsDefinitionEditing = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if allowsDefinitionEditing {
                LabeledContent("Name") {
                    TextField("Workflow name", text: $workflow.name)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Summary") {
                    TextField("What this workflow does", text: $workflow.summary, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }
            }

            ForEach(WorkflowSection.allCases, id: \.self) { section in
                workflowSection(section)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Filters each completed step into a concise handoff. Its completion verdict is used only after the last repeating step.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    WorkflowTargetFields(
                        title: "Coordinator",
                        target: $workflow.coordinator.target
                    )
                    if allowsDefinitionEditing {
                        ActivityTextEditor(
                            text: $workflow.coordinator.instructions,
                            minHeight: 100,
                            accessibilityLabel: "Coordinator instructions",
                            helpText: "Edit the instructions used to filter handoffs and decide whether the repeating loop is complete."
                        )
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Text("Handoff Coordinator")
                    .font(.headline)
            }
        }
    }

    @ViewBuilder
    private func workflowSection(_ section: WorkflowSection) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(sectionDescription(section))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let indices = workflow.steps.indices.filter {
                    workflow.steps[$0].section == section
                }
                if indices.isEmpty {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            Color.secondary.opacity(0.35),
                            style: StrokeStyle(
                                lineWidth: 1,
                                dash: [4, 3]
                            )
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                        .accessibilityElement()
                        .accessibilityLabel(
                            "\(section.displayName) has no steps"
                        )
                }
                ForEach(indices, id: \.self) { index in
                    stepEditor(index: index, sectionIndices: indices)
                    if index != indices.last {
                        Divider()
                    }
                }

                if allowsDefinitionEditing {
                    Button {
                        addStep(to: section)
                    } label: {
                        Label("Add \(section == .loop ? "Repeating" : section.displayName) Step", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add another step to \(section.displayName.lowercased())")
                }
            }
            .padding(.vertical, 4)
        } label: {
            Text(section.displayName)
                .font(.headline)
        }
    }

    private func stepEditor(index: Int, sectionIndices: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if allowsDefinitionEditing {
                    TextField("Step name", text: binding(for: index).name)
                        .font(.headline)
                        .textFieldStyle(.roundedBorder)
                    Spacer()
                    Button {
                        moveStep(index: index, direction: -1, sectionIndices: sectionIndices)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == sectionIndices.first)
                    .help("Move this step earlier")
                    Button {
                        moveStep(index: index, direction: 1, sectionIndices: sectionIndices)
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == sectionIndices.last)
                    .help("Move this step later")
                    Button(role: .destructive) {
                        workflow.steps.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this workflow step")
                } else {
                    Text(workflow.steps[index].name)
                        .font(.headline)
                }
            }

            if allowsDefinitionEditing {
                ActivityTextEditor(
                    text: binding(for: index).instructions,
                    minHeight: 105,
                    accessibilityLabel: "\(workflow.steps[index].name) instructions",
                    helpText: "Edit the instructions supplied whenever this step runs."
                )
            } else {
                Text(workflow.steps[index].instructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            WorkflowTargetFields(
                title: workflow.steps[index].name,
                target: binding(for: index).target
            )
        }
    }

    private func binding(for index: Int) -> Binding<WorkflowStep> {
        Binding(
            get: { workflow.steps[index] },
            set: { workflow.steps[index] = $0 }
        )
    }

    private func addStep(to section: WorkflowSection) {
        let baseTarget = workflow.steps.last?.target ?? workflow.coordinator.target
        let identifier = uniqueStepID(base: "step")
        let step = WorkflowStep(
            id: identifier,
            name: "New Step",
            section: section,
            instructions: "Describe what this step should accomplish and where it should stop.",
            target: baseTarget
        )
        if let lastIndex = workflow.steps.lastIndex(where: { $0.section == section }) {
            workflow.steps.insert(step, at: lastIndex + 1)
        } else {
            workflow.steps.append(step)
        }
    }

    private func moveStep(index: Int, direction: Int, sectionIndices: [Int]) {
        guard let position = sectionIndices.firstIndex(of: index) else { return }
        let destinationPosition = position + direction
        guard sectionIndices.indices.contains(destinationPosition) else { return }
        workflow.steps.swapAt(index, sectionIndices[destinationPosition])
    }

    private func uniqueStepID(base: String) -> String {
        let existing = Set(workflow.steps.map(\.id))
        var candidate = base
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func sectionDescription(_ section: WorkflowSection) -> String {
        switch section {
        case .prefix:
            "Runs once before the repeating loop. A read-only Plan step fits here."
        case .loop:
            "Runs every step in order, then asks the coordinator whether to repeat or finish."
        case .postfix:
            "Runs once after the coordinator declares the loop complete."
        }
    }
}

struct WorkflowTargetFields: View {
    let title: String
    @Binding var target: AgentTarget

    @Environment(CodenessApplicationModel.self) private var application

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Provider")
                    Picker("Provider", selection: $target.providerID) {
                        ForEach(application.providerCatalog.providers) { provider in
                            Text(application.providerName(provider.id)).tag(provider.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("Model")
                    HStack(spacing: 6) {
                        TextField("Model ID or alias", text: $target.model)
                            .textFieldStyle(.roundedBorder)
                        Menu {
                            ForEach(knownModels) { model in
                                Button(model.displayName) {
                                    target.model = model.id
                                    let effort = target.options.effort?
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                    if effort?.isEmpty != false
                                        || !model.supportedEfforts.contains(effort ?? "") {
                                        target.options.effort = model.defaultEffort
                                    }
                                }
                                .help(model.description)
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .disabled(knownModels.isEmpty)
                        .help("Choose a known model, or type any full model identifier")
                    }
                }
                GridRow {
                    Text("Effort")
                    HStack(spacing: 6) {
                        TextField(
                            "Provider default",
                            text: Binding(
                                get: { target.options.effort ?? "" },
                                set: { target.options.effort = $0.isEmpty ? nil : $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        Menu {
                            ForEach(knownEfforts, id: \.self) { effort in
                                Button(effort) { target.options.effort = effort }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .disabled(knownEfforts.isEmpty)
                    }
                }
                GridRow {
                    Text("Options")
                    HStack(spacing: 18) {
                        Toggle("Plan", isOn: planModeBinding)
                        Toggle("Fast", isOn: fastModeBinding)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .font(.caption)

            if target.options.mode == .plan {
                Label("Native read-only Plan mode", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let compatibilityMessage = application.targetCompatibilityMessage(target) {
                Label(
                    compatibilityMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if !application.isProviderReady(target.providerID) {
                Label(
                    "\(application.providerName(target.providerID)) is not currently available.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) agent target")
    }

    private var knownModels: [AgentModelDescriptor] {
        application.models(for: target.providerID)
    }

    private var selectedModel: AgentModelDescriptor? {
        knownModels.first { $0.id == target.model }
    }

    private var knownEfforts: [String] {
        selectedModel?.supportedEfforts ?? []
    }

    private var planModeBinding: Binding<Bool> {
        Binding(
            get: { target.options.mode == .plan },
            set: { target.options.mode = $0 ? .plan : .standard }
        )
    }

    private var fastModeBinding: Binding<Bool> {
        Binding(
            get: { target.options.speed == .fast },
            set: { target.options.speed = $0 ? .fast : .standard }
        )
    }

}
