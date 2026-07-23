import Testing
@testable import CodenessCore

struct PromptBuilderTests {
    @Test
    func relayPromptRetainsRelevantContentAndRequiresAConcreteShortLabel() {
        let context = HandoffContext(
            sender: .implementer,
            recipient: .reviewer,
            runKind: .implementation,
            recipientPurpose: "Review the checkpoint",
            source: "Changed Sources/App.swift and ran xcodebuild."
        )
        let prompt = RelayPromptBuilder.systemPrompt(for: context)

        #expect(prompt.contains("There is no target length, percentage, or compression ratio"))
        #expect(prompt.contains("If unsure whether something is relevant, retain it"))
        #expect(prompt.contains("Keep retained content as close to the source wording and order as possible"))
        #expect(prompt.contains("affected files and symbols"))
        #expect(prompt.contains("at most 48 characters"))
        #expect(prompt.contains("must not be only a generic phase name"))
    }

    @Test
    func templatesSupplyMultilineGoalAndPreviousOutputs() {
        let prompts = ActivityPrompts(
            implementation: "Implement one useful part.",
            review: "Review the recent work:\n{{implementation_output}}",
            fix: "Fix these findings:\n{{review_output}}"
        )
        let goal = "Implement Docs/Parser.md.\nInclude malformed-input tests."

        let implementation = PromptBuilder.implementation(goal: goal, template: prompts.implementation)
        #expect(implementation.contains("THE GOAL\n<goal>\n\(goal)\n</goal>"))
        #expect(implementation.hasSuffix("Implement one useful part."))
        #expect(
            PromptBuilder.review(
                goal: goal,
                template: prompts.review,
                implementationOutput: "Changed tokenization."
            ).hasSuffix("Review the recent work:\nChanged tokenization.")
        )
        let fix = PromptBuilder.fix(
            goal: goal,
            template: prompts.fix,
            reviewOutput: "Handle empty input."
        )
        #expect(fix.contains("Fix these findings:\nHandle empty input."))
        #expect(fix.contains("The whole goal is complete."))
        #expect(fix.contains("More implementation work remains."))
    }

    @Test
    func defaultsKeepImplementationAndFixingSeparate() {
        let prompts = ActivityPrompts.builtInDefaults

        #expect(prompts.implementation.contains("stop when you think a review is useful"))
        #expect(prompts.fix.contains("stop without continuing with the next implementation step"))
        #expect(prompts.review.contains(ActivityPrompts.implementationOutputPlaceholder))
        #expect(prompts.fix.contains(ActivityPrompts.reviewOutputPlaceholder))
        #expect(prompts.validationMessage == nil)
    }

    @Test
    func fixRelayRequiresSeparateFixAndWholeGoalVerdicts() {
        let context = HandoffContext(
            sender: .implementer,
            recipient: .implementer,
            runKind: .fix,
            recipientPurpose: "Continue or finish",
            source: "The findings are addressed. More implementation work remains."
        )

        let prompt = RelayPromptBuilder.systemPrompt(for: context)

        #expect(prompt.contains("Classify fixCheckpoint"))
        #expect(prompt.contains("Classify fixComplete"))
        #expect(prompt.contains("whole goal is complete"))
        #expect(prompt.contains("classify unclear"))
    }

    @Test
    func validationRequiresBothHandoffPlaceholders() {
        var prompts = ActivityPrompts.builtInDefaults
        prompts.review = "Review the repository."
        #expect(prompts.validationMessage?.contains(ActivityPrompts.implementationOutputPlaceholder) == true)

        prompts = .builtInDefaults
        prompts.fix = "Fix the findings."
        #expect(prompts.validationMessage?.contains(ActivityPrompts.reviewOutputPlaceholder) == true)
    }
}
