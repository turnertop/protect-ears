import Foundation
import VolumeGuardCore

final class MonitorChecks {
    var checks: [(String, () -> Void)] {
        [
            ("testCorrectionDoesNotWaitForBlockedInventory", correctionDoesNotWaitForBlockedInventory),
            ("testVolumeBurstDoesNotRescanOrRebind", volumeBurstDoesNotRescanOrRebind),
            ("testConfigurationStormHasBoundedDiscovery", configurationStormHasBoundedDiscovery),
            ("testFallbackCorrectsWithoutNotification", fallbackCorrectsWithoutNotification),
            ("testDisconnectedGuardDoesNotPollVolume", disconnectedGuardDoesNotPollVolume),
            ("testNewerRouteSurvivesStaleScan", newerRouteSurvivesStaleScan),
            ("testLearnedIdentitiesSurviveCoalescedUI", learnedIdentitiesSurviveCoalescedUI),
            ("testResetSerializesHALAndResumesGuard", resetSerializesHALAndResumesGuard),
            ("testStopDiscardsPendingUpdates", stopDiscardsPendingUpdates)
        ]
    }

    private func start(_ hardware: MonitorHardware,
                       update: @escaping (GuardSnapshot, Set<String>) -> Void = { _, _ in }) -> GuardMonitor {
        let monitor = GuardMonitor(hardware: hardware, update: update)
        monitor.start(limit: .fiveSteps, pinnedUIDs: [])
        expectTrue(waitFor { hardware.scanCount > 0 && hardware.bindingCount > 0 })
        pump(0.08)
        return monitor
    }

    private func correctionDoesNotWaitForBlockedInventory() {
        let hardware = MonitorHardware()
        let monitor = start(hardware)
        let pause = HardwarePause()
        hardware.pauseNextScan(pause)
        monitor.refresh()
        expectEqual(pause.entered.wait(timeout: .now() + 1), .success)
        hardware.setVolume(0.5)
        hardware.emitDevice(.volume)
        // Do not run the UI loop or release discovery until correction succeeds.
        expectEqual(hardware.corrected.wait(timeout: .now() + 1), .success)
        expectLessThanOrEqual(hardware.volume(), VolumeLimit.fiveSteps.scalar)
        pause.resume.signal()
        monitor.stop()
    }

    private func volumeBurstDoesNotRescanOrRebind() {
        let hardware = MonitorHardware()
        var updates = 0
        let monitor = start(hardware) { _, _ in updates += 1 }
        let scans = hardware.scanCount
        let bindings = hardware.bindingCount
        let reads = hardware.readCount
        let originalUpdates = updates
        hardware.setVolume(0.5)
        hardware.emitDevice(.volume, count: 10_000)
        expectEqual(hardware.corrected.wait(timeout: .now() + 1), .success)
        pump(0.2)
        expectEqual(hardware.scanCount, scans)
        expectEqual(hardware.bindingCount, bindings)
        expectLessThanOrEqual(hardware.readCount - reads, 100)
        expectLessThanOrEqual(updates - originalUpdates, 2)
        monitor.stop()
    }

    private func configurationStormHasBoundedDiscovery() {
        let hardware = MonitorHardware()
        let monitor = start(hardware)
        let scans = hardware.scanCount
        let bindings = hardware.bindingCount
        hardware.emitDevice(.configuration, count: 10_000)
        pump(0.7)
        expectTrue(hardware.scanCount > scans)
        expectLessThanOrEqual(hardware.scanCount - scans, 2)
        expectEqual(hardware.bindingCount, bindings)
        monitor.stop()
    }

    private func fallbackCorrectsWithoutNotification() {
        let hardware = MonitorHardware()
        let monitor = start(hardware)
        hardware.setVolume(0.5)
        expectEqual(hardware.corrected.wait(timeout: .now() + 1), .success)
        expectLessThanOrEqual(hardware.volume(), VolumeLimit.fiveSteps.scalar)
        monitor.stop()
    }

    private func disconnectedGuardDoesNotPollVolume() {
        let hardware = MonitorHardware()
        hardware.replaceDevices([MonitorHardware.speaker], defaultID: MonitorHardware.speaker.id)
        let monitor = GuardMonitor(hardware: hardware) { _, _ in }
        monitor.start(limit: .fiveSteps, pinnedUIDs: [])
        expectTrue(waitFor { hardware.scanCount > 0 })
        pump(0.35)
        expectEqual(hardware.readCount, 0)
        expectEqual(hardware.bindingCount, 0)
        monitor.stop()
    }

