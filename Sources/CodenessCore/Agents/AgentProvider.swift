import Foundation

public struct AgentSession: Codable, Equatable, Sendable {
    public let providerID: AgentProviderID
    public let id: String
    public let target: AgentTarget

    public init(providerID: AgentProviderID, id: String, target: AgentTarget) {
        self.providerID = providerID
        self.id = id
        self.target = target
    }
}

public struct AgentSessionRequest: Sendable, Equatable {
    public let existingSessionID: String?
    public let name: String
    public let cwd: String
    public let target: AgentTarget
    public let developerInstructions: String

    public init(
        existingSessionID: String?,
        name: String,
        cwd: String,
        target: AgentTarget,
        developerInstructions: String
    ) {
        self.existingSessionID = existingSessionID
        self.name = name
        self.cwd = cwd
        self.target = target
        self.developerInstructions = developerInstructions
    }
}

public struct AgentRunRequest: Sendable, Equatable {
    public let runID: UUID
    public let session: AgentSession
    public let cwd: String
    public let prompt: String
    public let target: AgentTarget
    public let outputSchema: JSONValue?

    public init(
        runID: UUID,
        session: AgentSession,
        cwd: String,
        prompt: String,
        target: AgentTarget,
        outputSchema: JSONValue? = nil
    ) {
        self.runID = runID
        self.session = session
        self.cwd = cwd
        self.prompt = prompt
        self.target = target
        self.outputSchema = outputSchema
    }
}

public struct AgentRunHandle: Sendable {
    public let runID: UUID
    public let providerID: AgentProviderID
    public let sessionID: String
    public let executionID: String?
    public let events: AsyncStream<AgentEvent>

    public init(
        runID: UUID,
        providerID: AgentProviderID,
        sessionID: String,
        executionID: String?,
        events: AsyncStream<AgentEvent>
    ) {
        self.runID = runID
        self.providerID = providerID
        self.sessionID = sessionID
        self.executionID = executionID
        self.events = events
    }
}

public struct AgentUtilityRequest: Sendable, Equatable {
    public let cwd: String
    public let prompt: String
    public let target: AgentTarget
    public let developerInstructions: String
    public let outputSchema: JSONValue

    public init(
        cwd: String,
        prompt: String,
        target: AgentTarget,
        developerInstructions: String,
        outputSchema: JSONValue
    ) {
        self.cwd = cwd
        self.prompt = prompt
        self.target = target
        self.developerInstructions = developerInstructions
        self.outputSchema = outputSchema
    }
}

public struct AgentUtilityResult: Sendable, Equatable {
    public let output: String
    public let tokenUsage: RunTokenUsage?

    public init(output: String, tokenUsage: RunTokenUsage? = nil) {
        self.output = output
        self.tokenUsage = tokenUsage
    }
}

public struct AgentInteractionDecision: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let explanation: String
    public let payload: JSONValue
    public let isDestructive: Bool

    public init(
        id: String,
        label: String,
        explanation: String,
        payload: JSONValue,
        isDestructive: Bool = false
    ) {
        self.id = id
        self.label = label
        self.explanation = explanation
        self.payload = payload
        self.isDestructive = isDestructive
    }
}

public struct AgentInteraction: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case approval
        case questions
        case dialog
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String
    public let questions: [InputQuestion]
    public let decisions: [AgentInteractionDecision]
    public let rawParameters: JSONValue

    public init(
        id: String,
        kind: Kind,
        title: String,
        detail: String,
        questions: [InputQuestion] = [],
        decisions: [AgentInteractionDecision] = [],
        rawParameters: JSONValue
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.questions = questions
        self.decisions = decisions
        self.rawParameters = rawParameters
    }
}

public enum AgentInteractionResolution: Sendable, Equatable {
    case decision(JSONValue)
    case answers([String: [String]])
    case raw(JSONValue)
    case cancel
}

