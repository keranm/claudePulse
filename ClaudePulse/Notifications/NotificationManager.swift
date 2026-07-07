import UserNotifications
import Foundation

final class NotificationManager {
    private var firedThresholds: Set<String> = []
    private var lastKnownPercent: Double = 0

    // Injected from SettingsStore so the user toggle is respected
    var notificationsEnabled: Bool = true

    func requestAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func check(usage: WindowUsage) {
        let percent = usage.percentUsed

        // Detect window reset: sharp drop after meaningful prior usage
        if lastKnownPercent > 0.10 && percent < 0.05 && !firedThresholds.isEmpty {
            firedThresholds.removeAll()
            guard notificationsEnabled else { lastKnownPercent = percent; return }
            fire(
                id: "reset-\(Int(Date().timeIntervalSince1970))",
                title: "Claude Pulse — Window Reset",
                body: "Your Claude window has reset. Good to go for another session.",
                sound: nil
            )
        }

        guard notificationsEnabled else { lastKnownPercent = percent; return }

        if percent >= 0.90 && !firedThresholds.contains("critical") {
            fire(
                id: "critical",
                title: "Claude Pulse — Quota Critical",
                body: "Quota exhaustion likely soon. Large tasks may fail before reset.",
                sound: .default
            )
            firedThresholds.insert("critical")
            firedThresholds.remove("warning")   // re-arm for the next window
        } else if percent >= 0.70 && !firedThresholds.contains("warning") {
            fire(
                id: "warning",
                title: "Claude Pulse — Approaching Limit",
                body: "You've used \(Int(percent * 100))% of your 5-hour window. Resets in \(usage.resetCountdownString).",
                sound: .default
            )
            firedThresholds.insert("warning")
        }

        lastKnownPercent = percent
    }

    private func fire(id: String, title: String, body: String, sound: UNNotificationSound?) {
        let content       = UNMutableNotificationContent()
        content.title     = title
        content.body      = body
        if let sound      { content.sound = sound }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
