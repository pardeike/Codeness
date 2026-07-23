import AppKit
import CodenessCore
import Testing
@testable import Codeness

@MainActor
struct RepositoryWindowGeometryTests {
    @Test
    func savedFrameIsAppliedBeforeDisplayAndIsNotReappliedAfterLoading() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-window-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = "/tmp/codeness-window-\(UUID().uuidString)"
        let store = WorkspaceStore(rootURL: root)
        try await store.save(RepositoryRecord(canonicalPath: path))
        let screen = try #require(NSScreen.main)
        let visibleFrame = screen.visibleFrame
        let storedFrame = StoredWindowFrame(
            x: visibleFrame.minX + 40,
            y: visibleFrame.minY + 40,
            width: 900,
            height: 700,
            displayIdentifier: screen.localizedName
        )
        try await store.saveViewState(
            RepositoryViewState(windowFrame: storedFrame),
            canonicalPath: path
        )
        let application = CodenessApplicationModel(store: store)
        let coordinator = application.coordinator(for: path)
        let initialWindowFrame = await application.storedWindowFrame(for: path)
        #expect(initialWindowFrame == storedFrame)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: RepositoryWindowMetrics.defaultContentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = RepositoryWindowMetrics.minimumWindowSize
        let controller = RepositoryWindowController(
            window: window,
            coordinator: coordinator,
            initialWindowFrame: initialWindowFrame,
            commandState: RepositoryWindowCommandState(),
            onClose: { _ in }
        )

        #expect(!window.isVisible)
        #expect(abs(window.frame.minX - CGFloat(storedFrame.x)) < 0.5)
        #expect(abs(window.frame.minY - CGFloat(storedFrame.y)) < 0.5)
        #expect(abs(window.frame.width - CGFloat(storedFrame.width)) < 0.5)
        #expect(abs(window.frame.height - CGFloat(storedFrame.height)) < 0.5)

        let adjustedFrame = NSRect(
            x: CGFloat(storedFrame.x) + 24,
            y: CGFloat(storedFrame.y) + 18,
            width: CGFloat(storedFrame.width) - 20,
            height: CGFloat(storedFrame.height) - 16
        )
        window.setFrame(adjustedFrame, display: false)
        controller.windowDidMove(
            Notification(name: NSWindow.didMoveNotification, object: window)
        )

        await coordinator.load()
        await waitUntil {
            guard let saved = coordinator.viewState.windowFrame else { return false }
            return abs(saved.x - adjustedFrame.minX) < 0.5
                && abs(saved.y - adjustedFrame.minY) < 0.5
                && abs(saved.width - adjustedFrame.width) < 0.5
                && abs(saved.height - adjustedFrame.height) < 0.5
        }

        #expect(abs(window.frame.minX - adjustedFrame.minX) < 0.5)
        #expect(abs(window.frame.minY - adjustedFrame.minY) < 0.5)
        #expect(abs(window.frame.width - adjustedFrame.width) < 0.5)
        #expect(abs(window.frame.height - adjustedFrame.height) < 0.5)

