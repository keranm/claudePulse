import WidgetKit
import SwiftUI

// MARK: - Entry

struct ClaudePulseEntry: TimelineEntry {
    let date: Date
    let percent: Double
    let windowEnd: Date
    let stateRaw: String

    var secondsUntilReset: TimeInterval { max(0, windowEnd.timeIntervalSince(date)) }

    var countdownString: String {
        let total   = Int(secondsUntilReset)
        let hours   = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0   { return "\(hours)h \(String(format: "%02d", minutes))m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    var stateColor: Color {
        switch stateRaw {
        case "warning":   return Color(red: 1.0,  green: 0.62, blue: 0.04)
        case "critical":  return Color(red: 0.95, green: 0.23, blue: 0.23)
        case "healthy":   return Color(red: 0.2,  green: 0.78, blue: 0.35)
        case "resetting": return .blue
        default:          return .secondary
        }
    }

    static var placeholder: ClaudePulseEntry {
        ClaudePulseEntry(
            date: Date(),
            percent: 0.55,
            windowEnd: Date().addingTimeInterval(4 * 3600 + 60),
            stateRaw: "warning"
        )
    }
}

// MARK: - Provider

struct ClaudePulseProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClaudePulseEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (ClaudePulseEntry) -> Void) {
        completion(context.isPreview ? .placeholder : buildEntry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudePulseEntry>) -> Void) {
        let now   = Date()
        let entry = buildEntry(at: now)

        // One entry per minute so the countdown stays accurate
        var entries: [ClaudePulseEntry] = []
        var tick = now
        while tick < entry.windowEnd && tick < now.addingTimeInterval(6 * 3600) {
            entries.append(ClaudePulseEntry(
                date: tick,
                percent: entry.percent,
                windowEnd: entry.windowEnd,
                stateRaw: entry.stateRaw
            ))
            tick = tick.addingTimeInterval(60)
        }
        if entries.isEmpty {
            entries.append(ClaudePulseEntry(date: now, percent: 0, windowEnd: now.addingTimeInterval(5 * 3600), stateRaw: "idle"))
        }

        completion(Timeline(entries: entries, policy: .after(entry.windowEnd)))
    }

    // MARK: - JSONL loading (mirrors UsageEngine logic)

    private func buildEntry(at now: Date) -> ClaudePulseEntry {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        let entries  = loadAllEntries(from: claudeDir)
        let usage    = UsageCalculator().calculate(
            entries: entries,
            creditCap: UsageCalculator.creditCapPro,
            weeklyCreditCap: UsageCalculator.weeklyCreditCapPro,
            now: now
        )

        let stateRaw: String
        switch usage.state {
        case .idle:      stateRaw = "idle"
        case .healthy:   stateRaw = "healthy"
        case .warning:   stateRaw = "warning"
        case .critical:  stateRaw = "critical"
        case .resetting: stateRaw = "resetting"
        }

        return ClaudePulseEntry(
            date: now,
            percent: usage.percentUsed,
            windowEnd: usage.windowEnd,
            stateRaw: stateRaw
        )
    }

    private func loadAllEntries(from dir: URL) -> [JSONLEntry] {
        let parser = JSONLParser()
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else { return [] }
        return projectDirs.flatMap { projectDir -> [JSONLEntry] in
            guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return [] }
            return jsonlFiles(under: projectDir).flatMap { parser.parse(fileURL: $0) }
        }
    }

    private func jsonlFiles(under dir: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else { return [] }
        return items.flatMap { item -> [URL] in
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return jsonlFiles(under: item)
            }
            return item.pathExtension == "jsonl" ? [item] : []
        }
    }
}

// MARK: - View

struct ClaudePulseWidgetView: View {
    let entry: ClaudePulseEntry

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 14)

                Circle()
                    .trim(from: 0, to: entry.percent)
                    .stroke(entry.stateColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 1) {
                    Text("\(Int(entry.percent * 100))%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text(entry.countdownString)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                    Text("until reset")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .padding(18)

            Circle()
                .fill(entry.stateColor)
                .frame(width: 8, height: 8)
                .padding(10)
        }
        .containerBackground(.background, for: .widget)
    }
}

// MARK: - Widget

@main
struct ClaudePulseWidgetBundle: Widget {
    let kind = "ClaudePulseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClaudePulseProvider()) { entry in
            ClaudePulseWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Pulse")
        .description("Monitor your Claude Code usage and time until reset.")
        .supportedFamilies([.systemSmall])
    }
}
