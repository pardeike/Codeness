import Foundation

public enum CompanySector: String, Codable, CaseIterable, Sendable {
    case universal
    case software
    case creativeMedia
    case researchData
    case physicalProduct
    case businessMarket

    public var displayName: String {
        switch self {
        case .universal: "Universal"
        case .software: "Software"
        case .creativeMedia: "Creative and Media"
        case .researchData: "Research and Data"
        case .physicalProduct: "Physical Product"
        case .businessMarket: "Business and Market"
        }
    }
}

public enum CompanyPositionID: String, Codable, CaseIterable, Sendable {
    case chiefExecutive
    case productManager
    case producer
    case developer
    case designer
    case researcher
    case qaTester
    case operationsManager
    case technicalLead
    case uxDesigner
    case releaseEngineer
    case artDirector
    case writer
    case editor
    case soundDesigner
    case researchLead
    case dataAnalyst
    case factChecker
    case industrialDesigner
    case mechanicalEngineer
    case fabricator
    case qaTechnician
    case marketingManager
    case salesManager
    case customerResearcher
    case financeManager
    case customerSupportLead
}

public struct CompanyPosition: Codable, Equatable, Identifiable, Sendable {
    public let id: CompanyPositionID
    public let title: String
    public let sector: CompanySector

    public init(id: CompanyPositionID, title: String, sector: CompanySector) {
        self.id = id
        self.title = title
        self.sector = sector
    }
}

public enum CompanyPositionCatalog {
    public static let positions: [CompanyPosition] = [
        .init(id: .chiefExecutive, title: "CEO", sector: .universal),
        .init(id: .productManager, title: "Product Manager", sector: .universal),
        .init(id: .producer, title: "Producer", sector: .universal),
        .init(id: .developer, title: "Developer", sector: .universal),
        .init(id: .designer, title: "Designer", sector: .universal),
        .init(id: .researcher, title: "Researcher", sector: .universal),
        .init(id: .qaTester, title: "QA Tester", sector: .universal),
        .init(id: .operationsManager, title: "Operations Manager", sector: .universal),
        .init(id: .technicalLead, title: "Technical Lead", sector: .software),
        .init(id: .uxDesigner, title: "UX Designer", sector: .software),
        .init(id: .releaseEngineer, title: "Release Engineer", sector: .software),
        .init(id: .artDirector, title: "Art Director", sector: .creativeMedia),
        .init(id: .writer, title: "Writer", sector: .creativeMedia),
        .init(id: .editor, title: "Editor", sector: .creativeMedia),
        .init(id: .soundDesigner, title: "Sound Designer", sector: .creativeMedia),
        .init(id: .researchLead, title: "Research Lead", sector: .researchData),
        .init(id: .dataAnalyst, title: "Data Analyst", sector: .researchData),
        .init(id: .factChecker, title: "Fact Checker", sector: .researchData),
        .init(id: .industrialDesigner, title: "Industrial Designer", sector: .physicalProduct),
        .init(id: .mechanicalEngineer, title: "Mechanical Engineer", sector: .physicalProduct),
        .init(id: .fabricator, title: "Fabricator", sector: .physicalProduct),
        .init(id: .qaTechnician, title: "QA Technician", sector: .physicalProduct),
        .init(id: .marketingManager, title: "Marketing Manager", sector: .businessMarket),
        .init(id: .salesManager, title: "Sales Manager", sector: .businessMarket),
        .init(id: .customerResearcher, title: "Customer Researcher", sector: .businessMarket),
        .init(id: .financeManager, title: "Finance Manager", sector: .businessMarket),
        .init(id: .customerSupportLead, title: "Customer Support Lead", sector: .businessMarket)
    ]

    public static func position(_ id: CompanyPositionID) -> CompanyPosition {
        guard let position = positions.first(where: { $0.id == id }) else {
            preconditionFailure("Missing predefined company position: \(id.rawValue)")
        }
        return position
    }

