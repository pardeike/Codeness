import AppKit
import SwiftUI

/// Adds the missing native-list behavior where clicking below the final row
/// clears an optional selection. Row and section-header clicks remain owned by
/// SwiftUI's List because the recognizer only acts when NSTableView finds no row.
struct ListBackgroundDeselectionBridge: NSViewRepresentable {
    let onDeselect: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDeselect: onDeselect)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.attachWhenAvailable()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDeselect = onDeselect
        context.coordinator.hostView = nsView
        context.coordinator.attachWhenAvailable()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        _ = nsView
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var onDeselect: @MainActor () -> Void
        weak var hostView: NSView?

        private weak var tableView: NSTableView?
        private weak var clipView: NSClipView?
        private var clickRecognizer: NSClickGestureRecognizer?
        private var attachmentTask: Task<Void, Never>?

        init(onDeselect: @escaping @MainActor () -> Void) {
            self.onDeselect = onDeselect
        }

        func attachWhenAvailable() {
            if let clipView {
                let clipWindow = unsafe clipView.window
                let hostWindow = unsafe hostView?.window
                if clipWindow === hostWindow {
                    return
                }
            }
            attachmentTask?.cancel()
            attachmentTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for attempt in 0..<12 where !Task.isCancelled {
                    await Task.yield()
                    if attachToMatchingList() {
                        return
                    }
                    if attempt < 11 {
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                }
            }
        }

        func detach() {
            attachmentTask?.cancel()
            attachmentTask = nil
            if let clickRecognizer, let clipView {
                clipView.removeGestureRecognizer(clickRecognizer)
            }
            clickRecognizer = nil
            clipView = nil
            tableView = nil
        }

        @objc
        private func clickedList(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended, let tableView else { return }
            let location = recognizer.location(in: tableView)
            guard ListBackgroundDeselectionPolicy.shouldDeselect(
                in: tableView,
                at: location
            ) else { return }
            onDeselect()
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            _ = gestureRecognizer
            _ = otherGestureRecognizer
            return true
        }

        private func attachToMatchingList() -> Bool {
            guard let hostView,
                  let rootView = unsafe hostView.window?.contentView else { return false }
            let hostFrame = hostView.convert(hostView.bounds, to: rootView)
            let candidates = tableViews(in: rootView).compactMap { tableView -> Candidate? in
                guard let scrollView = tableView.enclosingScrollView else { return nil }
                let scrollFrame = scrollView.convert(scrollView.bounds, to: rootView)
                let overlap = hostFrame.intersection(scrollFrame)
                guard !overlap.isNull, !overlap.isEmpty else { return nil }
                return Candidate(
                    tableView: tableView,
                    clipView: scrollView.contentView,
                    overlapArea: overlap.width * overlap.height
                )
            }
            guard let candidate = candidates.max(by: { $0.overlapArea < $1.overlapArea }) else {
                return false
            }

            detach()
            let recognizer = NSClickGestureRecognizer(target: self, action: #selector(clickedList(_:)))
            recognizer.numberOfClicksRequired = 1
            recognizer.delaysPrimaryMouseButtonEvents = false
            recognizer.delegate = self
            candidate.clipView.addGestureRecognizer(recognizer)
            tableView = candidate.tableView
            clipView = candidate.clipView
            clickRecognizer = recognizer
            return true
        }

        private func tableViews(in view: NSView) -> [NSTableView] {
            var result = (view as? NSTableView).map { [$0] } ?? []
            for subview in view.subviews {
                result.append(contentsOf: tableViews(in: subview))
            }
            return result
        }
    }
}

@MainActor
enum ListBackgroundDeselectionPolicy {
    static func shouldDeselect(in tableView: NSTableView, at location: NSPoint) -> Bool {
        tableView.row(at: location) == -1
    }
}

private struct Candidate {
    let tableView: NSTableView
    let clipView: NSClipView
    let overlapArea: CGFloat
}
