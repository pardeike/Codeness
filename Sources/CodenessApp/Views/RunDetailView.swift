import AppKit
import CodenessCore
import SwiftUI

struct RunDetailView: View {
    let coordinator: RepositoryCoordinator
    let run: RunRecord

    @Environment(CodenessApplicationModel.self) private var application
    @State private var scrollToEndRequest = 0
    @State private var isAtBottom: Bool

    init(coordinator: RepositoryCoordinator, run: RunRecord) {
        self.coordinator = coordinator
        self.run = run
        _isAtBottom = State(initialValue: coordinator.transcriptViewport(for: run.id).followsOutput)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcriptAndFinalResult
            if let relayError = run.relayError {
                Divider()
                RelayRecoveryView(coordinator: coordinator, run: run, error: relayError)
                    .frame(maxHeight: 270)
            }
        }
    }

    @ViewBuilder
    private var transcriptAndFinalResult: some View {
        if let finalOutput = run.finalOutput, !finalOutput.isEmpty {
            switch coordinator.runDetailPresentation {
            case .split:
                VSplitView {
                    transcript
                        .frame(minHeight: 180)
                    FinalResultView(
                        text: finalOutput,
                        repositoryPath: coordinator.record.canonicalPath
                    )
                    .frame(minHeight: 120, idealHeight: 260)
                }
            case .transcript:
                transcript
            case .result:
                FinalResultView(
                    text: finalOutput,
                    repositoryPath: coordinator.record.canonicalPath
                )
            }
        } else {
            transcript
        }
    }

    private var transcript: some View {
        SelectableTranscriptView(
            text: RunTranscriptPresentation.text(
                for: run,
                separatesRuns: application.separatesRunTranscripts,
                visibility: TranscriptVisibility(
                    reasoning: application.transcriptVisibility.reasoning,
                    actions: application.transcriptVisibility.actions,
                    results: run.finalOutput?.isEmpty != false,
                    diagnostics: application.transcriptVisibility.diagnostics
                )
            ),
            initialViewport: coordinator.transcriptViewport(for: run.id),
            scrollToEndRequest: scrollToEndRequest,
            onViewportChange: { viewport in
                isAtBottom = viewport.followsOutput
                coordinator.updateTranscriptViewport(for: run.id, state: viewport)
            }
        )
        .accessibilityLabel("Run transcript")
        .help("Select or scroll this run transcript; press Command-F to search it")
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                runIdentity
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                expandedControls
                    .fixedSize(horizontal: true, vertical: false)
            }
            HStack(spacing: 10) {
                runIdentity
                    .layoutPriority(1)
                Spacer(minLength: 4)
                compactControls
            }
        }
        .padding(12)
    }

    private var runIdentity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(run.handoff?.runLabel ?? run.kind.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(run.status.rawValue.capitalized)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .fixedSize()
            }
            Text("\(run.kind.displayName) · \(run.effort.capitalized) reasoning\(durationText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var expandedControls: some View {
        HStack(spacing: 8) {
            if run.finalOutput?.isEmpty == false {
                presentationPicker
            }
            visibilityMenu
            jumpToEndButton
            if let handoff = run.handoff {
                Button {
                    copy(handoff.handoffText)
                } label: {
                    Label("Copy Handoff", systemImage: "arrow.left.arrow.right")
                }
                .help("Copy the filtered context passed to the next workflow phase")
            }
        }
    }

    private var compactControls: some View {
        Menu {
            if run.finalOutput?.isEmpty == false {
                Picker("Presentation", selection: presentationBinding) {
                    ForEach(RunDetailPresentation.allCases, id: \.self) { presentation in
                        Text(presentation.displayName).tag(presentation)
                    }
                }
                Divider()
            }
            transcriptVisibilityControls
            Divider()
            Button("Jump to End") {
                scrollToEndRequest &+= 1
            }
            .disabled(isAtBottom)
            if let handoff = run.handoff {
                Button("Copy Handoff") {
                    copy(handoff.handoffText)
                }
            }
        } label: {
            Label("Run Actions", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("Choose presentation, transcript visibility, and run actions")
    }

    private var presentationPicker: some View {
        Picker("Presentation", selection: presentationBinding) {
            ForEach(RunDetailPresentation.allCases, id: \.self) { presentation in
                Text(presentation.displayName).tag(presentation)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 230)
        .help("Show the transcript, final result, or both")
    }

    private var visibilityMenu: some View {
        Menu {
            transcriptVisibilityControls
        } label: {
            Label("Show", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Choose which kinds of run history appear in every run detail")
    }

    @ViewBuilder
    private var transcriptVisibilityControls: some View {
        Toggle("Reasoning", isOn: visibilityBinding(\.reasoning))
            .help("Show or hide reasoning and plan updates")
        Toggle("Actions", isOn: visibilityBinding(\.actions))
            .help("Show or hide tool calls and action output")
        Toggle("Diagnostics", isOn: visibilityBinding(\.diagnostics))
            .help("Show or hide warnings, errors, and diagnostic events")
        Divider()
        Button("Recommended") {
            application.setTranscriptVisibility(.recommended)
        }
        .help("Show reasoning and diagnostics while hiding routine actions")
        Button("Show All") {
            application.setTranscriptVisibility(.all)
        }
        .help("Show reasoning, actions, and diagnostics")
    }

    private var jumpToEndButton: some View {
        Button {
            scrollToEndRequest &+= 1
        } label: {
            Label("Jump to End", systemImage: "arrow.down.to.line")
        }
        .disabled(isAtBottom)
        .help(isAtBottom ? "Already at the end" : "Jump to the latest transcript output and resume following")
    }

    private var presentationBinding: Binding<RunDetailPresentation> {
        Binding(
            get: { coordinator.runDetailPresentation },
            set: { coordinator.updateRunDetailPresentation($0) }
        )
    }

    private func visibilityBinding(
        _ keyPath: WritableKeyPath<TranscriptVisibility, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { application.transcriptVisibility[keyPath: keyPath] },
            set: { value in
                var visibility = application.transcriptVisibility
                visibility[keyPath: keyPath] = value
                application.setTranscriptVisibility(visibility)
            }
        )
    }

    private var durationText: String {
        guard let duration = run.durationMilliseconds else { return "" }
        let seconds = (Double(duration) / 1_000).formatted(.number.precision(.fractionLength(1)))
        return " · \(seconds)s"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct FinalResultView: View {
    let text: String
    let repositoryPath: String

    @State private var isFormatted = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Final Result")
                    .font(.headline)
                Spacer()
                Toggle("Formatted", isOn: $isFormatted)
                    .toggleStyle(.checkbox)
                    .help("Show rendered Markdown; turn this off to show its exact source")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy Final", systemImage: "doc.on.doc")
                }
                .help("Copy the exact final result")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()

            if isFormatted {
                MarkdownResultView(text: text, repositoryPath: repositoryPath)
                    .help("Select rendered Markdown or open one of its links")
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .help("Select or scroll the exact final-result source")
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Final result")
    }
}

private struct RelayRecoveryView: View {
    let coordinator: RepositoryCoordinator
    let run: RunRecord
    let error: String

    @State private var handoffText: String
    @State private var disposition: SourceDisposition
    @State private var label = "Unfiltered handoff"

    init(coordinator: RepositoryCoordinator, run: RunRecord, error: String) {
        self.coordinator = coordinator
        self.run = run
        self.error = error
        _handoffText = State(initialValue: run.finalOutput ?? "")
        _disposition = State(initialValue: Self.defaultDisposition(for: run.kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                Text("Relay paused")
                    .font(.headline)
                Text(error)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Retry Relay") {
                    Task { await coordinator.retryRelay() }
                }
                .help("Retry filtering and routing this run's final result through the handoff model")
            }
            HStack {
                Picker("Source state", selection: $disposition) {
                    ForEach(validDispositions, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .help("Choose how the preceding run ended so Codeness can select the next phase")
                TextField("Run label", text: $label)
                    .help("Enter the short label shown for this run in the sidebar")
            }
            TextEditor(text: $handoffText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 90)
                .border(.separator)
                .help("Edit the handoff text that will be sent to the next workflow phase")
            HStack {
                Spacer()
                Button("Use This Handoff") {
                    Task {
                        await coordinator.useHandoff(
                            text: handoffText,
                            disposition: disposition,
                            label: label
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .help("Use this edited handoff and continue to the next workflow phase")
                .disabled(handoffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
    }

    private var validDispositions: [SourceDisposition] {
        SourceDisposition.validValues(for: run.kind)
    }

    private static func defaultDisposition(for kind: RunKind) -> SourceDisposition {
        switch kind {
        case .implementation: .implementationCheckpoint
        case .review: .reviewComplete
        case .fix: .fixCheckpoint
        }
    }
}
