import SwiftUI

struct UsageMetricsView: View {
    let usage: WindowUsage

    private func weeklyState(for usage: WindowUsage) -> UsageState {
        UsageState.from(percent: usage.weeklyPercentUsed, isActive: usage.weeklyPercentUsed > 0)
    }

    private var hasBreakdown: Bool {
        usage.percentUsed > 0 || usage.cliPercentUsed > 0
    }

    private var cliState: UsageState {
        UsageState.from(percent: usage.cliPercentUsed, isActive: usage.isActive)
    }

    @ViewBuilder
    private func sourceRow(label: String, detail: String, percent: Double, state: UsageState, indent: Bool, cost: Double? = nil, unavailable: Bool = false) -> some View {
        HStack(spacing: 0) {
            if indent { Spacer().frame(width: 12) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 11, weight: indent ? .regular : .medium))
                        .foregroundStyle(.secondary)
                    if !detail.isEmpty {
                        Text("· \(detail)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    if let cost {
                        Text("· \(cost < 0.01 ? "<$0.01" : String(format: "$%.2f", cost)) credit")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if unavailable {
                        Text("unavailable")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("\(Int(percent * 100))%")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if !unavailable {
                    Capsule()
                        .fill(.secondary.opacity(0.12))
                        .frame(height: 5)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule()
                                    .fill(state.gradient)
                                    .frame(width: geo.size.width * CGFloat(min(percent, 1.0)))
                                    .animation(.easeInOut(duration: 0.5), value: percent)
                            }
                        }
                }
            }
        }
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
                        .padding(.top, 4)
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

            // ── Source breakdown (shown when API total > JSONL CLI usage) ──
            if hasBreakdown {
                VStack(spacing: 8) {
                    sourceRow(label: "Total", detail: "all surfaces", percent: usage.percentUsed, state: usage.state, indent: false)
                    sourceRow(label: "Claude Code", detail: "", percent: usage.cliPercentUsed, state: cliState, indent: true, cost: usage.costUSD)
                    sourceRow(label: "Other devices & web", detail: usage.hasAPIData ? "~estimated" : "", percent: max(0, usage.percentUsed - usage.cliPercentUsed), state: usage.state, indent: true, unavailable: !usage.hasAPIData)
                }
                .padding(.top, 4)
            }

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
