import Foundation

public enum CompanyCapability: String, Codable, CaseIterable, Sendable {
    case workspaceRead
    case webResearch
    case authoredArtifactWrite
    case sourceModification
    case commandExecution
    case productUIOperation
    case visualAssetProduction
    case audioAssetProduction
    case engineeringAssetProduction
    case externalCommunication
    case publishingMutation
    case irreversibleExternalMutation
}

public enum CompanyContributionKind: String, Codable, CaseIterable, Sendable {
    case executiveDecision
    case productDirection
    case deliveryCoordination
    case softwareImplementation
    case productDesign
    case researchFinding
    case qualityAssessment
    case operationsPlan
    case technicalDirection
    case interactionDesign
    case releaseEvidence
    case visualDirection
    case writtenContent
    case editorialRevision
    case audioDirection
    case researchPlan
    case dataAnalysis
    case factCheck
    case industrialDesign
    case mechanicalDesign
    case fabricationResult
    case conformanceReport
    case marketPositioning
    case salesEvidence
    case customerInsight
    case financialAnalysis
    case supportInsight
    case unstructured
}

public struct CompanyPositionPractice: Equatable, Sendable {
    public let positionID: CompanyPositionID
    public let purpose: String
    public let allowedContributions: Set<CompanyContributionKind>
    public let acceptanceEvidence: String
    public let subscribedContributions: Set<CompanyContributionKind>
    public let allowedCapabilities: Set<CompanyCapability>
    public let completionCondition: String
    public let escalationCondition: String

    public init(
        positionID: CompanyPositionID,
        purpose: String,
        allowedContributions: Set<CompanyContributionKind>,
        acceptanceEvidence: String,
        subscribedContributions: Set<CompanyContributionKind>,
        allowedCapabilities: Set<CompanyCapability>,
        completionCondition: String,
        escalationCondition: String
    ) {
        self.positionID = positionID
        self.purpose = purpose
        self.allowedContributions = allowedContributions
        self.acceptanceEvidence = acceptanceEvidence
        self.subscribedContributions = subscribedContributions
        self.allowedCapabilities = allowedCapabilities
        self.completionCondition = completionCondition
        self.escalationCondition = escalationCondition
    }

    public var forbiddenCapabilities: Set<CompanyCapability> {
        Set(CompanyCapability.allCases).subtracting(allowedCapabilities)
    }

    public var promptContract: String {
        let contributions = allowedContributions.map(\.rawValue).sorted().joined(separator: ", ")
        let capabilities = allowedCapabilities.map(\.rawValue).sorted().joined(separator: ", ")
        let forbidden = forbiddenCapabilities.map(\.rawValue).sorted().joined(separator: ", ")
        return """
        PROFESSION CONTRACT

        Purpose: \(purpose)
        Contributions you own: \(contributions)
        Evidence that counts: \(acceptanceEvidence)
        Tools and effects available to this profession: \(capabilities)
        Do not silently take on: \(forbidden)
        You are done when: \(completionCondition)
        Escalate when: \(escalationCondition)
        """
    }
}

public struct CompanyToolPolicy: Equatable, Sendable {
    public let positionID: CompanyPositionID

    public init(positionID: CompanyPositionID) {
        self.positionID = positionID
    }

    public var allowedCapabilities: Set<CompanyCapability> {
        CompanyPositionPracticeCatalog.practice(positionID).allowedCapabilities
    }

    public var id: String {
        let capabilities = allowedCapabilities.map(\.rawValue).sorted()
            .joined(separator: "+")
        return "\(positionID.rawValue):\(capabilities)"
    }

    public var permitsSourceMutation: Bool {
        allowedCapabilities.contains(.sourceModification)
    }

    public var permitsWebResearch: Bool {
        allowedCapabilities.contains(.webResearch)
    }

    public var requiresReadOnlySandbox: Bool {
        !permitsSourceMutation
    }

