import AppKit
import SwiftUI

enum AboutPresentation {
    static let productSummary =
        "A native supervisor for thoughtful, adaptive work with Codex and Claude."
    static let creatorSummary =
        "Independent tools for people who enjoy making complicated things behave."
    static let patreonURL = URL(string: "https://www.patreon.com/pardeike")!
    static let discordURL = URL(string: "https://discord.gg/CYnWvrbNhD")!

    static func versionText(marketingVersion: String?) -> String? {
        guard let marketingVersion else { return nil }
        let trimmedVersion = marketingVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty else { return nil }
        return "Version \(trimmedVersion)"
    }

    static func versionText(bundle: Bundle) -> String? {
        versionText(
            marketingVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
        )
    }
}

struct AboutView: View {
    let appIcon: NSImage
    let versionText: String?

    init(
        appIcon: NSImage = NSApplication.shared.applicationIconImage,
        versionText: String? = AboutPresentation.versionText(bundle: .main)
    ) {
        self.appIcon = appIcon
        self.versionText = versionText
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.055)
                ],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                productSection

                Divider()
                    .padding(.horizontal, 22)

                creatorSection
            }
            .padding(.horizontal, 36)
            .padding(.top, 48)
            .padding(.bottom, 32)
        }
        .frame(width: 536, height: 570)
    }

    private var productSection: some View {
        VStack(spacing: 12) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityLabel("Codeness app icon")

            VStack(spacing: 5) {
                Text("Codeness")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))

                if let versionText {
                    Text(versionText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text(AboutPresentation.productSummary)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 390)
        }
    }

    private var creatorSection: some View {
        HStack(alignment: .top, spacing: 24) {
            Image("AndreasPortrait")
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 112, height: 112)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .accessibilityLabel("Portrait of Andreas Pardeike")

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Made by Andreas Pardeike")
                        .font(.headline)

                    Text(AboutPresentation.creatorSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }

                VStack(alignment: .leading, spacing: 8) {
                    creatorLink(
                        "Support on Patreon",
                        systemImage: "heart.fill",
                        destination: AboutPresentation.patreonURL
                    )
                    creatorLink(
                        "Join the Brrainz Discord",
                        systemImage: "bubble.left.and.bubble.right.fill",
                        destination: AboutPresentation.discordURL
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
    }

    private func creatorLink(
        _ title: String,
        systemImage: String,
        destination: URL
    ) -> some View {
        Link(destination: destination) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .help("Open \(destination.host() ?? destination.absoluteString) in your browser")
    }
}
