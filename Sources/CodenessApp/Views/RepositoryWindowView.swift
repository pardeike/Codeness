import AppKit
import CodenessCore
import SwiftUI

struct RepositoryWindowView: View {
    @Bindable var coordinator: RepositoryCoordinator
    let appearanceState: RepositoryWindowAppearanceState
    @Environment(CodenessApplicationModel.self) private var application
    @Environment(RepositoryWindowCommandState.self) private var commandState
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
            Text(startOverExplanation)
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

    private var startOverExplanation: String {
        "Codeness will archive the current activity under Application Support, keep its goal as the next editable draft, and discard its old agent sessions. Repository files will not be changed."
    }

    @ViewBuilder
    private var detailContent: some View {
        if coordinator.activity == nil {
            ActivityConfigurationView(
                coordinator: coordinator,
                suggestedGoal: coordinator.record.activityDraft?.goal ?? ""
            )
        } else if let person = coordinator.selectedCompanyPerson {
            CompanyPersonDetailView(coordinator: coordinator, person: person)
                .id(person.id)
        } else if let review = coordinator.selectedReview {
            OverseerReviewDetailView(review: review)
                .id(review.id)
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
                List(selection: timelineSelectionBinding) {
                    if !coordinator.companyPeople.isEmpty {
                        Section("Company") {
                            ForEach(coordinator.companyPeople) { person in
                                CompanyPersonRow(person: person)
                                    .tag(person.id)
                                    .id(person.id)
                            }
                        }
                    }
                    if let activity = coordinator.activity {
                        ForEach(RunGroupingPolicy.workUnits(for: activity.runs)) { group in
                            Section {
                                ForEach(group.runs) { run in
                                    ForEach(reviews(before: run, in: activity)) { review in
                                        OverseerReviewRow(review: review)
                                            .tag(review.id)
                                            .id(review.id)
                                    }
                                    if reviews(before: run, in: activity).isEmpty,
                                       let change = strategyChange(before: run, in: activity) {
                                        StrategyChapterRow(change: change)
                                    }
                                    RunRow(
                                        run: run,
                                        isActive: coordinator.activeActivity?.status == .running
                                            && coordinator.liveRunID == run.id
                                    )
                                    .tag(run.id)
                                    .id(run.id)
                                    .help(
                                        "Show the \(run.displayName) turn "
                                            + "(\(run.status.displayName.lowercased()))"
                                    )
                                    ForEach(reviews(after: run, in: activity)) { review in
                                        OverseerReviewRow(review: review)
                                            .tag(review.id)
                                            .id(review.id)
                                    }
                                }
                            } header: {
                                RunGroupHeader(group: group)
                            }
                        }

                        ForEach(unrepresentedStrategyChanges(in: activity)) { change in
                            StrategyChapterRow(change: change)
                        }
                        ForEach(unrepresentedReviews(in: activity)) { review in
                            OverseerReviewRow(review: review)
                                .tag(review.id)
                                .id(review.id)
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
                .onChange(of: reviewProgressSignature) {
                    guard coordinator.selectedReviewID == coordinator.activity?
                        .liveTeam?.reviews.last?.id else { return }
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

    private var timelineSelectionBinding: Binding<UUID?> {
        Binding(
            get: {
                coordinator.selectedPersonID
                    ?? coordinator.selectedReviewID
                    ?? coordinator.selectedRunID
            },
            set: { id in
                if let id,
                   coordinator.companyPeople.contains(where: { $0.id == id }) {
                    coordinator.selectCompanyPerson(id)
                } else if let id,
                   coordinator.activity?.liveTeam?.reviews.contains(where: {
                       $0.id == id
                   }) == true {
                    coordinator.selectReview(id)
                } else {
                    coordinator.selectRun(id)
                }
            }
        )
    }

    private var reviewProgressSignature: String {
        guard let review = coordinator.activity?.liveTeam?.reviews.last else { return "" }
        return "\(review.id):\(review.status.rawValue):\(review.completedConsultationCount)"
    }

    private func reviews(
        before run: RunRecord,
        in activity: ActivityRecord
    ) -> [LiveTeamReviewRecord] {
        guard let revision = run.liveTeamMember?.revision,
              activity.runs.first(where: {
                  $0.liveTeamMember?.revision == revision
              })?.id == run.id else { return [] }
        return (activity.liveTeam?.reviews ?? [])
            .filter {
                $0.resultingDefinition != nil && $0.resultingRevision == revision
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func reviews(
        after run: RunRecord,
        in activity: ActivityRecord
    ) -> [LiveTeamReviewRecord] {
        (activity.liveTeam?.reviews ?? [])
            .filter { $0.sourceRunID == run.id && $0.resultingDefinition == nil }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func unrepresentedReviews(
        in activity: ActivityRecord
    ) -> [LiveTeamReviewRecord] {
        let runIDs = Set(activity.runs.map(\.id))
        let runRevisions = Set(activity.runs.compactMap(\.liveTeamMember?.revision))
        return (activity.liveTeam?.reviews ?? [])
            .filter { review in
                if review.resultingDefinition != nil,
                   let revision = review.resultingRevision,
                   runRevisions.contains(revision) {
                    return false
                }
                if review.resultingDefinition == nil,
                   let sourceRunID = review.sourceRunID,
                   runIDs.contains(sourceRunID) {
                    return false
                }
                return true
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func strategyChange(
        before run: RunRecord,
        in activity: ActivityRecord
    ) -> LiveTeamEditRecord? {
        guard let revision = run.liveTeamMember?.revision,
              revision > 1,
              activity.runs.first(where: {
                  $0.liveTeamMember?.revision == revision
              })?.id == run.id else {
            return nil
        }
        return strategyChanges(in: activity).first { $0.revision == revision }
    }

    private func unrepresentedStrategyChanges(
        in activity: ActivityRecord
    ) -> [LiveTeamEditRecord] {
        let runRevisions = Set(activity.runs.compactMap(\.liveTeamMember?.revision))
        return strategyChanges(in: activity).filter {
            !runRevisions.contains($0.revision)
        }
    }

    private func strategyChanges(in activity: ActivityRecord) -> [LiveTeamEditRecord] {
        guard let edits = activity.liveTeam?.editHistory else { return [] }
        let reviewedRevisions = Set(
            (activity.liveTeam?.reviews ?? []).compactMap { review in
                review.resultingDefinition == nil ? nil : review.resultingRevision
            }
        )
        var seenRevisions: Set<Int> = []
        return edits
            .filter { edit in
                edit.actor == .overseer
                    && edit.revision > 1
                    && !reviewedRevisions.contains(edit.revision)
                    && seenRevisions.insert(edit.revision).inserted
            }
            .sorted { $0.createdAt < $1.createdAt }
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
            rowTitles: coordinator.companyPeople.map(\.profile.fullName)
                + runs.map(\.displayName)
                + (coordinator.activity?.liveTeam?.reviews ?? []).map(\.sidebarTitle),
            rowMetadata: runs.map {
                runSidebarMetadata($0, targetName: application.targetDisplayName)
            } + coordinator.companyPeople.map(\.position.title)
                + (coordinator.activity?.liveTeam?.reviews ?? []).map(\.sidebarDetail),
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
                        columnVisibility == .detailOnly ? "Show Turn List" : "Hide Turn List",
                        systemImage: "list.bullet"
                    )
                }
                .help(columnVisibility == .detailOnly ? "Show turn list" : "Hide turn list")
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .help("Activity status: \(coordinator.statusMessage)")
            Text(coordinator.statusMessage)
                .help("Activity status: \(coordinator.statusMessage)")
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

private struct CompanyPersonRow: View {
    let person: CompanyPerson

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: person.positionID == .chiefExecutive
                ? "crown.fill"
                : "person.fill")
                .foregroundStyle(
                    person.positionID == .chiefExecutive ? Color.orange : Color.secondary
                )
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.profile.fullName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(person.position.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .help("Show \(person.profile.fullName)'s story, personality, and assignment")
    }
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

private struct StrategyChapterRow: View {
    let change: LiveTeamEditRecord
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 6) {
            Text("New strategy")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
                .accessibilityHidden(true)
            Button {
                showsDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show strategy change details")
            .help("Show why Codeness changed the agent strategy")
            .popover(isPresented: $showsDetails, arrowEdge: .leading) {
                StrategyChangeDetails(change: change)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .selectionDisabled()
    }
}

private extension LiveTeamReviewRecord {
    var sidebarTitle: String {
        decision?.outcome.displayName ?? mode.reviewDisplayName
    }

    var sidebarDetail: String {
        switch status {
        case .selectingManagers:
            "Gathering company"
        case .consultingManagers:
            "Company check-in · \(completedConsultationCount) of \(consultations.count)"
        case .overseerDeciding:
            "CEO deciding"
        case .completed, .failed:
            "\(mode.reviewDisplayName) · \(decision?.summary ?? "Review finished")"
        }
    }
}

private extension LiveTeamOverseerMode {
    var reviewDisplayName: String {
        switch self {
        case .strategicReview: "Investment review"
        case .completionReview: "Completion review"
        case .bootstrap: "Initial setup"
        case .migration: "Earlier activity setup"
        }
    }
}

private struct OverseerReviewRow: View {
    let review: LiveTeamReviewRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .padding(.bottom, 3)

            HStack(spacing: 8) {
                Text(review.sidebarTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if review.status == .completed || review.status == .failed {
                    Image(systemName: symbol)
                        .foregroundStyle(color)
                        .frame(width: 18)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Review in progress")
                }
            }

            Text(review.sidebarDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.top, 7)
        .padding(.bottom, 3)
        .listRowSeparator(.hidden)
        .help("Show this \(review.mode.reviewDisplayName.lowercased())")
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch review.status {
        case .selectingManagers, .consultingManagers: "person.3.sequence.fill"
        case .overseerDeciding: "eye.fill"
        case .completed:
            switch review.decision?.outcome {
            case .revised: "arrow.triangle.2.circlepath"
            case .completed: "checkmark.seal.fill"
            case .kept: "arrow.forward.circle.fill"
            case .continueWork: "arrow.right.circle.fill"
            case .rejectedPause: "arrow.uturn.forward.circle.fill"
            case .failed, nil: "eye.fill"
            }
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch review.status {
        case .selectingManagers, .consultingManagers, .overseerDeciding: .orange
        case .completed: .purple
        case .failed: .red
        }
    }
}

private struct StrategyChangeDetails: View {
    let change: LiveTeamEditRecord

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Strategy changed")
                    .font(.headline)
                Text(change.summary)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)

                detail("Why", text: change.reason)
                if !change.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    detail("Evidence", text: change.evidence)
                }
            }
            .frame(width: 312, alignment: .leading)
            .padding(14)
        }
        .frame(width: 340, height: 300)
        // A popover presented from a sidebar List inherits its single-line row
        // environment unless the detail surface explicitly restores wrapping.
        .lineLimit(nil)
    }

    private func detail(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func runSidebarMetadata(
    _ run: RunRecord,
    targetName: (AgentTarget) -> String
) -> String {
    if let person = run.liveTeamMember?.member.person {
        return "\(person.profile.fullName) · \(person.position.title)"
    }
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
                            .accessibilityLabel("Active turn")
                            .help("This is the currently active turn")
                    }
                }
                HStack(spacing: 5) {
                    if let person = run.liveTeamMember?.member.person {
                        Text(person.profile.fullName)
                        Text("·")
                        Text(person.position.title)
                    } else {
                        Text(run.agentTarget.map {
                            application.targetDisplayName($0)
                        } ?? run.kind.displayName)
                        Text("·")
                        Text(run.status.displayName)
                    }
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
