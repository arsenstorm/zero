import Foundation

/// The Zero plugin for Claude Code (the zero skill plus its session-start and stop hooks), shipped inside
/// Zero.app and installed with Claude Code's own plugin commands. The marketplace is the bundled folder, so
/// an update of Zero is an update of the plugin.
enum ClaudePlugin {
    static var bundled: String { Bundle.main.resourceURL!.appendingPathComponent("plugin").path }

    static func isInstalled() async -> Bool {
        (await shell("claude plugin list 2>/dev/null")).contains("zero@zero")
    }

    static func install() async -> String? {
        let path = bundled.replacingOccurrences(of: "'", with: "'\\''")
        let out = await shell("claude plugin marketplace add '\(path)' 2>&1; claude plugin marketplace update zero 2>&1; claude plugin install zero@zero 2>&1")
        return await isInstalled() ? nil : out
    }

    static func uninstall() async { _ = await shell("claude plugin uninstall zero@zero 2>&1") }

    /// A login shell, so the PATH that finds `claude` is the one in Arsen's terminal.
    private static func shell(_ command: String) async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
