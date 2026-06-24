import Foundation
import Observation
import Combine

@Observable
final class UsageEngine {
    private(set) var usage: WindowUsage = .empty
    private(set) var detectedPlan: ClaudePlan?

    private let parser     = JSONLParser()
    private let calculator = UsageCalculator()
    private let apiClient  = UsageAPIClient()
    private let watcher    = FileWatcher()
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
