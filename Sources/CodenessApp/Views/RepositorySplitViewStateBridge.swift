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
        private var reportTask: Task<Void, Never>?
        private var observationTask: Task<Void, Never>?
        private var lastReportedWidth: CGFloat?
        private var lastReportedVisibility: Bool?

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
            reportTask?.cancel()
            observationTask?.cancel()
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
            if let sidebar = splitView.arrangedSubviews.first {
                sidebar.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(splitViewDidResize),
                    name: NSView.frameDidChangeNotification,
                    object: sidebar
                )
            }
            applyRestoredWidthIfNeeded()
            reportCurrentState()
            beginObservingActualWidth()
            return true
        }

        @objc private func splitViewDidResize() {
            guard !isApplyingWidth else { return }
            scheduleStateReport()
        }

        func applyRestoredWidthIfNeeded() {
            guard !appliedRestoredWidth,
                  allowsSidebarRestoration,
                  let splitView,
                  splitView.arrangedSubviews.count >= 2,
                  let restoredSidebarWidth else { return }
            appliedRestoredWidth = true
            isApplyingWidth = true
            splitView.setPosition(restoredSidebarWidth, ofDividerAt: 0)
            isApplyingWidth = false
        }

        private func beginObservingActualWidth() {
            guard observationTask == nil else { return }
            observationTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    guard self?.splitView != nil else { return }
                    self?.reportCurrentState()
                }
            }
        }

        private func scheduleStateReport() {
            reportTask?.cancel()
            reportTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(10))
                guard !Task.isCancelled, let self else { return }
                reportCurrentState()
                reportTask = nil
            }
        }

        private func reportCurrentState() {
            guard let splitView,
                  let sidebar = splitView.arrangedSubviews.first else { return }
            let width = sidebar.frame.width
            let isVisible = allowsSidebarRestoration && !sidebar.isHidden && width > 1
            guard lastReportedWidth.map({ abs($0 - width) >= 0.5 }) != false
                    || lastReportedVisibility != isVisible else { return }
            lastReportedWidth = width
            lastReportedVisibility = isVisible
            onSidebarChange(width, isVisible)
        }

        private func findNavigationSplitView(in view: NSView) -> NSSplitView? {
            if let splitView = view as? NSSplitView,
               splitView.isVertical,
               splitView.arrangedSubviews.count >= 2 {
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
