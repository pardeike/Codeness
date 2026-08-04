import CodenessCore
import Testing

struct RunTranscriptPresentationTests {
    @Test
    func separateModeHidesTheInjectedPromptWithoutChangingTheStoredTranscript() {
        let prompt = "Here comes the review feedback:\n\nFix this issue."
        let transcript = "Prompt\n\(prompt)\n\n\nReasoning\nI will inspect the failure."
        let run = makeRun(prompt: prompt, transcript: transcript)

        #expect(
            RunTranscriptPresentation.text(for: run, separatesRuns: true)
                == "Reasoning\nI will inspect the failure."
        )
        #expect(run.transcript == transcript)
    }

    @Test
    func seamlessModeIncludesTheFullInjectedPrompt() {
        let prompt = "Review the implementation."
        let transcript = "Prompt\n\(prompt)\n\nReasoning\nReviewing."
        let run = makeRun(prompt: prompt, transcript: transcript)

        #expect(RunTranscriptPresentation.text(for: run, separatesRuns: false) == transcript)
    }

    @Test
    func separateModePreservesTranscriptsThatDoNotContainAStartedPrompt() {
        let transcript = "Could not start turn: server unavailable"
        let run = makeRun(prompt: "Implement this.", transcript: transcript)

        #expect(RunTranscriptPresentation.text(for: run, separatesRuns: true) == transcript)
    }

    @Test
    func structuredTranscriptDefaultsToReasoningResultAndDiagnostics() {
        let transcript = [
            RunTranscriptPresentation.storedText("Prompt\nDo the work.\n\n", section: .prompt),
            RunTranscriptPresentation.storedText("Reasoning\nInspecting.\n", section: .reasoning),
            RunTranscriptPresentation.storedText("\n› xcodebuild test\n", section: .action),
            RunTranscriptPresentation.storedText("\n⚠ A command failed\n", section: .diagnostic),
            RunTranscriptPresentation.storedText("\nResult\nFinished.\n", section: .result)
        ].joined()
        let run = makeRun(prompt: "Do the work.", transcript: transcript)

        let recommended = RunTranscriptPresentation.text(for: run, separatesRuns: true)
        #expect(recommended.contains("Inspecting."))
        #expect(recommended.contains("A command failed"))
        #expect(recommended.contains("Finished."))
        #expect(!recommended.contains("Do the work."))
        #expect(!recommended.contains("xcodebuild"))

        let all = RunTranscriptPresentation.text(
            for: run,
            separatesRuns: false,
            visibility: .all
        )
        #expect(all.contains("Do the work."))
        #expect(all.contains("xcodebuild"))
    }

    @Test
    func structuredTranscriptRecoversClaudeNarrativeStoredAfterLegacyActionMarkers() {
        let transcript = [
            RunTranscriptPresentation.storedText(
                "\n\nClaude\nInitial orientation.",
                section: .reasoning
            ),
            RunTranscriptPresentation.storedText("\n› Bash\n", section: .action),
            "Claude status: requestingClaude status: requestingNarrative after Bash.",
            RunTranscriptPresentation.storedText("\n› Read\n", section: .action),
            "Narrative after Read."
        ].joined()
        let run = makeRun(prompt: "Do the work.", transcript: transcript)

        let recommended = RunTranscriptPresentation.text(for: run, separatesRuns: true)
        #expect(recommended.contains("Initial orientation."))
        #expect(recommended.contains("Narrative after Bash."))
        #expect(recommended.contains("Narrative after Read."))
        #expect(!recommended.contains("› Bash"))
        #expect(!recommended.contains("› Read"))
        #expect(!recommended.contains("Claude status:"))

        let withActions = RunTranscriptPresentation.text(
            for: run,
            separatesRuns: true,
            visibility: .all
        )
        #expect(withActions.contains("› Bash"))
        #expect(withActions.contains("Narrative after Bash."))
        #expect(!withActions.contains("Claude status:"))
    }

    @Test
    func legacyTranscriptCanHideNoisyCommandBodies() {
        let transcript = """
        Prompt
        Do the work.

        Thinking
        I will inspect the repository.

        $ /bin/zsh -lc "sed -n '1,2000p' Source.swift"
        thousands of noisy tool-output characters
        [completed, exit 0]

        Thinking
        The source confirms the expected design.

        Result
        Review ready.
        """
        let run = makeRun(prompt: "Do the work.", transcript: transcript)

        let result = RunTranscriptPresentation.text(for: run, separatesRuns: true)
        #expect(result.contains("I will inspect the repository."))
        #expect(result.contains("The source confirms the expected design."))
        #expect(result.contains("Review ready."))
        #expect(!result.contains("sed -n"))
        #expect(!result.contains("noisy tool-output"))
        #expect(!result.contains("[completed, exit 0]"))
    }

    @Test
    func legacyFinalOutputMovesOutOfTheHistoryWhenASeparatePaneExists() {
        let finalOutput = "Implemented the parser and all tests pass."
        let transcript = """
        Thinking
        I will verify the parser.

        Thinking
        \(finalOutput)
        """
        let run = makeRun(
            prompt: "Implement the parser.",
            transcript: transcript,
            finalOutput: finalOutput
        )

        let history = RunTranscriptPresentation.text(
            for: run,
            separatesRuns: true,
            visibility: TranscriptVisibility(results: false)
        )
        #expect(history.contains("I will verify the parser."))
        #expect(!history.contains(finalOutput))
    }

    @Test
    func staleAppendLogDoesNotReplaceNewerMetadata() {
        let metadata = "Reasoning\nFirst update.\nLater metadata update.\n"
        let appendLog = "Reasoning\nFirst update.\n"

        #expect(
            RunTranscriptPresentation.reconciledTranscript(
                metadata: metadata,
                appendLog: appendLog
            ) == metadata
        )
    }

    @Test
    func appendLogExtensionRecoversTextWrittenAfterTheMetadataCheckpoint() {
        let metadata = "Reasoning\nFirst update.\n"
        let appendLog = metadata + "Latest streamed update.\n"

        #expect(
            RunTranscriptPresentation.reconciledTranscript(
                metadata: metadata,
                appendLog: appendLog
            ) == appendLog
        )
    }

    @Test
    func divergentAppendLogKeepsMetadataWithoutSynthesizingARemainder() {
        let common = "Reasoning\nFirst update.\n"
        let metadata = common + "Metadata-only update.\n"
        let appendLog = common + "Append-only later update.\n"

        #expect(
            RunTranscriptPresentation.reconciledTranscript(
                metadata: metadata,
                appendLog: appendLog
            ) == metadata
        )
    }

    @Test
    func middleGapAndTruncatedAppendLogsKeepMetadataCanonical() {
        let prefix = "Reasoning\nFirst update.\n"
        let sharedTail = "Shared final output.\n"
        let metadataWithMiddleGap = prefix + "Metadata-only diagnostic.\n" + sharedTail
        let appendLogMissingMiddle = prefix + sharedTail
        let truncatedAppendLog = prefix + "truncated fragment"

        #expect(
            RunTranscriptPresentation.reconciledTranscript(
                metadata: metadataWithMiddleGap,
                appendLog: appendLogMissingMiddle
            ) == metadataWithMiddleGap
        )
        #expect(
            RunTranscriptPresentation.reconciledTranscript(
                metadata: metadataWithMiddleGap,
                appendLog: truncatedAppendLog
            ) == metadataWithMiddleGap
        )
    }

    @Test
    func unrelatedAppendLogCannotPolluteDecodedMetadata() {
        let metadata = "Valid metadata transcript"
        let appendLog = "unrelated or corrupt data"

        #expect(
            RunTranscriptPresentation.reconciledTranscript(
                metadata: metadata,
                appendLog: appendLog
            ) == metadata
        )
    }

    private func makeRun(
        prompt: String,
        transcript: String,
        finalOutput: String? = nil
    ) -> RunRecord {
        RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .running,
            threadID: "thread",
            model: "gpt-test",
            effort: "medium",
            prompt: prompt,
            transcript: transcript,
            finalOutput: finalOutput
        )
    }
}
