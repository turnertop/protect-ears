import Foundation

public protocol OutputDeviceCatalog: AnyObject {
    func allDeviceIDs() throws -> [UInt32]
    func preferredOutputIDs() -> [UInt32]
    func deviceID(forUID uid: String) throws -> UInt32?
    func describeOutputDevice(_ id: UInt32) throws -> OutputDevice?
}

public struct OutputDeviceInventory {
    public let devices: [OutputDevice]
    public let issues: [String]
    public let systemListFailed: Bool
    public let failedRememberedUIDs: Set<String>
    public var needsClientRecovery: Bool { systemListFailed || !failedRememberedUIDs.isEmpty }
}

/// A broken/disappearing device must not prevent inspecting the other outputs.
public struct OutputDeviceScanner {
    private let catalog: OutputDeviceCatalog

    public init(catalog: OutputDeviceCatalog) { self.catalog = catalog }

    public func scan(rememberedUIDs: Set<String> = [], previous: [OutputDevice] = []) -> OutputDeviceInventory {
        var candidates = catalog.preferredOutputIDs()
        var issues: [String] = []
        var listFailed = false
        do {
            candidates += try catalog.allDeviceIDs()
        } catch {
            listFailed = true
            issues.append("Audio device list unavailable: \(error.localizedDescription)")
            candidates += previous.map(\.id)
        }

        // Resolve remembered headphones independently of the global device list.
        var rememberedByID: [UInt32: Set<String>] = [:]
        var failedUIDs: Set<String> = []
        for uid in rememberedUIDs.sorted() {
            do {
                if let id = try catalog.deviceID(forUID: uid), id != 0 {
                    candidates.append(id)
                    rememberedByID[id, default: []].insert(uid)
                }
            } catch {
                failedUIDs.insert(uid)
                issues.append("Remembered output lookup failed: \(error.localizedDescription)")
            }
        }

        var seen: Set<UInt32> = []
        var devices: [OutputDevice] = []
        for id in candidates where id != 0 && seen.insert(id).inserted {
            do {
                guard let device = try catalog.describeOutputDevice(id) else {
                    if let expected = rememberedByID[id] {
                        failedUIDs.formUnion(expected)
                        issues.append("Remembered output \(id) has no available output channels.")
                    }
                    continue
                }
                if let expected = rememberedByID[id] {
                    let mismatched = expected.subtracting([device.uid])
                    failedUIDs.formUnion(mismatched)
                    if !mismatched.isEmpty { issues.append("Output \(id) changed identity; checking the connection again.") }
                }
                // Identity always comes from a fresh read, never a cached object ID.
                devices.append(device)
            } catch {
                failedUIDs.formUnion(rememberedByID[id] ?? [])
                let label = previous.first(where: { $0.id == id })?.name ?? "Audio device \(id)"
                issues.append("\(label) unavailable: \(error.localizedDescription)")
            }
        }

        return OutputDeviceInventory(
            devices: devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            issues: issues, systemListFailed: listFailed, failedRememberedUIDs: failedUIDs
        )
    }
}

/// Repeated inventory failures get a process-local HAL reset, with a cooldown.
public struct AudioRecoveryPolicy {
    private var failures = 0
    private var lastRecovery: Date?
    private let cooldown: TimeInterval

    public init(cooldown: TimeInterval = 30) { self.cooldown = cooldown }

    public mutating func shouldRecover(failed: Bool, at now: Date, requested: Bool = false) -> Bool {
        guard failed else { failures = 0; return false }
        failures += 1
        guard failures >= 3 || requested else { return false }
        if let lastRecovery, now.timeIntervalSince(lastRecovery) < cooldown { return false }
        self.lastRecovery = now
        failures = 0
        return true
    }
}
