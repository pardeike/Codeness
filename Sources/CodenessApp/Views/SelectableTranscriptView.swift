import AppKit
import CodenessCore
import SwiftUI

struct SelectableTranscriptView: NSViewRepresentable {
    let text: String
    let initialViewport: TranscriptViewportState
    let scrollToEndRequest: Int
    let onViewportChange: (TranscriptViewportState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            initialViewport: initialViewport,
            scrollToEndRequest: scrollToEndRequest,
            onViewportChange: onViewportChange
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = TranscriptScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.scrollObserver = context.coordinator

        let textView = TranscriptTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.toolTip = "Select or scroll this run transcript; press Command-F to search it"
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        // NSTextView owns this unowned AppKit text-container reference for the view's lifetime.
        if let textContainer = unsafe textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }
        scrollView.documentView = textView
        context.coordinator.connect(scrollView: scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onViewportChange = onViewportChange
        context.coordinator.update(
            text: text,
            scrollToEndRequest: scrollToEndRequest,
            in: scrollView
        )
    }

    @MainActor
    final class Coordinator: NSObject, TranscriptScrollObserving {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var onViewportChange: (TranscriptViewportState) -> Void

        private var isFollowingOutput = true
        private let initialViewport: TranscriptViewportState
        private var didApplyInitialViewport = false
        private var isApplyingTextUpdate = false
        private var isPerformingProgrammaticScroll = false
        private var followRevision = 0
        private var lastScrollToEndRequest: Int
        private var lastReportedViewport: TranscriptViewportState?
        private var settleTask: Task<Void, Never>?

        init(
            initialViewport: TranscriptViewportState,
            scrollToEndRequest: Int,
            onViewportChange: @escaping (TranscriptViewportState) -> Void
        ) {
            self.initialViewport = initialViewport
            isFollowingOutput = initialViewport.followsOutput
            lastScrollToEndRequest = scrollToEndRequest
            self.onViewportChange = onViewportChange
        }

        deinit {
            settleTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        func connect(scrollView: NSScrollView, textView: NSTextView) {
            self.scrollView = scrollView
            self.textView = textView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        @objc private func boundsDidChange() {
            guard let scrollView,
                  !isApplyingTextUpdate,
                  !isPerformingProgrammaticScroll else { return }
            setFollowingOutput(isAtBottom(scrollView: scrollView))
        }

        func update(text: String, scrollToEndRequest: Int, in scrollView: NSScrollView) {
            if let textView, textView.string != text {
                let shouldFollow = didApplyInitialViewport
                    && (isFollowingOutput || isAtBottom(scrollView: scrollView))
                isApplyingTextUpdate = true
                replaceText(in: textView, with: text)
                isApplyingTextUpdate = false

                if !didApplyInitialViewport {
                    didApplyInitialViewport = true
                    restoreInitialViewport()
                } else if shouldFollow {
                    setFollowingOutput(true, report: false)
                    maintainBottomPosition()
                } else {
                    setFollowingOutput(false)
                }
            } else if !didApplyInitialViewport {
                didApplyInitialViewport = true
                restoreInitialViewport()
            } else {
                reportViewportState()
            }

            if lastScrollToEndRequest != scrollToEndRequest {
                lastScrollToEndRequest = scrollToEndRequest
                jumpToEnd()
            }
        }

        func userWillScroll() {
            settleTask?.cancel()
            followRevision &+= 1
            isFollowingOutput = false
            reportViewportState()
        }

        func userDidScroll() {
            guard let scrollView else { return }
            setFollowingOutput(isAtBottom(scrollView: scrollView))
        }

        private func jumpToEnd() {
            setFollowingOutput(true, report: false)
            maintainBottomPosition()
        }

        private func maintainBottomPosition() {
            guard isFollowingOutput else { return }
            followRevision &+= 1
            let revision = followRevision
            scrollToBottomNow()
            reportViewportState()

            settleTask?.cancel()
            settleTask = Task { @MainActor [weak self] in
                for _ in 0..<2 {
                    await Task.yield()
                    guard let self,
                          !Task.isCancelled,
                          self.isFollowingOutput,
                          self.followRevision == revision else { return }
                    self.scrollToBottomNow()
                }
                self?.reportViewportState()
            }
        }

        private func restoreInitialViewport() {
            guard let scrollView, let textView else { return }
            if initialViewport.followsOutput {
                setFollowingOutput(true, report: false)
                maintainBottomPosition()
                return
            }

            isPerformingProgrammaticScroll = true
            defer { isPerformingProgrammaticScroll = false }
            ensureLayout(in: textView)
            let textLength = (textView.string as NSString).length
            let characterOffset = min(max(initialViewport.topCharacterOffset, 0), textLength)
            guard textLength > 0,
                  let layoutManager = unsafe textView.layoutManager else {
                scrollView.contentView.scroll(to: .zero)
                setFollowingOutput(false)
                return
            }
            let safeCharacterOffset = min(characterOffset, textLength - 1)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: safeCharacterOffset)
            // Passing nil avoids exposing or dereferencing the optional effective-range pointer.
            let lineRect = unsafe layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil
            )
            let targetY = max(
                0,
                lineRect.minY + textView.textContainerOrigin.y + CGFloat(initialViewport.verticalOffset)
            )
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            setFollowingOutput(false)
        }

