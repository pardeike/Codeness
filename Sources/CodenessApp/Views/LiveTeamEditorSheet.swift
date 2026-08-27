import CodenessCore
import SwiftUI

struct LiveTeamEditorSheet: View {
    let coordinator: RepositoryCoordinator

    @Environment(CodenessApplicationModel.self) private var application
    @Environment(\.dismiss) private var dismiss
    @State private var definition: LiveTeamDefinition
    @State private var reason: String
    @State private var preferredNextMemberID: String?
    @State private var isSaving = false

    init(coordinator: RepositoryCoordinator, definition: LiveTeamDefinition) {
        self.coordinator = coordinator
        let initial = coordinator.pendingLiveTeamRevision?.actor == .board
            ? coordinator.pendingLiveTeamRevision?.definition ?? definition
            : definition
        _definition = State(initialValue: initial)
        _reason = State(initialValue: "You adjusted the agents.")
        _preferredNextMemberID = State(
            initialValue: coordinator.pendingLiveTeamRevision?.preferredNextMemberID
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit Agents")
                        .font(.title2.weight(.semibold))
                    Text("Changes take effect between agent turns.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if coordinator.pendingLiveTeamRevision?.actor == .overseer {
                        Label(
                            "Codeness has proposed agent changes. Saving your changes will replace them.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }

                    GroupBox("Working Goal") {
                        ActivityTextEditor(
                            text: $definition.workingGoal,
                            minHeight: 145,
                            accessibilityLabel: "Working goal",
                            helpText: "Edit the stable brief used by the agents."
                        )
                        .padding(.vertical, 5)
                    }

                    teamSection

                    GroupBox("Strategy Reviews") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Codeness uses this agent for strategy and completion reviews. Constraints in your goal still apply.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            AgentTargetFields(
                                title: "Strategy reviews",
                                target: $definition.overseerTarget
                            )
                        }
                        .padding(.vertical, 5)
                    }

                    GroupBox("Work Routing") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Codeness uses this agent for handoffs, retries, pauses, and review requests. It cannot change the working goal, agents, or memory policy.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            AgentTargetFields(
                                title: "Work routing",
                                target: $definition.coordinator.target
                            )
                            ActivityTextEditor(
                                text: $definition.coordinator.instructions,
                                minHeight: 95,
                                accessibilityLabel: "Work routing policy",
                                helpText: "Define local routing, retry, pause, and escalation policy without strategic authority."
                            )
                        }
                        .padding(.vertical, 5)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Reason") {
                            TextField(
                                "Why this change should improve progress",
                                text: $reason,
                                axis: .vertical
                            )
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                        }
                        LabeledContent("Continue with") {
                            Picker("Continue with", selection: $preferredNextMemberID) {
                                Text("Automatic").tag(String?.none)
                                ForEach(definition.members) { member in
                                    Text(member.name).tag(String?.some(member.id))
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Save Changes") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil || isSaving)
                .help("Apply these changes between agent turns")
            }
            .padding(14)
        }
        .frame(minWidth: 760, idealWidth: 880, minHeight: 620, idealHeight: 760)
    }

    private var teamSection: some View {
        GroupBox("Agents") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Order determines who works next. Once agents stop after their first turn; every-round agents remain in rotation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(definition.members.indices, id: \.self) { index in
                    memberEditor(index: index)
                    if index != definition.members.indices.last {
                        Divider()
                    }
                }

                Button {
                    addMember()
                } label: {
                    Label("Add Agent", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add another bounded agent responsibility")
            }
            .padding(.vertical, 5)
        }
    }

