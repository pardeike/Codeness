import Foundation

/// Keeps internal orchestration names out of text that Codeness presents to users.
/// It is intentionally limited to Codeness-generated control fields; user goals and
/// agent results are never rewritten.
enum LiveTeamProductLanguage {
    static func assignment(_ text: String) -> String {
        var result = replacingInternalRoles(in: text)
        result = replacing(
            in: result,
            [
                ("team members", "agents"),
                ("team member", "agent"),
                ("Team members", "Agents"),
                ("Team member", "Agent"),
                ("team revision", "agent change"),
                ("Team revision", "Agent change"),
                ("strategic revision", "strategy change"),
                ("Strategic revision", "Strategy change")
            ]
        )
        return result
    }

    static func narrative(_ text: String) -> String {
        var result = assignment(text)
        result = replacing(
            in: result,
            [
                ("smallest useful team", "smallest useful agent setup"),
                ("smallest coherent team", "smallest coherent agent setup"),
                ("Smallest useful team", "Smallest useful agent setup"),
                ("Smallest coherent team", "Smallest coherent agent setup"),
                ("Created 2-member live team", "Prepared 2 agents"),
                ("live-team", "agent"),
                ("Live-team", "Agent"),
                ("live team", "agent setup"),
                ("Live team", "Agent setup"),
                ("current team", "current agents"),
                ("Current team", "Current agents"),
                ("the team", "the agents"),
                ("The team", "The agents"),
                ("team revisions", "agent changes"),
                ("Team revisions", "Agent changes"),
                ("revision history", "change history"),
                ("Revision history", "Change history"),
                ("team cycle", "round"),
                ("Team cycle", "Round")
            ]
        )
        result = replacingWord("Revision", with: "Change", in: result)
        result = replacingWord("revision", with: "change", in: result)
        result = replacingWord("Cycle", with: "Round", in: result)
        result = replacingWord("cycle", with: "round", in: result)
        result = replacingWord("Team", with: "Agents", in: result)
        result = replacingWord("team", with: "agents", in: result)
        result = replacingWord("Member", with: "Agent", in: result)
        result = replacingWord("member", with: "agent", in: result)
        return result
    }

