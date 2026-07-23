import AppKit
import SwiftUI

struct MarkdownResultView: NSViewRepresentable {
    let text: String
    let repositoryPath: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        if let textContainer = unsafe textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.renderedText != text
                || context.coordinator.repositoryPath != repositoryPath,
              let textView = context.coordinator.textView else { return }
        context.coordinator.renderedText = text
        context.coordinator.repositoryPath = repositoryPath
        let selection = textView.selectedRange()
        if let textStorage = unsafe textView.textStorage {
            textStorage.setAttributedString(
                MarkdownResultRenderer.render(text, repositoryPath: repositoryPath)
            )
        }
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSIntersectionRange(selection, NSRange(location: 0, length: length)))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        var renderedText = ""
        var repositoryPath = ""

        func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at characterIndex: Int
        ) -> Bool {
            let url: URL?
            if let value = link as? URL {
                url = value
            } else if let value = link as? String {
                url = URL(string: value)
            } else {
                url = nil
            }
            guard let url else { return false }
            if url.isFileURL {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.fragment = nil
                guard let fileURL = components?.url else { return false }
                NSWorkspace.shared.open(fileURL)
                return true
            }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

@MainActor
enum MarkdownResultRenderer {
    private enum InlineKind {
        case link
        case code
        case bold
        case italic
        case url
    }

    private struct InlineMatch {
        let kind: InlineKind
        let result: NSTextCheckingResult
    }

    static func render(_ markdown: String, repositoryPath: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        var isCodeBlock = false

        for (index, lineValue) in lines.enumerated() {
            let line = String(lineValue)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                isCodeBlock.toggle()
                if index < lines.count - 1, !result.string.hasSuffix("\n\n") {
                    result.append(NSAttributedString(string: "\n"))
                }
                continue
            }

            if isCodeBlock {
                appendCodeLine(line, to: result)
            } else {
                appendBlockLine(line, repositoryPath: repositoryPath, to: result)
            }
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    private static func appendBlockLine(
        _ line: String,
        repositoryPath: String,
        to result: NSMutableAttributedString
    ) {
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 5

        if let heading = headingParts(line) {
            let sizes: [CGFloat] = [25, 21, 18, 16, 14, 13]
            let size = sizes[min(max(heading.level - 1, 0), sizes.count - 1)]
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: heading.level <= 2 ? .bold : .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            appendInline(
                heading.text,
                baseAttributes: attributes,
                repositoryPath: repositoryPath,
                to: result
            )
            return
        }

        if let content = unorderedListContent(line) {
            paragraph.headIndent = 22
            paragraph.firstLineHeadIndent = 4
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
            let attributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            result.append(NSAttributedString(string: "•\t", attributes: attributes))
            appendInline(
                content,
                baseAttributes: attributes,
                repositoryPath: repositoryPath,
                to: result
            )
            return
        }

        if let ordered = orderedListParts(line) {
            paragraph.headIndent = 28
            paragraph.firstLineHeadIndent = 2
            paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 22)]
            let attributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            result.append(NSAttributedString(string: "\(ordered.number).\t", attributes: attributes))
            appendInline(
                ordered.text,
                baseAttributes: attributes,
                repositoryPath: repositoryPath,
                to: result
            )
            return
        }

        if line.hasPrefix(">") {
            let content = line.dropFirst().trimmingCharacters(in: .whitespaces)
            paragraph.headIndent = 18
            paragraph.firstLineHeadIndent = 18
            let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            appendInline(
                content,
                baseAttributes: [
                    .font: italic,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph
                ],
                repositoryPath: repositoryPath,
                to: result
            )
            return
        }

        appendInline(
            line,
            baseAttributes: [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ],
            repositoryPath: repositoryPath,
            to: result
        )
    }

    private static func appendCodeLine(_ line: String, to result: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 12
        paragraph.firstLineHeadIndent = 12
        paragraph.tailIndent = -12
        paragraph.paragraphSpacing = 1
        result.append(NSAttributedString(
            string: line,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.28),
                .paragraphStyle: paragraph
            ]
        ))
    }

    private static func appendInline(
        _ text: String,
        baseAttributes: [NSAttributedString.Key: Any],
        repositoryPath: String,
        to result: NSMutableAttributedString
    ) {
        var remaining = text as NSString
        while remaining.length > 0 {
            guard let match = firstInlineMatch(in: remaining as String) else {
                result.append(NSAttributedString(
                    string: unescaped(remaining as String),
                    attributes: baseAttributes
                ))
                return
            }
            if match.result.range.location > 0 {
                let prefix = remaining.substring(to: match.result.range.location)
                result.append(NSAttributedString(string: unescaped(prefix), attributes: baseAttributes))
            }

            switch match.kind {
            case .link:
                let label = remaining.substring(with: match.result.range(at: 1))
                let destinationCapture = match.result.range(at: 2).location != NSNotFound ? 2 : 3
                let destination = remaining.substring(with: match.result.range(at: destinationCapture))
                var attributes = baseAttributes
                if let url = normalizedURL(destination, repositoryPath: repositoryPath) {
                    attributes[.link] = url
                    attributes[.foregroundColor] = NSColor.linkColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: unescaped(label), attributes: attributes))
            case .code:
                var attributes = baseAttributes
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                attributes[.backgroundColor] = NSColor.unemphasizedSelectedContentBackgroundColor
                    .withAlphaComponent(0.35)
                result.append(NSAttributedString(
                    string: remaining.substring(with: match.result.range(at: 1)),
                    attributes: attributes
                ))
            case .bold:
                let capture = match.result.range(at: 1).location != NSNotFound ? 1 : 2
                var attributes = baseAttributes
                let size = (baseAttributes[.font] as? NSFont)?.pointSize ?? NSFont.systemFontSize
                attributes[.font] = NSFont.systemFont(ofSize: size, weight: .semibold)
                result.append(NSAttributedString(
                    string: remaining.substring(with: match.result.range(at: capture)),
                    attributes: attributes
                ))
            case .italic:
                let capture = match.result.range(at: 1).location != NSNotFound ? 1 : 2
                var attributes = baseAttributes
                let baseFont = (baseAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                attributes[.font] = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                result.append(NSAttributedString(
                    string: remaining.substring(with: match.result.range(at: capture)),
                    attributes: attributes
                ))
            case .url:
                let value = remaining.substring(with: match.result.range)
                var attributes = baseAttributes
                if let url = URL(string: value) {
                    attributes[.link] = url
                    attributes[.foregroundColor] = NSColor.linkColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: value, attributes: attributes))
            }

            let nextLocation = NSMaxRange(match.result.range)
            remaining = remaining.substring(from: nextLocation) as NSString
        }
    }

    private static func firstInlineMatch(in text: String) -> InlineMatch? {
        let patterns: [(InlineKind, String)] = [
            (.link, #"\[([^\]]+)\]\((?:<([^>]+)>|([^\n]+?))(?:\s+"[^"]*")?\)"#),
            (.code, #"`([^`\n]+)`"#),
            (.bold, #"\*\*([^*\n]+)\*\*|__([^_\n]+)__"#),
            (.italic, #"(?<!\*)\*([^*\n]+)\*(?!\*)|(?<!_)_([^_\n]+)_(?!_)"#),
            (.url, #"https?://[^\s<>()]+"#)
        ]
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return patterns.compactMap { kind, pattern -> InlineMatch? in
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: searchRange) else { return nil }
            return InlineMatch(kind: kind, result: match)
        }
        .min { lhs, rhs in
            if lhs.result.range.location == rhs.result.range.location {
                return lhs.result.range.length > rhs.result.range.length
            }
            return lhs.result.range.location < rhs.result.range.location
        }
    }

    private static func headingParts(_ line: String) -> (level: Int, text: String)? {
        let prefix = line.prefix(while: { $0 == "#" })
        guard !prefix.isEmpty, prefix.count <= 6,
              line.dropFirst(prefix.count).first == " " else { return nil }
        return (prefix.count, String(line.dropFirst(prefix.count + 1)))
    }

    private static func unorderedListContent(_ line: String) -> String? {
        guard line.count >= 2 else { return nil }
        let prefix = line.prefix(2)
        guard prefix == "- " || prefix == "* " || prefix == "+ " else { return nil }
        return String(line.dropFirst(2))
    }

    private static func orderedListParts(_ line: String) -> (number: String, text: String)? {
        guard let expression = try? NSRegularExpression(pattern: #"^(\d+)[.)]\s+(.+)$"#),
              let match = expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let numberRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line) else { return nil }
        return (String(line[numberRange]), String(line[textRange]))
    }

    private static func normalizedURL(_ destination: String, repositoryPath: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        if let url = URL(string: decoded), let scheme = url.scheme, scheme != "file" {
            return url
        }

        var path: String
        var fragment: String?
        if let fileURL = URL(string: decoded), fileURL.isFileURL {
            path = fileURL.path
            fragment = fileURL.fragment
        } else {
            let parts = decoded.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            path = String(parts[0])
            fragment = parts.count > 1 ? String(parts[1]) : nil
        }
        path = NSString(string: path).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = URL(fileURLWithPath: repositoryPath, isDirectory: true)
                .appendingPathComponent(path)
                .standardizedFileURL.path
        }

        if !FileManager.default.fileExists(atPath: path),
           let lineSuffix = path.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) {
            let suffix = String(path[lineSuffix]).dropFirst()
            fragment = fragment ?? "line=\(suffix)"
            path.removeSubrange(lineSuffix)
        }

        var components = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)
        components?.fragment = fragment
        return components?.url
    }

    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\\([\\`*_[\]()#])"#,
            with: "$1",
            options: .regularExpression
        )
    }
}
