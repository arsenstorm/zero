// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Zero",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "ZeroCore"),
        .executableTarget(name: "zero", dependencies: ["ZeroCore"]),
        // Ghostty's terminal engine, built from source by `make ghostty` (see the Makefile).
        .binaryTarget(name: "GhosttyVt", path: "Vendor/GhosttyVt.xcframework"),
        // Keeps Zero's own agents' terminals running, whether or not Zero is open.
        .executableTarget(name: "zero-host", dependencies: ["ZeroCore", "GhosttyVt"], path: "Sources/ZeroHost"),
        .executableTarget(name: "ZeroApp", dependencies: ["ZeroCore"],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .testTarget(name: "ZeroCoreTests", dependencies: ["ZeroCore"]),
    ],
    swiftLanguageModes: [.v5]
)
