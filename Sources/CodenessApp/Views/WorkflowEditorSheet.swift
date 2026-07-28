import CodenessCore
import SwiftUI

struct WorkflowEditorSheet: View {
    let title: String
    let subtitle: String
    let confirmationTitle: String
    let confirmationHelp: String
    let onApply: (WorkflowTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workflow: WorkflowTemplate
    @State private var selection: WorkflowEditorSelection?

    init(
        title: String,
        subtitle: String = "Apply updates the staged workflows. Use Save in Codeness Settings to make them permanent.",
        confirmationTitle: String,
        confirmationHelp: String = "Apply this workflow to the staged workflows in Settings",
        workflow: WorkflowTemplate,
        onApply: @escaping (WorkflowTemplate) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.confirmationTitle = confirmationTitle
        self.confirmationHelp = confirmationHelp
        self.onApply = onApply
        _workflow = State(initialValue: workflow)
        _selection = State(initialValue: .overview)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            HSplitView {
                sidebar
                    .frame(
                        minWidth: 220,
                        idealWidth: 250,
                        maxWidth: 290,
                        maxHeight: .infinity
                    )

                detail
                    .frame(
                        minWidth: 650,
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
            }

            Divider()

            HStack(spacing: 10) {
                if let validationMessage = workflow.validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .help("Discard changes made in this workflow editor")
                Button(confirmationTitle) {
                    onApply(workflow)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(workflow.validationMessage != nil)
                .help(confirmationHelp)
            }
            .padding(14)
        }
        .frame(width: 940, height: 720)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Workflow") {
                    Label("Overview", systemImage: "doc.text")
                        .tag(WorkflowEditorSelection.overview)
                    Label("Coordinator", systemImage: "arrow.triangle.branch")
                        .tag(WorkflowEditorSelection.coordinator)
                }

                Divider()
                    .padding(.vertical, 8)
                    .accessibilityHidden(true)

                Section("Steps") {
                    ForEach(WorkflowSection.allCases, id: \.self) { section in
                        let steps = workflow.steps(in: section)
                        HStack(spacing: 6) {
                            Text(section.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                        }
                        .padding(.top, section == WorkflowSection.allCases.first ? 0 : 6)

                        ForEach(steps) { step in
                            HStack(spacing: 8) {
                                Label(
                                    step.name,
                                    systemImage: stepIcon(for: section)
                                )
                                Spacer()
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                            .tag(WorkflowEditorSelection.step(step.id))
                            .draggable(step.id)
                            .dropDestination(for: String.self) {
                                stepIDs,
                                location in
                                moveDraggedStep(
                                    stepIDs.first,
                                    to: section,
                                    relativeTo: step.id,
                                    placeAfter: location.y > 16
                                )
                            }
                        }

                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.secondary.opacity(0.10))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .overlay {
                                addStepButton(for: section)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .dropDestination(for: String.self) {
                                stepIDs,
                                _ in
                                moveDraggedStep(
                                    stepIDs.first,
                                    to: section,
                                    relativeTo: nil,
                                    placeAfter: true
                                )
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(
                                "Add a step to \(section.displayName.lowercased())"
                            )
                            .accessibilityHint(
                                "Drop a step here or use the plus button"
                            )
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Workflow structure")

        }
        .background(.quaternary.opacity(0.22))
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            ScrollView {
                overviewDetail
                    .detailPaneLayout()
            }
        case let .step(stepID):
            ScrollView {
                stepDetail(stepID: stepID)
                    .detailPaneLayout()
            }
        case .coordinator:
            ScrollView {
                coordinatorDetail
                    .detailPaneLayout()
            }
        }
    }

    private var overviewDetail: some View {
        VStack(alignment: .leading, spacing: 20) {
            detailHeading(
                "Overview",
                description: "Name and describe the reusable workflow."
            )

            LabeledContent("Name") {
                TextField("Workflow name", text: $workflow.name)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Summary") {
                TextField(
                    "What this workflow does",
                    text: $workflow.summary,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Structure")
                    .font(.headline)
                Text(structureSummary)
                    .foregroundStyle(.secondary)
                Text("Choose a step or the coordinator in the sidebar to edit its instructions and agent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func stepDetail(stepID: String) -> some View {
        if let index = workflow.steps.firstIndex(where: { $0.id == stepID }) {
            let step = workflow.steps[index]
            let stepBinding = binding(for: step)
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(sectionDescription(step.section))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Button {
                            moveStep(stepID: stepID, direction: -1)
                        } label: {
                            Label("Earlier", systemImage: "arrow.up")
                        }
                        .disabled(!canMoveStep(stepID: stepID, direction: -1))
                        .help("Move this step earlier")

                        Button {
                            moveStep(stepID: stepID, direction: 1)
                        } label: {
                            Label("Later", systemImage: "arrow.down")
                        }
                        .disabled(!canMoveStep(stepID: stepID, direction: 1))
                        .help("Move this step later")

                        Button(role: .destructive) {
                            deleteStep(stepID: stepID)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .help("Remove this workflow step")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                LabeledContent("Name") {
                    TextField("Step name", text: stepBinding.name)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Stage") {
                    Picker("Stage", selection: stepBinding.section) {
                        ForEach(WorkflowSection.allCases, id: \.self) { section in
                            Text(section.displayName).tag(section)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Instructions")
                        .font(.headline)
                    ActivityTextEditor(
                        text: stepBinding.instructions,
                        minHeight: 190,
                        accessibilityLabel: "\(step.name) instructions",
                        helpText: "Edit the instructions supplied whenever this step runs."
                    )
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Agent")
                        .font(.headline)
                    WorkflowTargetFields(
                        title: step.name,
                        target: stepBinding.target
                    )
                }
            }
        } else {
            ContentUnavailableView(
                "Step Not Found",
                systemImage: "exclamationmark.triangle",
                description: Text("Choose another item in the workflow structure.")
            )
        }
    }

    private func addStepButton(for section: WorkflowSection) -> some View {
        Button {
            addStep(to: section)
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Add \(section.displayName) Step")
        .help("Add a step to \(section.displayName.lowercased())")
    }

    private var coordinatorDetail: some View {
        VStack(alignment: .leading, spacing: 20) {
            detailHeading(
                "Handoff Coordinator",
                description: "Filters each completed step into a concise handoff and decides whether the workflow is complete after its repeating loop."
            )

            VStack(alignment: .leading, spacing: 7) {
                Text("Instructions")
                    .font(.headline)
                ActivityTextEditor(
                    text: $workflow.coordinator.instructions,
                    minHeight: 190,
                    accessibilityLabel: "Coordinator instructions",
                    helpText: "Edit the instructions used to filter handoffs and decide whether the repeating loop is complete."
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Agent")
                    .font(.headline)
                WorkflowTargetFields(
                    title: "Coordinator",
                    target: $workflow.coordinator.target
                )
            }
        }
    }

    private func detailHeading(
        _ title: String,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var structureSummary: String {
        WorkflowSection.allCases.compactMap { section -> String? in
            let count = workflow.steps(in: section).count
            guard count > 0 else { return nil }
            return "\(section.displayName): \(count)"
        }
        .joined(separator: "  ·  ")
    }

    private func binding(for fallback: WorkflowStep) -> Binding<WorkflowStep> {
        Binding(
            get: {
                workflow.steps.first(where: { $0.id == fallback.id }) ?? fallback
            },
            set: { updatedStep in
                updateStep(updatedStep, replacing: fallback.id)
            }
        )
    }

    private func updateStep(
        _ updatedStep: WorkflowStep,
        replacing stepID: String
    ) {
        guard let index = workflow.steps.firstIndex(where: { $0.id == stepID })
        else { return }
        let previousSection = workflow.steps[index].section
        guard previousSection != updatedStep.section else {
            workflow.steps[index] = updatedStep
            return
        }

        workflow.steps.remove(at: index)
        let destination = insertionIndex(for: updatedStep.section)
        workflow.steps.insert(updatedStep, at: destination)
    }

    private func addStep(to section: WorkflowSection) {
        let baseTarget = workflow.steps.last?.target ?? workflow.coordinator.target
        let step = WorkflowStep(
            id: uniqueStepID(base: "step"),
            name: "New Step",
            section: section,
            instructions: "Describe what this step should accomplish and where it should stop.",
            target: baseTarget
        )
        workflow.steps.insert(step, at: insertionIndex(for: section))
        selection = .step(step.id)
    }

    private func deleteStep(stepID: String) {
        guard let index = workflow.steps.firstIndex(where: { $0.id == stepID })
        else { return }
        let section = workflow.steps[index].section
        let sectionStepIDs = workflow.steps(in: section).map(\.id)
        let position = sectionStepIDs.firstIndex(of: stepID)
        let replacementID = position.flatMap { position in
            if sectionStepIDs.indices.contains(position + 1) {
                return sectionStepIDs[position + 1]
            }
            if position > 0 {
                return sectionStepIDs[position - 1]
            }
            return nil
        }

        workflow.steps.remove(at: index)
        selection = replacementID.map(WorkflowEditorSelection.step) ?? .overview
    }

    private func moveStep(stepID: String, direction: Int) {
        guard let index = workflow.steps.firstIndex(where: { $0.id == stepID })
        else { return }
        let section = workflow.steps[index].section
        let sectionIndices = workflow.steps.indices.filter {
            workflow.steps[$0].section == section
        }
        guard let position = sectionIndices.firstIndex(of: index) else { return }
        let destinationPosition = position + direction
        guard sectionIndices.indices.contains(destinationPosition) else { return }
        workflow.steps.swapAt(index, sectionIndices[destinationPosition])
    }

    private func canMoveStep(stepID: String, direction: Int) -> Bool {
        guard let index = workflow.steps.firstIndex(where: { $0.id == stepID })
        else { return false }
        let section = workflow.steps[index].section
        let sectionIndices = workflow.steps.indices.filter {
            workflow.steps[$0].section == section
        }
        guard let position = sectionIndices.firstIndex(of: index) else { return false }
        return sectionIndices.indices.contains(position + direction)
    }

    private func moveDraggedStep(
        _ stepID: String?,
        to section: WorkflowSection,
        relativeTo targetStepID: String?,
        placeAfter: Bool
    ) -> Bool {
        guard let stepID,
              stepID != targetStepID,
              let sourceIndex = workflow.steps.firstIndex(where: {
                  $0.id == stepID
              }) else { return false }

        var movedStep = workflow.steps.remove(at: sourceIndex)
        movedStep.section = section

        if let targetStepID,
           let targetIndex = workflow.steps.firstIndex(where: {
               $0.id == targetStepID
           }) {
            workflow.steps.insert(
                movedStep,
                at: targetIndex + (placeAfter ? 1 : 0)
            )
        } else {
            workflow.steps.insert(
                movedStep,
                at: insertionIndex(for: section)
            )
        }
        selection = .step(stepID)
        return true
    }

    private func insertionIndex(for section: WorkflowSection) -> Int {
        if let lastIndex = workflow.steps.lastIndex(where: { $0.section == section }) {
            return lastIndex + 1
        }
        let sectionIndex = WorkflowSection.allCases.firstIndex(of: section) ?? 0
        return workflow.steps.firstIndex { step in
            let stepSectionIndex =
                WorkflowSection.allCases.firstIndex(of: step.section) ?? 0
            return stepSectionIndex > sectionIndex
        } ?? workflow.steps.endIndex
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

    private func stepIcon(for section: WorkflowSection) -> String {
        switch section {
        case .prefix: "arrow.right.to.line"
        case .loop: "repeat"
        case .postfix: "checkmark"
        }
    }

    private func sectionDescription(_ section: WorkflowSection) -> String {
        switch section {
        case .prefix:
            "Runs once before the repeating loop."
        case .loop:
            "Runs in order each time the workflow repeats."
        case .postfix:
            "Runs once after the coordinator declares the loop complete."
        }
    }
}

private enum WorkflowEditorSelection: Hashable {
    case overview
    case step(String)
    case coordinator
}

private extension View {
    func detailPaneLayout() -> some View {
        frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
