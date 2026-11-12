import Foundation
import LoginItemSupport
import ServiceManagement

final class LoginItemChecks {
    var checks: [(String, () -> Void)] {
        [
            ("testNewInstallationNeverOptsIn", newInstallationNeverOptsIn),
            ("testMigratesAnExistingEnabledRegistration", migratesAnExistingEnabledRegistration),
            ("testDeniedLegacyRegistrationNeverOptsIn", deniedLegacyRegistrationNeverOptsIn),
            ("testEnabledChoiceSurvivesReplacement", enabledChoiceSurvivesReplacement),
            ("testOffChoiceSurvivesReplacement", offChoiceSurvivesReplacement),
            ("testFailedOffRequestIsRemembered", failedOffRequestIsRemembered),
            ("testMissingRegistrationIsNotRepairedEveryLaunch", missingRegistrationIsNotRepairedEveryLaunch),
            ("testSystemSettingsRemovalIsRemembered", systemSettingsRemovalIsRemembered),
            ("testRevokedApprovalIsNeverOverridden", revokedApprovalIsNeverOverridden),
            ("testPendingApprovalRemainsPending", pendingApprovalRemainsPending),
            ("testUpdateCannotClearPendingOSApproval", updateCannotClearPendingOSApproval),
            ("testFailedRepairStaysVisibleWithoutRetryLoop", failedRepairStaysVisibleWithoutRetryLoop),
            ("testExplicitRetryRecoversFailedRepair", explicitRetryRecoversFailedRepair),
            ("testUpdateHandoffUnregistersOldCopy", updateHandoffUnregistersOldCopy),
            ("testHandoffSurvivesOldProcessActivation", handoffSurvivesOldProcessActivation),
            ("testPreparedUpdateCanRollBackToSameBuild", preparedUpdateCanRollBackToSameBuild),
            ("testHandoffHonorsRemovalWhileAppWasClosed", handoffHonorsRemovalWhileAppWasClosed),
            ("testFailedHandoffStopsTheUpdate", failedHandoffStopsTheUpdate),
            ("testExplicitOffClearsPendingUpdate", explicitOffClearsPendingUpdate),
            ("testUnchangedStateDoesNotWritePreferences", unchangedStateDoesNotWritePreferences)
        ]
    }

