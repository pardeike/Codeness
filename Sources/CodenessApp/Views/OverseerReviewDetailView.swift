import CodenessCore
import Foundation
import SwiftUI

struct OverseerReviewDetailView: View {
    let review: LiveTeamReviewRecord
    let personRoles: [UUID: String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                reviewReason
                focusGroup
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
        ReviewDisclosureSection("Why This Decision Happened", symbol: "questionmark.circle") {
            Text(review.trigger)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var consultation: some View {
        ReviewDisclosureSection("Company Check-in", symbol: "person.3.sequence.fill") {
            if review.consultations.isEmpty {
                HStack(spacing: 10) {
                    if review.status == .selectingManagers
                        || review.status == .researchingFocusGroup {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(
                        review.status == .failed
                            ? "No company check-in was available."
                            : review.status == .researchingFocusGroup
                                ? "The company check-in starts after the focus group reports."
                                : "The CEO is gathering short reports from the current company."
                    )
                    .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(review.consultations) { manager in
                        ManagerConsultationView(
                            manager: manager,
                            role: personRoles[manager.id]
                        )
                    }
                }
            }
        }
    }

    private var focusGroup: some View {
        ReviewDisclosureSection("Focus Group", symbol: "person.2.wave.2.fill") {
            if let report = review.focusGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Simulated directional feedback, not real customer validation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    detail("Audience", text: report.audience)
                    detail("Question", text: report.question)
                    detail(
                        "A/B comparison",
                        text: "Current product vs \(report.comparison). \(report.comparisonReason)"
                    )

                    if let failure = report.failure {
                        detail("Availability", text: failure)
                    } else {
                        ForEach(report.participants.indices, id: \.self) { index in
                            let participant = report.participants[index]
                            detail(
                                "\(participant.archetype) · \(participant.choice.displayName)",
                                text: participant.reaction
                            )
                        }
                        detail("Verdict", text: report.verdict)
                        detail("Next product experiment", text: report.nextExperiment)
                    }

                    if let path = report.documentPath {
                        Label(path, systemImage: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    if review.status != .failed {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(
                        review.status == .failed
                            ? "No focus-group report was available."
                            : "Comparing the product with one relevant alternative."
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var overseerDecision: some View {
        ReviewDisclosureSection("CEO Investment Decision", symbol: "crown.fill") {
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
        ReviewDisclosureSection("Funded Company", symbol: "person.3.fill") {
            VStack(alignment: .leading, spacing: 14) {
                detail("Working goal", text: definition.workingGoal)
                detail("Strategic reason", text: definition.strategicReason)
                if let bet = definition.productBet {
                    detail("Product bet", text: """
                    \(bet.headline)

                    Value: \(bet.valuePromise)
                    Showcase: \(bet.showcase)
                    Integration target: \(bet.integrationTarget)
                    Stop condition: \(bet.killCondition)
                    Funding: \(bet.fundedTokenLimit.formatted()) tokens or \(bet.maximumTurns) turns
                    """)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("People")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(definition.members) { member in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(member.person?.profile.fullName ?? member.name)
                                    .fontWeight(.medium)
                                if let person = member.person {
                                    Text(person.position.title)
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.tint.opacity(0.12), in: Capsule())
                                }
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
                    "CEO investment decisions",
                    text: "Target: \(definition.overseerTarget.providerID.rawValue) · "
                        + definition.overseerTarget.model
                )
            }
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
        case .researchingFocusGroup: "Running focus group"
        case .selectingManagers: "Gathering company"
        case .consultingManagers:
            "Hearing \(review.completedConsultationCount) of \(review.consultations.count)"
        case .overseerDeciding: "CEO deciding"
        case .completed: review.decision?.outcome.displayName ?? "Completed"
        case .failed: "Interrupted"
        }
    }

    private var statusSymbol: String {
        switch review.status {
        case .researchingFocusGroup: "person.2.wave.2.fill"
        case .selectingManagers, .consultingManagers: "person.3.sequence.fill"
        case .overseerDeciding: "eye.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch review.status {
        case .researchingFocusGroup, .selectingManagers, .consultingManagers,
                .overseerDeciding: .orange
        case .completed: .blue
        case .failed: .red
        }
    }

    private var decisionPendingText: String {
        switch review.status {
        case .researchingFocusGroup:
            "The company check-in starts after the focus group reports."
        case .selectingManagers, .consultingManagers:
            "The CEO will decide after the company check-in."
        case .overseerDeciding:
            "The CEO is weighing product evidence, token return, and the fixed user goal."
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

private struct ReviewDisclosureSection<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content
    @State private var isExpanded = false

    init(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            } label: {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { isExpanded.toggle() }
            }
            .padding(8)
        }
    }
}

private struct ManagerConsultationView: View {
    let manager: LiveTeamManagerConsultation
    let role: String?
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 9) {
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
            .padding(.top, 8)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(manager.name)
                    .font(.headline)
                    .lineLimit(1)
                if let role {
                    Text(role)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
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
