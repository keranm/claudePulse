import Foundation
import Observation
import Combine
import os

@Observable
final class UsageEngine {
    private(set) var usage: WindowUsage = .empty
    private(set) var detectedPlan: ClaudePlan?

    private let parser     = JSONLParser()
    private let calculator = UsageCalculator()
    private let apiClient  = UsageAPIClient()
    private let watcher    = FileWatcher()
    private let calibrationLogger = CalibrationLogger()
    private var countdownTimer: Timer?
    private var settingsCancellable: AnyCancellable?
    private let claudeDir: URL

    // Debounce: ignore rapid successive file-system events
    private var debounceTask: Task<Void, Never>?

    var settings: SettingsStore? {
        didSet { observeSettings() }
    }

    init() {
        claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    func start() {
        watcher.onChange = { [weak self] in self?.scheduleRefresh() }
        watcher.start(path: claudeDir.path)

        // Refresh countdown display every 60s even without file activity
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        countdownTimer?.tolerance = 10
        refresh()
    }

    func stop() {
        watcher.stop()
        countdownTimer?.invalidate()
        countdownTimer = nil
        settingsCancellable?.cancel()
        debounceTask?.cancel()
    }

    // Debounce rapid FSEvents (burst writes coalesce within 0.5s)
    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    func refresh() {
        let dir = claudeDir
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            // API provides the authoritative percentage — covers all devices and surfaces.
            // Fetch first so detectedPlan is set before we pick the credit caps.
            let apiData = try? await self.apiClient.fetchUsage()

            // Use plan detected from Keychain; fall back to Pro caps if unavailable.
            let plan      = self.apiClient.detectedPlan
            let cap       = plan?.creditCap       ?? UsageCalculator.defaultCreditCap
            let weeklyCap = plan?.weeklyCreditCap ?? UsageCalculator.defaultWeeklyCreditCap

            // JSONL provides cost, token counts, and activity detection
            let entries = self.loadAllEntries(from: dir)
            var result  = self.calculator.calculate(entries: entries, creditCap: cap, weeklyCreditCap: weeklyCap)

            if let apiData {
                result = result.applyingAPIUsage(apiData)
            }

            // Capture a calibration sample pairing the local Claude-Code credit
            // estimate with Anthropic's authoritative all-surfaces %, so the
            // session caps can later be recalibrated. See CalibrationLogger.
            self.calibrationLogger.record(CalibrationSample(
                timestamp: Date(),
                windowStart: result.windowStart,
                hasAPIData: result.hasAPIData,
                apiUtilizationPct: apiData?.fiveHour?.usedPercentage ?? -1,
                cliCredits: result.creditsUsed,
                cacheCreationTokens: result.cacheCreationTokens,
                cacheReadTokens: result.cacheReadTokens,
                inputOutputTokens: result.inferenceTokens,
                creditCap: result.creditCap,
                plan: plan?.rawValue
            ))

            await MainActor.run {
                self.detectedPlan = plan
                self.usage = result
            }
        }
    }

    private func observeSettings() {
        settingsCancellable?.cancel()
        guard let settings else { return }
        settingsCancellable = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    private func loadAllEntries(from dir: URL) -> [JSONLEntry] {
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return projectDirs.flatMap { projectDir -> [JSONLEntry] in
            guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return [] }
            return jsonlFiles(under: projectDir).flatMap { parser.parse(fileURL: $0) }
        }
    }

    // Recursively collect all .jsonl files under a directory (catches subagents/ subdirs).
    private func jsonlFiles(under dir: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return items.flatMap { item -> [URL] in
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return jsonlFiles(under: item)
            }
            return item.pathExtension == "jsonl" ? [item] : []
        }
    }

    deinit { stop() }
}

// MARK: - Calibration logging

// One paired observation: the local Claude-Code credit estimate (cache-exclusive,
// the current formula) alongside Anthropic's authoritative all-surfaces 5-hour %,
// plus the cache-token split. Accumulating these lets us later fit the session
// cap against real utilization and detect whether cache-creation tokens need to
// count toward credits (residuals correlated with cacheCreationTokens ⇒ yes).
struct CalibrationSample: Codable {
    let timestamp: Date
    let windowStart: Date
    let hasAPIData: Bool
    let apiUtilizationPct: Double   // authoritative all-surfaces 5-hour %, 0–100
    let cliCredits: Double          // local Claude-Code-only credits (input+output)
    let cacheCreationTokens: Int    // local Claude Code cache write tokens in window
    let cacheReadTokens: Int        // local Claude Code cache read tokens in window
    let inputOutputTokens: Int      // local Claude Code input+output tokens in window
    let creditCap: Double           // plan session cap in effect
    let plan: String?
}

// Appends calibration samples as JSONL to Application Support. Best-effort: any
// failure is logged and ignored so it never affects the UI. Writes are serialized
// and de-duplicated so idle 60s refresh ticks don't bloat the file.
final class CalibrationLogger {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.claudepulse.calibration")
    private let log = Logger(subsystem: "com.claudepulse.app", category: "calibration")
    private var lastSignature: String?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init() {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("ClaudePulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("calibration.jsonl")
    }

    func record(_ sample: CalibrationSample) {
        // Only useful once we have an authoritative % to pair against.
        guard sample.apiUtilizationPct >= 0 else { return }

        queue.sync {
            let signature = "\(sample.windowStart.timeIntervalSince1970)|\(sample.apiUtilizationPct)|\(Int(sample.cliCredits))|\(sample.cacheCreationTokens)"
            guard signature != lastSignature else { return }
            lastSignature = signature

            guard var data = try? Self.encoder.encode(sample) else { return }
            data.append(0x0A)  // newline delimiter

            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: fileURL, options: .atomic)
                }
            } catch {
                log.error("calibration write failed: \(error.localizedDescription)")
            }
        }
    }
}
