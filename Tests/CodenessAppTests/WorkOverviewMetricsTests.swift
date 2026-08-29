import Foundation
import Testing
@testable import Codeness
import CodenessCore

struct WorkOverviewMetricsTests {
    @Test
    func companyFormationKeepsLongBootstrapVisiblyAliveWithoutInventingProgress() {
        let startedAt = Date(timeIntervalSince1970: 1_000)

        let first = CompanyFormationPresentation(
            status: .running,
            startedAt: startedAt,
            now: startedAt
        )
        let next = CompanyFormationPresentation(
            status: .running,
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(4)
        )
        let wrapped = CompanyFormationPresentation(
            status: .running,
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(20)
        )

        #expect(first.headline == "Founding the company")
        #expect(first.progress == "Choosing the team")
        #expect(first.activeMomentIndex == 0)
        #expect(next.activeMomentIndex == 1)
        #expect(next.detail == CompanyFormationPresentation.moments[1].title)
        #expect(next.progress == first.progress)
        #expect(wrapped.activeMomentIndex == 0)
        #expect(wrapped.progress == first.progress)
    }

    @Test
    func pausedCompanyFormationStopsTheActivityCue() {
        let presentation = CompanyFormationPresentation(
            status: .paused,
            startedAt: .distantPast,
            now: .now
        )

        #expect(presentation.headline == "Company setup is paused")
        #expect(presentation.progress == "Team not formed")
        #expect(presentation.detail == "Resume when you want Codeness to continue.")
        #expect(presentation.activeMomentIndex == nil)
    }

    @Test
    func companyMetricsSeparateProductTokensFromAllControlTokens() throws {
        let target = AgentTarget(providerID: .codex, model: "gpt-company")
        let chiefExecutive = metricsPerson(
            name: "CEO One",
            positionID: .chiefExecutive,
            assignment: "Own investment decisions.",
            tokens: 20
        )
        let formerChiefExecutive = metricsPerson(
            name: "CEO Zero",
            positionID: .chiefExecutive,
            assignment: "Fund the first product bet.",
            tokens: 5
        )
        let developer = metricsPerson(
            name: "Dev One",
            positionID: .developer,
            assignment: "Build the product.",
            tokens: 30
        )
        let member = LiveTeamMember(
            id: "build",
            name: "Ship Core Value",
            instructions: developer.assignment,
            target: target,
            runPolicy: .everyCycle,
            sessionPolicy: .ownMemory,
            positionID: .developer,
            person: developer
        )
        let definition = LiveTeamDefinition(
            revision: 1,
            workingGoal: "Ship core value.",
            members: [member],
            coordinator: .init(target: target, instructions: "Route directly."),
            strategicReason: "Build first.",
            operatingModelVersion: 2,
            overseerPerson: chiefExecutive,
            formerPeople: [formerChiefExecutive],
            productBet: .init(
                headline: "Ship core value",
                valuePromise: "A user can exercise it.",
                showcase: "Integrated demonstration",
                integrationTarget: "Main product",
                killCondition: "Stop if users cannot exercise it."
            ),
            setupTokenUsage: usage(10)
        )
        let snapshot = LiveTeamMemberSnapshot(
            member: member,
            workingGoal: definition.workingGoal,
            revision: 1,
            cycle: 1,
            sessionSlotID: "member:build",
            productBet: definition.productBet
        )
        let run = RunRecord(
            sequence: 1,
            role: .implementer,
            kind: .implementation,
            status: .completed,
            threadID: nil,
            model: target.model,
            effort: "high",
            prompt: "Build it.",
            startedAt: .now,
            tokenUsage: usage(100),
            liveTeamMember: snapshot
        )
        let review = LiveTeamReviewRecord(
            mode: .strategicReview,
            trigger: "Investment boundary",
            sourceRunID: run.id,
            baseRevision: 1,
            status: .completed,
            focusGroup: LiveTeamFocusGroupReport(
                subject: "Integrated demonstration",
                question: "Would the intended audience choose it?",
                audience: "Intended users",
                comparison: "Closest alternative",
                comparisonReason: "It serves the same need.",
                researchBasis: .liveWeb,
                sources: [],
                participants: [],
                findings: [],
                verdict: "Continue with one sharper interaction.",
                nextExperiment: "Exercise the sharper interaction.",
                limitations: "Simulated directional evidence.",
                tokenUsage: usage(25)
            ),
            consultations: [LiveTeamManagerConsultation(
                name: developer.profile.fullName,
                mandate: developer.assignment,
                status: .completed,
                tokenUsage: usage(50)
            )],
            decision: .init(
                outcome: .kept,
                summary: "Continue",
                reason: "Product evidence is strong.",
                evidence: "The demonstration works."
            ),
            completedAt: .now,
            controlTokenUsage: usage(40)
        )
        let activity = ActivityRecord(
            goal: "Ship the product.",
            prompts: .builtInDefaults,
            status: .running,
            runs: [run],
            liveTeam: LiveTeamState(
                overseer: .init(target: target, instructions: "Own the goal."),
                currentDefinition: definition,
                reviews: [review],
                definitionHistory: [definition]
            )
        )

        let metrics = WorkOverviewMetrics(
            activity: activity,
            repositoryUpdatedAt: .now,
            now: .now
        )

        #expect(metrics.productTokenUsage?.totalTokens == 100)
        #expect(metrics.controlTokenUsage?.totalTokens == 180)
        #expect(metrics.totalTokenUsage?.totalTokens == 280)
        #expect(metrics.recordedTokenRunCount == 1)
        #expect(metrics.investmentDecisionCount == 1)
        #expect(metrics.tokensPerInvestmentDecision == 280)
    }

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

private func usage(_ tokens: Int64) -> RunTokenUsage {
    RunTokenUsage(totalTokens: tokens, inputTokens: tokens, outputTokens: 0)
}

private func metricsPerson(
    name: String,
    positionID: CompanyPositionID,
    assignment: String,
    tokens: Int64
) -> CompanyPerson {
    CompanyPerson(
        positionID: positionID,
        profile: CompanyPersonaProfile(
            fullName: name,
            background: "Built real products.",
            formativeSuccess: "Shipped something people used.",
            formativeScar: "Watched process displace value.",
            convictions: ["Build first.", "Exercise the result.", "Reject mediocrity."],
            personalStake: "Wants the product to matter.",
            workingStyle: "Direct and ambitious.",
            conflictStyle: "Argues clearly from evidence.",
            blindSpot: "Moves too quickly.",
            evidenceThatChangesTheirMind: "Observed user behavior.",
            ingredients: .init(
                spark: "A real launch",
                riskPosture: "bold reversible bets",
                conflictStyle: "direct",
                craftObsession: "visible value",
                ambition: "build the reference product"
            )
        ),
        assignment: assignment,
        generationTokenUsage: usage(tokens)
    )
}
