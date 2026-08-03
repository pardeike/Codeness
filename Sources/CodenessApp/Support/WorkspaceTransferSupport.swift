import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let codenessWorkspace = UTType(
        exportedAs: "ap.codeness.workspace",
        conformingTo: .content
    )
}

enum WorkspaceTransferBundleInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
    }
}
