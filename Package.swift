// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "AndroidOnMac",
    platforms: [.macOS(.v13)],
    products: [.library(name: "AndroidOnMacCore", targets: ["AndroidOnMacCore"])],
    targets: [
        .target(name: "AndroidOnMacCore"),
        .testTarget(name: "AndroidOnMacCoreTests", dependencies: ["AndroidOnMacCore"])
    ]
)
