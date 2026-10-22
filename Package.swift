// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpinnetPlugins",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vulpsecula/Spinnet.git", revision: "0219cabb874593775c7d0762be5723b2392097a7")
    ],
    targets: [
        .testTarget(name: "BundledPluginTests", dependencies: [
            .product(name: "SpinnetPluginTestKit", package: "Spinnet"),
            .product(name: "SpinnetCore", package: "Spinnet"),
            .product(name: "SpinnetPluginHelper", package: "Spinnet")
        ])
    ]
)
