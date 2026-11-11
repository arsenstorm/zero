import Foundation

/// A model's id as people say it, for one not in its provider's list (Claude's list has Claude Code's aliases, Codex's
/// and OpenCode's their CLIs' caches; a task runs on a full id, or one since dropped): "claude-opus-5-5" is "Opus 5.5",
/// "claude-fable-5-1[1m]" "Fable 5.1 (1M)", "gpt-5.5-codex" "GPT-5.5 Codex", OpenCode's "zai/glm-5.3" "GLM-5.3".
public enum ModelNames {
    /// Short names said in capitals.
    private static let acronyms: Set<String> = ["gpt", "glm", "llm", "ai"]

    public static func readable(_ id: String) -> String {
        var rest = id
        // OpenCode's "provider/model": the provider is the chip's icon.
        if let slash = rest.lastIndex(of: "/") { rest = String(rest[rest.index(after: slash)...]) }
        let long = rest.hasSuffix("[1m]")
        if long { rest = String(rest.dropLast(4)) }
        let parts = rest.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return id }
        let name: String
        if parts[0] == "claude", parts.count >= 3, let major = Int(parts[2]) {
            // Claude's: family, then major and minor as one version.
            let minor = parts.count > 3 ? Int(parts[3]) : nil
            name = parts[1].capitalized + " " + (minor.map { "\(major).\($0)" } ?? "\(major)")
        } else if parts.count == 1, ["fable", "opus", "sonnet", "haiku"].contains(parts[0]) {
            name = parts[0].capitalized
        } else {
            // A family said in capitals keeps its version joined ("GPT-5.5", "GLM-5.3"); the rest are words.
            var words: [String] = []
            var index = 0
            if acronyms.contains(parts[0].lowercased()) {
                words.append(parts[0].uppercased() + (parts.count > 1 && parts[1].first?.isNumber == true ? "-" + parts[1] : ""))
                index = parts.count > 1 && parts[1].first?.isNumber == true ? 2 : 1
            }
            words += parts[index...].map { $0.first?.isLetter == true ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 }
            name = words.joined(separator: " ")
        }
        return name + (long ? " (1M)" : "")
    }
}
