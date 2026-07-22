import Foundation

public struct TranscriptUpdate: Sendable, Equatable {
    public let text: String
    public let itemID: String?
    public let finalOutput: String?
    public let section: TranscriptSectionKind?

    public init(
        text: String = "",
        itemID: String? = nil,
        finalOutput: String? = nil,
        section: TranscriptSectionKind? = nil
    ) {
        self.text = text
        self.itemID = itemID
        self.finalOutput = finalOutput
        self.section = section
    }
}

public enum TranscriptSectionKind: String, Sendable, Equatable {
    case prompt
    case reasoning
    case action
    case result
    case diagnostic
}

public enum TranscriptFormatter {
    public static func update(method: String, params: JSONValue, itemsWithDeltas: Set<String>) -> TranscriptUpdate {
        let itemID = params["itemId"]?.stringValue ?? params["item"]?["id"]?.stringValue

        switch method {
        case "item/agentMessage/delta":
            return .init(text: params["delta"]?.stringValue ?? "", itemID: itemID)
        case "item/reasoning/summaryTextDelta":
            let isFirstDelta = itemID.map { !itemsWithDeltas.contains($0) } ?? true
            return .init(
                text: (isFirstDelta ? "\n\nReasoning\n" : "")
                    + (params["delta"]?.stringValue ?? ""),
                itemID: itemID,
                section: isFirstDelta ? .reasoning : nil
            )
        case "item/reasoning/summaryPartAdded":
            return .init(itemID: itemID)
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            // Successful tool output is intentionally omitted from the reasoning-first
            // transcript. A concise excerpt is emitted on completion when the tool fails.
            return .init(itemID: itemID)
        case "item/plan/delta":
            let isFirstDelta = itemID.map { !itemsWithDeltas.contains($0) } ?? true
            return .init(
                text: (isFirstDelta ? "\n\nPlan\n" : "")
                    + (params["delta"]?.stringValue ?? ""),
                itemID: itemID,
                section: isFirstDelta ? .reasoning : nil
            )
        case "turn/plan/updated":
            let explanation = params["explanation"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let steps = params["plan"]?.arrayValue?.compactMap { step -> String? in
                guard let text = step["step"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                let state = switch step["status"]?.stringValue {
                case "completed": "done"
                case "inProgress", "in_progress": "active"
                default: "pending"
                }
                return "[\(state)] \(text)"
            } ?? []
            guard !explanation.isEmpty || !steps.isEmpty else { return .init() }
            let content = ([explanation] + steps)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return .init(text: "\n\nPlan\n\(content)\n", section: .reasoning)
        case "error":
            let message = params["error"]?["message"]?.stringValue ?? params["error"]?.encodedString() ?? "Unknown Codex error"
            return .init(text: "\n\nError: \(message)\n", section: .diagnostic)
        case "thread/compacted":
            return .init(text: "\n\n[Context compacted]\n", section: .diagnostic)
        case "item/started":
            return startedItem(params["item"] ?? .null)
        case "item/completed":
            return completedItem(params["item"] ?? .null, itemsWithDeltas: itemsWithDeltas)
        default:
            return .init()
        }
    }

    public static func finalOutput(from turn: JSONValue) -> String? {
        guard let items = turn["items"]?.arrayValue else { return nil }
        let agentMessages = items.compactMap { item -> (String, String?)? in
            guard item["type"]?.stringValue == "agentMessage",
                  let text = item["text"]?.stringValue else { return nil }
            return (text, item["phase"]?.stringValue)
        }
        return agentMessages.last(where: { $0.1 == "final_answer" })?.0 ?? agentMessages.last?.0
    }

    private static func startedItem(_ item: JSONValue) -> TranscriptUpdate {
        let itemID = item["id"]?.stringValue
        switch item["type"]?.stringValue {
        case "userMessage":
            let text = item["content"]?.arrayValue?
                .compactMap { $0["text"]?.stringValue }
                .joined(separator: "\n") ?? ""
            return .init(
                text: text.isEmpty ? "" : "Prompt\n\(text)\n\n",
                itemID: itemID,
                section: .prompt
            )
        case "commandExecution":
            let command = item["command"]?.stringValue ?? "command"
            return .init(
                text: "\n› \(compactCommand(command))\n",
                itemID: itemID,
                section: .action
            )
        case "fileChange":
            return .init(text: "\n› Editing files\n", itemID: itemID, section: .action)
        case "mcpToolCall", "dynamicToolCall":
            // MCP-heavy passes can contain dozens of successful read calls. They add
            // little supervision value, so only failures are rendered on completion.
            return .init(itemID: itemID)
        case "webSearch":
            let query = item["query"]?.stringValue ?? ""
            return .init(
                text: "\n› Web search: \(singleLine(query, limit: 160))\n",
                itemID: itemID,
                section: .action
            )
        case "reasoning":
            // Current App Server runs often emit empty reasoning items. Wait for the
            // first summary delta before adding a heading so the transcript does not
            // accumulate dozens of blank "Reasoning" sections.
            return .init(itemID: itemID)
        case "agentMessage":
            let isResult = item["phase"]?.stringValue == "final_answer"
            return .init(
                text: "\n\n\(isResult ? "Result" : "Reasoning")\n",
                itemID: itemID,
                section: isResult ? .result : .reasoning
            )
        case "contextCompaction":
            return .init(text: "\n\n[Context compacted]\n", itemID: itemID, section: .diagnostic)
        default:
            return .init(itemID: itemID)
        }
    }

    private static func completedItem(_ item: JSONValue, itemsWithDeltas: Set<String>) -> TranscriptUpdate {
        let itemID = item["id"]?.stringValue
        switch item["type"]?.stringValue {
        case "agentMessage":
            let text = item["text"]?.stringValue ?? ""
            let missingStream = itemID.map { !itemsWithDeltas.contains($0) } ?? true
            let phase = item["phase"]?.stringValue
            return .init(
                text: missingStream && !text.isEmpty ? text + "\n" : "\n",
                itemID: itemID,
                finalOutput: phase == "final_answer" ? text : nil,
                section: missingStream ? (phase == "final_answer" ? .result : .reasoning) : nil
            )
        case "commandExecution":
            let status = item["status"]?.stringValue ?? "completed"
            let exitCode = item["exitCode"]?.integerValue
            let output = item["aggregatedOutput"]?.stringValue ?? ""
            guard toolFailed(status: status, exitCode: exitCode, error: itemErrorText(item)) else {
                return .init(itemID: itemID)
            }
            let exitDescription = exitCode.map { ", exit \($0)" } ?? ""
            let detail = failureExcerpt(output.isEmpty ? itemErrorText(item) ?? "" : output)
            return .init(
                text: "\n⚠ Command \(status)\(exitDescription)\(detail.isEmpty ? "" : "\n\(detail)")\n",
                itemID: itemID,
                section: .diagnostic
            )
        case "fileChange":
            let status = item["status"]?.stringValue ?? "completed"
            guard toolFailed(status: status, exitCode: nil, error: itemErrorText(item)) else {
                return .init(itemID: itemID)
            }
            let error = itemFailureText(item)
            let detail = failureExcerpt(error ?? "")
            return .init(
                text: "\n⚠ File changes \(status)\(detail.isEmpty ? "" : ": \(detail)")\n",
                itemID: itemID,
                section: .diagnostic
            )
        case "mcpToolCall":
            let status = item["status"]?.stringValue ?? "completed"
            guard toolFailed(status: status, exitCode: nil, error: itemErrorText(item)) else {
                return .init(itemID: itemID)
            }
            let error = itemFailureText(item)
            let server = item["server"]?.stringValue ?? "MCP"
            let tool = item["tool"]?.stringValue ?? "tool"
            return failedToolUpdate(name: "\(server)/\(tool)", status: status, error: error, itemID: itemID)
        case "dynamicToolCall":
            let status = item["status"]?.stringValue ?? "completed"
            guard toolFailed(status: status, exitCode: nil, error: itemErrorText(item)) else {
                return .init(itemID: itemID)
            }
            let error = itemFailureText(item)
            let tool = item["tool"]?.stringValue ?? "tool"
            return failedToolUpdate(name: tool, status: status, error: error, itemID: itemID)
        default:
            return .init(itemID: itemID)
        }
    }

    private static func failedToolUpdate(
        name: String,
        status: String,
        error: String?,
        itemID: String?
    ) -> TranscriptUpdate {
        let detail = failureExcerpt(error ?? "")
        return .init(
            text: "\n⚠ \(name) \(status)\(detail.isEmpty ? "" : "\n\(detail)")\n",
            itemID: itemID,
            section: .diagnostic
        )
    }

    private static func toolFailed(status: String, exitCode: Int64?, error: String?) -> Bool {
        if let exitCode, exitCode != 0 { return true }
        if error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        return ["failed", "cancelled", "interrupted", "declined", "rejected"]
            .contains(status.lowercased())
    }

    private static func itemErrorText(_ item: JSONValue) -> String? {
        guard let error = item["error"], error != .null else { return nil }
        return error.stringValue ?? error["message"]?.stringValue ?? error.encodedString()
    }

    private static func itemFailureText(_ item: JSONValue) -> String? {
        if let error = itemErrorText(item) { return error }
        let resultText = item["result"]?["content"]?.arrayValue?
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return resultText?.isEmpty == false ? resultText : nil
    }

    private static func compactCommand(_ command: String) -> String {
        var value = singleLine(command, limit: 600)
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "zsh -lc ", "bash -lc "] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "\"" || first == "'"),
           last == first {
            value.removeFirst()
            value.removeLast()
        }
        return singleLine(value, limit: 180)
    }

    private static func singleLine(_ text: String, limit: Int) -> String {
        let flattened = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(max(1, limit - 1))) + "…"
    }

    private static func failureExcerpt(_ output: String) -> String {
        let withoutANSI = output.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        let clean = withoutANSI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
        var excerpt = lines.suffix(18).joined(separator: "\n")
        if excerpt.count > 2_400 {
            excerpt = "…" + String(excerpt.suffix(2_399))
        } else if lines.count > 18 {
            excerpt = "…\n" + excerpt
        }
        return excerpt
    }
}
