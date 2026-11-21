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
        // The interpreter's dispatch frame exceeds the Swift worker-thread stack
        // under -Onone. Keep debug symbols and optimize the core; the app stays unoptimized.
        .target(name: "MangekyouCore", swiftSettings: [
            .unsafeFlags(["-O"], .when(configuration: .debug))
        ]),
        .target(name: "MangekyouMedia", dependencies: ["MangekyouCore"]),
        .executableTarget(name: "MangekyouApp", dependencies: ["MangekyouCore", "MangekyouMedia"]),
        .executableTarget(name: "MangekyouInspect", dependencies: ["MangekyouCore", "MangekyouMedia"]),
        .executableTarget(name: "MangekyouScript", dependencies: ["MangekyouCore", "MangekyouMedia"]),
        .executableTarget(name: "SaveInterruptionProbe", dependencies: ["MangekyouCore"], path: "ResearchTools/SaveInterruptionProbe"),
        .executableTarget(name: "BlurFilterProbe", dependencies: ["MangekyouCore", "MangekyouMedia"], path: "ResearchTools/BlurFilterProbe"),
        .executableTarget(name: "ColorFilterProbe", dependencies: ["MangekyouCore", "MangekyouMedia"], path: "ResearchTools/ColorFilterProbe"),
        .testTarget(name: "MangekyouCoreTests", dependencies: ["MangekyouCore", "MangekyouMedia"])
    ]
)
