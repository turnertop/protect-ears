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

/// Volume events only check cached targets. Discovery cannot queue ahead of a
/// correction, and duplicate events occupy one dispatch-source slot, not a backlog.
/// This remains a reactive guard, not a filter in the audio signal path.
public final class GuardMonitor {
    private enum VolumeEvent {
        static let check: UInt = 1
        static let output: UInt = 2
    }
    private enum DiscoveryEvent {
        static let inventory: UInt = 1
        static let refresh: UInt = 2
        static let configuration: UInt = 4
        static let restarted: UInt = 8
    }
    private struct Binding: Equatable {
        let device: OutputDevice
        let controls: [VolumeControl]
    }

    private let volumeQueue = DispatchQueue(label: "com.protectears.volume", qos: .userInteractive)
    private let discoveryQueue = DispatchQueue(label: "com.protectears.discovery", qos: .utility)
    private let notificationQueue = DispatchQueue(label: "com.protectears.notifications", qos: .userInteractive)
    private let volumeEvents: DispatchSourceUserDataOr
    private let discoveryEvents: DispatchSourceUserDataOr
    private let hardware: GuardMonitoringHardware
    private let engine: GuardEngine
    private let delivery: SnapshotDelivery

    // Owned by volumeQueue.
    private var active = false
    private var suspended = false
    private var generation: UInt = 0
    private var fallback: DispatchSourceTimer?
    private var pendingCheck: DispatchWorkItem?
    private var lastCheck: UInt64 = 0
    private var devices: [OutputDevice] = []
    private var targets: [OutputDevice] = []
    private var limit: VolumeLimit = .fourSteps
    private var pinnedUIDs: Set<String> = []
    private var snapshot = GuardSnapshot()
    private var lastPublished: GuardSnapshot?

    // Owned by discoveryQueue.
    private var discovering = false
    private var systemObservations: [AudioObservation] = []
    private var deviceObservations: [AudioObservation] = []
    private var bindings: [Binding] = []
    private var scheduledScan: DispatchWorkItem?
    private var scanDeadline: DispatchTime?
    private var lastScan: Double = -.infinity
    private var pendingDiscovery: UInt = 0
    private var recoveryPolicy = AudioRecoveryPolicy()

