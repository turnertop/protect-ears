import Foundation

public struct GuardSnapshot: Equatable {
    public var reports: [DeviceReport] = []
    public var error: String?
    public var clampCount: Int = 0
    public var lastClamp: Date?
    public var defaultOutputID: UInt32?

    public init() {}
    public var selectedReports: [DeviceReport] { reports.filter(\.isProtected) }
    public var needsAttention: Bool {
        error != nil || selectedReports.contains { $0.state != .monitoring }
    }
}

/// Core Audio notifications and a 250 ms fallback run independently of the UI.
/// This is a reactive volume guard, not a filter in the audio signal path.
public final class GuardMonitor {
    private let queue = DispatchQueue(label: "com.protectears.volume", qos: .userInteractive)
    private let hardware: CoreAudioHardware
    private let engine: GuardEngine
    private let update: (GuardSnapshot, Set<String>) -> Void
    private var systemObservations: [AudioObservation] = []
    private var deviceObservations: [AudioObservation] = []
    private var timer: DispatchSourceTimer?
    private var devices: [OutputDevice] = []
    private var limit: VolumeLimit = .fourSteps
    private var pinnedUIDs: Set<String> = []
    private var snapshot = GuardSnapshot()
    private var lastInventory = Date.distantPast
    private var lastBinding = Date.distantPast

    public init(hardware: CoreAudioHardware = CoreAudioHardware(),
                update: @escaping (GuardSnapshot, Set<String>) -> Void) {
        self.hardware = hardware
        self.engine = GuardEngine(hardware: hardware)
        self.update = update
    }

    public func start(limit: VolumeLimit, pinnedUIDs: Set<String>) {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.limit = limit
            self.pinnedUIDs = pinnedUIDs
            self.bindSystem()
            self.check(refreshInventory: true, rebind: true)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250),
                           leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.check() }
            self.timer = timer
            timer.resume()
        }
    }

    public func configure(limit: VolumeLimit, pinnedUIDs: Set<String>) {
        queue.async { [weak self] in
            guard let self else { return }
            self.limit = limit
            self.pinnedUIDs = pinnedUIDs
            self.check(refreshInventory: true, rebind: true)
        }
    }

    public func refresh() {
        queue.async { [weak self] in
            self?.bindSystem()
            self?.check(refreshInventory: true, rebind: true)
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            deviceObservations.removeAll()
            systemObservations.removeAll()
        }
    }

    private func bindSystem() {
        systemObservations.removeAll()
        systemObservations = hardware.observeTopology(on: queue) { [weak self] in
            // Defer replacement until the current listener has returned. A Core
            // Audio service restart invalidates both system and device listeners.
            self?.queue.async { [weak self] in
                self?.bindSystem()
                self?.check(refreshInventory: true, rebind: true)
            }
        }
    }

    private func check(refreshInventory: Bool = false, rebind: Bool = false) {
        let now = Date()
        var inventoryChanged = false
        if refreshInventory || now.timeIntervalSince(lastInventory) >= 1 {
            do {
                let current = try hardware.outputDevices()
                inventoryChanged = current != devices
                devices = current
                snapshot.error = nil
            } catch {
                // Keep enforcing the last known devices if enumeration fails.
                snapshot.error = "Could not refresh audio devices. \(error.localizedDescription)"
            }
            lastInventory = now
        }

        // Clamp before any UI work or listener installation.
        let result = engine.enforce(devices: devices, limit: limit, pinnedUIDs: pinnedUIDs)
        let learned = result.learnedUIDs.subtracting(pinnedUIDs)
        pinnedUIDs.formUnion(learned)
        snapshot.reports = result.reports
        snapshot.defaultOutputID = hardware.defaultOutputID()
        if result.clampedDevices > 0 {
            snapshot.clampCount += result.clampedDevices
            snapshot.lastClamp = now
        }

        // Periodic rebinding recovers a driver that silently rebuilds its controls.
        if inventoryChanged || rebind || now.timeIntervalSince(lastBinding) >= 10 {
            deviceObservations.removeAll()
            for device in devices where device.isAirPodsMax || pinnedUIDs.contains(device.uid) {
                deviceObservations += hardware.observeDevice(device, on: queue) { [weak self] in
                    self?.queue.async { [weak self] in self?.check(refreshInventory: true) }
                }
            }
            lastBinding = now
        }

        let value = snapshot
        DispatchQueue.main.async { [update] in update(value, learned) }
    }
}
