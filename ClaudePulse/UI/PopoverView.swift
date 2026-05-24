import SwiftUI

struct PopoverView: View {
    var engine: UsageEngine
    var checkForUpdates: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeaderView(isActive: engine.usage.isActive)

            Divider().opacity(0.25)

            UsageMetricsView(usage: engine.usage)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)

            Divider().opacity(0.25)

            MenuActionsView(checkForUpdates: checkForUpdates)
        }
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
