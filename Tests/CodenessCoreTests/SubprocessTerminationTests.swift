import Darwin
import Foundation
import Testing
@testable import CodenessCore

struct SubprocessTerminationTests {
    @Test
    func translatesSignalsWithoutConfusingThemWithExitCodes() {
        let terminated = SubprocessTermination(
            reason: .uncaughtSignal,
            status: SIGTERM
        )
        let killed = SubprocessTermination(
            reason: .uncaughtSignal,
            status: SIGKILL
        )
        let crashed = SubprocessTermination(
            reason: .uncaughtSignal,
            status: SIGSEGV
        )
        let exitCode = SubprocessTermination(reason: .exit, status: SIGTERM)

        #expect(
            terminated.userFacingDescription(subject: "Codex App Server")
                == "Codex App Server was stopped."
        )
        #expect(
            killed.userFacingDescription(subject: "Claude")
                == "Claude was forcibly stopped."
        )
        #expect(
            crashed.userFacingDescription(subject: "Claude")
                == "Claude crashed."
        )
        #expect(
            exitCode.userFacingDescription(subject: "Codex App Server")
                == "Codex App Server stopped unexpectedly."
        )
        #expect(
            terminated.diagnosticDescription(subject: "Codex App Server")
                == "Codex App Server was terminated by signal 15 (SIGTERM)."
        )
    }

    @Test
    func providerAndAppServerErrorsUseFriendlyTerminationDescriptions() {
        let termination = SubprocessTermination(
            reason: .uncaughtSignal,
            status: SIGTERM
        )
        let providerError = AgentProviderError.processExited(
            provider: .claude,
            termination: termination,
            detail: ""
        )
        let appServerError = AppServerClientError.processExited(termination)

        #expect(providerError.localizedDescription == "Claude was stopped.")
        #expect(
            appServerError.localizedDescription
                == "Codex App Server was stopped."
        )
        #expect(!providerError.localizedDescription.contains("15"))
        #expect(!appServerError.localizedDescription.contains("15"))
    }

    @Test
    func executableVerificationAndDiscoveryTranslateSignalTermination() async throws {
        let fixture = try TerminatingExecutableFixture()
        defer { fixture.remove() }
        let descriptor = AgentProviderDescriptor(
            id: .claude,
            displayName: "Claude",
            executableName: "claude"
        )

        var codexMessage: String?
        var agentMessage: String?
        var discoveryMessage: String?
        await OwnedSubprocessSupervisorTestLease.withLease {
            do {
                _ = try await CodexExecutableLocator.verify(fixture.executableURL)
            } catch {
                codexMessage = error.localizedDescription
            }

            do {
                _ = try await AgentExecutableLocator.verify(
                    fixture.executableURL,
                    descriptor: descriptor
                )
            } catch {
                agentMessage = error.localizedDescription
            }

            do {
                _ = try await ClaudeExecutableInspector.models(
                    executableURL: fixture.executableURL
                )
            } catch {
                discoveryMessage = error.localizedDescription
            }
        }

        #expect(
            codexMessage
                == "Codex was stopped while Codeness was verifying it."
        )
        #expect(
            agentMessage
                == "Claude was stopped while Codeness was verifying it."
        )
        #expect(
            discoveryMessage
                == "Claude was stopped. Codeness could not discover its model catalog."
        )
        #expect(codexMessage?.contains("15") == false)
        #expect(agentMessage?.contains("15") == false)
        #expect(discoveryMessage?.contains("15") == false)
    }
}

private struct TerminatingExecutableFixture {
    let directory: URL
    let executableURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codeness-terminating-executable-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        executableURL = directory.appendingPathComponent("terminating-provider")
        try Data(
            """
            #!/bin/sh
            kill -TERM $$
            """.utf8
        ).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
