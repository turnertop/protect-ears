import AudioToolbox
import CoreAudio
import Foundation

public struct AudioFailure: LocalizedError {
    public let operation: String
    public let status: OSStatus
    public let objectID: UInt32?
    public let propertySelector: UInt32?
    public let propertyScope: UInt32?

    public init(operation: String, status: OSStatus, objectID: UInt32? = nil,
                propertySelector: UInt32? = nil, propertyScope: UInt32? = nil) {
        self.operation = operation
        self.status = status
        self.objectID = objectID
        self.propertySelector = propertySelector
        self.propertyScope = propertyScope
    }

    public var errorDescription: String? {
        var context = ["Core Audio \(status) '\(Self.code(UInt32(bitPattern: status)))'"]
        if let objectID { context.append("object \(objectID)") }
        if let propertySelector { context.append("property '\(Self.code(propertySelector))'") }
        if let propertyScope { context.append("scope '\(Self.code(propertyScope))'") }
        return "\(operation) failed (\(context.joined(separator: ", ")))."
    }

    private static func code(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        return bytes.allSatisfy { (32...126).contains($0) }
            ? String(bytes: bytes, encoding: .ascii)! : String(format: "0x%08x", value)
    }
}

public final class AudioObservation {
    private var cancelBlock: (() -> Void)?
    public init(cancel: @escaping () -> Void) { cancelBlock = cancel }
    public func cancel() { cancelBlock?(); cancelBlock = nil }
    deinit { cancel() }
}

public final class CoreAudioHardware: GuardMonitoringHardware, OutputDeviceCatalog {
    private struct DeviceKey: Hashable {
        let id: UInt32
        let uid: String
        let channels: UInt32
        init(_ device: OutputDevice) { id = device.id; uid = device.uid; channels = device.channelCount }
    }
    private let cacheLock = NSLock()
    private var volumeCache: [DeviceKey: [VolumeControl]] = [:]
    private var muteCache: [DeviceKey: [UInt32]] = [:]
    public init() {}

