import Foundation

// MARK: - API data models (shared with widget via UsageCalculator.swift)

// One rate-limit window as returned by the claude.ai usage endpoint.
// `usedPercentage` is 0–100; `resetsAt` is the absolute reset date.
struct RateLimitWindow {
    let usedPercentage: Double
    let resetsAt: Date
}

struct APIUsageData {
    let fiveHour: RateLimitWindow?
    let sevenDay:  RateLimitWindow?
}

// MARK: -

struct WindowUsage {
    let creditsUsed: Double      // Anthropic's credit units (weighted by model)
    let inferenceTokens: Int     // raw input+output tokens (informational)
    let cacheTokens: Int         // cache_read + cache_write (free on subscription)
    let costUSD: Double
    let percentUsed: Double      // creditsUsed / creditCap
    let windowStart: Date
    let windowEnd: Date
    let secondsUntilReset: TimeInterval
    let isActive: Bool
    let weeklyCredits: Double
    let weeklyPercentUsed: Double
    let weeklyWindowEnd: Date

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

    var weeklyResetCountdown: String {
        let secs    = Int(max(0, weeklyWindowEnd.timeIntervalSinceNow))
        let days    = secs / 86400
        let hours   = (secs % 86400) / 3600
        let minutes = (secs % 3600) / 60
        if days > 0  { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets soon"
    }

    var percentInt: Int { Int(percentUsed * 100) }

    var creditString: String    { Self.formatK(Int(creditsUsed)) }
    var weeklyTokenString: String { Self.formatK(Int(weeklyCredits)) }
    var tokenString: String     { Self.formatK(inferenceTokens) }

    static func formatK(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return "\(n / 1_000)K" }
        return "\(n)"
    }

    static var empty: WindowUsage {
        let now = Date()
        return WindowUsage(
            creditsUsed: 0, inferenceTokens: 0, cacheTokens: 0, costUSD: 0,
            percentUsed: 0, windowStart: now,
            windowEnd: now.addingTimeInterval(5 * 3600),
            secondsUntilReset: 5 * 3600, isActive: false,
            weeklyCredits: 0, weeklyPercentUsed: 0,
            weeklyWindowEnd: now.addingTimeInterval(7 * 24 * 3600)
        )
    }

    // Overlay authoritative percentages and reset times from the claude.ai API
    // while keeping the JSONL-derived cost/token breakdown unchanged.
    func applyingAPIUsage(_ api: APIUsageData) -> WindowUsage {
        let sessionPercent: Double
        let newWindowEnd: Date
        let newSecondsUntilReset: TimeInterval

        if let fh = api.fiveHour {
            sessionPercent         = min(fh.usedPercentage / 100.0, 1.0)
            newWindowEnd           = fh.resetsAt
            newSecondsUntilReset   = max(0, fh.resetsAt.timeIntervalSinceNow)
        } else {
            sessionPercent       = percentUsed
            newWindowEnd         = windowEnd
            newSecondsUntilReset = secondsUntilReset
        }

        let weeklyPercent: Double
        let newWeeklyWindowEnd: Date

        if let sd = api.sevenDay {
            weeklyPercent       = min(sd.usedPercentage / 100.0, 1.0)
            newWeeklyWindowEnd  = sd.resetsAt
        } else {
            weeklyPercent      = weeklyPercentUsed
            newWeeklyWindowEnd = weeklyWindowEnd
        }

        return WindowUsage(
            creditsUsed: creditsUsed,
            inferenceTokens: inferenceTokens,
            cacheTokens: cacheTokens,
            costUSD: costUSD,
            percentUsed: sessionPercent,
            windowStart: windowStart,
            windowEnd: newWindowEnd,
            secondsUntilReset: newSecondsUntilReset,
            isActive: isActive,
            weeklyCredits: weeklyCredits,
            weeklyPercentUsed: weeklyPercent,
            weeklyWindowEnd: newWeeklyWindowEnd
        )
    }
}

// MARK: - Credit rates per model (from she-llac.com/claude-limits)
// credits = ceil(input_tokens × input_rate + output_tokens × output_rate)
// Cache reads = 0 credits (free on subscription plans)

private struct CreditRates {
    let input: Double
    let output: Double

    static let haiku  = CreditRates(input: 0.133, output: 0.667)
    static let sonnet = CreditRates(input: 0.4,   output: 2.0)
    static let opus   = CreditRates(input: 0.667, output: 3.333)
    // Fable 5 / Mythos 5 credit rates are not yet confirmed by she-llac.com;
    // using opus rate as a conservative lower bound (actual rate may be higher).
    static let fable  = CreditRates(input: 0.667, output: 3.333)
    static let defaultRates = CreditRates(input: 0.4, output: 2.0)

    static func forModel(_ model: String?) -> CreditRates {
        guard let model else { return defaultRates }
        if model.contains("haiku")  { return haiku }
        if model.contains("fable") || model.contains("mythos") { return fable }
        if model.contains("opus")   { return opus }
        return sonnet
    }
}

final class UsageCalculator {
    static let windowDuration: TimeInterval = 5 * 3600
    static let weekDuration: TimeInterval   = 7 * 24 * 3600
    static let activityCutoff: TimeInterval = 300

