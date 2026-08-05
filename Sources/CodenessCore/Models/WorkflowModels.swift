import Foundation

public struct AgentProviderID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public static let codex = AgentProviderID(rawValue: "codex")
    public static let claude = AgentProviderID(rawValue: "claude")
    public static let openAICompatible = AgentProviderID(rawValue: "openai-compatible")

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct OpenAICompatibleProviderConfiguration: Codable, Equatable, Sendable {
    public static let defaultDisplayName = "OpenAI-compatible"

    public var endpoint: String
    public var apiKeyFile: String
    public var apiKeyName: String
    public var displayName: String

    public init(
        endpoint: String = "https://api.openai.com/v1",
        apiKeyFile: String = "~/.api-keys",
        apiKeyName: String = "OPENAI_API_KEY",
        displayName: String = Self.defaultDisplayName
    ) {
        self.endpoint = endpoint
        self.apiKeyFile = apiKeyFile
        self.apiKeyName = apiKeyName
        let cleanDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = cleanDisplayName.isEmpty
            ? Self.defaultDisplayName
            : cleanDisplayName
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case apiKeyFile
        case apiKeyName
        case displayName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            endpoint: try container.decode(String.self, forKey: .endpoint),
            apiKeyFile: try container.decode(String.self, forKey: .apiKeyFile),
            apiKeyName: try container.decode(String.self, forKey: .apiKeyName),
            displayName: try container.decodeIfPresent(
                String.self,
                forKey: .displayName
            ) ?? Self.defaultDisplayName
        )
    }

    public var endpointURL: URL? {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              var url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.hasSuffix("chat/completions") else { return url }
        url.appendPathComponent("chat/completions")
        return url
    }

    public var validationMessage: String? {
        guard endpointURL != nil else {
            return "Enter a valid HTTP or HTTPS \(displayName) endpoint."
        }
        let cleanKeyFile = apiKeyFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKeyName = apiKeyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanKeyFile.isEmpty == cleanKeyName.isEmpty else {
            return "Enter both the API-key file and property name, or leave both empty."
        }
        return nil
    }
}

public enum AgentMode: String, Codable, CaseIterable, Sendable {
    case standard
    case plan

    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .plan: "Plan"
        }
    }
}

public enum AgentSpeed: String, Codable, CaseIterable, Sendable {
    case standard
    case fast

    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .fast: "Fast"
        }
    }
}

public struct AgentExecutionOptions: Codable, Equatable, Sendable {
    public var effort: String?
    public var mode: AgentMode
    public var speed: AgentSpeed

    public init(
        effort: String? = nil,
        mode: AgentMode = .standard,
        speed: AgentSpeed = .standard
    ) {
        self.effort = effort
        self.mode = mode
        self.speed = speed
    }
}

public struct AgentTarget: Codable, Equatable, Sendable {
    public var providerID: AgentProviderID
    public var model: String
    public var options: AgentExecutionOptions

    public init(
        providerID: AgentProviderID,
        model: String,
        options: AgentExecutionOptions = .init()
    ) {
        self.providerID = providerID
        self.model = model
        self.options = options
    }

    public var validationMessage: String? {
        if providerID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The provider is empty."
        }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The model is empty."
        }
        return nil
    }
}

public struct AgentModelDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let description: String
    public let supportedEfforts: [String]
    public let defaultEffort: String?
    public let supportsPlanMode: Bool
    public let supportsFastMode: Bool
    public let isAlias: Bool

    public init(
        id: String,
        displayName: String,
        description: String = "",
        supportedEfforts: [String] = [],
        defaultEffort: String? = nil,
        supportsPlanMode: Bool = true,
        supportsFastMode: Bool = false,
        isAlias: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
        self.supportsPlanMode = supportsPlanMode
        self.supportsFastMode = supportsFastMode
        self.isAlias = isAlias
    }
}

