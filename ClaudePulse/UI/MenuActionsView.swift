import SwiftUI

struct MenuActionsView: View {
    @Environment(\.openSettings) private var openSettings
    var checkForUpdates: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            MenuActionRow(icon: "arrow.up.right.square", label: "Claude Usage", shortcut: "⌘O") {
                if let url = URL(string: "https://claude.ai/settings/usage") {
                    NSWorkspace.shared.open(url)
                }
            }
            MenuActionRow(icon: "gearshape", label: "Settings", shortcut: "⌘,") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuActionRow(icon: "arrow.triangle.2.circlepath", label: "Check for Updates", shortcut: "") {
                checkForUpdates()
            }

            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .opacity(0.4)

            MenuActionRow(icon: "xmark.circle", label: "Quit Claude Pulse", shortcut: "⌘Q", isDestructive: true) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.bottom, 4)
    }
}

struct MenuActionRow: View {
    let icon: String
    let label: String
    let shortcut: String
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(isDestructive ? .red.opacity(0.85) : .secondary)

                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(isDestructive ? .red.opacity(0.9) : .primary)

                Spacer()

                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isHovered ? 0.07 : 0))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { isHovered = $0 }
    }
}
