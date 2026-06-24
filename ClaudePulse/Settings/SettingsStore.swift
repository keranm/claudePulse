import Foundation
import ServiceManagement

enum ClaudePlan: String, CaseIterable {
    case pro   = "Pro"
    case max5  = "Max 5×"
    case max20 = "Max 20×"

    var creditCap: Double {
        switch self {
        case .pro:   return UsageCalculator.creditCapPro
        case .max5:  return UsageCalculator.creditCapMax5
        case .max20: return UsageCalculator.creditCapMax20
        }
    }

    var weeklyCreditCap: Double {
        switch self {
        case .pro:   return UsageCalculator.weeklyCreditCapPro
        case .max5:  return UsageCalculator.weeklyCreditCapMax5
        case .max20: return UsageCalculator.weeklyCreditCapMax20
        }
    }
}

final class SettingsStore: ObservableObject {
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    init() {
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        registerOnFirstLaunch()
    }

    private func registerOnFirstLaunch() {
        let key = "hasRegisteredLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: key)
        launchAtLogin = true
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("SMAppService error: \(error)")
        }
    }
}
