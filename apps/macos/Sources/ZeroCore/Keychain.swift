import Foundation

/// Values in the login Keychain, read and written through macOS's `security` tool, as Claude Code does: an item then
/// trusts that tool rather than this build of Zero, so a rebuilt or updated Zero reads it without asking for the
/// Keychain password.
public enum Keychain {
    public static func loadString(service: String, account: String) -> String? {
        security(["find-generic-password", "-s", service, "-a", account, "-w"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func saveString(_ value: String?, service: String, account: String) {
        if let value {
            _ = security(["add-generic-password", "-U", "-s", service, "-a", account, "-w", value])
        } else {
            _ = security(["delete-generic-password", "-s", service, "-a", account])
        }
    }

    private static func security(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
