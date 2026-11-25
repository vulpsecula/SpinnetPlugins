// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpinnetPlugins",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vulpsecula/Spinnet.git", revision: "f5500efe29f6e09413047b1dedc887fb483fcef8")
    ],
    targets: [
        .testTarget(name: "PluginTests", dependencies: [
            .product(name: "SpinnetPluginTestKit", package: "Spinnet"),
            .product(name: "SpinnetCore", package: "Spinnet"),
            .product(name: "SpinnetPluginHelper", package: "Spinnet")
        ])
    ]
)
