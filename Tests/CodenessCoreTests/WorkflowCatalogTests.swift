import Foundation
import Testing
@testable import CodenessCore

struct AgentProviderCatalogTests {
    @Test
    func bundledCatalogExposesAvailableProviders() throws {
        let bundle = Bundle(for: AgentProviderCatalogTestBundleToken.self)
        let providers = try AgentProviderCatalogLoader.loadBundled(
            bundles: [bundle]
        )

        #expect(providers.providers.map(\.id) == [.codex, .claude, .openAICompatible])
        #expect(providers.provider(.codex)?.supportsPlanMode == true)
        #expect(providers.provider(.codex)?.supportsFastMode == true)
        #expect(providers.provider(.codex)?.minimumVersion == "0.145.0")
        #expect(providers.provider(.claude)?.minimumVersion == nil)
        #expect(providers.provider(.claude)?.knownModels.contains {
            $0.id == "opus[1m]" && $0.supportsFastMode
        } == true)
        #expect(providers.provider(.claude)?.knownModels.contains {
            $0.id == "sonnet" && !$0.supportsFastMode
        } == true)
        #expect(providers.provider(.openAICompatible)?.knownModels.isEmpty == true)
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
        #expect(CodexAgentProvider.maximumPersistentWorkflowSessionCount == 4)
        let accepted = capacityWorkflow(
            codexStepCount: CodexAgentProvider.maximumPersistentWorkflowSessionCount,
            coordinatorProvider: .codex
        )
        let rejected = capacityWorkflow(
            codexStepCount: CodexAgentProvider.maximumPersistentWorkflowSessionCount + 1,
            coordinatorProvider: .codex
        )

        #expect(accepted.validationMessage == nil)
        #expect(rejected.validationMessage?.contains("5 persistent Codex step sessions") == true)
        #expect(rejected.validationMessage?.contains("one temporary Codex coordinator session") == true)
        #expect(rejected.validationMessage?.contains("5-thread loaded-session budget") == true)
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
        #expect(rejected.validationMessage?.contains("6 persistent Codex step sessions") == true)
        #expect(rejected.validationMessage?.contains("temporary Codex coordinator") == false)
        #expect(rejected.validationMessage?.contains("5-thread loaded-session budget") == true)
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

}

private final class AgentProviderCatalogTestBundleToken {}
