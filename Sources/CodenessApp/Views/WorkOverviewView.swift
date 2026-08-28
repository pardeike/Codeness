import AppKit
import CodenessCore
import SwiftUI

struct WorkOverviewView: View {
    @Bindable var coordinator: RepositoryCoordinator
    @Environment(CodenessApplicationModel.self) private var application
    @State private var isGoalExpanded = false

    private var record: RepositoryRecord { coordinator.record }

    var body: some View {
        if let activity = record.activity {
            TimelineView(
                .periodic(
                    from: .now,
                    by: activity.status == .running ? 1 : 60
                )
            ) { context in
                overview(
                    activity: activity,
                    metrics: WorkOverviewMetrics(
                        activity: activity,
                        repositoryUpdatedAt: record.updatedAt,
                        now: context.date
                    )
                )
            }
            .task(id: coordinator.workOverviewSummarySourceSignature) {
                coordinator.requestWorkOverviewSummary()
            }
        }
    }

    private func overview(
        activity: ActivityRecord,
        metrics: WorkOverviewMetrics
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let liveTeam = activity.liveTeam {
                    liveTeamOverview(activity: activity, state: liveTeam)
                }
                if metrics.usesLiveTeam {
                    productReturn(metrics)
                }
                compactSummary(metrics)
                workSummary
                goal(activity.goal)
                phaseTimes(metrics)
                phaseTokens(metrics)
                detailsGrid(activity: activity, metrics: metrics)
            }
            .frame(maxWidth: 1_050, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var workSummary: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let summary = coordinator.workOverviewSummaryText {
                    WorkSummaryMarkdownView(markdown: summary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if coordinator.isGeneratingWorkOverviewSummary {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Summarizing the goal and \(handoffCountText)…")
                            .foregroundStyle(.secondary)
                    }
                } else if let error = coordinator.workOverviewSummaryError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Button("Retry Summary") {
                        coordinator.requestWorkOverviewSummary(force: true)
                    }
                    .help("Ask Codeness to generate the work overview again")
                } else {
                    Label(
                        "A work summary will appear after the first completed handoff.",
                        systemImage: "text.badge.plus"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } label: {
            HStack {
                Label("Work Summary", systemImage: "text.document")
                    .font(.headline)
                Spacer()
                if let generatedAt = coordinator.workOverviewSummaryGeneratedAt {
                    Text("Updated \(generatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if coordinator.hasWorkOverviewSummarySource,
                   !coordinator.isGeneratingWorkOverviewSummary {
                    Button {
                        coordinator.requestWorkOverviewSummary(force: true)
                    } label: {
                        Label("Refresh Summary", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Regenerate the summary from the goal and every handoff")
                }
            }
        }
    }

    private var handoffCountText: String {
        let count = record.activity?.runs.count(where: {
            $0.handoff != nil || $0.workflowHandoff != nil || $0.coordinatorDecision != nil
        }) ?? 0
        return count == 1 ? "handoff" : "\(count) handoffs"
    }

    private func goal(_ text: String) -> some View {
        DisclosureGroup(isExpanded: $isGoalExpanded) {
            Text(text)
                .padding(.top, 8)
                .textSelection(.enabled)
        } label: {
            Label("Goal", systemImage: "scope")
                .font(.headline)
        }
    }

    private func liveTeamOverview(
        activity: ActivityRecord,
        state: LiveTeamState
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if let definition = state.currentDefinition {
                    if let bet = definition.productBet {
                        let fundedUsage = CompanyProductMotor.usage(
                            for: definition,
                            runs: activity.runs
                        )
                        VStack(alignment: .leading, spacing: 5) {
                            Label(bet.headline, systemImage: "bolt.fill")
                                .font(.headline)
                            Text(bet.valuePromise)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Showcase: \(bet.showcase)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ProgressView(
                                value: Double(fundedUsage.effectiveFundingTokens),
                                total: Double(bet.fundedTokenLimit)
                            )
                            Text(
                                "\(WorkOverviewFormatting.tokens(fundedUsage.effectiveFundingTokens)) of \(WorkOverviewFormatting.tokens(bet.fundedTokenLimit)) effective funding tokens used"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Text(definition.strategicReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        if let chiefExecutive = definition.overseerPerson {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(chiefExecutive.profile.fullName)
                                    .fontWeight(.medium)
                                Text(chiefExecutive.position.title)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange.opacity(0.14), in: Capsule())
                                Spacer()
                            }
                        }
                        ForEach(definition.members) { member in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(member.person?.profile.fullName ?? member.name)
                                    .fontWeight(.medium)
                                Text(member.person?.position.title ?? member.runPolicy.displayName)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                                Text(member.sessionPolicy.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }

                } else {
                    HStack(spacing: 10) {
                        if activity.status == .running {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Codeness is preparing the agents.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        } label: {
            Label("Company", systemImage: "person.3.sequence.fill")
                .font(.headline)
        }
    }

    private func productReturn(_ metrics: WorkOverviewMetrics) -> some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Product work")
                    Text(metrics.productTokenUsage.map {
                        WorkOverviewFormatting.tokens($0.totalTokens)
                    } ?? "—")
                        .monospacedDigit()
                }
                GridRow {
                    Text("Company control")
                    Text(metrics.controlTokenUsage.map {
                        WorkOverviewFormatting.tokens($0.totalTokens)
                    } ?? "—")
                        .monospacedDigit()
                }
                GridRow {
                    Text("Investment decisions")
                    Text("\(metrics.investmentDecisionCount)")
                        .monospacedDigit()
                }
                GridRow {
                    Text("Tokens per decision")
                    Text(metrics.tokensPerInvestmentDecision.map {
                        WorkOverviewFormatting.tokens($0)
                    } ?? "—")
                        .monospacedDigit()
                }
            }
            .padding(8)
        } label: {
            Label("Product Return", systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline)
        }
    }

    private func compactSummary(_ metrics: WorkOverviewMetrics) -> some View {
        HStack(spacing: 10) {
            compactSummaryItem(
                "\(metrics.totalRunCount) \(metrics.totalRunCount == 1 ? "turn" : "turns")",
                symbol: "terminal"
            )
            compactSummaryDivider
            compactSummaryItem(
                "\(metrics.workUnitCount) \(metrics.usesGenericWorkflow || metrics.usesLiveTeam ? "round" : "work unit")\(metrics.workUnitCount == 1 ? "" : "s")",
                symbol: "square.stack.3d.up"
            )
            compactSummaryDivider
            compactSummaryItem(
                "\(WorkOverviewFormatting.duration(milliseconds: metrics.totalRunMilliseconds)) active",
                symbol: "timer"
            )
            compactSummaryDivider
            compactSummaryItem(
                "\(WorkOverviewFormatting.duration(milliseconds: metrics.elapsedMilliseconds)) elapsed",
                symbol: "clock"
            )
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func compactSummaryItem(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
    }

    private var compactSummaryDivider: some View {
        Divider()
            .frame(height: 14)
    }

    private func phaseTimes(_ metrics: WorkOverviewMetrics) -> some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                ForEach(Array(metrics.phases.enumerated()), id: \.element.id) { index, phase in
                    GridRow {
                        Label(phase.name, systemImage: phaseSymbol(phase))
                            .frame(minWidth: 105, alignment: .leading)
                        ProgressView(
                            value: Double(phase.durationMilliseconds),
                            total: Double(max(metrics.totalRunMilliseconds, 1))
                        )
                        .tint(phaseColor(phase, index: index))
                        .frame(minWidth: 90, maxWidth: .infinity)
                        Text(
                            phase.runCount == 0
                                ? "—"
                                : WorkOverviewFormatting.duration(
                                    milliseconds: phase.durationMilliseconds
                                )
                        )
                        .monospacedDigit()
                        .frame(minWidth: 74, alignment: .trailing)
                        Text("\(phase.runCount)")
                            .monospacedDigit()
                            .frame(minWidth: 68, alignment: .trailing)
                    }
                }
            }
            .padding(8)
        } label: {
            HStack(spacing: 16) {
                Label("Time by Phase", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Spacer(minLength: 16)
                Text("Turns")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .trailing)
            }
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity)
        }
    }

    private func phaseTokens(_ metrics: WorkOverviewMetrics) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(Array(metrics.phases.enumerated()), id: \.element.id) { index, phase in
                        GridRow {
                            Label(phase.name, systemImage: phaseSymbol(phase))
                                .frame(minWidth: 90, alignment: .leading)
                            ProgressView(
                                value: Double(phase.tokenUsage?.totalTokens ?? 0),
                                total: Double(max(metrics.totalTokenUsage?.totalTokens ?? 0, 1))
                            )
                            .tint(phaseColor(phase, index: index))
                            .frame(minWidth: 70, maxWidth: .infinity)
                            tokenCell(
                                phase.tokenUsage.map { WorkOverviewFormatting.inputTokens($0) },
                                detail: phase.tokenUsage.map {
                                    "\(WorkOverviewFormatting.tokenDetail(WorkOverviewFormatting.inputTokens($0))) input tokens, including \(WorkOverviewFormatting.tokenDetail($0.cachedInputTokens)) cache reads and \(WorkOverviewFormatting.tokenDetail($0.cacheWriteInputTokens)) cache writes"
                                }
                            )
                            tokenCell(
                                phase.tokenUsage?.outputTokens,
                                detail: phase.tokenUsage.map {
                                    "\(WorkOverviewFormatting.tokenDetail($0.outputTokens)) output tokens, including \(WorkOverviewFormatting.tokenDetail($0.reasoningOutputTokens)) reasoning"
                                }
                            )
                            tokenCell(
                                phase.tokenUsage?.totalTokens,
                                detail: phase.tokenUsage.map {
                                    "\(WorkOverviewFormatting.tokenDetail($0.totalTokens)) total tokens"
                                }
                            )
                        }
                    }
                }

                if let usage = metrics.totalTokenUsage {
                    Text(
                        "Cached input: \(WorkOverviewFormatting.tokens(usage.cachedInputTokens))"
                            + "  ·  Recorded for \(metrics.recordedTokenRunCount) of \(metrics.totalRunCount) turns"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(
                        "\(WorkOverviewFormatting.tokenDetail(usage.cachedInputTokens)) cached input tokens"
                    )
                } else {
                    Text("Token usage has not been recorded for these turns.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } label: {
            HStack(spacing: 12) {
                Label("Tokens by Phase", systemImage: "number")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text("Input")
                    .frame(width: 62, alignment: .trailing)
                Text("Output")
                    .frame(width: 62, alignment: .trailing)
                Text("Total")
                    .frame(width: 62, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity)
        }
    }

    private func tokenCell(_ value: Int64?, detail: String?) -> some View {
        Text(value.map(WorkOverviewFormatting.tokens) ?? "—")
            .monospacedDigit()
            .frame(minWidth: 62, alignment: .trailing)
            .help(detail ?? "Token usage was not recorded")
    }

    private func detailsGrid(
        activity: ActivityRecord,
        metrics: WorkOverviewMetrics
    ) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)],
            alignment: .leading,
            spacing: 12
        ) {
            OverviewInfoCard(title: "Activity", symbol: "calendar") {
                if let workflow = activity.workflow {
                    OverviewInfoRow(title: "Earlier activity", value: workflow.name)
                }
                OverviewInfoRow(
                    title: "Started",
                    value: WorkOverviewFormatting.date(activity.createdAt)
                )
                OverviewInfoRow(
                    title: "Last saved",
                    value: WorkOverviewFormatting.date(metrics.repositoryUpdatedAt)
                )
                if let completedAt = activity.completedAt {
                    OverviewInfoRow(
                        title: "Finished",
                        value: WorkOverviewFormatting.date(completedAt)
                    )
                }
            }

            OverviewInfoCard(title: "Sessions", symbol: "person.2") {
                if let definition = activity.liveTeam?.currentDefinition {
                    ForEach(definition.members) { member in
                        let slotID = member.sessionPolicy.persistentSlotID(
                            memberID: member.id
                        )
                        OverviewInfoRow(
                            title: member.name,
                            value: slotID.map {
                                sessionDescription(activity.stepSessions[$0])
                            } ?? "Fresh each turn"
                        )
                    }
                } else if let workflow = activity.workflow {
                    ForEach(workflow.steps) { step in
                        let session = activity.stepSessions[step.id]
                        OverviewInfoRow(
                            title: step.name,
                            value: sessionDescription(session)
                        )
                    }
                } else {
                    OverviewInfoRow(
                        title: "Agent sessions",
                        value: "Created when work starts"
                    )
                }
                OverviewInfoRow(
                    title: "Repository added",
                    value: WorkOverviewFormatting.date(record.createdAt)
                )
            }

            OverviewInfoCard(title: "Agent targets", symbol: "cpu") {
                if let definition = activity.liveTeam?.currentDefinition {
                    ForEach(definition.members) { member in
                        OverviewInfoRow(
                            title: member.name,
                            value: targetDescription(member.target)
                        )
                    }
                    OverviewInfoRow(
                        title: "Work routing",
                        value: targetDescription(definition.coordinator.target)
                    )
                    if let overseer = activity.liveTeam?.overseer {
                        OverviewInfoRow(
                            title: "Strategy reviews",
                            value: targetDescription(overseer.target)
                        )
                    }
                } else if let workflow = activity.workflow {
                    ForEach(workflow.steps) { step in
                        OverviewInfoRow(
                            title: step.name,
                            value: targetDescription(step.target)
                        )
                    }
                    OverviewInfoRow(
                        title: "Work routing",
                        value: targetDescription(workflow.coordinator.target)
                    )
                } else {
                    OverviewInfoRow(
                        title: "Agents",
                        value: "Chosen from your goal"
                    )
                }
            }
        }
    }

    private func targetDescription(_ target: AgentTarget) -> String {
        var values = [application.targetDisplayName(target)]
        if let effort = target.options.effort, !effort.isEmpty {
            values.append(effort)
        }
        if target.options.mode != .standard {
            values.append(target.options.mode.displayName)
        }
        if target.options.speed == .fast {
            values.append("Fast")
        }
        return values.joined(separator: " ")
    }

    private func sessionDescription(_ session: WorkflowSessionState?) -> String {
        guard let session else { return "Not created" }
        let readiness = session.providerSessionID == nil ? "Pending" : "Ready"
        return session.lineage == 1 ? readiness : "\(readiness) · lineage \(session.lineage)"
    }

    private func phaseSymbol(_ phase: WorkOverviewMetrics.Phase) -> String {
        if let kind = phase.kind {
            return switch kind {
            case .implementation: "hammer"
            case .review: "checklist"
            case .fix: "wrench.and.screwdriver"
            }
        }
        return switch phase.section {
        case .some(.prefix): "arrow.right.to.line"
        case .some(.loop): "repeat"
        case .some(.postfix): "checkmark.seal"
        case nil: "terminal"
        }
    }

    private func phaseColor(_ phase: WorkOverviewMetrics.Phase, index: Int) -> Color {
        if let kind = phase.kind {
            return switch kind {
            case .implementation: .blue
            case .review: .purple
            case .fix: .orange
            }
        }
        let colors: [Color] = [.blue, .purple, .orange, .teal, .indigo, .pink]
        return colors[index % colors.count]
    }
}

struct WorkOverviewMetrics: Equatable {
    struct Phase: Equatable, Identifiable {
        let id: String
        let name: String
        let kind: RunKind?
        let section: WorkflowSection?
        let runCount: Int
        let completedRunCount: Int
        let durationMilliseconds: Int64
        let tokenRunCount: Int
        let tokenUsage: RunTokenUsage?
    }

