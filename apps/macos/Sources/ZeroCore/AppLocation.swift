import Foundation

/// Where Zero runs from, and whether it should move to Applications first: the updater replaces it in place, and the
/// `zero` link and zerod's install point into it, so a copy left in Downloads (or on the disk image) breaks them.
public enum AppLocation {
    /// Whether the app at `app` (its real path, not a translocated one) should be moved: an app outside
    /// /Applications and ~/Applications, unless it's a development build (`make bundle`'s build/Zero.app in a git
    /// checkout; `swift run` and Xcode run no .app at all).
    public static func needsMove(_ app: URL, home: URL, exists: (String) -> Bool = FileManager.default.fileExists) -> Bool {
        let path = app.standardizedFileURL.path
        guard path.hasSuffix(".app") else { return false }
        let folders = ["/Applications/", home.standardizedFileURL.appendingPathComponent("Applications").path + "/"]
        if folders.contains(where: path.hasPrefix) { return false }
        let parent = app.standardizedFileURL.deletingLastPathComponent()
        let development =
            parent.lastPathComponent == "build" && exists(parent.deletingLastPathComponent().appendingPathComponent(".git").path)
        return !development
    }

    #if os(macOS)
        /// The app's real path: where it was opened from, when macOS runs it translocated (a quarantined app opened
        /// where Finder didn't move it, from a random read-only path under AppTranslocation).
        public static func original(of app: URL) -> URL {
            typealias IsTranslocated =
                @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
            typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
            // Security.framework's SecTranslocate calls aren't in the public headers; LetsMove and Sparkle look them up too.
            guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
                let isSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
                let originalSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
            else { return app }
            var translocated = false
            guard unsafeBitCast(isSymbol, to: IsTranslocated.self)(app as CFURL, &translocated, nil), translocated,
                let original = unsafeBitCast(originalSymbol, to: OriginalPath.self)(app as CFURL, nil)?.takeRetainedValue()
            else { return app }
            return original as URL
        }
    #endif
}
