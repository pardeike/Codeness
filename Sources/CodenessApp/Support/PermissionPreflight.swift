import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import Observation

enum PermissionPreflightKind: String, CaseIterable, Identifiable, Sendable {
    case fullDiskAccess
    case filesAndFolders
    case accessibility
    case screenRecording
    case systemAudioRecording
    case automation
    case developerTools
    case appManagement

    var id: Self { self }

    var title: String {
        switch self {
        case .fullDiskAccess: "Full Disk Access"
        case .filesAndFolders: "Files & Folders"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .systemAudioRecording: "System Audio Recording"
        case .automation: "Automation"
        case .developerTools: "Developer Tools"
        case .appManagement: "App Management"
        }
    }

    var systemImage: String {
        switch self {
        case .fullDiskAccess: "externaldrive.badge.checkmark"
        case .filesAndFolders: "folder.badge.questionmark"
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.inset.filled.and.person.filled"
        case .systemAudioRecording: "speaker.wave.3.fill"
        case .automation: "gearshape.2"
        case .developerTools: "hammer"
        case .appManagement: "app.badge.checkmark"
        }
    }

    var settingsPrivacyKey: String {
        switch self {
        case .fullDiskAccess: "Privacy_AllFiles"
        case .filesAndFolders: "Privacy_FilesAndFolders"
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .systemAudioRecording: "Privacy_AudioCapture"
        case .automation: "Privacy_Automation"
        case .developerTools: "Privacy_DevTools"
        case .appManagement: "Privacy_AppBundles"
        }
    }
}

enum PermissionPreflightStatus: Hashable, Sendable {
    case accessVerified
    case notVerified
    case onDemand
    case allowed
    case notAllowed
    case managedPerApp
    case verifyInSettings

    var label: String {
        switch self {
        case .accessVerified: "Access Verified"
        case .notVerified: "Not Verified"
        case .onDemand: "On Demand"
        case .allowed: "Allowed"
        case .notAllowed: "Not Allowed"
        case .managedPerApp: "Managed Per App"
        case .verifyInSettings: "Verify in Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .accessVerified, .allowed: "checkmark.circle.fill"
        case .notVerified, .notAllowed: "exclamationmark.circle.fill"
        case .onDemand, .managedPerApp, .verifyInSettings: "info.circle.fill"
        }
    }

    var presentation: PermissionPreflightStatusPresentation {
        switch self {
        case .accessVerified, .allowed: .positive
        case .notVerified, .notAllowed: .attention
        case .onDemand, .managedPerApp, .verifyInSettings: .informational
        }
    }
}

enum PermissionPreflightStatusPresentation: Sendable {
    case positive
    case attention
    case informational
}

enum PermissionPreflightVerification: Equatable, Sendable {
    case protectedFileProbe
    case onDemand
    case preciseSystemAPI
    case perApplication
    case settingsOnly
}

enum PermissionPreflightAction: Equatable, Sendable {
    case granted
    case verified
    case requestAccess
    case openSettings

    var title: String {
        switch self {
        case .granted: "Granted"
        case .verified: "Verified"
        case .requestAccess: "Request Access"
        case .openSettings: "Open Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .granted, .verified: "checkmark"
        case .requestAccess: "hand.raised"
        case .openSettings: "gear"
        }
    }
}

struct PermissionPreflightRow: Identifiable, Equatable, Sendable {
    let id: PermissionPreflightKind
    let status: PermissionPreflightStatus
    let verification: PermissionPreflightVerification
    let detail: String
    let action: PermissionPreflightAction
}

struct PermissionPreflightSummary: Equatable, Sendable {
    let verifiedCount: Int
    let verifiableCount: Int

    var title: String {
        "\(verifiedCount) of \(verifiableCount) checks verified"
    }

    var detail: String {
        if verifiedCount == verifiableCount {
            "The permissions macOS lets Codeness check are currently available."
        } else {
            "Review the remaining checkable permissions if a workflow needs those capabilities."
        }
    }

