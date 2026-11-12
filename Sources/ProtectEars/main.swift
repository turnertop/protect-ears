import AppKit
import Combine
import LoginItemSupport
import ServiceManagement
import SwiftUI
import VolumeGuardCore

private func diagnostics() -> Int32 {
    let hardware = CoreAudioHardware()
    do {
        print("Audio diagnostics. No volume or mute settings are changed.")
        if CommandLine.arguments.contains("--reset-audio-client") {
            // Exercise recovery in this diagnostic process, leaving other apps alone.
            _ = hardware.scanOutputDevices()
            try hardware.resetAudioClient()
            print("Reinitialized this diagnostic process's Core Audio connection.")
        }
        let inventory = hardware.scanOutputDevices()
        let devices = inventory.devices
        let defaultID = hardware.defaultOutputID()
        print("AirPods Max detection uses the device name, then remembers its UID in the app.")
        for issue in inventory.issues { print("Inventory warning: \(issue)") }
        for device in devices {
            let controls = try hardware.volumeControls(for: device)
            let volumes = controls.map { control -> String in
                do { return String(format: "%.2f%%", try hardware.readVolume(control, on: device) * 100) }
                catch { return "unreadable: \(error.localizedDescription)" }
            }
            print("\(device.id == defaultID ? "*" : " ") \(device.name)")
            print("  AirPods Max: \(device.isAirPodsMax); output channels: \(device.channelCount)")
            print("  Volume controls: \(volumes.isEmpty ? "none" : volumes.joined(separator: ", "))")
            if device.isAirPodsMax {
                let resolved = try hardware.deviceID(forUID: device.uid)
                print("  Independent identity lookup: \(resolved == device.id ? "matches" : "unavailable")")
            }
        }
        if devices.isEmpty { print("No live output devices found.") }
        return inventory.devices.isEmpty && !inventory.issues.isEmpty ? 1 : 0
    } catch {
        fputs("Audio diagnostics failed: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = GuardStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var subscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let app = existing.first {
            app.activate(options: [.activateIgnoringOtherApps])
            NSApplication.shared.terminate(nil)
            return
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: GuardView(store: store))
        subscription = Publishers.CombineLatest(store.$snapshot, store.$limit)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateStatusItem()
        }
        store.start()
        updateStatusItem()

        // Login launches stay quiet. Opening the app explicitly shows its controls.
        if NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue != keyAELaunchedAsLogInItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showPopover() }
        }
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("App launched; menu-bar item and SwiftUI controls initialized.")
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { store.stop() }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateStatusItem() {
        let attention = store.snapshot.needsAttention
        let image = NSImage(systemSymbolName: attention ? "exclamationmark.shield" : "ear.badge.waveform",
                            accessibilityDescription: "Protect Ears")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.title = " \(store.limit.rawValue)"
        statusItem?.button?.toolTip = "Protect Ears · \(store.heading) · \(store.limit.percent) ceiling"
    }
}

if CommandLine.arguments.contains("--login-status") || CommandLine.arguments.contains("--prepare-for-update")
    || CommandLine.arguments.contains("--restore-login-registration") {
    let controller = LoginItemController(service: SystemLoginItemService(),
                                         preferences: DefaultsLoginItemPreferences(), build: LoginItemBuild.identifier())
    // Status is read-only: do not migrate, repair, or change a login preference.
    if CommandLine.arguments.contains("--login-status") {
        let record = DefaultsLoginItemPreferences().record
        let payload: [String: Any] = ["status": SMAppService.mainApp.status.rawValue,
                                      "requested": record.map { $0.requested as Any } ?? NSNull(),
                                      "preparedForUpdate": record?.preparedForUpdate ?? false]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        let preparing = CommandLine.arguments.contains("--prepare-for-update")
        let result = preparing ? controller.prepareForUpdate() : controller.restoreAfterLaunch()
        if let error = result.error { fputs("\(error)\n", stderr); exit(1) }
        print("\(preparing ? "Prepared" : "Restored") login preference: \(result.requested ? "on" : "off").")
    }
    exit(0)
} else if CommandLine.arguments.contains("--diagnose") {
    exit(diagnostics())
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
