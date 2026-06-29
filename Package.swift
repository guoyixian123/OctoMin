// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OctoMin",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "OctoMinCLI", targets: ["OctoMinCLI"]),
        .executable(name: "OctoMinApp", targets: ["OctoMinGUI"])
    ],
    targets: [
        .target(
            name: "OctoMinCore",
            path: "Sources/OctoMinCore"
        ),
        .executableTarget(
            name: "OctoMinCLI",
            dependencies: ["OctoMinCore"],
            path: "Sources/OctoMinCLI"
        ),
        .executableTarget(
            name: "OctoMinGUI",
            dependencies: ["OctoMinCore"],
            path: "Sources/OctoMinGUI",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
