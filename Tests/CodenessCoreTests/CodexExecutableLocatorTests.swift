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

    @Test
    func executableCandidatesUseMergedLoginShellPathBeforeBaseProcessPath() {
        let environment = CodexExecutableLocator.processEnvironment(
            baseEnvironment: ["PATH": "/app/bin:/usr/bin"],
            loginShellEnvironment: ["PATH": "/login/bin:/usr/bin"]
        )

        let candidates = CodexExecutableLocator.candidatePaths(
            environment: environment
        )

        #expect(candidates.prefix(3) == [
            "/login/bin/codex",
            "/usr/bin/codex",
            "/app/bin/codex"
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func transientLoginShellFailureIsRetriedAndSuccessfulResultIsCached() async throws {
        try await OwnedSubprocessSupervisorTestLease.withLease {
            let fixture = try LoginShellFixture(
                pathComponent: "/retry-only/bin",
                failFirstInvocation: true
            )
            defer { fixture.remove() }
            let loader = LoginShellEnvironmentLoader()

            let first = try await loader.load(baseEnvironment: fixture.environment)
            #expect(first == nil)
            let second = try await loader.load(baseEnvironment: fixture.environment)
            #expect(second?["PATH"]?.split(separator: ":").first == "/retry-only/bin")
            let cached = try await loader.load(baseEnvironment: fixture.environment)
            #expect(cached == second)
            #expect(try fixture.invocationCount() == 2)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func interactiveZshrcPathIsCapturedAfterProfileStdoutContamination() async throws {
        try await OwnedSubprocessSupervisorTestLease.withLease {
            let fixture = try LoginShellFixture(
                pathComponent: "/zshrc-only/bin",
                failFirstInvocation: false,
                wrapsZsh: false
            )
            defer { fixture.remove() }
            let loader = LoginShellEnvironmentLoader()

            let environment = try await loader.load(baseEnvironment: fixture.environment)

            #expect(environment?["PATH"]?.split(separator: ":").first == "/zshrc-only/bin")
            #expect(environment?["CODENESS_ZSHRC_ONLY"] == "loaded")
        }
    }
}

private struct LoginShellFixture {
    let directoryURL: URL
    let shellURL: URL
    let invocationURL: URL
    let wrapsZsh: Bool

    init(
        pathComponent: String,
        failFirstInvocation: Bool,
        wrapsZsh: Bool = true
    ) throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codeness-login-shell-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        shellURL = directoryURL.appendingPathComponent("shell")
        invocationURL = directoryURL.appendingPathComponent("invocations")
        self.wrapsZsh = wrapsZsh
        let zshrc = """
        print 'intentional profile stdout contamination'
        export CODENESS_ZSHRC_ONLY=loaded
        export PATH="\(pathComponent):$PATH"
        """
        try Data(zshrc.utf8).write(
            to: directoryURL.appendingPathComponent(".zshrc"),
            options: .atomic
        )
        if wrapsZsh {
            let failure = failFirstInvocation
                ? "if [ \"$count\" -eq 1 ]; then exit 23; fi"
                : ""
            let wrapper = """
            #!/bin/sh
            count=0
            if [ -f "\(invocationURL.path)" ]; then count=$(/bin/cat "\(invocationURL.path)"); fi
            count=$((count + 1))
            /bin/echo "$count" > "\(invocationURL.path)"
            \(failure)
            exec /bin/zsh "$@"
            """
            try Data(wrapper.utf8).write(to: shellURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: shellURL.path
            )
        }
    }

    var environment: [String: String] {
        [
            "HOME": directoryURL.path,
            "ZDOTDIR": directoryURL.path,
            "PATH": "/usr/bin:/bin",
            "SHELL": wrapsZsh ? shellURL.path : "/bin/zsh"
        ]
    }

    func invocationCount() throws -> Int {
        Int(try String(contentsOf: invocationURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
