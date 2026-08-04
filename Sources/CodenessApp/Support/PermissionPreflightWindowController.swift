import AppKit
import SwiftUI

@MainActor
final class PermissionPreflightWindowController: NSWindowController {
    let model: PermissionPreflightModel
    private var hasBeenPresented = false

    init(client: any PermissionPreflightClient = SystemPermissionPreflightClient()) {
        let model = PermissionPreflightModel(client: client)
        self.model = model

        let hostingController = NSHostingController(
            rootView: PermissionPreflightView(model: model)
        )
        hostingController.sizingOptions = []

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.setContentSize(NSSize(width: 720, height: 700))
        panel.minSize = NSSize(width: 680, height: 620)
        panel.title = "Codeness Permissions"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("codeness-permission-preflight")
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true

        super.init(window: panel)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func present() {
        model.refresh()
        guard let window else { return }
        if !hasBeenPresented {
            window.center()
            hasBeenPresented = true
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        model.refresh()
    }
}
