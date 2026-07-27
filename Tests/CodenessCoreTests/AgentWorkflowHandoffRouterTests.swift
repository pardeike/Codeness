import Foundation
import Testing
@testable import CodenessCore

struct AgentWorkflowHandoffRouterTests {
    @Test
    func usesConfiguredProviderTargetAndAcceptsCompletionOnlyAtLoopDecision() async throws {
        let provider = UtilityOnlyAgentProvider(id: .claude)
        let registry = AgentProviderRegistry(providers: [provider])
        let router = AgentWorkflowHandoffRouter(providers: registry)
        let target = AgentTarget(
            providerID: .claude,
            model: "opus",
            options: .init(effort: "max", mode: .plan, speed: .fast)
        )
        let configuration = WorkflowCoordinatorConfiguration(
            target: target,
            instructions: "Filter facts and decide the whole goal."
        )
        let snapshot = WorkflowStepSnapshot(
            step: WorkflowStep(
                id: "review",
                name: "Review",
                section: .loop,
                instructions: "Review.",
                target: target
            ),
            loopIteration: 2
        )
        let ordinary = WorkflowHandoffContext(
            goal: "Finish the feature",
            workflowName: "Code / Review",
            sourceStep: snapshot,
            nextStepName: "Code",
            makesLoopDecision: false,
            previousHandoff: WorkflowHandoff(
                text: "Preserve the accepted architecture.",
                outcome: .continueWorkflow,
                runLabel: "Architecture"
            ),
            source: "The source claims everything is complete."
        )

        let ordinaryHandoff = try await router.route(
            ordinary,
            configuration: configuration,
            cwd: "/tmp/repository"
        )
        #expect(ordinaryHandoff.outcome == .continueWorkflow)

        let decision = WorkflowHandoffContext(
            goal: ordinary.goal,
            workflowName: ordinary.workflowName,
            sourceStep: ordinary.sourceStep,
            nextStepName: nil,
            makesLoopDecision: true,
            source: ordinary.source
        )
        let decisionHandoff = try await router.route(
            decision,
            configuration: configuration,
            cwd: "/tmp/repository"
        )
        #expect(decisionHandoff.outcome == .complete)

        let summaryContext = WorkSummaryContext(
            goal: ordinary.goal,
            handoffs: [
                WorkSummaryHandoff(
                    runID: UUID(),
                    sequence: 1,
                    kind: .review,
                    label: "Completion review",
                    disposition: .fixComplete,
                    text: "All configured work is complete."
                )
            ]
        )
        let summary = try await router.summarizeWork(
            summaryContext,
            configuration: configuration,
            cwd: "/tmp/repository"
        )
        #expect(summary == "### Completed\n- All configured work is complete.")

        let requests = await provider.requests()
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.target == target })
        #expect(requests.allSatisfy {
            $0.developerInstructions == configuration.instructions
        })
        #expect(requests.first?.prompt.contains("This is not the loop decision point") == true)
        #expect(requests.first?.prompt.contains("Preserve the accepted architecture") == true)
        #expect(requests.first?.prompt.contains("HANDOFF CONSERVATION") == true)
        #expect(requests[1].prompt.contains("last step in the repeating loop") == true)
        #expect(requests[2].prompt.contains("HANDOFFS IN CHRONOLOGICAL ORDER") == true)
        #expect(requests[2].outputSchema == WorkSummaryPrompt.outputSchema)
        #expect(requests.prefix(2).allSatisfy {
            $0.outputSchema == AgentWorkflowHandoffRouter.outputSchema
        })
    }
}

private actor UtilityOnlyAgentProvider: AgentProviding {
    nonisolated let id: AgentProviderID
    private var utilityRequests: [AgentUtilityRequest] = []

    init(id: AgentProviderID) {
        self.id = id
    }

    func prepareSession(_ request: AgentSessionRequest) throws -> AgentSession {
        throw AgentProviderError.invalidSession(request.name)
    }

    func startRun(_ request: AgentRunRequest) throws -> AgentRunHandle {
        throw AgentProviderError.missingRun(request.runID)
    }

    func steer(runID: UUID, message: String) throws {
        throw AgentProviderError.missingRun(runID)
    }

    func interrupt(runID: UUID) throws {
        throw AgentProviderError.missingRun(runID)
    }

    func resolveInteraction(
        runID: UUID,
        interactionID: String,
        resolution: AgentInteractionResolution
    ) throws {
        _ = interactionID
        _ = resolution
        throw AgentProviderError.missingRun(runID)
    }

    func runUtility(_ request: AgentUtilityRequest) -> AgentUtilityResult {
        utilityRequests.append(request)
        if request.outputSchema == WorkSummaryPrompt.outputSchema {
            return AgentUtilityResult(
                output: """
                {"summary":"### Completed\\n- All configured work is complete."}
                """
            )
        }
        return AgentUtilityResult(
            output: """
            {
              "handoffText": "All configured work is complete.",
              "outcome": "complete",
              "runLabel": "Completion review"
            }
            """
        )
    }

    func shutdown() {}

    func requests() -> [AgentUtilityRequest] {
        utilityRequests
    }
}
