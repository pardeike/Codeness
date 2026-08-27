import Foundation
import Testing
@testable import Codeness

@MainActor
struct PermissionPreflightTests {
    @Test
    func inventoryUsesTheRequiredOrderAndCapabilityTypes() {
        let client = FakePermissionPreflightClient()
        let model = PermissionPreflightModel(client: client)
        model.refresh()

        #expect(model.rows.map(\.id) == [
            .fullDiskAccess,
            .filesAndFolders,
            .accessibility,
            .screenRecording,
            .systemAudioRecording,
            .automation,
            .developerTools,
            .appManagement
        ])
        #expect(model.rows.map(\.verification) == [
            .protectedFileProbe,
            .onDemand,
            .preciseSystemAPI,
            .preciseSystemAPI,
            .settingsOnly,
            .perApplication,
            .settingsOnly,
            .settingsOnly
        ])
    }

    @Test
    func dynamicAndCapabilityAwareStatusesMapHonestly() {
        let client = FakePermissionPreflightClient()
        let model = PermissionPreflightModel(client: client)

        model.refresh()
        var statuses = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0.status) })
        #expect(statuses[.fullDiskAccess] == .notVerified)
        #expect(statuses[.filesAndFolders] == .onDemand)
        #expect(statuses[.accessibility] == .notAllowed)
        #expect(statuses[.screenRecording] == .notAllowed)
        #expect(statuses[.systemAudioRecording] == .verifyInSettings)
        #expect(statuses[.automation] == .managedPerApp)
        #expect(statuses[.developerTools] == .verifyInSettings)
        #expect(statuses[.appManagement] == .verifyInSettings)
        var actions = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0.action) })
        #expect(actions[.fullDiskAccess] == .openSettings)
        #expect(actions[.accessibility] == .requestAccess)
        #expect(actions[.screenRecording] == .requestAccess)
        #expect(actions[.systemAudioRecording] == .openSettings)

        client.fullDiskAccessIsVerified = true
        client.accessibilityIsAllowed = true
        client.screenRecordingIsAllowed = true
        model.refresh()
        statuses = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0.status) })
        #expect(statuses[.fullDiskAccess] == .accessVerified)
        #expect(statuses[.accessibility] == .allowed)
        #expect(statuses[.screenRecording] == .allowed)
        #expect(statuses[.systemAudioRecording] == .verifyInSettings)
        actions = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0.action) })
        #expect(actions[.fullDiskAccess] == .verified)
        #expect(actions[.accessibility] == .granted)
        #expect(actions[.screenRecording] == .granted)
        #expect(actions[.systemAudioRecording] == .openSettings)
    }

    @Test
    func constructionAndPassiveRefreshNeverPromptOrOpenSettings() {
        let client = FakePermissionPreflightClient()
        let model = PermissionPreflightModel(client: client)

        #expect(client.totalPassiveCheckCount == 0)
        #expect(client.accessibilityRequestCount == 0)
        #expect(client.screenRecordingRequestCount == 0)
        #expect(client.openedSettingsURLs.isEmpty)

        model.refresh()
        #expect(client.totalPassiveCheckCount == 3)
        #expect(client.accessibilityRequestCount == 0)
        #expect(client.screenRecordingRequestCount == 0)
        #expect(client.openedSettingsURLs.isEmpty)
    }

    @Test
    func explicitRequestActionsRouteOnlyToTheirMatchingSystemAPI() {
        let client = FakePermissionPreflightClient()
        client.accessibilityRequestSucceeds = true
        client.screenRecordingRequestSucceeds = true
        let model = PermissionPreflightModel(client: client)

        model.performPrimaryAction(for: .accessibility)
        #expect(client.accessibilityRequestCount == 1)
        #expect(client.screenRecordingRequestCount == 0)
        #expect(client.openedSettingsURLs.isEmpty)

        model.performPrimaryAction(for: .screenRecording)
        #expect(client.accessibilityRequestCount == 1)
        #expect(client.screenRecordingRequestCount == 1)
        #expect(client.openedSettingsURLs.isEmpty)
    }

    @Test
    func screenRequestDeniedByTheSystemFallsBackToItsSettingsPane() {
        let client = FakePermissionPreflightClient()
        let model = PermissionPreflightModel(client: client)

        model.performPrimaryAction(for: .accessibility)
        #expect(client.accessibilityRequestCount == 1)
        #expect(client.openedSettingsURLs.isEmpty)

        model.performPrimaryAction(for: .screenRecording)
        #expect(client.screenRecordingRequestCount == 1)
        #expect(client.openedSettingsURLs == [
            PermissionSettingsLinks.urls(for: .screenRecording)
        ])
    }

    @Test
    func grantedRowsArePassiveWhenInvokedProgrammatically() {
        let client = FakePermissionPreflightClient()
        client.fullDiskAccessIsVerified = true
        client.accessibilityIsAllowed = true
        client.screenRecordingIsAllowed = true
        let model = PermissionPreflightModel(client: client)
        model.refresh()

        model.performPrimaryAction(for: .fullDiskAccess)
        model.performPrimaryAction(for: .accessibility)
        model.performPrimaryAction(for: .screenRecording)

        #expect(client.accessibilityRequestCount == 0)
        #expect(client.screenRecordingRequestCount == 0)
        #expect(client.openedSettingsURLs.isEmpty)
    }

    @Test
    func settingsActionsUseTheMatchingDeepLinkRoute() {
        let client = FakePermissionPreflightClient()
        let model = PermissionPreflightModel(client: client)
        let settingsKinds: [PermissionPreflightKind] = [
            .fullDiskAccess,
            .filesAndFolders,
            .systemAudioRecording,
            .automation,
            .developerTools,
            .appManagement
        ]

        for kind in settingsKinds {
            model.performPrimaryAction(for: kind)
        }

        #expect(client.openedSettingsURLs == settingsKinds.map {
            PermissionSettingsLinks.urls(for: $0)
        })
        #expect(client.accessibilityRequestCount == 0)
        #expect(client.screenRecordingRequestCount == 0)
    }

    @Test
    func deepLinksPreferModernThenLegacyThenGenericSystemSettings() {
        let expectedKeys: [PermissionPreflightKind: String] = [
            .fullDiskAccess: "Privacy_AllFiles",
            .filesAndFolders: "Privacy_FilesAndFolders",
            .accessibility: "Privacy_Accessibility",
            .screenRecording: "Privacy_ScreenCapture",
            .systemAudioRecording: "Privacy_AudioCapture",
            .automation: "Privacy_Automation",
            .developerTools: "Privacy_DevTools",
            .appManagement: "Privacy_AppBundles"
        ]

        for kind in PermissionPreflightKind.allCases {
            let key = expectedKeys[kind]
            let urls = PermissionSettingsLinks.urls(for: kind).map(\.absoluteString)
            #expect(urls == [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(key ?? "")",
                "x-apple.systempreferences:com.apple.preference.security?\(key ?? "")",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                "file:///System/Applications/System%20Settings.app/"
            ])
        }
    }

    @Test
    func refreshRechecksEveryDynamicCapabilityAndUpdatesTheSummary() {
        let client = FakePermissionPreflightClient()
        let model = PermissionPreflightModel(client: client)

        model.refresh()
        #expect(model.refreshCount == 1)
        #expect(model.summary == PermissionPreflightSummary(
            verifiedCount: 0,
            verifiableCount: 3
        ))
        #expect(model.summary.title == "0 of 3 checks verified")

        client.fullDiskAccessIsVerified = true
        client.accessibilityIsAllowed = true
        client.screenRecordingIsAllowed = true
        model.refresh()

        #expect(model.refreshCount == 2)
        #expect(client.totalPassiveCheckCount == 6)
        #expect(model.summary == PermissionPreflightSummary(
            verifiedCount: 3,
            verifiableCount: 3
        ))
        #expect(model.summary.title == "3 of 3 checks verified")
    }

    @Test
    func fullDiskProbeCandidatesAvoidUnrelatedProtectedDataCategories() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let paths = SystemPermissionPreflightClient.protectedProbeURLs(
            homeDirectory: home
        ).map(\.path)

        #expect(paths == [
            "/Users/example/Library/Safari/History.db",
            "/Users/example/Library/Messages/chat.db"
        ])
        #expect(paths.allSatisfy {
            !$0.localizedCaseInsensitiveContains("Contacts")
                && !$0.localizedCaseInsensitiveContains("Calendars")
        })
    }

    @Test
    func appBundleExplainsDeclaredCapabilitiesWithoutUnrelatedPrompts() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        let description = try #require(info["NSAppleEventsUsageDescription"] as? String)
        #expect(description.contains("Apple events"))
        #expect(description.contains("apps you choose"))
        let audioDescription = try #require(
            info["NSAudioCaptureUsageDescription"] as? String
        )
        #expect(audioDescription.contains("system audio"))
        #expect(audioDescription.contains("activity"))
        let appManagementDescription = try #require(
            info["NSAppBundlesUsageDescription"] as? String
        )
        #expect(appManagementDescription.contains("update or remove apps"))
        #expect(appManagementDescription.contains("activity"))

        let prohibitedUsageKeys = [
            "NSMicrophoneUsageDescription",
            "NSCameraUsageDescription",
            "NSContactsUsageDescription",
            "NSCalendarsUsageDescription",
            "NSUserNotificationsUsageDescription",
            "NSInputMonitoringUsageDescription",
            "NSLocalNetworkUsageDescription"
        ]
        #expect(prohibitedUsageKeys.allSatisfy { info[$0] == nil })
    }
}