        private func scrollToBottomNow() {
            guard let scrollView, let textView else { return }
            isPerformingProgrammaticScroll = true
            defer { isPerformingProgrammaticScroll = false }

            // NSTextView owns these AppKit text-system objects for the view's lifetime.
            ensureLayout(in: textView)
            let end = (textView.string as NSString).length
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
            if let documentView = scrollView.documentView {
                let originY = max(0, documentView.bounds.maxY - scrollView.contentView.bounds.height)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: originY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        private func replaceText(in textView: NSTextView, with text: String) {
            let existing = textView.string
            // NSTextView owns its unowned AppKit text storage for the view's lifetime.
            if text.hasPrefix(existing), let textStorage = unsafe textView.textStorage {
                let suffix = String(text.dropFirst(existing.count))
                textStorage.append(NSAttributedString(
                    string: suffix,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                        .foregroundColor: NSColor.textColor
                    ]
                ))
                return
            }

            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
            textView.textColor = .textColor
            let textLength = (text as NSString).length
            let clampedRanges: [NSValue] = selectedRanges.compactMap { value -> NSValue? in
                guard let range = value.rangeValue.intersection(NSRange(location: 0, length: textLength)) else {
                    return nil
                }
                return NSValue(range: range)
            }
            if !clampedRanges.isEmpty {
                textView.setSelectedRanges(clampedRanges, affinity: .downstream, stillSelecting: false)
            }
        }

        private func setFollowingOutput(_ value: Bool, report: Bool = true) {
            if isFollowingOutput != value {
                followRevision &+= 1
                isFollowingOutput = value
                if !value {
                    settleTask?.cancel()
                }
            }
            if report {
                reportViewportState()
            }
        }

        private func reportViewportState() {
            guard didApplyInitialViewport,
                  let scrollView,
                  let textView else { return }
            let viewport = viewportState(
                scrollView: scrollView,
                textView: textView,
                followsOutput: isFollowingOutput
            )
            guard viewport != lastReportedViewport else { return }
            lastReportedViewport = viewport
            let handler = onViewportChange
            Task { @MainActor in handler(viewport) }
        }

        private func viewportState(
            scrollView: NSScrollView,
            textView: NSTextView,
            followsOutput: Bool
        ) -> TranscriptViewportState {
            ensureLayout(in: textView)
            let textLength = (textView.string as NSString).length
            guard textLength > 0,
                  let layoutManager = unsafe textView.layoutManager else {
                return TranscriptViewportState(followsOutput: followsOutput)
            }

            let visibleY = scrollView.contentView.bounds.minY
            let insertionPoint = NSPoint(
                x: textView.textContainerOrigin.x + 1,
                y: visibleY + 1
            )
            let characterOffset = min(
                max(textView.characterIndexForInsertion(at: insertionPoint), 0),
                textLength - 1
            )
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterOffset)
            // Passing nil avoids exposing or dereferencing the optional effective-range pointer.
            let lineRect = unsafe layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil
            )
            let lineY = lineRect.minY + textView.textContainerOrigin.y
            return TranscriptViewportState(
                topCharacterOffset: characterOffset,
                verticalOffset: Double(visibleY - lineY),
                followsOutput: followsOutput
            )
        }

        private func ensureLayout(in textView: NSTextView) {
            if let layoutManager = unsafe textView.layoutManager,
               let textContainer = unsafe textView.textContainer {
                layoutManager.ensureLayout(for: textContainer)
            }
        }

        private func isAtBottom(scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return true }
            let visibleMaxY = scrollView.contentView.bounds.maxY
            return documentView.bounds.maxY - visibleMaxY <= 40
        }
    }
}

@MainActor
private protocol TranscriptScrollObserving: AnyObject {
    func userWillScroll()
    func userDidScroll()
}

@MainActor
private final class TranscriptScrollView: NSScrollView {
    weak var scrollObserver: (any TranscriptScrollObserving)?

    override func scrollWheel(with event: NSEvent) {
        scrollObserver?.userWillScroll()
        super.scrollWheel(with: event)
        scrollObserver?.userDidScroll()
    }
}

@MainActor
private final class TranscriptTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            let action = NSMenuItem()
            action.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            performFindPanelAction(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private extension NSRange {
    func intersection(_ other: NSRange) -> NSRange? {
        let value = NSIntersectionRange(self, other)
        return value.length > 0 || location == other.location ? value : nil
    }
}
