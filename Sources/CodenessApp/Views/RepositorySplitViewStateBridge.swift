import AppKit
import SwiftUI

struct RepositorySplitViewStateBridge: NSViewRepresentable {
    let restoredSidebarWidth: CGFloat?
    let optimalSidebarWidth: CGFloat
    let allowsSidebarRestoration: Bool
    let onSidebarChange: (CGFloat, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            restoredSidebarWidth: restoredSidebarWidth,
            optimalSidebarWidth: optimalSidebarWidth,
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
        context.coordinator.optimalSidebarWidth = optimalSidebarWidth
        context.coordinator.allowsSidebarRestoration = allowsSidebarRestoration
        context.coordinator.attachIfPossible(from: nsView)
        context.coordinator.applyRestoredWidthIfNeeded()
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var restoredSidebarWidth: CGFloat?
        var optimalSidebarWidth: CGFloat
        var allowsSidebarRestoration: Bool
        var onSidebarChange: (CGFloat, Bool) -> Void

        private weak var splitView: NSSplitView?
        private var appliedRestoredWidth = false
        private var isApplyingWidth = false
        private var reportTask: Task<Void, Never>?
        private var observationTask: Task<Void, Never>?
        private var doubleClickMonitor: Any?
        private var lastReportedWidth: CGFloat?
        private var lastReportedVisibility: Bool?

        init(
            restoredSidebarWidth: CGFloat?,
            optimalSidebarWidth: CGFloat,
            allowsSidebarRestoration: Bool,
            onSidebarChange: @escaping (CGFloat, Bool) -> Void
        ) {
            self.restoredSidebarWidth = restoredSidebarWidth
            self.optimalSidebarWidth = optimalSidebarWidth
            self.allowsSidebarRestoration = allowsSidebarRestoration
            self.onSidebarChange = onSidebarChange
        }

        isolated deinit {
            reportTask?.cancel()
            observationTask?.cancel()
            if let doubleClickMonitor {
                NSEvent.removeMonitor(doubleClickMonitor)
            }
            NotificationCenter.default.removeObserver(self)
        }

        @discardableResult
        func attachIfPossible(from probe: NSView) -> Bool {
            if let splitView {
                suppressAutomaticTitlebarBackgrounds(in: splitView)
                return true
            }
            // AppKit owns the probe's unowned window reference for the duration of this
            // main-actor view-hierarchy lookup; the optional becomes nil when detached.
            guard let root = unsafe probe.window?.contentView,
                  let splitView = findNavigationSplitView(in: root) else { return false }
            self.splitView = splitView
            suppressAutomaticTitlebarBackgrounds(in: splitView)
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
            installDoubleClickMonitor()
            return true
        }

        func detach() {
            reportTask?.cancel()
            reportTask = nil
            observationTask?.cancel()
            observationTask = nil
            if let doubleClickMonitor {
                NSEvent.removeMonitor(doubleClickMonitor)
                self.doubleClickMonitor = nil
            }
            NotificationCenter.default.removeObserver(self)
            splitView = nil
        }

        @objc private func splitViewDidResize() {
            guard !isApplyingWidth else { return }
            if let splitView {
                suppressAutomaticTitlebarBackgrounds(in: splitView)
            }
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

        private func installDoubleClickMonitor() {
            guard doubleClickMonitor == nil else { return }
            doubleClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .leftMouseDown
            ) { [weak self] event in
                guard let self,
                      event.clickCount == 2,
                      let splitView = self.splitView,
                      let sidebar = splitView.arrangedSubviews.first else {
                    return event
                }
                let splitWindow = unsafe splitView.window
                guard event.window === splitWindow else { return event }
                let point = splitView.convert(event.locationInWindow, from: nil)
                let dividerHitArea = NSRect(
                    x: sidebar.frame.maxX,
                    y: splitView.bounds.minY,
                    width: max(1, splitView.dividerThickness),
                    height: splitView.bounds.height
                )
                    .insetBy(dx: -4, dy: 0)
                guard dividerHitArea.contains(point) else { return event }
                self.toggleSidebarWidth()
                return nil
            }
        }

        private func toggleSidebarWidth() {
            guard let splitView,
                  let sidebar = splitView.arrangedSubviews.first else { return }
            let minimumWidth = max(
                RepositoryWindowMetrics.minimumSidebarWidth,
                splitView.minPossiblePositionOfDivider(at: 0)
            )
            let maximumWidth = min(
                RepositoryWindowMetrics.maximumSidebarWidth,
                splitView.maxPossiblePositionOfDivider(at: 0)
            )
            guard maximumWidth >= minimumWidth else { return }
            let optimalWidth = min(
                maximumWidth,
                max(minimumWidth, optimalSidebarWidth)
            )
            let targetWidth = RepositoryWindowMetrics.sidebarDoubleClickTarget(
                currentWidth: sidebar.frame.width,
                optimalWidth: optimalWidth,
                maximumWidth: maximumWidth
            )

            isApplyingWidth = true
            splitView.setPosition(targetWidth, ofDividerAt: 0)
            isApplyingWidth = false
            scheduleStateReport()
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
            suppressAutomaticTitlebarBackgrounds(in: splitView)
            let width = sidebar.frame.width
            let isVisible = allowsSidebarRestoration && !sidebar.isHidden && width > 1
            guard lastReportedWidth.map({ abs($0 - width) >= 0.5 }) != false
                    || lastReportedVisibility != isVisible else { return }
            lastReportedWidth = width
            lastReportedVisibility = isVisible
            onSidebarChange(width, isVisible)
        }

        private func suppressAutomaticTitlebarBackgrounds(in splitView: NSSplitView) {
            // macOS 26 adds an unconfigurable titlebar scroll-edge backdrop to
            // every NavigationSplitView column, even when the window toolbar
            // has no content over that column. It covers the first 52 points
            // of every detail page. The background is an AppKit-owned sibling
            // of the arranged column views, so page-level SwiftUI scroll-edge
            // modifiers cannot affect it.
            for view in splitView.subviews
            where NSStringFromClass(type(of: view)) == "NSTitlebarBackgroundView" {
                view.isHidden = true
            }
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