    private func controller(_ service: FakeLoginService, _ preferences: FakeLoginPreferences,
                            build: String = "old-build") -> LoginItemController {
        LoginItemController(service: service, preferences: preferences, build: build)
    }
    private func enabledRecord() -> FakeLoginPreferences {
        FakeLoginPreferences(LoginItemRecord(requested: true, build: "old-build", status: .enabled))
    }
    private func newInstallationNeverOptsIn() {
        for status: SMAppService.Status in [.notFound, .notRegistered] {
            let service = FakeLoginService(status)
            let preferences = FakeLoginPreferences()
            expectFalse(controller(service, preferences).restoreAfterLaunch().requested)
            expectEqual(service.registrations, 0)
        }
    }
    private func migratesAnExistingEnabledRegistration() {
        let service = FakeLoginService(.enabled)
        let preferences = FakeLoginPreferences()
        expectTrue(controller(service, preferences).restoreAfterLaunch().requested)
        expectEqual(preferences.record?.requested, true)
        expectEqual(service.registrations, 0)
    }
    private func deniedLegacyRegistrationNeverOptsIn() {
        let service = FakeLoginService(.requiresApproval)
        expectFalse(controller(service, FakeLoginPreferences()).restoreAfterLaunch().requested)
        expectEqual(service.registrations, 0)
    }
    private func enabledChoiceSurvivesReplacement() {
        for status: SMAppService.Status in [.notFound, .notRegistered] {
            let service = FakeLoginService(status)
            let preferences = enabledRecord()
            let result = controller(service, preferences, build: "new-code-hash").restoreAfterLaunch()
            expectTrue(result.requested)
            expectEqual(result.status, .enabled)
            expectEqual(service.registrations, 1)
            expectEqual(controller(service, preferences, build: "new-code-hash").restoreAfterLaunch().status, .enabled)
            expectEqual(service.registrations, 1)
        }
    }
    private func offChoiceSurvivesReplacement() {
        let service = FakeLoginService(.notFound)
        let preferences = FakeLoginPreferences(LoginItemRecord(requested: false, build: "old-build", status: .notFound))
        expectFalse(controller(service, preferences, build: "new-build").restoreAfterLaunch().requested)
        expectEqual(service.registrations, 0)
    }
    private func missingRegistrationIsNotRepairedEveryLaunch() {
        let service = FakeLoginService(.notFound)
        let preferences = enabledRecord()
        expectFalse(controller(service, preferences).restoreAfterLaunch().requested)
        expectFalse(controller(service, preferences, build: "next-build").restoreAfterLaunch().requested)
        expectEqual(service.registrations, 0)
    }
    private func failedOffRequestIsRemembered() {
        let service = FakeLoginService(.enabled)
        service.failUnregister = true
        let preferences = enabledRecord()
        let manager = controller(service, preferences)
        expectFalse(manager.setEnabled(false).requested)
        expectTrue(manager.snapshot.error != nil)
        expectFalse(manager.refresh().requested)
        expectTrue(manager.snapshot.needsRepair)
        service.failUnregister = false
        expectFalse(manager.setEnabled(false).requested)
        expectFalse(manager.snapshot.needsRepair)
        expectEqual(manager.snapshot.error, nil)
    }
    private func systemSettingsRemovalIsRemembered() {
        let service = FakeLoginService(.enabled)
        let preferences = enabledRecord()
        let manager = controller(service, preferences)
        manager.restoreAfterLaunch()
        service.status = .notFound
        expectFalse(manager.refresh().requested)
        expectFalse(controller(service, preferences, build: "next-build").restoreAfterLaunch().requested)
        expectEqual(service.registrations, 0)
    }
    private func revokedApprovalIsNeverOverridden() {
        let service = FakeLoginService(.requiresApproval)
        let result = controller(service, enabledRecord(), build: "new-build").restoreAfterLaunch()
        expectFalse(result.requested)
        expectEqual(service.registrations, 0)
        expectEqual(service.unregistrations, 0)
    }
    private func pendingApprovalRemainsPending() {
        let service = FakeLoginService(.notFound)
        service.registeredStatus = .requiresApproval
        let preferences = FakeLoginPreferences()
        let manager = controller(service, preferences)
        expectTrue(manager.setEnabled(true).needsApproval)
        expectTrue(manager.refresh().needsApproval)
        expectTrue(controller(service, preferences, build: "new-build").restoreAfterLaunch().needsApproval)
        expectEqual(service.registrations, 1)
    }
    private func failedRepairStaysVisibleWithoutRetryLoop() {
        let service = FakeLoginService(.notFound)
        service.failRegister = true
        let preferences = enabledRecord()
        let manager = controller(service, preferences, build: "new-build")
        expectTrue(manager.restoreAfterLaunch().needsRepair)
        expectTrue(manager.snapshot.error != nil)
        for _ in 0..<10 { manager.refresh() }
        expectTrue(controller(service, preferences, build: "new-build").restoreAfterLaunch().needsRepair)
        expectEqual(service.registrations, 1)
    }
    private func updateCannotClearPendingOSApproval() {
        let service = FakeLoginService(.notFound)
        service.registeredStatus = .requiresApproval
        let preferences = FakeLoginPreferences()
        let manager = controller(service, preferences)
        manager.setEnabled(true)
        manager.prepareForUpdate()
        expectEqual(service.unregistrations, 0)
        service.status = .notFound
        expectTrue(controller(service, preferences, build: "new-build").restoreAfterLaunch().needsRepair)
        expectTrue(controller(service, preferences, build: "another-build").restoreAfterLaunch().needsRepair)
        expectEqual(service.registrations, 1)
    }
    private func explicitRetryRecoversFailedRepair() {
        let service = FakeLoginService(.notFound)
        service.failRegister = true
        let manager = controller(service, enabledRecord(), build: "new-build")
        manager.restoreAfterLaunch()
        service.failRegister = false
        expectEqual(manager.setEnabled(true).status, .enabled)
        expectEqual(manager.snapshot.error, nil)
    }
    private func updateHandoffUnregistersOldCopy() {
        let service = FakeLoginService(.enabled)
        let preferences = enabledRecord()
        let prepared = controller(service, preferences).prepareForUpdate()
        expectTrue(prepared.requested)
        expectTrue(prepared.preparedForUpdate)
        expectEqual(prepared.error, nil)
        expectEqual(service.unregistrations, 1)
        expectEqual(controller(service, preferences, build: "new-build").restoreAfterLaunch().status, .enabled)
        expectFalse(preferences.record!.preparedForUpdate)
        expectEqual(service.registrations, 1)
    }
    private func handoffSurvivesOldProcessActivation() {
        let service = FakeLoginService(.enabled)
        let preferences = enabledRecord()
        let oldProcess = controller(service, preferences)
        oldProcess.restoreAfterLaunch()
        controller(service, preferences).prepareForUpdate()
        expectTrue(oldProcess.refresh().requested)
        expectTrue(preferences.record!.preparedForUpdate)
        expectEqual(service.registrations, 0)
    }
    private func preparedUpdateCanRollBackToSameBuild() {
        let service = FakeLoginService(.enabled)
        let preferences = enabledRecord()
        controller(service, preferences).prepareForUpdate()
        expectEqual(controller(service, preferences).restoreAfterLaunch().status, .enabled)
        expectEqual(service.registrations, 1)
    }
    private func handoffHonorsRemovalWhileAppWasClosed() {
        let service = FakeLoginService(.notFound)
        let preferences = enabledRecord()
        expectFalse(controller(service, preferences).prepareForUpdate().requested)
        expectFalse(controller(service, preferences, build: "new-build").restoreAfterLaunch().requested)
        expectEqual(service.registrations, 0)
    }
    private func failedHandoffStopsTheUpdate() {
        let service = FakeLoginService(.enabled)
        service.failUnregister = true
        let preferences = enabledRecord()
        expectTrue(controller(service, preferences).prepareForUpdate().error != nil)
        expectFalse(preferences.record!.preparedForUpdate)
        expectEqual(service.status, .enabled)
    }
    private func explicitOffClearsPendingUpdate() {
        let service = FakeLoginService(.enabled)
        let preferences = enabledRecord()
        let manager = controller(service, preferences)
        manager.prepareForUpdate()
        expectFalse(manager.setEnabled(false).requested)
        expectFalse(preferences.record!.preparedForUpdate)
        expectFalse(controller(service, preferences, build: "new-build").restoreAfterLaunch().requested)
        expectEqual(service.registrations, 0)
    }
    private func unchangedStateDoesNotWritePreferences() {
        let service = FakeLoginService(.enabled)
        let preferences = enabledRecord()
        let manager = controller(service, preferences)
        manager.restoreAfterLaunch()
        for _ in 0..<20 { manager.refresh() }
        expectEqual(preferences.saves, 0)
        expectEqual(service.registrations, 0)
    }
}

private final class FakeLoginService: LoginItemService {
    var status: SMAppService.Status
    var registeredStatus: SMAppService.Status = .enabled
    var registrations = 0, unregistrations = 0
    var failRegister = false, failUnregister = false
    init(_ status: SMAppService.Status) { self.status = status }
    func register() throws {
        registrations += 1
        if failRegister { throw NSError(domain: "Simulated registration failure", code: 1) }
        status = registeredStatus
    }
    func unregister() throws {
        unregistrations += 1
        if failUnregister { throw NSError(domain: "Simulated unregister failure", code: 2) }
        status = .notRegistered
    }
}
private final class FakeLoginPreferences: LoginItemPreferences {
    var saves = 0
    var record: LoginItemRecord? { didSet { saves += 1 } }
    init(_ record: LoginItemRecord? = nil) { self.record = record }
    func flush() {}
}
