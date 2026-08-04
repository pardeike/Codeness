import CodenessCore
import SwiftUI

struct ApplicationSettingsView: View {
    let application: CodenessApplicationModel
    @State private var executablePath: String
    @State private var claudeExecutablePath: String
    @State private var workflowCatalog: WorkflowCatalog
    @State private var selectedWorkflowID: String
    @State private var workflowEditor: WorkflowEditorPresentation?
    @State private var separatesRunTranscripts: Bool
    @State private var isSaving = false
    @State private var closeRequestID = 0

    init(application: CodenessApplicationModel) {
        self.application = application
        _executablePath = State(initialValue: application.configuredExecutablePath)
        _claudeExecutablePath = State(
            initialValue: application.configuredClaudeExecutablePath
        )
        _workflowCatalog = State(initialValue: application.workflowCatalog)
        _selectedWorkflowID = State(
            initialValue: application.workflowCatalog.defaultTemplateID
        )
        _separatesRunTranscripts = State(initialValue: application.separatesRunTranscripts)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Agent CLIs")
                        .font(.title2.weight(.semibold))
                    VStack(alignment: .leading, spacing: 7) {
                        LabeledContent("Codex executable") {
                            FilePathField(
                                path: $executablePath,
                                placeholder: "Automatic discovery",
                                panelTitle: "Choose the Codex Executable",
                                prompt: "Choose",
                                requiresExecutable: true
                            )
                            .help("Choose or drop the Codex executable; use the advanced path menu for manual entry, or clear it for automatic discovery")
                        }
                        LabeledContent("Codex status") {
                            HStack {
                                Text(application.serverState.label)
                                    .foregroundStyle(.secondary)
                                if codexCanRetry {
                                    Button("Retry") {
                                        Task {
                                            _ = await application.restartServer(
                                                configuredPath: cleanExecutablePath
                                            )
                                        }
                                    }
                                    .disabled(application.isProviderRestartPending(.codex))
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        LabeledContent("Claude executable") {
                            FilePathField(
                                path: $claudeExecutablePath,
                                placeholder: "Automatic discovery",
                                panelTitle: "Choose the Claude Executable",
                                prompt: "Choose",
                                requiresExecutable: true
                            )
                            .help("Choose or drop the Claude executable, or clear the field for automatic discovery")
                        }
                        LabeledContent("Claude status") {
                            HStack {
                                Text(application.claudeState.label)
                                    .foregroundStyle(.secondary)
                                if claudeCanRetry {
                                    Button("Retry") {
                                        Task {
                                            _ = await application.restartClaude(
                                                configuredPath: cleanClaudeExecutablePath
                                            )
                                        }
                                    }
                                    .disabled(application.isProviderRestartPending(.claude))
                                }
                            }
                        }
                    }
                    Text("Executable paths are shared by every repository window. Leave either field empty for automatic discovery. A changed CLI is restarted only when it has no active turn.")
                        .foregroundStyle(.secondary)

                    Divider()

                    Text("Transcript")
                        .font(.title2.weight(.semibold))
                    Toggle("Keep run transcripts separate", isOn: $separatesRunTranscripts)
                        .help("Show only each run's own response instead of its injected prompt and handoff context")
                    Text("Hides the injected prompt and handoff context from each run so it shows only that step’s own response. Turn this off to include the full prompt for a seamless context view.")
                        .foregroundStyle(.secondary)

                    Divider()

                    workflowLibrary
                }
                .padding(24)
            }

            Divider()
            HStack {
                Button("Restore Built-in Workflows") {
                    workflowCatalog = application.builtInWorkflowCatalog
                    selectedWorkflowID = workflowCatalog.defaultTemplateID
                }
                .help("Discard local workflow edits and restore all bundled workflows")
                Spacer()
                Button("Cancel", role: .cancel) {
                    revert()
                    closeRequestID &+= 1
                }
                .keyboardShortcut(.cancelAction)
                .help("Discard unsaved changes and close Settings")
                Button {
                    Task {
                        _ = await saveSettings()
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
                .help("Save agent executables, workflows, and transcript preferences")
                .disabled(
                    isSaving
                        || serverIsStarting
                        || workflowValidationMessage != nil
                        || !hasSavableChanges
                )
            }
            .padding(14)
        }
        .frame(width: 960, height: 820)
        .background {
            SettingsWindowCloseGuard(
                isDirty: isDirty,
                save: { await saveSettings() },
                discard: { revert() },
                closeRequestID: closeRequestID
            )
            .frame(width: 0, height: 0)
        }
        .sheet(item: $workflowEditor) { presentation in
            WorkflowEditorSheet(
                title: presentation.title,
                confirmationTitle: presentation.confirmationTitle,
                workflow: presentation.workflow
            ) { updatedWorkflow in
                applyWorkflowEdit(
                    updatedWorkflow,
                    replacing: presentation.replacingWorkflowID
                )
            }
            .environment(application)
        }
        .alert(
            "Codeness",
            isPresented: Binding(
                get: { application.applicationError != nil },
                set: { if !$0 { application.clearError() } }
            )
        ) {
            Button("OK") { application.clearError() }
                .help("Dismiss this Codeness error")
        } message: {
            Text(application.applicationError ?? "Unknown error")
        }
    }

    private var workflowLibrary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Workflows")
                .font(.title2.weight(.semibold))
            Text("Each new activity copies one reusable workflow. Select a workflow to manage it, or open its editor to change steps, instructions, agents, models, and options.")
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                ForEach(workflowCatalog.templates) { workflow in
                    let isSelected = workflow.id == selectedWorkflowID
                    WorkflowLibraryRow(
                        workflow: workflow,
                        isDefault: workflow.id == workflowCatalog.defaultTemplateID,
                        isSelected: isSelected,
                        kind: workflowKind(for: workflow),
                        stepSummary: stepSummary(for: workflow)
                    )
                    .onTapGesture(count: 2) {
                        selectedWorkflowID = workflow.id
                        presentSelectedWorkflowEditor()
                    }
                    .onTapGesture {
                        selectedWorkflowID = workflow.id
                    }
                    .draggable(workflow.id)
                    .dropDestination(for: String.self) {
                        workflowIDs,
                        location in
                        moveDraggedWorkflow(
                            workflowIDs.first,
                            relativeTo: workflow.id,
                            placeAfter: location.y > 34
                        )
                    }
                    .help("Select this workflow; double-click to edit it")
                    .accessibilityAction {
                        selectedWorkflowID = workflow.id
                    }
                    .accessibilityAction(named: "Edit") {
                        selectedWorkflowID = workflow.id
                        presentSelectedWorkflowEditor()
                    }
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(.separator.opacity(0.55), lineWidth: 1)
            }
            .accessibilityLabel("Workflows")

            HStack(spacing: 8) {
                Button {
                    presentNewWorkflowEditor()
                } label: {
                    Label("New…", systemImage: "plus")
                }
                .help("Create a workflow in a separate editor")
                Button {
                    presentDuplicateWorkflowEditor()
                } label: {
                    Label("Duplicate…", systemImage: "plus.square.on.square")
                }
                .disabled(selectedWorkflow == nil)
                .help("Create a workflow by editing a copy of the selected workflow")
                Button {
                    presentSelectedWorkflowEditor()
                } label: {
                    Label("Edit…", systemImage: "pencil")
                }
                .disabled(selectedWorkflow == nil)
                .help("Open the selected workflow in a separate editor")
                Button(role: .destructive) {
                    deleteSelectedWorkflow()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!canDeleteSelectedWorkflow)
                .help(
                    canDeleteSelectedWorkflow
                        ? "Delete the selected workflow"
                        : "At least one workflow is required"
                )
                if canResetSelectedWorkflow {
                    Button {
                        resetSelectedWorkflow()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .help("Reset this bundled workflow to its original definition")
                }
                Spacer()
                Picker("Default", selection: defaultWorkflowBinding) {
                    ForEach(workflowCatalog.templates) { workflow in
                        Text(workflow.name).tag(workflow.id)
                    }
                }
                .frame(width: 330)
                .help("Choose the workflow copied into each new activity")
            }

            if let workflowValidationMessage {
                Label(workflowValidationMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var cleanExecutablePath: String {
        executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanClaudeExecutablePath: String {
        claudeExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var needsCodexRestart: Bool {
        if cleanExecutablePath != application.configuredExecutablePath {
            return true
        }
        switch application.serverState {
        case .ready:
            return !application.isExecutableConfigurationActive(cleanExecutablePath)
        case .failed, .stopped:
            return false
        case .starting:
            return false
        }
    }

    private var needsClaudeRestart: Bool {
        if cleanClaudeExecutablePath != application.configuredClaudeExecutablePath {
            return true
        }
        switch application.claudeState {
        case .ready:
            return !application.isClaudeExecutableConfigurationActive(
                cleanClaudeExecutablePath
            )
        case .failed, .stopped:
            return false
        case .starting:
            return false
        }
    }

    private var serverIsStarting: Bool {
        application.serverState == .starting
            || application.claudeState == .starting
            || application.isProviderRestartPending(.codex)
            || application.isProviderRestartPending(.claude)
    }

    private var codexCanRetry: Bool {
        switch application.serverState {
        case .failed, .stopped: true
        case .starting, .ready: false
        }
    }

    private var claudeCanRetry: Bool {
        switch application.claudeState {
        case .failed, .stopped: true
        case .starting, .ready: false
        }
    }

    private var isDirty: Bool {
        workflowCatalog != application.workflowCatalog
            || separatesRunTranscripts != application.separatesRunTranscripts
            || cleanExecutablePath != application.configuredExecutablePath
            || cleanClaudeExecutablePath != application.configuredClaudeExecutablePath
    }

    private var hasSavableChanges: Bool {
        isDirty || needsCodexRestart || needsClaudeRestart
    }

    private func revert() {
        executablePath = application.configuredExecutablePath
        claudeExecutablePath = application.configuredClaudeExecutablePath
        workflowCatalog = application.workflowCatalog
        selectedWorkflowID = workflowCatalog.defaultTemplateID
        separatesRunTranscripts = application.separatesRunTranscripts
    }

    @discardableResult
    private func saveSettings() async -> Bool {
        guard !isSaving,
              workflowValidationMessage == nil,
              !serverIsStarting else { return false }
        isSaving = true
        defer { isSaving = false }

        if needsCodexRestart {
            let restarted = await application.restartServer(configuredPath: cleanExecutablePath)
            guard restarted else { return false }
        }
        if needsClaudeRestart {
            let restarted = await application.restartClaude(
                configuredPath: cleanClaudeExecutablePath
            )
            guard restarted else { return false }
        }
        executablePath = cleanExecutablePath
        claudeExecutablePath = cleanClaudeExecutablePath
        application.updateWorkflowCatalog(workflowCatalog)
        application.setSeparatesRunTranscripts(separatesRunTranscripts)
        return true
    }

    private var selectedWorkflow: WorkflowTemplate? {
        workflowCatalog.template(id: selectedWorkflowID)
    }

    private var defaultWorkflowBinding: Binding<String> {
        Binding(
            get: { workflowCatalog.defaultTemplateID },
            set: { identifier in
                workflowCatalog = WorkflowCatalog(
                    schemaVersion: workflowCatalog.schemaVersion,
                    defaultTemplateID: identifier,
                    templates: workflowCatalog.templates
                )
            }
        )
    }

    private var workflowValidationMessage: String? {
        if workflowCatalog.templates.isEmpty {
            return "At least one workflow is required."
        }
        if !workflowCatalog.templates.contains(where: {
            $0.id == workflowCatalog.defaultTemplateID
        }) {
            return "The default workflow does not exist."
        }
        let identifiers = workflowCatalog.templates.map(\.id)
        if Set(identifiers).count != identifiers.count {
            return "Workflow identifiers must be unique."
        }
        return workflowCatalog.templates.compactMap(\.validationMessage).first
    }

    private var canDeleteSelectedWorkflow: Bool {
        workflowCatalog.templates.count > 1 && selectedWorkflow != nil
    }

    private var canResetSelectedWorkflow: Bool {
        guard let builtIn = application.builtInWorkflowCatalog.template(
            id: selectedWorkflowID
        ) else { return false }
        return builtIn != selectedWorkflow
    }

    private func presentSelectedWorkflowEditor() {
        guard let workflow = selectedWorkflow else { return }
        workflowEditor = WorkflowEditorPresentation(
            title: "Edit Workflow",
            confirmationTitle: "Apply",
            workflow: workflow,
            replacingWorkflowID: workflow.id
        )
    }

    private func presentDuplicateWorkflowEditor() {
        guard var copy = selectedWorkflow else { return }
        copy.id = uniqueWorkflowID(base: copy.id + "-copy")
        copy.name += " Copy"
        workflowEditor = WorkflowEditorPresentation(
            title: "Duplicate Workflow",
            confirmationTitle: "Add",
            workflow: copy,
            replacingWorkflowID: nil
        )
    }

    private func presentNewWorkflowEditor() {
        let target = selectedWorkflow?.steps.first?.target
            ?? selectedWorkflow?.coordinator.target
            ?? AgentTarget(providerID: .codex, model: "gpt-5.6-sol")
        let identifier = uniqueWorkflowID(base: "custom-workflow")
        let workflow = WorkflowTemplate(
            id: identifier,
            name: "New Workflow",
            summary: "A configurable repeating workflow.",
            steps: [
                WorkflowStep(
                    id: "work",
                    name: "Work",
                    section: .loop,
                    instructions: "Complete the next useful portion of the goal and report the result.",
                    target: target
                )
            ],
            coordinator: WorkflowCoordinatorConfiguration(
                target: selectedWorkflow?.coordinator.target ?? target,
                instructions: selectedWorkflow?.coordinator.instructions
                    ?? "Produce a concise factual handoff and decide whether the full goal is complete."
            )
        )
        workflowEditor = WorkflowEditorPresentation(
            title: "New Workflow",
            confirmationTitle: "Add",
            workflow: workflow,
            replacingWorkflowID: nil
        )
    }

    private func applyWorkflowEdit(
        _ workflow: WorkflowTemplate,
        replacing workflowID: String?
    ) {
        var templates = workflowCatalog.templates
        if let workflowID,
           let index = templates.firstIndex(where: { $0.id == workflowID }) {
            templates[index] = workflow
        } else {
            templates.append(workflow)
        }
        workflowCatalog = WorkflowCatalog(
            schemaVersion: workflowCatalog.schemaVersion,
            defaultTemplateID: workflowCatalog.defaultTemplateID,
            templates: templates
        )
        selectedWorkflowID = workflow.id
    }

    private func workflowKind(for workflow: WorkflowTemplate) -> String {
        guard let builtIn = application.builtInWorkflowCatalog.template(id: workflow.id)
        else { return "Custom" }
        return builtIn == workflow ? "Built-in" : "Built-in · Modified"
    }

    private func stepSummary(for workflow: WorkflowTemplate) -> String {
        WorkflowSection.allCases.compactMap { section -> String? in
            let steps = workflow.steps(in: section)
            guard !steps.isEmpty else { return nil }
            return steps.map(\.name).joined(separator: " → ")
        }
        .joined(separator: " · ")
    }

    private func deleteSelectedWorkflow() {
        guard canDeleteSelectedWorkflow else { return }
        let templates = workflowCatalog.templates.filter { $0.id != selectedWorkflowID }
        let defaultID = workflowCatalog.defaultTemplateID == selectedWorkflowID
            ? (templates.first?.id ?? "")
            : workflowCatalog.defaultTemplateID
        workflowCatalog = WorkflowCatalog(
            schemaVersion: workflowCatalog.schemaVersion,
            defaultTemplateID: defaultID,
            templates: templates
        )
        selectedWorkflowID = defaultID
    }

    private func resetSelectedWorkflow() {
        guard let builtIn = application.builtInWorkflowCatalog.template(
            id: selectedWorkflowID
        ) else { return }
        var templates = workflowCatalog.templates
        guard let index = templates.firstIndex(where: { $0.id == selectedWorkflowID })
        else { return }
        templates[index] = builtIn
        workflowCatalog = WorkflowCatalog(
            schemaVersion: workflowCatalog.schemaVersion,
            defaultTemplateID: workflowCatalog.defaultTemplateID,
            templates: templates
        )
    }

    private func moveDraggedWorkflow(
        _ workflowID: String?,
        relativeTo targetWorkflowID: String,
        placeAfter: Bool
    ) -> Bool {
        guard let workflowID,
              workflowID != targetWorkflowID else { return false }

        var templates = workflowCatalog.templates
        guard let sourceIndex = templates.firstIndex(where: {
            $0.id == workflowID
        }) else { return false }
        let movedWorkflow = templates.remove(at: sourceIndex)
        guard let targetIndex = templates.firstIndex(where: {
            $0.id == targetWorkflowID
        }) else { return false }
        templates.insert(
            movedWorkflow,
            at: targetIndex + (placeAfter ? 1 : 0)
        )
        workflowCatalog = WorkflowCatalog(
            schemaVersion: workflowCatalog.schemaVersion,
            defaultTemplateID: workflowCatalog.defaultTemplateID,
            templates: templates
        )
        selectedWorkflowID = workflowID
        return true
    }

    private func uniqueWorkflowID(base: String) -> String {
        let existing = Set(workflowCatalog.templates.map(\.id))
        var candidate = base
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}

private struct WorkflowEditorPresentation: Identifiable {
    let id = UUID()
    let title: String
    let confirmationTitle: String
    let workflow: WorkflowTemplate
    let replacingWorkflowID: String?
}

private struct WorkflowLibraryRow: View {
    let workflow: WorkflowTemplate
    let isDefault: Bool
    let isSelected: Bool
    let kind: String
    let stepSummary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(workflow.name)
                    .font(.headline)
                Text(kind)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if isDefault {
                    Label("Default", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Text(workflow.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(stepSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : .clear)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
