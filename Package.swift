// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyCompress",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MyCompressCLI", targets: ["MyCompressCLI"]),
        .executable(name: "MyCompressApp", targets: ["MyCompressGUI"])
    ],
    targets: [
        .target(
            name: "MyCompressCore",
            path: "Sources/MyCompressCore"
        ),
        .executableTarget(
            name: "MyCompressCLI",
            dependencies: ["MyCompressCore"],
            path: "Sources/MyCompressCLI"
        ),
        .executableTarget(
            name: "MyCompressGUI",
            dependencies: ["MyCompressCore"],
            path: "Sources/MyCompressGUI",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
