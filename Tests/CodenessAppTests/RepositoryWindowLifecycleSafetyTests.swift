import AppKit
import CodenessCore
import Foundation
import Testing
@testable import Codeness

@MainActor
struct RepositoryWindowLifecycleSafetyTests {
    @Test
    func repositoryRemainsByteForByteUnchangedAcrossWindowLifecycles() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try RepositorySnapshot.capture(fixture.repositoryURL)

        let appServer = CodexAppServerClient()
        try await appServer.start(configuration: fixture.appServerConfiguration)
        defer { Task { await appServer.shutdown() } }

        let store = WorkspaceStore(rootURL: fixture.applicationSupportURL)
        let application = CodenessApplicationModel(appServer: appServer, store: store)
        let commands = RepositoryWindowCommandState()
        let manager = RepositoryWindowManager(applicationModel: application, commandState: commands)
        await manager.loadRecentRepositories()

        // Open through the production manager, invoke File > Save's implementation,
        // and exercise a normal close with no activity.
        var opened = try await manager.openRepository(at: fixture.repositoryURL, display: true).controller
        await opened.coordinator.load()
        opened.window?.makeKeyAndOrderFront(nil)
        await Task.yield()
        #expect(opened.window?.representedURL == nil)
        NSDocumentController.shared.saveAllDocuments(nil)
        try original.assertUnchanged(at: fixture.repositoryURL, after: "AppKit Save All")
        #expect(await manager.saveCurrentRepositoryState())
        try original.assertUnchanged(at: fixture.repositoryURL, after: "File > Save")

        opened.window?.performClose(nil)
        try await waitUntil { manager.isEmpty }
        try original.assertUnchanged(at: fixture.repositoryURL, after: "normal close")

        // Start a real queued Codex turn through the coordinator, then exercise the
        // warning sheet and graceful pause-and-close path. The fake App Server keeps
        // the turn alive until the test supplies its authoritative terminal event.
        opened = try await manager.openRepository(at: fixture.repositoryURL, display: true).controller
        await opened.coordinator.load()
        await opened.coordinator.startActivity(goal: "Protect this fixture", prompts: .builtInDefaults)
        #expect(opened.coordinator.requiresCloseConfirmation)
        let activeRun = try #require(opened.coordinator.activeRun)
        let threadID = try #require(activeRun.threadID)
        let turnID = try #require(activeRun.turnID)