    let phases: [Phase]
    let totalRunCount: Int
    let completedRunCount: Int
    let workUnitCount: Int
    let totalRunMilliseconds: Int64
    let elapsedMilliseconds: Int64
    let repositoryUpdatedAt: Date
    let isFinished: Bool
    let recordedTokenRunCount: Int
    let totalTokenUsage: RunTokenUsage?
    let usesGenericWorkflow: Bool
    let usesLiveTeam: Bool
    let productTokenUsage: RunTokenUsage?
    let controlTokenUsage: RunTokenUsage?
    let investmentDecisionCount: Int
    let tokensPerInvestmentDecision: Int64?

    init(
        activity: ActivityRecord,
        repositoryUpdatedAt: Date,
        now: Date
    ) {
        if let definition = activity.liveTeam?.currentDefinition {
            var phaseMembers = definition.members
            for run in activity.runs {
                guard let member = run.liveTeamMember?.member,
                      !phaseMembers.contains(where: { $0.id == member.id }) else {
                    continue
                }
                phaseMembers.append(member)
            }
            phases = phaseMembers.map { member in
                Self.phase(
                    id: member.id,
                    name: member.name,
                    kind: nil,
                    section: nil,
                    runs: activity.runs.filter {
                        $0.liveTeamMember?.member.id == member.id
                    },
                    now: now
                )
            }
            usesGenericWorkflow = false
            usesLiveTeam = true
        } else if let workflow = activity.workflow {
            phases = workflow.steps.map { step in
                Self.phase(
                    id: step.id,
                    name: step.name,
                    kind: nil,
                    section: step.section,
                    runs: activity.runs.filter { $0.workflowStep?.id == step.id },
                    now: now
                )
            }
            usesGenericWorkflow = true
            usesLiveTeam = false
        } else {
            phases = [
                RunKind.implementation,
                RunKind.review,
                RunKind.fix
            ].map { kind in
                Self.phase(
                    id: kind.rawValue,
                    name: kind.displayName,
                    kind: kind,
                    section: nil,
                    runs: activity.runs.filter { $0.kind == kind },
                    now: now
                )
            }
            usesGenericWorkflow = false
            usesLiveTeam = false
        }
        totalRunCount = activity.runs.count
        completedRunCount = activity.runs.count(where: { $0.status == .completed })
        if usesLiveTeam {
            workUnitCount = activity.runs.compactMap(\.liveTeamMember?.cycle).max() ?? 0
        } else {
            workUnitCount = RunGroupingPolicy.loopIterationCount(for: activity.runs)
        }
        totalRunMilliseconds = phases.reduce(0) { $0 + $1.durationMilliseconds }
        let endDate = activity.completedAt ?? now
        elapsedMilliseconds = Self.milliseconds(from: activity.createdAt, to: endDate)
        self.repositoryUpdatedAt = repositoryUpdatedAt
        isFinished = activity.completedAt != nil
        let productUsageValues = activity.runs.compactMap(\.tokenUsage)
        productTokenUsage = productUsageValues.isEmpty
            ? nil
            : productUsageValues.reduce(RunTokenUsage.zero) { $0.adding($1) }

        let definitions = Self.companyDefinitions(activity)
        var peopleByID: [UUID: CompanyPerson] = [:]
        for definition in definitions {
            if let person = definition.overseerPerson {
                peopleByID[person.id] = person
            }
            for person in definition.members.compactMap(\.person) {
                peopleByID[person.id] = person
            }
            for person in definition.formerPeople {
                peopleByID[person.id] = person
            }
        }
        var controlValues = definitions.filter { $0.revision == 1 }
            .compactMap(\.setupTokenUsage)
        controlValues += peopleByID.values.compactMap(\.generationTokenUsage)
        controlValues += activity.runs.compactMap(\.coordinatorDecision?.tokenUsage)
        controlValues += (activity.liveTeam?.reviews ?? []).compactMap(\.controlTokenUsage)
        controlValues += (activity.liveTeam?.reviews ?? []).flatMap(\.consultations)
            .compactMap(\.tokenUsage)
        controlTokenUsage = controlValues.isEmpty
            ? nil
            : controlValues.reduce(RunTokenUsage.zero) { $0.adding($1) }

        investmentDecisionCount = (activity.liveTeam?.reviews ?? []).count {
            $0.status == .completed
        }
        let allUsage = [productTokenUsage, controlTokenUsage].compactMap { $0 }
        totalTokenUsage = allUsage.isEmpty
            ? nil
            : allUsage.reduce(RunTokenUsage.zero) { $0.adding($1) }
        recordedTokenRunCount = productUsageValues.count
        tokensPerInvestmentDecision = investmentDecisionCount > 0
            ? (totalTokenUsage?.totalTokens ?? 0) / Int64(investmentDecisionCount)
            : nil
    }

