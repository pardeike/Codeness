import Foundation
import Testing
@testable import CodenessCore

struct CodexExecutableLocatorTests {
    @Test
    func explicitMissingPathDoesNotFallBackToDiscoveredCodex() {
        let path = "/tmp/codeness-missing-codex-\(UUID().uuidString)"

        #expect(throws: CodexExecutableError.self) {
            _ = try CodexExecutableLocator.resolve(configuredPath: path)
        }
    }

    @Test
    func explicitExecutablePathIsReturnedAsConfigured() throws {
        let resolved = try CodexExecutableLocator.resolve(configuredPath: "/bin/sh")

        #expect(resolved.path == "/bin/sh")
    }
}
