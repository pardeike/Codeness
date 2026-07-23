import AppKit
import SwiftUI

/// Restores and records the transcript/result divider as a fraction so it
/// remains useful when the repository window is resized or moved to a display
/// with different dimensions.
struct RunDetailSplitViewStateBridge: NSViewRepresentable {
    let restoredFraction: Double?
    let onFractionChange: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            restoredFraction: restoredFraction,
            onFractionChange: onFractionChange
        )
    }

    func makeNSView(context: Context) -> RunDetailSplitProbeView {
        let view = RunDetailSplitProbeView()
        view.bridgeCoordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: RunDetailSplitProbeView, context: Context) {
        context.coordinator.restoredFraction = restoredFraction
        context.coordinator.onFractionChange = onFractionChange
        context.coordinator.attachIfPossible(from: nsView)
        context.coordinator.applyRestoredFractionIfNeeded()
    }

    static func dismantleNSView(
        _ nsView: RunDetailSplitProbeView,
        coordinator: Coordinator
    ) {
        _ = nsView
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var restoredFraction: Double?
        var onFractionChange: (Double) -> Void

        private weak var splitView: NSSplitView?
        private var appliedRestoredFraction = false
        private var isApplyingFraction = false

        init(
            restoredFraction: Double?,
            onFractionChange: @escaping (Double) -> Void
        ) {
            self.restoredFraction = restoredFraction
            self.onFractionChange = onFractionChange
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @discardableResult
        func attachIfPossible(from probe: NSView) -> Bool {
            if splitView != nil { return true }
            guard let rootView = unsafe probe.window?.contentView else { return false }
            let probeFrame = probe.convert(probe.bounds, to: rootView)
            let candidates = horizontalSplitViews(in: rootView).compactMap {
                splitView -> SplitCandidate? in
                let splitFrame = splitView.convert(splitView.bounds, to: rootView)
                let overlap = probeFrame.intersection(splitFrame)
                guard !overlap.isNull, !overlap.isEmpty else { return nil }
                return SplitCandidate(
                    splitView: splitView,
                    overlapArea: overlap.width * overlap.height
                )
            }
            guard let splitView = candidates
                .max(by: { $0.overlapArea < $1.overlapArea })?
                .splitView else { return false }
            self.splitView = splitView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(splitViewDidResize),
                name: NSSplitView.didResizeSubviewsNotification,
                object: splitView
            )
            applyRestoredFractionIfNeeded()
            reportCurrentFraction()
            return true
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            splitView = nil
        }

        func applyRestoredFractionIfNeeded() {
            guard !appliedRestoredFraction,
                  let splitView,
                  splitView.subviews.count >= 2,
                  let restoredFraction else { return }
            let first = splitView.subviews[0]
            let second = splitView.subviews[1]
            let contentHeight = first.frame.height + second.frame.height
            guard contentHeight > 0 else { return }
            let firstHeight = contentHeight * min(max(restoredFraction, 0.15), 0.85)
            let firstIsBelowSecond = first.frame.midY < second.frame.midY
            let dividerPosition = firstIsBelowSecond
                ? splitView.bounds.minY + firstHeight
                : splitView.bounds.maxY - firstHeight

            appliedRestoredFraction = true
            isApplyingFraction = true
            splitView.setPosition(dividerPosition, ofDividerAt: 0)
            isApplyingFraction = false
        }

        @objc
        private func splitViewDidResize() {
            guard !isApplyingFraction else { return }
            reportCurrentFraction()
        }

        private func reportCurrentFraction() {
            guard let splitView,
                  splitView.subviews.count >= 2 else { return }
            let firstHeight = splitView.subviews[0].frame.height
            let secondHeight = splitView.subviews[1].frame.height
            let contentHeight = firstHeight + secondHeight
            guard contentHeight > 0 else { return }
            onFractionChange(min(max(firstHeight / contentHeight, 0.15), 0.85))
        }

        private func horizontalSplitViews(in view: NSView) -> [NSSplitView] {
            var result: [NSSplitView] = []
            if let splitView = view as? NSSplitView,
               !splitView.isVertical,
               splitView.subviews.count >= 2 {
                result.append(splitView)
            }
            for subview in view.subviews {
                result.append(contentsOf: horizontalSplitViews(in: subview))
            }
            return result
        }
    }
}

@MainActor
final class RunDetailSplitProbeView: NSView {
    weak var bridgeCoordinator: RunDetailSplitViewStateBridge.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0..<12 where !Task.isCancelled {
                await Task.yield()
                if bridgeCoordinator?.attachIfPossible(from: self) == true {
                    return
                }
                if attempt < 11 {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        }
    }
}

private struct SplitCandidate {
    let splitView: NSSplitView
    let overlapArea: CGFloat
}
