import SwiftUI

struct PopoverHeaderView: View {
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image("InAppIcon")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 22, height: 22)

            Text("Claude Pulse")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(isActive ? Color(red: 0.2, green: 0.78, blue: 0.35) : Color.gray)
                    .frame(width: 7, height: 7)
                Text(isActive ? "Active" : "Idle")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 6)
    }
}
