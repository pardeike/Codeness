import Foundation

enum RunSelectionPolicy {
    static func shouldSelectNextRun(
        selectedRunID: UUID?,
        activeRunID: UUID?,
        activeRunIsAtBottom: Bool?
    ) -> Bool {
        guard let activeRunID else { return selectedRunID == nil }
        return selectedRunID == activeRunID && activeRunIsAtBottom == true
    }
}
