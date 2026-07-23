import AppKit
import CodenessCore
import SwiftUI

struct WorkOverviewView: View {
    @Bindable var coordinator: RepositoryCoordinator

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
                overviewHeader(activity: activity)
                goal(activity.goal)
                workSummary
                summaryGrid(metrics)
                phaseTimes(metrics)
                phaseTokens(metrics)
                detailsGrid(activity: activity, metrics: metrics)
                Label(
                    "Select a run in the sidebar to inspect its transcript and final result.",
                    systemImage: "sidebar.left"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
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
                    .help("Ask the configured handoff model to generate the work overview again")
                } else {
                    Label(
                        "A narrative summary will appear after the first completed handoff.",
                        systemImage: "text.badge.plus"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } label: {
            HStack {
                Label("Work so far", systemImage: "text.document")
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
        let count = record.activity?.runs.count(where: { $0.handoff != nil }) ?? 0
        return count == 1 ? "handoff" : "\(count) handoffs"
    }

    private func overviewHeader(activity: ActivityRecord) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "folder.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 46, height: 46)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 4) {
                Text(URL(fileURLWithPath: record.canonicalPath).lastPathComponent)
                    .font(.title2.weight(.semibold))
                Text(record.canonicalPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 16)

            Label(
                activity.status.rawValue.capitalized,
                systemImage: statusSymbol(activity.status)
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor(activity.status))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(statusColor(activity.status).opacity(0.12), in: Capsule())
        }
    }