    private func newerRouteSurvivesStaleScan() {
        let hardware = MonitorHardware()
        var snapshot = GuardSnapshot()
        let monitor = start(hardware) { value, _ in snapshot = value }
        let pause = HardwarePause()
        hardware.pauseNextScan(pause)
        monitor.refresh()
        expectEqual(pause.entered.wait(timeout: .now() + 1), .success)
        let reconnected = OutputDevice(id: 99, uid: MonitorHardware.headphones.uid,
                                       name: "Renamed headphones", channelCount: 2)
        let reused = OutputDevice(id: MonitorHardware.headphones.id, uid: "different-speakers",
                                  name: "Other speakers", channelCount: 2)
        hardware.replaceDevices([reconnected, reused], defaultID: 99)
        hardware.setVolume(0.8, id: reused.id)
        hardware.setVolume(0.5, id: 99)
        hardware.emitSystem(.output)
        expectEqual(hardware.corrected.wait(timeout: .now() + 1), .success)
        expectEqual(hardware.volume(id: reused.id), 0.8)
        pause.resume.signal()
        expectTrue(waitFor { snapshot.selectedReports.first?.id == 99 })
        pump(0.6)
        expectEqual(snapshot.selectedReports.first?.id, 99)
        expectEqual(hardware.volume(id: reused.id), 0.8)
        expectEqual(hardware.staleWrites, 0)
        monitor.stop()
    }

    private func learnedIdentitiesSurviveCoalescedUI() {
        let hardware = MonitorHardware()
        let second = OutputDevice(id: 42, uid: "second-pair", name: "Second AirPods Max", channelCount: 2)
        hardware.replaceDevices([MonitorHardware.headphones, second], defaultID: MonitorHardware.headphones.id)
        var learned: Set<String> = []
        let monitor = start(hardware) { _, value in learned.formUnion(value) }
        expectTrue(waitFor { learned == [MonitorHardware.headphones.uid, second.uid] })
        monitor.stop()
    }

    private func resetSerializesHALAndResumesGuard() {
        let hardware = MonitorHardware()
        let monitor = start(hardware)
        let pause = HardwarePause()
        hardware.failInventoryAndPauseReset(pause)
        monitor.refresh()
        expectEqual(pause.entered.wait(timeout: .now() + 1), .success)
        let reads = hardware.readCount
        hardware.setVolume(0.5)
        monitor.refresh()
        pump(0.15)
        expectEqual(hardware.readCount, reads)
        expectEqual(hardware.accessesDuringReset, 0)
        pause.resume.signal()
        expectTrue(waitFor { hardware.volume() <= VolumeLimit.fiveSteps.scalar })
        expectEqual(hardware.resetCount, 1)
        monitor.stop()
    }

    private func stopDiscardsPendingUpdates() {
        let hardware = MonitorHardware()
        var updates = 0
        let monitor = start(hardware) { _, _ in updates += 1 }
        hardware.setVolume(0.5)
        hardware.emitDevice(.volume)
        expectEqual(hardware.corrected.wait(timeout: .now() + 1), .success)
        monitor.stop()
        let count = updates
        pump(0.15)
        expectEqual(updates, count)
        let reads = hardware.readCount
        pump(0.15)
        expectEqual(hardware.readCount, reads)
    }
}

private func pump(_ interval: TimeInterval) {
    let end = Date().addingTimeInterval(interval)
    while Date() < end { _ = RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.005))) }
}

private func waitFor(_ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(1)
    repeat {
        if condition() { return true }
        pump(0.005)
    } while Date() < end
    return condition()
}

private final class HardwarePause {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    func wait() {
        entered.signal()
        _ = resume.wait(timeout: .now() + 3)
    }
}

/// Thread-safe fake for the real monitor queues; no Core Audio calls or sound.
private final class MonitorHardware: GuardMonitoringHardware {
    static let headphones = OutputDevice(id: 10, uid: "test-airpods", name: "Test AirPods Max", channelCount: 2)
    static let speaker = OutputDevice(id: 20, uid: "test-speakers", name: "Speakers", channelCount: 2)
    private let lock = NSLock()
    private var devices = [headphones, speaker]
    private var defaultID: UInt32? = headphones.id
    private var values: [UInt32: Float] = [:]
    private var scans = 0, bindings = 0, reads = 0, resets = 0, stale = 0, duringReset = 0
    private var resetting = false, broken = false
    private var scanPause: HardwarePause?, resetPause: HardwarePause?
    private var deviceListeners: [UUID: (UInt32, DispatchQueue, (AudioDeviceChange) -> Void)] = [:]
    private var systemListeners: [UUID: (DispatchQueue, (AudioSystemChange) -> Void)] = [:]
    let corrected = DispatchSemaphore(value: 0)
    var scanCount: Int { locked { scans } }
    var bindingCount: Int { locked { bindings } }
    var readCount: Int { locked { reads } }
    var resetCount: Int { locked { resets } }
    var staleWrites: Int { locked { stale } }
    var accessesDuringReset: Int { locked { duringReset } }

