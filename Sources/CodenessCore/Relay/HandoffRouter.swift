import CryptoKit
import Foundation

public struct HTTPResult: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

public struct URLSessionHTTPTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> HTTPResult {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HandoffRouterError.invalidHTTPResponse
        }
        return HTTPResult(data: data, statusCode: httpResponse.statusCode)
    }
}

public protocol APIKeyLoading: Sendable {
    func apiKey(file: String, name: String) async throws -> String
}

public struct JSONAPIKeyLoader: APIKeyLoading {
    public init() {}

    public func apiKey(file: String, name: String) async throws -> String {
        let path = NSString(string: file).expandingTildeInPath
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw HandoffRouterError.apiKeyFile(error.localizedDescription)
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let key = value[name]?.stringValue, !key.isEmpty else {
            throw HandoffRouterError.apiKeyMissing(name: name, path: path)
        }
        return key
    }
}

public protocol HandoffConfigurationValidating: Sendable {
    func validateLocal(_ settings: RelaySettings) async throws
    func testRemote(_ settings: RelaySettings) async throws
}

public enum HandoffConfigurationError: LocalizedError, Sendable, Equatable {
    case missingAPIKeyFile
    case missingAPIKeyName
    case missingModel

    public var errorDescription: String? {
        switch self {
        case .missingAPIKeyFile:
            "Choose the JSON file containing the handoff API key."
        case .missingAPIKeyName:
            "Choose the JSON property containing the handoff API key."
        case .missingModel:
            "Choose a handoff model."
        }
    }
}

public actor HandoffConfigurationValidator: HandoffConfigurationValidating {
    private static let modelsURL = URL(string: "https://api.openai.com/v1/models")!

    private let transport: any HTTPTransport
    private let keyLoader: any APIKeyLoading

    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        keyLoader: any APIKeyLoading = JSONAPIKeyLoader()
    ) {
        self.transport = transport
        self.keyLoader = keyLoader
    }

    public func validateLocal(_ settings: RelaySettings) async throws {
        let file = settings.apiKeyFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = settings.apiKeyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.selection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !file.isEmpty else { throw HandoffConfigurationError.missingAPIKeyFile }
        guard !name.isEmpty else { throw HandoffConfigurationError.missingAPIKeyName }
        guard !model.isEmpty else { throw HandoffConfigurationError.missingModel }
        _ = try await keyLoader.apiKey(file: file, name: name)
    }

    public func testRemote(_ settings: RelaySettings) async throws {
        try await validateLocal(settings)
        let key = try await keyLoader.apiKey(
            file: settings.apiKeyFile.trimmingCharacters(in: .whitespacesAndNewlines),
            name: settings.apiKeyName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let model = settings.selection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: Self.modelsURL.appending(path: model))
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let result = try await transport.send(request)
        guard (200..<300).contains(result.statusCode) else {
            let response = try? JSONDecoder().decode(JSONValue.self, from: result.data)
            let rawDetail = String(decoding: result.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = response?["error"]?["message"]?.stringValue
                ?? (rawDetail.isEmpty ? "No response body" : rawDetail)
            throw HandoffRouterError.httpStatus(result.statusCode, detail)
        }
    }
}

private enum WorkSummaryPrompt {
    static let cacheVersion = "compact-markdown-v1"
    static let system = """
    Write the “Work so far” section of a software-workflow dashboard. Use only the supplied goal and handoffs. Reconcile older statements with later handoffs and report the net current state instead of retelling the chronology. Do not invent repository facts.

    The summary string must contain compact Markdown only:
    - Use these level-three headings when applicable, in this order: `### Completed`, `### Current state`, `### Remaining`.
    - Put one to four short bullet points under each heading.
    - Never return prose paragraphs or a single wall of text.
    - Keep the entire summary at or below 120 words and each bullet at or below 20 words.
    - Prefer direct, terse wording. Omit introductions, repeated goal text, and superseded implementation details.
    - Omit `Remaining` when the handoffs contain no unfinished work or material risk.
    - Do not add a separate “Work so far” title.
    """
}

