import Foundation
import Testing
@testable import CodenessCore

struct WorkspaceResolverTests {
    @Test
    func acceptsOrdinaryDirectoriesAndPreservesTheExactSelection() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let first = workspace.appendingPathComponent("Sources/Feature", isDirectory: true)
        let second = workspace.appendingPathComponent("Tests/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let resolver = WorkspaceResolver()
        let resolvedRoot = try await resolver.canonicalWorkspace(for: workspace)
        let resolvedFirst = try await resolver.canonicalWorkspace(for: first)
        let resolvedSecond = try await resolver.canonicalWorkspace(for: second)

        #expect(resolvedRoot == canonical(workspace))
        #expect(resolvedFirst == canonical(first))
        #expect(resolvedSecond == canonical(second))
        #expect(resolvedFirst != resolvedSecond)
    }

    @Test
    func resolvesSymlinksWithoutReplacingTheSelectedFolder() async throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let workspace = container.appendingPathComponent("Workspace", isDirectory: true)
        let nested = workspace.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let link = container.appendingPathComponent("NestedLink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nested)

        let resolved = try await WorkspaceResolver().canonicalWorkspace(for: link)

        #expect(resolved == canonical(nested))
    }

    @Test
    func rejectsFilesAndMissingPaths() async throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let file = container.appendingPathComponent("fixture.txt")
        let missing = container.appendingPathComponent("Missing", isDirectory: true)
        try Data("fixture\n".utf8).write(to: file)
        let resolver = WorkspaceResolver()

        await expectNotDirectory(file, resolver: resolver)
        await expectNotDirectory(missing, resolver: resolver)
    }

    private func expectNotDirectory(_ url: URL, resolver: WorkspaceResolver) async {
        do {
            _ = try await resolver.canonicalWorkspace(for: url)
            Issue.record("Expected \(url.path) to be rejected")
        } catch let error as WorkspaceResolutionError {
            guard case .notDirectory = error else {
                Issue.record("Expected notDirectory, received \(error)")
                return
            }
        } catch {
            Issue.record("Expected WorkspaceResolutionError, received \(error)")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodenessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
