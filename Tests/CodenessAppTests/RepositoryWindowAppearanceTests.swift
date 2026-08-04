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
}
