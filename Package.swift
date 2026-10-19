// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AndroidOnMac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AndroidOnMacCore", targets: ["AndroidOnMacCore"]),
        .executable(name: "ProcessLauncher", targets: ["ProcessLauncher"]),
        .executable(name: "VirtualDisplayHelper", targets: ["VirtualDisplayHelper"]),
        .executable(name: "AndroidOnMac", targets: ["AndroidOnMac"])
    ],
    targets: [
        .target(name: "AndroidOnMacCore"),
        .target(name: "MacDisplayCapture"),
        .target(name: "MacDisplayTransport", dependencies: ["AndroidOnMacCore"]),
        .executableTarget(name: "ProcessLauncher"),
        .executableTarget(name: "VirtualDisplayHelper", exclude: ["DESKPAD_LICENSE.txt"], cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("CoreGraphics")]),
        .executableTarget(name: "AndroidOnMac", dependencies: ["AndroidOnMacCore", "MacDisplayCapture", "MacDisplayTransport"]),
        .testTarget(name: "MacDisplayCaptureTests", dependencies: ["MacDisplayCapture"]),
        .testTarget(name: "MacDisplayTransportTests", dependencies: ["MacDisplayTransport", "AndroidOnMacCore"]),
        .testTarget(name: "AndroidOnMacCoreTests", dependencies: ["AndroidOnMacCore", "ProcessLauncher"])
    ],
    swiftLanguageModes: [.v5]
)
