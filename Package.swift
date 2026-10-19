// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AndroidOnMac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AndroidOnMacCore", targets: ["AndroidOnMacCore"]),
        .executable(name: "ProcessLauncher", targets: ["ProcessLauncher"]),
        .executable(name: "AndroidOnMac", targets: ["AndroidOnMac"])
    ],
    targets: [
        .target(name: "AndroidOnMacCore"),
        .executableTarget(name: "ProcessLauncher"),
        .executableTarget(name: "AndroidOnMac", dependencies: ["AndroidOnMacCore"]),
        .testTarget(name: "AndroidOnMacCoreTests", dependencies: ["AndroidOnMacCore", "ProcessLauncher"])
    ],
    swiftLanguageModes: [.v5]
)
