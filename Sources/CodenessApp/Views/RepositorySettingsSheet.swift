import CodenessCore
import SwiftUI

struct RepositorySettingsSheet: View {
    let coordinator: RepositoryCoordinator

    @Environment(CodenessApplicationModel.self) private var application
    @Environment(\.dismiss) private var dismiss
    @State private var settings: RepositorySettings

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

                Section("Handoff API Key") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            settingsLabel("API-key JSON file")
                            TextField("API-key JSON file", text: $settings.relay.apiKeyFile)
                                .labelsHidden()
                                .help("Enter the JSON file containing the handoff API key")
                            settingsLabel("JSON key")
                            TextField("JSON key", text: $settings.relay.apiKeyName)
                                .labelsHidden()
                                .frame(width: 170)
                                .help("Enter the property name whose value is the handoff API key")
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
    }

    private func settingsLabel(_ title: String) -> some View {
        Text(title)
            .fixedSize()
            .frame(minWidth: 90, alignment: .leading)
    }
}

struct ModelSelectionGridHeader: View {
    var body: some View {
        GridRow {
            Color.clear
                .frame(width: 110, height: 1)
            Text("Model")
            Text("Reasoning effort")
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
            .frame(minWidth: 300, maxWidth: .infinity)
            .help("Choose the model used for the \(title.lowercased()) phase")
            Picker("Effort", selection: $selection.effort) {
                ForEach(efforts, id: \.self) { effort in
                    Text(effort).tag(effort)
                }
            }
            .labelsHidden()
            .frame(width: 180)
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