    public var claudeToolNames: [String] {
        var tools: [String] = []
        if allowedCapabilities.contains(.workspaceRead) {
            tools += ["Read", "Glob", "Grep"]
        }
        if allowedCapabilities.contains(.webResearch) {
            tools += ["WebSearch", "WebFetch"]
        }
        if allowedCapabilities.contains(.commandExecution), permitsSourceMutation {
            tools.append("Bash")
        }
        if allowedCapabilities.contains(.sourceModification) {
            tools += ["Edit", "Write"]
        }
        return tools
    }

    public var openAICompatibleToolNames: Set<String> {
        var tools: Set<String> = []
        if allowedCapabilities.contains(.workspaceRead) {
            tools.formUnion(["read", "glob", "grep"])
        }
        if allowedCapabilities.contains(.commandExecution), permitsSourceMutation {
            tools.insert("bash")
        }
        if allowedCapabilities.contains(.sourceModification) {
            tools.formUnion(["edit", "write"])
        }
        return tools
    }
}

public struct CompanyAssignmentContract: Codable, Equatable, Sendable {
    public let contributionKind: CompanyContributionKind
    public let requiredCapabilities: [CompanyCapability]
    public let acceptanceEvidence: String
    public let dependencyContributionKinds: [CompanyContributionKind]
    public let stopCondition: String

    public init(
        contributionKind: CompanyContributionKind,
        requiredCapabilities: [CompanyCapability],
        acceptanceEvidence: String,
        dependencyContributionKinds: [CompanyContributionKind],
        stopCondition: String
    ) {
        self.contributionKind = contributionKind
        self.requiredCapabilities = requiredCapabilities
        self.acceptanceEvidence = acceptanceEvidence
        self.dependencyContributionKinds = dependencyContributionKinds
        self.stopCondition = stopCondition
    }

    public func validationMessage(
        positionID: CompanyPositionID,
        target: AgentTarget
    ) -> String? {
        let practice = CompanyPositionPracticeCatalog.practice(positionID)
        guard practice.allowedContributions.contains(contributionKind) else {
            return "\(CompanyPositionCatalog.position(positionID).title) cannot own \(contributionKind.rawValue)."
        }
        let requested = Set(requiredCapabilities)
        guard requested.count == requiredCapabilities.count else {
            return "The assignment repeats a required capability."
        }
        guard Set(dependencyContributionKinds).count == dependencyContributionKinds.count else {
            return "The assignment repeats a predecessor contribution dependency."
        }
        guard requested.isSubset(of: practice.allowedCapabilities) else {
            let forbidden = requested.subtracting(practice.allowedCapabilities)
                .map(\.rawValue).sorted().joined(separator: ", ")
            return "\(CompanyPositionCatalog.position(positionID).title) cannot use required capabilities: \(forbidden)."
        }
        let targetCapabilities = CompanyTargetCapabilityProfile(target: target).capabilities
        guard requested.isSubset(of: targetCapabilities) else {
            let unavailable = requested.subtracting(targetCapabilities)
                .map(\.rawValue).sorted().joined(separator: ", ")
            return "Target \(target.providerID.rawValue)/\(target.model) cannot supply required capabilities: \(unavailable)."
        }
        if acceptanceEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The assignment has no acceptance evidence."
        }
        if stopCondition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The assignment has no stopping or capability-block condition."
        }
        return nil
    }

    public var promptContract: String {
        let capabilities = requiredCapabilities.map(\.rawValue).joined(separator: ", ")
        let dependencies = dependencyContributionKinds.map(\.rawValue).joined(separator: ", ")
        return """
        ASSIGNMENT CONTRACT

        Required contribution: \(contributionKind.rawValue)
        Required capabilities: \(capabilities.isEmpty ? "none" : capabilities)
        Acceptance evidence: \(acceptanceEvidence)
        Relevant predecessor contributions: \(dependencies.isEmpty ? "none" : dependencies)
        Stop or block when: \(stopCondition)
        """
    }
}

public struct CompanyTargetCapabilityProfile: Equatable, Sendable {
    public let capabilities: Set<CompanyCapability>

    public init(target: AgentTarget) {
        var capabilities: Set<CompanyCapability> = [.workspaceRead]
        if target.providerID == .codex || target.providerID == .claude {
            capabilities.insert(.webResearch)
        }
        if target.options.mode != .plan {
            capabilities.formUnion([.sourceModification, .commandExecution])
        }
        self.capabilities = capabilities
    }

