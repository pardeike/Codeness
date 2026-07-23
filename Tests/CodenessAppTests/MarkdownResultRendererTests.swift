import AppKit
import Foundation
import Testing
@testable import Codeness

@MainActor
struct MarkdownResultRendererTests {
    @Test
    func rendersBlockSyntaxAndTurnsLocalFileReferencesIntoLinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeness-markdown-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("A File.swift")
        try Data("let value = 1\n".utf8).write(to: sourceURL)
        let markdown = """
        # Review Complete

        - Fixed **the parser**
        - Inspect [`A File.swift`](<Sources/A File.swift:12>)
        - Open [the same file](Sources/A File.swift:7)

        ```swift
        let value = 1
        ```
        """

        let rendered = MarkdownResultRenderer.render(markdown, repositoryPath: root.path)

        #expect(rendered.string.contains("Review Complete"))
        #expect(!rendered.string.contains("# Review Complete"))
        #expect(rendered.string.contains("•\tFixed the parser"))
        #expect(rendered.string.contains("A File.swift"))
        #expect(rendered.string.contains("the same file"))
        #expect(!rendered.string.contains("](<"))
        #expect(!rendered.string.contains("](Sources/"))
        #expect(rendered.string.contains("let value = 1"))

        var links: [URL] = []
        unsafe rendered.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if let url = value as? URL {
                links.append(url)
            }
        }
        #expect(links.count == 2)
        let destinations = links.map { link -> (String?, String?) in
            var components = URLComponents(url: link, resolvingAgainstBaseURL: false)
            let fragment = components?.fragment
            components?.fragment = nil
            return (components?.url?.path, fragment)
        }
        #expect(destinations.contains { $0 == (sourceURL.path, "line=12") })
        #expect(destinations.contains { $0 == (sourceURL.path, "line=7") })
    }
}