public struct WorkSummaryHandoff: Sendable, Equatable {
    public let runID: UUID
    public let sequence: Int
    public let kind: RunKind
    public let label: String
    public let disposition: SourceDisposition
    public let text: String

    public init(
        runID: UUID,
        sequence: Int,
        kind: RunKind,
        label: String,
        disposition: SourceDisposition,
        text: String
    ) {
        self.runID = runID
        self.sequence = sequence
        self.kind = kind
        self.label = label
        self.disposition = disposition
        self.text = text
    }
}

public struct WorkSummaryContext: Sendable, Equatable {
    public let goal: String
    public let handoffs: [WorkSummaryHandoff]

    public init(goal: String, handoffs: [WorkSummaryHandoff]) {
        self.goal = goal
        self.handoffs = handoffs
    }

    public var sourceSignature: String {
        let fields = [WorkSummaryPrompt.cacheVersion, goal] + handoffs.flatMap { handoff in
            [
                handoff.runID.uuidString,
                String(handoff.sequence),
                handoff.kind.rawValue,
                handoff.label,
                handoff.disposition.rawValue,
                handoff.text
            ]
        }
        let source = fields
            .map { "\(Data($0.utf8).count):\($0)" }
            .joined(separator: "|")
        let hexadecimal = Array("0123456789abcdef".utf8)
        let bytes = SHA256.hash(data: Data(source.utf8)).flatMap { byte in
            [
                hexadecimal[Int(byte >> 4)],
                hexadecimal[Int(byte & 0x0F)]
            ]
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public protocol HandoffRouting: Sendable {
    func route(_ context: HandoffContext, settings: RelaySettings) async throws -> HandoffEnvelope
    func summarizeWork(_ context: WorkSummaryContext, settings: RelaySettings) async throws -> String
}

public extension HandoffRouting {
    func summarizeWork(_ context: WorkSummaryContext, settings: RelaySettings) async throws -> String {
        _ = context
        _ = settings
        throw HandoffRouterError.workSummaryUnsupported
    }
}

public enum HandoffRouterError: LocalizedError, Sendable, Equatable {
    case apiKeyFile(String)
    case apiKeyMissing(name: String, path: String)
    case invalidHTTPResponse
    case httpStatus(Int, String)
    case refusal(String)
    case missingOutput
    case invalidEnvelope(String)
    case invalidWorkSummary(String)
    case workSummaryUnsupported

    public var errorDescription: String? {
        switch self {
        case .apiKeyFile(let detail): "The relay API-key file could not be read: \(detail)"
        case .apiKeyMissing(let name, let path): "The relay API-key file \(path) has no non-empty \(name) value."
        case .invalidHTTPResponse: "The relay returned a non-HTTP response."
        case .httpStatus(let status, let detail): "The relay returned HTTP \(status): \(detail)"
        case .refusal(let detail): "The relay refused the handoff: \(detail)"
        case .missingOutput: "The relay response contained no structured output."
        case .invalidEnvelope(let detail): "The relay returned an invalid handoff: \(detail)"
        case .invalidWorkSummary(let detail): "The relay returned an invalid work summary: \(detail)"
        case .workSummaryUnsupported: "The configured handoff router cannot generate a work summary."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .httpStatus(let status, _): status == 429 || status >= 500
        case .invalidHTTPResponse, .missingOutput, .invalidEnvelope, .invalidWorkSummary: true
        default: false
        }
    }
}

public actor HandoffRouter: HandoffRouting {
    private static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!

    private let transport: any HTTPTransport
    private let keyLoader: any APIKeyLoading

    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        keyLoader: any APIKeyLoading = JSONAPIKeyLoader()
    ) {
        self.transport = transport
        self.keyLoader = keyLoader
    }

    public func route(_ context: HandoffContext, settings: RelaySettings) async throws -> HandoffEnvelope {
        let key = try await keyLoader.apiKey(file: settings.apiKeyFile, name: settings.apiKeyName)
        let request = try Self.makeRequest(context: context, settings: settings, key: key)
        var lastError: (any Error)?

        for attempt in 0..<3 {
            do {
                let result = try await transport.send(request)
                return try Self.decode(result, for: context.runKind)
            } catch {
                lastError = error
                let retryable = (error as? HandoffRouterError)?.isRetryable == true || error is URLError
                guard retryable, attempt < 2 else { throw error }
                try await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
            }
        }
        throw lastError ?? HandoffRouterError.missingOutput
    }

    public func summarizeWork(
        _ context: WorkSummaryContext,
        settings: RelaySettings
    ) async throws -> String {
        let key = try await keyLoader.apiKey(file: settings.apiKeyFile, name: settings.apiKeyName)
        let request = try Self.makeWorkSummaryRequest(
            context: context,
            settings: settings,
            key: key
        )
        var lastError: (any Error)?

        for attempt in 0..<3 {
            do {
                let result = try await transport.send(request)
                return try Self.decodeWorkSummary(result)
            } catch {
                lastError = error
                let retryable = (error as? HandoffRouterError)?.isRetryable == true
                    || error is URLError
                guard retryable, attempt < 2 else { throw error }
                try await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
            }
        }
        throw lastError ?? HandoffRouterError.missingOutput
    }

    public static func makeRequest(context: HandoffContext, settings: RelaySettings, key: String) throws -> URLRequest {
        let validDispositions = SourceDisposition.validValues(for: context.runKind)
        let schema: JSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([
                .string("handoffText"),
                .string("sourceDisposition"),
                .string("runLabel")
            ]),
            "properties": .object([
                "handoffText": .object([
                    "type": .string("string"),
                    "minLength": .integer(1)
                ]),
                "sourceDisposition": .object([
                    "type": .string("string"),
                    "enum": .array(validDispositions.map { .string($0.rawValue) })
                ]),
                "runLabel": .object([
                    "type": .string("string"),
                    "minLength": .integer(1),
                    "maxLength": .integer(48)
                ])
            ])
        ])

        let body = JSONValue.object([
            "model": .string(settings.selection.model),
            "store": .bool(false),
            "reasoning": .object(["effort": .string(settings.selection.effort)]),
            "input": .array([
                .object([
                    "role": .string("system"),
                    "content": .array([.object([
                        "type": .string("input_text"),
                        "text": .string(RelayPromptBuilder.systemPrompt(for: context))
                    ])])
                ]),
                .object([
                    "role": .string("user"),
                    "content": .array([.object([
                        "type": .string("input_text"),
                        "text": .string(RelayPromptBuilder.userPrompt(for: context))
                    ])])
                ])
            ]),
            "text": .object([
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string("codeness_handoff"),
                    "strict": .bool(true),
                    "schema": schema
                ])
            ])
        ])

        var request = URLRequest(url: responsesURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.encodedData()
        request.timeoutInterval = 60
        return request
    }

    public static func makeWorkSummaryRequest(
        context: WorkSummaryContext,
        settings: RelaySettings,
        key: String
    ) throws -> URLRequest {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string("summary")]),
            "properties": .object([
                "summary": .object([
                    "type": .string("string"),
                    "minLength": .integer(1)
                ])
            ])
        ])
        let handoffs = context.handoffs.map { handoff in
            """
            ### \(handoff.sequence). \(handoff.kind.displayName) — \(handoff.label)
            Disposition: \(handoff.disposition.displayName)

            \(handoff.text)
            """
        }
        let userPrompt = """
        GOAL

        \(context.goal)

        HANDOFFS IN CHRONOLOGICAL ORDER

        \(handoffs.joined(separator: "\n\n"))
        """
        let body = JSONValue.object([
            "model": .string(settings.selection.model),
            "store": .bool(false),
            "reasoning": .object(["effort": .string(settings.selection.effort)]),
            "input": .array([
                .object([
                    "role": .string("system"),
                    "content": .array([.object([
                        "type": .string("input_text"),
                        "text": .string(WorkSummaryPrompt.system)
                    ])])
                ]),
                .object([
                    "role": .string("user"),
                    "content": .array([.object([
                        "type": .string("input_text"),
                        "text": .string(userPrompt)
                    ])])
                ])
            ]),
            "text": .object([
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string("codeness_work_summary"),
                    "strict": .bool(true),
                    "schema": schema
                ])
            ])
        ])

        var request = URLRequest(url: responsesURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.encodedData()
        request.timeoutInterval = 60
        return request
    }

    public static func decode(_ result: HTTPResult, for runKind: RunKind) throws -> HandoffEnvelope {
        let text = try outputText(from: result)
        do {
            let envelope = try JSONDecoder().decode(HandoffEnvelope.self, from: Data(text.utf8))
            guard SourceDisposition.validValues(for: runKind).contains(envelope.sourceDisposition) else {
                throw HandoffRouterError.invalidEnvelope(
                    "sourceDisposition \(envelope.sourceDisposition.rawValue) is not valid after \(runKind.displayName)."
                )
            }
            guard !envelope.handoffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HandoffRouterError.invalidEnvelope("handoffText must contain information for the next session.")
            }
            let label = envelope.runLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let genericLabels = ["implement", "implementation", "review", "fix", "fixes", "closeout"]
            guard !label.isEmpty, label.count <= 48, !genericLabels.contains(label.lowercased()) else {
                throw HandoffRouterError.invalidEnvelope(
                    "runLabel must be a concrete label of at most 48 characters, not a generic phase name."
                )
            }
            return HandoffEnvelope(
                handoffText: envelope.handoffText,
                sourceDisposition: envelope.sourceDisposition,
                runLabel: label
            )
        } catch let error as HandoffRouterError {
            throw error
        } catch {
            throw HandoffRouterError.invalidEnvelope(error.localizedDescription)
        }
    }

    public static func decodeWorkSummary(_ result: HTTPResult) throws -> String {
        struct Payload: Decodable {
            let summary: String
        }

        let text = try outputText(from: result)
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(text.utf8))
            let summary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else {
                throw HandoffRouterError.invalidWorkSummary("summary must contain information.")
            }
            return summary
        } catch let error as HandoffRouterError {
            throw error
        } catch {
            throw HandoffRouterError.invalidWorkSummary(error.localizedDescription)
        }
    }

    private static func outputText(from result: HTTPResult) throws -> String {
        guard (200..<300).contains(result.statusCode) else {
            let response = try? JSONDecoder().decode(JSONValue.self, from: result.data)
            let rawDetail = String(decoding: result.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = response?["error"]?["message"]?.stringValue
                ?? (rawDetail.isEmpty ? "No response body" : rawDetail)
            throw HandoffRouterError.httpStatus(result.statusCode, detail)
        }
        let response: JSONValue
        do {
            response = try JSONDecoder().decode(JSONValue.self, from: result.data)
        } catch {
            throw HandoffRouterError.invalidEnvelope(
                "response body is not valid JSON: \(error.localizedDescription)"
            )
        }

        if let refusal = response["output"]?.arrayValue?
            .flatMap({ $0["content"]?.arrayValue ?? [] })
            .first(where: { $0["type"]?.stringValue == "refusal" })?["refusal"]?.stringValue {
            throw HandoffRouterError.refusal(refusal)
        }

        guard let text = response["output"]?.arrayValue?
            .flatMap({ $0["content"]?.arrayValue ?? [] })
            .first(where: { $0["type"]?.stringValue == "output_text" })?["text"]?.stringValue else {
            throw HandoffRouterError.missingOutput
        }
        return text
    }
}
