import AppKit
import SwiftUI
import ZeroCore

/// Zero opened from Downloads or its disk image: before anything else (onboarding, zerod), a small window of its own
/// that moves it to Applications and opens it from there. Out there the updater can't replace it, and macOS runs a
/// downloaded app from a random read-only copy (translocation).
@MainActor @Observable final class MoveToApplications {
    /// Where this Zero really is, if it should move; nil for an installed or development build.
    static func needed() -> URL? {
        let app = AppLocation.original(of: Bundle.main.bundleURL)
        return AppLocation.needsMove(app, home: FileManager.default.homeDirectoryForCurrentUser) ? app : nil
    }

    let source: URL
    var folder = URL(fileURLWithPath: "/Applications")
    /// What the window says under its line: what moving replaces, or why it didn't work.
    var detail: String?
    var moving = false
    /// /Applications can't be written to on this account: offered ~/Applications instead.
    var inHome: Bool { folder.path != "/Applications" }
    var destination: URL { folder.appendingPathComponent("Zero.app") }

    init(source: URL) {
        self.source = source
        if !FileManager.default.isWritableFile(atPath: folder.path) {
            folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            detail = "Your account can't add apps to /Applications, so Zero goes in the Applications folder in your home."
        } else if FileManager.default.fileExists(atPath: destination.path) {
            detail = "The Zero already there moves to the Trash."
        }
    }

    func window() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: MoveView(model: self)))
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    func move() async {
        moving = true
        do {
            try await place()
            relaunch()
        } catch {
            detail = error.localizedDescription
            moving = false
        }
    }

    /// Copies this Zero beside the destination, checks the copy, then puts it in place (an older Zero there goes to
    /// the Trash, quitting first if it's open).
    private func place() async throws {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(".Zero-\(UUID().uuidString).app")
        defer { try? files.removeItem(at: copy) }
        try files.copyItem(at: source, to: copy)
        // A copy keeps the download's quarantine, and macOS would translocate it again; Finder's own move clears it.
        run("/usr/bin/xattr", ["-d", "-r", "com.apple.quarantine", copy.path])
        guard Updates.signedAsThis(copy) else { throw Failure("The copy in \(folder.path) didn't check out. Try again.") }
        if files.fileExists(atPath: destination.path) {
            try await quitInstalled()
            try files.trashItem(at: destination, resultingItemURL: nil)
        }
        try files.moveItem(at: copy, to: destination)
    }

    private func quitInstalled() async throws {
        let open = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current && $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL }
        for app in open { app.terminate() }
        for _ in 0..<50 where open.contains(where: { !$0.isTerminated }) { try await Task.sleep(for: .milliseconds(100)) }
        if open.contains(where: { !$0.isTerminated }) { throw Failure("Quit the Zero that's open, then try again.") }
    }

    /// Done with this copy: from a disk image, it's ejected once this Zero has quit; anywhere else, it goes to the
    /// Trash. The installed Zero opens once this one is gone, so there's never two.
    private func relaunch() {
        let values = try? source.resourceValues(forKeys: [.volumeURLKey, .volumeIsReadOnlyKey])
        var volume = ""
        if values?.volumeIsReadOnly == true, let url = values?.volume, url.path != "/" {
            volume = url.path
        } else {
            try? FileManager.default.trashItem(at: source, resultingItemURL: nil)
        }
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.1; done
            [ -z "$2" ] || /usr/bin/hdiutil detach "$2" -quiet
            /usr/bin/open "$3"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", "\(ProcessInfo.processInfo.processIdentifier)", volume, destination.path]
        guard (try? process.run()) != nil else {
            detail = "Zero is in \(folder.path) now. Open it from there."
            return
        }
        NSApp.terminate(nil)
    }

    private func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}

private struct MoveView: View {
    let model: MoveToApplications

    var body: some View {
        VStack(spacing: 0) {
            ZeroMark().frame(width: 58, height: 56).padding(.top, 40)
            Text("Zero needs to be in your Applications folder").font(.system(size: 15, weight: .semibold)).padding(.top, 20)
            // Its space kept whether or not there's anything to say, so the buttons never move.
            Text(model.detail ?? " ").font(.system(size: 12.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2, reservesSpace: true).frame(maxWidth: 320).padding(.top, 8)
            HStack(spacing: 8) {
                DialogButton(title: "Quit") { NSApp.terminate(nil) }
                DialogButton(
                    title: model.inHome ? "Move to ~/Applications" : "Move to Applications", kind: .primary, enabled: !model.moving
                ) {
                    Task { await model.move() }
                }
            }
            .padding(.top, 20).padding(.bottom, 28)
        }
        .frame(width: 400)
        .background(Theme.card)
    }
}
