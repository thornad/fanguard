// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FanGuard",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FanGuardCore"),
        .executableTarget(name: "FanGuard", dependencies: ["FanGuardCore"]),
        .executableTarget(name: "fanguardd", dependencies: ["FanGuardCore"]),
        .testTarget(name: "FanGuardCoreTests", dependencies: ["FanGuardCore"]),
    ]
)
