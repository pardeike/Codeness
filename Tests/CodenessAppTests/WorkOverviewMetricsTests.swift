import Foundation
import Testing
@testable import Codeness
import CodenessCore

struct WorkOverviewMetricsTests {
    @Test
    func liveTeamMetricsAggregateByMemberIdentityAndCountCycles() throws {
        let startedAt = Date(timeIntervalSince1970: 30_000)
        let target = AgentTarget(providerID: .codex, model: "gpt-live")
        let deliver = LiveTeamMember(
            id: "deliver",
            name: "Deliver",
            instructions: "Deliver a bounded unit.",
            target: target,
            runPolicy: .everyCycle,
            sessionPolicy: .ownMemory
        )
        let review = LiveTeamMember(
            id: "review",
            name: "Review",
            instructions: "Review independently.",
            target: target,
            runPolicy: .everyCycle,
            sessionPolicy: .freshEveryRun
        )
        let definition = LiveTeamDefinition(
            revision: 2,
            workingGoal: "Deliver and review the bounded result.",
            members: [deliver, review],
            coordinator: .init(target: target, instructions: "Route local work."),
            strategicReason: "Delivery and independent review are both required."
        )
        let liveRun: (Int, LiveTeamMember, Int) -> RunRecord = { sequence, member, cycle in
            RunRecord(
                sequence: sequence,
                role: member.id == "review" ? .reviewer : .implementer,
                kind: member.id == "review" ? .review : .implementation,
                status: .completed,
                threadID: "session-\(sequence)",
                model: target.model,
                effort: "high",
                prompt: member.instructions,
                startedAt: startedAt,
                durationMilliseconds: 1_000,
                tokenUsage: .init(totalTokens: 10, inputTokens: 8, outputTokens: 2),
                liveTeamMember: .init(
                    member: member,
                    workingGoal: definition.workingGoal,
                    revision: definition.revision,
                    cycle: cycle,
                    sessionSlotID: member.sessionPolicy.persistentSlotID(memberID: member.id)
                        ?? "fresh:\(member.id):\(sequence)"
                )
            )
        }
        let activity = ActivityRecord(
            goal: "Board goal",
            prompts: .builtInDefaults,
            status: .running,
            runs: [
                liveRun(1, deliver, 1),
                liveRun(2, review, 1),
                liveRun(3, deliver, 2)
            ],
            liveTeam: LiveTeamState(
                overseer: .init(target: target, instructions: "Control strategy."),
                currentDefinition: definition
            ),
            createdAt: startedAt
        )

        let metrics = WorkOverviewMetrics(
            activity: activity,
            repositoryUpdatedAt: startedAt,
            now: startedAt.addingTimeInterval(10)
        )

        #expect(metrics.usesLiveTeam)
        #expect(!metrics.usesGenericWorkflow)
        #expect(metrics.workUnitCount == 2)
        #expect(metrics.phases.map(\.name) == ["Deliver", "Review"])
        #expect(try #require(metrics.phases.first { $0.id == "deliver" }).runCount == 2)
        #expect(try #require(metrics.phases.first { $0.id == "review" }).runCount == 1)
        #expect(metrics.totalTokenUsage?.totalTokens == 30)
    }

