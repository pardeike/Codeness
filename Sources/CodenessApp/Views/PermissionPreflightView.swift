import SwiftUI

struct PermissionPreflightView: View {
    @Bindable var model: PermissionPreflightModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.045)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.rows) { row in
                            permissionRow(row)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                }

                footer
            }
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 620, idealHeight: 700)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: model.summary.systemImage)
                .font(.system(size: 35, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 5) {
                Text("Permission Preflight")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text(model.summary.title)
                    .font(.headline)

                Text(model.summary.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh status without requesting any new permission")
        }
        .padding(.horizontal, 26)
        .padding(.top, 26)
        .padding(.bottom, 18)
        .background(.ultraThinMaterial)
    }

    private func permissionRow(_ row: PermissionPreflightRow) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: row.id.systemImage)
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(row.id.title)
                        .font(.headline)

                    statusBadge(row.status)
                }

                Text(row.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1.5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.performPrimaryAction(for: row.id)
            } label: {
                Label(row.action.title, systemImage: row.action.systemImage)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .fixedSize()
            .disabled(row.action == .granted || row.action == .verified)
            .help(actionHelp(for: row))
        }
        .padding(16)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.075), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func statusBadge(_ status: PermissionPreflightStatus) -> some View {
        Label(status.label, systemImage: status.systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(statusColor(status.presentation))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                statusColor(status.presentation).opacity(0.10),
                in: Capsule()
            )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Status checks never request access. In this window, only a Request Access button can show a macOS permission prompt.",
                systemImage: "hand.raised.fill"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            Label(
                "If System Settings asks to reopen Codeness, do that before starting an unsupervised workflow.",
                systemImage: "arrow.clockwise"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            if model.settingsOpenFailed {
                Label(
                    "System Settings could not be opened. Open Privacy & Security manually.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    private func statusColor(_ presentation: PermissionPreflightStatusPresentation) -> Color {
        switch presentation {
        case .positive: .green
        case .attention: .orange
        case .informational: .secondary
        }
    }

    private func actionHelp(for row: PermissionPreflightRow) -> String {
        switch row.action {
        case .granted:
            "Codeness can currently use \(row.id.title)"
        case .verified:
            "Codeness verified access without reading protected data"
        case .requestAccess:
            "Ask macOS for \(row.id.title) access"
        case .openSettings:
            "Open the \(row.id.title) section in System Settings"
        }
    }
}
