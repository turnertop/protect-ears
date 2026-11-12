import Foundation

public enum AudioSystemChange: Equatable { case devices, output, serviceRestarted }
public enum AudioDeviceChange: Equatable { case volume, configuration }

/// Property reads may run concurrently on discovery and correction queues.
/// The monitor serializes client resets after suspending correction access.
public protocol GuardMonitoringHardware: VolumeHardware {
    func scanOutputDevices(rememberedUIDs: Set<String>, previous: [OutputDevice]) -> OutputDeviceInventory
    func preferredOutputIDs() -> [UInt32]
    func describeOutputDevice(_ id: UInt32) throws -> OutputDevice?
    func defaultOutputID() -> UInt32?
    func resetAudioClient() throws
    func invalidateControlCache(deviceID: UInt32?)
    func observeTopology(on queue: DispatchQueue,
                         handler: @escaping (AudioSystemChange) -> Void) -> [AudioObservation]
    func observeDevice(_ device: OutputDevice, on queue: DispatchQueue,
                       handler: @escaping (AudioDeviceChange) -> Void) -> [AudioObservation]
}

/// Never send a mute/write to an object ID that now belongs to another device.
public struct StaleAudioDevice: LocalizedError {
    public init() {}
    public var errorDescription: String? { "The audio device changed identity; refreshing its connection." }
}