    private func goal(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GOAL")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.title3)
                .textSelection(.enabled)
        }
    }

    private func summaryGrid(_ metrics: WorkOverviewMetrics) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190, maximum: 300), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            OverviewMetricCard(
                title: "Runs",
                value: "\(metrics.totalRunCount)",
                detail: "\(metrics.completedRunCount) completed",
                symbol: "terminal"
            )
            OverviewMetricCard(
                title: "Work units",
                value: "\(metrics.workUnitCount)",
                detail: metrics.workUnitCount == 1 ? "review cycle" : "review cycles",
                symbol: "square.stack.3d.up"
            )
            OverviewMetricCard(
                title: "Run time",
                value: WorkOverviewFormatting.duration(
                    milliseconds: metrics.totalRunMilliseconds
                ),
                detail: "across all phases",
                symbol: "timer"
            )
            OverviewMetricCard(
                title: "Elapsed",
                value: WorkOverviewFormatting.duration(
                    milliseconds: metrics.elapsedMilliseconds
                ),
                detail: metrics.isFinished ? "start to finish" : "since activity start",
                symbol: "clock"
            )
        }
    }

    private func phaseTimes(_ metrics: WorkOverviewMetrics) -> some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Phase")
                    Text("Share")
                    Text("Time")
                        .frame(minWidth: 74, alignment: .trailing)
                    Text("Runs")
                        .frame(minWidth: 54, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()
                    .gridCellColumns(4)

                ForEach(metrics.phases) { phase in
                    GridRow {
                        Label(phase.kind.displayName, systemImage: phaseSymbol(phase.kind))
                            .frame(minWidth: 105, alignment: .leading)
                        ProgressView(
                            value: Double(phase.durationMilliseconds),
                            total: Double(max(metrics.totalRunMilliseconds, 1))
                        )
                        .tint(phaseColor(phase.kind))
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
                            .frame(minWidth: 54, alignment: .trailing)
                    }
                }
            }
            .padding(8)
        } label: {
            Label("Time by Phase", systemImage: "chart.bar.xaxis")
                .font(.headline)
        }
    }

    private func phaseTokens(_ metrics: WorkOverviewMetrics) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Text("Phase")
                        Text("Share")
                        Text("Input")
                            .frame(minWidth: 62, alignment: .trailing)
                        Text("Output")
                            .frame(minWidth: 62, alignment: .trailing)
                        Text("Total")
                            .frame(minWidth: 62, alignment: .trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Divider()
                        .gridCellColumns(5)

                    ForEach(metrics.phases) { phase in
                        GridRow {
                            Label(phase.kind.displayName, systemImage: phaseSymbol(phase.kind))
                                .frame(minWidth: 90, alignment: .leading)
                            ProgressView(
                                value: Double(phase.tokenUsage?.totalTokens ?? 0),
                                total: Double(max(metrics.totalTokenUsage?.totalTokens ?? 0, 1))
                            )
                            .tint(phaseColor(phase.kind))
                            .frame(minWidth: 70, maxWidth: .infinity)
                            tokenCell(
                                phase.tokenUsage?.inputTokens,
                                detail: phase.tokenUsage.map {
                                    "\(WorkOverviewFormatting.tokenDetail($0.inputTokens)) input tokens, including \(WorkOverviewFormatting.tokenDetail($0.cachedInputTokens)) cached"
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
                            + "  ·  Recorded for \(metrics.recordedTokenRunCount) of \(metrics.totalRunCount) runs"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(
                        "\(WorkOverviewFormatting.tokenDetail(usage.cachedInputTokens)) cached input tokens"
                    )
                } else {
                    Text("Token usage has not been recorded for these runs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } label: {
            Label("Tokens by Phase", systemImage: "number")
                .font(.headline)
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
            columns: [GridItem(.adaptive(minimum: 280), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            OverviewInfoCard(title: "Activity", symbol: "calendar") {
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
                OverviewInfoRow(
                    title: "Goal revisions",
                    value: "\(activity.goalAmendments.count)"
                )
            }

            OverviewInfoCard(title: "Sessions", symbol: "person.2") {
                OverviewInfoRow(
                    title: "Implementer",
                    value: record.implementerThreadID == nil ? "Not created" : "Ready"
                )
                OverviewInfoRow(
                    title: "Reviewer",
                    value: record.reviewerThreadID == nil ? "Not created" : "Ready"
                )
                OverviewInfoRow(
                    title: "Repository added",
                    value: WorkOverviewFormatting.date(record.createdAt)
                )
            }

            OverviewInfoCard(title: "Models", symbol: "cpu") {
                OverviewInfoRow(
                    title: "Implement",
                    value: modelDescription(record.settings.implementer)
                )
                OverviewInfoRow(
                    title: "Review",
                    value: modelDescription(record.settings.reviewer)
                )
                OverviewInfoRow(
                    title: "Fix",
                    value: modelDescription(record.settings.fixer)
                )
                OverviewInfoRow(
                    title: "Handoff",
                    value: modelDescription(record.settings.relay.selection)
                )
            }
        }
    }

    private func modelDescription(_ selection: ModelSelection) -> String {
        "\(selection.model) · \(selection.effort)"
    }

    private func statusSymbol(_ status: ActivityStatus) -> String {
        switch status {
        case .running: "play.circle.fill"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ status: ActivityStatus) -> Color {
        switch status {
        case .running: .green
        case .paused: .orange
        case .completed: .blue
        case .cancelled: .secondary
        case .failed: .red
        }
    }

    private func phaseSymbol(_ kind: RunKind) -> String {
        switch kind {
        case .implementation: "hammer"
        case .review: "checklist"
        case .fix: "wrench.and.screwdriver"
        }
    }

    private func phaseColor(_ kind: RunKind) -> Color {
        switch kind {
        case .implementation: .blue
        case .review: .purple
        case .fix: .orange
        }
    }
}

struct WorkOverviewMetrics: Equatable {
    struct Phase: Equatable, Identifiable {
        let kind: RunKind
        let runCount: Int
        let completedRunCount: Int
        let durationMilliseconds: Int64
        let tokenRunCount: Int
        let tokenUsage: RunTokenUsage?

        var id: RunKind { kind }
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

    init(
        activity: ActivityRecord,
        repositoryUpdatedAt: Date,
        now: Date
    ) {
        phases = [
            RunKind.implementation,
            RunKind.review,
            RunKind.fix
        ].map { kind in
            let runs = activity.runs.filter { $0.kind == kind }
            let recordedUsage = runs.compactMap(\.tokenUsage)
            return Phase(
                kind: kind,
                runCount: runs.count,
                completedRunCount: runs.count(where: { $0.status == .completed }),
                durationMilliseconds: runs.reduce(0) {
                    $0 + Self.measuredDuration(for: $1, now: now)
                },
                tokenRunCount: recordedUsage.count,
                tokenUsage: recordedUsage.isEmpty
                    ? nil
                    : recordedUsage.reduce(.zero) { $0.adding($1) }
            )
        }
        totalRunCount = activity.runs.count
        completedRunCount = activity.runs.count(where: { $0.status == .completed })
        workUnitCount = RunGroupingPolicy.workUnits(for: activity.runs).count
        totalRunMilliseconds = phases.reduce(0) { $0 + $1.durationMilliseconds }
        let endDate = activity.completedAt ?? now
        elapsedMilliseconds = Self.milliseconds(from: activity.createdAt, to: endDate)
        self.repositoryUpdatedAt = repositoryUpdatedAt
        isFinished = activity.completedAt != nil
        recordedTokenRunCount = phases.reduce(0) { $0 + $1.tokenRunCount }
        let recordedUsage = phases.compactMap(\.tokenUsage)
        totalTokenUsage = recordedUsage.isEmpty
            ? nil
            : recordedUsage.reduce(.zero) { $0.adding($1) }
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

private struct OverviewMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5))
        }
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
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}
