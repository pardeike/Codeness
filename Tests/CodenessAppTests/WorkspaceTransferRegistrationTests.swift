import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Codeness

struct WorkspaceTransferRegistrationTests {
    @Test
    func registersFlatCodenessFilesWithFinder() throws {
        #expect(UTType.codenessWorkspace.identifier == "ap.codeness.workspace")
        #expect(UTType.codenessWorkspace.conforms(to: .content))
        #expect(UTType.codenessWorkspace.preferredFilenameExtension == "codeness")

        let info = Bundle.main.infoDictionary ?? [:]
        let documentTypes = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let workspaceType = try #require(documentTypes.first {
            ($0["LSItemContentTypes"] as? [String])?.contains("ap.codeness.workspace") == true
        })
        #expect(workspaceType["CFBundleTypeRole"] as? String == "Viewer")
        #expect(workspaceType["LSHandlerRank"] as? String == "Owner")
        #expect(workspaceType["CFBundleTypeIconFile"] as? String == "AppIcon.icns")

        let declarations = try #require(
            info["UTExportedTypeDeclarations"] as? [[String: Any]]
        )
        let declaration = try #require(declarations.first {
            $0["UTTypeIdentifier"] as? String == "ap.codeness.workspace"
        })
        let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
        #expect((tags["public.filename-extension"] as? [String]) == ["codeness"])
        #expect(Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil)
    }
}
