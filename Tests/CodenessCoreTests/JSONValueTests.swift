import Foundation
import Testing
@testable import CodenessCore

struct JSONValueTests {
    @Test
    func roundTripsMixedJSONWithoutLosingIntegers() throws {
        let source: JSONValue = .object([
            "id": .integer(9_007_199_254_740_991),
            "enabled": .bool(true),
            "nested": .array([.string("value"), .null, .number(1.25)])
        ])

        let data = try source.encodedData()
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded == source)
        #expect(decoded["id"]?.integerValue == 9_007_199_254_740_991)
    }

    @Test
    func prettyPrintedOutputIsStableAndSorted() {
        let value: JSONValue = .object(["z": .integer(1), "a": .string("first")])
        let output = value.encodedString(prettyPrinted: true)

        #expect(output.firstIndex(of: "a")! < output.firstIndex(of: "z")!)
    }

    @Test
    func integerValueRejectsFractionalNonFiniteAndOutOfRangeNumbers() {
        #expect(JSONValue.number(42).integerValue == 42)
        #expect(JSONValue.number(1.5).integerValue == nil)
        #expect(JSONValue.number(.infinity).integerValue == nil)
        #expect(JSONValue.number(.nan).integerValue == nil)
        #expect(JSONValue.number(Double(Int64.max)).integerValue == nil)
        #expect(JSONValue.number(-Double(Int64.max) * 2).integerValue == nil)
    }

    @Test
    func tokenUsageArithmeticSaturatesAndNormalizesMutatedNegativeCounters() {
        let nearMaximum = RunTokenUsage(
            totalTokens: .max,
            inputTokens: .max - 1,
            cachedInputTokens: .max,
            cacheWriteInputTokens: .max,
            outputTokens: .max,
            reasoningOutputTokens: .max
        )
        let increment = RunTokenUsage(
            totalTokens: 1,
            inputTokens: 2,
            cachedInputTokens: 1,
            cacheWriteInputTokens: 1,
            outputTokens: 1,
            reasoningOutputTokens: 1
        )
        let saturated = nearMaximum.adding(increment)
        #expect(saturated.totalTokens == .max)
        #expect(saturated.inputTokens == .max)
        #expect(saturated.cachedInputTokens == .max)
        #expect(saturated.cacheWriteInputTokens == .max)
        #expect(saturated.outputTokens == .max)
        #expect(saturated.reasoningOutputTokens == .max)

        var malformed = RunTokenUsage(
            totalTokens: 10,
            inputTokens: 10,
            outputTokens: 10
        )
        malformed.totalTokens = .min
        malformed.inputTokens = .min
        malformed.outputTokens = .min
        let normalized = malformed.adding(.zero)
        #expect(normalized.totalTokens == 0)
        #expect(normalized.inputTokens == 0)
        #expect(normalized.outputTokens == 0)
        #expect(RunTokenUsage.zero.subtracting(malformed) == .zero)
    }
}
