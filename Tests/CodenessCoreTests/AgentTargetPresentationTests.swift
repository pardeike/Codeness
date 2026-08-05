import Testing
@testable import CodenessCore

struct AgentTargetPresentationTests {
    @Test
    func catalogResolvesProviderAndTargetNamesThroughOneGenericPath() {
        let catalog = AgentProviderCatalog(
            schemaVersion: 1,
            providers: [
                AgentProviderDescriptor(
                    id: .codex,
                    displayName: "Codex",
                    executableName: "codex"
                ),
                AgentProviderDescriptor(
                    id: .claude,
                    displayName: "Claude",
                    executableName: "claude"
                ),
                AgentProviderDescriptor(
                    id: .openAICompatible,
                    displayName: "OpenAI-compatible",
                    executableName: ""
                )
            ]
        )
        let model = "model/koala-v3"
        let overrides: [AgentProviderID: String] = [.openAICompatible: "Koala"]

        #expect(
            catalog.displayName(
                for: AgentTarget(providerID: .codex, model: model),
                overrides: overrides
            )
                == "Codex · \(model)"
        )
        #expect(
            catalog.displayName(
                for: AgentTarget(providerID: .claude, model: model),
                overrides: overrides
            )
                == "Claude · \(model)"
        )
        #expect(
            catalog.displayName(
                for: AgentTarget(providerID: .openAICompatible, model: model),
                overrides: overrides
            )
                == "Koala · \(model)"
        )
    }
}
