// swift-tools-version: 5.9
// AgentHub: CodeIsland (MIT, (c) wxtsky) vendored as a library for the notch.
import PackageDescription

let package = Package(
    name: "AgentHub",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentHub", targets: ["AgentHub"]),
        .executable(name: "codeisland-bridge", targets: ["codeisland-bridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(path: "../NotchKit"),
    ],
    targets: [
        .target(name: "CodeIslandCore", path: "Sources/CodeIslandCore"),
        .target(
            name: "AgentHub",
            dependencies: [
                "CodeIslandCore",
                .product(name: "Yams", package: "Yams"),
                .product(name: "NotchKit", package: "NotchKit"),
            ],
            path: "Sources/AgentHub",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "codeisland-bridge",
            dependencies: ["CodeIslandCore"],
            path: "Sources/codeisland-bridge"
        ),
        .target(name: "TestDefaultsReset", path: "Tests/TestDefaultsReset"),
        // Stand-in ancestor processes the bridge golden tests run under; built next to the test bundles, never shipped.
        .executableTarget(name: "codeisland-golden-stub", path: "Tests/GoldenAncestryStub"),
        .testTarget(name: "AgentHubTests", dependencies: ["AgentHub"], path: "Tests/AgentHubTests"),
        .testTarget(
            name: "CodeIslandCoreTests",
            dependencies: ["CodeIslandCore", "TestDefaultsReset"],
            path: "Tests/CodeIslandCoreTests"
        ),
    ]
)
