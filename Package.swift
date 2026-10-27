// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpinnetPlugins",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vulpsecula/Spinnet.git", revision: "031ad42c4439fe07fcd7473d4f91671095d8c701")
    ],
    targets: [
        .testTarget(name: "BundledPluginTests", dependencies: [
            .product(name: "SpinnetPluginTestKit", package: "Spinnet"),
            .product(name: "SpinnetCore", package: "Spinnet"),
            .product(name: "SpinnetPluginHelper", package: "Spinnet")
        ])
    ]
)
