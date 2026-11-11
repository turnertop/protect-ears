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
    private var recoveryPolicy = AudioRecoveryPolicy()

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
            self?.check(refreshInventory: true, rebind: true, requestedRecovery: true)
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

    private func check(refreshInventory: Bool = false, rebind: Bool = false, requestedRecovery: Bool = false) {
        let now = Date()
        var inventoryChanged = false
        var learnedDuringRecovery: Set<String> = []
        if refreshInventory || now.timeIntervalSince(lastInventory) >= 1 {
            var inventory = hardware.scanOutputDevices(rememberedUIDs: pinnedUIDs, previous: devices)
            var recoveryError: String?
            if recoveryPolicy.shouldRecover(failed: inventory.needsClientRecovery, at: now,
                                             requested: requestedRecovery) {
                // Reduce any already-readable target before resetting the local client.
                let beforeReset = engine.enforce(devices: inventory.devices, limit: limit, pinnedUIDs: pinnedUIDs)
                learnedDuringRecovery.formUnion(beforeReset.learnedUIDs.subtracting(pinnedUIDs))
                pinnedUIDs.formUnion(beforeReset.learnedUIDs)
                if beforeReset.clampedDevices > 0 {
                    snapshot.clampCount += beforeReset.clampedDevices
                    snapshot.lastClamp = now
                }
                deviceObservations.removeAll()
                systemObservations.removeAll()
                devices.removeAll()
                do { try hardware.resetAudioClient() }
                catch { recoveryError = error.localizedDescription }
                bindSystem()
                lastBinding = .distantPast
                // Object IDs from before unload must not be reused.
                inventory = hardware.scanOutputDevices(rememberedUIDs: pinnedUIDs)
            }
            inventoryChanged = inventory.devices != devices
            devices = inventory.devices
            let issues = inventory.issues + (recoveryError.map { [$0] } ?? [])
            snapshot.error = issues.isEmpty ? nil : issues.prefix(3).joined(separator: "\n")
            lastInventory = now
        }

        // Clamp before any UI work or listener installation.
        let result = engine.enforce(devices: devices, limit: limit, pinnedUIDs: pinnedUIDs)
        let learned = result.learnedUIDs.subtracting(pinnedUIDs).union(learnedDuringRecovery)
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