    var systemImage: String {
        verifiedCount == verifiableCount
            ? "checkmark.shield.fill"
            : "checkmark.shield"
    }
}

@MainActor
protocol PermissionPreflightClient: AnyObject {
    func probeFullDiskAccess() -> Bool
    func accessibilityAccessIsAllowed() -> Bool
    func requestAccessibilityAccess() -> Bool
    func screenRecordingAccessIsAllowed() -> Bool
    func requestScreenRecordingAccess() -> Bool
    func openSystemSettings(urls: [URL]) -> Bool
}

@MainActor
final class SystemPermissionPreflightClient: PermissionPreflightClient {
    private let workspace: NSWorkspace
    private let protectedProbeURLs: [URL]

    init(
        workspace: NSWorkspace = .shared,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.workspace = workspace
        protectedProbeURLs = Self.protectedProbeURLs(homeDirectory: homeDirectory)
    }

    func probeFullDiskAccess() -> Bool {
        for url in protectedProbeURLs {
            // Opening a descriptor is sufficient evidence. Deliberately do not read
            // any user data from the protected file.
            let descriptor = unsafe Darwin.open(
                url.path,
                O_RDONLY | O_CLOEXEC | O_NONBLOCK
            )
            guard descriptor >= 0 else { continue }
            Darwin.close(descriptor)
            return true
        }
        return false
    }

    func accessibilityAccessIsAllowed() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityAccess() -> Bool {
        // This is the stable string value of kAXTrustedCheckOptionPrompt. Referencing
        // the imported mutable CF global is rejected under strict concurrency.
        return AXIsProcessTrustedWithOptions([
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary)
    }

    func screenRecordingAccessIsAllowed() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func openSystemSettings(urls: [URL]) -> Bool {
        for url in urls where workspace.open(url) {
            return true
        }
        return false
    }

    static func protectedProbeURLs(homeDirectory: URL) -> [URL] {
        [
            homeDirectory.appendingPathComponent("Library/Safari/History.db"),
            homeDirectory.appendingPathComponent("Library/Messages/chat.db")
        ]
    }
}

enum PermissionSettingsLinks {
    static let modernPaneIdentifier = "com.apple.settings.PrivacySecurity.extension"
    static let legacyPaneIdentifier = "com.apple.preference.security"

    static func urls(for kind: PermissionPreflightKind) -> [URL] {
        let key = kind.settingsPrivacyKey
        let deepLinks = [
            URL(string: "x-apple.systempreferences:\(modernPaneIdentifier)?\(key)"),
            URL(string: "x-apple.systempreferences:\(legacyPaneIdentifier)?\(key)"),
            URL(string: "x-apple.systempreferences:\(modernPaneIdentifier)")
        ].compactMap { $0 }
        return deepLinks + [
            URL(
                fileURLWithPath: "/System/Applications/System Settings.app",
                isDirectory: true
            )
        ]
    }
}

@MainActor
@Observable
final class PermissionPreflightModel {
    private(set) var rows: [PermissionPreflightRow]
    private(set) var refreshCount = 0
    private(set) var settingsOpenFailed = false

    @ObservationIgnored private let client: any PermissionPreflightClient

    init(client: any PermissionPreflightClient = SystemPermissionPreflightClient()) {
        self.client = client
        rows = Self.rows(
            fullDiskAccessIsVerified: false,
            accessibilityIsAllowed: false,
            screenRecordingIsAllowed: false
        )
    }

    var summary: PermissionPreflightSummary {
        let verifiedStatuses: Set<PermissionPreflightStatus> = [.accessVerified, .allowed]
        let verifiableRows = rows.filter {
            $0.verification == .protectedFileProbe || $0.verification == .preciseSystemAPI
        }
        return PermissionPreflightSummary(
            verifiedCount: verifiableRows.count { verifiedStatuses.contains($0.status) },
            verifiableCount: verifiableRows.count
        )
    }