    private static func companyDefinitions(_ activity: ActivityRecord) -> [LiveTeamDefinition] {
        var byRevision: [Int: LiveTeamDefinition] = [:]
        for definition in activity.liveTeam?.definitionHistory ?? [] {
            byRevision[definition.revision] = definition
        }
        for definition in (activity.liveTeam?.reviews ?? []).compactMap(\.resultingDefinition) {
            byRevision[definition.revision] = definition
        }
        if let current = activity.liveTeam?.currentDefinition {
            byRevision[current.revision] = current
        }
        return byRevision.values.sorted { $0.revision < $1.revision }
    }

    private static func phase(
        id: String,
        name: String,
        kind: RunKind?,
        section: WorkflowSection?,
        runs: [RunRecord],
        now: Date
    ) -> Phase {
        let recordedUsage = runs.compactMap(\.tokenUsage)
        return Phase(
            id: id,
            name: name,
            kind: kind,
            section: section,
            runCount: runs.count,
            completedRunCount: runs.count(where: { $0.status == .completed }),
            durationMilliseconds: runs.reduce(0) {
                $0 + measuredDuration(for: $1, now: now)
            },
            tokenRunCount: recordedUsage.count,
            tokenUsage: recordedUsage.isEmpty
                ? nil
                : recordedUsage.reduce(.zero) { $0.adding($1) }
        )
    }

