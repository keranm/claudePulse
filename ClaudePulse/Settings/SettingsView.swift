import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    var detectedPlan: ClaudePlan?

    var body: some View {
        Form {
            Section("Claude Plan") {
                if let plan = detectedPlan {
                    HStack {
                        Text("Plan")
                        Spacer()
                        Text(plan.rawValue)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("5-hour session cap")
                        Spacer()
                        Text(formattedCap(plan.creditCap))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Weekly cap")
                        Spacer()
                        Text(formattedCap(plan.weeklyCreditCap))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        Text("Plan not detected — open Claude Code to authenticate")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }

                Link(destination: URL(string: "https://claude.ai/upgrade")!) {
                    HStack(spacing: 4) {
                        Text("Manage your plan on Claude.ai")
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                    }
                }
                .foregroundStyle(.blue)
            }

            Section("Notifications") {
                Toggle("Enable usage warnings", isOn: $settings.notificationsEnabled)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 320)
        .navigationTitle("Claude Pulse Settings")
    }

    private func formattedCap(_ cap: Double) -> String {
        if cap >= 1_000_000 { return String(format: "%.1fM credits", cap / 1_000_000) }
        return "\(Int(cap) / 1_000)K credits"
    }
}
