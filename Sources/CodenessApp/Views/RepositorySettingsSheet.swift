import CodenessCore
import Foundation
import SwiftUI

struct RepositorySettingsSheet: View {
    let coordinator: RepositoryCoordinator

    @Environment(CodenessApplicationModel.self) private var application
    @Environment(\.dismiss) private var dismiss
    @State private var settings: RepositorySettings
    @State private var isTestingHandoff = false
    @State private var handoffTestMessage: String?
    @State private var handoffTestSucceeded = false

    init(coordinator: RepositoryCoordinator) {
        self.coordinator = coordinator
        _settings = State(initialValue: coordinator.record.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
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
                            .frame(maxWidth: 300)
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

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .help("Discard repository-setting changes and close this sheet")
                Button("Save") {
                    Task {
                        if await coordinator.updateSettings(settings) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .help("Save these model, reasoning, and handoff settings for this repository")
                .disabled(settings == coordinator.record.settings)
            }
            .padding(14)
        }
        .frame(width: 840, height: 640)
        .onChange(of: settings.relay) {
            handoffTestMessage = nil
            handoffTestSucceeded = false
        }
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