    private func memberEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                TextField("Agent name", text: memberBinding(index).name)
                    .font(.headline)
                    .textFieldStyle(.roundedBorder)
                Text(definition.members[index].id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                memberOrderButton(index: index, offset: -1)
                memberOrderButton(index: index, offset: 1)
                Button(role: .destructive) {
                    removeMember(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(definition.members.count == 1)
                .accessibilityLabel("Remove \(definition.members[index].name)")
                .help("Remove this agent")
            }

            ActivityTextEditor(
                text: memberBinding(index).instructions,
                minHeight: 105,
                accessibilityLabel: "\(definition.members[index].name) responsibility",
                helpText: "Define one bounded responsibility and an explicit stopping condition."
            )

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Schedule")
                    Picker("Schedule", selection: memberBinding(index).runPolicy) {
                        ForEach(LiveTeamRunPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Memory")
                    Picker("Memory", selection: sessionKindBinding(index)) {
                        ForEach(LiveTeamSessionKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                }
                if case .sharedMemory(let groupID) = definition.members[index].sessionPolicy {
                    GridRow {
                        Text("Memory group")
                        TextField(
                            "Shared group identifier",
                            text: Binding(
                                get: { groupID },
                                set: {
                                    definition.members[index].sessionPolicy = .sharedMemory(
                                        groupID: $0
                                    )
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .font(.caption)

            AgentTargetFields(
                title: definition.members[index].name,
                target: memberBinding(index).target
            )

            if coordinator.activity?.status == .paused,
               definition.members[index].sessionPolicy.persistentSlotID(
                   memberID: definition.members[index].id
               ) != nil {
                Button(resetMemoryLabel(for: definition.members[index])) {
                    let memberID = definition.members[index].id
                    Task { _ = await coordinator.resetLiveTeamSession(memberID: memberID) }
                }
                .help(resetMemoryHelp(for: definition.members[index]))
            }
        }
    }

    private func resetMemoryLabel(for member: LiveTeamMember) -> String {
        if case .sharedMemory = member.sessionPolicy {
            return "Reset Shared Memory"
        }
        return "Reset Memory"
    }

    private func resetMemoryHelp(for member: LiveTeamMember) -> String {
        if case .sharedMemory(let groupID) = member.sessionPolicy {
            return "Start a fresh provider conversation for every agent in shared group \(groupID)"
        }
        return "Start a fresh provider conversation for this agent without changing the setup"
    }

    private func memberBinding(_ index: Int) -> Binding<LiveTeamMember> {
        Binding(
            get: { definition.members[index] },
            set: { definition.members[index] = $0 }
        )
    }

    private func memberOrderButton(index: Int, offset: Int) -> some View {
        Button {
            definition.members.swapAt(index, index + offset)
        } label: {
            Image(systemName: offset < 0 ? "arrow.up" : "arrow.down")
        }
        .buttonStyle(.borderless)
        .disabled(!definition.members.indices.contains(index + offset))
        .accessibilityLabel(offset < 0 ? "Move agent earlier" : "Move agent later")
        .help(offset < 0 ? "Move this agent earlier" : "Move this agent later")
    }

    private func sessionKindBinding(_ index: Int) -> Binding<LiveTeamSessionKind> {
        Binding(
            get: { LiveTeamSessionKind(definition.members[index].sessionPolicy) },
            set: { kind in
                definition.members[index].sessionPolicy = switch kind {
                case .own: .ownMemory
                case .shared: .sharedMemory(groupID: "shared")
                case .fresh: .freshEveryRun
                }
            }
        )
    }

    private func addMember() {
        let target = definition.members.last?.target ?? definition.coordinator.target
        let identifier = uniqueMemberID(base: "agent")
        definition.members.append(LiveTeamMember(
            id: identifier,
            name: "New Agent",
            instructions: "Perform one bounded responsibility, report evidence, and stop.",
            target: target,
            runPolicy: .everyCycle,
            sessionPolicy: .ownMemory
        ))
    }

    private func removeMember(at index: Int) {
        let removedID = definition.members[index].id
        definition.members.remove(at: index)
        if preferredNextMemberID == removedID {
            preferredNextMemberID = nil
        }
    }

    private func uniqueMemberID(base: String) -> String {
        let existing = Set(definition.members.map(\.id))
        var candidate = base
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private var validationMessage: String? {
        let cleanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanReason.isEmpty {
            return "Explain why this change should improve progress."
        }
        var candidate = definition
        candidate.strategicReason = cleanReason
        if let message = candidate.validationMessage {
            return message
        }
        for member in candidate.members {
            if let message = application.targetCompatibilityMessage(member.target) {
                return "\(member.name): \(message)"
            }
        }
        if let message = application.targetCompatibilityMessage(candidate.coordinator.target) {
            return "Work routing: \(message)"
        }
        if let message = application.targetCompatibilityMessage(candidate.overseerTarget) {
            return "Strategy reviews: \(message)"
        }
        return nil
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let currentRevision = coordinator.liveTeamDefinition?.revision ?? definition.revision
        let succeeded = await coordinator.submitLiveTeamRevision(
            definition,
            baseRevision: currentRevision,
            reason: reason,
            preferredNextMemberID: preferredNextMemberID,
            replacePendingBoardRevision: coordinator.pendingLiveTeamRevision?.actor == .board,
            discardOverseerProposal: coordinator.pendingLiveTeamRevision?.actor == .overseer
        )
        if succeeded {
            dismiss()
        }
    }
}

private enum LiveTeamSessionKind: String, CaseIterable {
    case own
    case shared
    case fresh

    init(_ policy: LiveTeamSessionPolicy) {
        switch policy {
        case .ownMemory: self = .own
        case .sharedMemory: self = .shared
        case .freshEveryRun: self = .fresh
        }
    }

    var displayName: String {
        switch self {
        case .own: "Own memory"
        case .shared: "Shared memory"
        case .fresh: "Fresh every turn"
        }
    }
}