        window.delegate = nil
        withExtendedLifetime(controller) {}
    }

    @Test
    func restoredFrameIsClampedToAnAvailableDisplayBeforeDisplay() async throws {
        let screen = try #require(NSScreen.main)
        let visibleFrame = screen.visibleFrame
        let storedFrame = StoredWindowFrame(
            x: visibleFrame.maxX + 500,
            y: visibleFrame.maxY + 500,
            width: visibleFrame.width * 2,
            height: visibleFrame.height * 2,
            displayIdentifier: "Disconnected Display"
        )
        let coordinator = RepositoryCoordinator(
            canonicalPath: "/tmp/codeness-window-\(UUID().uuidString)",
            appServer: CodexAppServerClient(),
            router: HandoffRouter(),
            store: WorkspaceStore()
        )
        await coordinator.load()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: RepositoryWindowMetrics.defaultContentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = RepositoryWindowMetrics.minimumWindowSize
        let controller = RepositoryWindowController(
            window: window,
            coordinator: coordinator,
            initialWindowFrame: storedFrame,
            commandState: RepositoryWindowCommandState(),
            onClose: { _ in }
        )

        #expect(!window.isVisible)
        #expect(window.frame.minX >= visibleFrame.minX - 0.5)
        #expect(window.frame.minY >= visibleFrame.minY - 0.5)
        #expect(window.frame.maxX <= visibleFrame.maxX + 0.5)
        #expect(window.frame.maxY <= visibleFrame.maxY + 0.5)

        window.delegate = nil
        withExtendedLifetime(controller) {}
    }

    @Test
    func missingViewStateHasNoStoredFrame() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-window-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let application = CodenessApplicationModel(store: WorkspaceStore(rootURL: root))

        #expect(await application.storedWindowFrame(for: "/tmp/missing") == nil)
    }

    @Test
    func sidebarYieldsOnlyAfterTheDetailReachesItsMinimumWidth() {
        #expect(
            RepositoryWindowMetrics.sidebarWidth(
                currentWidth: 338,
                forProposedSplitWidth: 900,
                dividerWidth: 0
            ) == 338
        )
        #expect(
            RepositoryWindowMetrics.sidebarWidth(
                currentWidth: 338,
                forProposedSplitWidth: 800,
                dividerWidth: 0
            ) == 330
        )
        #expect(
            RepositoryWindowMetrics.sidebarWidth(
                currentWidth: 338,
                forProposedSplitWidth: 600,
                dividerWidth: 0
            ) == RepositoryWindowMetrics.minimumSidebarWidth
        )
    }

    @Test
    func systemSidebarToolbarItemsAreHiddenWithoutChangingToolbarStructure() {
        let splitView = NSSplitView()
        let privateTrackingSeparatorItem = NSTrackingSeparatorToolbarItem(
            identifier: .init("com.apple.SwiftUI.splitViewSeparator-0"),
            splitView: splitView,
            dividerIndex: 0
        )
        let standardSidebarItem = NSToolbarItem(itemIdentifier: .toggleSidebar)
        let trackingSeparatorItem = NSToolbarItem(itemIdentifier: .sidebarTrackingSeparator)
        let swiftUISidebarItem = NSToolbarItem(itemIdentifier: .init(
            "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
        ))
        let repositorySidebarItem = NSToolbarItem(itemIdentifier: .init(
            "repository-sidebar-toggle"
        ))
        let items = [
            privateTrackingSeparatorItem,
            standardSidebarItem,
            trackingSeparatorItem,
            swiftUISidebarItem,
            repositorySidebarItem
        ]

        RepositoryWindowController.hideSystemSidebarToolbarItems(in: items)

        #expect(items.count == 5)
        #expect(privateTrackingSeparatorItem.isHidden)
        #expect(standardSidebarItem.isHidden)
        #expect(trackingSeparatorItem.isHidden)
        #expect(swiftUISidebarItem.isHidden)
        #expect(!repositorySidebarItem.isHidden)
    }

    @Test
    func splitBridgeReportsActualSidebarFrames() async throws {
        let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        splitView.isVertical = true
        let sidebar = NSView()
        let detail = NSView()
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(detail)

        let probe = ProbeView(frame: splitView.bounds)
        let rootView = NSView(frame: splitView.bounds)
        rootView.addSubview(splitView)
        rootView.addSubview(probe)
        let window = NSWindow(
            contentRect: splitView.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = rootView

        var reportedWidths: [CGFloat] = []
        let bridge = RepositorySplitViewStateBridge.Coordinator(
            restoredSidebarWidth: 338,
            allowsSidebarRestoration: true,
            onSidebarChange: { width, _ in
                reportedWidths.append(width)
            }
        )
        probe.bridgeCoordinator = bridge

        #expect(bridge.attachIfPossible(from: probe))
        #expect(abs(sidebar.frame.width - 338) < 0.5)

        splitView.setPosition(300, ofDividerAt: 0)
        await waitUntil {
            reportedWidths.last.map { abs($0 - 300) < 0.5 } == true
        }

        #expect(abs(try #require(reportedWidths.last) - 300) < 0.5)

        window.contentView = nil
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
