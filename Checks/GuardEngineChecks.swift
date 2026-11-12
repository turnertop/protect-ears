import Foundation
import VolumeGuardCore

final class GuardEngineChecks {
    private let left = VolumeControl(selector: 1, element: 1)
    private let right = VolumeControl(selector: 1, element: 2)

    private func device(_ name: String = "Alex’s AirPods Max", id: UInt32 = 10,
                        uid: String = "airpods-max") -> OutputDevice {
        OutputDevice(id: id, uid: uid, name: name, channelCount: 2)
    }

    func testFourAndFiveStepsUseSixteenStepScale() {
        expectEqual(VolumeLimit.fourSteps.scalar, 0.25)
        expectEqual(VolumeLimit.fiveSteps.scalar, 0.3125)
    }

    func testInvalidSavedLimitHasConservativeFallback() {
        expectEqual(VolumeLimit(rawValue: 16) ?? .fourSteps, .fourSteps)
        expectEqual(VolumeLimit(rawValue: 0) ?? .fourSteps, .fourSteps)
    }

    func testAutomaticDetectionAllowsCustomNamesAndCase() {
        expectTrue(device().isAirPodsMax)
        expectTrue(device("ALEX AIRPODS MAX").isAirPodsMax)
        expectTrue(device("AirPods-Max").isAirPodsMax)
        expectFalse(device("AirPods Pro").isAirPodsMax)
        expectFalse(device("AirPods Maximum speaker").isAirPodsMax)
    }

    func testClampsAnAppVolumeSpikeOnBothChannels() {
        let hardware = FakeHardware(values: [left: 0.9, right: 0.9])
        let result = GuardEngine(hardware: hardware).enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
        expectEqual(hardware.values[left], 0.25)
        expectEqual(hardware.values[right], 0.25)
        expectEqual(result.clampedDevices, 1)
        expectEqual(result.reports.first?.state, .monitoring)
    }

    func testNeverRaisesALowerVolumeOrUnmutes() {
        let hardware = FakeHardware(values: [left: 0.1, right: 0.2])
        hardware.muted = true
        let result = GuardEngine(hardware: hardware).enforce(devices: [device()], limit: .fiveSteps, pinnedUIDs: [])
        expectTrue(hardware.writes.isEmpty)
        expectTrue(hardware.muted)
        expectEqual(result.clampedDevices, 0)
        expectEqual(result.reports.first?.state, .monitoring)
    }

    func testChecksIndividualChannelsWithoutRaisingQuietChannel() {
        let hardware = FakeHardware(values: [left: 0.1, right: 0.8])
        _ = GuardEngine(hardware: hardware).enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
        expectEqual(hardware.values[left], 0.1)
        expectEqual(hardware.values[right], 0.25)
        expectEqual(hardware.writes.count, 1)
    }

    func testDoesNotChangeSpeakersOrOtherHeadphones() {
        let hardware = FakeHardware(values: [left: 0.9, right: 0.9])
        let devices = [device("MacBook Pro Speakers", id: 20, uid: "speakers"),
                       device("AirPods Pro", id: 30, uid: "pro")]
        let result = GuardEngine(hardware: hardware).enforce(devices: devices, limit: .fourSteps, pinnedUIDs: [])
        expectTrue(hardware.writes.isEmpty)
        expectEqual(hardware.muteAttempts, 0)
        expectTrue(result.reports.allSatisfy { $0.state == .unselected })
    }

    func testCapsAirPodsEvenWhenSpeakersAreAlsoPresent() {
        let hardware = FakeHardware(values: [left: 0.8, right: 0.8])
        let result = GuardEngine(hardware: hardware).enforce(
            devices: [device("Speakers", id: 20, uid: "speakers"), device()], limit: .fourSteps, pinnedUIDs: [])
        expectEqual(result.reports.filter(\.isProtected).count, 1)
        expectTrue(hardware.writes.allSatisfy { $0.deviceID == 10 })
    }

    func testRemembersUIDForRenamedHeadphonesOnReconnect() {
        let hardware = FakeHardware(values: [left: 0.8, right: 0.8])
        let engine = GuardEngine(hardware: hardware)
        let original = engine.enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
        expectEqual(original.learnedUIDs, ["airpods-max"])
        hardware.values = [left: 0.9, right: 0.9]
        let renamed = device("Alex’s Headphones", id: 99)
        let result = engine.enforce(devices: [renamed], limit: .fourSteps, pinnedUIDs: original.learnedUIDs)
        expectEqual(result.reports.first?.state, .monitoring)
        expectEqual(hardware.values[right], 0.25)
    }

