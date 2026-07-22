import Foundation
import Testing
@testable import CodenessCore

struct GitRepositoryResolverTests {
    @Test
    func preservesTheExactSelectedSubdirectory() async throws {
        let repository = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repository) }
        try runGit(["init", repository.path])

        let first = repository.appendingPathComponent("Sources/Feature", isDirectory: true)
        let second = repository.appendingPathComponent("Tests/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let resolver = GitRepositoryResolver()
        let resolvedRoot = try await resolver.canonicalWorkspace(for: repository)
        let resolvedFirst = try await resolver.canonicalWorkspace(for: first)
        let resolvedSecond = try await resolver.canonicalWorkspace(for: second)

        #expect(resolvedRoot == canonical(repository))
        #expect(resolvedFirst == canonical(first))
        #expect(resolvedSecond == canonical(second))
        #expect(resolvedFirst != resolvedSecond)
    }

    @Test
    func resolvesSymlinksWithoutReplacingTheSelectedFolderWithTheGitRoot() async throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let repository = container.appendingPathComponent("Repository", isDirectory: true)
        try runGit(["init", repository.path])
        let nested = repository.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let link = container.appendingPathComponent("NestedLink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nested)

        let resolved = try await GitRepositoryResolver().canonicalWorkspace(for: link)

        #expect(resolved == canonical(nested))
    }

    @Test
    func acceptsFoldersInsideALinkedWorktree() async throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let repository = container.appendingPathComponent("Main", isDirectory: true)
        let worktree = container.appendingPathComponent("Worktree", isDirectory: true)
        try runGit(["init", repository.path])
        try runGit(["-C", repository.path, "config", "user.email", "codeness@example.invalid"])
        try runGit(["-C", repository.path, "config", "user.name", "Codeness Tests"])
        try Data("fixture\n".utf8).write(to: repository.appendingPathComponent("fixture.txt"))
        try runGit(["-C", repository.path, "add", "fixture.txt"])
        try runGit(["-C", repository.path, "commit", "-m", "fixture"])
        try runGit(["-C", repository.path, "worktree", "add", worktree.path])
        let nested = worktree.appendingPathComponent("Selected", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let resolved = try await GitRepositoryResolver().canonicalWorkspace(for: nested)

        #expect(resolved == canonical(nested))
    }

    @Test
    func rejectsOrdinaryDirectoriesAndBareRepositories() async throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let ordinary = container.appendingPathComponent("Ordinary", isDirectory: true)
        let bare = container.appendingPathComponent("Bare.git", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        try runGit(["init", "--bare", bare.path])
        let resolver = GitRepositoryResolver()

        await expectNotRepository(ordinary, resolver: resolver)
        await expectNotRepository(bare, resolver: resolver)
    }

    private func expectNotRepository(_ url: URL, resolver: GitRepositoryResolver) async {
        do {
            _ = try await resolver.canonicalWorkspace(for: url)
            Issue.record("Expected \(url.path) to be rejected")
        } catch let error as GitRepositoryError {
            guard case .notRepository = error else {
                Issue.record("Expected notRepository, received \(error)")
                return
            }
        } catch {
            Issue.record("Expected GitRepositoryError, received \(error)")
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
            let detail = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw NSError(
                domain: "GitRepositoryResolverTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }
}