    static func runLabel(_ text: String) -> String {
        var result = narrative(text)
        result = result.replacingOccurrences(
            of: #"(?i)([-_ ]+)(change|setup)([-_ ]+[0-9]+)$"#,
            with: "",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func definition(_ definition: LiveTeamDefinition) -> LiveTeamDefinition {
        var result = definition
        result.workingGoal = assignment(result.workingGoal)
        result.strategicReason = narrative(result.strategicReason)
        result.members = result.members.map(member)
        result.coordinator.instructions = narrative(result.coordinator.instructions)
        result.coordinator.target = executionTarget(result.coordinator.target)
        result.overseerTarget = executionTarget(result.overseerTarget)
        return result
    }

    static func member(_ member: LiveTeamMember) -> LiveTeamMember {
        var result = member
        result.name = narrative(result.name)
        result.instructions = assignment(result.instructions)
        result.target = executionTarget(result.target)
        return result
    }

    static func coordinatorDecision(
        _ decision: LiveTeamCoordinatorDecision
    ) -> LiveTeamCoordinatorDecision {
        var result = decision
        result.handoff = narrative(result.handoff)
        result.runLabel = runLabel(result.runLabel)
        result.evidence = narrative(result.evidence)
        return result
    }

    static func strategicDecision(
        _ decision: LiveTeamStrategicDecision
    ) -> LiveTeamStrategicDecision {
        var result = decision
        result.reason = narrative(result.reason)
        result.evidence = narrative(result.evidence)
        result.proposedDefinition = result.proposedDefinition.map(definition)
        return result
    }

    static func completionDecision(
        _ decision: LiveTeamCompletionDecision
    ) -> LiveTeamCompletionDecision {
        var result = decision
        result.reason = narrative(result.reason)
        result.evidence = narrative(result.evidence)
        return result
    }

    static func normalizePersistedControlText(in activity: inout ActivityRecord) {
        guard var state = activity.liveTeam else { return }
        state.overseer.instructions = narrative(state.overseer.instructions)
        state.overseer.target = executionTarget(state.overseer.target)
        state.currentDefinition = state.currentDefinition.map(definition)
        if var pending = state.pendingRevision {
            pending.definition = definition(pending.definition)
            pending.reason = narrative(pending.reason)
            pending.evidence = narrative(pending.evidence)
            state.pendingRevision = pending
        }
        state.coordinatorHandoff = state.coordinatorHandoff.map(narrative)
        state.lastCoordinatorDecision = state.lastCoordinatorDecision.map(
            coordinatorDecision
        )
        state.editHistory = state.editHistory.map { edit in
            LiveTeamEditRecord(
                id: edit.id,
                revision: edit.revision,
                actor: edit.actor,
                summary: narrative(edit.summary),
                reason: narrative(edit.reason),
                evidence: narrative(edit.evidence),
                createdAt: edit.createdAt
            )
        }
        state.strategicReviewAfterBoundary = state.strategicReviewAfterBoundary.map(
            request
        )
        state.resumeCheckpoint = state.resumeCheckpoint.map(resumeCheckpoint)
        state.boardDirectionReason = state.boardDirectionReason.map(narrative)
        activity.liveTeam = state

        activity.stepSessions = activity.stepSessions.mapValues { session in
            var result = session
            if result.target.options.mode == .plan {
                result.providerSessionID = nil
            }
            result.target = executionTarget(result.target)
            return result
        }

        activity.runs = activity.runs.map { run in
            var result = run
            result.coordinatorDecision = result.coordinatorDecision.map(
                coordinatorDecision
            )
            if let snapshot = result.liveTeamMember {
                result.liveTeamMember = LiveTeamMemberSnapshot(
                    member: member(snapshot.member),
                    workingGoal: assignment(snapshot.workingGoal),
                    revision: snapshot.revision,
                    cycle: snapshot.cycle,
                    sessionSlotID: snapshot.sessionSlotID
                )
            }
            return result
        }
    }

    static func workSummary(_ text: String) -> String {
        narrative(text)
    }

    private static func executionTarget(_ target: AgentTarget) -> AgentTarget {
        var result = target
        result.options.mode = .standard
        return result
    }

    private static func request(_ request: LiveTeamOverseerRequest) -> LiveTeamOverseerRequest {
        var result = request
        result.reason = narrative(result.reason)
        return result
    }

    private static func resumeCheckpoint(
        _ checkpoint: LiveTeamResumeCheckpoint
    ) -> LiveTeamResumeCheckpoint {
        switch checkpoint {
        case .invokeOverseer(let value): .invokeOverseer(request(value))
        case .recoverRun, .routeCompletedRun, .applyCoordinatorDecision, .perform:
            checkpoint
        }
    }

    private static func replacingInternalRoles(in text: String) -> String {
        var result = replacing(
            in: text,
            [
                ("the Overseer, Coordinator, and every team member", "every Codeness agent"),
                ("The Overseer, Coordinator, and every team member", "Every Codeness agent"),
                ("Overseer, Coordinator, and every team member", "every Codeness agent"),
                ("Every Overseer, Coordinator, and team member", "Every Codeness agent"),
                ("every Overseer, Coordinator, and team member", "every Codeness agent"),
                ("the Overseer, Coordinator, builder, and reviewer", "the strategy, routing, build, and review agents"),
                ("The Overseer, Coordinator, builder, and reviewer", "The strategy, routing, build, and review agents"),
                ("Overseer attention is required to", "Codeness must"),
                ("Overseer Bootstrap", "Initial strategy review"),
                ("updated Coordinator, updated Overseer", "updated work routing and strategy reviews"),
                ("fresh Overseer review", "fresh strategy review"),
                ("Fresh Overseer review", "Fresh strategy review"),
                ("Coordinator evidence", "routing evidence"),
                ("Coordinator handoff", "handoff"),
                ("Coordinator policy", "work-routing policy"),
                ("The Board's", "Your"),
                ("The Board’s", "Your"),
                ("the Board's", "your"),
                ("the Board’s", "your"),
                ("Board-authorized", "user-authorized"),
                ("Board-approved", "user-approved"),
                ("no new Board authority", "no additional permission from you"),
                ("new Board authority", "additional permission from you"),
                ("Board goal", "user goal"),
                ("Board authority", "your authority"),
                ("Board policy", "your requirements"),
                ("Board direction", "your direction"),
                ("Board review", "your review"),
                ("Board edit", "your change"),
                ("The Board", "You"),
                ("the Board", "you"),
                ("Overseer's", "Codeness's"),
                ("Overseer’s", "Codeness’s"),
                ("Coordinator's", "Codeness's"),
                ("Coordinator’s", "Codeness’s"),
                ("overseer's", "Codeness's"),
                ("overseer’s", "Codeness’s"),
                ("coordinator's", "Codeness's"),
                ("coordinator’s", "Codeness’s"),
                ("the Overseer", "Codeness"),
                ("The Overseer", "Codeness"),
                ("the Coordinator", "Codeness"),
                ("The Coordinator", "Codeness"),
                ("the overseer", "Codeness"),
                ("an overseer", "Codeness"),
                ("the coordinator", "Codeness"),
                ("a coordinator", "Codeness")
            ]
        )
        result = replacingWord("Board", with: "user", in: result)
        result = replacingWord("Overseer", with: "Codeness", in: result)
        result = replacingWord("Coordinator", with: "Codeness", in: result)
        result = replacingWord("overseer", with: "strategy review", in: result)
        result = replacingWord("coordinator", with: "work routing", in: result)
        return result
    }

    private static func replacing(
        in text: String,
        _ replacements: [(String, String)]
    ) -> String {
        replacements.reduce(text) { result, replacement in
            result.replacingOccurrences(of: replacement.0, with: replacement.1)
        }
    }

    private static func replacingWord(
        _ word: String,
        with replacement: String,
        in text: String
    ) -> String {
        text.replacingOccurrences(
            of: #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#,
            with: replacement,
            options: .regularExpression
        )
    }
}