        opened.window?.performClose(nil)
        try await waitUntil { opened.window?.attachedSheet != nil }
        let closeButton = try #require(
            opened.window?.attachedSheet?.contentView?.descendantButton(titled: "Pause and Close")
        )
        closeButton.performClick(nil)
        try await waitUntil {
            opened.coordinator.pauseState == .waitingForTurn
                || opened.coordinator.pauseState == .requestingCheckpoint
        }
        await opened.coordinator.handle(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turn": .object([
                    "id": .string(turnID),
                    "items": .array([]),
                    "status": .string("interrupted")
                ])
            ]),
            rawLine: "fixture turn completed"
        ))
        try await waitUntil { manager.isEmpty }
        try original.assertUnchanged(at: fixture.repositoryURL, after: "graceful pause and close")

        // Exercise the application-quit preparation path. It deliberately preserves
        // the open-window registry so a subsequent launch can restore the repository.
        opened = try await manager.openRepository(at: fixture.repositoryURL, display: true).controller
        await opened.coordinator.load()
        #expect(await manager.prepareForApplicationTermination())
        #expect(await opened.coordinator.prepareForClose(strategy: .graceful) == .ready)
        try original.assertUnchanged(at: fixture.repositoryURL, after: "quit preparation")
        opened.window?.performClose(nil)
        try await waitUntil { manager.isEmpty }
        try original.assertUnchanged(at: fixture.repositoryURL, after: "quit close")

        // Restore through the production open-window registry.
        let restoredCommands = RepositoryWindowCommandState()
        let restoredManager = RepositoryWindowManager(
            applicationModel: application,
            commandState: restoredCommands
        )
        await restoredManager.loadRecentRepositories()
        await withCheckedContinuation { continuation in
            restoredManager.restoreOpenRepositories {
                continuation.resume()
            }
        }
        #expect(restoredManager.repositoryWindows.count == 1)
        try original.assertUnchanged(at: fixture.repositoryURL, after: "restoration")

        // Close and reopen through the same URL exposed by the Open Recent command.
        let restored = try #require(restoredManager.repositoryWindows.first)
        restored.window?.performClose(nil)
        try await waitUntil { restoredManager.isEmpty }
        let recentURL = try #require(restoredCommands.recentURLs.first)
        let recent = try await restoredManager.openRepository(at: recentURL, display: true).controller
        await recent.coordinator.load()
        try original.assertUnchanged(at: fixture.repositoryURL, after: "Open Recent")

        // Reset through the real repository-window path. The operation must archive
        // only Codeness metadata, retain the previous editable configuration, and
        // leave every byte in the selected Git repository untouched.
        let previousSettings = recent.coordinator.record.settings
        #expect(recent.coordinator.canStartOver)
        await recent.coordinator.startOver()
        #expect(recent.coordinator.record.activity == nil)
        #expect(recent.coordinator.record.activityDraft?.goal == "Protect this fixture")
        #expect(recent.coordinator.record.activityDraft?.prompts == .builtInDefaults)
        #expect(recent.coordinator.record.implementerThreadID == nil)
        #expect(recent.coordinator.record.reviewerThreadID == nil)
        #expect(recent.coordinator.record.settings == previousSettings)
        #expect(recent.coordinator.canStartActivity)
        try original.assertUnchanged(at: fixture.repositoryURL, after: "Start Over")

        recent.window?.performClose(nil)
        try await waitUntil { restoredManager.isEmpty }
        try original.assertUnchanged(at: fixture.repositoryURL, after: "final close")

        #expect(NSDocumentController.shared.documents.isEmpty)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                throw TestFailure("Timed out waiting for an AppKit lifecycle transition.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct TestFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct RepositorySnapshot: Equatable {
    enum Entry: Equatable {
        case directory
        case file(Data)
        case symbolicLink(String)
    }

    let entries: [String: Entry]

    static func capture(_ rootURL: URL) throws -> RepositorySnapshot {
        guard try rootURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw TestFailure("Repository is no longer a directory: \(rootURL.path)")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw TestFailure("Could not enumerate repository: \(rootURL.path)")
        }

        var entries: [String: Entry] = [:]
        for case let url as URL in enumerator {
            let relativePath = String(url.path.dropFirst(rootURL.path.count + 1))
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                entries[relativePath] = .symbolicLink(
                    try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                )
            } else if values.isDirectory == true {
                entries[relativePath] = .directory
            } else {
                entries[relativePath] = .file(try Data(contentsOf: url))
            }
        }
        return RepositorySnapshot(entries: entries)
    }

    func assertUnchanged(at rootURL: URL, after operation: String) throws {
        let current = try Self.capture(rootURL)
        guard current == self else {
            throw TestFailure("Repository contents changed after \(operation).")
        }
    }
}

private extension NSView {
    func descendantButton(titled title: String) -> NSButton? {
        if let button = self as? NSButton, button.title == title {
            return button
        }
        return subviews.lazy.compactMap { $0.descendantButton(titled: title) }.first
    }
}

private struct Fixture {
    let rootURL: URL
    let repositoryURL: URL
    let applicationSupportURL: URL
    let scriptURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodenessAppLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        repositoryURL = rootURL.appendingPathComponent("Repository", isDirectory: true)
        applicationSupportURL = rootURL.appendingPathComponent("Application Support", isDirectory: true)
        scriptURL = rootURL.appendingPathComponent("fake-app-server.py")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try runGit(["init", repositoryURL.path])

        let nested = repositoryURL.appendingPathComponent("Sources/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("sentinel text\n".utf8).write(
            to: nested.appendingPathComponent("sentinel.txt"),
            options: .atomic
        )
        try Data([0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF]).write(
            to: repositoryURL.appendingPathComponent("sentinel.bin"),
            options: .atomic
        )
        try Data("hidden\n".utf8).write(
            to: repositoryURL.appendingPathComponent(".sentinel"),
            options: .atomic
        )
        try FileManager.default.createSymbolicLink(
            at: repositoryURL.appendingPathComponent("sentinel-link"),
            withDestinationURL: nested.appendingPathComponent("sentinel.txt")
        )
        try Data(Self.fakeAppServer.utf8).write(to: scriptURL, options: .atomic)
    }

    var appServerConfiguration: CodexLaunchConfiguration {
        CodexLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [scriptURL.path]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestFailure(String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ))
        }
    }

    private static let fakeAppServer = #"""
import json
import sys

thread_count = 0
turn_count = 0

def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        emit({"id": identifier, "result": {"userAgent": "fixture"}})
    elif method == "thread/start":
        thread_count += 1
        emit({"id": identifier, "result": {"thread": {"id": "thread-" + str(thread_count)}}})
    elif method == "turn/start":
        turn_count += 1
        emit({"id": identifier, "result": {"turn": {"id": "turn-" + str(turn_count)}}})
    elif identifier is not None:
        emit({"id": identifier, "result": {}})
"""#
}
