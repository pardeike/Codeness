import AppKit
import CodenessCore
import Testing
@testable import Codeness

@MainActor
struct SelectableTranscriptViewTests {
    @Test
    func viewportMappingUsesTextLayoutWithoutWindowHitTesting() throws {
        let text = "first\nsecond\nthird\nfourth\n"
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = HitTestDetectingTextView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 400),
            textContainer: textContainer
        )
        textView.textContainerInset = NSSize(width: 14, height: 12)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        scrollView.documentView = textView

        layoutManager.ensureLayout(for: textContainer)
        let thirdLineOffset = (text as NSString).range(of: "third").location
        let thirdLineGlyph = layoutManager.glyphIndexForCharacter(at: thirdLineOffset)
        let thirdLineRect = unsafe layoutManager.lineFragmentRect(
            forGlyphAt: thirdLineGlyph,
            effectiveRange: nil
        )
        scrollView.contentView.setBoundsOrigin(NSPoint(
            x: 0,
            y: thirdLineRect.minY + textView.textContainerOrigin.y
        ))

        let viewport = TranscriptViewportMapper.state(
            scrollView: scrollView,
            textView: textView,
            followsOutput: false
        )

        #expect(viewport.topCharacterOffset == thirdLineOffset)
        #expect(abs(viewport.verticalOffset) < 0.001)
        #expect(!viewport.followsOutput)
        #expect(!textView.didRequestWindowHitTest)
    }
}

@MainActor
private final class HitTestDetectingTextView: NSTextView {
    private(set) var didRequestWindowHitTest = false

    override func characterIndexForInsertion(at point: NSPoint) -> Int {
        didRequestWindowHitTest = true
        return super.characterIndexForInsertion(at: point)
    }
}
