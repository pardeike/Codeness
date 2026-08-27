import Testing
@testable import CodenessCore

struct TranscriptFormatterTests {
    @Test
    func extractsFinalAnswerInsteadOfCommentary() {
        let turn: JSONValue = .object([
            "items": .array([
                .object([
                    "type": .string("agentMessage"),
                    "phase": .string("commentary"),
                    "text": .string("Working")
                ]),
                .object([
                    "type": .string("agentMessage"),
                    "phase": .string("final_answer"),
                    "text": .string("Checkpoint complete")
                ])
            ])
        ])

        #expect(TranscriptFormatter.finalOutput(from: turn) == "Checkpoint complete")
    }

    @Test
    func acceptsACompletedPlanAsTheTurnOutput() {
        let planItem: JSONValue = .object([
            "id": .string("plan-1"),
            "type": .string("plan"),
            "text": .string("Fix the disconnected objective, then refresh runtime evidence.")
        ])
        let turn: JSONValue = .object([
            "items": .array([planItem])
        ])
        let completed: JSONValue = .object([
            "item": planItem
        ])

        #expect(
            TranscriptFormatter.finalOutput(from: turn)
                == "Fix the disconnected objective, then refresh runtime evidence."
        )
        let update = TranscriptFormatter.update(
            method: "item/completed",
            params: completed,
            itemsWithDeltas: []
        )
        #expect(update.finalOutput == "Fix the disconnected objective, then refresh runtime evidence.")
        #expect(update.section == .result)
        #expect(update.text.contains("Plan\nFix the disconnected objective"))
    }

    @Test
    func agentMessagesRemainPreferredOverPlanItems() {
        let turn: JSONValue = .object([
            "items": .array([
                .object([
                    "type": .string("plan"),
                    "text": .string("Earlier plan")
                ]),
                .object([
                    "type": .string("agentMessage"),
                    "phase": .string("final_answer"),
                    "text": .string("Final answer")
                ])
            ])
        ])

        #expect(TranscriptFormatter.finalOutput(from: turn) == "Final answer")
    }

    @Test
    func terminalPlanIsPreferredOverEarlierCommentary() {
        let turn: JSONValue = .object([
            "items": .array([
                .object([
                    "type": .string("agentMessage"),
                    "phase": .string("commentary"),
                    "text": .string("I am reviewing the evidence.")
                ]),
                .object([
                    "type": .string("plan"),
                    "text": .string("Repair the objective layout before acceptance.")
                ])
            ])
        ])

        #expect(
            TranscriptFormatter.finalOutput(from: turn)
                == "Repair the objective layout before acceptance."
        )
    }

    @Test
    func rendersOnlyACompactCommandAndSuppressesSuccessfulOutput() {
        let started: JSONValue = .object([
            "item": .object([
                "id": .string("command-1"),
                "type": .string("commandExecution"),
                "command": .string("/bin/zsh -lc \"xcodebuild test && very-long-follow-up\"")
            ])
        ])
        let outputDelta: JSONValue = .object([
            "itemId": .string("command-1"),
            "delta": .string("hundreds of noisy build lines")
        ])
        let completed: JSONValue = .object([
            "item": .object([
                "id": .string("command-1"),
                "type": .string("commandExecution"),
                "status": .string("completed"),
                "exitCode": .integer(0),
                "aggregatedOutput": .string("duplicate")
            ])
        ])

        #expect(TranscriptFormatter.update(method: "item/started", params: started, itemsWithDeltas: []).text.contains("xcodebuild test"))
        let delta = TranscriptFormatter.update(
            method: "item/commandExecution/outputDelta",
            params: outputDelta,
            itemsWithDeltas: []
        )
        #expect(delta.text.isEmpty)
        #expect(delta.itemID == "command-1")
        let finish = TranscriptFormatter.update(
            method: "item/completed",
            params: completed,
            itemsWithDeltas: ["command-1"]
        )
        #expect(finish.text.isEmpty)
    }

    @Test
    func keepsAConciseFailedCommandExcerptWithoutANSIEscapes() {
        let completed: JSONValue = .object([
            "item": .object([
                "id": .string("command-2"),
                "type": .string("commandExecution"),
                "status": .string("failed"),
                "exitCode": .integer(1),
                "aggregatedOutput": .string("\u{001B}[31mERROR\u{001B}[0m apply_patch verification failed\nNo matching context")
            ])
        ])

        let finish = TranscriptFormatter.update(
            method: "item/completed",
            params: completed,
            itemsWithDeltas: []
        )
        #expect(finish.text.contains("⚠ Command failed (exit 1)"))
        #expect(finish.text.contains("  └ ERROR apply_patch verification failed\n    No matching context"))
        #expect(!finish.text.contains("\u{001B}"))
    }

    @Test
    func hidesSuccessfulMCPCallsButShowsFailures() {
        let started: JSONValue = .object([
            "item": .object([
                "id": .string("tool-1"),
                "type": .string("mcpToolCall"),
                "server": .string("decompiler"),
                "tool": .string("resolve_member_id")
            ])
        ])
        let succeeded: JSONValue = .object([
            "item": .object([
                "id": .string("tool-1"),
                "type": .string("mcpToolCall"),
                "status": .string("completed"),
                "error": .null,
                "result": .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string("large successful result")])
                    ])
                ])
            ])
        ])
        let failed: JSONValue = .object([
            "item": .object([
                "id": .string("tool-2"),
                "type": .string("mcpToolCall"),
                "server": .string("decompiler"),
                "tool": .string("resolve_member_id"),
                "status": .string("failed"),
                "error": .null,
                "result": .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string("Member was not found")])
                    ])
                ])
            ])
        ])

        #expect(TranscriptFormatter.update(method: "item/started", params: started, itemsWithDeltas: []).text.isEmpty)
        #expect(TranscriptFormatter.update(method: "item/completed", params: succeeded, itemsWithDeltas: []).text.isEmpty)
        let failure = TranscriptFormatter.update(method: "item/completed", params: failed, itemsWithDeltas: [])
        #expect(failure.text.contains("decompiler/resolve_member_id failed"))
        #expect(failure.text.contains("  └ Member was not found"))
    }

    @Test
    func startsReasoningWithoutAVisibleHeading() {
        let started: JSONValue = .object([
            "item": .object([
                "id": .string("reasoning-1"),
                "type": .string("reasoning")
            ])
        ])
        let partAdded: JSONValue = .object(["itemId": .string("reasoning-1")])
        let firstDelta: JSONValue = .object([
            "itemId": .string("reasoning-1"),
            "delta": .string("Checking the implementation.")
        ])
        let laterDelta: JSONValue = .object([
            "itemId": .string("reasoning-1"),
            "delta": .string(" More detail.")
        ])

        let heading = TranscriptFormatter.update(method: "item/started", params: started, itemsWithDeltas: [])
        let separator = TranscriptFormatter.update(
            method: "item/reasoning/summaryPartAdded",
            params: partAdded,
            itemsWithDeltas: []
        )
        let first = TranscriptFormatter.update(
            method: "item/reasoning/summaryTextDelta",
            params: firstDelta,
            itemsWithDeltas: []
        )
        let later = TranscriptFormatter.update(
            method: "item/reasoning/summaryTextDelta",
            params: laterDelta,
            itemsWithDeltas: ["reasoning-1"]
        )
        #expect(heading.text.isEmpty)
        #expect(separator.text.isEmpty)
        #expect(first.text == "\n\nChecking the implementation.")
        #expect(first.section == .reasoning)
        #expect(later.text == " More detail.")
        #expect(later.section == nil)
    }

    @Test
    func startsAgentMessagesWithoutVisibleReasoningOrResultHeadings() {
        let commentary: JSONValue = .object([
            "item": .object([
                "id": .string("message-1"),
                "type": .string("agentMessage"),
                "phase": .string("commentary")
            ])
        ])
        let finalAnswer: JSONValue = .object([
            "item": .object([
                "id": .string("message-2"),
                "type": .string("agentMessage"),
                "phase": .string("final_answer")
            ])
        ])

        let reasoning = TranscriptFormatter.update(
            method: "item/started",
            params: commentary,
            itemsWithDeltas: []
        )
        let result = TranscriptFormatter.update(
            method: "item/started",
            params: finalAnswer,
            itemsWithDeltas: []
        )

        #expect(reasoning.text == "\n\n")
        #expect(reasoning.section == .reasoning)
        #expect(result.text == "\n\n")
        #expect(result.section == .result)
    }

    @Test
    func rendersStableTurnPlanSnapshots() {
        let params: JSONValue = .object([
            "explanation": .string("Checking the durable workflow first."),
            "plan": .array([
                .object(["step": .string("Inspect recovery"), "status": .string("completed")]),
                .object(["step": .string("Repair persistence"), "status": .string("inProgress")]),
                .object(["step": .string("Run tests"), "status": .string("pending")])
            ])
        ])

        let update = TranscriptFormatter.update(
            method: "turn/plan/updated",
            params: params,
            itemsWithDeltas: []
        )

        #expect(update.section == .reasoning)
        #expect(update.text.contains("Plan\n"))
        #expect(update.text.contains("Checking the durable workflow first."))
        #expect(update.text.contains("[done] Inspect recovery"))
        #expect(update.text.contains("[active] Repair persistence"))
        #expect(update.text.contains("[pending] Run tests"))
    }
}
