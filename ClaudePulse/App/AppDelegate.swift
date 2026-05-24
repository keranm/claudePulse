import AppKit
import SwiftUI
import Combine
import WidgetKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?

    let engine              = UsageEngine()
    let notificationManager = NotificationManager()
    let settings            = SettingsStore()
    private var updaterController: SPUStandardUpdaterController!

    private var updateTimer: Timer?
    private var settingsCancellable: AnyCancellable?

    // Cache to avoid redundant menu bar redraws
    private var lastRenderedState:   UsageState?
    private var lastRenderedPercent: Int = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        engine.settings = settings
        notificationManager.notificationsEnabled = settings.notificationsEnabled

        setupStatusItem()
        setupPopover()
        engine.start()

        // Propagate notifications toggle changes immediately
        settingsCancellable = settings.$notificationsEnabled.sink { [weak self] enabled in
            self?.notificationManager.notificationsEnabled = enabled
        }

        // UI update + notification check every 15s (notifications have internal guards)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.updateMenuBarItem()
            self?.notificationManager.check(usage: self?.engine.usage ?? .empty)
        }
        updateTimer?.tolerance = 3

        notificationManager.requestAuthorization()
        updateMenuBarItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
        settingsCancellable?.cancel()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    func updateMenuBarItem() {
        guard let button = statusItem.button else { return }
        let usage   = engine.usage
        let state   = usage.state
        let percent = usage.percentInt

        // Skip redraw if nothing changed
        if state == lastRenderedState && percent == lastRenderedPercent { return }
        lastRenderedState   = state
        lastRenderedPercent = percent

        let icon = MenuBarIcon.image(percent: usage.percentUsed, state: state)

        let title: String
        switch state {
        case .idle:                title = " Claude —"
        case .healthy, .warning:   title = " Claude \(percent)%"
        case .critical:            title = " Claude !"
        case .resetting:           title = " Claude ↺"
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: state == .idle ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]

        button.image           = icon
        button.imagePosition   = .imageLeft
        button.attributedTitle = NSAttributedString(string: title, attributes: attrs)

        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.setValue(true, forKeyPath: "shouldHideAnchor")

        let checkForUpdates: () -> Void = { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }
        let hostingController = NSHostingController(rootView: PopoverView(engine: engine, checkForUpdates: checkForUpdates))
        hostingController.view.setFrameSize(NSSize(width: 280, height: 300))
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 280, height: 300)
    }

    @objc private func togglePopover(_ sender: Any?) {
        popover.isShown ? closePopover() : openPopover()
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in self?.closePopover() }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
