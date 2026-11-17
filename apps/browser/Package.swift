// swift-tools-version:6.2
// Zero Browser: Chromium (CEF) out of process, off-screen, drawn by Zero.app's side panel. helper.sh builds and bundles it.
import PackageDescription

// `cef` is a symlink to the CEF binary distribution (cef.sh); build/wrapper holds libcef_dll_wrapper.a built by its CMake.
let root = Context.packageDirectory
let cefFlags = ["-I\(root)/cef", "-fno-rtti", "-fno-exceptions", "-DCEF_USE_SANDBOX"]
let wrapper = ["-L\(root)/build/wrapper/libcef_dll_wrapper", "-lcef_dll_wrapper"]

let package = Package(
    name: "ZeroBrowser",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "ZeroBrowser", cxxSettings: [.unsafeFlags(cefFlags)],
                          linkerSettings: [.unsafeFlags(wrapper), .linkedFramework("AppKit"), .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
                                           .linkedFramework("IOSurface"), .linkedFramework("Security")]),
        // One binary, copied into the five helper apps Chromium launches (GPU, Renderer, Plugin, Alerts, plain).
        .executableTarget(name: "ZeroBrowserHelper", cxxSettings: [.unsafeFlags(cefFlags)],
                          linkerSettings: [.unsafeFlags(wrapper), .linkedFramework("CoreFoundation"), .linkedFramework("Security")]),
    ],
    cxxLanguageStandard: .cxx20
)
