import AppKit
import CodenessCore
import SwiftUI

struct PromptTemplateFields: View {
    @Binding var prompts: ActivityPrompts

    var body: some View {
        PromptTemplateEditor(
            title: "1. Implement",
            description: "Drives one self-chosen, review-sized work unit. The complete Goal is automatically supplied above this prompt as THE GOAL.",
            helpText: "Edit the prompt used to implement each review-sized work unit.",
            text: $prompts.implementation
        )
        PromptTemplateEditor(
            title: "2. Review",
            description: "Reviews that work unit against THE GOAL without editing. {{implementation_output}} is replaced with the filtered implementer result.",
            helpText: "Edit the prompt used to review the preceding implementation output.",
            text: $prompts.review
        )
        PromptTemplateEditor(
            title: "3. Fix",
            description: "Addresses only the review findings in the context of THE GOAL. {{review_output}} is replaced with the filtered reviewer result.",
            helpText: "Edit the prompt used to address the preceding review feedback.",
            text: $prompts.fix
        )
    }
}

private struct PromptTemplateEditor: View {
    let title: String
    let description: String
    let helpText: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ActivityTextEditor(
                text: $text,
                minHeight: 125,
                accessibilityLabel: title,
                helpText: helpText
            )
        }
    }
}

struct ActivityTextEditor: View {
    @Binding var text: String
    let minHeight: CGFloat
    let accessibilityLabel: String
    let helpText: String
    var placeholder: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .textBackgroundColor)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                // TextEditor contributes a small native text-container inset.
                // Eight surrounding points align its caret and content with
                // the placeholder's existing nine-point overlay inset.
                .padding(8)
                .accessibilityLabel(accessibilityLabel)
                .help(helpText)

            if text.isEmpty, let placeholder {
                Text(placeholder)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 9)
                    .padding(.top, 9)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.separator)
        }
    }
}
