import AppKit
import CodenessCore
import SwiftUI

struct RunDetailView: View {
    let coordinator: RepositoryCoordinator
    let run: RunRecord

    @Environment(CodenessApplicationModel.self) private var application
    @State private var scrollToEndRequest = 0
    @State private var isAtBottom: Bool
    @State private var showsReasoning = true
    @State private var showsActions = false
    @State private var showsDiagnostics = true

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
            } else if let handoff = run.handoff {
                Divider()
                HandoffSummaryView(handoff: handoff)
            }
        }
    }

    @ViewBuilder
    private var transcriptAndFinalResult: some View {
        if let finalOutput = run.finalOutput, !finalOutput.isEmpty {
            VSplitView {
                transcript
                    .frame(minHeight: 180)
                FinalResultView(text: finalOutput)
                    .frame(minHeight: 120, idealHeight: 220)
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
                    reasoning: showsReasoning,
                    actions: showsActions,
                    results: run.finalOutput?.isEmpty != false,
                    diagnostics: showsDiagnostics
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(run.handoff?.runLabel ?? run.kind.displayName)
                        .font(.headline)
                    Text(run.status.rawValue.capitalized)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text("\(run.kind.displayName) · \(run.model) · \(run.effort) reasoning\(durationText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Toggle("Reasoning", isOn: $showsReasoning)
                    .help("Show or hide reasoning and plan updates")
                Toggle("Actions", isOn: $showsActions)
                    .help("Show or hide tool calls and action output")
                Toggle("Diagnostics", isOn: $showsDiagnostics)
                    .help("Show or hide warnings, errors, and diagnostic events")
                Divider()
                Button("Recommended") {
                    applyVisibility(.recommended)
                }
                .help("Show reasoning and diagnostics while hiding routine actions")
                Button("Show All") {
                    applyVisibility(.all)
                }
                .help("Show reasoning, actions, and diagnostics")
            } label: {
                Label("Show", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Choose which kinds of run history appear in the detail view")
            Button {
                scrollToEndRequest &+= 1
            } label: {
                Label("Jump to End", systemImage: "arrow.down.to.line")
            }
            .disabled(isAtBottom)
            .help(isAtBottom ? "Already at the end" : "Jump to the latest transcript output and resume following")
            if let handoff = run.handoff {
                Button {
                    copy(handoff.handoffText)
                } label: {
                    Label("Copy Handoff", systemImage: "arrow.left.arrow.right")
                }
                .help("Copy the filtered handoff text passed to the next workflow phase")
            }
        }
        .padding(12)
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

    private func applyVisibility(_ visibility: TranscriptVisibility) {
        showsReasoning = visibility.reasoning
        showsActions = visibility.actions
        showsDiagnostics = visibility.diagnostics
    }
}

private struct FinalResultView: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Final Result")
                    .font(.headline)
                Text("Source sent to the handoff model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy Final", systemImage: "doc.on.doc")
                }
                .help("Copy the final result supplied to the handoff model")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .help("Select or scroll the final result supplied to the handoff model")
            .background(Color(nsColor: .textBackgroundColor))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Final result sent to the handoff model")
    }
}

private struct HandoffSummaryView: View {
    let handoff: HandoffEnvelope
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                Text(handoff.handoffText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .frame(maxHeight: 180)
        } label: {
            HStack {
                Text("Handoff")
                Spacer()
                Text(handoff.sourceDisposition.displayName)
                    .foregroundStyle(.secondary)
            }
        }
        .help(expanded ? "Collapse the handoff text" : "Expand the filtered handoff text")
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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
                        await coordinator.useHandoff(text: handoffText, disposition: disposition, label: label)
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
        case .fix: .fixComplete
        }
    }
}
