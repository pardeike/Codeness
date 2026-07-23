import AppKit
import Testing
@testable import Codeness

@MainActor
struct ListBackgroundDeselectionPolicyTests {
    @Test
    func onlyEmptyTableBackgroundClearsTheSelection() {
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Run")))
        let dataSource = TwoRunDataSource()
        tableView.dataSource = dataSource
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()

        let firstRow = tableView.rect(ofRow: 0)
        let secondRow = tableView.rect(ofRow: 1)
        #expect(!ListBackgroundDeselectionPolicy.shouldDeselect(
            in: tableView,
            at: NSPoint(x: firstRow.midX, y: firstRow.midY)
        ))
        #expect(!ListBackgroundDeselectionPolicy.shouldDeselect(
            in: tableView,
            at: NSPoint(x: secondRow.midX, y: secondRow.midY)
        ))
        #expect(ListBackgroundDeselectionPolicy.shouldDeselect(
            in: tableView,
            at: NSPoint(x: secondRow.midX, y: secondRow.maxY + 30)
        ))
    }
}

@MainActor
private final class TwoRunDataSource: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        _ = tableView
        return 2
    }
}