    @Test
    func aggregatesRunTimeAndActivityContextAcrossWorkflowPhases() throws {
        let startedAt = Date(timeIntervalSince1970: 10_000)
        let now = startedAt.addingTimeInterval(3_600)
        let runs = [
            run(
                sequence: 1,
                kind: .implementation,
                status: .completed,
                startedAt: startedAt,
                durationMilliseconds: 120_000,
                tokenUsage: RunTokenUsage(
                    totalTokens: 1_250_000,
                    inputTokens: 1_240_000,
                    cachedInputTokens: 900_000,
                    outputTokens: 10_000,
                    reasoningOutputTokens: 2_000
                )
            ),
            run(
                sequence: 2,
                kind: .review,
                status: .completed,
                startedAt: startedAt.addingTimeInterval(200),
                completedAt: startedAt.addingTimeInterval(500),
                tokenUsage: RunTokenUsage(
                    totalTokens: 400_000,
                    inputTokens: 396_000,
                    cachedInputTokens: 300_000,
                    outputTokens: 4_000,
                    reasoningOutputTokens: 1_000
                )
            ),
            run(
                sequence: 3,
                kind: .fix,
                status: .completed,
                startedAt: startedAt.addingTimeInterval(600),
                durationMilliseconds: 60_000,
                tokenUsage: RunTokenUsage(
                    totalTokens: 200_000,
                    inputTokens: 198_000,
                    cachedInputTokens: 150_000,
                    outputTokens: 2_000,
                    reasoningOutputTokens: 500
                )
            ),
            run(
                sequence: 4,
                kind: .implementation,
                status: .running,
                startedAt: startedAt.addingTimeInterval(3_000)
            )
        ]
        let updatedAt = startedAt.addingTimeInterval(3_500)
        let activity = ActivityRecord(
            goal: "Finish the repository",
            prompts: .builtInDefaults,
            status: .running,
            runs: runs,
            createdAt: startedAt
        )

        let metrics = WorkOverviewMetrics(
            activity: activity,
            repositoryUpdatedAt: updatedAt,
            now: now
        )

        #expect(metrics.totalRunCount == 4)
        #expect(metrics.completedRunCount == 3)
        #expect(metrics.workUnitCount == 2)
        #expect(metrics.totalRunMilliseconds == 1_080_000)
        #expect(metrics.elapsedMilliseconds == 3_600_000)
        #expect(metrics.repositoryUpdatedAt == updatedAt)
        #expect(!metrics.isFinished)
        #expect(metrics.recordedTokenRunCount == 3)
        #expect(metrics.totalTokenUsage?.totalTokens == 1_850_000)
        #expect(metrics.totalTokenUsage?.inputTokens == 1_834_000)
        #expect(metrics.totalTokenUsage?.cachedInputTokens == 1_350_000)
        #expect(metrics.totalTokenUsage?.outputTokens == 16_000)
        #expect(metrics.totalTokenUsage?.reasoningOutputTokens == 3_500)

        let implementation = try #require(
            metrics.phases.first(where: { $0.kind == .implementation })
        )
        #expect(implementation.runCount == 2)
        #expect(implementation.completedRunCount == 1)
        #expect(implementation.durationMilliseconds == 720_000)
        #expect(implementation.tokenRunCount == 1)
        #expect(implementation.tokenUsage?.totalTokens == 1_250_000)

        let review = try #require(metrics.phases.first(where: { $0.kind == .review }))
        #expect(review.runCount == 1)
        #expect(review.durationMilliseconds == 300_000)

