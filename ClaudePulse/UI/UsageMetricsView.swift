import SwiftUI

struct UsageMetricsView: View {
    let usage: WindowUsage

    private func weeklyState(for usage: WindowUsage) -> UsageState {
        UsageState.from(percent: usage.weeklyPercentUsed, isActive: usage.weeklyPercentUsed > 0)
    }

    var body: some View {
        VStack(spacing: 10) {

            // ── 5-hour window ──────────────────────────────────────────────
            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(usage.percentInt)%")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(usage.state.color)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: usage.percentInt)

                    Text(usage.creditString + " credits")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text("5-hour window")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(usage.resetCountdownString)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: usage.secondsUntilReset)

                    Text("until reset")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            UsageProgressBar(percent: usage.percentUsed, state: usage.state)

            // ── Weekly window ──────────────────────────────────────────────
            VStack(spacing: 4) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("This week")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(usage.weeklyTokenString + " credits")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Capsule()
                        .fill(.secondary.opacity(0.12))
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule()
                                    .fill(weeklyState(for: usage).gradient)
                                    .frame(width: geo.size.width * CGFloat(usage.weeklyPercentUsed))
                                    .animation(.easeInOut(duration: 0.5), value: usage.weeklyPercentUsed)
                            }
                        }
                    Text(usage.weeklyResetCountdown)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }

            GuidanceTextView(state: usage.state)
        }
    }
}
