// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Zero",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "ZeroCore"),
        .executableTarget(name: "zero", dependencies: ["ZeroCore"]),
        .executableTarget(name: "ZeroApp", dependencies: ["ZeroCore"],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .testTarget(name: "ZeroCoreTests", dependencies: ["ZeroCore"]),
    ],
    swiftLanguageModes: [.v5]
)
