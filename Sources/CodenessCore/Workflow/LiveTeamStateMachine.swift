import Foundation

public enum LiveTeamScheduleTransition: Sendable, Equatable {
    case run(LiveTeamCheckpoint)
    case noEligibleMember
}

public enum LiveTeamStateMachine {
    public static func initialCheckpoint(
        for definition: LiveTeamDefinition,
        completedOnceMemberIDs: Set<String> = []
    ) -> LiveTeamCheckpoint? {
        guard let member = definition.members.first(where: {
            isEligible($0, completedOnceMemberIDs: completedOnceMemberIDs)
        }) else { return nil }
        return LiveTeamCheckpoint(
            memberID: member.id,
            cycle: 1,
            revision: definition.revision
        )
    }

    public static func nextCheckpoint(
        after completedMemberID: String,
        cycle: Int,
        in definition: LiveTeamDefinition,
        completedOnceMemberIDs: Set<String>,
        preferredMemberID: String? = nil
    ) -> LiveTeamCheckpoint? {
        if let preferredMemberID,
           let preferred = definition.member(id: preferredMemberID),
           isEligible(preferred, completedOnceMemberIDs: completedOnceMemberIDs) {
            return LiveTeamCheckpoint(
                memberID: preferred.id,
                cycle: max(cycle, 1),
                revision: definition.revision
            )
        }

        guard !definition.members.isEmpty else { return nil }
        let startIndex: Int
        if let completedIndex = definition.members.firstIndex(where: {
            $0.id == completedMemberID
        }) {
            startIndex = completedIndex + 1
        } else {
            startIndex = 0
        }

        for index in startIndex..<definition.members.count {
            let candidate = definition.members[index]
            if isEligible(candidate, completedOnceMemberIDs: completedOnceMemberIDs) {
                return LiveTeamCheckpoint(
                    memberID: candidate.id,
                    cycle: max(cycle, 1),
                    revision: definition.revision
                )
            }
        }

        for index in 0..<min(startIndex, definition.members.count) {
            let candidate = definition.members[index]
            if isEligible(candidate, completedOnceMemberIDs: completedOnceMemberIDs) {
                return LiveTeamCheckpoint(
                    memberID: candidate.id,
                    cycle: max(cycle, 1) + 1,
                    revision: definition.revision
                )
            }
        }
        return nil
    }

    public static func checkpoint(
        reconciling checkpoint: LiveTeamCheckpoint?,
        in definition: LiveTeamDefinition,
        completedOnceMemberIDs: Set<String>
    ) -> LiveTeamCheckpoint? {
        if let checkpoint,
           let member = definition.member(id: checkpoint.memberID),
           isEligible(member, completedOnceMemberIDs: completedOnceMemberIDs) {
            return LiveTeamCheckpoint(
                memberID: checkpoint.memberID,
                cycle: checkpoint.cycle,
                revision: definition.revision
            )
        }
        return initialCheckpoint(
            for: definition,
            completedOnceMemberIDs: completedOnceMemberIDs
        )
    }

    public static func pendingRevision(
        definition: LiveTeamDefinition,
        baseRevision: Int,
        actor: LiveTeamRevisionActor,
        reason: String,
        evidence: String,
        preferredNextMemberID: String? = nil,
        currentDefinition: LiveTeamDefinition,
        existingPending: LiveTeamPendingRevision?,
        replacingBoardPending: Bool = false
    ) throws -> LiveTeamPendingRevision {
        guard baseRevision == currentDefinition.revision else {
            throw LiveTeamRevisionError.stale(
                base: baseRevision,
                current: currentDefinition.revision
            )
        }
        if let existingPending {
            if actor == .overseer, existingPending.actor == .board {
                throw LiveTeamRevisionError.pendingBoardRevision
            }
            guard actor == .board,
                  existingPending.actor == .board,
                  replacingBoardPending else {
                throw LiveTeamRevisionError.pendingRevisionRequiresDecision
            }
        }
        var normalized = definition
        normalized.revision = currentDefinition.revision + 1
        normalized.strategicReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = normalized.validationMessage {
            throw LiveTeamRevisionError.invalid(message)
        }
        if let preferredNextMemberID,
           normalized.member(id: preferredNextMemberID) == nil {
            throw LiveTeamRevisionError.invalid(
                "The preferred next agent is not part of the proposed setup."
            )
        }
        return LiveTeamPendingRevision(
            definition: normalized,
            baseRevision: baseRevision,
            actor: actor,
            reason: normalized.strategicReason,
            evidence: evidence,
            preferredNextMemberID: preferredNextMemberID
        )
    }

    public static func activationSummary(
        from old: LiveTeamDefinition,
        to new: LiveTeamDefinition
    ) -> String {
        let oldIDs = Set(old.members.map(\.id))
        let newIDs = Set(new.members.map(\.id))
        let added = newIDs.subtracting(oldIDs).count
        let removed = oldIDs.subtracting(newIDs).count
        let edited = new.members.count { member in
            guard let previous = old.member(id: member.id) else { return false }
            return previous != member
        }
        var parts: [String] = []
        if added > 0 { parts.append("added \(added)") }
        if removed > 0 { parts.append("removed \(removed)") }
        if edited > 0 { parts.append("changed \(edited)") }
        if old.workingGoal != new.workingGoal { parts.append("updated working goal") }
        if old.coordinator != new.coordinator { parts.append("updated work routing") }
        if old.overseerTarget != new.overseerTarget { parts.append("updated strategy reviews") }
        return parts.isEmpty ? "No structural change" : parts.joined(separator: ", ")
    }

    public static func reconciledCompletedOnceMemberIDs(
        _ completedMemberIDs: Set<String>,
        from old: LiveTeamDefinition,
        to new: LiveTeamDefinition
    ) -> Set<String> {
        guard old.workingGoal == new.workingGoal else { return [] }
        return Set(new.members.compactMap { member in
            guard member.runPolicy == .once,
                  completedMemberIDs.contains(member.id),
                  let previous = old.member(id: member.id),
                  previous.runPolicy == .once,
                  previous.instructions == member.instructions else {
                return nil
            }
            return member.id
        })
    }

    private static func isEligible(
        _ member: LiveTeamMember,
        completedOnceMemberIDs: Set<String>
    ) -> Bool {
        member.runPolicy == .everyCycle || !completedOnceMemberIDs.contains(member.id)
    }
}