        let fix = try #require(metrics.phases.first(where: { $0.kind == .fix }))
        #expect(fix.runCount == 1)
        #expect(fix.durationMilliseconds == 60_000)
    }

    @Test
    func formatsOverviewDurationsCompactly() {
        #expect(WorkOverviewFormatting.duration(milliseconds: 0) == "0s")
        #expect(WorkOverviewFormatting.duration(milliseconds: 12_400) == "12s")
        #expect(WorkOverviewFormatting.duration(milliseconds: 210_500) == "3m 31s")
        #expect(WorkOverviewFormatting.duration(milliseconds: 7_260_000) == "2h 1m")
    }

    @Test
    func formatsTokenCountsCompactlyAndRetainsExactDetail() {
        #expect(WorkOverviewFormatting.tokens(0) == "0")
        #expect(WorkOverviewFormatting.tokens(999) == "999")
        #expect(WorkOverviewFormatting.tokens(1_250) == "1.2K")
        #expect(WorkOverviewFormatting.tokens(12_400) == "12.4K")
        #expect(WorkOverviewFormatting.tokens(125_000) == "125K")
        #expect(WorkOverviewFormatting.tokens(1_250_000) == "1.2M")
        #expect(WorkOverviewFormatting.tokenDetail(1_250_000) == "1,250,000")
    }

    @Test
    func derivesTotalInputForClaudeUsageRecordedBeforeInputNormalization() {
        let legacyUsage = RunTokenUsage(
            totalTokens: 46_600_000,
            inputTokens: 379,
            cachedInputTokens: 46_451_621,
            outputTokens: 148_000
        )

        #expect(WorkOverviewFormatting.inputTokens(legacyUsage) == 46_452_000)
    }

    @Test
    func preservesSummarySectionsAndBulletsAsSeparateVisualBlocks() {
        let markdown = """
        ### Completed
        - Added **window restoration**.
        - Persisted divider positions.

        ### Current state
        - The workflow is paused.

        ### Remaining
        - Verify the installed app.
        """

        #expect(
            WorkOverviewFormatting.summaryBlocks(markdown) == [
                .heading("Completed"),
                .bullet("Added **window restoration**."),
                .bullet("Persisted divider positions."),
                .heading("Current state"),
                .bullet("The workflow is paused."),
                .heading("Remaining"),
                .bullet("Verify the installed app.")
            ]
        )
    }

    @Test
    func genericMetricsAggregateByConfiguredStepAndCountOnlyLoopCycles() throws {
        let startedAt = Date(timeIntervalSince1970: 20_000)
        let codex = AgentTarget(providerID: .codex, model: "codex-model")
        let claude = AgentTarget(providerID: .claude, model: "sonnet")
        let plan = WorkflowStep(
            id: "plan",
            name: "Plan",
            section: .prefix,
            instructions: "Plan.",
            target: codex
        )
        let code = WorkflowStep(
            id: "code",
            name: "Code",
            section: .loop,
            instructions: "Code.",
            target: claude
        )
        let inspect = WorkflowStep(
            id: "inspect",
            name: "Inspect",
            section: .loop,
            instructions: "Inspect.",
            target: codex
        )
        let workflow = WorkflowTemplate(
            id: "generic",
            name: "Generic",
            summary: "Metrics",
            steps: [plan, code, inspect],
            coordinator: WorkflowCoordinatorConfiguration(
                target: codex,
                instructions: "Route."
            )
        )
        let activity = ActivityRecord(
            goal: "Measure generic work",
            prompts: .builtInDefaults,
            status: .completed,
            runs: [
                genericRun(1, step: plan, iteration: 1, startedAt: startedAt),
                genericRun(2, step: code, iteration: 1, startedAt: startedAt),
                genericRun(3, step: inspect, iteration: 1, startedAt: startedAt),
                genericRun(4, step: code, iteration: 2, startedAt: startedAt),
                genericRun(5, step: inspect, iteration: 2, startedAt: startedAt)
            ],
            workflow: workflow,
            completedAt: startedAt.addingTimeInterval(10)
        )

        let metrics = WorkOverviewMetrics(
            activity: activity,
            repositoryUpdatedAt: startedAt,
            now: startedAt.addingTimeInterval(20)
        )

        #expect(metrics.usesGenericWorkflow)
        #expect(metrics.workUnitCount == 2)
        #expect(metrics.phases.map(\.name) == ["Plan", "Code", "Inspect"])
        #expect(try #require(metrics.phases.first { $0.id == "plan" }).runCount == 1)
        #expect(try #require(metrics.phases.first { $0.id == "code" }).runCount == 2)
        #expect(try #require(metrics.phases.first { $0.id == "inspect" }).runCount == 2)
        #expect(metrics.phases.allSatisfy { $0.kind == nil })
    }

    private func run(
        sequence: Int,
        kind: RunKind,
        status: RunStatus,
        startedAt: Date,
        completedAt: Date? = nil,
        durationMilliseconds: Int64? = nil,
        tokenUsage: RunTokenUsage? = nil
    ) -> RunRecord {
        RunRecord(
            sequence: sequence,
            role: kind == .review ? .reviewer : .implementer,
            kind: kind,
            status: status,
            threadID: "thread-\(sequence)",
            model: "model",
            effort: "high",
            prompt: "Run \(sequence)",
            startedAt: startedAt,
            completedAt: completedAt,
            durationMilliseconds: durationMilliseconds,
            tokenUsage: tokenUsage
        )
    }

    private func genericRun(
        _ sequence: Int,
        step: WorkflowStep,
        iteration: Int,
        startedAt: Date
    ) -> RunRecord {
        RunRecord(
            sequence: sequence,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: "session-\(step.id)",
            model: step.target.model,
            effort: "high",
            prompt: step.name,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(1),
            durationMilliseconds: 1_000,
            workflowStep: WorkflowStepSnapshot(
                step: step,
                loopIteration: iteration
            ),
            agentTarget: step.target
        )
    }
}