@MainActor
private final class FakePermissionPreflightClient: PermissionPreflightClient {
    var fullDiskAccessIsVerified = false
    var accessibilityIsAllowed = false
    var screenRecordingIsAllowed = false
    var accessibilityRequestSucceeds = false
    var screenRecordingRequestSucceeds = false
    var settingsOpenSucceeds = true

    private(set) var fullDiskProbeCount = 0
    private(set) var accessibilityCheckCount = 0
    private(set) var screenRecordingCheckCount = 0
    private(set) var accessibilityRequestCount = 0
    private(set) var screenRecordingRequestCount = 0
    private(set) var openedSettingsURLs: [[URL]] = []

    var totalPassiveCheckCount: Int {
        fullDiskProbeCount + accessibilityCheckCount + screenRecordingCheckCount
    }

    func probeFullDiskAccess() -> Bool {
        fullDiskProbeCount += 1
        return fullDiskAccessIsVerified
    }

    func accessibilityAccessIsAllowed() -> Bool {
        accessibilityCheckCount += 1
        return accessibilityIsAllowed
    }

    func requestAccessibilityAccess() -> Bool {
        accessibilityRequestCount += 1
        return accessibilityRequestSucceeds
    }

    func screenRecordingAccessIsAllowed() -> Bool {
        screenRecordingCheckCount += 1
        return screenRecordingIsAllowed
    }

    func requestScreenRecordingAccess() -> Bool {
        screenRecordingRequestCount += 1
        return screenRecordingRequestSucceeds
    }

    func openSystemSettings(urls: [URL]) -> Bool {
        openedSettingsURLs.append(urls)
        return settingsOpenSucceeds
    }
}