    func testReusedObjectIDDoesNotProtectADifferentDevice() {
        let hardware = FakeHardware(values: [left: 0.8, right: 0.8])
        let result = GuardEngine(hardware: hardware).enforce(
            devices: [device("Speakers", uid: "different-uid")], limit: .fourSteps, pinnedUIDs: ["airpods-max"])
        expectEqual(result.reports.first?.state, .unselected)
        expectTrue(hardware.writes.isEmpty)
    }

    func testManuallySelectedRenamedDeviceIsCapped() {
        let hardware = FakeHardware(values: [left: 0.8])
        let result = GuardEngine(hardware: hardware).enforce(
            devices: [device("My headphones")], limit: .fiveSteps, pinnedUIDs: ["airpods-max"])
        expectEqual(hardware.values[left], 0.3125)
        expectEqual(result.reports.first?.state, .monitoring)
    }

    func testEveryLaterSpikeIsClampedAgain() {
        let hardware = FakeHardware(values: [left: 0.8])
        let engine = GuardEngine(hardware: hardware)
        for _ in 0..<5 {
            hardware.values[left] = 1
            let result = engine.enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
            expectEqual(hardware.values[left], 0.25)
            expectEqual(result.clampedDevices, 1)
        }
    }

    func testLoweringCeilingTakesEffectImmediately() {
        let hardware = FakeHardware(values: [left: 0.3125])
        _ = GuardEngine(hardware: hardware).enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
        expectEqual(hardware.values[left], 0.25)
    }

    func testRaisingCeilingNeverRaisesActualVolume() {
        let hardware = FakeHardware(values: [left: 0.25])
        _ = GuardEngine(hardware: hardware).enforce(devices: [device()], limit: .fiveSteps, pinnedUIDs: [])
        expectTrue(hardware.writes.isEmpty)
    }

    func testQuietPassReadsEachControlOnce() {
        let hardware = FakeHardware(values: [left: 0.2, right: 0.2])
        _ = GuardEngine(hardware: hardware).enforce(devices: [device()], limit: .fiveSteps, pinnedUIDs: [])
        expectEqual(hardware.readCount, 2)
        expectTrue(hardware.writes.isEmpty)
    }

    func testStaleIdentityNeverMutesAnUnrelatedDevice() {
        let hardware = FakeHardware(values: [left: 0.8])
        hardware.staleIdentity = true
        let result = GuardEngine(hardware: hardware).enforce(devices: [device()], limit: .fiveSteps, pinnedUIDs: [])
        expectTrue(hardware.writes.isEmpty)
        expectEqual(hardware.muteAttempts, 0)
        expectEqual(result.reports.first?.state, .failed)
    }

    func testReadFailureAttemptsMuteAndReportsAttention() {
        let hardware = FakeHardware(values: [left: 0.8])
        hardware.failRead = true
        let result = GuardEngine(hardware: hardware).enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
        expectTrue(hardware.muted)
        expectEqual(result.reports.first?.state, .mutedAfterFailure)
        expectEqual(result.clampedDevices, 0)
    }

    func testWriteFailureDoesNotClaimCapWasApplied() {
        let hardware = FakeHardware(values: [left: 0.8])
        hardware.failWrite = true
        let result = GuardEngine(hardware: hardware).enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
        expectEqual(result.reports.first?.state, .mutedAfterFailure)
        expectEqual(result.clampedDevices, 0)
    }

    func testMissingVolumeControlsAttemptMute() {
        let hardware = FakeHardware(values: [:])
        let result = GuardEngine(hardware: hardware).enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
        expectTrue(hardware.muted)
        expectEqual(result.reports.first?.state, .mutedAfterFailure)
    }

    func testCannotMuteOrCapReportsFailure() {
        let hardware = FakeHardware(values: [:])
        hardware.canMute = false
        let result = GuardEngine(hardware: hardware).enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
        expectEqual(result.reports.first?.state, .failed)
        expectTrue(result.reports.first?.detail?.contains("Pause playback") == true)
    }

    func testInvalidVolumesFailClosed() {
        for invalid in [Float.nan, Float.infinity, -0.1, 1.1] {
            let hardware = FakeHardware(values: [left: invalid])
            let result = GuardEngine(hardware: hardware).enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
            expectEqual(result.reports.first?.state, .mutedAfterFailure)
            expectTrue(hardware.writes.isEmpty)
        }
    }

