import CodenessCore
import SwiftUI

struct WorkflowEditorSheet: View {
    let title: String
    let confirmationTitle: String
    let onApply: (WorkflowTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workflow: WorkflowTemplate

    init(
        title: String,
        confirmationTitle: String,
        workflow: WorkflowTemplate,
        onApply: @escaping (WorkflowTemplate) -> Void
    ) {
        self.title = title
        self.confirmationTitle = confirmationTitle
        self.onApply = onApply
        _workflow = State(initialValue: workflow)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text("Apply updates the staged workflow library. Use Save in Codeness Settings to make the library permanent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            ScrollView {
                WorkflowTemplateFields(workflow: $workflow)
                    .padding(20)
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
                .help("Apply this workflow to the staged Settings library")
            }
            .padding(14)
        }
        .frame(width: 920, height: 760)
    }
}
