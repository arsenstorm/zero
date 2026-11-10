import Foundation

/// Claude Code's own record of its sessions: one JSONL per session under ~/.claude/projects/<cwd>, where the
/// user's turns and the title Claude gives the session ("aiTitle") live. Zero reads them to know which session
/// an agent is (to resume it) and what Claude called it (to label it).
public enum ClaudeSessions {
    public static var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    /// Claude Code's folder name for a working directory: every "/" and "." becomes "-".
    public static func folder(for cwd: String) -> URL {
        root.appendingPathComponent(cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-"))
    }

    /// The newest session in `cwd` whose first user turn is exactly `prompt`.
    public static func find(prompt: String, cwd: String) -> String? {
        guard let escaped = try? String(decoding: JSONEncoder().encode(prompt), as: UTF8.self) else { return nil }
        let needle = "\"role\":\"user\",\"content\":" + escaped
        for file in files(in: cwd) {
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains(needle) else { continue }
            return file.deletingPathExtension().lastPathComponent
        }
        return nil
    }

    /// What Claude titled the session, once it has.
    public static func title(of session: String, cwd: String) -> String? {
        let file = folder(for: cwd).appendingPathComponent(session + ".jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
            let range = text.range(of: "\"aiTitle\":\"([^\"]+)\"", options: [.regularExpression, .backwards])
        else { return nil }
        let match = text[range]
        return match.dropFirst("\"aiTitle\":\"".count).dropLast().replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Session files, newest first.
    private static func files(in cwd: String) -> [URL] {
        let folder = folder(for: cwd)
        let urls =
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "jsonl" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }
}
