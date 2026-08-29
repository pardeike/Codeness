import Foundation
import Testing
@testable import CodenessCore

struct CompanyHarnessV2FixtureTests {
    @Test
    func fixtureExercisesCreativeCompanyWithoutADeveloperDefault() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/CompanyHarnessV2")
        let brief = try String(
            contentsOf: fixture.appending(path: "COMPANY_BRIEF.md"),
            encoding: .utf8
        )
        #expect(brief.contains("Research, Product, Art, Sound, and Quality"))
        #expect(brief.contains("does not require software implementation"))

        let positions: [CompanyPositionID] = [
            .researcher, .productManager, .artDirector, .soundDesigner, .qaTester
        ]
        let contributions: [CompanyContributionKind] = [
            .researchFinding, .productDirection, .visualDirection,
            .audioDirection, .qualityAssessment
        ]
        let members = zip(positions, contributions).map { positionID, contribution in
            fixtureMember(positionID: positionID, contribution: contribution)
        }

        #expect(!members.contains { $0.positionID == .developer })
        for member in members {
            let snapshot = fixtureSnapshot(member)
            let prompt = LiveTeamPromptBuilder.memberPrompt(
                snapshot: snapshot,
                handoff: nil
            )
            #expect(prompt.contains("Required contribution: \(member.companyAssignment!.contributionKind.rawValue)"))
            #expect(!prompt.contains("Improve the repository's actual product"))
            #expect(!prompt.contains("Report concrete product changes"))
            #expect(!prompt.contains("prove the best one through the repository"))
            #expect(prompt.contains("complete authored work inline"))
            if member.positionID != .developer {
                #expect(!CompanyToolPolicy(positionID: member.positionID!).permitsSourceMutation)
            }
        }
    }

    @Test
    func fixtureHandoversCarryOnlyRecipientRelevantCompanyEvidence() throws {
        let researcher = fixtureMember(
            positionID: .researcher,
            contribution: .researchFinding
        )
        let productManager = fixtureMember(
            positionID: .productManager,
            contribution: .productDirection,
            dependencies: [.researchFinding]
        )
        let research = CompanyWorkReport(
            workerID: researcher.id,
            positionID: .researcher,
            contributionKind: .researchFinding,
            summary: "Visitors need an obvious first action and interruption-tolerant pacing.",
            artifacts: ["AUDIENCE_NOTES.md"],
            evidence: ["Pairs hesitate when the first action is unclear."],
            decisions: ["Prioritize a legible arrival cue."],
            constraints: ["Families may interrupt the sequence."],
            risks: ["Notes are directional, not observed validation."],
            capabilityBlock: nil,
            recommendedRecipientPositions: [.productManager]
        )
        let researchPacket = CompanyHandoffPacket(
            report: research,
            recipientPositionID: productManager.positionID,
            recipientAssignment: productManager.companyAssignment
        ).rendered
        #expect(researchPacket.contains("AUDIENCE_NOTES.md"))
        #expect(researchPacket.contains("obvious first action"))
        #expect(!researchPacket.localizedCaseInsensitiveContains("implement"))

        let artDirector = fixtureMember(
            positionID: .artDirector,
            contribution: .visualDirection
        )
        let soundDesigner = fixtureMember(
            positionID: .soundDesigner,
            contribution: .audioDirection,
            dependencies: [.visualDirection]
        )
        let art = CompanyWorkReport(
            workerID: artDirector.id,
            positionID: .artDirector,
            contributionKind: .visualDirection,
            summary: "Light moves from a narrow amber threshold through playful overlap to a broad blue release.",
            artifacts: ["VisualDirection.md"],
            evidence: ["All three states map to the fixed emotional sequence."],
            decisions: ["Use overlap, not brightness, for the curiosity peak."],
            constraints: ["The exit must stay visually calm.", "Transitions last 45 seconds."],
            risks: [],
            capabilityBlock: nil,
            recommendedRecipientPositions: [.soundDesigner]
        )
        let soundPacket = CompanyHandoffPacket(
            report: art,
            recipientPositionID: soundDesigner.positionID,
            recipientAssignment: soundDesigner.companyAssignment
        ).rendered
        #expect(soundPacket.contains("amber threshold"))
        #expect(soundPacket.contains("Transitions last 45 seconds"))
        #expect(!soundPacket.localizedCaseInsensitiveContains("program"))

        let qaTester = fixtureMember(
            positionID: .qaTester,
            contribution: .qualityAssessment,
            dependencies: [.researchFinding, .productDirection, .visualDirection, .audioDirection]
        )
        let sound = CompanyWorkReport(
            workerID: soundDesigner.id,
            positionID: .soundDesigner,
            contributionKind: .audioDirection,
            summary: "Sparse localized sound marks invitation, discovery, consequence, and release.",
            artifacts: ["Complete sound direction authored inline."],
            evidence: ["Every cue has a visual equivalent and preserves conversation."],
            decisions: ["Use real silence between the three sound zones."],
            constraints: ["Ordinary footsteps remain audible."],
            risks: ["Representative corridor playback remains unverified."],
            capabilityBlock: nil,
            recommendedRecipientPositions: [.qaTester]
        )
        let qaPacket = CompanyHandoffPacket(
            report: sound,
            recipientPositionID: qaTester.positionID,
            recipientAssignment: qaTester.companyAssignment
        ).rendered
        #expect(qaPacket.contains("Sparse localized sound"))
        #expect(!qaPacket.contains("outside the recipient's subscribed assignment dependencies"))
    }

    @Test
    func fixtureMakesMissingAudioProductionAnExecutiveEvent() throws {
        let soundDesigner = fixtureMember(
            positionID: .soundDesigner,
            contribution: .audioDirection
        )
        let snapshot = fixtureSnapshot(soundDesigner)
        let report = CompanyWorkReport(
            workerID: soundDesigner.id,
            positionID: .soundDesigner,
            contributionKind: .audioDirection,
            summary: "The three-state music direction is specified, but this target cannot render audio.",
            artifacts: ["AudioDirection.md"],
            evidence: ["Timing, register, density, and transition rules are complete."],
            decisions: ["Footsteps remain audible throughout."],
            constraints: ["No audio-production capability is available."],
            risks: [],
            capabilityBlock: CompanyCapabilityBlock(
                kind: .targetUnavailable,
                requiredCapability: .audioAssetProduction,
                detail: "The assigned target cannot synthesize or edit a playable asset.",
                artifacts: ["AudioDirection.md"],
                suggestedPositions: [.soundDesigner]
            ),
            recommendedRecipientPositions: [.chiefExecutive]
        )
        let output = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        let definition = fixtureDefinition(member: soundDesigner)

        let decision = CompanyProductMotor.decision(
            sourceResult: output,
            snapshot: snapshot,
            definition: definition,
            proposedCheckpoint: nil,
            runs: []
        )

        #expect(decision.disposition == .requestOversight)
        #expect(decision.handoff.contains("targetUnavailable / audioAssetProduction"))
        #expect(decision.handoff.contains("AudioDirection.md"))
        #expect(!decision.handoff.localizedCaseInsensitiveContains("write code"))
    }

    @Test
    func fixtureQualityHandoffIncludesEveryAssignedPredecessorContribution() throws {
        let researcher = fixtureMember(positionID: .researcher, contribution: .researchFinding)
        let product = fixtureMember(
            positionID: .productManager,
            contribution: .productDirection,
            dependencies: [.researchFinding]
        )
        let art = fixtureMember(
            positionID: .artDirector,
            contribution: .visualDirection,
            dependencies: [.productDirection]
        )
        let sound = fixtureMember(
            positionID: .soundDesigner,
            contribution: .audioDirection,
            dependencies: [.productDirection, .visualDirection]
        )
        let quality = fixtureMember(
            positionID: .qaTester,
            contribution: .qualityAssessment,
            dependencies: [.researchFinding, .productDirection, .visualDirection, .audioDirection]
        )
        var definition = fixtureDefinition(member: sound)
        definition.members = [researcher, product, art, sound, quality]
        let prior: [(LiveTeamMember, String)] = [
            (researcher, "Visitors need a recoverable first action."),
            (product, "The Waking Trail is the accepted corridor promise."),
            (art, "Warm arrival, cool discovery, and quiet release share one sightline.")
        ]
        let runs = prior.enumerated().map { index, item in
            let priorReport = CompanyWorkReport(
                workerID: item.0.id,
                positionID: item.0.positionID!,
                contributionKind: item.0.companyAssignment!.contributionKind,
                summary: item.1,
                artifacts: ["Complete inline predecessor work."],
                evidence: [item.1],
                decisions: [], constraints: [], risks: [],
                capabilityBlock: nil,
                recommendedRecipientPositions: []
            )
            return RunRecord(
                sequence: index + 1,
                role: .implementer,
                kind: .implementation,
                status: .completed,
                threadID: nil,
                model: item.0.target.model,
                effort: "low",
                prompt: "Profession-specific work.",
                finalOutput: String(
                    decoding: try! JSONEncoder().encode(priorReport),
                    as: UTF8.self
                ),
                startedAt: .now,
                liveTeamMember: fixtureSnapshot(item.0),
                coordinatorDecision: LiveTeamCoordinatorDecision(
                    handoff: "Summary: This contribution was redacted for an earlier recipient.",
                    runLabel: item.1,
                    disposition: .continueTeam,
                    evidence: "Accepted profession evidence.",
                    progressEvidence: .none
                )
            )
        }
        let soundReport = CompanyWorkReport(
            workerID: sound.id,
            positionID: .soundDesigner,
            contributionKind: .audioDirection,
            summary: "Sparse sound and silence follow the same three visual states.",
            artifacts: ["Complete inline sound direction."],
            evidence: ["Conversation remains intelligible."],
            decisions: ["Silence separates each localized zone."],
            constraints: [],
            risks: [],
            capabilityBlock: nil,
            recommendedRecipientPositions: [.qaTester]
        )
        let output = String(decoding: try JSONEncoder().encode(soundReport), as: UTF8.self)

        let decision = CompanyProductMotor.decision(
            sourceResult: output,
            snapshot: fixtureSnapshot(sound),
            definition: definition,
            proposedCheckpoint: LiveTeamCheckpoint(
                memberID: quality.id,
                cycle: 1,
                revision: definition.revision
            ),
            runs: runs
        )

        #expect(decision.handoff.contains("recoverable first action"))
        #expect(decision.handoff.contains("accepted corridor promise"))
        #expect(decision.handoff.contains("quiet release"))
        #expect(decision.handoff.contains("Sparse sound and silence"))
    }

    @Test
    func malformedCompanyReportCannotContinueAsAcceptedWork() {
        let researcher = fixtureMember(positionID: .researcher, contribution: .researchFinding)
        let product = fixtureMember(
            positionID: .productManager,
            contribution: .productDirection,
            dependencies: [.researchFinding]
        )
        var definition = fixtureDefinition(member: researcher)
        definition.members = [researcher, product]

        let decision = CompanyProductMotor.decision(
            sourceResult: "not a structured report",
            snapshot: fixtureSnapshot(researcher),
            definition: definition,
            proposedCheckpoint: LiveTeamCheckpoint(
                memberID: product.id,
                cycle: 1,
                revision: definition.revision
            ),
            runs: []
        )

        #expect(decision.disposition == .requestOversight)
        #expect(decision.evidence.contains("structured work-report contract"))
        #expect(decision.handoff.contains("not a structured report"))
    }

    @Test
    func aggregateCompanyHandoffKeepsCurrentWorkWithinSingleBound() throws {
        let sound = fixtureMember(
            positionID: .soundDesigner,
            contribution: .audioDirection,
            dependencies: [.researchFinding, .productDirection, .visualDirection]
        )
        let quality = fixtureMember(
            positionID: .qaTester,
            contribution: .qualityAssessment,
            dependencies: [.researchFinding, .productDirection, .visualDirection, .audioDirection]
        )
        var definition = fixtureDefinition(member: sound)
        let predecessors = [
            fixtureMember(positionID: .researcher, contribution: .researchFinding),
            fixtureMember(positionID: .productManager, contribution: .productDirection),
            fixtureMember(positionID: .artDirector, contribution: .visualDirection)
        ]
        definition.members = predecessors + [sound, quality]
        let runs = predecessors.enumerated().map { index, member in
            RunRecord(
                sequence: index + 1,
                role: .implementer,
                kind: .implementation,
                status: .completed,
                threadID: nil,
                model: member.target.model,
                effort: "low",
                prompt: "Profession-specific work.",
                startedAt: .now,
                liveTeamMember: fixtureSnapshot(member),
                coordinatorDecision: LiveTeamCoordinatorDecision(
                    handoff: "Contribution: \(member.companyAssignment!.contributionKind.rawValue)\n" + String(repeating: "prior evidence ", count: 600),
                    runLabel: "Prior evidence",
                    disposition: .continueTeam,
                    evidence: "Accepted profession evidence.",
                    progressEvidence: .none
                )
            )
        }
        let report = CompanyWorkReport(
            workerID: sound.id,
            positionID: .soundDesigner,
            contributionKind: .audioDirection,
            summary: "CURRENT SOUND DIRECTION",
            artifacts: [String(repeating: "current detail ", count: 600)],
            evidence: [], decisions: [], constraints: [], risks: [],
            capabilityBlock: nil,
            recommendedRecipientPositions: [.qaTester]
        )

        let decision = CompanyProductMotor.decision(
            sourceResult: String(decoding: try JSONEncoder().encode(report), as: UTF8.self),
            snapshot: fixtureSnapshot(sound),
            definition: definition,
            proposedCheckpoint: LiveTeamCheckpoint(memberID: quality.id, cycle: 1, revision: definition.revision),
            runs: runs
        )

        #expect(decision.handoff.count <= 6_000)
        #expect(decision.handoff.contains("CURRENT SOUND DIRECTION"))
        #expect(decision.handoff.contains("researchFinding"))
        #expect(decision.handoff.contains("productDirection"))
        #expect(decision.handoff.contains("visualDirection"))
    }
}

