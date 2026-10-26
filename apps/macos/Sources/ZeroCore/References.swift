import Foundation

/// Linear issues ("OPS-3096", "eng-9559"), pull requests ("#12846", "app#12846") and commits ("064c6bb7b5") in
/// what agents write, as links.
public enum References {
    private static let pattern = try! NSRegularExpression(pattern:
        #"\b([A-Za-z]{1,5})-(\d+)\b|(?:\b([\w.-]+/[\w.-]+|[\w.-]+))?#(\d+)\b|\b([0-9a-f]{7,40})\b"#)

    /// Each reference's range in `text` (UTF-16, as NSString counts) and where it goes. A bare "#123" or commit
    /// needs `repo` ("owner/name"); "name#123" takes `repo`'s owner. Issues are ids whose prefix is a team in
    /// `linear` (team key → workspace URL key, from the connected workspaces), so "UTF-8" stays text.
    /// `linearApp` opens them in Linear's app.
    public static func find(in text: String, repo: String?, linear: [String: String], linearApp: Bool) -> [(range: NSRange, url: URL)] {
        let ns = text as NSString
        func group(_ match: NSTextCheckingResult, _ i: Int) -> String? {
            match.range(at: i).location == NSNotFound ? nil : ns.substring(with: match.range(at: i))
        }
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let link: String?
            if let team = group(match, 1)?.uppercased(), let number = group(match, 2) {
                guard let workspace = linear[team] else { return nil }
                let path = "\(workspace)/issue/\(team)-\(number)"
                link = linearApp ? "linear://\(path)" : "https://linear.app/\(path)"
            } else if let number = group(match, 4) {
                let target: String? = switch group(match, 3) {
                case nil: repo
                case let name? where name.contains("/"): name
                case let name?: repo.map { $0.split(separator: "/")[0] + "/" + name }
                }
                link = target.map { "https://github.com/\($0)/pull/\(number)" }
            } else if let sha = group(match, 5) {
                // A hash has letters and digits; "1234567" and "deadbeef" are something else.
                guard sha.contains(where: \.isNumber), sha.contains(where: \.isLetter) else { return nil }
                link = repo.map { "https://github.com/\($0)/commit/\(sha)" }
            } else { link = nil }
            return link.flatMap(URL.init(string:)).map { (match.range, $0) }
        }
    }

    /// "owner/name" of the GitHub repository holding `cwd`, from its origin remote. Cached; nil when there is none.
    public static func repo(of cwd: String) -> String? {
        if let hit = lock.withLock({ repos[cwd] }) { return hit }
        let found = origin(cwd).flatMap(parse)
        lock.withLock { repos[cwd] = .some(found) }
        return found
    }

    static func parse(_ remote: String) -> String? {
        guard let range = remote.range(of: "github.com") else { return nil }
        var path = remote[range.upperBound...].drop { $0 == ":" || $0 == "/" }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        return path.split(separator: "/").count == 2 ? String(path) : nil
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var repos: [String: String?] = [:]

    private static func origin(_ cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "remote", "get-url", "origin"]
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