    public static var promptCatalog: String {
        Dictionary(grouping: positions, by: \CompanyPosition.sector)
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { sector, positions in
                "\(sector.displayName): " + positions.map {
                    "\($0.id.rawValue)=\($0.title)"
                }.joined(separator: ", ")
            }
            .joined(separator: "\n")
    }
}

public struct CompanyPersonaIngredients: Codable, Equatable, Sendable {
    public let spark: String
    public let riskPosture: String
    public let conflictStyle: String
    public let craftObsession: String
    public let ambition: String
    public let nonce: UUID

    public init(
        spark: String,
        riskPosture: String,
        conflictStyle: String,
        craftObsession: String,
        ambition: String,
        nonce: UUID = UUID()
    ) {
        self.spark = spark
        self.riskPosture = riskPosture
        self.conflictStyle = conflictStyle
        self.craftObsession = craftObsession
        self.ambition = ambition
        self.nonce = nonce
    }

    public static func random<R: RandomNumberGenerator>(using generator: inout R) -> Self {
        func pick(_ values: [String]) -> String {
            values[Int.random(in: values.indices, using: &generator)]
        }
        return Self(
            spark: pick([
                "a breakthrough shipped before anyone thought it was ready",
                "a beloved product rescued from timid consensus",
                "a public failure caused by polishing the wrong thing",
                "a tiny prototype that unexpectedly changed an industry",
                "a customer reaction that made the whole team rethink the product"
            ]),
            riskPosture: pick([
                "bold reversible bets", "fast public proof", "technical daring",
                "sharp scope with extravagant execution", "contrarian customer bets"
            ]),
            conflictStyle: pick([
                "direct and energetic", "playfully provocative", "calm but immovable",
                "show-don't-tell competitive", "warm, impatient, and exacting"
            ]),
            craftObsession: pick([
                "delight visible in seconds", "surprising interaction",
                "a product people ask to use again", "elegant working systems",
                "a distinctive point of view"
            ]),
            ambition: pick([
                "make the category feel obsolete", "ship the story people retell",
                "turn skeptics into advocates", "build the reference product",
                "make the result impossible to ignore"
            ]),
            nonce: randomUUID(using: &generator)
        )
    }

    public static func random() -> Self {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    private static func randomUUID<R: RandomNumberGenerator>(
        using generator: inout R
    ) -> UUID {
        let high = generator.next()
        let low = generator.next()
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: high >> 56),
            UInt8(truncatingIfNeeded: high >> 48),
            UInt8(truncatingIfNeeded: high >> 40),
            UInt8(truncatingIfNeeded: high >> 32),
            UInt8(truncatingIfNeeded: high >> 24),
            UInt8(truncatingIfNeeded: high >> 16),
            UInt8(truncatingIfNeeded: high >> 8),
            UInt8(truncatingIfNeeded: high),
            UInt8(truncatingIfNeeded: low >> 56),
            UInt8(truncatingIfNeeded: low >> 48),
            UInt8(truncatingIfNeeded: low >> 40),
            UInt8(truncatingIfNeeded: low >> 32),
            UInt8(truncatingIfNeeded: low >> 24),
            UInt8(truncatingIfNeeded: low >> 16),
            UInt8(truncatingIfNeeded: low >> 8),
            UInt8(truncatingIfNeeded: low)
        ))
    }
}

public struct CompanyPersonaProfile: Codable, Equatable, Sendable {
    public var fullName: String
    public var background: String
    public var formativeSuccess: String
    public var formativeScar: String
    public var convictions: [String]
    public var personalStake: String
    public var workingStyle: String
    public var conflictStyle: String
    public var blindSpot: String
    public var evidenceThatChangesTheirMind: String
    public var ingredients: CompanyPersonaIngredients

