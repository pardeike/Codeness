import CodenessCore
import Foundation
import SwiftUI

struct OverseerReviewDetailView: View {
    let review: LiveTeamReviewRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                reviewReason
                consultation
                overseerDecision
                if let definition = review.resultingDefinition {
                    resultingSetup(definition)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(review.mode.displayName)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "eye.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 46, height: 46)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 4) {
                Text(review.mode.displayName)
                    .font(.title2.weight(.semibold))
                Text("Started \(review.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Label(statusText, systemImage: statusSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
    }

    private var reviewReason: some View {
        reviewSection("Why This Review Happened", symbol: "questionmark.circle") {
            Text(review.trigger)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var consultation: some View {
        reviewSection("Staff Consultation", symbol: "person.3.sequence.fill") {
            if review.consultations.isEmpty {
                HStack(spacing: 10) {
                    if review.status == .selectingManagers {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(
                        review.status == .failed
                            ? "No manager list was available."
                            : "The Overseer is selecting the relevant manager perspectives."
                    )
                    .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(review.consultations) { manager in
                        ManagerConsultationView(manager: manager)
                    }
                }
            }
        }
    }

    private var overseerDecision: some View {
        reviewSection("Overseer Judgment", symbol: "eye.fill") {
            if let decision = review.decision {
                VStack(alignment: .leading, spacing: 12) {
                    Label(decision.outcome.displayName, systemImage: decisionSymbol(decision))
                        .font(.headline)
                    if !decision.summary.isEmpty {
                        Text(decision.summary)
                            .font(.subheadline.weight(.medium))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    detail("Judgment", text: decision.reason)
                    if !decision.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        detail("Evidence", text: decision.evidence)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    if review.status != .failed {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(decisionPendingText)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func resultingSetup(_ definition: LiveTeamDefinition) -> some View {
        reviewSection("Resulting Agent Setup", symbol: "person.3.fill") {
            VStack(alignment: .leading, spacing: 14) {
                detail("Working goal", text: definition.workingGoal)
                detail("Strategic reason", text: definition.strategicReason)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Agents")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(definition.members) { member in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(member.name)
                                    .fontWeight(.medium)
                                Text(member.runPolicy.displayName)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                                Text(member.sessionPolicy.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            Text(member.instructions)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(
                                "\(member.target.providerID.rawValue) · \(member.target.model)"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(
                            .quaternary.opacity(0.45),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                }

                detail(
                    "Work routing",
                    text: definition.coordinator.instructions
                        + "\n\n"
                        + "Target: \(definition.coordinator.target.providerID.rawValue) · "
                        + definition.coordinator.target.model
                )
                detail(
                    "Strategy reviews",
                    text: "Target: \(definition.overseerTarget.providerID.rawValue) · "
                        + definition.overseerTarget.model
                )
            }
        }
    }

    private func reviewSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        } label: {
            Label(title, systemImage: symbol)
                .font(.headline)
        }
    }

    private func detail(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        switch review.status {
        case .selectingManagers: "Selecting managers"
        case .consultingManagers:
            "Consulting \(review.completedConsultationCount) of \(review.consultations.count)"
        case .overseerDeciding: "Overseer deciding"
        case .completed: review.decision?.outcome.displayName ?? "Completed"
        case .failed: "Interrupted"
        }
    }

    private var statusSymbol: String {
        switch review.status {
        case .selectingManagers, .consultingManagers: "person.3.sequence.fill"
        case .overseerDeciding: "eye.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch review.status {
        case .selectingManagers, .consultingManagers, .overseerDeciding: .orange
        case .completed: .blue
        case .failed: .red
        }
    }

    private var decisionPendingText: String {
        switch review.status {
        case .selectingManagers, .consultingManagers:
            "The Overseer will decide after the consultation."
        case .overseerDeciding:
            "The Overseer is weighing the reports against the fixed user goal and durable evidence."
        case .completed, .failed:
            "No decision was recorded."
        }
    }

    private func decisionSymbol(_ decision: LiveTeamReviewDecision) -> String {
        switch decision.outcome {
        case .kept: "arrow.forward.circle.fill"
        case .revised: "arrow.triangle.2.circlepath.circle.fill"
        case .completed: "checkmark.seal.fill"
        case .continueWork: "hammer.circle.fill"
        case .rejectedPause: "arrow.uturn.forward.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

private struct ManagerConsultationView: View {
    let manager: LiveTeamManagerConsultation

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(manager.name)
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(manager.mandate)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if manager.status == .waiting || manager.status == .reporting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Preparing a short independent report…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                reportField("Involvement", manager.involvement)
                reportField("Progress", manager.progress)
                reportField("Evidence", manager.evidence)
                reportField("Concern", manager.concern)
                reportField("Recommended next move", manager.nextMove)
                if let failure = manager.failure {
                    reportField("Availability", failure, color: .orange)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private func reportField(
        _ title: String,
        _ text: String?,
        color: Color = .primary
    ) -> some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusText: String {
        switch manager.status {
        case .waiting: "Waiting"
        case .reporting: "Reporting"
        case .completed: "Reported"
        case .unavailable: "Unavailable"
        }
    }

    private var symbol: String {
        switch manager.status {
        case .waiting: "clock"
        case .reporting: "ellipsis.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch manager.status {
        case .waiting: .secondary
        case .reporting: .orange
        case .completed: .blue
        case .unavailable: .orange
        }
    }
}
