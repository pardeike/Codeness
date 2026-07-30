import Foundation

public enum ClaudeExecutableInspector {
    public static func models(
        executableURL: URL,
        environment: [String: String] = CodexExecutableLocator.processEnvironment()
    ) throws -> [AgentModelDescriptor] {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        var environment = environment
        environment["CLAUDE_CODE_ENTRYPOINT"] = "cli"

        process.executableURL = executableURL
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        process.arguments = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--safe-mode",
            "--permission-mode", "dontAsk",
            "--tools", "",
            "--no-session-persistence"
        ]

        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()

        let requestID = "codeness-model-catalog"
        var request = try JSONValue.object([
            "type": .string("control_request"),
            "request_id": .string(requestID),
            "request": .object([
                "subtype": .string("initialize"),
                "supportedDialogKinds": .array([])
            ])
        ]).encodedData()
        request.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: request)
        try input.fileHandleForWriting.close()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let messages = String(decoding: outputData, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            }
        let response = messages.first { message in
            message["type"]?.stringValue == "control_response"
                && message["response"]?["request_id"]?.stringValue == requestID
        }
        let models = response?["response"]?["response"]?["models"]?.arrayValue?
            .compactMap(modelDescriptor) ?? []
        let detail = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let termination = SubprocessTermination(process: process)
        guard termination.succeeded else {
            throw AgentProviderError.processExited(
                provider: .claude,
                termination: termination,
                detail: detail.isEmpty
                    ? "Codeness could not discover its model catalog."
                    : detail
            )
        }
        guard !models.isEmpty else {
            throw AgentProviderError.invalidResponse(
                detail.isEmpty
                    ? "Claude did not return a model catalog"
                    : "Claude model discovery failed: \(detail)"
            )
        }
        return models
    }

    private static func modelDescriptor(
        _ value: JSONValue
    ) -> AgentModelDescriptor? {
        guard let id = value["value"]?.stringValue,
              let displayName = value["displayName"]?.stringValue else {
            return nil
        }
        let efforts = value["supportedEffortLevels"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        let defaultEffort: String? = if efforts.contains("high") {
            "high"
        } else {
            efforts.first
        }
        var details = [value["description"]?.stringValue]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if let resolvedModel = value["resolvedModel"]?.stringValue,
           resolvedModel != id {
            details.append("Resolves to \(resolvedModel).")
        }
        return AgentModelDescriptor(
            id: id,
            displayName: displayName,
            description: details.joined(separator: " "),
            supportedEfforts: efforts,
            defaultEffort: defaultEffort,
            supportsPlanMode: true,
            supportsFastMode: value["supportsFastMode"]?.boolValue ?? false,
            isAlias: true
        )
    }
}
