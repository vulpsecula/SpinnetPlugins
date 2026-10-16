// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpinnetPlugins",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vulpsecula/Spinnet.git", revision: "7866233772deb029f15cdfa68f885e300b6a320a")
    ],
    targets: [
        .testTarget(name: "BundledPluginTests", dependencies: [
            .product(name: "SpinnetPluginTestKit", package: "Spinnet"),
            .product(name: "SpinnetCore", package: "Spinnet"),
            .product(name: "SpinnetPluginHelper", package: "Spinnet")
        ])
    ]
)