    public init(hardware: GuardMonitoringHardware = CoreAudioHardware(),
                update: @escaping (GuardSnapshot, Set<String>) -> Void) {
        self.hardware = hardware
        engine = GuardEngine(hardware: hardware)
        delivery = SnapshotDelivery(update: update)
        volumeEvents = DispatchSource.makeUserDataOrSource(queue: volumeQueue)
        discoveryEvents = DispatchSource.makeUserDataOrSource(queue: discoveryQueue)
        volumeEvents.setEventHandler { [weak self] in
            guard let self, self.active, !self.suspended else { return }
            if self.volumeEvents.data & VolumeEvent.output != 0 { self.probeOutput() }
            self.requestCheck()
        }
        discoveryEvents.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.discoveryEvents.data
            self.scheduleScan(flags: flags,
                              immediate: flags & (DiscoveryEvent.refresh | DiscoveryEvent.restarted) != 0)
        }
        volumeEvents.resume()
        discoveryEvents.resume()
    }

    deinit {
        volumeEvents.cancel()
        discoveryEvents.cancel()
        fallback?.cancel()
        pendingCheck?.cancel()
        scheduledScan?.cancel()
    }

    public func start(limit: VolumeLimit, pinnedUIDs: Set<String>) {
        volumeQueue.async { [weak self] in
            guard let self, !self.active else { return }
            self.active = true
            self.suspended = false
            self.limit = limit
            self.pinnedUIDs = pinnedUIDs
            self.lastPublished = nil
            self.delivery.resume()
            self.probeOutput()
            self.check()
        }
        discoveryQueue.async { [weak self] in
            guard let self, !self.discovering else { return }
            self.discovering = true
            self.bindSystem()
            self.scheduleScan(immediate: true)
        }
    }

    public func configure(limit: VolumeLimit, pinnedUIDs: Set<String>) {
        volumeQueue.async { [weak self] in
            guard let self, self.active else { return }
            self.limit = limit
            self.pinnedUIDs = pinnedUIDs
            self.selectTargets()
            self.check()
            self.discoveryEvents.or(data: DiscoveryEvent.inventory)
        }
    }

    public func refresh() {
        volumeEvents.or(data: VolumeEvent.check | VolumeEvent.output)
        discoveryEvents.or(data: DiscoveryEvent.refresh)
    }

    /// Call from the UI/lifecycle thread, never from a hardware callback.
    public func stop() {
        volumeQueue.sync {
            active = false
            generation &+= 1
            targets.removeAll()
            devices.removeAll()
            fallback?.cancel()
            fallback = nil
            pendingCheck?.cancel()
            pendingCheck = nil
            delivery.cancel()
        }
        discoveryQueue.sync {
            discovering = false
            scheduledScan?.cancel()
            scheduledScan = nil
            scanDeadline = nil
            pendingDiscovery = 0
            bindings.removeAll()
            deviceObservations.removeAll()
            systemObservations.removeAll()
        }
    }

    private func bindSystem() {
        systemObservations.removeAll()
        systemObservations = hardware.observeTopology(on: notificationQueue) { [weak self] event in
            guard let self else { return }
            self.volumeEvents.or(data: event == .output ? VolumeEvent.check | VolumeEvent.output : VolumeEvent.check)
            self.discoveryEvents.or(data: event == .serviceRestarted
                ? DiscoveryEvent.restarted : DiscoveryEvent.inventory)
        }
    }

    private func scheduleScan(flags: UInt = 0, after delay: Double = 0, immediate: Bool = false) {
        guard discovering else { return }
        pendingDiscovery |= flags
        let now = DispatchTime.now()
        let uptime = Double(now.uptimeNanoseconds) / 1_000_000_000
        // Metadata notifications can accompany volume changes. Bound discovery
        // to two scans/second even when a driver continuously emits them.
        let wait = max(delay, immediate ? 0 : max(0, lastScan + 0.5 - uptime))
        let deadline = now + wait
        if let scanDeadline, scanDeadline <= deadline { return }
        scheduledScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        scheduledScan = work
        scanDeadline = deadline
        discoveryQueue.asyncAfter(deadline: deadline, execute: work)
    }

    private func scan() {
        scheduledScan = nil
        scanDeadline = nil
        guard discovering else { return }
        let flags = pendingDiscovery
        pendingDiscovery = 0
        lastScan = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        var context = volumeQueue.sync { (active, pinnedUIDs, devices, generation) }
        guard context.0 else { return }
        var forceBinding = flags & (DiscoveryEvent.refresh | DiscoveryEvent.restarted) != 0
        if forceBinding { bindSystem() }
        if forceBinding || flags & DiscoveryEvent.configuration != 0 {
            hardware.invalidateControlCache(deviceID: nil)
        }
        var inventory = hardware.scanOutputDevices(rememberedUIDs: context.1, previous: context.2)
        var recoveryError: String?
        if recoveryPolicy.shouldRecover(failed: inventory.needsClientRecovery, at: Date(),
                                         requested: flags & DiscoveryEvent.refresh != 0) {
            deviceObservations.removeAll()
            systemObservations.removeAll()
            // Drain the short correction queue and suspend HAL access before
            // unloading this process's audio client. No other app is restarted.
            context = volumeQueue.sync {
                check()
                suspended = true
                targets.removeAll()
                devices.removeAll()
                generation &+= 1
                selectTargets()
                return (active, pinnedUIDs, devices, generation)
            }
            guard context.0 else { return }
            do { try hardware.resetAudioClient() }
            catch { recoveryError = error.localizedDescription }
            bindSystem()
            forceBinding = true
            inventory = hardware.scanOutputDevices(rememberedUIDs: context.1, previous: [])
        }
        let defaultID = hardware.defaultOutputID()
        let issues = inventory.issues + (recoveryError.map { [$0] } ?? [])
        let currentTargets: [OutputDevice] = volumeQueue.sync {
            guard active else { return [] }
            if generation == context.3 {
                if devices != inventory.devices { hardware.invalidateControlCache(deviceID: nil) }
                devices = inventory.devices
                snapshot.error = issues.isEmpty ? nil : issues.prefix(3).joined(separator: "\n")
                snapshot.defaultOutputID = defaultID
                suspended = false
                selectTargets()
                // Correct newly discovered outputs before installing listeners.
                check()
            } else {
                // A route event discovered a newer device while this scan ran.
                discoveryEvents.or(data: DiscoveryEvent.inventory)
            }
            return targets
        }
        let desired = currentTargets.map { Binding(device: $0, controls: (try? hardware.volumeControls(for: $0)) ?? []) }
        if forceBinding || desired != bindings {
            deviceObservations.removeAll()
            bindings = desired
            for device in currentTargets {
                deviceObservations += hardware.observeDevice(device, on: notificationQueue) { [weak self] event in
                    guard let self else { return }
                    if event == .volume {
                        self.volumeEvents.or(data: VolumeEvent.check)
                    } else {
                        self.discoveryEvents.or(data: DiscoveryEvent.configuration)
                    }
                }
            }
        }
        scheduleScan(after: inventory.needsClientRecovery || !issues.isEmpty || currentTargets.isEmpty ? 1 : 5)
    }

    /// Only route changes probe the default device; volume events never scan it.
    private func probeOutput() {
        guard active, !suspended else { return }
        snapshot.defaultOutputID = hardware.defaultOutputID()
        guard let id = snapshot.defaultOutputID,
              let device = try? hardware.describeOutputDevice(id) else { return }
        guard !devices.contains(device) else { return }
        devices.removeAll { $0.id == device.id || $0.uid == device.uid }
        devices.append(device)
        hardware.invalidateControlCache(deviceID: nil)
        generation &+= 1
        selectTargets()
    }

    private func selectTargets() {
        targets = devices.filter { pinnedUIDs.contains($0.uid) || $0.isAirPodsMax }
        if targets.isEmpty {
            fallback?.cancel()
            fallback = nil
        } else if fallback == nil {
            let timer = DispatchSource.makeTimerSource(queue: volumeQueue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100),
                           leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.check() }
            fallback = timer
            timer.resume()
        }
    }

    private func check() {
        guard active, !suspended else { return }
        pendingCheck?.cancel()
        pendingCheck = nil
        lastCheck = DispatchTime.now().uptimeNanoseconds
        let result = engine.enforce(devices: targets, limit: limit, pinnedUIDs: pinnedUIDs)
        let learned = result.learnedUIDs.subtracting(pinnedUIDs)
        pinnedUIDs.formUnion(learned)
        let reports = Dictionary(uniqueKeysWithValues: result.reports.map { ($0.id, $0) })
        snapshot.reports = devices.map {
            reports[$0.id] ?? DeviceReport(device: $0, state: .unselected, volume: nil, muted: false, detail: nil)
        }
        if result.clampedDevices > 0 {
            snapshot.clampCount += result.clampedDevices
            snapshot.lastClamp = Date()
        }
        if result.reports.contains(where: { $0.state == .failed || $0.volume == nil }) {
            discoveryEvents.or(data: DiscoveryEvent.inventory)
        }
        if snapshot != lastPublished || !learned.isEmpty {
            lastPublished = snapshot
            delivery.submit(snapshot, learned: learned)
        }
    }

    private func requestCheck() {
        guard pendingCheck == nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let next = lastCheck + 5_000_000
        if now >= next {
            check()
        } else {
            // The first ordinary event runs immediately. Only notifications in
            // the same 5 ms burst share one follow-up, including our own writes.
            let work = DispatchWorkItem { [weak self] in
                self?.pendingCheck = nil
                self?.check()
            }
            pendingCheck = work
            volumeQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: next), execute: work)
        }
    }
}

/// Latest-state delivery bounds UI work even while the main thread is busy.
private final class SnapshotDelivery {
    private let lock = NSLock()
    private let update: (GuardSnapshot, Set<String>) -> Void
    private var pending: (GuardSnapshot, Set<String>)?
    private var scheduled = false
    private var active = false

    init(update: @escaping (GuardSnapshot, Set<String>) -> Void) { self.update = update }
    func resume() { lock.lock(); active = true; lock.unlock() }
    func cancel() { lock.lock(); active = false; pending = nil; lock.unlock() }

    func submit(_ snapshot: GuardSnapshot, learned: Set<String>) {
        lock.lock()
        guard active else { lock.unlock(); return }
        pending = (snapshot, learned.union(pending?.1 ?? []))
        let enqueue = !scheduled
        scheduled = true
        lock.unlock()
        guard enqueue else { return }
        // Only display work is delayed/coalesced; hardware correction already ran.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let value = self.active ? self.pending : nil
            self.pending = nil
            self.scheduled = false
            self.lock.unlock()
            if let value { self.update(value.0, value.1) }
        }
    }
}
