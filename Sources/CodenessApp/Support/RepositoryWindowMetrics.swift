import AppKit

enum RepositoryWindowMetrics {
    static let defaultContentSize = NSSize(width: 1_260, height: 820)
    static let minimumWindowSize = NSSize(width: 700, height: 560)
    static let minimumSidebarWidth: CGFloat = 220
    static let minimumDetailWidth: CGFloat = 470
    static let idealSidebarWidth: CGFloat = 330
    static let maximumSidebarWidth: CGFloat = 430

    static func sidebarWidth(
        currentWidth: CGFloat,
        forProposedSplitWidth proposedSplitWidth: CGFloat,
        dividerWidth: CGFloat
    ) -> CGFloat {
        let widthAvailableAfterDetail = proposedSplitWidth
            - minimumDetailWidth
            - dividerWidth
        return max(minimumSidebarWidth, min(currentWidth, widthAvailableAfterDetail))
    }
}
