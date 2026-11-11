import CoreAudio
import Foundation
import VolumeGuardCore

final class InventoryChecks {
    private let airpods = OutputDevice(id: 7, uid: "headphones", name: "Alex’s AirPods Max", channelCount: 2)
    private let speakers = OutputDevice(id: 2, uid: "speakers", name: "Mac Speakers", channelCount: 2)
    private let control = VolumeControl(selector: 1, element: 1)

    var checks: [(String, () -> Void)] {
        [
            ("testBrokenDeviceDoesNotHideAirPods", testBrokenDeviceDoesNotHideAirPods),
            ("testInputOnlyDeviceIsSkipped", testInputOnlyDeviceIsSkipped),
            ("testDeviceListFailureStillCapsDefaultAirPods", testDeviceListFailureStillCapsDefaultAirPods),
            ("testRememberedUIDFindsRenamedHeadphonesWithoutGlobalList", testRememberedUIDFindsRenamedHeadphonesWithoutGlobalList),
            ("testCachedIDsAreReadAgainBeforeUse", testCachedIDsAreReadAgainBeforeUse),
            ("testSuccessfulScanDoesNotKeepUnpluggedDevices", testSuccessfulScanDoesNotKeepUnpluggedDevices),
            ("testFailedRememberedDeviceRequestsRecovery", testFailedRememberedDeviceRequestsRecovery),
            ("testRecoveryClearsTransientDiscoveryErrors", testRecoveryClearsTransientDiscoveryErrors),
            ("testDuplicateAndUnknownIDsAreIgnored", testDuplicateAndUnknownIDsAreIgnored),
            ("testErrorIdentifiesObjectAndUnsupportedProperty", testErrorIdentifiesObjectAndUnsupportedProperty),
            ("testAutomaticRecoveryRequiresRepeatedFailures", testAutomaticRecoveryRequiresRepeatedFailures),
            ("testRecoveryCooldownPreventsResetLoop", testRecoveryCooldownPreventsResetLoop),
            ("testRefreshCanRecoverFirstFailure", testRefreshCanRecoverFirstFailure),
            ("testHealthyRefreshDoesNotResetAudioClient", testHealthyRefreshDoesNotResetAudioClient)
        ]
    }

    func testBrokenDeviceDoesNotHideAirPods() {
        let catalog = FakeCatalog(ids: [99, 7], outputs: [7: airpods])
        catalog.brokenIDs = [99]
        let result = OutputDeviceScanner(catalog: catalog).scan(rememberedUIDs: [airpods.uid])
        expectEqual(result.devices, [airpods])
        expectEqual(result.issues.count, 1)
        expectFalse(result.needsClientRecovery)
        let hardware = FakeHardware(values: [control: 0.9])
        let enforced = GuardEngine(hardware: hardware).enforce(devices: result.devices, limit: .fiveSteps, pinnedUIDs: [])
        expectEqual(hardware.values[control], 0.3125)
        expectEqual(enforced.reports.first?.state, .monitoring)
    }

    func testInputOnlyDeviceIsSkipped() {
        let catalog = FakeCatalog(ids: [88, 7], outputs: [7: airpods])
        let result = OutputDeviceScanner(catalog: catalog).scan()
        expectEqual(result.devices, [airpods])
        expectTrue(result.issues.isEmpty)
    }

    func testDeviceListFailureStillCapsDefaultAirPods() {
        let catalog = FakeCatalog(ids: [], outputs: [7: airpods])
        catalog.failList = true
        catalog.preferred = [7]
        let result = OutputDeviceScanner(catalog: catalog).scan()
        expectEqual(result.devices, [airpods])
        expectTrue(result.systemListFailed)
        let hardware = FakeHardware(values: [control: 0.8])
        _ = GuardEngine(hardware: hardware).enforce(devices: result.devices, limit: .fiveSteps, pinnedUIDs: [])
        expectEqual(hardware.values[control], 0.3125)
    }

    func testRememberedUIDFindsRenamedHeadphonesWithoutGlobalList() {
        let renamed = OutputDevice(id: 77, uid: airpods.uid, name: "My Headphones", channelCount: 2)
        let catalog = FakeCatalog(ids: [], outputs: [2: speakers, 77: renamed])
        catalog.failList = true
        catalog.preferred = [2]
        let result = OutputDeviceScanner(catalog: catalog).scan(rememberedUIDs: [airpods.uid])
        expectTrue(result.devices.contains(renamed))
        let hardware = FakeHardware(values: [control: 0.8])
        _ = GuardEngine(hardware: hardware).enforce(devices: result.devices, limit: .fiveSteps, pinnedUIDs: [airpods.uid])
        expectEqual(hardware.values[control], 0.3125)
        expectTrue(hardware.writes.allSatisfy { $0.deviceID == 77 })
    }

    func testCachedIDsAreReadAgainBeforeUse() {
        let reused = OutputDevice(id: airpods.id, uid: "new-speakers", name: "Other Speakers", channelCount: 2)
        let catalog = FakeCatalog(ids: [], outputs: [7: reused])
        catalog.failList = true
        let result = OutputDeviceScanner(catalog: catalog).scan(rememberedUIDs: [airpods.uid], previous: [airpods])
        expectEqual(result.devices, [reused])
        let hardware = FakeHardware(values: [control: 0.9])
        _ = GuardEngine(hardware: hardware).enforce(devices: result.devices, limit: .fiveSteps, pinnedUIDs: [airpods.uid])
        expectTrue(hardware.writes.isEmpty)
        expectEqual(hardware.muteAttempts, 0)
    }

