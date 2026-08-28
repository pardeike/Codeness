import AppKit
import CodenessCore
import Foundation
import Testing
@testable import Codeness

@MainActor
struct RepositoryWindowAppearanceTests {
    @Test
    func controlsAppearActiveOnlyForAKeyWindowInTheActiveApplication() {
        let state = RepositoryWindowAppearanceState()

        state.update(applicationIsActive: false, windowIsKey: false)
        #expect(!state.appearsActive)

        state.update(applicationIsActive: false, windowIsKey: true)
        #expect(!state.appearsActive)

        state.update(applicationIsActive: true, windowIsKey: false)
        #expect(!state.appearsActive)

        state.update(applicationIsActive: true, windowIsKey: true)
        #expect(state.appearsActive)
    }

    @Test
    func everyRepositoryDetailPageSuppressesTheAutomaticTopBar() async throws {
        _ = NSApplication.shared
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-top-edge-\(UUID().uuidString)", isDirectory: true)
        let configurationURL = fixtureRoot.appendingPathComponent(
            "Configuration",
            isDirectory: true
        )
        let activityURL = fixtureRoot.appendingPathComponent("Activity", isDirectory: true)
        let supportURL = fixtureRoot.appendingPathComponent("State", isDirectory: true)
        for repositoryURL in [configurationURL, activityURL] {
            try FileManager.default.createDirectory(
                at: repositoryURL,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let fixture = detailPageFixture()
        let store = WorkspaceStore(rootURL: supportURL)
        try await store.save(RepositoryRecord(
            canonicalPath: configurationURL.path,
            activityDraft: .init(goal: "Build the product.", prompts: .builtInDefaults)
        ))
        try await store.save(RepositoryRecord(
            canonicalPath: activityURL.path,
            activity: fixture.activity
        ))
        let application = CodenessApplicationModel(store: store)
        let manager = RepositoryWindowManager(
            applicationModel: application,
            commandState: RepositoryWindowCommandState()
        )

        let configurationController = try await manager.openRepository(
            at: configurationURL,
            display: true
        ).controller
        defer { configurationController.window?.orderOut(nil) }
        await configurationController.coordinator.load()
        try await settle(configurationController.window)
        assertAutomaticTopBarsAreSuppressed(
            in: configurationController.window,
            page: "goal configuration"
        )

        let activityController = try await manager.openRepository(
            at: activityURL,
            display: true
        ).controller
        defer { activityController.window?.orderOut(nil) }
        let coordinator = activityController.coordinator
        await coordinator.load()
        try await settle(activityController.window)

        coordinator.selectRun(nil)
        try await settle(activityController.window)
        #expect(coordinator.selectedRun == nil)
        assertAutomaticTopBarsAreSuppressed(
            in: activityController.window,
            page: "company overview"
        )

        coordinator.selectCompanyPerson(fixture.personID)
        try await settle(activityController.window)
        #expect(coordinator.selectedCompanyPerson?.id == fixture.personID)
        assertAutomaticTopBarsAreSuppressed(
            in: activityController.window,
            page: "company person"
        )

        coordinator.selectReview(fixture.reviewID)
        try await settle(activityController.window)
        #expect(coordinator.selectedReview?.id == fixture.reviewID)
        assertAutomaticTopBarsAreSuppressed(
            in: activityController.window,
            page: "investment review"
        )

        coordinator.selectRun(fixture.runID)
        try await settle(activityController.window)
        #expect(coordinator.selectedRun?.id == fixture.runID)
        assertAutomaticTopBarsAreSuppressed(
            in: activityController.window,
            page: "agent turn"
        )
    }

    private func settle(_ window: NSWindow?) async throws {
        window?.setContentSize(NSSize(width: 900, height: 600))
        try await Task.sleep(for: .milliseconds(250))
    }

    private func assertAutomaticTopBarsAreSuppressed(
        in window: NSWindow?,
        page: String
    ) {
        guard let contentView = window?.contentView,
              let splitView = findSplitView(in: contentView) else {
            Issue.record("The \(page) page did not render inside a navigation split view")
            return
        }

        let visibleTopBars = splitView.subviews.filter {
            NSStringFromClass(type(of: $0)) == "NSTitlebarBackgroundView"
                && !$0.isHidden
                && $0.alphaValue > 0
                && $0.frame.width > 0
                && $0.frame.height > 0
        }
        #expect(visibleTopBars.isEmpty, "The \(page) page has a visible automatic top bar")
    }

    private func findSplitView(in view: NSView) -> NSSplitView? {
        if let splitView = view as? NSSplitView, splitView.isVertical {
            return splitView
        }
        for subview in view.subviews {
            if let splitView = findSplitView(in: subview) {
                return splitView
            }
        }
        return nil
    }
}

private struct RepositoryDetailPageFixture {
    let activity: ActivityRecord
    let personID: UUID
    let reviewID: UUID
    let runID: UUID
}

private func detailPageFixture() -> RepositoryDetailPageFixture {
    let target = AgentTarget(providerID: .codex, model: "fixture-model")
    let chiefExecutive = detailPagePerson(
        name: "Rhea Calder",
        positionID: .chiefExecutive,
        assignment: "Own the product goal and investment decisions."
    )
    let developer = detailPagePerson(
        name: "Eli Navarro",
        positionID: .developer,
        assignment: "Build and exercise the integrated product."
    )
    let member = LiveTeamMember(
        id: "developer",
        name: "Ship Product Value",
        instructions: developer.assignment,
        target: target,
        runPolicy: .everyCycle,
        sessionPolicy: .ownMemory,
        positionID: .developer,
        person: developer
    )
    let definition = LiveTeamDefinition(
        revision: 1,
        workingGoal: "Ship an integrated product slice.",
        members: [member],
        coordinator: .init(target: target, instructions: "Route direct product work."),
        strategicReason: "Put usable product evidence first.",
        operatingModelVersion: 2,
        overseerPerson: chiefExecutive,
        productBet: .init(
            headline: "Show the real product",
            valuePromise: "A user can experience the core value directly.",
            showcase: "An integrated demonstration",
            integrationTarget: "The main product",
            killCondition: "Stop if exercised work produces no visible value."
        )
    )
    let run = RunRecord(
        sequence: 1,
        role: .implementer,
        kind: .implementation,
        status: .completed,
        threadID: "fixture-session",
        model: target.model,
        effort: "high",
        prompt: member.instructions,
        transcript: "Implemented and exercised the product slice.",
        finalOutput: "The integrated product slice is ready.",
        completedAt: .now,
        liveTeamMember: .init(
            member: member,
            workingGoal: definition.workingGoal,
            revision: definition.revision,
            cycle: 1,
            sessionSlotID: "member:developer",
            productBet: definition.productBet
        )
    )
    let review = LiveTeamReviewRecord(
        mode: .strategicReview,
        trigger: "Review the return on the first product slice.",
        sourceRunID: run.id,
        baseRevision: definition.revision,
        status: .completed,
        consultations: [
            .init(
                id: developer.id,
                name: developer.profile.fullName,
                mandate: developer.assignment,
                status: .completed,
                involvement: "Built the product slice.",
                progress: "The slice is integrated and runnable.",
                evidence: "The product was exercised.",
                concern: "The next slice needs more depth.",
                nextMove: "Deepen the interaction."
            )
        ],
        decision: .init(
            outcome: .kept,
            summary: "Fund the next product slice.",
            reason: "The integrated result produced visible value.",
            evidence: "The product was exercised successfully."
        ),
        completedAt: .now
    )
    let activity = ActivityRecord(
        goal: "Build a product people want to use.",
        prompts: .builtInDefaults,
        status: .paused,
        runs: [run],
        liveTeam: .init(
            overseer: .init(target: target, instructions: "Own the goal."),
            currentDefinition: definition,
            reviews: [review],
            definitionHistory: [definition]
        )
    )
    return RepositoryDetailPageFixture(
        activity: activity,
        personID: developer.id,
        reviewID: review.id,
        runID: run.id
    )
}

private func detailPagePerson(
    name: String,
    positionID: CompanyPositionID,
    assignment: String
) -> CompanyPerson {
    CompanyPerson(
        positionID: positionID,
        profile: .init(
            fullName: name,
            background: "Built ambitious products with small teams.",
            formativeSuccess: "Shipped a product customers adopted.",
            formativeScar: "Watched ceremony displace delivery.",
            convictions: ["Working product wins.", "Visible value earns trust."],
            personalStake: "Wants this product to matter.",
            workingStyle: "Direct, energetic, and evidence hungry.",
            conflictStyle: "Challenges weak assumptions clearly.",
            blindSpot: "Can underestimate integration cost.",
            evidenceThatChangesTheirMind: "Observed user behavior.",
            ingredients: .init(
                spark: "A risky launch that worked",
                riskPosture: "bold reversible bets",
                conflictStyle: "direct",
                craftObsession: "visible value",
                ambition: "build the reference product"
            )
        ),
        assignment: assignment
    )
}
