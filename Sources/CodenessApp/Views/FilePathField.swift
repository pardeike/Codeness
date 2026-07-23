import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FilePathField: View {
    @Binding var path: String
    let placeholder: String
    let panelTitle: String
    let prompt: String
    var requiresExecutable = false

    @State private var isDropTargeted = false
    @State private var showsManualEditor = false
    @State private var manualPath = ""

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(path.isEmpty ? placeholder : path)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: requiresExecutable ? "terminal" : "doc")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Browse…") {
                presentOpenPanel()
            }
            .help("Choose this file with the standard macOS file browser")

            Menu {
                Button("Enter Path Manually…") {
                    manualPath = path
                    showsManualEditor = true
                }
                if !path.isEmpty {
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                    Button("Clear Path") {
                        path = ""
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Show advanced path options")
            .popover(isPresented: $showsManualEditor, arrowEdge: .bottom) {
                manualPathEditor
            }
        }
        .padding(4)
        .background(
            isDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.16))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL),
                  isAccepted(url) else { return false }
            path = NSString(string: url.path).abbreviatingWithTildeInPath
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
    }

    private var manualPathEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter Path Manually")
                .font(.headline)
            TextField("", text: $manualPath, prompt: Text(placeholder))
                .labelsHidden()
                .accessibilityLabel(placeholder)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
                .onSubmit {
                    applyManualPath()
                }
            HStack {
                Spacer()
                Button("Cancel") {
                    showsManualEditor = false
                }
                Button("Apply") {
                    applyManualPath()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private func applyManualPath() {
        path = manualPath.trimmingCharacters(in: .whitespacesAndNewlines)
        showsManualEditor = false
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = panelTitle
        panel.prompt = prompt
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = requiresExecutable ? [.unixExecutable] : [.json, .data]
        panel.allowsOtherFileTypes = true

        panel.begin { response in
            guard response == .OK, let url = panel.url, isAccepted(url) else { return }
            path = NSString(string: url.path).abbreviatingWithTildeInPath
        }
    }

    private func isAccepted(_ url: URL) -> Bool {
        !requiresExecutable || FileManager.default.isExecutableFile(atPath: url.path)
    }
}