    public var promptDescription: String {
        capabilities.map(\.rawValue).sorted().joined(separator: ", ")
    }
}

public enum CompanyPositionPracticeCatalog {
    private static let readWrite: Set<CompanyCapability> = [.workspaceRead, .authoredArtifactWrite]
    private static let research: Set<CompanyCapability> = [.workspaceRead, .webResearch, .authoredArtifactWrite]
    private static let productInspection: Set<CompanyCapability> = [.workspaceRead, .productUIOperation, .authoredArtifactWrite]

    public static let practices: [CompanyPositionPractice] = [
        practice(
            .chiefExecutive,
            "Company thesis, investment decisions, staffing, and acceptance conditions.",
            [.executiveDecision],
            "A funded decision with explicit evidence, tradeoffs, staffing, and stop conditions.",
            [.productDirection, .deliveryCoordination, .researchFinding, .qualityAssessment, .operationsPlan, .technicalDirection, .releaseEvidence, .visualDirection, .audioDirection, .dataAnalysis, .marketPositioning, .salesEvidence, .customerInsight, .financialAnalysis, .supportInsight],
            [.workspaceRead],
            "the company has a clear funded decision and the right accountable professions",
            "evidence invalidates the bet or the company lacks a profession or target with a required capability"
        ),
        practice(
            .productManager,
            "User problems, product priority, requirements, and acceptance decisions.",
            [.productDirection],
            "A decision-ready product brief tied to user evidence and observable acceptance criteria.",
            [.researchFinding, .qualityAssessment, .interactionDesign, .dataAnalysis, .marketPositioning, .salesEvidence, .customerInsight, .supportInsight],
            research,
            "a maker can act without inventing the user problem, priority, or acceptance rule",
            "the work requires implementation, specialist craft, or customer contact outside the assignment"
        ),
        practice(
            .producer,
            "Delivery sequencing, dependencies, and readiness across the hired company.",
            [.deliveryCoordination],
            "A dependency-aware delivery decision grounded in actual contribution state.",
            [.productDirection, .softwareImplementation, .productDesign, .qualityAssessment, .visualDirection, .audioDirection, .releaseEvidence, .fabricationResult, .conformanceReport],
            readWrite,
            "owners, dependencies, and the next delivery boundary are explicit",
            "a missing craft or blocked capability needs a staffing decision"
        ),
        practice(
            .developer,
            "Working software behavior and technical integration.",
            [.softwareImplementation],
            "Changed behavior with focused build or test evidence and inspectable source artifacts.",
            [.productDirection, .qualityAssessment, .technicalDirection, .interactionDesign, .visualDirection, .audioDirection, .releaseEvidence, .supportInsight],
            [.workspaceRead, .sourceModification, .commandExecution, .productUIOperation],
            "the assigned behavior works and focused verification covers the changed path",
            "the next required result belongs to design, audio, research, product, release, or another profession"
        ),
        practice(
            .designer,
            "Product behavior, form, and system design expressed as an inspectable design artifact.",
            [.productDesign],
            "A coherent design artifact with rationale, constraints, and acceptance cues.",
            [.productDirection, .researchFinding, .qualityAssessment, .customerInsight, .technicalDirection],
            productInspection.union([.visualAssetProduction]),
            "the intended experience and the artifact another specialist should implement are concrete",
            "the assignment requires source implementation, audio production, or physical engineering"
        ),
        practice(
            .researcher,
            "Sourced findings that reduce uncertainty for a named company decision.",
            [.researchFinding],
            "Traceable sources, findings, uncertainty, and a stated decision implication.",
            [.productDirection, .researchPlan, .dataAnalysis, .factCheck, .customerInsight],
            research,
            "the research question is answered to the stated confidence or its uncertainty is bounded",
            "answering requires implementation, unapproved contact, or a specialist method not available"
        ),
        practice(
            .qaTester,
            "Product behavior verification, reproduction, and acceptance judgment.",
            [.qualityAssessment],
            "Reproduction steps, expected and observed behavior, environment, and verdict.",
            [.productDirection, .softwareImplementation, .productDesign, .interactionDesign,
             .researchFinding, .visualDirection, .audioDirection, .releaseEvidence],
            [.workspaceRead, .commandExecution, .productUIOperation],
            "the assigned behavior has a reproducible acceptance verdict",
            "a defect needs implementation or the environment cannot exercise the promised behavior"
        ),
        practice(
            .operationsManager,
            "Reliable operating procedures and observed process control.",
            [.operationsPlan],
            "An executable operating procedure with ownership, signals, and failure handling.",
            [.deliveryCoordination, .qualityAssessment, .releaseEvidence, .supportInsight],
            productInspection.union([.commandExecution]),
            "the operation has an owner, trigger, observable result, and recovery path",
            "the remedy requires source changes, publishing, or another profession's craft"
        ),
        practice(
            .technicalLead,
            "Technical direction, system boundaries, integration choices, and code acceptance.",
            [.technicalDirection],
            "A concrete technical decision supported by source inspection and focused verification.",
            [.productDirection, .softwareImplementation, .qualityAssessment, .releaseEvidence, .supportInsight],
            [.workspaceRead, .commandExecution, .authoredArtifactWrite],
            "the implementing profession has an unambiguous technical boundary and acceptance rule",
            "the decision requires product authority or direct implementation outside this assignment"
        ),
        practice(
            .uxDesigner,
            "User flows, interaction behavior, accessibility, and usability evidence.",
            [.interactionDesign],
            "An inspectable flow or prototype with states, accessibility needs, and user evidence.",
            [.productDirection, .researchFinding, .qualityAssessment, .customerInsight, .supportInsight],
            productInspection.union([.visualAssetProduction]),
            "the user flow and its acceptance states are concrete enough to implement and test",
            "the work requires source implementation, art direction, or unapproved user contact"
        ),
        practice(
            .releaseEngineer,
            "Reproducible packaging, signing, artifact integrity, and release readiness.",
            [.releaseEvidence],
            "A reproducible artifact with build, signature, package, and readiness evidence.",
            [.softwareImplementation, .qualityAssessment, .deliveryCoordination, .operationsPlan],
            [.workspaceRead, .commandExecution],
            "the release artifact is reproducible and its integrity and readiness are proven",
            "publishing lacks authorization or a product defect requires another profession"
        ),
        practice(
            .artDirector,
            "Visual direction and visual asset acceptance.",
            [.visualDirection],
            "Inspectable visual direction or assets with composition, style, hierarchy, and acceptance rationale.",
            [.productDirection, .productDesign, .interactionDesign, .researchFinding, .qualityAssessment, .marketPositioning],
            productInspection.union([.visualAssetProduction]),
            "the visual intent is embodied in inspectable direction or assets and acceptance is explicit",
            "the next step requires programming, audio production, or another unavailable specialist capability"
        ),
        practice(
            .writer,
            "Audience-appropriate canonical prose and narrative content.",
            [.writtenContent],
            "Finished prose matched to the named audience, purpose, voice, and source constraints.",
            [.productDirection, .researchFinding, .factCheck, .editorialRevision, .marketPositioning, .customerInsight],
            readWrite.union([.webResearch]),
            "the requested text is complete, sourced where needed, and ready for its intended channel",
            "the work requires visual, audio, code, publication, or facts that cannot be established"
        ),
        practice(
            .editor,
            "Clarity, consistency, correctness, and voice in existing content.",
            [.editorialRevision],
            "A traceable revision that preserves meaning while meeting the canonical voice and accuracy bar.",
            [.writtenContent, .factCheck, .productDirection, .researchFinding, .marketPositioning],
            readWrite,
            "the supplied corpus is consistent, clear, and ready for its audience",
            "the requested change requires new reporting, visual craft, implementation, or publication"
        ),
        practice(
            .soundDesigner,
            "Audio and music direction, produced sound assets, and audio acceptance.",
            [.audioDirection],
            "Playable audio direction or assets with timing, mood, integration constraints, and acceptance rationale.",
            [.productDirection, .productDesign, .interactionDesign, .visualDirection, .qualityAssessment],
            [.workspaceRead, .authoredArtifactWrite, .productUIOperation, .audioAssetProduction],
            "the audio intent is playable or specified precisely enough for integration and acceptance",
            "the next step requires programming, visual production, or an unavailable audio capability"
        ),
        practice(
            .researchLead,
            "Research questions, methods, evidence synthesis, and confidence judgments.",
            [.researchPlan],
            "A decision-linked method and synthesis with source quality, confidence, and stopping rules.",
            [.productDirection, .researchFinding, .dataAnalysis, .factCheck, .customerInsight],
            research,
            "the research program can answer the decision with explicit evidence and confidence rules",
            "the company lacks data, access, consent, or a specialist needed by the method"
        ),
        practice(
            .dataAnalyst,
            "Reproducible analysis and interpretation of supplied data.",
            [.dataAnalysis],
            "A reproducible calculation or dataset result with assumptions and decision-relevant interpretation.",
            [.researchPlan, .researchFinding, .productDirection, .financialAnalysis, .customerInsight],
            [.workspaceRead, .commandExecution, .authoredArtifactWrite],
            "the analysis is reproducible and answers the stated question without hiding uncertainty",
            "required data is missing, invalid, unauthorized, or needs collection by another profession"
        ),
        practice(
            .factChecker,
            "Source-backed verification of consequential claims.",
            [.factCheck],
            "A claim ledger with sources, verdicts, qualifications, and unresolved evidence gaps.",
            [.writtenContent, .researchFinding, .dataAnalysis, .marketPositioning, .salesEvidence],
            [.workspaceRead, .webResearch, .authoredArtifactWrite],
            "each assigned claim has a supported verdict or an explicit unresolved status",
            "verification requires inaccessible evidence, unapproved contact, or rewriting beyond a correction"
        ),
        practice(
            .industrialDesigner,
            "Physical form, ergonomics, materials, and manufacturability intent.",
            [.industrialDesign],
            "An inspectable physical-design artifact with dimensions, materials, use context, and acceptance rationale.",
            [.productDirection, .researchFinding, .customerInsight, .mechanicalDesign, .conformanceReport],
            [.workspaceRead, .authoredArtifactWrite, .visualAssetProduction, .engineeringAssetProduction],
            "the physical form and its user and manufacturing constraints are concrete",
            "the next step requires mechanical proof, fabrication, software, or unavailable CAD capability"
        ),
        practice(
            .mechanicalEngineer,
            "Mechanical specifications, calculations, models, and validation decisions.",
            [.mechanicalDesign],
            "An engineering model or specification with calculations, tolerances, assumptions, and validation evidence.",
            [.industrialDesign, .researchFinding, .fabricationResult, .conformanceReport, .productDirection],
            [.workspaceRead, .commandExecution, .authoredArtifactWrite, .engineeringAssetProduction],
            "the mechanical design meets stated loads, interfaces, tolerances, and validation criteria",
            "the work requires fabrication, industrial redesign, software, or unavailable engineering tools"
        ),
        practice(
            .fabricator,
            "Physical production execution and evidence from the built result.",
            [.fabricationResult],
            "A fabrication artifact or build record tied to supplied drawings, materials, and tolerances.",
            [.industrialDesign, .mechanicalDesign, .deliveryCoordination, .conformanceReport],
            [.workspaceRead, .authoredArtifactWrite, .engineeringAssetProduction],
            "the assigned physical result is produced or its fabrication failure is precisely evidenced",
            "drawings are unsafe or incomplete, tolerances conflict, or engineering redesign is required"
        ),
        practice(
            .qaTechnician,
            "Measured conformance of physical or technical outputs.",
            [.conformanceReport],
            "A measurement record with method, equipment, tolerance, result, and verdict.",
            [.industrialDesign, .mechanicalDesign, .fabricationResult, .qualityAssessment],
            [.workspaceRead, .commandExecution, .authoredArtifactWrite, .engineeringAssetProduction],
            "the assigned characteristics have measured pass or fail verdicts",
            "measurement is impossible, unsafe, or requires repair or redesign by another profession"
        ),
        practice(
            .marketingManager,
            "Audience positioning, campaign decisions, and marketing assets.",
            [.marketPositioning],
            "A specific audience, defensible promise, channel decision, and inspectable campaign content.",
            [.productDirection, .researchFinding, .factCheck, .writtenContent, .visualDirection, .customerInsight, .salesEvidence],
            research.union([.visualAssetProduction]),
            "the position and campaign are grounded in product truth and ready for authorized production",
            "claims lack evidence, the product promise is unclear, or publication needs authorization"
        ),
        practice(
            .salesManager,
            "Commercial qualification, offer design, and objection evidence.",
            [.salesEvidence],
            "A qualified sales hypothesis with offer, objections, evidence, and a bounded next decision.",
            [.productDirection, .marketPositioning, .customerInsight, .financialAnalysis, .supportInsight],
            research,
            "the offer and qualification decision are grounded in evidence rather than invented outreach",
            "the work requires unapproved contact, pricing authority, spending, or a product change"
        ),
        practice(
            .customerResearcher,
            "Customer research methods, observations, and synthesized needs.",
            [.customerInsight],
            "A consent-respecting protocol or evidence synthesis with observations separated from interpretation.",
            [.productDirection, .researchPlan, .researchFinding, .salesEvidence, .supportInsight],
            research,
            "customer evidence answers the stated decision without overstating the sample",
            "contact lacks authorization or consent, or the finding needs product implementation"
        ),
        practice(
            .financeManager,
            "Cost models, budgets, runway, and investment analysis.",
            [.financialAnalysis],
            "A reproducible financial model with assumptions, sensitivity, and a decision implication.",
            [.executiveDecision, .productDirection, .deliveryCoordination, .dataAnalysis, .marketPositioning, .salesEvidence],
            [.workspaceRead, .commandExecution, .authoredArtifactWrite],
            "the financial decision has a traceable model and material uncertainty is explicit",
            "the work requires spending, account mutation, inaccessible records, or executive authority"
        ),
        practice(
            .customerSupportLead,
            "Support diagnosis, customer response design, escalation, and recurring-problem evidence.",
            [.supportInsight],
            "A reproducible support diagnosis with customer-safe response, evidence, and correct escalation owner.",
            [.productDirection, .qualityAssessment, .releaseEvidence, .customerInsight, .salesEvidence],
            productInspection,
            "the issue is diagnosed, the response is accurate, and the correct owner has actionable evidence",
            "a source fix, external reply, refund, publication, or another profession's authority is required"
        )
    ]