    func testVerifiesReadbackAndRetriesBelowQuantizedCeiling() {
        let hardware = FakeHardware(values: [left: 0.8])
        hardware.quantizationOffset = 0.01
        let result = GuardEngine(hardware: hardware).enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
        expectLessThanOrEqual(hardware.values[left]!, 0.25)
        expectEqual(hardware.writes.count, 2)
        expectEqual(result.reports.first?.state, .monitoring)
    }

    func testDriverIgnoringSuccessfulWritesIsMuted() {
        let hardware = FakeHardware(values: [left: 0.8])
        hardware.ignoreWrites = true
        let result = GuardEngine(hardware: hardware).enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
        expectEqual(hardware.writes.count, 3)
        expectTrue(hardware.muted)
        expectEqual(result.reports.first?.state, .mutedAfterFailure)
    }

    func testEmergencyMuteRemainsVisibleAfterDriverRecovers() {
        let hardware = FakeHardware(values: [left: 0.8])
        let engine = GuardEngine(hardware: hardware)
        hardware.failWrite = true
        _ = engine.enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
        hardware.failWrite = false
        let recovered = engine.enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
        expectEqual(recovered.reports.first?.state, .mutedAfterFailure)
        expectTrue(hardware.muted)
        hardware.muted = false // Simulate the user checking and unmuting manually.
        let unmuted = engine.enforce(devices: [device()], limit: .fourSteps, pinnedUIDs: [])
        expectEqual(unmuted.reports.first?.state, .monitoring)
    }

    func testNoConnectedHeadphonesIsAWaitingState() {
        let hardware = FakeHardware(values: [left: 0.8])
        let result = GuardEngine(hardware: hardware).enforce(devices: [], limit: .fourSteps, pinnedUIDs: [])
        expectTrue(result.reports.isEmpty)
        expectTrue(hardware.writes.isEmpty)
    }

    func testSnapshotFlagsFailuresWithoutFlaggingOrdinaryMute() {
        let hardware = FakeHardware(values: [left: 0.1])
        hardware.muted = true
        var snapshot = GuardSnapshot()
        snapshot.reports = GuardEngine(hardware: hardware).enforce(
            devices: [device()], limit: .fourSteps, pinnedUIDs: []).reports
        expectFalse(snapshot.needsAttention)
        snapshot.error = "Could not enumerate devices"
        expectTrue(snapshot.needsAttention)
    }
}

final class FakeHardware: VolumeHardware {
    struct Write { let deviceID: UInt32; let value: Float }
    var values: [VolumeControl: Float]
    var writes: [Write] = []
    var muted = false
    var canMute = true
    var muteAttempts = 0
    var failRead = false
    var failWrite = false
    var ignoreWrites = false
    var quantizationOffset: Float = 0
    var readCount = 0
    var staleIdentity = false

    init(values: [VolumeControl: Float]) { self.values = values }
    func outputDevices() throws -> [OutputDevice] { [] }
    func volumeControls(for device: OutputDevice) throws -> [VolumeControl] {
        values.keys.sorted { $0.element < $1.element }
    }
    func readVolume(_ control: VolumeControl, on device: OutputDevice) throws -> Float {
        readCount += 1
        if failRead { throw NSError(domain: "Simulated read failure", code: 1) }
        return values[control]!
    }
    func writeVolume(_ value: Float, control: VolumeControl, on device: OutputDevice) throws {
        if staleIdentity { throw StaleAudioDevice() }
        if failWrite { throw NSError(domain: "Simulated write failure", code: 2) }
        writes.append(Write(deviceID: device.id, value: value))
        if !ignoreWrites { values[control] = value + quantizationOffset }
    }
    func emergencyMute(_ device: OutputDevice) -> Bool {
        muteAttempts += 1
        if canMute { muted = true }
        return muted
    }
    func isMuted(_ device: OutputDevice) -> Bool { muted }
}

// A dependency-free runner works with Apple's Command Line Tools, without Xcode/XCTest.
enum CheckRecorder {
    static var current = ""
    static var failures: [String] = []
    static func record(_ passed: Bool, _ description: String, file: StaticString, line: UInt) {
        if !passed { failures.append("\(current): \(description) at \(file):\(line)") }
    }
}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    CheckRecorder.record(actual == expected, "expected \(expected), got \(actual)", file: file, line: line)
}
func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    CheckRecorder.record(value, "expected true", file: file, line: line)
}
func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    CheckRecorder.record(!value, "expected false", file: file, line: line)
}
func expectLessThanOrEqual<T: Comparable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    CheckRecorder.record(actual <= expected, "expected \(actual) <= \(expected)", file: file, line: line)
}