public enum AgentEvent: Sendable, Equatable {
    case started(executionID: String)
    case transcript(String)
    case diagnostic(String)
    case tokenUsage(RunTokenUsage)
    case interaction(AgentInteraction)
    case interactionResolved(String)
    case completed(
        output: String,
        durationMilliseconds: Int64?,
        tokenUsage: RunTokenUsage?
    )
    case interrupted(String?)
    case sessionUnavailable(String)
    case failed(String)
}

public enum AgentProviderError: LocalizedError, Sendable {
    case unavailable(AgentProviderID, String)
    case unsupportedProvider(AgentProviderID)
    case sessionUnavailable(
        provider: AgentProviderID,
        sessionID: String,
        detail: String
    )
    case invalidSession(String)
    case missingRun(UUID)
    case invalidResponse(String)
    case processExited(
        provider: AgentProviderID,
        termination: SubprocessTermination,
        detail: String
    )

    public var errorDescription: String? {
        switch self {
        case .unavailable(let provider, let detail):
            return "\(provider.rawValue.capitalized) is unavailable: \(detail)"
        case .unsupportedProvider(let provider):
            return "No agent provider is registered for \(provider.rawValue)."
        case .sessionUnavailable(_, _, let detail):
            return detail
        case .invalidSession(let detail):
            return "The agent session is invalid: \(detail)"
        case .missingRun(let runID):
            return "The agent run \(runID.uuidString) is no longer active."
        case .invalidResponse(let detail):
            return "The agent CLI returned an invalid response: \(detail)"
        case .processExited(let provider, let termination, let detail):
            let summary = termination.userFacingDescription(
                subject: provider.rawValue.capitalized
            )
            return detail.isEmpty ? summary : "\(summary) \(detail)"
        }
    }
}

public protocol AgentProviding: Actor {
    nonisolated var id: AgentProviderID { get }

    func prepareSession(_ request: AgentSessionRequest) async throws -> AgentSession
    func startRun(_ request: AgentRunRequest) async throws -> AgentRunHandle
    func steer(runID: UUID, message: String) async throws
    func interrupt(runID: UUID) async throws
    func resolveInteraction(
        runID: UUID,
        interactionID: String,
        resolution: AgentInteractionResolution
    ) async throws
    func runUtility(_ request: AgentUtilityRequest) async throws -> AgentUtilityResult
    func shutdown() async
}

public actor AgentProviderRegistry {
    private var providers: [AgentProviderID: any AgentProviding] = [:]

    public init(providers: [any AgentProviding] = []) {
        for provider in providers {
            self.providers[provider.id] = provider
        }
    }

    public func register(_ provider: any AgentProviding) {
        providers[provider.id] = provider
    }

    public func unregister(_ providerID: AgentProviderID) {
        providers.removeValue(forKey: providerID)
    }

    public func prepareSession(_ request: AgentSessionRequest) async throws -> AgentSession {
        try await provider(request.target.providerID).prepareSession(request)
    }

    public func startRun(_ request: AgentRunRequest) async throws -> AgentRunHandle {
        try await provider(request.target.providerID).startRun(request)
    }

    public func steer(
        providerID: AgentProviderID,
        runID: UUID,
        message: String
    ) async throws {
        try await provider(providerID).steer(runID: runID, message: message)
    }

    public func interrupt(providerID: AgentProviderID, runID: UUID) async throws {
        try await provider(providerID).interrupt(runID: runID)
    }

    public func resolveInteraction(
        providerID: AgentProviderID,
        runID: UUID,
        interactionID: String,
        resolution: AgentInteractionResolution
    ) async throws {
        try await provider(providerID).resolveInteraction(
            runID: runID,
            interactionID: interactionID,
            resolution: resolution
        )
    }

    public func runUtility(_ request: AgentUtilityRequest) async throws -> AgentUtilityResult {
        try await provider(request.target.providerID).runUtility(request)
    }

    public func shutdown() async {
        for provider in providers.values {
            await provider.shutdown()
        }
    }

    private func provider(_ id: AgentProviderID) throws -> any AgentProviding {
        guard let provider = providers[id] else {
            throw AgentProviderError.unsupportedProvider(id)
        }
        return provider
    }
}
