import CodenessCore
import SwiftUI

struct ApplicationSettingsView: View {
    let application: CodenessApplicationModel
    @State private var prompts: ActivityPrompts
    @State private var modelDefaults: RepositoryModelDefaults
    @State private var executablePath: String
    @State private var separatesRunTranscripts: Bool
    @State private var isSaving = false

    init(application: CodenessApplicationModel) {
        self.application = application
        _prompts = State(initialValue: application.promptDefaults)
        _modelDefaults = State(initialValue: application.repositoryModelDefaults)
        _executablePath = State(initialValue: application.configuredExecutablePath)
        _separatesRunTranscripts = State(initialValue: application.separatesRunTranscripts)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Codex")
                        .font(.title2.weight(.semibold))
                    LabeledContent("Executable") {
                        TextField("Automatic discovery", text: $executablePath)
                            .textFieldStyle(.roundedBorder)
                            .help("Enter the Codex executable path, or leave this empty to discover it automatically")
                    }
                    Text("This executable is shared by every repository window. Leave the field empty to discover Codex automatically; changing it restarts the shared App Server when no turn is active.")
                        .foregroundStyle(.secondary)

                    Divider()

                    Text("Transcript")
                        .font(.title2.weight(.semibold))
                    Toggle("Keep run transcripts separate", isOn: $separatesRunTranscripts)
                        .help("Show only each run's own response instead of its injected prompt and handoff context")
                    Text("Hides the injected prompt and handoff text from each run row so Implement, Review, and Fix show only their own response. Turn this off to include the full prompt for a seamless context view.")
                        .foregroundStyle(.secondary)

                    Divider()

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
                .padding(24)
            }

            Divider()
            HStack {
                Button("Use Built-in Prompt and Model Defaults") {
                    prompts = .builtInDefaults
                    modelDefaults = .builtInDefaults
                }
                .help("Replace the edited prompt and model defaults with Codeness's built-in values")
                Spacer()
                Button("Revert") {
                    prompts = application.promptDefaults
                    modelDefaults = application.repositoryModelDefaults
                    executablePath = application.configuredExecutablePath
                    separatesRunTranscripts = application.separatesRunTranscripts
                }
                .help("Discard unsaved changes and restore the currently saved preferences")
                Button {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        let cleanPath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
                        if needsExecutableRestart {
                            let restarted = await application.restartServer(configuredPath: cleanPath)
                            guard restarted else { return }
                        }
                        executablePath = cleanPath
                        application.updatePromptDefaults(prompts)
                        application.updateRepositoryModelDefaults(modelDefaults)
                        application.setSeparatesRunTranscripts(separatesRunTranscripts)
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
                .help("Save these global defaults and transcript preferences")
                .disabled(
                    isSaving
                        || serverIsStarting
                        || prompts.validationMessage != nil
                        || (prompts == application.promptDefaults
                            && modelDefaults == application.repositoryModelDefaults
                            && separatesRunTranscripts == application.separatesRunTranscripts
                            && !needsExecutableRestart)
                )
            }
            .padding(14)
        }
        .frame(width: 900, height: 760)
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

    private var cleanExecutablePath: String {
        executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var needsExecutableRestart: Bool {
        if cleanExecutablePath != application.configuredExecutablePath {
            return true
        }
        switch application.serverState {
        case .ready:
            return !application.isExecutableConfigurationActive(cleanExecutablePath)
        case .failed, .stopped:
            return true
        case .starting:
            return false
        }
    }

    private var serverIsStarting: Bool {
        application.serverState == .starting
    }
}
