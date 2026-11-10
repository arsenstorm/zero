// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Zero",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "ZeroCore"),
        // `zero`: the commands agents and hooks call most, on Darwin alone; the rest it hands to zero-full.
        // SwiftPM links Foundation into every program; unused here, it would still be loaded at each start.
        .executableTarget(name: "zero", path: "Sources/ZeroFront", linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip_dylibs"])]),
        .executableTarget(name: "zero-full", dependencies: ["ZeroCore"], path: "Sources/zero"),
        // Ghostty's terminal engine, built from source by `make ghostty` (see the Makefile).
        .binaryTarget(name: "GhosttyVt", path: "Vendor/GhosttyVt.xcframework"),
        // Keeps Zero's own agents' terminals running, whether or not Zero is open.
        .executableTarget(name: "zero-host", dependencies: ["ZeroCore", "GhosttyVt"], path: "Sources/ZeroHost"),
        // A task's provider terminal is drawn from the same engine (GhosttyView).
        .executableTarget(
            name: "ZeroApp", dependencies: ["ZeroCore", "GhosttyVt"],
            linkerSettings: [.linkedFramework("Carbon")]),
        .testTarget(name: "ZeroCoreTests", dependencies: ["ZeroCore"]),
    ],
    swiftLanguageModes: [.v5]
)
