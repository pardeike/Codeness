import Foundation

public enum WorkflowCatalogLoader {
    public static func loadProviderCatalog(from data: Data) throws -> AgentProviderCatalog {
        let catalog = try decode(AgentProviderCatalog.self, from: data, resource: "AgentProviders.json")
        guard catalog.schemaVersion == 1 else {
            throw WorkflowCatalogError.unsupportedSchema(
                resource: "AgentProviders.json",
                version: catalog.schemaVersion
            )
        }
        guard !catalog.providers.isEmpty else {
            throw WorkflowCatalogError.invalidCatalog(
                resource: "AgentProviders.json",
                detail: "it contains no providers"
            )
        }
        let identifiers = catalog.providers.map(\.id)
        guard Set(identifiers).count == identifiers.count else {
            throw WorkflowCatalogError.invalidCatalog(
                resource: "AgentProviders.json",
                detail: "provider identifiers are not unique"
            )
        }
        return catalog
    }

    public static func loadWorkflowCatalog(from data: Data) throws -> WorkflowCatalog {
        let catalog = try decode(WorkflowCatalog.self, from: data, resource: "BuiltInWorkflows.json")
        guard catalog.schemaVersion == 1 else {
            throw WorkflowCatalogError.unsupportedSchema(
                resource: "BuiltInWorkflows.json",
                version: catalog.schemaVersion
            )
        }
        guard !catalog.templates.isEmpty else {
            throw WorkflowCatalogError.invalidCatalog(
                resource: "BuiltInWorkflows.json",
                detail: "it contains no workflow templates"
            )
        }
        let identifiers = catalog.templates.map(\.id)
        guard Set(identifiers).count == identifiers.count else {
            throw WorkflowCatalogError.invalidCatalog(
                resource: "BuiltInWorkflows.json",
                detail: "workflow identifiers are not unique"
            )
        }
        guard catalog.templates.contains(where: { $0.id == catalog.defaultTemplateID }) else {
            throw WorkflowCatalogError.invalidCatalog(
                resource: "BuiltInWorkflows.json",
                detail: "the default template does not exist"
            )
        }
        if let validationMessage = catalog.templates.compactMap(\.validationMessage).first {
            throw WorkflowCatalogError.invalidCatalog(
                resource: "BuiltInWorkflows.json",
                detail: validationMessage
            )
        }
        return catalog
    }

    public static func loadBundledProviderCatalog(
        bundles: [Bundle] = [.main]
    ) throws -> AgentProviderCatalog {
        try loadProviderCatalog(from: resourceData(named: "AgentProviders", bundles: bundles))
    }

    public static func loadBundledWorkflowCatalog(
        bundles: [Bundle] = [.main]
    ) throws -> WorkflowCatalog {
        try loadWorkflowCatalog(from: resourceData(named: "BuiltInWorkflows", bundles: bundles))
    }

    private static func resourceData(named name: String, bundles: [Bundle]) throws -> Data {
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: "json") {
                return try Data(contentsOf: url)
            }
        }
        throw WorkflowCatalogError.missingResource("\(name).json")
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        resource: String
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw WorkflowCatalogError.invalidCatalog(
                resource: resource,
                detail: error.localizedDescription
            )
        }
    }
}
