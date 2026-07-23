import AppKit
import SwiftUI

struct SettingsWindowCloseGuard: NSViewRepresentable {
    let isDirty: Bool
    let save: @MainActor () async -> Bool
    let discard: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isDirty: isDirty, save: save, discard: discard)
    }

    func makeNSView(context: Context) -> SettingsWindowProbeView {
        let view = SettingsWindowProbeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: SettingsWindowProbeView, context: Context) {
        context.coordinator.isDirty = isDirty
        context.coordinator.save = save
        context.coordinator.discard = discard
        context.coordinator.attach(to: unsafe nsView.window)
    }

    static func dismantleNSView(_ nsView: SettingsWindowProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var isDirty: Bool
        var save: @MainActor () async -> Bool
        var discard: @MainActor () -> Void

        private weak var window: NSWindow?
        private var delegateProxy: SettingsWindowDelegateProxy?

        init(
            isDirty: Bool,
            save: @escaping @MainActor () async -> Bool,
            discard: @escaping @MainActor () -> Void
        ) {
            self.isDirty = isDirty
            self.save = save
            self.discard = discard
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            detach()
            let proxy = SettingsWindowDelegateProxy(
                originalDelegate: window.delegate,
                isDirty: { [weak self] in self?.isDirty == true },
                save: { [weak self] in await self?.save() == true },
                discard: { [weak self] in self?.discard() }
            )
            self.window = window
            delegateProxy = proxy
            window.delegate = proxy
        }

        func detach() {
            guard let window, let delegateProxy else { return }
            if window.delegate === delegateProxy {
                window.delegate = unsafe delegateProxy.originalDelegate
            }
            self.window = nil
            self.delegateProxy = nil
        }
    }
}

@MainActor
final class SettingsWindowProbeView: NSView {
    weak var coordinator: SettingsWindowCloseGuard.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.attach(to: unsafe window)
    }
}

@MainActor
private final class SettingsWindowDelegateProxy: NSObject, NSWindowDelegate {
    // AppKit invokes window-delegate selectors on the main thread. The NSObject
    // forwarding overrides are imported as nonisolated, so this unowned delegate
    // bridge is explicitly unsafe at that Objective-C boundary.
    nonisolated(unsafe) weak var originalDelegate: (any NSWindowDelegate)?

    private let isDirty: () -> Bool
    private let save: () async -> Bool
    private let discard: () -> Void
    private var bypassCloseGuard = false
    private var isPresentingAlert = false

    init(
        originalDelegate: (any NSWindowDelegate)?,
        isDirty: @escaping () -> Bool,
        save: @escaping () async -> Bool,
        discard: @escaping () -> Void
    ) {
        unsafe self.originalDelegate = originalDelegate
        self.isDirty = isDirty
        self.save = save
        self.discard = discard
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if bypassCloseGuard {
            bypassCloseGuard = false
            isPresentingAlert = false
            return true
        }
        if !isDirty() {
            return (unsafe originalDelegate)?.windowShouldClose?(sender) ?? true
        }
        guard !isPresentingAlert else { return false }
        isPresentingAlert = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes before closing Settings?"
        alert.informativeText = "Your edited prompts, models, transcript preferences, and executable path have not been saved."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self, let sender else { return }
            switch response {
            case .alertFirstButtonReturn:
                Task { @MainActor [weak self, weak sender] in
                    guard let self, let sender else { return }
                    if await save() {
                        bypassCloseGuard = true
                        await Task.yield()
                        sender.performClose(nil)
                    } else {
                        isPresentingAlert = false
                    }
                }
            case .alertSecondButtonReturn:
                discard()
                bypassCloseGuard = true
                Task { @MainActor [weak sender] in
                    await Task.yield()
                    sender?.performClose(nil)
                }
            default:
                isPresentingAlert = false
            }
        }
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (unsafe originalDelegate)?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if (unsafe originalDelegate)?.responds(to: selector) == true {
            return unsafe originalDelegate
        }
        return super.forwardingTarget(for: selector)
    }
}
