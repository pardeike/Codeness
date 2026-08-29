import CodenessCore
import Foundation
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
            RunTranscriptPresentation.storedText("\n\nInspecting.\n", section: .reasoning),
            RunTranscriptPresentation.storedText("\n› xcodebuild test\n", section: .action),
            RunTranscriptPresentation.storedText("\n⚠ A command failed\n", section: .diagnostic),
            RunTranscriptPresentation.storedText("\nFinished.\n", section: .result)
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
    func structuredCompanyReportsStayStoredButAreHiddenFromTheTranscript() throws {
        let snapshot = assignedCompanySnapshot()
        let report = CompanyWorkReport(
            workerID: snapshot.member.id,
            positionID: .artDirector,
            contributionKind: .visualDirection,
            summary: "Established a playful paper-cut visual direction.",
            artifacts: ["ART_DIRECTION.md"],
            evidence: ["The palette and shape language cover the core interaction states."],
            decisions: ["Use torn-paper silhouettes and saturated rain colors."],
            constraints: [],
            risks: ["Small silhouettes need contrast testing."],
            capabilityBlock: nil,
            recommendedRecipientPositions: [.developer]
        )
        let rawReport = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        let transcript = RunTranscriptPresentation.storedText(
            "Exploring three distinct visual directions.\n",
            section: .reasoning
        ) + RunTranscriptPresentation.storedText(rawReport, section: .reasoning)
        let run = makeRun(
            prompt: "Define the visual direction.",
            transcript: transcript,
            liveTeamMember: snapshot
        )

        let presented = RunTranscriptPresentation.text(for: run, separatesRuns: true)
        #expect(presented.contains("Exploring three distinct visual directions."))
        #expect(!presented.contains("workerID"))
        #expect(!presented.contains("recommendedRecipientPositions"))
        #expect(run.transcript.contains(rawReport))
        #expect(report.presentationMarkdown.contains("playful paper-cut visual direction"))
        #expect(report.presentationMarkdown.contains("ART_DIRECTION.md"))
        #expect(!report.presentationMarkdown.contains("workerID"))
    }

    @Test
    func steeringMessagesRemainVisibleAndIdentifyOnlyTheUserMessage() throws {
        let transcript = RunTranscriptPresentation.storedText(
            "Agent output before steering.\n",
            section: .reasoning
        )
        + RunTranscriptPresentation.storedSteeringMessage(
            "Prioritize the native interaction proof."
        )
        + "Agent output after steering.\n"
        let run = makeRun(prompt: "Review the app.", transcript: transcript)

        let steeringOnly = RunTranscriptPresentation.content(
            for: run,
            separatesRuns: true,
            visibility: TranscriptVisibility(
                reasoning: false,
                actions: false,
                results: false,
                diagnostics: false
            )
        )
        #expect(
            steeringOnly.text
                == "You steered\nPrioritize the native interaction proof.\n"
        )
        #expect(steeringOnly.steeringRanges.count == 1)
        let range = try #require(steeringOnly.steeringRanges.first)
        #expect(
            (steeringOnly.text as NSString).substring(with: NSRange(
                location: range.location,
                length: range.length
            )) == "You steered\nPrioritize the native interaction proof."
        )

        let complete = RunTranscriptPresentation.content(
            for: run,
            separatesRuns: true,
            visibility: .all
        )
        #expect(complete.text.contains("Agent output before steering."))
        #expect(complete.text.contains("Agent output after steering."))
        #expect(complete.steeringRanges.count == 1)
        let completeRange = try #require(complete.steeringRanges.first)
        let styledText = (complete.text as NSString).substring(with: NSRange(
            location: completeRange.location,
            length: completeRange.length
        ))
        #expect(!styledText.contains("Agent output after steering."))
    }

    @Test
    func openAICompatibleToolSummariesFollowActionVisibility() {
        let transcript = RunTranscriptPresentation.storedText(
            "Using glob…\n",
            section: .action
        )
        + RunTranscriptPresentation.storedText(
            "Using read…\n",
            section: .action
        )
        let run = makeRun(prompt: "Inspect the repository.", transcript: transcript)

        let recommended = RunTranscriptPresentation.text(for: run, separatesRuns: true)
        #expect(!recommended.contains("Using glob"))
        #expect(!recommended.contains("Using read"))

        let withActions = RunTranscriptPresentation.text(
            for: run,
            separatesRuns: true,
            visibility: .all
        )
        #expect(withActions.contains("Using glob…\nUsing read…"))
    }

    @Test
    func resultAfterOpenAICompatibleActionsDoesNotInheritActionVisibility() {
        let transcript = RunTranscriptPresentation.storedText(
            "Using bash…\n",
            section: .action
        )
        + RunTranscriptPresentation.storedText(
            "Build and tests passed.",
            section: .result
        )
        let run = makeRun(prompt: "Test the change.", transcript: transcript)

        let recommended = RunTranscriptPresentation.text(for: run, separatesRuns: true)
        #expect(!recommended.contains("Using bash"))
        #expect(recommended == "Build and tests passed.")
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
        finalOutput: String? = nil,
        liveTeamMember: LiveTeamMemberSnapshot? = nil
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
            finalOutput: finalOutput,
            liveTeamMember: liveTeamMember
        )
    }

    private func assignedCompanySnapshot() -> LiveTeamMemberSnapshot {
        let member = LiveTeamMember(
            id: "art_direction",
            name: "Define Visual Direction",
            instructions: "Create a decision-ready visual direction.",
            target: AgentTarget(providerID: .codex, model: "gpt-test"),
            runPolicy: .once,
            sessionPolicy: .ownMemory,
            positionID: .artDirector,
            companyAssignment: CompanyAssignmentContract(
                contributionKind: .visualDirection,
                requiredCapabilities: [.workspaceRead],
                acceptanceEvidence: "A coherent visual direction is inspectable.",
                dependencyContributionKinds: [],
                stopCondition: "Stop when the direction is decision-ready."
            )
        )
        return LiveTeamMemberSnapshot(
            member: member,
            workingGoal: "Define the product before implementation.",
            revision: 1,
            cycle: 1,
            sessionSlotID: "member:art_direction"
        )
    }
}
