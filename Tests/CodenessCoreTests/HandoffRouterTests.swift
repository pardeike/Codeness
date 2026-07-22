import Foundation
import Testing
@testable import CodenessCore

struct HandoffRouterTests {
    @Test
    func buildsStrictStructuredOutputRequest() throws {
        let context = HandoffContext(
            sender: .reviewer,
            recipient: .implementer,
            runKind: .review,
            recipientPurpose: "Fix once and continue",
            source: "Finding in Parser.swift:42."
        )
        let settings = RelaySettings()
        let request = try HandoffRouter.makeRequest(context: context, settings: settings, key: "secret")
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())

        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(body["store"]?.boolValue == false)
        #expect(body["text"]?["format"]?["strict"]?.boolValue == true)
        #expect(body["text"]?["format"]?["schema"]?["additionalProperties"]?.boolValue == false)
        #expect(body["text"]?["format"]?["schema"]?["properties"]?["handoffText"]?["minLength"]?.integerValue == 1)
        #expect(body["text"]?["format"]?["schema"]?["properties"]?["runLabel"]?["maxLength"]?.integerValue == 48)
        #expect(
            body["text"]?["format"]?["schema"]?["properties"]?["sourceDisposition"]?["enum"]?.arrayValue?
                .compactMap(\.stringValue) == ["reviewComplete", "blocked", "failed", "unclear"]
        )
    }

    @Test
    func restrictsStructuredOutputToEachKnownPhase() throws {
        let expectations: [(RunKind, [String])] = [
            (.implementation, ["implementationCheckpoint", "implementationComplete", "blocked", "failed", "unclear"]),
            (.review, ["reviewComplete", "blocked", "failed", "unclear"]),
            (.fix, ["fixComplete", "blocked", "failed", "unclear"])
        ]

        for (runKind, expectedValues) in expectations {
            let context = HandoffContext(
                sender: runKind == .review ? .reviewer : .implementer,
                recipient: runKind == .review ? .implementer : .reviewer,
                runKind: runKind,
                recipientPurpose: "Continue the workflow",
                source: "Completed source output"
            )
            let request = try HandoffRouter.makeRequest(
                context: context,
                settings: RelaySettings(),
                key: "secret"
            )
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            let values = body["text"]?["format"]?["schema"]?["properties"]?["sourceDisposition"]?["enum"]?
                .arrayValue?.compactMap(\.stringValue)

            #expect(values == expectedValues)
        }
    }

    @Test
    func decodesLegacyBaseURLAndDoesNotPersistItAgain() throws {
        let legacyJSON = """
        {
          "baseURL": "https://example.invalid/v1",
          "apiKeyFile": "/tmp/keys.json",
          "apiKeyName": "TEST_KEY",
          "selection": {
            "model": "relay-model",
            "effort": "medium"
          }
        }
        """

        let settings = try JSONDecoder().decode(RelaySettings.self, from: Data(legacyJSON.utf8))
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(settings))

        #expect(settings.apiKeyFile == "/tmp/keys.json")
        #expect(settings.apiKeyName == "TEST_KEY")
        #expect(settings.selection == ModelSelection(model: "relay-model", effort: "medium"))
        #expect(encoded["baseURL"] == nil)
    }

    @Test
    func decodesStructuredEnvelope() throws {
        let envelope = """
        {"handoffText":"Keep Parser.swift:42 unchanged.","sourceDisposition":"reviewComplete","runLabel":"Parser review"}
        """
        let response: JSONValue = .object([
            "output": .array([.object([
                "type": .string("message"),
                "content": .array([.object([
                    "type": .string("output_text"),
                    "text": .string(envelope)
                ])])
            ])])
        ])
        let decoded = try HandoffRouter.decode(
            HTTPResult(data: try response.encodedData(), statusCode: 200),
            for: .review
        )

        #expect(decoded.sourceDisposition == .reviewComplete)
        #expect(decoded.handoffText == "Keep Parser.swift:42 unchanged.")
        #expect(decoded.runLabel == "Parser review")
    }

    @Test
    func rejectsGenericRunLabels() throws {
        let envelope = """
        {"handoffText":"Changed the parser.","sourceDisposition":"implementationCheckpoint","runLabel":"Implement"}
        """
        let response: JSONValue = .object([
            "output": .array([.object([
                "content": .array([.object([
                    "type": .string("output_text"),
                    "text": .string(envelope)
                ])])
            ])])
        ])

        #expect(throws: HandoffRouterError.self) {
            try HandoffRouter.decode(
                HTTPResult(data: try response.encodedData(), statusCode: 200),
                for: .implementation
            )
        }
    }

    @Test
    func rejectsWhitespaceOnlyHandoffs() throws {
        let envelope = """
        {"handoffText":"  \n  ","sourceDisposition":"reviewComplete","runLabel":"Parser review"}
        """
        let response: JSONValue = .object([
            "output": .array([.object([
                "content": .array([.object([
                    "type": .string("output_text"),
                    "text": .string(envelope)
                ])])
            ])])
        ])

        #expect(throws: HandoffRouterError.self) {
            try HandoffRouter.decode(
                HTTPResult(data: try response.encodedData(), statusCode: 200),
                for: .review
            )
        }
    }

    @Test
    func surfacesRefusalsWithoutUsingUnstructuredText() throws {
        let response: JSONValue = .object([
            "output": .array([.object([
                "content": .array([.object([
                    "type": .string("refusal"),
                    "refusal": .string("No relay")
                ])])
            ])])
        ])

        #expect(throws: HandoffRouterError.refusal("No relay")) {
            try HandoffRouter.decode(
                HTTPResult(data: try response.encodedData(), statusCode: 200),
                for: .review
            )
        }
    }

    @Test
    func classifiesPlainTextServerErrorsBeforeDecodingJSON() throws {
        #expect(throws: HandoffRouterError.httpStatus(503, "temporarily unavailable")) {
            try HandoffRouter.decode(
                HTTPResult(
                    data: Data("temporarily unavailable".utf8),
                    statusCode: 503
                ),
                for: .review
            )
        }
    }

    @Test
    func rejectsAValidEnumValueFromTheWrongPhase() throws {
        let envelope = """
        {"handoffText":"Keep all three findings.","sourceDisposition":"implementationCheckpoint","runLabel":"Animation review findings"}
        """
        let response: JSONValue = .object([
            "output": .array([.object([
                "content": .array([.object([
                    "type": .string("output_text"),
                    "text": .string(envelope)
                ])])
            ])])
        ])

        #expect(throws: HandoffRouterError.invalidEnvelope(
            "sourceDisposition implementationCheckpoint is not valid after Review."
        )) {
            try HandoffRouter.decode(
                HTTPResult(data: try response.encodedData(), statusCode: 200),
                for: .review
            )
        }
    }

    @Test
    func retriesPlainTextTransientResponses() async throws {
        let envelope = """
        {"handoffText":"Keep the finding.","sourceDisposition":"reviewComplete","runLabel":"Parser retry"}
        """
        let response: JSONValue = .object([
            "output": .array([.object([
                "content": .array([.object([
                    "type": .string("output_text"),
                    "text": .string(envelope)
                ])])
            ])])
        ])
        let transport = SequencedHTTPTransport(results: [
            HTTPResult(data: Data("busy".utf8), statusCode: 503),
            HTTPResult(data: try response.encodedData(), statusCode: 200)
        ])
        let router = HandoffRouter(transport: transport, keyLoader: StaticAPIKeyLoader())
        let context = HandoffContext(
            sender: .reviewer,
            recipient: .implementer,
            runKind: .review,
            recipientPurpose: "Address the review",
            source: "Finding"
        )

        let routed = try await router.route(context, settings: .init())

        #expect(routed.runLabel == "Parser retry")
        #expect(await transport.callCount == 2)
    }

    @Test
    func retriesAnImpossiblePhaseDispositionWithoutPausingTheWorkflow() async throws {
        let invalidEnvelope = """
        {"handoffText":"Keep all findings.","sourceDisposition":"implementationCheckpoint","runLabel":"Animation review findings"}
        """
        let validEnvelope = """
        {"handoffText":"Keep all findings.","sourceDisposition":"reviewComplete","runLabel":"Animation review findings"}
        """
        let transport = SequencedHTTPTransport(results: [
            try response(containing: invalidEnvelope),
            try response(containing: validEnvelope)
        ])
        let router = HandoffRouter(transport: transport, keyLoader: StaticAPIKeyLoader())
        let context = HandoffContext(
            sender: .reviewer,
            recipient: .implementer,
            runKind: .review,
            recipientPurpose: "Address the review",
            source: "Three review findings"
        )

        let routed = try await router.route(context, settings: .init())

        #expect(routed.sourceDisposition == .reviewComplete)
        #expect(await transport.callCount == 2)
    }

    @Test
    func retriesAMalformedSuccessfulResponse() async throws {
        let validEnvelope = """
        {"handoffText":"Keep the finding.","sourceDisposition":"reviewComplete","runLabel":"Parser review finding"}
        """
        let transport = SequencedHTTPTransport(results: [
            HTTPResult(data: Data("not JSON".utf8), statusCode: 200),
            try response(containing: validEnvelope)
        ])
        let router = HandoffRouter(transport: transport, keyLoader: StaticAPIKeyLoader())
        let context = HandoffContext(
            sender: .reviewer,
            recipient: .implementer,
            runKind: .review,
            recipientPurpose: "Address the review",
            source: "One review finding"
        )

        let routed = try await router.route(context, settings: .init())

        #expect(routed.sourceDisposition == .reviewComplete)
        #expect(await transport.callCount == 2)
    }

    private func response(containing envelope: String) throws -> HTTPResult {
        let response: JSONValue = .object([
            "output": .array([.object([
                "content": .array([.object([
                    "type": .string("output_text"),
                    "text": .string(envelope)
                ])])
            ])])
        ])
        return HTTPResult(data: try response.encodedData(), statusCode: 200)
    }
}

private actor SequencedHTTPTransport: HTTPTransport {
    private var results: [HTTPResult]
    private(set) var callCount = 0

    init(results: [HTTPResult]) {
        self.results = results
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        _ = request
        callCount += 1
        return results.removeFirst()
    }
}

private struct StaticAPIKeyLoader: APIKeyLoading {
    func apiKey(file: String, name: String) async throws -> String {
        _ = file
        _ = name
        return "secret"
    }
}
