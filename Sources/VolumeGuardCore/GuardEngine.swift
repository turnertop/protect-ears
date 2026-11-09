import Foundation

public enum VolumeLimit: Int, CaseIterable {
    case fourSteps = 4
    case fiveSteps = 5

    public var scalar: Float { Float(rawValue) / 16 }
    public var percent: String { self == .fourSteps ? "25%" : "31.25%" }
}

public struct OutputDevice: Equatable, Identifiable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public let channelCount: UInt32

    public init(id: UInt32, uid: String, name: String, channelCount: UInt32) {
        self.id = id
        self.uid = uid
        self.name = name
        self.channelCount = channelCount
    }

    public var isAirPodsMax: Bool {
        name.range(of: #"airpods[\s\p{P}]*max\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
}

public struct VolumeControl: Hashable {
    public let selector: UInt32
    public let element: UInt32

    public init(selector: UInt32, element: UInt32) {
        self.selector = selector
        self.element = element
    }
}

public protocol VolumeHardware: AnyObject {
    func outputDevices() throws -> [OutputDevice]
    func volumeControls(for device: OutputDevice) throws -> [VolumeControl]
    func readVolume(_ control: VolumeControl, on device: OutputDevice) throws -> Float
    func writeVolume(_ value: Float, control: VolumeControl, on device: OutputDevice) throws
    /// Only sets mute ON. Nothing in the guard ever unmutes a device.
    func emergencyMute(_ device: OutputDevice) -> Bool
    func isMuted(_ device: OutputDevice) -> Bool
}

public struct DeviceReport: Equatable, Identifiable {
    public enum State: Equatable {
        case monitoring
        case mutedAfterFailure
        case failed
        case unselected
    }

    public var id: UInt32 { device.id }
    public let device: OutputDevice
    public let state: State
    public let volume: Float?
    public let muted: Bool
    public let detail: String?
    public var isProtected: Bool { state != .unselected }
}

public struct GuardResult {
    public let reports: [DeviceReport]
    public let clampedDevices: Int
    public let learnedUIDs: Set<String>
}

/// Serial, synchronous policy layer. Tests use simulated hardware; they never play sound.
public final class GuardEngine {
    private let hardware: VolumeHardware
    // Prevent a later successful check from concealing an emergency mute.
    private var emergencyUIDs: Set<String> = []

    public init(hardware: VolumeHardware) { self.hardware = hardware }

    public func enforce(devices: [OutputDevice], limit: VolumeLimit, pinnedUIDs: Set<String>) -> GuardResult {
        var reports: [DeviceReport] = []
        var clamped = 0
        var learned: Set<String> = []

        for device in devices {
            let selected = device.isAirPodsMax || pinnedUIDs.contains(device.uid)
            guard selected else {
                reports.append(DeviceReport(device: device, state: .unselected, volume: nil,
                                            muted: false, detail: nil))
                continue
            }
            if device.isAirPodsMax { learned.insert(device.uid) }

            do {
                let controls = try hardware.volumeControls(for: device)
                guard !controls.isEmpty else { throw GuardFailure.noVolumeControl }
                var didLower = false

                for control in controls {
                    var current = try validVolume(control, device)
                    guard current > limit.scalar + 0.00001 else { continue }

                    // Drivers can quantize a requested value upward. Retry below the
                    // ceiling, and verify the value rather than trusting a successful write.
                    for attempt in 0..<3 where current > limit.scalar + 0.00001 {
                        let target = max(0, limit.scalar - Float(attempt) / 64)
                        try hardware.writeVolume(min(current, target), control: control, on: device)
                        current = try validVolume(control, device)
                    }
                    guard current <= limit.scalar + 0.00001 else {
                        throw GuardFailure.didNotAcceptLimit
                    }
                    didLower = true
                }

                // Re-read every control: changing a virtual control can affect others.
                let finalValues = try controls.map { try validVolume($0, device) }
                guard finalValues.allSatisfy({ $0 <= limit.scalar + 0.00001 }) else {
                    throw GuardFailure.didNotAcceptLimit
                }
                let muted = hardware.isMuted(device)
                if !muted { emergencyUIDs.remove(device.uid) }
                let previouslyMuted = emergencyUIDs.contains(device.uid)
                reports.append(DeviceReport(
                    device: device, state: previouslyMuted ? .mutedAfterFailure : .monitoring,
                    volume: finalValues.max(), muted: muted,
                    detail: previouslyMuted ? "Muted after an earlier control error. Check volume before unmuting in Sound settings." : nil
                ))
                if didLower { clamped += 1 }
            } catch {
                let muted = hardware.emergencyMute(device)
                if muted { emergencyUIDs.insert(device.uid) }
                reports.append(DeviceReport(
                    device: device, state: muted ? .mutedAfterFailure : .failed,
                    volume: nil, muted: muted,
                    detail: "\(error.localizedDescription) " + (muted
                        ? "Device muted. Check volume in Sound settings."
                        : "Could not verify a cap or mute this device. Pause playback.")
                ))
            }
        }

        return GuardResult(reports: reports, clampedDevices: clamped, learnedUIDs: learned)
    }

    private func validVolume(_ control: VolumeControl, _ device: OutputDevice) throws -> Float {
        let value = try hardware.readVolume(control, on: device)
        guard value.isFinite, (0...1).contains(value) else { throw GuardFailure.invalidVolume }
        return value
    }
}

private enum GuardFailure: LocalizedError {
    case noVolumeControl, invalidVolume, didNotAcceptLimit

    var errorDescription: String? {
        switch self {
        case .noVolumeControl: return "No readable output-volume control."
        case .invalidVolume: return "The device returned an invalid volume."
        case .didNotAcceptLimit: return "The device did not accept the volume ceiling."
        }
    }
}
