import CodenessCore
import SwiftUI

struct SteerSheet: View {
    let coordinator: RepositoryCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Steer Active Turn")
                .font(.title2.weight(.semibold))
            Text("The message is injected into the currently running Codex turn.")
                .foregroundStyle(.secondary)
            TextEditor(text: $message)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .border(Color(nsColor: .separatorColor))
                .help("Enter additional guidance to inject into the active Codex turn")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .help("Close this sheet without steering the active turn")
                Button("Send") {
                    Task {
                        await coordinator.steer(message)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .help("Inject this guidance into the active Codex turn")
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 300)
    }
}
