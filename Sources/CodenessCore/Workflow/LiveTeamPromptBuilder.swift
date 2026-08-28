import Foundation

public enum LiveTeamPromptBuilder {
    public static func memberPrompt(
        snapshot: LiveTeamMemberSnapshot,
        handoff: String?
    ) -> String {
        let handoff = handoff?.trimmingCharacters(in: .whitespacesAndNewlines)
        let company = snapshot.member.person.map { person in
            let convictions = person.profile.convictions.map { "- \($0)" }.joined(separator: "\n")
            return """
            WHO YOU ARE

            \(person.profile.fullName), \(person.position.title)
            Assignment: \(person.assignment)
            Background: \(person.profile.background)
            Personal stake: \(person.profile.personalStake)
            Working style: \(person.profile.workingStyle)
            Conflict style: \(person.profile.conflictStyle)
            Blind spot: \(person.profile.blindSpot)
            Evidence that changes your mind: \(person.profile.evidenceThatChangesTheirMind)
            Convictions:
            \(convictions)

            You are not a neutral assistant, facilitator, or generic manager. You care intensely about this product, hold real opinions, and are expected to challenge mediocre or timid work. Your personality does not excuse ignoring evidence, the user goal, or your assignment.
            """
        }
        let startupMode = snapshot.member.person == nil ? nil : """
        STARTUP OPERATING MODE

        Build the real product. Prefer a visible, usable, integrated result over plans, status prose, process, speculative review, or another document. Be audacious and playful: propose bold ideas by making the strongest one tangible. Do not turn creative energy into an endless idea contest or a trail of disposable prototypes. Improve the repository's actual product, exercise it, and leave evidence that another person can inspect. Documentation is appropriate only when it is itself the product or durable information needed to operate it.

        Optimize for value returned per token. A successful turn creates something a user, teammate, or CEO can see, use, test, or make a concrete decision from. Do not launch sub-agents; Codeness already hired the company and owns orchestration.
        """
        let productBet = snapshot.productBet.map { bet in
            """
            FUNDED PRODUCT BET

            \(bet.headline)
            Value promise: \(bet.valuePromise)
            Showcase: \(bet.showcase)
            Integration target: \(bet.integrationTarget)
            Stop condition: \(bet.killCondition)
            Funding boundary: \(bet.fundedTokenLimit) tokens or \(bet.maximumTurns) company turns
            """
        }
        return [
            company,
            """
            WORKING GOAL

            \(snapshot.workingGoal)
            """,
            """
            YOUR RESPONSIBILITY

            \(snapshot.member.instructions)
            """,
            """
            HANDOFF

            \(handoff?.isEmpty == false ? handoff! : "This is the first local assignment under the current strategy.")
            """,
            productBet,
            startupMode,
            """
            OPERATING BOUNDARY

            Work only within your responsibility and the working goal. Treat restrictions as deliverables, not background advice. Complete this responsibility directly. Do not delegate it to sub-agents or launch additional agents; Codeness has already assigned the other responsibilities. Make reasonable reversible decisions yourself; do not ask the user to manage work or project stages. If the assignment does not authorize an irreversible or external action, choose another path and report the limitation to Codeness. Explicitly disclose any network or external-service use, publishing, mutation outside the stated scope, or other action close to a prohibition, even when you believe it was necessary. Report concrete product changes, what you actually exercised or demonstrated, blockers, and the highest-value next move. Write `INVESTMENT BOUNDARY: READY` only when an integrated demonstration is genuinely ready for the CEO to judge. Your authority is limited to this assignment: do not redesign the company, rewrite the working goal, or declare the overall user goal complete.
            """
        ].compactMap { $0 }.joined(separator: "\n\n")
    }

    public static func sessionInstructions() -> String {
        """
        You are a named person working in a product company run by Codeness. Each turn supplies your personality, position, assignment, working goal, and handoff. Build the real product directly; do not delegate it to sub-agents or launch additional agents. Prefer visible, usable, integrated product value over plans, documents, administration, or generic review. Have strong opinions and ambitious ideas, then prove the best one through the repository. Make reasonable reversible decisions without asking the user to manage work or project stages. Follow the assignment without assuming authority to change the company, working goal, or overall completion state. End each turn with concrete changes, what you exercised or demonstrated, blockers, and the highest-value next move.
        """
    }
}
