import Foundation

public enum AgentProviderCatalogLoader {
    public static func load(from data: Data) throws -> AgentProviderCatalog {
        let catalog: AgentProviderCatalog
        do {
            catalog = try JSONDecoder().decode(AgentProviderCatalog.self, from: data)
        } catch {
            throw AgentProviderCatalogError.invalid(
                resource: "AgentProviders.json",
                detail: error.localizedDescription
            )
        }
        guard catalog.schemaVersion == 1 else {
            throw AgentProviderCatalogError.unsupportedSchema(catalog.schemaVersion)
        }
        guard !catalog.providers.isEmpty else {
            throw AgentProviderCatalogError.invalid(
                resource: "AgentProviders.json",
                detail: "it contains no providers"
            )
        }
        let identifiers = catalog.providers.map(\.id)
        guard Set(identifiers).count == identifiers.count else {
            throw AgentProviderCatalogError.invalid(
                resource: "AgentProviders.json",
                detail: "provider identifiers are not unique"
            )
        }
        return catalog
    }

    public static func loadBundled(
        bundles: [Bundle] = [.main]
    ) throws -> AgentProviderCatalog {
        for bundle in bundles {
            if let url = bundle.url(forResource: "AgentProviders", withExtension: "json") {
                return try load(from: Data(contentsOf: url))
            }
        }
        throw AgentProviderCatalogError.missingResource("AgentProviders.json")
    }
}

public enum AgentProviderCatalogError: LocalizedError, Sendable {
    case missingResource(String)
    case unsupportedSchema(Int)
    case invalid(resource: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let resource):
            "Codeness could not find its bundled \(resource) resource."
        case .unsupportedSchema(let version):
            "AgentProviders.json uses unsupported schema version \(version)."
        case .invalid(let resource, let detail):
            "\(resource) is invalid: \(detail)"
        }
    }
}