@main
private enum CheckRunner {
    static func main() {
        let suite = GuardEngineChecks()
        let checks: [(String, () -> Void)] = [
            ("testFourAndFiveStepsUseSixteenStepScale", suite.testFourAndFiveStepsUseSixteenStepScale),
            ("testInvalidSavedLimitHasConservativeFallback", suite.testInvalidSavedLimitHasConservativeFallback),
            ("testAutomaticDetectionAllowsCustomNamesAndCase", suite.testAutomaticDetectionAllowsCustomNamesAndCase),
            ("testClampsAnAppVolumeSpikeOnBothChannels", suite.testClampsAnAppVolumeSpikeOnBothChannels),
            ("testNeverRaisesALowerVolumeOrUnmutes", suite.testNeverRaisesALowerVolumeOrUnmutes),
            ("testChecksIndividualChannelsWithoutRaisingQuietChannel", suite.testChecksIndividualChannelsWithoutRaisingQuietChannel),
            ("testDoesNotChangeSpeakersOrOtherHeadphones", suite.testDoesNotChangeSpeakersOrOtherHeadphones),
            ("testCapsAirPodsEvenWhenSpeakersAreAlsoPresent", suite.testCapsAirPodsEvenWhenSpeakersAreAlsoPresent),
            ("testRemembersUIDForRenamedHeadphonesOnReconnect", suite.testRemembersUIDForRenamedHeadphonesOnReconnect),
            ("testReusedObjectIDDoesNotProtectADifferentDevice", suite.testReusedObjectIDDoesNotProtectADifferentDevice),
            ("testManuallySelectedRenamedDeviceIsCapped", suite.testManuallySelectedRenamedDeviceIsCapped),
            ("testEveryLaterSpikeIsClampedAgain", suite.testEveryLaterSpikeIsClampedAgain),
            ("testLoweringCeilingTakesEffectImmediately", suite.testLoweringCeilingTakesEffectImmediately),
            ("testRaisingCeilingNeverRaisesActualVolume", suite.testRaisingCeilingNeverRaisesActualVolume),
            ("testQuietPassReadsEachControlOnce", suite.testQuietPassReadsEachControlOnce),
            ("testStaleIdentityNeverMutesAnUnrelatedDevice", suite.testStaleIdentityNeverMutesAnUnrelatedDevice),
            ("testReadFailureAttemptsMuteAndReportsAttention", suite.testReadFailureAttemptsMuteAndReportsAttention),
            ("testWriteFailureDoesNotClaimCapWasApplied", suite.testWriteFailureDoesNotClaimCapWasApplied),
            ("testMissingVolumeControlsAttemptMute", suite.testMissingVolumeControlsAttemptMute),
            ("testCannotMuteOrCapReportsFailure", suite.testCannotMuteOrCapReportsFailure),
            ("testInvalidVolumesFailClosed", suite.testInvalidVolumesFailClosed),
            ("testVerifiesReadbackAndRetriesBelowQuantizedCeiling", suite.testVerifiesReadbackAndRetriesBelowQuantizedCeiling),
            ("testDriverIgnoringSuccessfulWritesIsMuted", suite.testDriverIgnoringSuccessfulWritesIsMuted),
            ("testEmergencyMuteRemainsVisibleAfterDriverRecovers", suite.testEmergencyMuteRemainsVisibleAfterDriverRecovers),
            ("testNoConnectedHeadphonesIsAWaitingState", suite.testNoConnectedHeadphonesIsAWaitingState),
            ("testSnapshotFlagsFailuresWithoutFlaggingOrdinaryMute", suite.testSnapshotFlagsFailuresWithoutFlaggingOrdinaryMute)
        ] + InventoryChecks().checks + MonitorChecks().checks + LoginItemChecks().checks
        for (name, check) in checks {
            CheckRecorder.current = name
            check()
        }
        for failure in CheckRecorder.failures { fputs("FAIL: \(failure)\n", stderr) }
        print("\(checks.count) simulated checks; \(CheckRecorder.failures.count) failures. No real audio or login settings changed.")
        exit(CheckRecorder.failures.isEmpty ? 0 : 1)
    }
}
