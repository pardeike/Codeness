import Foundation

extension URL {
    var abbreviatedPath: String {
        NSString(string: path).abbreviatingWithTildeInPath
    }

    var repositoryMenuTitle: String {
        let parent = deletingLastPathComponent().abbreviatedPath
        return "\(lastPathComponent) — \(parent)"
    }
}
