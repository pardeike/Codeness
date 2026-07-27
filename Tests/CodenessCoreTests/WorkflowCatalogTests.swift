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
