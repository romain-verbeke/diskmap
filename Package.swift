// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskMap",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DiskMap", targets: ["DiskMap"]),
        .executable(name: "diskmap-cli", targets: ["diskmap-cli"]),
    ],
    targets: [
        .target(name: "DiskMapCore"),
        .executableTarget(name: "DiskMap", dependencies: ["DiskMapCore"]),
        .executableTarget(name: "diskmap-cli", dependencies: ["DiskMapCore"]),
        .testTarget(name: "DiskMapCoreTests", dependencies: ["DiskMapCore"]),
    ]
)
