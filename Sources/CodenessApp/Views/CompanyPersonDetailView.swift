import CodenessCore
import SwiftUI

struct CompanyPersonDetailView: View {
    @Bindable var coordinator: RepositoryCoordinator
    let person: CompanyPerson
    @State private var showsBackground = false
    @State private var showsConvictions = false
    @State private var showsWorkingStyle = false
    @State private var showsExperience = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if person.positionID == .chiefExecutive {
                    chiefExecutiveControl
                }
                assignment
                DisclosureGroup("Story", isExpanded: $showsBackground) {
                    detail("Background", person.profile.background)
                    detail("Formative success", person.profile.formativeSuccess)
                    detail("Formative scar", person.profile.formativeScar)
                }
                DisclosureGroup("Convictions and stake", isExpanded: $showsConvictions) {
                    detail("Personal stake", person.profile.personalStake)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Convictions")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(person.profile.convictions, id: \.self) { conviction in
                            Label(conviction, systemImage: "flame.fill")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 8)
                }
                DisclosureGroup("Personality at work", isExpanded: $showsWorkingStyle) {
                    detail("Working style", person.profile.workingStyle)
                    detail("Conflict style", person.profile.conflictStyle)
                    detail("Blind spot", person.profile.blindSpot)
                    detail(
                        "Evidence that changes their mind",
                        person.profile.evidenceThatChangesTheirMind
                    )
                }
                DisclosureGroup("Lived record", isExpanded: $showsExperience) {
                    if person.experience.isEmpty {
                        Text("Their product track record in this company will grow here.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(person.experience) { experience in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(experience.headline)
                                    .fontWeight(.medium)
                                Text(experience.detail)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(experience.createdAt.formatted())
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                cost
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .modifier(RepositoryDetailTopEdgeSuppression())
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: person.positionID == .chiefExecutive
                ? "crown.fill"
                : "person.crop.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(
                    person.positionID == .chiefExecutive ? Color.orange : Color.accentColor
                )
                .frame(width: 52, height: 52)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(person.profile.fullName)
                    .font(.title2.weight(.semibold))
                Text(person.position.title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(person.position.sector.displayName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var assignment: some View {
        GroupBox("Current assignment") {
            Text(person.assignment)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(8)
        }
    }

    private var chiefExecutiveControl: some View {
        HStack(spacing: 10) {
            if coordinator.isReplacingChiefExecutive {
                ProgressView()
                    .controlSize(.small)
                Text("Recruiting a new CEO…")
                    .foregroundStyle(.secondary)
            } else {
                Button("Replace CEO") {
                    Task { await coordinator.replaceChiefExecutive() }
                }
                .help("Generate and appoint a different persistent CEO for future investment decisions")
                Text("The replacement takes over future investment decisions without interrupting current product work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cost: some View {
        GroupBox("Hiring investment") {
            VStack(alignment: .leading, spacing: 5) {
                if let usage = person.generationTokenUsage {
                    Text("Actual generation cost: \(usage.totalTokens.formatted()) tokens")
                } else {
                    Text("Actual generation cost was not reported by the provider.")
                }
                if person.opportunityChargeTokens > 0 {
                    Text("Company opportunity charge: \(person.opportunityChargeTokens.formatted()) tokens")
                }
                Text("Hired \(person.hiredAt.formatted())")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.top, 8)
    }
}