public extension AgentModelDescriptor {
    init(codexModel: CodexModel) {
        self.init(
            id: codexModel.model,
            displayName: codexModel.displayName,
            description: codexModel.description,
            supportedEfforts: codexModel.efforts,
            defaultEffort: codexModel.defaultEffort,
            supportsPlanMode: true,
            supportsFastMode: codexModel.serviceTiers.contains {
                $0.name.localizedCaseInsensitiveCompare("Fast") == .orderedSame
            },
            isAlias: false
        )
    }
}

public struct AgentProviderDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: AgentProviderID
    public let displayName: String
    public let executableName: String
    public let minimumVersion: String?
    public let executableSearchPaths: [String]
    public let knownModels: [AgentModelDescriptor]
    public let supportsPlanMode: Bool
    public let supportsFastMode: Bool

    public init(
        id: AgentProviderID,
        displayName: String,
        executableName: String,
        minimumVersion: String? = nil,
        executableSearchPaths: [String] = [],
        knownModels: [AgentModelDescriptor] = [],
        supportsPlanMode: Bool = true,
        supportsFastMode: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.executableName = executableName
        self.minimumVersion = minimumVersion
        self.executableSearchPaths = executableSearchPaths
        self.knownModels = knownModels
        self.supportsPlanMode = supportsPlanMode
        self.supportsFastMode = supportsFastMode
    }
}

public struct AgentProviderCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let providers: [AgentProviderDescriptor]

    public init(schemaVersion: Int, providers: [AgentProviderDescriptor]) {
        self.schemaVersion = schemaVersion
        self.providers = providers
    }

    public func provider(_ id: AgentProviderID) -> AgentProviderDescriptor? {
        providers.first { $0.id == id }
    }

    public func displayName(
        for providerID: AgentProviderID,
        overrides: [AgentProviderID: String] = [:]
    ) -> String {
        if let override = overrides[providerID]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return provider(providerID)?.displayName ?? providerID.rawValue.capitalized
    }

    public func displayName(
        for target: AgentTarget,
        overrides: [AgentProviderID: String] = [:]
    ) -> String {
        "\(displayName(for: target.providerID, overrides: overrides)) · \(target.model)"
    }
}

public enum WorkflowSection: String, Codable, CaseIterable, Sendable {
    case prefix
    case loop
    case postfix

    public var displayName: String {
        switch self {
        case .prefix: "Before loop"
        case .loop: "Repeating loop"
        case .postfix: "After completion"
        }
    }
}

public struct WorkflowStep: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var section: WorkflowSection
    public var instructions: String
    public var target: AgentTarget

    public init(
        id: String,
        name: String,
        section: WorkflowSection,
        instructions: String,
        target: AgentTarget
    ) {
        self.id = id
        self.name = name
        self.section = section
        self.instructions = instructions
        self.target = target
    }

    public var validationMessage: String? {
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "A workflow step has no identifier."
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Step \(id) has no name."
        }
        if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(name) has no instructions."
        }
        if let targetMessage = target.validationMessage {
            return "\(name): \(targetMessage)"
        }
        return nil
    }
}

public struct WorkflowCoordinatorConfiguration: Codable, Equatable, Sendable {
    public var target: AgentTarget
    public var instructions: String

    public init(target: AgentTarget, instructions: String) {
        self.target = target
        self.instructions = instructions
    }
}

