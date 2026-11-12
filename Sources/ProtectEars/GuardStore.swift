import AppKit
import LoginItemSupport
import ServiceManagement
import SwiftUI
import VolumeGuardCore

final class GuardStore: ObservableObject {
    @Published private(set) var snapshot = GuardSnapshot()
    @Published private(set) var limit: VolumeLimit
    @Published private(set) var login = LoginItemSnapshot()

    private let defaults = UserDefaults.standard
    private var pinnedUIDs: Set<String>
    private var observers: [NSObjectProtocol] = []
    private lazy var loginController = LoginItemController(
        service: SystemLoginItemService(), preferences: DefaultsLoginItemPreferences(),
        build: LoginItemBuild.identifier())
    private lazy var monitor = GuardMonitor { [weak self] snapshot, learned in
        guard let self else { return }
        if self.snapshot != snapshot { self.snapshot = snapshot }
        if !learned.isEmpty {
            self.pinnedUIDs.formUnion(learned)
            self.saveDevices()
        }
    }

    init() {
        limit = VolumeLimit(rawValue: defaults.integer(forKey: "maximumSteps")) ?? .fourSteps
        pinnedUIDs = Set(defaults.stringArray(forKey: "protectedDeviceUIDs") ?? [])
    }

    func start() {
        monitor.start(limit: limit, pinnedUIDs: pinnedUIDs)
        login = loginController.restoreAfterLaunch()
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.monitor.refresh() })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.login = self.loginController.refresh()
            self.monitor.refresh()
        })
    }

    func stop() { monitor.stop() }

    func setLimit(_ limit: VolumeLimit) {
        self.limit = limit
        defaults.set(limit.rawValue, forKey: "maximumSteps")
        monitor.configure(limit: limit, pinnedUIDs: pinnedUIDs)
    }

    func setProtected(_ selected: Bool, device: OutputDevice) {
        guard !device.isAirPodsMax else { return }
        if selected { pinnedUIDs.insert(device.uid) } else { pinnedUIDs.remove(device.uid) }
        saveDevices()
        monitor.configure(limit: limit, pinnedUIDs: pinnedUIDs)
    }

    func setStartAtLogin(_ enabled: Bool) {
        login = loginController.setEnabled(enabled)
        if login.needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func refresh() { monitor.refresh() }

    func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }

    var heading: String {
        if snapshot.needsAttention { return "Check your headphones" }
        if snapshot.selectedReports.isEmpty { return "Waiting for AirPods Max" }
        return "Volume guard is running"
    }

    var symbol: String {
        snapshot.needsAttention ? "exclamationmark.shield" : "ear.badge.waveform"
    }

    private func saveDevices() {
        defaults.set(pinnedUIDs.sorted(), forKey: "protectedDeviceUIDs")
    }
}