    func refresh() {
        rows = Self.rows(
            fullDiskAccessIsVerified: client.probeFullDiskAccess(),
            accessibilityIsAllowed: client.accessibilityAccessIsAllowed(),
            screenRecordingIsAllowed: client.screenRecordingAccessIsAllowed()
        )
        refreshCount &+= 1
    }

    func performPrimaryAction(for kind: PermissionPreflightKind) {
        settingsOpenFailed = false
        guard let action = rows.first(where: { $0.id == kind })?.action,
              action != .granted,
              action != .verified else {
            return
        }
        switch kind {
        case .accessibility:
            // The Accessibility prompt is asynchronous. Its action opens the
            // matching Settings pane, so do not race it with a second window.
            _ = client.requestAccessibilityAccess()
        case .screenRecording:
            if !client.requestScreenRecordingAccess() {
                settingsOpenFailed = !client.openSystemSettings(
                    urls: PermissionSettingsLinks.urls(for: kind)
                )
            }
        case .fullDiskAccess, .filesAndFolders, .systemAudioRecording, .automation,
             .developerTools, .appManagement:
            settingsOpenFailed = !client.openSystemSettings(
                urls: PermissionSettingsLinks.urls(for: kind)
            )
        }
        refresh()
    }

    private static func rows(
        fullDiskAccessIsVerified: Bool,
        accessibilityIsAllowed: Bool,
        screenRecordingIsAllowed: Bool
    ) -> [PermissionPreflightRow] {
        [
            PermissionPreflightRow(
                id: .fullDiskAccess,
                status: fullDiskAccessIsVerified ? .accessVerified : .notVerified,
                verification: .protectedFileProbe,
                detail: "Codeness verifies this only by opening a protected file without reading it. Not Verified can also mean that no probe file exists; macOS does not provide a precise status API.",
                action: fullDiskAccessIsVerified ? .verified : .openSettings
            ),
            PermissionPreflightRow(
                id: .filesAndFolders,
                status: .onDemand,
                verification: .onDemand,
                detail: "macOS asks about protected folders when they are first used. There is no single Files & Folders grant Codeness can preflight.",
                action: .openSettings
            ),
            PermissionPreflightRow(
                id: .accessibility,
                status: accessibilityIsAllowed ? .allowed : .notAllowed,
                verification: .preciseSystemAPI,
                detail: "Needed only when a workflow controls another app through Accessibility. macOS reports this status precisely.",
                action: accessibilityIsAllowed ? .granted : .requestAccess
            ),
            PermissionPreflightRow(
                id: .screenRecording,
                status: screenRecordingIsAllowed ? .allowed : .notAllowed,
                verification: .preciseSystemAPI,
                detail: "Needed only when a workflow captures the screen. macOS reports this grant precisely; system-audio recording is a separate permission.",
                action: screenRecordingIsAllowed ? .granted : .requestAccess
            ),
            PermissionPreflightRow(
                id: .systemAudioRecording,
                status: .verifyInSettings,
                verification: .settingsOnly,
                detail: "Needed only when a workflow records audio from running apps. macOS manages this separately from screen recording and does not provide Codeness with a public preflight or generic request API.",
                action: .openSettings
            ),
            PermissionPreflightRow(
                id: .automation,
                status: .managedPerApp,
                verification: .perApplication,
                detail: "Apple-event access is granted separately for each target app when a workflow first tries to automate it.",
                action: .openSettings
            ),
            PermissionPreflightRow(
                id: .developerTools,
                status: .verifyInSettings,
                verification: .settingsOnly,
                detail: "Some development workflows may require this access. macOS does not provide Codeness with a public status API for it.",
                action: .openSettings
            ),
            PermissionPreflightRow(
                id: .appManagement,
                status: .verifyInSettings,
                verification: .settingsOnly,
                detail: "Some workflows that update or remove other apps may require this access. Verify it in System Settings when relevant.",
                action: .openSettings
            )
        ]
    }
}
