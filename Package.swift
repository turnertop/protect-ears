// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ProtectEars",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ProtectEars", targets: ["ProtectEars"])],
    targets: [
        .target(name: "VolumeGuardCore"),
        .executableTarget(name: "ProtectEars", dependencies: ["VolumeGuardCore"]),
        .executableTarget(name: "GuardEngineChecks", dependencies: ["VolumeGuardCore"], path: "Checks")
    ]
)
