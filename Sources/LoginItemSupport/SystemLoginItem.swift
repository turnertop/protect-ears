import Foundation
import Security
import ServiceManagement

public final class SystemLoginItemService: LoginItemService {
    public init() {}
    public var status: SMAppService.Status { SMAppService.mainApp.status }
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
}

public final class DefaultsLoginItemPreferences: LoginItemPreferences {
    public static let key = "loginItemPreference"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var record: LoginItemRecord? {
        get {
            guard let data = defaults.data(forKey: Self.key) else { return nil }
            return try? JSONDecoder().decode(LoginItemRecord.self, from: data)
        }
        set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.key)
        }
    }
    // The update handoff crosses processes and can be followed immediately by
    // replacing the bundle. Flush these infrequent changes before returning.
    public func flush() { defaults.synchronize() }
}

public enum LoginItemBuild {
    /// Includes the code hash: local rebuilds can change identity without bumping
    /// the version. Capture once at launch, before an installer moves the bundle.
    public static func identifier(bundle: Bundle = .main) -> String {
        var code: SecStaticCode?
        var information: CFDictionary?
        var hash = "unavailable"
        if SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess,
           let code,
           SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
           let data = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data {
            hash = data.map { String(format: "%02x", $0) }.joined()
        }
        let inode = (try? FileManager.default.attributesOfItem(atPath: bundle.bundleURL.path)[.systemFileNumber]) as? NSNumber
        return "\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"):\(hash):\(inode?.stringValue ?? "unknown"):\(bundle.bundleURL.standardizedFileURL.path)"
    }
}
