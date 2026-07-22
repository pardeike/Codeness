import Foundation
import Testing
@testable import CodenessCore

struct CodexLaunchConfigurationTests {
    @Test
    func defaultsToCodenessShellProfilePolicy() {
        let configuration = CodexLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            environment: [:]
        )

        #expect(configuration.arguments == [
            "-c", "shell_environment_policy.inherit=all",
            "-c", "shell_environment_policy.experimental_use_profile=true",
            "app-server", "--stdio"
        ])
    }

    @Test
    func preservesExplicitArguments() {
        let configuration = CodexLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: ["custom-server", "--fixture"],
            environment: [:]
        )

        #expect(configuration.arguments == ["custom-server", "--fixture"])
    }
}
