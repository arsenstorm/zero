import Foundation
#if os(macOS)
    import Security
#endif

/// A release of Zero on GitHub: its version (the tag, "v0.2") and the zipped app among its files.
public struct Release: Decodable, Equatable, Sendable {
    public let tag: String
    public let notes: String?
    public let assets: [Asset]

    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let url: URL
        enum CodingKeys: String, CodingKey { case name, url = "browser_download_url" }
    }

    enum CodingKeys: String, CodingKey { case tag = "tag_name", notes = "body", assets }

    public var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
    public var app: Asset? { assets.first { $0.name.hasSuffix(".zip") } }
}

/// Zero's updates, from its GitHub releases (`make release` makes them). Nothing installs unless it's signed as the
/// running build is.
public enum Updates {
    public static let repository = "arsenstorm/zero"

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Whether version `a` comes after `b`, number by number ("0.10" after "0.9").
    public static func newer(_ a: String, than b: String) -> Bool {
        let (x, y) = (a.split(separator: ".").map { Int($0) ?? 0 }, b.split(separator: ".").map { Int($0) ?? 0 })
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p > q }
        }
        return false
    }

    public static func latest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
            return try JSONDecoder().decode(Release.self, from: data)
        }
        // ponytail: while the repository is private only the user's GitHub CLI can read it; drop once it's public.
        guard let data = gh(["api", "repos/\(repository)/releases/latest"]) else {
            throw Failure("Couldn't reach Zero's releases on GitHub")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    #if os(macOS)
        /// The release's app, downloaded and unzipped into a folder of its own.
        public static func download(_ release: Release) async throws -> URL {
            guard let asset = release.app else { throw Failure("Zero \(release.version) has no app to download") }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zero-update-\(release.version)")
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let zip = folder.appendingPathComponent(asset.name)
            if let (file, response) = try? await URLSession.shared.download(from: asset.url),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                try FileManager.default.moveItem(at: file, to: zip)
            } else if gh(["release", "download", release.tag, "-R", repository, "-p", asset.name, "-D", folder.path]) == nil {
                throw Failure("Couldn't download Zero \(release.version)")
            }
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) != nil else {
                throw Failure("Couldn't unzip Zero \(release.version)")
            }
            let app = folder.appendingPathComponent("Zero.app")
            guard signedAsThis(app) else { throw Failure("Zero \(release.version) isn't signed as this Zero is, so it wasn't installed") }
            return app
        }

        /// Whether the app at `app` meets this build's own designated requirement: signed by the same identity, intact.
        public static func signedAsThis(_ app: URL) -> Bool {
            var running: SecCode?, me: SecStaticCode?, requirement: SecRequirement?, theirs: SecStaticCode?
            guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
                SecCodeCopyStaticCode(running, [], &me) == errSecSuccess, let me,
                SecCodeCopyDesignatedRequirement(me, [], &requirement) == errSecSuccess,
                SecStaticCodeCreateWithPath(app as CFURL, [], &theirs) == errSecSuccess, let theirs
            else { return false }
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
            return SecStaticCodeCheckValidity(theirs, flags, requirement) == errSecSuccess
        }

        /// Installs `app` (checked by `download`) with its own install script, which quits this app, puts the new one in
        /// its place, restarts zerod gracefully and opens Zero again.
        public static func install(_ app: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [app.appendingPathComponent("Contents/Resources/install.sh").path, app.path, "restart"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
    #endif

    /// `gh` with the user's own sign-in, through their login shell (an app started from Finder has no Homebrew PATH).
    private static func gh(_ arguments: [String]) -> Data? {
        run("/bin/zsh", ["-lc", "gh \"$@\"", "gh"] + arguments)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> Data? {
        #if os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        #else
            return nil
        #endif
    }
}
