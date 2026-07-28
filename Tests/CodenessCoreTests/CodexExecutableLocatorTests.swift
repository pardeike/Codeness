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

    @Test
    func providerEnvironmentIncludesLoginShellExportsAndPath() {
        let environment = CodexExecutableLocator.processEnvironment(
            baseEnvironment: [
                "PATH": "/app/bin:/usr/bin",
                "APP_ONLY": "app",
                "SHARED": "app"
            ],
            loginShellEnvironment: [
                "PATH": "/custom/bin:/usr/bin",
                "SHELL_ONLY": "shell",
                "SHARED": "shell",
                "PWD": "/stale/shell/directory"
            ]
        )

        #expect(environment["APP_ONLY"] == "app")
        #expect(environment["SHELL_ONLY"] == "shell")
        #expect(environment["SHARED"] == "app")
        #expect(environment["PWD"] == nil)
        #expect(environment["PATH"]?.split(separator: ":").prefix(3) == [
            "/custom/bin",
            "/usr/bin",
            "/app/bin"
        ])
        #expect(
            environment["PATH"]?.split(separator: ":")
                .filter { $0 == "/usr/bin" }
                .count == 1
        )
    }
}
