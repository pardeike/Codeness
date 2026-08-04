import Foundation
import Testing
@testable import CodenessCore

struct WorkflowCatalogTests {
    @Test
    func bundledCatalogsExposeProvidersAndReusableWorkflowPresets() throws {
        let bundle = Bundle(for: WorkflowCatalogTestBundleToken.self)
        let providers = try WorkflowCatalogLoader.loadBundledProviderCatalog(
            bundles: [bundle]
        )
        let workflows = try WorkflowCatalogLoader.loadBundledWorkflowCatalog(
            bundles: [bundle]
        )

        #expect(providers.providers.map(\.id) == [.codex, .claude])
        #expect(providers.provider(.codex)?.supportsPlanMode == true)
        #expect(providers.provider(.codex)?.supportsFastMode == true)
        #expect(providers.provider(.claude)?.knownModels.contains {
            $0.id == "opus[1m]" && $0.supportsFastMode
        } == true)
        #expect(providers.provider(.claude)?.knownModels.contains {
            $0.id == "sonnet" && !$0.supportsFastMode
        } == true)
        #expect(workflows.defaultTemplateID == "implement-review-fix")
        #expect(Set(workflows.templates.map(\.id)) == [
            "implement-review-fix",
            "code-review",
            "plan-implement-review-fix"
        ])
        #expect(workflows.templates.allSatisfy { $0.validationMessage == nil })
        let planned = try #require(
            workflows.template(id: "plan-implement-review-fix")
        )
        #expect(planned.steps(in: .prefix).map(\.name) == ["Plan"])
        #expect(planned.steps(in: .loop).map(\.name) == [
            "Implement",
            "Review",
            "Fix"
        ])
        #expect(planned.steps.first?.target.options.mode == .plan)
        #expect(planned.coordinator.target.options.speed == .fast)
    }

    @Test
    func bundledWorkflowPromptsKeepScopeAndRoutingTopologyIndependent() throws {
        let bundle = Bundle(for: WorkflowCatalogTestBundleToken.self)
        let workflows = try WorkflowCatalogLoader.loadBundledWorkflowCatalog(
            bundles: [bundle]
        )

        for workflow in workflows.templates {
            let coordinator = workflow.coordinator.instructions
            #expect(coordinator.contains("actual next configured step"))
            #expect(coordinator.contains("current active work unit as scope authority"))
            #expect(coordinator.contains("blocking, parked, and resolved work distinct"))
            #expect(coordinator.contains("last repeating step"))
            #expect(!coordinator.contains("so Code receives"))
            #expect(!coordinator.contains("Only after Fix"))

            for review in workflow.steps.filter({
                $0.name.localizedCaseInsensitiveContains("review")
            }) {
                #expect(review.instructions.contains("active work unit"))
                #expect(review.instructions.contains("block this work unit"))
                #expect(review.instructions.contains("parked for later planning"))
                #expect(review.instructions.contains("overall-goal completion separately"))
            }
        }
    }

    @Test
    func rejectsDuplicateWorkflowIdentifiers() {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "defaultTemplateID": "same",
              "templates": [
                \(workflowJSON(identifier: "same")),
                \(workflowJSON(identifier: "same"))
              ]
            }
            """.utf8
        )

        #expect(throws: WorkflowCatalogError.self) {
            try WorkflowCatalogLoader.loadWorkflowCatalog(from: data)
        }
    }

    @Test
    func validatesMinimumProviderVersionsNumerically() throws {
        let descriptor = AgentProviderDescriptor(
            id: .claude,
            displayName: "Claude",
            executableName: "claude",
            minimumVersion: "2.1.220"
        )

        try AgentExecutableLocator.validateVersion(
            "2.1.220 (Claude Code)",
            descriptor: descriptor
        )
        try AgentExecutableLocator.validateVersion(
            "claude 2.10.0",
            descriptor: descriptor
        )
        #expect(throws: AgentExecutableError.self) {
            try AgentExecutableLocator.validateVersion(
                "Claude Code 2.1.99",
                descriptor: descriptor
            )
        }
    }

    @Test
    func codexCoordinatorReservesTransientHeadroomFromPersistentStepSessions() {
        #expect(CodexAgentProvider.maximumPersistentWorkflowSessionCount == 23)
        let accepted = capacityWorkflow(
            codexStepCount: CodexAgentProvider.maximumPersistentWorkflowSessionCount,
            coordinatorProvider: .codex
        )
        let rejected = capacityWorkflow(
            codexStepCount: CodexAgentProvider.maximumPersistentWorkflowSessionCount + 1,
            coordinatorProvider: .codex
        )

        #expect(accepted.validationMessage == nil)
        #expect(rejected.validationMessage?.contains("24 persistent Codex step sessions") == true)
        #expect(rejected.validationMessage?.contains("one temporary Codex coordinator session") == true)
        #expect(rejected.validationMessage?.contains("24-thread loaded-session budget") == true)
    }

    @Test
    func nonCodexCoordinatorAllowsTheFullCodexPersistentSessionBudget() {
        let accepted = capacityWorkflow(
            codexStepCount: CodexAgentProvider.maximumLoadedThreadBudget,
            coordinatorProvider: .claude
        )
        let rejected = capacityWorkflow(
            codexStepCount: CodexAgentProvider.maximumLoadedThreadBudget + 1,
            coordinatorProvider: .claude
        )

        #expect(accepted.validationMessage == nil)
        #expect(rejected.validationMessage?.contains("25 persistent Codex step sessions") == true)
        #expect(rejected.validationMessage?.contains("temporary Codex coordinator") == false)
        #expect(rejected.validationMessage?.contains("24-thread loaded-session budget") == true)
    }

    private func capacityWorkflow(
        codexStepCount: Int,
        coordinatorProvider: AgentProviderID
    ) -> WorkflowTemplate {
        let codex = AgentTarget(providerID: .codex, model: "codex-model")
        let coordinator = AgentTarget(
            providerID: coordinatorProvider,
            model: "coordinator-model"
        )
        return WorkflowTemplate(
            id: "capacity-\(codexStepCount)-\(coordinatorProvider.rawValue)",
            name: "Capacity workflow",
            summary: "Exercises provider session capacity.",
            steps: (0..<codexStepCount).map { index in
                WorkflowStep(
                    id: "step-\(index)",
                    name: "Step \(index)",
                    section: .loop,
                    instructions: "Perform step \(index).",
                    target: codex
                )
            },
            coordinator: WorkflowCoordinatorConfiguration(
                target: coordinator,
                instructions: "Route the result."
            )
        )
    }

    private func workflowJSON(identifier: String) -> String {
        """
        {
          "id": "\(identifier)",
          "name": "Workflow",
          "summary": "Test",
          "steps": [
            {
              "id": "work",
              "name": "Work",
              "section": "loop",
              "instructions": "Do work.",
              "target": {
                "providerID": "codex",
                "model": "model",
                "options": {
                  "effort": "high",
                  "mode": "standard",
                  "speed": "standard"
                }
              }
            }
          ],
          "coordinator": {
            "target": {
              "providerID": "codex",
              "model": "model",
              "options": {
                "effort": "low",
                "mode": "standard",
                "speed": "standard"
              }
            },
            "instructions": "Route the result."
          }
        }
        """
    }
}

private final class WorkflowCatalogTestBundleToken {}
