import Foundation

struct WindowUsage {
    // Inference tokens = input + output (what Anthropic rate-limits on).
    // Cache tokens excluded — empirically not counted toward the 5h window cap.
    let inferenceTokens: Int
    let cacheTokens: Int
    let costUSD: Double
    let percentUsed: Double        // inferenceTokens / tokenCap, or 0 if tokenCap == 0
    let windowStart: Date
    let windowEnd: Date
    let secondsUntilReset: TimeInterval
    let isActive: Bool

    // Weekly rollup (last 7 days)
    let weeklyTokens: Int

    var state: UsageState {
        UsageState.from(percent: percentUsed, isActive: isActive)
    }

    var resetCountdownString: String {
        let total = Int(secondsUntilReset)
        let hours   = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0  { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    var percentInt: Int { Int(percentUsed * 100) }

    var tokenString: String { Self.formatK(inferenceTokens) }
    var weeklyTokenString: String { Self.formatK(weeklyTokens) }

    static func formatK(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return "\(n / 1_000)K" }
        return "\(n)"
    }

    static var empty: WindowUsage {
        WindowUsage(inferenceTokens: 0, cacheTokens: 0, costUSD: 0, percentUsed: 0,
                    windowStart: Date(), windowEnd: Date().addingTimeInterval(5 * 3600),
                    secondsUntilReset: 5 * 3600, isActive: false,
                    weeklyTokens: 0)
    }
}

final class UsageCalculator {
    static let windowDuration: TimeInterval = 5 * 3600   // 5 hours
    static let weekDuration: TimeInterval   = 7 * 24 * 3600
    // Empirically derived: 207K output tokens = 41% of cap → cap ≈ 500K.
    // Cache reads are NOT counted — Anthropic excludes them from rate limits.
    static let defaultTokenCap: Int         = 500_000
    static let activityCutoff: TimeInterval = 300        // "active" if request in last 5 min

    func calculate(entries: [JSONLEntry], tokenCap: Int, now: Date = Date()) -> WindowUsage {
        // Collect all assistant entries with valid timestamps, sorted oldest→newest
        let all = entries
            .compactMap { e -> (Date, JSONLEntry)? in
                guard e.message?.role == "assistant",
                      e.message?.usage != nil,
                      let ts = e.timestamp else { return nil }
                return (ts, e)
            }
            .sorted { $0.0 < $1.0 }

        guard !all.isEmpty else { return .empty }

        // ── Detect the actual Anthropic window start ──────────────────────────
        // Anthropic's window: starts at the first request, lasts exactly 5h.
        // A new window starts when the previous window's 5h have elapsed.
        var windowStart = all[0].0
        for (ts, _) in all.dropFirst() {
            if ts > windowStart.addingTimeInterval(Self.windowDuration) {
                windowStart = ts      // previous window expired; this request starts a new one
            }
        }
        let windowEnd = windowStart.addingTimeInterval(Self.windowDuration)

        // If the window has fully expired with no new request, return empty
        if windowEnd <= now {
            return WindowUsage(inferenceTokens: 0, cacheTokens: 0, costUSD: 0, percentUsed: 0,
                               windowStart: now, windowEnd: now.addingTimeInterval(Self.windowDuration),
                               secondsUntilReset: Self.windowDuration, isActive: false,
                               weeklyTokens: weeklyTokens(from: all, now: now))
        }

        // ── Count tokens in the current window ────────────────────────────────
        let recentCutoff = now.addingTimeInterval(-Self.activityCutoff)
        var inferenceTokens = 0
        var cacheTokens     = 0
        var totalCost       = 0.0
        var isActive        = false

        for (ts, entry) in all {
            guard ts >= windowStart && ts <= now,
                  let usage = entry.message?.usage else { continue }
            inferenceTokens += (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0)
            cacheTokens     += (usage.cacheReadInputTokens ?? 0) + (usage.cacheCreationInputTokens ?? 0)
            totalCost       += usage.cost(for: entry.message?.model)
            if !isActive && ts >= recentCutoff { isActive = true }
        }

        let percent = tokenCap > 0 ? min(Double(inferenceTokens) / Double(tokenCap), 1.0) : 0

        return WindowUsage(
            inferenceTokens: inferenceTokens,
            cacheTokens: cacheTokens,
            costUSD: totalCost,
            percentUsed: percent,
            windowStart: windowStart,
            windowEnd: windowEnd,
            secondsUntilReset: max(0, windowEnd.timeIntervalSince(now)),
            isActive: isActive,
            weeklyTokens: weeklyTokens(from: all, now: now)
        )
    }

    private func weeklyTokens(from all: [(Date, JSONLEntry)], now: Date) -> Int {
        let weekStart = now.addingTimeInterval(-Self.weekDuration)
        return all.reduce(0) { sum, pair in
            let (ts, entry) = pair
            guard ts >= weekStart && ts <= now,
                  let usage = entry.message?.usage else { return sum }
            return sum + (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0)
        }
    }
}
