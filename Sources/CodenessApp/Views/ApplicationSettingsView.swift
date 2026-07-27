import CodenessCore
import SwiftUI

struct ApplicationSettingsView: View {
    let application: CodenessApplicationModel
    @State private var prompts: ActivityPrompts
    @State private var modelDefaults: RepositoryModelDefaults
    @State private var executablePath: String
    @State private var claudeExecutablePath: String
    @State private var workflowCatalog: WorkflowCatalog
    @State private var selectedWorkflowID: String
    @State private var workflowEditor: WorkflowEditorPresentation?
    @State private var separatesRunTranscripts: Bool
    @State private var isSaving = false

    init(application: CodenessApplicationModel) {
        self.application = application
        _prompts = State(initialValue: application.promptDefaults)
        _modelDefaults = State(initialValue: application.repositoryModelDefaults)
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
                            }
                        }
                    }
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

                    Divider()

                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("These settings are retained for activities created by versions of Codeness before configurable workflows.")
                                .foregroundStyle(.secondary)
                            legacyDefaults
                        }
                        .padding(.top, 10)
                    } label: {
                        Text("Legacy Activity Defaults")
                            .font(.title2.weight(.semibold))
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                Button("Restore Built-in Workflows") {
                    workflowCatalog = application.builtInWorkflowCatalog
                    selectedWorkflowID = workflowCatalog.defaultTemplateID
                }
                .help("Discard local workflow-library edits and restore all bundled workflows")
                Button("Use Built-in Legacy Defaults") {
                    prompts = .builtInDefaults
                    modelDefaults = .builtInDefaults
                }
                .help("Replace the legacy prompt and model defaults with their built-in values")
                Spacer()
                Button("Revert") {
                    revert()
                }
                .help("Discard unsaved changes and restore the currently saved preferences")
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
                .help("Save agent executables, workflow library, defaults, and transcript preferences")
                .disabled(
                    isSaving
                        || serverIsStarting
                        || prompts.validationMessage != nil
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
                discard: { revert() }
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
            Text("Workflow Library")
                .font(.title2.weight(.semibold))
            Text("Each new activity copies one reusable workflow. Select a workflow to manage it, or open its editor to change steps, instructions, agents, models, modes, and speeds.")
                .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                List(selection: workflowSelectionBinding) {
                    ForEach(workflowCatalog.templates) { workflow in
                        WorkflowLibraryRow(
                            workflow: workflow,
                            isDefault: workflow.id == workflowCatalog.defaultTemplateID,
                            kind: workflowKind(for: workflow),
                            stepSummary: stepSummary(for: workflow)
                        )
                        .id(workflow.id)
                        .tag(workflow.id)
                    }
                    Color.clear
                        .frame(height: 60)
                        .listRowSeparator(.hidden)
                        .accessibilityHidden(true)
                }
                .onChange(of: selectedWorkflowID) { _, identifier in
                    withAnimation {
                        proxy.scrollTo(identifier, anchor: .center)
                    }
                }
            }
            .frame(height: 205)
            .accessibilityLabel("Workflow library")

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
                        ? "Delete the selected custom workflow"
                        : "Bundled workflows cannot be deleted"
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

    private var legacyDefaults: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Default Repository Models")
                        .font(.title2.weight(.semibold))
                    Text("A new repository window copies these model and reasoning choices. Every window keeps its own editable settings afterward, so changing these defaults never changes an existing window.")
                        .foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        ModelSelectionGridHeader()
                        ModelSelectionGridRow(
                            title: "Implement",
                            selection: $modelDefaults.implementer,
                            models: application.models
                        )
                        ModelSelectionGridRow(
                            title: "Review",
                            selection: $modelDefaults.reviewer,
                            models: application.models
                        )
                        ModelSelectionGridRow(
                            title: "Fix",
                            selection: $modelDefaults.fixer,
                            models: application.models
                        )
                        ModelSelectionGridRow(
                            title: "Handoff",
                            selection: $modelDefaults.handoff,
                            models: application.models
                        )
                    }

                    Divider()

                    Text("Default Activity Prompts")
                        .font(.title2.weight(.semibold))
                    Text("A repository window copies these suggestions when it has not started. Editing a window’s prompts does not change these defaults.")
                        .foregroundStyle(.secondary)
                    PromptTemplateFields(prompts: $prompts)
                    if let validationMessage = prompts.validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
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
        application.serverState == .starting || application.claudeState == .starting
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
        prompts != application.promptDefaults
            || modelDefaults != application.repositoryModelDefaults
            || workflowCatalog != application.workflowCatalog
            || separatesRunTranscripts != application.separatesRunTranscripts
            || cleanExecutablePath != application.configuredExecutablePath
            || cleanClaudeExecutablePath != application.configuredClaudeExecutablePath
    }

    private var hasSavableChanges: Bool {
        isDirty || needsCodexRestart || needsClaudeRestart
    }

    private func revert() {
        prompts = application.promptDefaults
        modelDefaults = application.repositoryModelDefaults
        executablePath = application.configuredExecutablePath
        claudeExecutablePath = application.configuredClaudeExecutablePath
        workflowCatalog = application.workflowCatalog
        selectedWorkflowID = workflowCatalog.defaultTemplateID
        separatesRunTranscripts = application.separatesRunTranscripts
    }

    @discardableResult
    private func saveSettings() async -> Bool {
        guard !isSaving,
              prompts.validationMessage == nil,
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
        application.updatePromptDefaults(prompts)
        application.updateRepositoryModelDefaults(modelDefaults)
        application.setSeparatesRunTranscripts(separatesRunTranscripts)
        return true
    }

    private var selectedWorkflow: WorkflowTemplate? {
        workflowCatalog.template(id: selectedWorkflowID)
    }

    private var workflowSelectionBinding: Binding<String?> {
        Binding(
            get: { selectedWorkflowID },
            set: { identifier in
                if let identifier {
                    selectedWorkflowID = identifier
                }
            }
        )
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
            return "The workflow library needs at least one workflow."
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
        guard workflowCatalog.templates.count > 1 else { return false }
        return application.builtInWorkflowCatalog.template(id: selectedWorkflowID) == nil
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
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
