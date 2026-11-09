import AudioToolbox
import CoreAudio
import Foundation

public struct AudioFailure: LocalizedError {
    public let operation: String
    public let status: OSStatus
    public var errorDescription: String? { "\(operation) failed (Core Audio \(status))." }
}

public final class AudioObservation {
    private var cancelBlock: (() -> Void)?
    init(cancel: @escaping () -> Void) { cancelBlock = cancel }
    public func cancel() { cancelBlock?(); cancelBlock = nil }
    deinit { cancel() }
}

public final class CoreAudioHardware: VolumeHardware {
    public init() {}

    public func outputDevices() throws -> [OutputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let ids: [AudioDeviceID] = try array(system, address(kAudioHardwarePropertyDevices))
        return try ids.compactMap { id in
            let streams: [AudioStreamID] = try array(id, address(kAudioDevicePropertyStreams, output: true))
            guard !streams.isEmpty else { return nil }
            let alive: UInt32 = try scalar(id, address(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0))
            guard alive != 0 else { return nil }
            return OutputDevice(
                id: id,
                uid: try string(id, address(kAudioDevicePropertyDeviceUID)),
                name: try string(id, address(kAudioObjectPropertyName)),
                channelCount: try outputChannelCount(id)
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func defaultOutputID() -> UInt32? {
        try? scalar(AudioObjectID(kAudioObjectSystemObject),
                    address(kAudioHardwarePropertyDefaultOutputDevice), initial: UInt32(0))
    }

    public func volumeControls(for device: OutputDevice) throws -> [VolumeControl] {
        // Include individual channels even when a main control exists, so an
        // asymmetric channel cannot hide behind an average volume reading.
        let direct = (0...device.channelCount).compactMap { element -> VolumeControl? in
            var property = address(kAudioDevicePropertyVolumeScalar, output: true, element: element)
            return AudioObjectHasProperty(device.id, &property)
                ? VolumeControl(selector: property.mSelector, element: element) : nil
        }
        if !direct.isEmpty { return direct }
        var virtual = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, output: true)
        return AudioObjectHasProperty(device.id, &virtual)
            ? [VolumeControl(selector: virtual.mSelector, element: 0)] : []
    }

    public func readVolume(_ control: VolumeControl, on device: OutputDevice) throws -> Float {
        try scalar(device.id, address(control.selector, output: true, element: control.element), initial: Float(0))
    }

    public func writeVolume(_ value: Float, control: VolumeControl, on device: OutputDevice) throws {
        var property = address(control.selector, output: true, element: control.element)
        var writable: DarwinBoolean = false
        try check(AudioObjectIsPropertySettable(device.id, &property, &writable), "Check volume control")
        guard writable.boolValue else {
            throw AudioFailure(operation: "Output volume is read-only", status: kAudioHardwareIllegalOperationError)
        }
        var volume = value
        try check(AudioObjectSetPropertyData(device.id, &property, 0, nil,
                                            UInt32(MemoryLayout<Float>.size), &volume), "Set output volume")
    }

    public func emergencyMute(_ device: OutputDevice) -> Bool {
        if isMuted(device) { return true }
        let elements = muteElements(device)
        guard !elements.isEmpty else { return false }
        for element in elements {
            var property = address(kAudioDevicePropertyMute, output: true, element: element)
            var writable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device.id, &property, &writable) == noErr,
                  writable.boolValue else { continue }
            var muted: UInt32 = 1
            _ = AudioObjectSetPropertyData(device.id, &property, 0, nil,
                                           UInt32(MemoryLayout<UInt32>.size), &muted)
        }
        return isMuted(device)
    }

    public func isMuted(_ device: OutputDevice) -> Bool {
        let elements = muteElements(device)
        guard !elements.isEmpty else { return false }
        let states = elements.map {
            (try? scalar(device.id, address(kAudioDevicePropertyMute, output: true, element: $0),
                         initial: UInt32(0))) == 1
        }
        // A main mute covers the device; otherwise every output channel must mute.
        if elements.first == 0, states.first == true { return true }
        let channelStates = zip(elements, states).filter { $0.0 != 0 }
        return device.channelCount > 0 && channelStates.count == Int(device.channelCount)
            && channelStates.allSatisfy { $0.1 }
    }

    public func observeTopology(on queue: DispatchQueue, handler: @escaping () -> Void) -> [AudioObservation] {
        [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
         kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioHardwarePropertyServiceRestarted].compactMap {
            observe(AudioObjectID(kAudioObjectSystemObject), address($0), on: queue, handler: handler)
        }
    }

    public func observeDevice(_ device: OutputDevice, on queue: DispatchQueue,
                              handler: @escaping () -> Void) -> [AudioObservation] {
        var properties = [
            address(kAudioDevicePropertyDeviceHasChanged),
            address(kAudioDevicePropertyDeviceIsAlive),
            address(kAudioDevicePropertyStreamConfiguration, output: true),
            address(kAudioDevicePropertyNominalSampleRate)
        ]
        for element in 0...device.channelCount {
            properties.append(address(kAudioDevicePropertyVolumeScalar, output: true, element: element))
            properties.append(address(kAudioDevicePropertyMute, output: true, element: element))
        }
        properties.append(address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, output: true))
        return properties.compactMap { observe(device.id, $0, on: queue, handler: handler) }
    }

    private func observe(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress,
                         on queue: DispatchQueue, handler: @escaping () -> Void) -> AudioObservation? {
        var property = property
        guard AudioObjectHasProperty(id, &property) else { return nil }
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(id, &property, queue, block) == noErr else { return nil }
        return AudioObservation {
            _ = AudioObjectRemovePropertyListenerBlock(id, &property, queue, block)
        }
    }

    private func muteElements(_ device: OutputDevice) -> [UInt32] {
        (0...device.channelCount).filter {
            var property = address(kAudioDevicePropertyMute, output: true, element: $0)
            return AudioObjectHasProperty(device.id, &property)
        }
    }

    private func outputChannelCount(_ id: AudioDeviceID) throws -> UInt32 {
        var property = address(kAudioDevicePropertyStreamConfiguration, output: true)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "Read output configuration size")
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, memory), "Read output configuration")
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }

    private func scalar<T>(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress, initial: T) throws -> T {
        var property = property
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0)
        }
        try check(status, "Read audio property")
        return value
    }

    private func string(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress) throws -> String {
        let value: CFString = try scalar(id, property, initial: "" as CFString)
        return value as String
    }

    private func array<T>(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress) throws -> [T] {
        var property = property
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "Read audio list size")
        guard size > 0 else { return [] }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { memory.deallocate() }
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, memory), "Read audio list")
        return Array(UnsafeBufferPointer(start: memory.assumingMemoryBound(to: T.self),
                                         count: Int(size) / MemoryLayout<T>.stride))
    }

    private func address(_ selector: AudioObjectPropertySelector, output: Bool = false,
                         element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
                                   mElement: element)
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw AudioFailure(operation: operation, status: status) }
    }
}
