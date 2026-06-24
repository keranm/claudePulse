import SwiftUI

@main
struct ClaudePulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(settings: appDelegate.settings, detectedPlan: appDelegate.engine.detectedPlan)
        }
    }
}