private func fixtureMember(
    positionID: CompanyPositionID,
    contribution: CompanyContributionKind,
    dependencies: [CompanyContributionKind] = []
) -> LiveTeamMember {
    let practice = CompanyPositionPracticeCatalog.practice(positionID)
    let person = CompanyPerson(
        positionID: positionID,
        profile: CompanyPersonaProfile(
            fullName: "\(CompanyPositionCatalog.position(positionID).title) Fixture",
            background: "Experienced in this exact profession.",
            formativeSuccess: "Delivered a clear, accepted specialist contribution.",
            formativeScar: "Saw generic teamwork erase important craft boundaries.",
            convictions: [
                "Specialist evidence beats generic activity.",
                "Clear boundaries make collaboration faster.",
                "Another profession's work deserves a real owner."
            ],
            personalStake: "Wants Lantern Passage to feel coherent.",
            workingStyle: "Direct, specific, and evidence-led.",
            conflictStyle: "Names craft disagreements plainly.",
            blindSpot: "Can overprotect the profession boundary.",
            evidenceThatChangesTheirMind: "A stronger accepted specialist artifact.",
            ingredients: .init(
                spark: "a museum experience that worked without instructions",
                riskPosture: "bold reversible bets",
                conflictStyle: "direct and exacting",
                craftObsession: "coherent specialist contributions",
                ambition: "make the experience memorable"
            )
        ),
        assignment: "Own the \(contribution.rawValue) contribution for Lantern Passage."
    )
    return LiveTeamMember(
        id: positionID.rawValue,
        name: "Own \(contribution.rawValue)",
        instructions: person.assignment,
        target: fixtureTarget(),
        runPolicy: .once,
        sessionPolicy: .ownMemory,
        positionID: positionID,
        person: person,
        companyAssignment: CompanyAssignmentContract(
            contributionKind: contribution,
            requiredCapabilities: practice.allowedCapabilities
                .filter { [.workspaceRead, .webResearch].contains($0) }
                .sorted { $0.rawValue < $1.rawValue },
            acceptanceEvidence: practice.acceptanceEvidence,
            dependencyContributionKinds: dependencies,
            stopCondition: "Stop when the contribution is accepted or report a capability block."
        )
    )
}

