import Foundation
import Testing
@testable import Codeness

struct AboutPresentationTests {
    @Test
    func versionShowsTheMarketingVersionWithoutTheBuildNumber() {
        #expect(
            AboutPresentation.versionText(marketingVersion: "0.9.1")
                == "Version 0.9.1"
        )
    }

    @Test
    func missingOrEmptyVersionIsOmitted() {
        #expect(AboutPresentation.versionText(marketingVersion: nil) == nil)
        #expect(AboutPresentation.versionText(marketingVersion: "") == nil)
        #expect(AboutPresentation.versionText(marketingVersion: "  \n") == nil)
    }

    @Test
    func creatorLinksUseTheCanonicalDestinations() {
        #expect(
            AboutPresentation.patreonURL.absoluteString
                == "https://www.patreon.com/pardeike"
        )
        #expect(
            AboutPresentation.discordURL.absoluteString
                == "https://discord.gg/CYnWvrbNhD"
        )
    }
}