    private static func measuredDuration(for run: RunRecord, now: Date) -> Int64 {
        if let durationMilliseconds = run.durationMilliseconds {
            return max(durationMilliseconds, 0)
        }
        if let completedAt = run.completedAt {
            return milliseconds(from: run.startedAt, to: completedAt)
        }
        switch run.status {
        case .queued, .running, .routing, .awaitingApproval:
            return milliseconds(from: run.startedAt, to: now)
        case .paused, .completed, .interrupted, .failed:
            return 0
        }
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int64 {
        max(Int64((end.timeIntervalSince(start) * 1_000).rounded()), 0)
    }
}

private struct WorkSummaryMarkdownView: View {
    let blocks: [WorkSummaryMarkdownBlock]

    init(markdown: String) {
        blocks = WorkOverviewFormatting.summaryBlocks(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let text):
                    Text(WorkOverviewFormatting.inlineMarkdown(text))
                        .font(.headline)
                        .padding(.top, index == 0 ? 0 : 4)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(WorkOverviewFormatting.inlineMarkdown(text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                case .paragraph(let text):
                    Text(WorkOverviewFormatting.inlineMarkdown(text))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

enum WorkSummaryMarkdownBlock: Equatable {
    case heading(String)
    case bullet(String)
    case paragraph(String)
}

enum WorkOverviewFormatting {
    static func inputTokens(_ usage: RunTokenUsage) -> Int64 {
        max(usage.inputTokens, usage.totalTokens - usage.outputTokens)
    }

    static func duration(milliseconds: Int64) -> String {
        let totalSeconds = max(Int((Double(milliseconds) / 1_000).rounded()), 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        }
        return "\(seconds)s"
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func tokens(_ value: Int64) -> String {
        let clamped = max(value, 0)
        switch clamped {
        case 0..<1_000:
            return "\(clamped)"
        case 1_000..<1_000_000:
            return abbreviated(Double(clamped) / 1_000, suffix: "K")
        default:
            return abbreviated(Double(clamped) / 1_000_000, suffix: "M")
        }
    }

    static func tokenDetail(_ value: Int64) -> String {
        max(value, 0).formatted(
            .number
                .locale(Locale(identifier: "en_US"))
                .grouping(.automatic)
        )
    }

    private static func abbreviated(_ value: Double, suffix: String) -> String {
        let digits = value >= 100 ? 0 : 1
        return value.formatted(
            .number
                .locale(Locale(identifier: "en_US"))
                .precision(.fractionLength(digits))
        ) + suffix
    }

    static func summaryBlocks(_ text: String) -> [WorkSummaryMarkdownBlock] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { lineValue in
                let line = String(lineValue).trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return nil }

                let headingPrefix = line.prefix(while: { $0 == "#" })
                if !headingPrefix.isEmpty,
                   headingPrefix.count <= 6,
                   line.dropFirst(headingPrefix.count).first == " " {
                    return .heading(
                        String(line.dropFirst(headingPrefix.count + 1))
                    )
                }

                if line.count >= 2 {
                    let prefix = line.prefix(2)
                    if prefix == "- " || prefix == "* " || prefix == "+ " {
                        return .bullet(String(line.dropFirst(2)))
                    }
                }

                return .paragraph(line)
            }
    }

    static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }
}

private struct OverviewInfoCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(spacing: 10) {
                content
            }
            .padding(8)
        } label: {
            Label(title, systemImage: symbol)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct OverviewInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .layoutPriority(1)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}
