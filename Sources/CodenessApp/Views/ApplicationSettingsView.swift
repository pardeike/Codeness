import CodenessCore
import SwiftUI

struct ApplicationSettingsView: View {
    let application: CodenessApplicationModel
    @State private var executablePath: String
    @State private var claudeExecutablePath: String
    @State private var openAICompatibleEndpoint: String
    @State private var openAICompatibleAPIKeyFile: String
    @State private var openAICompatibleAPIKeyName: String
    @State private var openAICompatibleDisplayName: String
    @State private var separatesRunTranscripts: Bool
    @State private var codexDebugMode: Bool
    @State private var isSaving = false
    @State private var closeRequestID = 0

    init(application: CodenessApplicationModel) {
        self.application = application
        _executablePath = State(initialValue: application.configuredExecutablePath)
        _claudeExecutablePath = State(
            initialValue: application.configuredClaudeExecutablePath
        )
        _openAICompatibleEndpoint = State(
            initialValue: application.openAICompatibleConfiguration.endpoint
        )
        _openAICompatibleAPIKeyFile = State(
            initialValue: application.openAICompatibleConfiguration.apiKeyFile
        )
        _openAICompatibleAPIKeyName = State(
            initialValue: application.openAICompatibleConfiguration.apiKeyName
        )
        _openAICompatibleDisplayName = State(
            initialValue: application.openAICompatibleConfiguration.displayName
        )
        _separatesRunTranscripts = State(initialValue: application.separatesRunTranscripts)
        _codexDebugMode = State(initialValue: application.codexDebugMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Agent Providers")
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
                        Toggle("Debug Mode", isOn: $codexDebugMode)
                            .help("Keep completed internal Codex sessions archived for debugging")
                        Text("Off deletes completed internal Codex sessions. On archives them so their transcripts remain available for debugging.")
                            .foregroundStyle(.secondary)
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
                    VStack(alignment: .leading, spacing: 7) {
                        LabeledContent("Display name") {
                            TextField(
                                "OpenAI-compatible",
                                text: $openAICompatibleDisplayName
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Endpoint") {
                            TextField(
                                "https://api.openai.com/v1",
                                text: $openAICompatibleEndpoint
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("API-key file") {
                            TextField("Optional JSON key file", text: $openAICompatibleAPIKeyFile)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("API-key name") {
                            TextField("OPENAI_API_KEY", text: $openAICompatibleAPIKeyName)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("\(application.openAICompatibleConfiguration.displayName) status") {
                            Text(application.openAICompatibleState.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("The endpoint may be a server root such as https://example.test/v1 or a complete /chat/completions URL. Leave the key file and name empty for endpoints without authentication. Settings changes take effect when no active turn uses this provider.")
                        .foregroundStyle(.secondary)
                    if let openAICompatibleValidationMessage {
                        Label(
                            openAICompatibleValidationMessage,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.red)
                    }

                    Divider()

                    Text("Transcript")
                        .font(.title2.weight(.semibold))
                    Toggle("Keep turn transcripts separate", isOn: $separatesRunTranscripts)
                        .help("Show only each turn's own response instead of its injected prompt and handoff context")
                    Text("Hides the injected prompt and handoff context from each turn so it shows only that agent’s own response. Turn this off to include the full prompt for a seamless context view.")
                        .foregroundStyle(.secondary)

                }
                .padding(24)
            }

            Divider()
            HStack {
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
                .help("Save agent provider and transcript settings")
                .disabled(
                    isSaving
                        || serverIsStarting
                        || openAICompatibleValidationMessage != nil
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

    private var cleanClaudeExecutablePath: String {
        claudeExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanOpenAICompatibleConfiguration: OpenAICompatibleProviderConfiguration {
        OpenAICompatibleProviderConfiguration(
            endpoint: openAICompatibleEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKeyFile: openAICompatibleAPIKeyFile.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKeyName: openAICompatibleAPIKeyName.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: openAICompatibleDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
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

    private var needsOpenAICompatibleRestart: Bool {
        if cleanOpenAICompatibleConfiguration != application.openAICompatibleConfiguration {
            return true
        }
        switch application.openAICompatibleState {
        case .ready:
            return false
        case .failed, .stopped:
            return true
        case .starting:
            return false
        }
    }

    private var openAICompatibleValidationMessage: String? {
        cleanOpenAICompatibleConfiguration.validationMessage
    }

    private var serverIsStarting: Bool {
        application.serverState == .starting
            || application.claudeState == .starting
            || application.openAICompatibleState == .starting
            || application.isProviderRestartPending(.codex)
            || application.isProviderRestartPending(.claude)
            || application.isProviderRestartPending(.openAICompatible)
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
        separatesRunTranscripts != application.separatesRunTranscripts
            || codexDebugMode != application.codexDebugMode
            || cleanExecutablePath != application.configuredExecutablePath
            || cleanClaudeExecutablePath != application.configuredClaudeExecutablePath
            || cleanOpenAICompatibleConfiguration != application.openAICompatibleConfiguration
    }

    private var hasSavableChanges: Bool {
        isDirty || needsCodexRestart || needsClaudeRestart || needsOpenAICompatibleRestart
    }

    private func revert() {
        executablePath = application.configuredExecutablePath
        claudeExecutablePath = application.configuredClaudeExecutablePath
        openAICompatibleEndpoint = application.openAICompatibleConfiguration.endpoint
        openAICompatibleAPIKeyFile = application.openAICompatibleConfiguration.apiKeyFile
        openAICompatibleAPIKeyName = application.openAICompatibleConfiguration.apiKeyName
        openAICompatibleDisplayName = application.openAICompatibleConfiguration.displayName
        separatesRunTranscripts = application.separatesRunTranscripts
        codexDebugMode = application.codexDebugMode
    }

    @discardableResult
    private func saveSettings() async -> Bool {
        guard !isSaving,
              openAICompatibleValidationMessage == nil,
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
        if needsOpenAICompatibleRestart {
            let restarted = await application.restartOpenAICompatible(
                configuration: cleanOpenAICompatibleConfiguration
            )
            guard restarted else { return false }
        }
        executablePath = cleanExecutablePath
        claudeExecutablePath = cleanClaudeExecutablePath
        openAICompatibleEndpoint = cleanOpenAICompatibleConfiguration.endpoint
        openAICompatibleAPIKeyFile = cleanOpenAICompatibleConfiguration.apiKeyFile
        openAICompatibleAPIKeyName = cleanOpenAICompatibleConfiguration.apiKeyName
        openAICompatibleDisplayName = cleanOpenAICompatibleConfiguration.displayName
        application.setSeparatesRunTranscripts(separatesRunTranscripts)
        await application.setCodexDebugMode(codexDebugMode)
        return true
    }
}
