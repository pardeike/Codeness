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
}