    public func outputDevices() throws -> [OutputDevice] {
        let inventory = scanOutputDevices()
        if inventory.devices.isEmpty, let issue = inventory.issues.first {
            throw NSError(domain: "ProtectEars.AudioInventory", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: issue])
        }
        return inventory.devices
    }

    public func scanOutputDevices(rememberedUIDs: Set<String> = [], previous: [OutputDevice] = []) -> OutputDeviceInventory {
        OutputDeviceScanner(catalog: self).scan(rememberedUIDs: rememberedUIDs, previous: previous)
    }

    public func allDeviceIDs() throws -> [UInt32] {
        try array(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices))
    }

    public func preferredOutputIDs() -> [UInt32] {
        [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice].compactMap {
            try? scalar(AudioObjectID(kAudioObjectSystemObject), address($0), initial: UInt32(0))
        }.filter { $0 != kAudioObjectUnknown }
    }

    public func deviceID(forUID uid: String) throws -> UInt32? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var property = address(kAudioHardwarePropertyTranslateUIDToDevice)
        let uidString = uid as CFString
        var qualifier = Unmanaged.passUnretained(uidString)
        var id: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withExtendedLifetime(uidString) {
            withUnsafePointer(to: &qualifier) { pointer in
                AudioObjectGetPropertyData(system, &property,
                    UInt32(MemoryLayout<Unmanaged<CFString>>.size), pointer, &size, &id)
            }
        }
        try check(status, "Resolve output identity", objectID: system, property: property)
        return id == kAudioObjectUnknown ? nil : id
    }

    public func describeOutputDevice(_ id: UInt32) throws -> OutputDevice? {
        // Some input-only/virtual devices do not implement output-stream properties.
        // Stream configuration already provides the actual output channel count.
        var configuration = address(kAudioDevicePropertyStreamConfiguration, output: true)
        guard AudioObjectHasProperty(id, &configuration) else { return nil }
        let channels = try outputChannelCount(id)
        guard channels > 0 else { return nil }
        let alive: UInt32 = try scalar(id, address(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0))
        guard alive != 0 else { return nil }
        return OutputDevice(id: id, uid: try string(id, address(kAudioDevicePropertyDeviceUID)),
                            name: try string(id, address(kAudioObjectPropertyName)), channelCount: channels)
    }

    public func resetAudioClient() throws {
        // This app performs no audio I/O. Unload resets only this process's HAL;
        // callers must remove its listeners and discard object IDs first.
        invalidateControlCache(deviceID: nil)
        try check(AudioHardwareUnload(), "Reconnect audio client")
    }

    public func defaultOutputID() -> UInt32? {
        try? scalar(AudioObjectID(kAudioObjectSystemObject),
                    address(kAudioHardwarePropertyDefaultOutputDevice), initial: UInt32(0))
    }

    public func volumeControls(for device: OutputDevice) throws -> [VolumeControl] {
        let key = DeviceKey(device)
        if let cached = locked({ volumeCache[key] }) { return cached }
        // Include individual channels even when a main control exists, so an
        // asymmetric channel cannot hide behind an average volume reading.
        let direct = (0...device.channelCount).compactMap { element -> VolumeControl? in
            var property = address(kAudioDevicePropertyVolumeScalar, output: true, element: element)
            return AudioObjectHasProperty(device.id, &property)
                ? VolumeControl(selector: property.mSelector, element: element) : nil
        }
        var virtual = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, output: true)
        let fallback = AudioObjectHasProperty(device.id, &virtual)
            ? [VolumeControl(selector: virtual.mSelector, element: 0)] : []
        let controls = direct.isEmpty ? fallback : direct
        // Bound the cache even if object IDs change repeatedly during reconnection.
        locked {
            volumeCache = volumeCache.filter { $0.key.id != device.id }
            if !controls.isEmpty { volumeCache[key] = controls }
        }
        return controls
    }

    public func readVolume(_ control: VolumeControl, on device: OutputDevice) throws -> Float {
        do {
            return try scalar(device.id, address(control.selector, output: true, element: control.element), initial: Float(0))
        } catch {
            invalidateControlCache(deviceID: device.id)
            throw error
        }
    }

    public func writeVolume(_ value: Float, control: VolumeControl, on device: OutputDevice) throws {
        try verifyIdentity(device)
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
        guard (try? verifyIdentity(device)) != nil else { return false }
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

    public func observeTopology(on queue: DispatchQueue, handler: @escaping (AudioSystemChange) -> Void) -> [AudioObservation] {
        [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
         kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioHardwarePropertyServiceRestarted].compactMap { selector in
            let change: AudioSystemChange = selector == kAudioHardwarePropertyServiceRestarted
                ? .serviceRestarted : (selector == kAudioHardwarePropertyDevices ? .devices : .output)
            return observe(AudioObjectID(kAudioObjectSystemObject), address(selector), on: queue) { handler(change) }
        }
    }

    public func observeDevice(_ device: OutputDevice, on queue: DispatchQueue,
                              handler: @escaping (AudioDeviceChange) -> Void) -> [AudioObservation] {
        var properties = [
            address(kAudioDevicePropertyDeviceHasChanged),
            address(kAudioDevicePropertyDeviceIsAlive),
            address(kAudioDevicePropertyStreamConfiguration, output: true),
            address(kAudioDevicePropertyNominalSampleRate)
        ]
        var observations = properties.compactMap { property in
            observe(device.id, property, on: queue) { handler(.configuration) }
        }
        properties.removeAll(keepingCapacity: true)
        for element in 0...device.channelCount {
            properties.append(address(kAudioDevicePropertyVolumeScalar, output: true, element: element))
            properties.append(address(kAudioDevicePropertyMute, output: true, element: element))
        }
        properties.append(address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, output: true))
        observations += properties.compactMap { property in
            observe(device.id, property, on: queue) { handler(.volume) }
        }
        return observations
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
        let key = DeviceKey(device)
        if let cached = locked({ muteCache[key] }) { return cached }
        let elements = (0...device.channelCount).filter {
            var property = address(kAudioDevicePropertyMute, output: true, element: $0)
            return AudioObjectHasProperty(device.id, &property)
        }
        locked {
            muteCache = muteCache.filter { $0.key.id != device.id }
            muteCache[key] = elements
        }
        return elements
    }

    public func invalidateControlCache(deviceID: UInt32?) {
        locked {
            if let deviceID {
                volumeCache = volumeCache.filter { $0.key.id != deviceID }
                muteCache = muteCache.filter { $0.key.id != deviceID }
            } else {
                volumeCache.removeAll(keepingCapacity: true)
                muteCache.removeAll(keepingCapacity: true)
            }
        }
    }

    private func verifyIdentity(_ device: OutputDevice) throws {
        guard let uid = try? string(device.id, address(kAudioDevicePropertyDeviceUID)), uid == device.uid else {
            invalidateControlCache(deviceID: device.id)
            throw StaleAudioDevice()
        }
    }

    private func locked<T>(_ work: () -> T) -> T {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return work()
    }

    private func outputChannelCount(_ id: AudioDeviceID) throws -> UInt32 {
        var property = address(kAudioDevicePropertyStreamConfiguration, output: true)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "Read output configuration size", objectID: id, property: property)
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, memory), "Read output configuration", objectID: id, property: property)
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
        try check(status, "Read audio property", objectID: id, property: property)
        return value
    }

    private func string(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress) throws -> String {
        var property = property
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value)
        try check(status, "Read audio string", objectID: id, property: property)
        guard let value else {
            throw AudioFailure(operation: "Read empty audio string", status: kAudioHardwareUnspecifiedError,
                               objectID: id, propertySelector: property.mSelector, propertyScope: property.mScope)
        }
        // These properties return an owned CFString (AudioHardwareBase.h).
        return value.takeRetainedValue() as String
    }

    private func array<T>(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress) throws -> [T] {
        var property = property
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "Read audio list size", objectID: id, property: property)
        guard size > 0 else { return [] }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { memory.deallocate() }
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, memory), "Read audio list", objectID: id, property: property)
        return Array(UnsafeBufferPointer(start: memory.assumingMemoryBound(to: T.self),
                                         count: Int(size) / MemoryLayout<T>.stride))
    }

    private func address(_ selector: AudioObjectPropertySelector, output: Bool = false,
                         element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
                                   mElement: element)
    }

    private func check(_ status: OSStatus, _ operation: String, objectID: UInt32? = nil,
                       property: AudioObjectPropertyAddress? = nil) throws {
        if status != noErr {
            throw AudioFailure(operation: operation, status: status, objectID: objectID,
                               propertySelector: property?.mSelector, propertyScope: property?.mScope)
        }
    }
}
