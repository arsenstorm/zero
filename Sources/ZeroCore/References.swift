import Foundation

/// Linear issues ("OPS-3096") and pull requests ("#12846", "app#12846") in what agents write, as links.
public enum References {
    // ponytail: the workspace is Arsen's; a Settings field when Zero has a second Linear user.
    public static let linearWorkspace = "acme"
    /// Look like issue ids but are standards.
    private static let notIssues: Set<String> = ["UTF", "ISO", "SHA", "RFC", "CVE", "GPT", "MD", "TLS", "HTTP", "X"]
    private static let pattern = try! NSRegularExpression(pattern: #"\b([A-Z][A-Z0-9]{1,9})-\d+\b|(?:\b([\w.-]+/[\w.-]+|[\w.-]+))?#(\d+)\b"#)

    /// Each reference's range in `text` (UTF-16, as NSString counts) and where it goes. A bare "#123" needs `repo`
    /// ("owner/name"); "name#123" takes `repo`'s owner. `linearApp` opens issues in Linear's app instead of the web.
    public static func find(in text: String, repo: String?, linearApp: Bool) -> [(range: NSRange, url: URL)] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            if match.range(at: 1).location != NSNotFound {
                guard !notIssues.contains(ns.substring(with: match.range(at: 1))) else { return nil }
                let id = ns.substring(with: match.range)
                let url = linearApp ? "linear://\(linearWorkspace)/issue/\(id)" : "https://linear.app/\(linearWorkspace)/issue/\(id)"
                return URL(string: url).map { (match.range, $0) }
            }
            let number = ns.substring(with: match.range(at: 3))
            let named = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
            let target: String?
            switch named {
            case nil: target = repo
            case let name? where name.contains("/"): target = name
            case let name?: target = repo.map { $0.split(separator: "/")[0] + "/" + name }
            }
            guard let target else { return nil }
            return URL(string: "https://github.com/\(target)/pull/\(number)").map { (match.range, $0) }
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
