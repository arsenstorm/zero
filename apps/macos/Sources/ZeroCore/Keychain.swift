import Foundation

/// Values in the login Keychain, read and written through macOS's `security` tool, as Claude Code does: an item then
/// trusts that tool rather than this build of Zero, so a rebuilt or updated Zero, and zerod, read it without asking
/// for the Keychain password. (Written through the Security framework instead, an item becomes this build's, and
/// `security` can't read it.) A value is never on a command line: `security -i` is given the command on its input.
/// `keychain`: a keychain file to use instead of the user's (a test's own).
public enum Keychain {
    public static func loadString(service: String, account: String, in keychain: String? = nil) -> String? {
        security(["find-generic-password", "-s", service, "-a", account, "-w"] + [keychain].compactMap { $0 })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func saveString(_ value: String?, service: String, account: String, in keychain: String? = nil) {
        guard let value else {
            _ = security(["delete-generic-password", "-s", service, "-a", account] + [keychain].compactMap { $0 })
            return
        }
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let line =
            "add-generic-password -U -a \(quoted(account)) -s \(quoted(service)) -w \(quoted(value))"
            + (keychain.map { " " + quoted($0) } ?? "") + "\n"
        // A line of `security -i` holds about 4 KB, and no line break: one that doesn't fit isn't kept, and reading it
        // back says so.
        guard line.utf8.count <= 4032, !(service + account + value).contains(where: \.isNewline) else { return }
        _ = security(["-i"], input: line)
    }

    private static func security(_ arguments: [String], input: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let given = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : given
        guard (try? process.run()) != nil else { return nil }
        if let input {
            given.fileHandleForWriting.write(Data(input.utf8))
            try? given.fileHandleForWriting.close()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