    public init(
        fullName: String,
        background: String,
        formativeSuccess: String,
        formativeScar: String,
        convictions: [String],
        personalStake: String,
        workingStyle: String,
        conflictStyle: String,
        blindSpot: String,
        evidenceThatChangesTheirMind: String,
        ingredients: CompanyPersonaIngredients
    ) {
        self.fullName = fullName
        self.background = background
        self.formativeSuccess = formativeSuccess
        self.formativeScar = formativeScar
        self.convictions = convictions
        self.personalStake = personalStake
        self.workingStyle = workingStyle
        self.conflictStyle = conflictStyle
        self.blindSpot = blindSpot
        self.evidenceThatChangesTheirMind = evidenceThatChangesTheirMind
        self.ingredients = ingredients
    }

    public var validationMessage: String? {
        let required = [
            fullName, background, formativeSuccess, formativeScar, personalStake,
            workingStyle, conflictStyle, blindSpot, evidenceThatChangesTheirMind
        ]
        if required.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "A company persona is incomplete."
        }
        if convictions.count < 2 || convictions.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return "A company persona needs at least two real convictions."
        }
        let characterText = ([
            background, personalStake, workingStyle, conflictStyle
        ] + convictions).joined(separator: " ").lowercased()
        let indifferentPatterns = [
            "neutral facilitator", "consensus facilitator", "consensus builder",
            "indifferent", "content with mediocrity", "avoids disagreement",
            "avoids conflict", "has no strong opinion", "generic assistant",
            "prioritizes consensus", "seeks consensus", "risk-averse", "risk averse",
            "prefers not to take sides", "no personal stake", "low ambition"
        ]
        if indifferentPatterns.contains(where: characterText.contains) {
            return "A company persona cannot be neutral, indifferent, or invested in mediocrity."
        }
        return nil
    }
}

public struct CompanyExperienceRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let headline: String
    public let detail: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        headline: String,
        detail: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.headline = headline
        self.detail = detail
    }
}

public struct CompanyPerson: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var positionID: CompanyPositionID
    public var profile: CompanyPersonaProfile
    public var assignment: String
    public var hiredAt: Date
    public var hiredRevision: Int?
    public var generationTokenUsage: RunTokenUsage?
    public var opportunityChargeTokens: Int64
    public var experience: [CompanyExperienceRecord]

    public init(
        id: UUID = UUID(),
        positionID: CompanyPositionID,
        profile: CompanyPersonaProfile,
        assignment: String,
        hiredAt: Date = .now,
        hiredRevision: Int? = nil,
        generationTokenUsage: RunTokenUsage? = nil,
        opportunityChargeTokens: Int64 = 0,
        experience: [CompanyExperienceRecord] = []
    ) {
        self.id = id
        self.positionID = positionID
        self.profile = profile
        self.assignment = assignment
        self.hiredAt = hiredAt
        self.hiredRevision = hiredRevision.map { max($0, 1) }
        self.generationTokenUsage = generationTokenUsage
        self.opportunityChargeTokens = max(opportunityChargeTokens, 0)
        self.experience = experience
    }

    public var position: CompanyPosition {
        CompanyPositionCatalog.position(positionID)
    }
}

public struct CompanyProductBet: Codable, Equatable, Sendable {
    public var headline: String
    public var valuePromise: String
    public var audience: String?
    public var focusQuestion: String?
    public var showcase: String
    public var integrationTarget: String
    public var killCondition: String
    public var fundedTokenLimit: Int64
    public var maximumTurns: Int

    public init(
        headline: String,
        valuePromise: String,
        audience: String? = nil,
        focusQuestion: String? = nil,
        showcase: String,
        integrationTarget: String,
        killCondition: String,
        fundedTokenLimit: Int64 = 1_000_000,
        maximumTurns: Int = 8
    ) {
        self.headline = headline
        self.valuePromise = valuePromise
        self.audience = audience
        self.focusQuestion = focusQuestion
        self.showcase = showcase
        self.integrationTarget = integrationTarget
        self.killCondition = killCondition
        self.fundedTokenLimit = max(fundedTokenLimit, 100_000)
        self.maximumTurns = min(max(maximumTurns, 6), 20)
    }

    public var validationMessage: String? {
        let required = [headline, valuePromise, showcase, integrationTarget, killCondition]
        return required.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) ? "The current product bet is incomplete." : nil
    }
}
