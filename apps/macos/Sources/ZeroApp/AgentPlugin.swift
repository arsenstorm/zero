import Foundation

/// The Zero plugin for Claude Code (the zero skill plus its session-start and stop hooks), shipped inside
/// Zero.app and installed with Claude Code's own plugin commands. The marketplace is the bundled folder, so
/// an update of Zero is an update of the plugin.
enum ClaudePlugin {
    static var bundled: String { Bundle.main.resourceURL!.appendingPathComponent("plugin").path }

    /// Read from Claude Code's record of installed plugins, which is instant, rather than `claude plugin list`.
    static var isInstalled: Bool {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any] else { return false }
        return plugins["zero@zero"] != nil
    }

    static func install() async -> String? {
        let path = bundled.replacingOccurrences(of: "'", with: "'\\''")
        let out = await shell("claude plugin marketplace add '\(path)' 2>&1; claude plugin marketplace update zero 2>&1; claude plugin install zero@zero 2>&1")
        return isInstalled ? nil : out
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

/// Zero's MCP server (`zerod mcp`: the scratchpads) in Codex's and OpenCode's own config, one entry each, added and
/// taken out as written so nothing else in either file changes. Claude Code gets it with the Zero plugin.
enum AgentMCP {
    static let command = "/Applications/Zero.app/Contents/MacOS/zerod"
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let codex = home.appendingPathComponent(".codex/config.toml")
    private static let opencode = home.appendingPathComponent(".config/opencode/opencode.json")
    private static let codexEntry = "\n[mcp_servers.zero]\ncommand = \"\(command)\"\nargs = [\"mcp\"]\n"
    private static let opencodeEntry = "\"zero\": {\"type\": \"local\", \"command\": [\"\(command)\", \"mcp\"], \"enabled\": true}"

    static var isInstalled: Bool {
        let toml = (try? String(contentsOf: codex, encoding: .utf8)) ?? ""
        let json = try? String(contentsOf: opencode, encoding: .utf8)
        return toml.contains("[mcp_servers.zero]") && (json.map(inOpenCode) ?? true)
    }

    private static func inOpenCode(_ text: String) -> Bool {
        let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        return (json?["mcp"] as? [String: Any])?["zero"] != nil
    }

    /// Adds it where it's missing; an error to show, or nil.
    static func install() -> String? {
        var problems: [String] = []
        if let toml = try? String(contentsOf: codex, encoding: .utf8) {
            if !toml.contains("[mcp_servers.zero]") {
                do { try (toml + codexEntry).write(to: codex, atomically: true, encoding: .utf8) } catch { problems.append("Codex: \(error.localizedDescription)") }
            }
        }
        if let text = try? String(contentsOf: opencode, encoding: .utf8), !inOpenCode(text) {
            if let edited = openCodeAdding(to: text) {
                do { try edited.write(to: opencode, atomically: true, encoding: .utf8) } catch { problems.append("OpenCode: \(error.localizedDescription)") }
            } else {
                problems.append("OpenCode: add \(opencodeEntry) under \"mcp\" in \(opencode.path)")
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    static func uninstall() {
        if let toml = try? String(contentsOf: codex, encoding: .utf8), toml.contains(codexEntry) {
            try? toml.replacingOccurrences(of: codexEntry, with: "").write(to: codex, atomically: true, encoding: .utf8)
        }
        if let text = try? String(contentsOf: opencode, encoding: .utf8) {
            for form in [opencodeEntry + ",\n    ", ",\n    " + opencodeEntry, opencodeEntry] where text.contains(form) {
                let edited = text.replacingOccurrences(of: form, with: "")
                if (try? JSONSerialization.jsonObject(with: Data(edited.utf8))) != nil { try? edited.write(to: opencode, atomically: true, encoding: .utf8) }
                break
            }
        }
    }

    /// OpenCode's config with the entry first in its "mcp" (made if missing), or nil when it's there already or the
    /// result wouldn't parse.
    private static func openCodeAdding(to text: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], !inOpenCode(text) else { return nil }
        let edited: String
        if let range = text.range(of: #""mcp"\s*:\s*\{"#, options: .regularExpression) {
            let empty = (json["mcp"] as? [String: Any])?.isEmpty ?? true
            edited = text.replacingCharacters(in: range, with: text[range] + "\n    " + opencodeEntry + (empty ? "" : ","))
        } else if let close = text.range(of: "}", options: .backwards) {
            edited = text.replacingCharacters(in: close, with: ",\n  \"mcp\": {\n    \(opencodeEntry)\n  }\n}")
        } else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(edited.utf8))) != nil ? edited : nil
    }
}