private func fixtureSnapshot(_ member: LiveTeamMember) -> LiveTeamMemberSnapshot {
    LiveTeamMemberSnapshot(
        member: member,
        workingGoal: "Define a coherent, testable Lantern Passage experience.",
        revision: 1,
        cycle: 1,
        sessionSlotID: "member:\(member.id)"
    )
}

private func fixtureDefinition(member: LiveTeamMember) -> LiveTeamDefinition {
    let chiefExecutive = fixtureMember(
        positionID: .chiefExecutive,
        contribution: .executiveDecision
    ).person!
    return LiveTeamDefinition(
        revision: 1,
        workingGoal: "Define a coherent, testable Lantern Passage experience.",
        members: [member],
        coordinator: .init(target: fixtureTarget(), instructions: "Route typed contributions."),
        strategicReason: "Exercise profession-specific company collaboration.",
        operatingModelVersion: 2,
        overseerPerson: chiefExecutive,
        productBet: CompanyProductBet(
            headline: "Lantern Passage direction",
            valuePromise: "Visitors understand and enjoy a screen-free corridor experience.",
            audience: "Small-museum visitors",
            focusQuestion: "Is the first action legible without instructions?",
            showcase: "A coherent visual, audio, and acceptance package",
            integrationTarget: "The three-moment corridor journey",
            killCondition: "Stop if the directions cannot coexist within the fixed space."
        )
    )
}

private func fixtureTarget() -> AgentTarget {
    AgentTarget(
        providerID: .codex,
        model: "fixture-low-token-model",
        options: .init(effort: "low", mode: .standard, speed: .standard)
    )
}