    func setVolume(_ value: Float, id: UInt32 = headphones.id) { locked { values[id] = value } }
    func volume(id: UInt32 = headphones.id) -> Float { locked { values[id] ?? 0.2 } }
    func replaceDevices(_ new: [OutputDevice], defaultID: UInt32?) { locked { devices = new; self.defaultID = defaultID } }
    func pauseNextScan(_ pause: HardwarePause) { locked { scanPause = pause } }
    func failInventoryAndPauseReset(_ pause: HardwarePause) { locked { broken = true; resetPause = pause } }

    func outputDevices() throws -> [OutputDevice] { locked { devices } }
    func scanOutputDevices(rememberedUIDs: Set<String>, previous: [OutputDevice]) -> OutputDeviceInventory {
        let (inventory, pause): (OutputDeviceInventory, HardwarePause?) = locked {
            touchedHAL()
            scans += 1
            let pause = scanPause
            scanPause = nil
            return (OutputDeviceInventory(devices: devices, systemListFailed: broken), pause)
        }
        pause?.wait()
        return inventory
    }
    func defaultOutputID() -> UInt32? { locked { touchedHAL(); return defaultID } }
    func preferredOutputIDs() -> [UInt32] { defaultOutputID().map { [$0] } ?? [] }
    func describeOutputDevice(_ id: UInt32) throws -> OutputDevice? {
        locked { touchedHAL(); return devices.first { $0.id == id } }
    }
    func volumeControls(for device: OutputDevice) throws -> [VolumeControl] {
        locked { touchedHAL(); return [VolumeControl(selector: 1, element: 0)] }
    }
    func readVolume(_ control: VolumeControl, on device: OutputDevice) throws -> Float {
        locked { touchedHAL(); reads += 1; return values[device.id] ?? 0.2 }
    }
    func writeVolume(_ value: Float, control: VolumeControl, on device: OutputDevice) throws {
        try locked {
            touchedHAL()
            guard devices.first(where: { $0.id == device.id })?.uid == device.uid else {
                stale += 1
                throw StaleAudioDevice()
            }
            values[device.id] = value
        }
        corrected.signal()
        emitDevice(.volume, id: device.id)
    }
    func isMuted(_ device: OutputDevice) -> Bool { locked { touchedHAL(); return false } }
    func emergencyMute(_ device: OutputDevice) -> Bool { false }
    func invalidateControlCache(deviceID: UInt32?) {}
    func resetAudioClient() throws {
        let pause: HardwarePause? = locked {
            resets += 1
            resetting = true
            let pause = resetPause
            resetPause = nil
            return pause
        }
        pause?.wait()
        locked { resetting = false; broken = false }
    }
    func observeTopology(on queue: DispatchQueue,
                         handler: @escaping (AudioSystemChange) -> Void) -> [AudioObservation] {
        let token = UUID()
        locked { systemListeners[token] = (queue, handler) }
        return [AudioObservation { [weak self] in _ = self?.locked { self?.systemListeners.removeValue(forKey: token) } }]
    }
    func observeDevice(_ device: OutputDevice, on queue: DispatchQueue,
                       handler: @escaping (AudioDeviceChange) -> Void) -> [AudioObservation] {
        let token = UUID()
        locked { bindings += 1; deviceListeners[token] = (device.id, queue, handler) }
        return [AudioObservation { [weak self] in _ = self?.locked { self?.deviceListeners.removeValue(forKey: token) } }]
    }
    func emitDevice(_ event: AudioDeviceChange, count: Int = 1, id: UInt32 = headphones.id) {
        let listeners = locked { Array(deviceListeners.values).filter { $0.0 == id } }
        for (_, queue, handler) in listeners { queue.async { for _ in 0..<count { handler(event) } } }
    }
    func emitSystem(_ event: AudioSystemChange) {
        let listeners = locked { Array(systemListeners.values) }
        for (queue, handler) in listeners { queue.async { handler(event) } }
    }
    private func touchedHAL() { if resetting { duringReset += 1 } }
    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