    public static func practice(_ positionID: CompanyPositionID) -> CompanyPositionPractice {
        guard let practice = practices.first(where: { $0.positionID == positionID }) else {
            preconditionFailure("Missing company position practice: \(positionID.rawValue)")
        }
        return practice
    }

    public static var promptCatalog: String {
        practices.map { practice in
            let position = CompanyPositionCatalog.position(practice.positionID)
            let contributions = practice.allowedContributions.map(\.rawValue).sorted()
                .joined(separator: ", ")
            let capabilities = practice.allowedCapabilities.map(\.rawValue).sorted()
                .joined(separator: ", ")
            return "\(position.title) owns \(contributions). Evidence: \(practice.acceptanceEvidence) Capabilities: \(capabilities)"
        }.joined(separator: "\n")
    }

    private static func practice(
        _ positionID: CompanyPositionID,
        _ purpose: String,
        _ contributions: Set<CompanyContributionKind>,
        _ evidence: String,
        _ subscriptions: Set<CompanyContributionKind>,
        _ capabilities: Set<CompanyCapability>,
        _ completion: String,
        _ escalation: String
    ) -> CompanyPositionPractice {
        CompanyPositionPractice(
            positionID: positionID,
            purpose: purpose,
            allowedContributions: contributions,
            acceptanceEvidence: evidence,
            subscribedContributions: subscriptions,
            allowedCapabilities: capabilities,
            completionCondition: completion,
            escalationCondition: escalation
        )
    }
}
