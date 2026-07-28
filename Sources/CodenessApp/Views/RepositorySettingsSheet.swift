import CodenessCore
import Foundation
import SwiftUI

struct RepositorySettingsSheet: View {
    let coordinator: RepositoryCoordinator

    @Environment(CodenessApplicationModel.self) private var application
    @Environment(\.dismiss) private var dismiss
    @State private var settings: RepositorySettings
    @State private var workflow: WorkflowTemplate?
    @State private var selection: WorkflowPreferencesSelection?
    @State private var isTestingHandoff = false
    @State private var handoffTestMessage: String?
    @State private var handoffTestSucceeded = false
    @State private var isSaving = false

    init(coordinator: RepositoryCoordinator) {
        self.coordinator = coordinator
        _settings = State(initialValue: coordinator.record.settings)
        _workflow = State(initialValue: coordinator.record.activity?.workflow)
        _selection = State(initialValue: .overview)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if workflow != nil {
                workflowPreferences
            } else {
                legacyRepositorySettings
            }

            Divider()
            footer
        }
        .frame(width: workflow == nil ? 880 : 940, height: workflow == nil ? 680 : 720)
        .onChange(of: settings.relay) {
            handoffTestMessage = nil
            handoffTestSucceeded = false
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Workflow Preferences")
                    .font(.title2.weight(.semibold))
                Text(
                    workflow?.name
                        ?? "Model and handoff defaults for this repository"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if workflow != nil {
                Label(activityStatusTitle, systemImage: activityStatusIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(activityStatusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        activityStatusColor.opacity(0.12),
                        in: Capsule()
                    )
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let validationMessage {
                Label(
                    validationMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .help("Discard workflow-preference changes and close this sheet")
            Button {
                Task {
                    isSaving = true
                    defer { isSaving = false }
                    if await save() {
                        dismiss()
                    }
                }
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Save")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .help(saveHelp)
            .disabled(!canSave || isSaving)
        }
        .padding(14)
    }

    private var workflowPreferences: some View {
        HSplitView {
            workflowSidebar
                .frame(
                    minWidth: 220,
                    idealWidth: 250,
                    maxWidth: 290,
                    maxHeight: .infinity
                )

            workflowDetail
                .frame(
                    minWidth: 650,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
        }
    }

    private var workflowSidebar: some View {
        List(selection: $selection) {
            Section("Workflow") {
                Label("Overview", systemImage: "doc.text")
                    .tag(WorkflowPreferencesSelection.overview)
                Label("Coordinator", systemImage: "arrow.triangle.branch")
                    .tag(WorkflowPreferencesSelection.coordinator)
            }

            Divider()
                .padding(.vertical, 8)
                .accessibilityHidden(true)

            Section("Steps") {
                ForEach(WorkflowSection.allCases, id: \.self) { section in
                    let steps = workflow?.steps(in: section) ?? []
                    if !steps.isEmpty {
                        Text(section.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(
                                .top,
                                section == firstPopulatedSection ? 0 : 6
                            )
                            .accessibilityAddTraits(.isHeader)

                        ForEach(steps) { step in
                            Label(
                                step.name,
                                systemImage: stepIcon(for: section)
                            )
                            .tag(WorkflowPreferencesSelection.step(step.id))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Workflow preferences")
        .background(.quaternary.opacity(0.22))
    }

    @ViewBuilder
    private var workflowDetail: some View {
        switch selection ?? .overview {
        case .overview:
            ScrollView {
                overviewDetail
                    .workflowPreferencesDetailLayout()
            }
        case .coordinator:
            ScrollView {
                coordinatorDetail
                    .workflowPreferencesDetailLayout()
            }
        case let .step(stepID):
            ScrollView {
                stepDetail(stepID: stepID)
                    .workflowPreferencesDetailLayout()
            }
        }
    }

    @ViewBuilder
    private var overviewDetail: some View {
        if let workflow {
            VStack(alignment: .leading, spacing: 20) {
                detailHeading(
                    workflow.name,
                    description: workflow.summary
                )

                activityStateNotice

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Structure")
                        .font(.headline)
                    ForEach(WorkflowSection.allCases, id: \.self) { section in
                        let count = workflow.steps(in: section).count
                        if count > 0 {
                            HStack(spacing: 10) {
                                Image(systemName: stepIcon(for: section))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(section.displayName)
                                Spacer()
                                Text("\(count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text("Coordinator")
                    }
                }

                Divider()

                Label(
                    "Step names, stages, and order stay fixed. Instructions and agents can be changed while paused.",
                    systemImage: "lock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func stepDetail(stepID: String) -> some View {
        if let step = workflow?.step(id: stepID) {
            VStack(alignment: .leading, spacing: 20) {
                detailHeading(
                    step.name,
                    description: sectionDescription(step.section)
                )

                if !preferencesAreEditable {
                    activityStateNotice
                }

                if preferencesAreEditable {
                    instructionsEditor(
                        stepBinding(for: step).instructions,
                        accessibilityLabel: "\(step.name) instructions",
                        helpText: "Edit the instructions used the next time this step starts."
                    )
                } else {
                    readOnlyInstructions(
                        step.instructions,
                        title: "Instructions"
                    )
                }

                if isCurrentRecoveryStep(stepID) {
                    Label(
                        "Restart uses these instructions. Resume continues with the saved prompt from the failed run.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Agent")
                        .font(.headline)
                    WorkflowTargetFields(
                        title: step.name,
                        target: stepBinding(for: step).target
                    )
                    .disabled(!preferencesAreEditable)
                }
            }
        } else {
            ContentUnavailableView(
                "Step Not Found",
                systemImage: "exclamationmark.triangle",
                description: Text("Choose another workflow step.")
            )
        }
    }

    private var coordinatorDetail: some View {
        VStack(alignment: .leading, spacing: 20) {
            detailHeading(
                "Handoff Coordinator",
                description: "Filters each completed step into a concise handoff and decides whether the repeating loop is complete."
            )

            if !preferencesAreEditable {
                activityStateNotice
            }

            if preferencesAreEditable {
                instructionsEditor(
                    coordinatorInstructionsBinding,
                    accessibilityLabel: "Coordinator instructions",
                    helpText: "Edit the instructions used for the next handoff."
                )
            } else {
                readOnlyInstructions(
                    workflow?.coordinator.instructions ?? "",
                    title: "Instructions"
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Agent")
                    .font(.headline)
                WorkflowTargetFields(
                    title: "Coordinator",
                    target: coordinatorTargetBinding
                )
                .disabled(!preferencesAreEditable)
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

    private func instructionsEditor(
        _ instructions: Binding<String>,
        accessibilityLabel: String,
        helpText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Instructions")
                .font(.headline)
            ActivityTextEditor(
                text: instructions,
                minHeight: 190,
                accessibilityLabel: accessibilityLabel,
                helpText: helpText
            )
        }
    }

    private func readOnlyInstructions(
        _ instructions: String,
        title: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(instructions)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    .quaternary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
    }

    private var activityStateNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: activityStatusIcon)
                .foregroundStyle(activityStatusColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(activityNoticeTitle)
                    .font(.headline)
                Text(activityStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            activityStatusColor.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private var legacyRepositorySettings: some View {
        Form {
            Section("Models") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    ModelSelectionGridHeader()

                    ModelSelectionGridRow(
                        title: "Implement",
                        selection: $settings.implementer,
                        models: application.models
                    )
                    ModelSelectionGridRow(
                        title: "Review",
                        selection: $settings.reviewer,
                        models: application.models
                    )
                    ModelSelectionGridRow(
                        title: "Fix",
                        selection: $settings.fixer,
                        models: application.models
                    )
                    ModelSelectionGridRow(
                        title: "Handoff",
                        selection: $settings.relay.selection,
                        models: application.models
                    )
                }
            }

            Section("Handoff") {
                LabeledContent("Credentials file") {
                    FilePathField(
                        path: $settings.relay.apiKeyFile,
                        placeholder: "Choose a JSON credentials file",
                        panelTitle: "Choose the API-key JSON File",
                        prompt: "Choose"
                    )
                    .help("Choose or drop the JSON file containing the handoff API key; the advanced path menu also supports manual entry")
                }
                LabeledContent("Key in file") {
                    Picker("Key in file", selection: $settings.relay.apiKeyName) {
                        ForEach(availableAPIKeyNames, id: \.self) { keyName in
                            Text(keyName).tag(keyName)
                        }
                    }
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help("Choose the JSON property whose value is the handoff API key")
                }
                HStack(spacing: 10) {
                    Button("Test Handoff") {
                        Task { await testHandoffConfiguration() }
                    }
                    .disabled(isTestingHandoff)
                    .help("Verify the API-key file, JSON property, credentials, and selected handoff model")
                    if isTestingHandoff {
                        ProgressView()
                            .controlSize(.small)
                    } else if let handoffTestMessage {
                        Label(
                            handoffTestMessage,
                            systemImage: handoffTestSucceeded
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(handoffTestSucceeded ? .green : .red)
                        .font(.caption)
                        .textSelection(.enabled)
                    }
                }
                Text("The key is read at relay-call time and is never stored by Codeness.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var firstPopulatedSection: WorkflowSection? {
        WorkflowSection.allCases.first {
            !(workflow?.steps(in: $0).isEmpty ?? true)
        }
    }

    private var preferencesAreEditable: Bool {
        coordinator.record.activity?.status == .paused
    }

    private var activityStatusTitle: String {
        switch coordinator.record.activity?.status {
        case .running: "Running"
        case .paused: "Paused — editable"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        case nil: "Not started"
        }
    }

    private var activityStatusIcon: String {
        switch coordinator.record.activity?.status {
        case .running: "play.circle.fill"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case nil: "circle"
        }
    }

    private var activityStatusColor: Color {
        switch coordinator.record.activity?.status {
        case .paused: .accentColor
        case .running: .orange
        case .completed: .green
        case .failed: .red
        case .cancelled, nil: .secondary
        }
    }

    private var activityStatusDetail: String {
        switch coordinator.record.activity?.status {
        case .paused:
            "You can change instructions and agents. Provider, model, or mode changes start a new session lineage."
        case .running:
            "Pause the activity before changing instructions or agents."
        case .completed:
            "This activity is complete. Use Start Over to run it with different workflow preferences."
        case .cancelled:
            "This activity was cancelled. Use Start Over to run it with different workflow preferences."
        case .failed:
            "This activity failed. Resume and pause it before changing workflow preferences, or use Start Over."
        case nil:
            "Start an activity before changing its workflow preferences."
        }
    }

    private var activityNoticeTitle: String {
        switch coordinator.record.activity?.status {
        case .paused: "Preferences editable"
        case .running: "Pause to edit"
        case .completed, .cancelled, .failed: "Preferences locked"
        case nil: "Preferences unavailable"
        }
    }

    private var validationMessage: String? {
        if let workflow {
            return workflow.validationMessage
                ?? application.workflowCompatibilityMessage(workflow)
        }
        return nil
    }

    private func stepBinding(for fallback: WorkflowStep) -> Binding<WorkflowStep> {
        Binding(
            get: {
                workflow?.step(id: fallback.id) ?? fallback
            },
            set: { updatedStep in
                guard var workflow,
                      let index = workflow.steps.firstIndex(where: {
                          $0.id == fallback.id
                      }) else { return }
                workflow.steps[index] = updatedStep
                self.workflow = workflow
            }
        )
    }

    private var coordinatorTargetBinding: Binding<AgentTarget> {
        Binding(
            get: {
                workflow?.coordinator.target
                    ?? application.workflowCatalog.defaultTemplate!.coordinator.target
            },
            set: { updatedTarget in
                guard var workflow else { return }
                workflow.coordinator.target = updatedTarget
                self.workflow = workflow
            }
        )
    }

    private var coordinatorInstructionsBinding: Binding<String> {
        Binding(
            get: {
                workflow?.coordinator.instructions ?? ""
            },
            set: { updatedInstructions in
                guard var workflow else { return }
                workflow.coordinator.instructions = updatedInstructions
                self.workflow = workflow
            }
        )
    }

    private func isCurrentRecoveryStep(_ stepID: String) -> Bool {
        guard let activity = coordinator.record.activity,
              case .recoverRun(let runID)? = activity.workflowResumeCheckpoint,
              let run = activity.runs.first(where: { $0.id == runID }),
              [.failed, .interrupted].contains(run.status) else {
            return false
        }
        return run.workflowStep?.id == stepID
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

    private var canSave: Bool {
        if let workflow {
            return preferencesAreEditable
                && workflow.validationMessage == nil
                && application.workflowCompatibilityMessage(workflow) == nil
                && workflow != coordinator.record.activity?.workflow
        }
        return settings != coordinator.record.settings
    }

    private var saveHelp: String {
        workflow == nil
            ? "Save these model, reasoning, and handoff settings for this repository"
            : "Save instruction and agent changes for this paused activity"
    }

    private func save() async -> Bool {
        if let workflow {
            return await coordinator.updateWorkflowPreferences(workflow)
        }
        return await coordinator.updateSettings(settings)
    }

    private func testHandoffConfiguration() async {
        isTestingHandoff = true
        defer { isTestingHandoff = false }
        do {
            try await coordinator.testHandoffConfiguration(settings.relay)
            handoffTestSucceeded = true
            handoffTestMessage = "Configuration verified"
        } catch {
            handoffTestSucceeded = false
            handoffTestMessage = error.localizedDescription
        }
    }

    private var availableAPIKeyNames: [String] {
        let configuredName = settings.relay.apiKeyName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedPath = NSString(string: settings.relay.apiKeyFile)
            .expandingTildeInPath
        var names: Set<String> = configuredName.isEmpty ? [] : [configuredName]

        if let data = FileManager.default.contents(atPath: expandedPath),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            names.formUnion(
                dictionary.compactMap { key, value in
                    value is String ? key : nil
                }
            )
        }

        return names.sorted()
    }
}

private enum WorkflowPreferencesSelection: Hashable {
    case overview
    case coordinator
    case step(String)
}

private extension View {
    func workflowPreferencesDetailLayout() -> some View {
        frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct ModelSelectionGridHeader: View {
    var body: some View {
        GridRow {
            Text("Role")
                .frame(width: 110, alignment: .leading)
            Text("Model")
                .frame(minWidth: 300, maxWidth: .infinity, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            Text("Reasoning effort")
                .frame(width: 180, alignment: .trailing)
                .gridColumnAlignment(.trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct ModelSelectionGridRow: View {
    let title: String
    @Binding var selection: ModelSelection
    let models: [CodexModel]

    var body: some View {
        GridRow {
            Text(title)
                .frame(width: 110, alignment: .leading)
            Picker("Model", selection: modelBinding) {
                if !models.contains(where: { $0.model == selection.model }) {
                    Text(selection.model).tag(selection.model)
                }
                ForEach(models) { model in
                    Text(model.displayName).tag(model.model)
                }
            }
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 300, maxWidth: .infinity, alignment: .trailing)
            .help("Choose the model used for the \(title.lowercased()) phase")
            Picker("Effort", selection: $selection.effort) {
                ForEach(efforts, id: \.self) { effort in
                    Text(effort).tag(effort)
                }
            }
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: 180, alignment: .trailing)
            .help("Choose the reasoning effort used for the \(title.lowercased()) phase")
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { selection.model },
            set: { modelName in
                selection.model = modelName
                if let model = models.first(where: { $0.model == modelName }),
                   !model.efforts.contains(selection.effort) {
                    selection.effort = model.defaultEffort
                }
            }
        )
    }

    private var efforts: [String] {
        let supported = models.first(where: { $0.model == selection.model })?.efforts ?? []
        if supported.isEmpty { return [selection.effort] }
        if supported.contains(selection.effort) { return supported }
        return [selection.effort] + supported
    }
}
