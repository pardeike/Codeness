import AppKit
import CodenessCore
import SwiftUI

struct RepositoryWindowView: View {
    @Bindable var coordinator: RepositoryCoordinator
    let appearanceState: RepositoryWindowAppearanceState
    @Environment(CodenessApplicationModel.self) private var application
    @Environment(RepositoryWindowCommandState.self) private var commandState
    @State private var showsSettings = false
    @State private var showsGoalAmendment = false
    @State private var showsStartOverConfirmation = false
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var steerMessage = ""
    @State private var isSendingSteer = false
    @FocusState private var isSteerFieldFocused: Bool

    init(
        coordinator: RepositoryCoordinator,
        appearanceState: RepositoryWindowAppearanceState
    ) {
        self.coordinator = coordinator
        self.appearanceState = appearanceState
        _columnVisibility = State(
            initialValue: coordinator.activity == nil
                ? .detailOnly
                : (coordinator.viewState.sidebarVisible ? .all : .detailOnly)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                runList
                    .navigationSplitViewColumnWidth(
                        min: RepositoryWindowMetrics.minimumSidebarWidth,
                        ideal: coordinator.viewState.sidebarWidth
                            ?? RepositoryWindowMetrics.idealSidebarWidth,
                        max: RepositoryWindowMetrics.maximumSidebarWidth
                    )
            } detail: {
                detailColumn
            }
            .background {
                RepositorySplitViewStateBridge(
                    restoredSidebarWidth: coordinator.viewState.sidebarWidth.map { CGFloat($0) },
                    optimalSidebarWidth: optimalSidebarWidth,
                    allowsSidebarRestoration: coordinator.activity != nil
                        && columnVisibility != .detailOnly,
                    onSidebarChange: { width, isVisible in
                        coordinator.updateSidebar(width: Double(width), isVisible: isVisible)
                    }
                )
                .frame(width: 0, height: 0)
            }
            .onChange(of: columnVisibility) { _, visibility in
                coordinator.updateSidebar(
                    width: coordinator.viewState.sidebarWidth,
                    isVisible: visibility != .detailOnly
                )
            }
            .onChange(of: coordinator.activity?.id) { _, activityID in
                columnVisibility = activityID == nil ? .detailOnly : .all
            }
            Divider()
            statusBar
        }
        // Attach the toolbar to the window-level container, not to either
        // NavigationSplitView column. Its leading items then keep the same
        // placement when the run list is shown or hidden.
        .toolbar { toolbarContent }
        .toolbar(removing: .sidebarToggle)
        .sheet(isPresented: $showsSettings) {
            RepositorySettingsSheet(coordinator: coordinator)
                .environment(application)
        }
        .sheet(isPresented: $showsGoalAmendment) {
            GoalAmendmentSheet(coordinator: coordinator)
        }
        .sheet(isPresented: interactionBinding) {
            if let interaction = coordinator.pendingInteraction {
                ServerInteractionSheet(coordinator: coordinator, interaction: interaction)
                    .id(interaction.id.encodedString())
            }
        }
        .alert("Repository Error", isPresented: coordinatorErrorBinding) {
            Button("OK") { coordinator.clearError() }
                .help("Dismiss this repository error")
        } message: {
            Text(coordinator.errorMessage ?? "Unknown error")
        }
        .alert("Codeness", isPresented: applicationErrorBinding) {
            Button("OK") { application.clearError() }
                .help("Dismiss this Codeness error")
        } message: {
            Text(application.applicationError ?? "Unknown error")
        }
        .alert("Start Over in This Repository?", isPresented: $showsStartOverConfirmation) {
            Button("Cancel", role: .cancel) {}
                .help("Keep the current Codeness activity and its session pair")
            Button("Start Over", role: .destructive) {
                Task { await coordinator.startOver() }
            }
            .help("Archive the current Codeness activity and return to editable configuration")
        } message: {
            Text(
                "Codeness will archive the current activity under Application Support, copy its goal and workflow into editable fields, and discard its old agent sessions. Repository files will not be changed."
            )
        }
        .onChange(of: commandState.steerFocusRequest) {
            guard commandState.steerFocusTargetPath == coordinator.record.canonicalPath,
                  coordinator.canInterrupt else { return }
            isSteerFieldFocused = true
        }
        .onChange(of: commandState.goalAmendmentRequest) {
            guard commandState.goalAmendmentTargetPath == coordinator.record.canonicalPath,
                  coordinator.canAmendGoal else { return }
            showsGoalAmendment = true
        }
        .onChange(of: commandState.startOverRequest) {
            guard commandState.startOverTargetPath == coordinator.record.canonicalPath,
                  coordinator.canStartOver else { return }
            showsStartOverConfirmation = true
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if coordinator.activity == nil {
            if let workflow = coordinator.record.activityDraft?.workflow
                ?? application.workflowCatalog.defaultTemplate {
                ActivityConfigurationView(
                    coordinator: coordinator,
                    suggestedGoal: coordinator.record.activityDraft?.goal ?? "",
                    suggestedWorkflow: workflow
                )
            } else {
                ContentUnavailableView(
                    "Workflows Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Restore the bundled workflow resources, then reopen this repository.")
                )
            }
        } else if let run = coordinator.selectedRun {
            RunDetailView(coordinator: coordinator, run: run)
                .id(run.id)
        } else {
            WorkOverviewView(coordinator: coordinator)
        }
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            detailContent
            if coordinator.canInterrupt {
                Divider()
                steerComposer
            }
        }
    }

    private var steerComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Steer the active turn…", text: $steerMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($isSteerFieldFocused)
                .submitLabel(.send)
                .onSubmit {
                    Task { await sendSteerMessage() }
                }
                .help("Send additional guidance to the currently running agent turn")
            Button {
                Task { await sendSteerMessage() }
            } label: {
                Label("Send", systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isSendingSteer
                    || steerMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .help("Send this guidance to the active turn")
        }
        .padding(10)
        .background(.bar)
    }

    private var runList: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(selection: runSelectionBinding) {
                    if let activity = coordinator.activity {
                        ForEach(RunGroupingPolicy.workUnits(for: activity.runs)) { group in
                            Section {
                                ForEach(group.runs) { run in
                                    RunRow(
                                        run: run,
                                        isActive: coordinator.activeActivity?.status == .running
                                            && coordinator.liveRunID == run.id
                                    )
                                    .tag(run.id)
                                    .id(run.id)
                                    .help(
                                        "Show \(run.displayName) "
                                            + "(\(run.status.displayName.lowercased())) transcript"
                                    )
                                }
                            } header: {
                                RunGroupHeader(group: group)
                            }
                        }
                    }

                    Color.clear
                        .frame(height: 8)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .accessibilityHidden(true)
                        .id(RunListScrollAnchor.bottom)
                }
                .background {
                    ListBackgroundDeselectionBridge {
                        coordinator.selectRun(nil)
                    }
                }
                .modifier(RunListTopEdgeProtection())
                .onAppear {
                    guard followedRunID != nil else { return }
                    proxy.scrollTo(RunListScrollAnchor.bottom, anchor: .bottom)
                }
                .onChange(of: followedRunID) { _, runID in
                    guard runID != nil else { return }
                    scrollRunListToBottom(using: proxy)
                }
                .onChange(of: coordinator.transcriptFollowRequestRevision) {
                    scrollRunListToBottom(using: proxy)
                }
                .onChange(of: workflowControls) {
                    guard followedRunID != nil else { return }
                    scrollRunListToBottom(using: proxy)
                }
            }

            if workflowControls.isVisible {
                Divider()
                workflowControlBar
            }
        }
    }

    private var followedRunID: UUID? {
        let selectedRunFollowsOutput = coordinator.selectedRunID.map {
            coordinator.transcriptViewport(for: $0).followsOutput
        } ?? false
        return RunListFollowPolicy.targetRunID(
            selectedRunID: coordinator.selectedRunID,
            liveRunID: coordinator.liveRunID,
            latestRunID: coordinator.activity?.runs.last?.id,
            selectedRunFollowsOutput: selectedRunFollowsOutput
        )
    }

    private var runSelectionBinding: Binding<UUID?> {
        Binding(
            get: { coordinator.selectedRunID },
            set: { coordinator.selectRun($0) }
        )
    }

    private func scrollRunListToBottom(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(RunListScrollAnchor.bottom, anchor: .bottom)
            }
        }
    }

    private var workflowControlBar: some View {
        HStack(spacing: 10) {
            if let transport = workflowControls.transport {
                workflowTransportButton(transport)
            }

            if let immediateControl = workflowControls.immediateControl {
                Button {
                    Task { await coordinator.interrupt() }
                } label: {
                    Text(immediateControl.buttonTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityLabel(immediateControl.accessibilityLabel)
                .accessibilityHint(immediateControl.help)
                .help(immediateControl.help)
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background {
            Rectangle()
                .fill(.bar)
                .overlay {
                    if workflowControls.transport?.pauseNotice != nil {
                        Color.orange.opacity(0.08)
                    }
                }
        }
    }

    private var workflowControls: WorkflowControlPresentation {
        WorkflowControlPresentation(
            canResume: coordinator.canResume && !selectedRunHasInlineRecoveryActions,
            isActivityRunning: coordinator.activity?.status == .running,
            pauseAfterCurrent: coordinator.pauseAfterCurrent,
            canInterrupt: coordinator.canInterrupt
        )
    }

    private var selectedRunHasInlineRecoveryActions: Bool {
        guard let selectedRun = coordinator.selectedRun else { return false }
        return RunRecoveryPresentation(
            activity: coordinator.activity,
            run: selectedRun
        )?.isActionable == true
    }

    private var optimalSidebarWidth: CGFloat {
        let runs = coordinator.activity?.runs ?? []
        let groups = coordinator.activity.map {
            RunGroupingPolicy.workUnits(for: $0.runs)
        } ?? []
        var controlTitles = workflowControls.transport.map {
            [$0.buttonTitle]
        } ?? []
        if let immediateControl = workflowControls.immediateControl {
            controlTitles.append(immediateControl.buttonTitle)
        }
        return RepositoryWindowMetrics.optimalSidebarWidth(
            rowTitles: runs.map(\.displayName),
            rowMetadata: runs.map {
                runSidebarMetadata($0, targetName: application.targetDisplayName)
            },
            sectionTitles: groups.map(\.title),
            controlTitles: controlTitles
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if coordinator.activity != nil {
            ToolbarItem(placement: .navigation) {
                Button {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                } label: {
                    Label(
                        columnVisibility == .detailOnly ? "Show Run List" : "Hide Run List",
                        systemImage: "list.bullet"
                    )
                }
                .help(columnVisibility == .detailOnly ? "Show run list" : "Hide run list")
            }
        }

        ToolbarItem(placement: .navigation) {
            Button {
                showsSettings = true
            } label: {
                Label("Workflow Preferences", systemImage: "gearshape")
            }
            .help("Configure agent targets for future workflow steps")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .help("Workflow status: \(coordinator.statusMessage)")
            Text(coordinator.statusMessage)
                .help("Workflow status: \(coordinator.statusMessage)")
            Spacer()
            Text("Codex: \(application.serverState.label)")
                .help("Codex status: \(application.serverState.label)")
            Text("·")
            Text("Claude: \(application.claudeState.label)")
                .help("Claude status: \(application.claudeState.label)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var statusColor: Color {
        if coordinator.errorMessage != nil { return .red }
        if coordinator.activeActivity?.status == .paused { return .orange }
        if coordinator.activeRun?.status == .running { return .green }
        if coordinator.activity?.status == .completed { return .blue }
        return .secondary
    }

    private var interactionBinding: Binding<Bool> {
        Binding(
            get: { coordinator.pendingInteraction != nil },
            set: { isPresented in
                if !isPresented, coordinator.pendingInteraction != nil {
                    Task { await coordinator.cancelInteraction() }
                }
            }
        )
    }

    private var coordinatorErrorBinding: Binding<Bool> {
        Binding(
            get: { coordinator.errorMessage != nil },
            set: { if !$0 { coordinator.clearError() } }
        )
    }

    private var applicationErrorBinding: Binding<Bool> {
        Binding(
            get: { application.applicationError != nil },
            set: { if !$0 { application.clearError() } }
        )
    }

    private func sendSteerMessage() async {
        guard !isSendingSteer else { return }
        let message = steerMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        isSendingSteer = true
        defer { isSendingSteer = false }
        if await coordinator.steer(message) {
            steerMessage = ""
        }
    }

    private func perform(_ transport: WorkflowTransportControl) {
        switch transport {
        case .resume:
            Task { await coordinator.resume() }
        case .pauseAfterCurrent:
            coordinator.setPauseAfterCurrent(true)
        case .keepRunning:
            coordinator.setPauseAfterCurrent(false)
        }
    }

    @ViewBuilder
    private func workflowTransportButton(_ transport: WorkflowTransportControl) -> some View {
        if appearanceState.appearsActive {
            workflowTransportButtonContent(transport)
                .buttonStyle(
                    ActiveWorkflowTransportButtonStyle(
                        tint: transportTint(for: transport)
                    )
                )
        } else {
            workflowTransportButtonContent(transport)
                .buttonStyle(.borderedProminent)
                .tint(transportTint(for: transport))
        }
    }

    private func workflowTransportButtonContent(
        _ transport: WorkflowTransportControl
    ) -> some View {
        Button {
            perform(transport)
        } label: {
            Text(transport.buttonTitle)
                .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(transport.title)
        .accessibilityHint(transport.help)
        .help(transport.help)
    }

    private func transportTint(for transport: WorkflowTransportControl) -> Color {
        switch transport.emphasis {
        case .caution: .orange
        case .proceed: .green
        }
    }
}

private struct ActiveWorkflowTransportButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(height: 24)
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.78 : 1))
            }
            .contentShape(Rectangle())
    }
}

private enum RunListScrollAnchor {
    static let bottom = "run-list-follow-bottom"
}

private struct RunListTopEdgeProtection: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}

private struct RunGroupHeader: View {
    let group: RunWorkUnit

    var body: some View {
        Text(group.title)
    }
}

private func runSidebarMetadata(
    _ run: RunRecord,
    targetName: (AgentTarget) -> String
) -> String {
    let target = run.agentTarget.map {
        targetName($0)
    } ?? run.kind.displayName
    return "\(target) · \(run.status.displayName)"
}

private struct RunRow: View {
    let run: RunRecord
    let isActive: Bool
    @Environment(CodenessApplicationModel.self) private var application

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(run.displayName)
                        .lineLimit(1)
                    Spacer()
                    if isActive {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("Active run")
                            .help("This is the currently active run")
                    }
                }
                HStack(spacing: 5) {
                    Text(run.agentTarget.map {
                        application.targetDisplayName($0)
                    } ?? run.kind.displayName)
                    Text("·")
                    Text(run.status.displayName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var symbol: String {
        switch run.status {
        case .queued: "clock"
        case .running: "waveform"
        case .routing: "arrow.left.arrow.right"
        case .awaitingApproval: "questionmark.circle"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .interrupted: "stop.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch run.status {
        case .running: .green
        case .routing, .awaitingApproval, .paused: .orange
        case .completed: .blue
        case .interrupted, .failed: .red
        case .queued: .secondary
        }
    }
}
