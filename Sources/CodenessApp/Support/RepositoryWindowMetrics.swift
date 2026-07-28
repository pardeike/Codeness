import AppKit

enum RepositoryWindowMetrics {
    static let defaultContentSize = NSSize(width: 1_260, height: 820)
    static let minimumWindowSize = NSSize(width: 700, height: 560)
    static let minimumSidebarWidth: CGFloat = 220
    static let minimumDetailWidth: CGFloat = 470
    static let idealSidebarWidth: CGFloat = 330
    static let maximumSidebarWidth: CGFloat = 430

    static func optimalSidebarWidth(
        rowTitles: [String],
        rowMetadata: [String],
        sectionTitles: [String],
        controlTitles: [String]
    ) -> CGFloat {
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let captionFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let rowChromeWidth: CGFloat = 68
        let sectionChromeWidth: CGFloat = 44
        let buttonChromeWidth: CGFloat = 24
        let controlSpacing: CGFloat = 10
        let dockInsets: CGFloat = 24

        let rowContentWidth = zip(rowTitles, rowMetadata).map { title, metadata in
            max(
                textWidth(title, font: bodyFont),
                textWidth(metadata, font: captionFont)
            ) + rowChromeWidth
        }.max() ?? 0
        let sectionContentWidth = sectionTitles.map {
            textWidth($0, font: captionFont) + sectionChromeWidth
        }.max() ?? 0
        let controlsContentWidth = controlTitles.enumerated().reduce(CGFloat.zero) {
            width,
            item in
            width
                + textWidth(item.element, font: bodyFont)
                + buttonChromeWidth
                + (item.offset == 0 ? 0 : controlSpacing)
        } + (controlTitles.isEmpty ? 0 : dockInsets)

        let measuredWidth = max(
            idealSidebarWidth,
            rowContentWidth,
            sectionContentWidth,
            controlsContentWidth
        )
        return min(maximumSidebarWidth, ceil(measuredWidth))
    }

    static func sidebarDoubleClickTarget(
        currentWidth: CGFloat,
        optimalWidth: CGFloat,
        maximumWidth: CGFloat = maximumSidebarWidth
    ) -> CGFloat {
        let optimalWidth = min(optimalWidth, maximumWidth)
        guard maximumWidth - optimalWidth >= 0.5 else { return maximumWidth }
        let midpoint = optimalWidth + (maximumWidth - optimalWidth) / 2
        return currentWidth >= midpoint ? optimalWidth : maximumWidth
    }

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

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
