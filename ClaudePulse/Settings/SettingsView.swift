import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Claude Plan") {
                Picker("Plan", selection: $settings.plan) {
                    ForEach(ClaudePlan.allCases, id: \.self) { plan in
                        Text(plan.rawValue).tag(plan)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("5-hour session cap")
                    Spacer()
                    Text(formattedSessionCap)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Text("Credit limits from she-llac.com/claude-limits. Credits weight tokens by model: Sonnet input=0.4, output=2.0; Haiku input=0.133, output=0.667; Opus input=0.667, output=3.333. Cache reads are free.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Enable usage warnings", isOn: $settings.notificationsEnabled)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }

            Text("Claude Pulse reads your locally stored JSONL files to estimate usage. It will never be as accurate as /usage within Claude Code or Anthropic's web interface.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 360)
        .navigationTitle("Claude Pulse Settings")
    }

    private var formattedSessionCap: String {
        let cap = settings.creditCap
        if cap >= 1_000_000 { return String(format: "%.1fM credits", cap / 1_000_000) }
        return "\(Int(cap) / 1_000)K credits"
    }
}