    // Session credit caps by plan (from she-llac.com/claude-limits)
    static let creditCapPro:   Double = 550_000
    static let creditCapMax5:  Double = 3_300_000
    static let creditCapMax20: Double = 11_000_000
    static let defaultCreditCap: Double = creditCapPro

    // Weekly credit caps by plan
    static let weeklyCreditCapPro:   Double = 5_000_000
    static let weeklyCreditCapMax5:  Double = 41_666_700
    static let weeklyCreditCapMax20: Double = 83_333_300
    static let defaultWeeklyCreditCap: Double = weeklyCreditCapPro

    func calculate(entries: [JSONLEntry], creditCap: Double, weeklyCreditCap: Double, now: Date = Date()) -> WindowUsage {
        // Deduplicate by requestId — Claude Code writes the same API response multiple
        // times (streaming reconnects). Keep earliest entry per requestId.
        var seenRequestIds = Set<String>()
        let all = entries
            .compactMap { e -> (Date, JSONLEntry)? in
                guard e.message?.role == "assistant",
                      e.message?.usage != nil,
                      let ts = e.timestamp else { return nil }
                if let rid = e.requestId {
                    guard seenRequestIds.insert(rid).inserted else { return nil }
                }
                return (ts, e)
            }
            .sorted { $0.0 < $1.0 }

        guard !all.isEmpty else { return .empty }

        // ── Detect session window start ───────────────────────────────────────
        var windowStart = all[0].0
        for (ts, _) in all.dropFirst() {
            if ts > windowStart.addingTimeInterval(Self.windowDuration) {
                windowStart = ts
            }
        }
        let windowEnd = windowStart.addingTimeInterval(Self.windowDuration)

        // ── Detect weekly window start ────────────────────────────────────────
        // Limit lookback to ~10 days so the rolling algorithm can find one full
        // 7-day boundary without walking back months of old JSONL data.
        let tenDaysAgo = now.addingTimeInterval(-10 * 24 * 3600)
        let weeklyBase = all.filter { $0.0 >= tenDaysAgo }
        let weeklyRoot = weeklyBase.isEmpty ? all : weeklyBase
        var weeklyWindowStart = weeklyRoot[0].0
        for (ts, _) in weeklyRoot.dropFirst() {
            if ts > weeklyWindowStart.addingTimeInterval(Self.weekDuration) {
                weeklyWindowStart = ts
            }
        }
        let weeklyWindowEnd = weeklyWindowStart.addingTimeInterval(Self.weekDuration)

        // ── Accumulate weekly credits ─────────────────────────────────────────
        var weeklyCreditsTotal = 0.0
        for (ts, entry) in all {
            guard ts >= weeklyWindowStart && ts <= now,
                  let usage = entry.message?.usage else { continue }
            let rates = CreditRates.forModel(entry.message?.model)
            let inp = usage.inputTokens ?? 0
            let out = usage.outputTokens ?? 0
            weeklyCreditsTotal += ceil(Double(inp) * rates.input + Double(out) * rates.output)
        }
        let weeklyPercent = weeklyCreditCap > 0 ? min(weeklyCreditsTotal / weeklyCreditCap, 1.0) : 0

        if windowEnd <= now {
            return WindowUsage(
                creditsUsed: 0, inferenceTokens: 0, cacheTokens: 0, costUSD: 0,
                percentUsed: 0, windowStart: now,
                windowEnd: now.addingTimeInterval(Self.windowDuration),
                secondsUntilReset: Self.windowDuration, isActive: false,
                weeklyCredits: weeklyCreditsTotal,
                weeklyPercentUsed: weeklyPercent,
                weeklyWindowEnd: weeklyWindowEnd
            )
        }

        // ── Accumulate session credits ────────────────────────────────────────
        let recentCutoff = now.addingTimeInterval(-Self.activityCutoff)
        var creditsUsed     = 0.0
        var inferenceTokens = 0
        var cacheTokens     = 0
        var totalCost       = 0.0
        var isActive        = false

        for (ts, entry) in all {
            guard ts >= windowStart && ts <= now,
                  let usage = entry.message?.usage else { continue }

            let rates = CreditRates.forModel(entry.message?.model)
            let inp = usage.inputTokens ?? 0
            let out = usage.outputTokens ?? 0
            creditsUsed     += ceil(Double(inp) * rates.input + Double(out) * rates.output)
            inferenceTokens += inp + out
            cacheTokens     += (usage.cacheReadInputTokens ?? 0) + (usage.cacheCreationInputTokens ?? 0)
            totalCost       += usage.cost(for: entry.message?.model)
            if !isActive && ts >= recentCutoff { isActive = true }
        }

        let percent = creditCap > 0 ? min(creditsUsed / creditCap, 1.0) : 0

        return WindowUsage(
            creditsUsed: creditsUsed,
            inferenceTokens: inferenceTokens,
            cacheTokens: cacheTokens,
            costUSD: totalCost,
            percentUsed: percent,
            windowStart: windowStart,
            windowEnd: windowEnd,
            secondsUntilReset: max(0, windowEnd.timeIntervalSince(now)),
            isActive: isActive,
            weeklyCredits: weeklyCreditsTotal,
            weeklyPercentUsed: weeklyPercent,
            weeklyWindowEnd: weeklyWindowEnd
        )
    }
}
