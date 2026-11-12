import Foundation
import ServiceManagement

public protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

public struct LoginItemRecord: Codable, Equatable {
    public var requested: Bool
    public var build: String
    public var lastStatus: Int
    public var preparedForUpdate: Bool
    public var approvalRequired: Bool

    public init(requested: Bool, build: String, status: SMAppService.Status, preparedForUpdate: Bool = false) {
        self.requested = requested
        self.build = build
        lastStatus = status.rawValue
        self.preparedForUpdate = preparedForUpdate
        approvalRequired = status == .requiresApproval
    }
}

public protocol LoginItemPreferences: AnyObject {
    var record: LoginItemRecord? { get set }
    func flush()
}

public struct LoginItemSnapshot: Equatable {
    public var requested = false
    public var status: SMAppService.Status = .notRegistered
    public var preparedForUpdate = false
    public var error: String?
    public init() {}
    public var needsApproval: Bool { requested && status == .requiresApproval }
    public var needsRepair: Bool {
        !preparedForUpdate && ((requested && (status == .notFound || status == .notRegistered))
                               || (!requested && status == .enabled))
    }
}

/// Called at launch and on explicit UI/lifecycle events, never on a polling timer.
/// A version change may repair a missing registration; ordinary relaunches must
/// not undo an item removed in System Settings. OS approval is always respected.
public final class LoginItemController {
    private let service: LoginItemService
    private let preferences: LoginItemPreferences
    private let build: String
    public private(set) var snapshot = LoginItemSnapshot()

    public init(service: LoginItemService, preferences: LoginItemPreferences, build: String) {
        self.service = service
        self.preferences = preferences
        self.build = build
    }

    @discardableResult
    public func restoreAfterLaunch() -> LoginItemSnapshot {
        let status = service.status
        guard var record = preferences.record else {
            // Older releases did not save intent. Adopt an existing enabled
            // registration, but never assume that missing/denied means opt-in.
            return save(LoginItemRecord(requested: status == .enabled, build: build, status: status))
        }
        let changed = record.build != build
        if record.requested, !record.approvalRequired, status != .requiresApproval,
           (changed || record.preparedForUpdate), status != .enabled {
            // Consume this build's repair attempt before touching the service.
            // Failure remains visible; activation events cannot retry in a loop.
            record.build = build
            record.preparedForUpdate = false
            save(record)
            return enable(record)
        }
        record = observing(status, record: record, preserveMissing: record.preparedForUpdate)
        record.build = build
        record.preparedForUpdate = false
        return save(record)
    }

    @discardableResult
    public func refresh() -> LoginItemSnapshot {
        let status = service.status
        let record = preferences.record ?? LoginItemRecord(requested: status == .enabled, build: build, status: status)
        return save(observing(status, record: record, preserveMissing: record.preparedForUpdate))
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> LoginItemSnapshot {
        var record = LoginItemRecord(requested: enabled, build: build, status: service.status)
        save(record)
        if enabled { return enable(record) }
        do {
            if service.status == .enabled || service.status == .requiresApproval { try service.unregister() }
        } catch {
            record.lastStatus = service.status.rawValue
            return save(record, error: "Could not turn off Start at login: \(error.localizedDescription)")
        }
        record.lastStatus = service.status.rawValue
        return save(record)
    }

    /// An installer calls this in the OLD bundle before moving it to a backup.
    /// The next launch restores the choice, including if an update is rolled back.
    @discardableResult
    public func prepareForUpdate() -> LoginItemSnapshot {
        refresh()
        var record = preferences.record!
        record.preparedForUpdate = true
        save(record)
        do {
            // Keep a denied/pending OS approval intact across replacement.
            if service.status == .enabled { try service.unregister() }
        } catch {
            record.preparedForUpdate = false
            record.lastStatus = service.status.rawValue
            return save(record, error: "Could not prepare the login item for updating: \(error.localizedDescription)")
        }
        record.lastStatus = service.status.rawValue
        return save(record)
    }

    private func enable(_ initial: LoginItemRecord) -> LoginItemSnapshot {
        var record = initial
        var errorText: String?
        do {
            // A revoked OS approval cannot be repaired by registering again.
            if service.status != .enabled && service.status != .requiresApproval { try service.register() }
        } catch {
            if service.status != .enabled && service.status != .requiresApproval {
                errorText = "Could not enable Start at login: \(error.localizedDescription)"
            }
        }
        record.lastStatus = service.status.rawValue
        record.approvalRequired = service.status == .requiresApproval
        return save(record, error: errorText)
    }

    private func observing(_ status: SMAppService.Status, record initial: LoginItemRecord,
                           preserveMissing: Bool) -> LoginItemRecord {
        var record = initial
        if status == .enabled {
            // An observed transition can reflect an external opt-in. A failed
            // explicit Off request must not silently become an On preference.
            if record.lastStatus != status.rawValue { record.requested = true }
            record.approvalRequired = false
        } else if record.lastStatus == SMAppService.Status.enabled.rawValue && !preserveMissing {
            // Removing the item or revoking consent outside the app is an off choice.
            record.requested = false
        }
        if status == .requiresApproval { record.approvalRequired = true }
        record.lastStatus = status.rawValue
        return record
    }

    @discardableResult
    private func save(_ record: LoginItemRecord, error: String? = nil) -> LoginItemSnapshot {
        if preferences.record != record { preferences.record = record; preferences.flush() }
        snapshot.requested = record.requested
        snapshot.status = service.status
        snapshot.preparedForUpdate = record.preparedForUpdate
        snapshot.error = error
        if snapshot.needsRepair, snapshot.error == nil {
            snapshot.error = !record.requested
                ? "Start at login is still enabled in macOS. Use Retry to turn it off."
                : record.approvalRequired
                ? "Start at login needs your approval after this update. Use Retry to review it."
                : "Start at login is not registered. Use Retry to restore it."
        }
        return snapshot
    }
}
