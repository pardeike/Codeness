import Testing
@testable import Codeness

struct CompanyAvatarTests {
    @Test
    func avatarSourceIsStableForTheSamePersona() {
        let identity = "Mara Vey|CEO|Bold product builder|Direct|Ship something people love"

        #expect(
            CompanyAvatarSource(identity: identity)
                == CompanyAvatarSource(identity: identity)
        )
    }

    @Test
    func currentCompanyGetsSixDistinctAvatarSeeds() {
        let identities = [
            "Mara Vey|CEO",
            "Iris Calder|Product Manager",
            "Tamsin Rooke|Developer",
            "Soren Vale|Designer",
            "Elian Voss|Sound Designer",
            "Nika Svalberg|QA Tester"
        ]
        let seeds = Set(identities.map { CompanyAvatarSource(identity: $0).seed })

        #expect(seeds.count == identities.count)
    }

    @Test
    func avatarURLUsesAdventurerNeutralWithoutExposingPersonaText() {
        let source = CompanyAvatarSource(
            identity: "Mara Vey|CEO|Private formative scar and personal stake"
        )
        let url = source.url.absoluteString

        #expect(url.contains("/adventurer-neutral/png"))
        #expect(url.contains("seed=\(source.seed)"))
        #expect(url.contains("size=128"))
        #expect(!url.contains("Mara"))
        #expect(!url.contains("Private"))
    }
}
