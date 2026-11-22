// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PluginKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PluginKit", targets: ["PluginKit"])],
    dependencies: [.package(path: "../NotchKit")],
    targets: [
        .target(name: "PluginKit", dependencies: [.product(name: "NotchKit", package: "NotchKit")]),
        .testTarget(name: "PluginKitTests", dependencies: ["PluginKit"]),
    ]
)
