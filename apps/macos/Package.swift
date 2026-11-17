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
        // Zero's side of Zero Browser (Chromium in its own app, Contents/Helpers): starts it, shows its frames, sends its
        // input. Plain Obj-C: CEF itself is only in the browser app.
        .target(
            name: "ZeroBrowserHost",
            linkerSettings: [.linkedFramework("IOSurface"), .linkedFramework("QuartzCore"), .linkedFramework("Security")]),
        .executableTarget(name: "ZeroApp", dependencies: ["ZeroCore", "ZeroBrowserHost"], linkerSettings: [.linkedFramework("Carbon")]),
        .testTarget(name: "ZeroCoreTests", dependencies: ["ZeroCore", "ZeroBrowserHost"]),
    ],
    swiftLanguageModes: [.v5]
)
