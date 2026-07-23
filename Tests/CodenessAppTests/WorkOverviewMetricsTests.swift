import Foundation
import Testing
@testable import Codeness
import CodenessCore

struct WorkOverviewMetricsTests {
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
}
