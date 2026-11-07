// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mangekyou",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MangekyouCore", targets: ["MangekyouCore"]),
        .executable(name: "Mangekyou", targets: ["MangekyouApp"]),
        .executable(name: "mangekyou-inspect", targets: ["MangekyouInspect"]),
        .executable(name: "mangekyou-script", targets: ["MangekyouScript"])
    ],
    targets: [
        .target(name: "MangekyouCore"),
        .target(name: "MangekyouMedia", dependencies: ["MangekyouCore"]),
        .executableTarget(name: "MangekyouApp", dependencies: ["MangekyouCore", "MangekyouMedia"]),
        .executableTarget(name: "MangekyouInspect", dependencies: ["MangekyouCore", "MangekyouMedia"]),
        .executableTarget(name: "MangekyouScript", dependencies: ["MangekyouCore"]),
        .testTarget(name: "MangekyouCoreTests", dependencies: ["MangekyouCore", "MangekyouMedia"])
    ]
)