    func testSuccessfulScanDoesNotKeepUnpluggedDevices() {
        let catalog = FakeCatalog(ids: [2], outputs: [2: speakers])
        let result = OutputDeviceScanner(catalog: catalog).scan(rememberedUIDs: [airpods.uid], previous: [airpods])
        expectEqual(result.devices, [speakers])
        expectFalse(result.needsClientRecovery)
    }

    func testFailedRememberedDeviceRequestsRecovery() {
        let catalog = FakeCatalog(ids: [7, 2], outputs: [7: airpods, 2: speakers])
        catalog.brokenIDs = [7]
        let result = OutputDeviceScanner(catalog: catalog).scan(rememberedUIDs: [airpods.uid])
        expectEqual(result.devices, [speakers])
        expectEqual(result.failedRememberedUIDs, [airpods.uid])
        expectTrue(result.needsClientRecovery)
    }

    func testRecoveryClearsTransientDiscoveryErrors() {
        let catalog = FakeCatalog(ids: [7], outputs: [7: airpods])
        catalog.brokenIDs = [7]
        let scanner = OutputDeviceScanner(catalog: catalog)
        expectTrue(scanner.scan(rememberedUIDs: [airpods.uid]).needsClientRecovery)
        catalog.brokenIDs = []
        let recovered = scanner.scan(rememberedUIDs: [airpods.uid])
        expectEqual(recovered.devices, [airpods])
        expectTrue(recovered.issues.isEmpty)
        expectFalse(recovered.needsClientRecovery)
    }

    func testDuplicateAndUnknownIDsAreIgnored() {
        let catalog = FakeCatalog(ids: [0, 7, 7], outputs: [7: airpods])
        catalog.preferred = [0, 7]
        let result = OutputDeviceScanner(catalog: catalog).scan(rememberedUIDs: [airpods.uid])
        expectEqual(result.devices.count, 1)
        expectEqual(catalog.inspected, [7])
    }

    func testErrorIdentifiesObjectAndUnsupportedProperty() {
        let error = AudioFailure(operation: "Read audio list size", status: kAudioHardwareUnknownPropertyError,
                                 objectID: 99, propertySelector: kAudioDevicePropertyStreams,
                                 propertyScope: kAudioDevicePropertyScopeOutput)
        expectTrue(error.localizedDescription.contains("2003332927 'who?'"))
        expectTrue(error.localizedDescription.contains("object 99"))
        expectTrue(error.localizedDescription.contains("'stm#'"))
        expectTrue(error.localizedDescription.contains("'outp'"))
    }

    func testAutomaticRecoveryRequiresRepeatedFailures() {
        var policy = AudioRecoveryPolicy()
        let now = Date(timeIntervalSince1970: 100)
        expectFalse(policy.shouldRecover(failed: true, at: now))
        expectFalse(policy.shouldRecover(failed: true, at: now.addingTimeInterval(1)))
        expectTrue(policy.shouldRecover(failed: true, at: now.addingTimeInterval(2)))
    }

    func testRecoveryCooldownPreventsResetLoop() {
        var policy = AudioRecoveryPolicy(cooldown: 30)
        let now = Date(timeIntervalSince1970: 100)
        expectTrue(policy.shouldRecover(failed: true, at: now, requested: true))
        for seconds in 1...29 {
            expectFalse(policy.shouldRecover(failed: true, at: now.addingTimeInterval(Double(seconds)), requested: true))
        }
        expectTrue(policy.shouldRecover(failed: true, at: now.addingTimeInterval(30)))
    }

    func testRefreshCanRecoverFirstFailure() {
        var policy = AudioRecoveryPolicy()
        expectTrue(policy.shouldRecover(failed: true, at: Date(), requested: true))
    }

    func testHealthyRefreshDoesNotResetAudioClient() {
        var policy = AudioRecoveryPolicy()
        let now = Date()
        expectFalse(policy.shouldRecover(failed: false, at: now, requested: true))
        expectFalse(policy.shouldRecover(failed: true, at: now))
        expectFalse(policy.shouldRecover(failed: false, at: now))
        expectFalse(policy.shouldRecover(failed: true, at: now))
    }
}

private final class FakeCatalog: OutputDeviceCatalog {
    let ids: [UInt32]
    let outputs: [UInt32: OutputDevice]
    var preferred: [UInt32] = []
    var brokenIDs: Set<UInt32> = []
    var failList = false
    var inspected: [UInt32] = []

    init(ids: [UInt32], outputs: [UInt32: OutputDevice]) { self.ids = ids; self.outputs = outputs }
    func allDeviceIDs() throws -> [UInt32] {
        if failList {
            throw AudioFailure(operation: "Read audio list size", status: kAudioHardwareUnknownPropertyError,
                               objectID: 1, propertySelector: kAudioHardwarePropertyDevices)
        }
        return ids
    }
    func preferredOutputIDs() -> [UInt32] { preferred }
    func deviceID(forUID uid: String) throws -> UInt32? { outputs.values.first { $0.uid == uid }?.id }
    func describeOutputDevice(_ id: UInt32) throws -> OutputDevice? {
        inspected.append(id)
        if brokenIDs.contains(id) {
            throw AudioFailure(operation: "Read output configuration size", status: kAudioHardwareUnknownPropertyError,
                               objectID: id, propertySelector: kAudioDevicePropertyStreamConfiguration,
                               propertyScope: kAudioDevicePropertyScopeOutput)
        }
        return outputs[id]
    }
}
