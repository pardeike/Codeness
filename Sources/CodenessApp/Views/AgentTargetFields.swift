import CodenessCore
import SwiftUI

struct AgentTargetFields: View {
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
                        .help("Choose an available model, or enter a full model identifier")
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
                    Text("Speed")
                    Toggle("Fast", isOn: fastModeBinding)
                    .toggleStyle(.checkbox)
                }
            }
            .font(.caption)

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

    private var fastModeBinding: Binding<Bool> {
        Binding(
            get: { target.options.speed == .fast },
            set: { target.options.speed = $0 ? .fast : .standard }
        )
    }
}
