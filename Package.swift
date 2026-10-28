// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpinnetPlugins",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vulpsecula/Spinnet.git", revision: "f54190de59ef12ea5a07c39126d21cc3f57f70a9")
    ],
    targets: [
        .testTarget(name: "PluginTests", dependencies: [
            .product(name: "SpinnetPluginTestKit", package: "Spinnet"),
            .product(name: "SpinnetCore", package: "Spinnet"),
            .product(name: "SpinnetPluginHelper", package: "Spinnet")
        ])
    ]
)
