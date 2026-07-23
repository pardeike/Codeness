import AppKit
import SwiftUI

struct RepositorySplitViewStateBridge: NSViewRepresentable {
    let restoredSidebarWidth: CGFloat?
    let allowsSidebarRestoration: Bool
    let onSidebarChange: (CGFloat, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            restoredSidebarWidth: restoredSidebarWidth,
            allowsSidebarRestoration: allowsSidebarRestoration,
            onSidebarChange: onSidebarChange
        )
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.bridgeCoordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.onSidebarChange = onSidebarChange
        context.coordinator.restoredSidebarWidth = restoredSidebarWidth
        context.coordinator.allowsSidebarRestoration = allowsSidebarRestoration
        context.coordinator.attachIfPossible(from: nsView)
        context.coordinator.applyRestoredWidthIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject {
        var restoredSidebarWidth: CGFloat?
        var allowsSidebarRestoration: Bool
        var onSidebarChange: (CGFloat, Bool) -> Void

        private weak var splitView: NSSplitView?
        private var appliedRestoredWidth = false
        private var isApplyingWidth = false

        init(
            restoredSidebarWidth: CGFloat?,
            allowsSidebarRestoration: Bool,
            onSidebarChange: @escaping (CGFloat, Bool) -> Void
        ) {
            self.restoredSidebarWidth = restoredSidebarWidth
            self.allowsSidebarRestoration = allowsSidebarRestoration
            self.onSidebarChange = onSidebarChange
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @discardableResult
        func attachIfPossible(from probe: NSView) -> Bool {
            if splitView != nil { return true }
            // AppKit owns the probe's unowned window reference for the duration of this
            // main-actor view-hierarchy lookup; the optional becomes nil when detached.
            guard let root = unsafe probe.window?.contentView,
                  let splitView = findNavigationSplitView(in: root) else { return false }
            self.splitView = splitView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(splitViewDidResize),
                name: NSSplitView.didResizeSubviewsNotification,
                object: splitView
            )
            applyRestoredWidthIfNeeded()
            reportCurrentState()
            return true
        }

        @objc private func splitViewDidResize() {
            guard !isApplyingWidth else { return }
            reportCurrentState()
        }

        func applyRestoredWidthIfNeeded() {
            guard !appliedRestoredWidth,
                  allowsSidebarRestoration,
                  let splitView,
                  splitView.subviews.count >= 2,
                  let restoredSidebarWidth else { return }
            appliedRestoredWidth = true
            isApplyingWidth = true
            splitView.setPosition(restoredSidebarWidth, ofDividerAt: 0)
            isApplyingWidth = false
        }

        private func reportCurrentState() {
            guard let splitView,
                  let sidebar = splitView.subviews.first else { return }
            let width = sidebar.frame.width
            onSidebarChange(width, allowsSidebarRestoration && !sidebar.isHidden && width > 1)
        }

        private func findNavigationSplitView(in view: NSView) -> NSSplitView? {
            if let splitView = view as? NSSplitView,
               splitView.isVertical,
               splitView.subviews.count >= 2 {
                return splitView
            }
            for subview in view.subviews {
                if let splitView = findNavigationSplitView(in: subview) {
                    return splitView
                }
            }
            return nil
        }
    }
}

@MainActor
final class ProbeView: NSView {
    weak var bridgeCoordinator: RepositorySplitViewStateBridge.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Task { @MainActor [weak self] in
            for _ in 0..<8 {
                await Task.yield()
                guard let self else { return }
                if bridgeCoordinator?.attachIfPossible(from: self) == true {
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }
}
