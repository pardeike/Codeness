import SwiftUI

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