public struct WorkflowTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var steps: [WorkflowStep]
    public var coordinator: WorkflowCoordinatorConfiguration

    public init(
        id: String,
        name: String,
        summary: String,
        steps: [WorkflowStep],
        coordinator: WorkflowCoordinatorConfiguration
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.steps = steps
        self.coordinator = coordinator
    }

    public func steps(in section: WorkflowSection) -> [WorkflowStep] {
        steps.filter { $0.section == section }
    }

    public func step(id: String) -> WorkflowStep? {
        steps.first { $0.id == id }
    }

    public var validationMessage: String? {
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The workflow has no identifier."
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The workflow has no name."
        }
        if steps(in: .loop).isEmpty {
            return "\(name) needs at least one repeating step."
        }
        let identifiers = steps.map(\.id)
        if Set(identifiers).count != identifiers.count {
            return "\(name) contains duplicate step identifiers."
        }
        if let message = steps.compactMap(\.validationMessage).first {
            return message
        }
        if let targetMessage = coordinator.target.validationMessage {
            return "Coordinator: \(targetMessage)"
        }
        if coordinator.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The coordinator instructions are empty."
        }
        let codexStepSessionCount = steps.lazy.filter {
            $0.target.providerID == .codex
        }.count
        let codexCoordinatorHeadroom = coordinator.target.providerID == .codex ? 1 : 0
        let requiredCodexThreadCount = codexStepSessionCount + codexCoordinatorHeadroom
        if requiredCodexThreadCount > CodexAgentProvider.maximumLoadedThreadBudget {
            let coordinatorDetail = codexCoordinatorHeadroom == 1
                ? " plus one temporary Codex coordinator session"
                : ""
            return "\(name) requires \(codexStepSessionCount) persistent Codex step sessions\(coordinatorDetail), exceeding Codex's \(CodexAgentProvider.maximumLoadedThreadBudget)-thread loaded-session budget. Reduce the number of Codex steps or use another provider for the workflow coordinator."
        }
        return nil
    }
}

public struct WorkflowCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let defaultTemplateID: String
    public let templates: [WorkflowTemplate]

    public init(schemaVersion: Int, defaultTemplateID: String, templates: [WorkflowTemplate]) {
        self.schemaVersion = schemaVersion
        self.defaultTemplateID = defaultTemplateID
        self.templates = templates
    }

    public var defaultTemplate: WorkflowTemplate? {
        templates.first { $0.id == defaultTemplateID } ?? templates.first
    }

    public func template(id: String) -> WorkflowTemplate? {
        templates.first { $0.id == id }
    }
}

public struct WorkflowCursor: Codable, Equatable, Sendable {
    public var section: WorkflowSection
    public var stepIndex: Int
    public var loopIteration: Int

    public init(section: WorkflowSection, stepIndex: Int, loopIteration: Int = 1) {
        self.section = section
        self.stepIndex = stepIndex
        self.loopIteration = max(loopIteration, 1)
    }
}

public enum WorkflowOutcome: String, Codable, CaseIterable, Sendable {
    case continueWorkflow
    case complete
    case blocked
    case failed
    case unclear

    public var displayName: String {
        switch self {
        case .continueWorkflow: "Continue"
        case .complete: "Complete"
        case .blocked: "Blocked"
        case .failed: "Failed"
        case .unclear: "Unclear"
        }
    }
}

public struct WorkflowHandoff: Codable, Equatable, Sendable {
    public var text: String
    public var outcome: WorkflowOutcome
    public var runLabel: String

    public init(text: String, outcome: WorkflowOutcome, runLabel: String) {
        self.text = text
        self.outcome = outcome
        self.runLabel = runLabel
    }
}

public struct WorkflowSessionState: Codable, Equatable, Sendable {
    public let stepID: String
    public var lineage: Int
    public var target: AgentTarget
    public var providerSessionID: String?

    public init(
        stepID: String,
        lineage: Int = 1,
        target: AgentTarget,
        providerSessionID: String? = nil
    ) {
        self.stepID = stepID
        self.lineage = max(lineage, 1)
        self.target = target
        self.providerSessionID = providerSessionID
    }
}

public enum WorkflowResumeCheckpoint: Codable, Equatable, Sendable {
    case recoverRun(UUID)
    case routeCompletedRun(UUID)
    case perform(WorkflowCursor)
}

public struct WorkflowStepSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let section: WorkflowSection
    public let loopIteration: Int

    public init(step: WorkflowStep, loopIteration: Int) {
        id = step.id
        name = step.name
        section = step.section
        self.loopIteration = max(loopIteration, 1)
    }
}

public enum WorkflowCatalogError: LocalizedError, Sendable {
    case missingResource(String)
    case unsupportedSchema(resource: String, version: Int)
    case invalidCatalog(resource: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let resource):
            "Codeness could not find its bundled \(resource) resource."
        case .unsupportedSchema(let resource, let version):
            "\(resource) uses unsupported schema version \(version)."
        case .invalidCatalog(let resource, let detail):
            "\(resource) is invalid: \(detail)"
        }
    }
}
