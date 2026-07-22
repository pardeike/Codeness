import Foundation
import Testing
@testable import CodenessCore

struct RunSelectionPolicyTests {
    @Test
    func selectsTheFirstRunInAnEmptyActivity() {
        #expect(
            RunSelectionPolicy.shouldSelectNextRun(
                selectedRunID: nil,
                activeRunID: nil,
                activeRunIsAtBottom: nil
            )
        )
    }

    @Test
    func followsOnlyTheSelectedActiveRunAtTheBottom() {
        let active = UUID()
        let earlier = UUID()

        #expect(
            RunSelectionPolicy.shouldSelectNextRun(
                selectedRunID: active,
                activeRunID: active,
                activeRunIsAtBottom: true
            )
        )
        #expect(
            !RunSelectionPolicy.shouldSelectNextRun(
                selectedRunID: active,
                activeRunID: active,
                activeRunIsAtBottom: false
            )
        )
        #expect(
            !RunSelectionPolicy.shouldSelectNextRun(
                selectedRunID: earlier,
                activeRunID: active,
                activeRunIsAtBottom: true
            )
        )
    }
}
