import AppKit
import CodenessCore
import SwiftUI

struct RepositoryWindowView: View {
    @Bindable var coordinator: RepositoryCoordinator
    @Environment(CodenessApplicationModel.self) private var application
    @Environment(RepositoryWindowCommandState.self) private var commandState
    @State private var showsSettings = false
    @State private var showsGoalAmendment = false
    @State private var showsStartOverConfirmation = false
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var steerMessage = ""
    @State private var isSendingSteer = false
    @FocusState private var isSteerFieldFocused: Bool

    init(coordinator: RepositoryCoordinator) {
        self.coordinator = coordinator
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
                        min: 275,
                        ideal: coordinator.viewState.sidebarWidth ?? 330,
                        max: 430
                    )
            } detail: {
                detailColumn
            }
            .background {
                RepositorySplitViewStateBridge(
                    restoredSidebarWidth: coordinator.viewState.sidebarWidth.map { CGFloat($0) },
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
                "Codeness will archive the current activity under Application Support, copy its Goal and prompts into editable fields, and discard the old session IDs. Repository files and per-repository model settings will not be changed."
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
            ActivityConfigurationView(
                coordinator: coordinator,
                suggestedGoal: coordinator.record.activityDraft?.goal ?? "",
                suggestedPrompts: coordinator.record.activityDraft?.prompts
                    ?? application.promptDefaults
            )
        } else if let run = coordinator.selectedRun {
            RunDetailView(coordinator: coordinator, run: run)
                .id(run.id)
        } else {
            ContentUnavailableView(
                "No Run Selected",
                systemImage: "terminal",
                description: Text("Select an Implement, Review, or Fix row to inspect its transcript.")
            )
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
                .help("Send additional guidance to the currently running Codex turn")
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
        List(selection: $coordinator.selectedRunID) {
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
                            .help(
                                "Show \(run.handoff?.runLabel ?? run.kind.displayName) "
                                    + "(\(run.status.rawValue)) transcript"
                            )
                        }
                    } header: {
                        RunGroupHeader(group: group)
                    }
                }
            }
        }
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
                Label("Repository Settings", systemImage: "gearshape")
            }
            .help("Configure models, reasoning effort, and handoff credentials for this repository")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if coordinator.activity != nil {
                Button {
                    showsStartOverConfirmation = true
                } label: {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                }
                .disabled(!coordinator.canStartOver)
                .help(
                    coordinator.canStartOver
                        ? "Archive this Codeness activity and return to its editable Goal and prompts without changing repository files"
                        : "Pause or finish the current work before starting over"
                )
            }

            if let liveRunID = coordinator.liveRunID, coordinator.selectedRunID != liveRunID {
                Button {
                    coordinator.selectLiveRun()
                } label: {
                    Label("Jump to Live", systemImage: "dot.radiowaves.left.and.right")
                }
                .help("Select the currently active run and show its live transcript")
            }

            if coordinator.canResume {
                Button {
                    Task { await coordinator.resume() }
                } label: {
                    Label("Resume Automatically", systemImage: "play.fill")
                }
                .help("Resume from the saved checkpoint and continue subsequent phases automatically")
            } else if coordinator.activeActivity != nil {
                Button {
                    coordinator.setPauseAfterCurrent(!coordinator.pauseAfterCurrent)
                } label: {
                    Label(
                        coordinator.pauseAfterCurrent ? "Keep Running" : "Pause After Current",
                        systemImage: coordinator.pauseAfterCurrent ? "arrow.forward.circle" : "pause.circle"
                    )
                }
                .help(
                    coordinator.pauseAfterCurrent
                        ? "Cancel the pending pause and continue automatically after this run"
                        : "Pause the workflow after the current run reaches a safe stopping point"
                )
            }

            if coordinator.canAmendGoal {
                Button {
                    showsGoalAmendment = true
                } label: {
                    Label("Amend Goal", systemImage: "square.and.pencil")
                }
                .help("Revise the Goal used by subsequent workflow phases while retaining its change history")
            }

            if coordinator.canInterrupt {
                Button {
                    Task { await coordinator.interrupt() }
                } label: {
                    Label("Interrupt", systemImage: "stop.fill")
                }
                .help("Interrupt the active Codex turn and preserve a resumable checkpoint")
            }

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
            Text(application.serverState.label)
                .help("Codex App Server status: \(application.serverState.label)")
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
}

private struct RunGroupHeader: View {
    let group: RunWorkUnit

    var body: some View {
        Text("Work Unit \(group.number)")
    }
}

private struct RunRow: View {
    let run: RunRecord
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(run.handoff?.runLabel ?? run.kind.displayName)
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
                    Text(run.kind.displayName)
                    Text("·")
                    Text(run.status.rawValue.capitalized)
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
