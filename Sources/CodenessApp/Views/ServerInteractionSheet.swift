import CodenessCore
import SwiftUI

struct ServerInteractionSheet: View {
    let coordinator: RepositoryCoordinator
    let interaction: PendingServerInteraction

    @State private var answers: [String: String]
    @State private var rawResponse = "{}"

    init(coordinator: RepositoryCoordinator, interaction: PendingServerInteraction) {
        self.coordinator = coordinator
        self.interaction = interaction
        _answers = State(initialValue: Dictionary(uniqueKeysWithValues: interaction.questions.map { question in
            (question.id, question.options.first?.label ?? "")
        }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(interaction.title)
                .font(.title2.weight(.semibold))
            if coordinator.pendingInteractionCount > 1 {
                Text("\(coordinator.pendingInteractionCount) requests waiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(interaction.detail)
                .textSelection(.enabled)
            if isApproval {
                approvalActions
            } else if !interaction.questions.isEmpty {
                questionsForm
                HStack {
                    Spacer()
                    Button("Cancel Turn Request") {
                        Task { await coordinator.cancelInteraction() }
                    }
                    .help("Cancel this request and interrupt the Codex turn that issued it")
                    Button("Submit") {
                        let values = answers.mapValues { [$0] }
                        Task { await coordinator.resolveQuestions(values) }
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Submit these answers to the waiting Codex turn")
                    .disabled(interaction.questions.contains { answers[$0.id, default: ""].isEmpty })
                }
            } else {
                genericResponse
            }
            DisclosureGroup("Raw request") {
                ScrollView {
                    Text(interaction.rawParameters.encodedString(prettyPrinted: true))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
            .help("Expand or collapse the raw App Server request parameters")
        }
        .padding(20)
        .frame(width: 660)
        .frame(minHeight: 440)
        .interactiveDismissDisabled()
    }

    private var isApproval: Bool {
        interaction.method == "item/commandExecution/requestApproval" ||
            interaction.method == "item/fileChange/requestApproval"
    }

    private var approvalActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if interaction.approvalDecisions.isEmpty {
                Text("Codex did not offer a valid decision for this request.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel Request", role: .destructive) {
                        Task { await coordinator.cancelInteraction() }
                    }
                    .help("Return an error for this request so the waiting turn is not left blocked")
                }
            } else {
                ForEach(Array(interaction.approvalDecisions.enumerated()), id: \.offset) { _, decision in
                    Button(role: decision.isDestructive ? .destructive : nil) {
                        Task { await coordinator.resolveApproval(decision) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(decision.label)
                                    .fontWeight(.medium)
                                Text(decision.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .help(decision.explanation)
                }
            }
        }
    }

    private var questionsForm: some View {
        Form {
            ForEach(interaction.questions) { question in
                Section(question.header) {
                    Text(question.question)
                    if !question.options.isEmpty {
                        Picker("Answer", selection: answerBinding(for: question.id)) {
                            ForEach(question.options) { option in
                                VStack(alignment: .leading) {
                                    Text(option.label)
                                    if !option.description.isEmpty {
                                        Text(option.description)
                                    }
                                }
                                .tag(option.label)
                            }
                        }
                        .help("Choose an answer for \(question.header)")
                    }
                    if question.isSecret {
                        SecureField("Answer", text: answerBinding(for: question.id))
                            .help("Enter the private answer for \(question.header)")
                    } else {
                        TextField(question.options.isEmpty ? "Answer" : "Or enter another answer", text: answerBinding(for: question.id))
                            .help("Enter an answer for \(question.header)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var genericResponse: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("JSON result")
                .font(.headline)
            TextEditor(text: $rawResponse)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 130)
                .border(Color(nsColor: .separatorColor))
                .help("Edit the JSON response returned to the waiting App Server request")
            HStack {
                Spacer()
                Button("Cancel Request") {
                    Task { await coordinator.cancelInteraction() }
                }
                .help("Cancel this request and interrupt the Codex turn that issued it")
                Button("Respond") {
                    Task { await coordinator.resolveRawInteraction(rawResponse) }
                }
                .buttonStyle(.borderedProminent)
                .help("Send this JSON response to the waiting App Server request")
            }
        }
    }

    private func answerBinding(for id: String) -> Binding<String> {
        Binding(
            get: { answers[id, default: ""] },
            set: { answers[id] = $0 }
        )
    }
}
