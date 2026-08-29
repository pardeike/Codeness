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
                .background(Color(nsColor: .windowBackgroundColor))
                .zIndex(1)
            Divider()
            if let workerBrief = WorkerBriefPresentation(
                snapshot: run.liveTeamMember,
                prompt: run.prompt
            ) {
                VSplitView {
                    WorkerBriefView(presentation: workerBrief)
                        .id(run.id)
                        .frame(minHeight: 90, idealHeight: 180)
                    transcriptWithLiveStatus
                        .frame(minHeight: 180)
                }
                .background {
                    RunDetailSplitViewStateBridge(
                        restoredFraction: coordinator.viewState.workerBriefFraction ?? 0.26,
                        allowedFractionRange: RepositoryViewState.workerBriefFractionRange,
                        onFractionChange: coordinator.updateWorkerBriefFraction
                    )
                }
            } else {
                transcriptWithLiveStatus
            }
            if let recoveryPresentation {
                Divider()
                RunRecoveryView(
                    coordinator: coordinator,
                    run: run,
                    presentation: recoveryPresentation
                )
                .frame(maxHeight: 180)
            }
        }
    }

    private var transcriptWithLiveStatus: some View {
        transcriptAndFinalResult
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let liveStatusPresentation {
                    RunLiveStatusView(presentation: liveStatusPresentation)
                        .padding(.bottom, 10)
                }
            }
    }

    private var recoveryPresentation: RunRecoveryPresentation? {
        guard !coordinator.requiresLegacyConversion else { return nil }
        return RunRecoveryPresentation(activity: coordinator.activity, run: run)
    }

    private var liveStatusPresentation: RunLiveStatusPresentation? {
        RunLiveStatusPresentation(
            run: run,
            liveRunID: coordinator.liveRunID,
            pauseAfterCurrent: coordinator.pauseAfterCurrent,
            pausedWorkflowMessage: pausedWorkflowMessage
        )
    }

    private var pausedWorkflowMessage: String? {
        guard let activity = coordinator.activity,
              activity.status == .paused,
              activity.runs.last?.id == run.id else {
            return nil
        }
        if case .perform? = activity.liveTeam?.resumeCheckpoint {
            return coordinator.statusMessage
        }
        if case .perform? = activity.workflowResumeCheckpoint {
            return coordinator.statusMessage
        }
        return nil
    }

    @ViewBuilder
    private var transcriptAndFinalResult: some View {
        if let finalOutput = presentedFinalOutput, !finalOutput.isEmpty {
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
                .background {
                    RunDetailSplitViewStateBridge(
                        restoredFraction: coordinator.viewState.detailSplitFraction,
                        onFractionChange: coordinator.updateRunDetailSplitFraction
                    )
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

    private var presentedFinalOutput: String? {
        guard let finalOutput = run.finalOutput,
              let snapshot = run.liveTeamMember,
              let report = CompanyWorkReport.decode(finalOutput, for: snapshot) else {
            return run.finalOutput
        }
        return report.presentationMarkdown
    }

    private var transcript: some View {
        SelectableTranscriptView(
            presentation: RunTranscriptPresentation.content(
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
            scrollToEndRequest: effectiveScrollToEndRequest,
            onViewportChange: { viewport in
                isAtBottom = viewport.followsOutput
                coordinator.updateTranscriptViewport(for: run.id, state: viewport)
            },
            onUserStoppedFollowing: {
                coordinator.stopFollowingActiveProgress(for: run.id)
            }
        )
        .accessibilityLabel("Turn transcript")
        .help("Select or scroll this turn transcript; press Command-F to search it")
    }

    private var effectiveScrollToEndRequest: Int {
        let activeProgressRequest = coordinator.transcriptFollowRequestRunID == run.id
            ? coordinator.transcriptFollowRequestRevision
            : 0
        return scrollToEndRequest &+ activeProgressRequest
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
                Text(run.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(run.status.displayName)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .fixedSize()
            }
            Text(runIdentityDetailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var runIdentityDetailText: String {
        guard let person = run.liveTeamMember?.member.person else {
            return runConfigurationText
        }
        return [
            person.profile.fullName,
            person.position.title,
            runConfigurationText,
        ].joined(separator: " · ")
    }

    private var expandedControls: some View {
        HStack(spacing: 8) {
            if recoveryPresentation == nil,
               coordinator.canRestartWorkflowStep(run.id) {
                RestartWorkflowStepButton(coordinator: coordinator, run: run)
            }
            visibilityMenu
            jumpToEndButton
        }
    }

    private var compactControls: some View {
        Menu {
            if recoveryPresentation == nil,
               coordinator.canRestartWorkflowStep(run.id) {
                RestartWorkflowStepButton(coordinator: coordinator, run: run)
                Divider()
            }
            transcriptVisibilityControls
            Divider()
            Button("Jump to End") {
                scrollToEndRequest &+= 1
            }
            .disabled(isAtBottom)
        } label: {
            Label("Turn Actions", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("Choose transcript visibility and turn actions")
    }

    private var visibilityMenu: some View {
        Menu {
            transcriptVisibilityControls
        } label: {
            Label("Show", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Choose which kinds of history appear in every turn detail")
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

    private var runConfigurationText: String {
        guard let target = run.agentTarget else {
            return "\(run.kind.displayName) · \(run.effort.capitalized) reasoning\(durationText)"
        }
        var values = [application.targetDisplayName(target)]
        if let effort = target.options.effort, !effort.isEmpty {
            values.append("\(effort.capitalized) effort")
        }
        if target.options.mode != .standard {
            values.append(target.options.mode.displayName)
        }
        if target.options.speed == .fast {
            values.append("Fast")
        }
        return values.joined(separator: " · ") + durationText
    }
}

struct WorkerBriefPresentation: Equatable {
    let goal: String
    let assignment: String
    let acceptance: String
    let stop: String
    let handoff: String

    init?(snapshot: LiveTeamMemberSnapshot?, prompt: String) {
        guard let snapshot, let assignment = snapshot.member.companyAssignment else {
            return nil
        }
        let extractedHandoff = Self.promptSection(
            "HANDOFF",
            before: "FUNDED PRODUCT BET",
            in: prompt
        ) ?? "None"
        goal = Self.singleLine(snapshot.workingGoal)
        self.assignment = Self.singleLine(snapshot.member.instructions)
        acceptance = Self.singleLine(assignment.acceptanceEvidence)
        stop = Self.singleLine(assignment.stopCondition)
        handoff = Self.singleLine(extractedHandoff)
    }

    private static func promptSection(
        _ heading: String,
        before nextHeading: String,
        in prompt: String
    ) -> String? {
        let marker = "\n\(heading)\n\n"
        guard let start = prompt.range(of: marker)?.upperBound else { return nil }
        let remainder = prompt[start...]
        let endMarker = "\n\n\(nextHeading)\n"
        guard let end = remainder.range(of: endMarker)?.lowerBound else { return nil }
        let value = prompt[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }
}

private struct WorkerBriefView: View {
    let presentation: WorkerBriefPresentation
    @State private var goalExpanded = false
    @State private var assignmentExpanded = false
    @State private var acceptanceExpanded = false
    @State private var stopExpanded = false
    @State private var handoffExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Worker brief")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    briefSection("Goal", text: presentation.goal, isExpanded: $goalExpanded)
                    briefSection(
                        "Assignment",
                        text: presentation.assignment,
                        isExpanded: $assignmentExpanded
                    )
                    briefSection(
                        "Acceptance",
                        text: presentation.acceptance,
                        isExpanded: $acceptanceExpanded
                    )
                    briefSection("Stop", text: presentation.stop, isExpanded: $stopExpanded)
                    briefSection(
                        "Handoff",
                        text: presentation.handoff,
                        isExpanded: $handoffExpanded
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Worker brief")
    }

    private func briefSection(
        _ title: String,
        text: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        DisclosureGroup(title, isExpanded: isExpanded) {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(.top, 2)
                .padding(.leading, 4)
        }
        .font(.callout.weight(.medium))
    }
}

private struct RunLiveStatusView: View {
    let presentation: RunLiveStatusPresentation

    var body: some View {
        HStack(spacing: 7) {
            if presentation.showsProgress {
                ProgressView()
                    .controlSize(.mini)
                    .tint(tint)
            } else if let systemImage = presentation.systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
            Text(presentation.text)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(tint.opacity(0.28))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.text)
    }

    private var tint: Color {
        switch presentation.tone {
        case .active: .green
        case .attention: .orange
        }
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

private struct RunRecoveryView: View {
    let coordinator: RepositoryCoordinator
    let run: RunRecord
    let presentation: RunRecoveryPresentation

    @State private var showsFullMessage = false
    @State private var showsManualHandoff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                recoveryDetails
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, presentation.isActionable ? 10 : 12)
            }
            .scrollBounceBehavior(.basedOnSize)

            if presentation.isActionable {
                recoveryActions
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(Color.orange.opacity(0.08))
        .sheet(isPresented: $showsManualHandoff) {
            ManualHandoffSheet(
                coordinator: coordinator,
                run: run,
                presentation: presentation,
                initialText: manualHandoffText
            )
        }
    }

    private var recoveryDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    if let title {
                        Text(title)
                            .font(.headline)
                    }
                    Text(presentation.message)
                        .foregroundStyle(title == nil ? .primary : .secondary)
                        .lineLimit(showsFullMessage || !hasMoreDetails ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer()
                if hasMoreDetails {
                    Button(showsFullMessage ? "Less" : "Details…") {
                        showsFullMessage.toggle()
                    }
                    .buttonStyle(.link)
                }
            }

            if presentation.kind == .workflowPaused,
               let handoff = presentation.handoffText,
               !handoff.isEmpty {
                Text(handoff)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
            }
        }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        HStack(spacing: 8) {
            switch presentation.kind {
            case .stepStopped:
                Button("Resume") {
                    Task { await coordinator.resume() }
                }
                .buttonStyle(.borderedProminent)
                if coordinator.canRestartWorkflowStep(run.id) {
                    RestartWorkflowStepButton(coordinator: coordinator, run: run)
                }

            case .handoffFailed:
                Button("Try Again") {
                    Task { await coordinator.retryRelay() }
                }
                .buttonStyle(.borderedProminent)
                Button("Continue with Result…") {
                    showsManualHandoff = true
                }
                .disabled(manualHandoffText.isEmpty)

            case .workflowPaused:
                Button("Try Again") {
                    Task {
                        if presentation.isGenericWorkflow {
                            await coordinator.retryWorkflowStep(run.id)
                        } else {
                            await coordinator.retryRelay()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .help(
                    presentation.isGenericWorkflow
                        ? "Rerun this turn in its existing agent session, falling back to a fresh session if needed"
                        : "Prepare the handoff again"
                )
                Button("Continue Anyway…") {
                    showsManualHandoff = true
                }
                .disabled(manualHandoffText.isEmpty)

            case .historical:
                EmptyView()
            }
        }
    }

    private var title: String? {
        switch presentation.kind {
        case .stepStopped, .historical:
            nil
        case .handoffFailed:
            if let nextStepName = presentation.nextStepName {
                "Couldn’t prepare \(nextStepName)"
            } else {
                "Couldn’t prepare the next agent"
            }
        case .workflowPaused:
            "Activity needs attention"
        }
    }

    private var hasMoreDetails: Bool {
        presentation.message.count > 180 || presentation.message.contains("\n")
    }

    private var manualHandoffText: String {
        (
            run.coordinatorDecision?.handoff
                ?? run.workflowHandoff?.text
                ?? run.handoff?.handoffText
                ?? run.finalOutput
                ?? ""
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ManualHandoffSheet: View {
    let coordinator: RepositoryCoordinator
    let run: RunRecord
    let presentation: RunRecoveryPresentation

    @Environment(\.dismiss) private var dismiss
    @State private var handoffText: String
    @State private var completesWorkflow = false
    @State private var legacyDisposition: SourceDisposition

    init(
        coordinator: RepositoryCoordinator,
        run: RunRecord,
        presentation: RunRecoveryPresentation,
        initialText: String
    ) {
        self.coordinator = coordinator
        self.run = run
        self.presentation = presentation
        _handoffText = State(initialValue: initialText)
        _legacyDisposition = State(initialValue: Self.defaultDisposition(for: run.kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                presentation.kind == .workflowPaused
                    ? "Continue Anyway"
                    : "Continue with Result"
            )
            .font(.headline)

            if presentation.isGenericWorkflow, presentation.canFinishWorkflow {
                Picker("", selection: $completesWorkflow) {
                    Text("Another Round").tag(false)
                    Text("Finish Activity").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            } else if !presentation.isGenericWorkflow, legacyChoices.count > 1 {
                Picker("", selection: $legacyDisposition) {
                    ForEach(legacyChoices, id: \.self) { disposition in
                        Text(legacyLabel(for: disposition)).tag(disposition)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            } else if let nextStepName = presentation.nextStepName {
                Text("This will be sent to \(nextStepName).")
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $handoffText)
                .font(.body)
                .frame(minHeight: 220)
                .border(.separator)
                .accessibilityLabel("Handoff text")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button(submitTitle) {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    handoffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 340)
    }

    private var submitTitle: String {
        if presentation.isGenericWorkflow, completesWorkflow {
            return "Finish"
        }
        if !presentation.isGenericWorkflow, legacyDisposition == .fixComplete {
            return "Finish"
        }
        return "Continue"
    }

    private var legacyChoices: [SourceDisposition] {
        switch run.kind {
        case .implementation:
            [.implementationCheckpoint, .implementationComplete]
        case .review:
            [.reviewComplete]
        case .fix:
            [.fixCheckpoint, .fixComplete]
        }
    }

    private func legacyLabel(for disposition: SourceDisposition) -> String {
        switch disposition {
        case .implementationCheckpoint:
            "More Work"
        case .implementationComplete:
            "Implementation Complete"
        case .reviewComplete:
            "Continue to Fixes"
        case .fixCheckpoint:
            "Continue Implementation"
        case .fixComplete:
            "Finish Activity"
        case .blocked, .failed, .unclear:
            disposition.displayName
        }
    }

    private func submit() {
        let text = handoffText.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = run.coordinatorDecision?.runLabel
            ?? run.workflowHandoff?.runLabel
            ?? run.handoff?.runLabel
            ?? run.workflowStep?.name
            ?? run.kind.displayName
        let isGenericWorkflow = presentation.isGenericWorkflow
        let outcome: WorkflowOutcome = completesWorkflow ? .complete : .continueWorkflow
        let disposition = legacyDisposition
        dismiss()
        Task {
            if isGenericWorkflow {
                await coordinator.useWorkflowHandoff(
                    text: text,
                    outcome: outcome,
                    label: label
                )
            } else {
                await coordinator.useHandoff(
                    text: text,
                    disposition: disposition,
                    label: label
                )
            }
        }
    }

    private static func defaultDisposition(for kind: RunKind) -> SourceDisposition {
        switch kind {
        case .implementation: .implementationCheckpoint
        case .review: .reviewComplete
        case .fix: .fixCheckpoint
        }
    }
}

private struct RestartWorkflowStepButton: View {
    let coordinator: RepositoryCoordinator
    let run: RunRecord

    @State private var showsConfirmation = false

    var body: some View {
        Button {
            showsConfirmation = true
        } label: {
            Label("Restart…", systemImage: "arrow.counterclockwise.circle")
        }
        .help(
            "Run \(stepName) again in a fresh agent session while preserving the repository and previous turn history"
        )
        .confirmationDialog(
            "Restart \(stepName) in a Fresh Session?",
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restart") {
                Task {
                    await coordinator.restartWorkflowStep(run.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The previous turn and transcript remain in history. Repository files are not reverted; the fresh agent will inspect their current state before continuing."
            )
        }
    }

    private var stepName: String {
        run.workflowStep?.name ?? run.kind.displayName
    }
}
