import Foundation
import ZeroCore

/// Asks over files. Every folder matched by a pattern in Settings is a drop: Zero keeps the client script in it,
/// reads `asks/<id>.json` as they appear, and writes `answers/<id>.json` when the ask is final. Anything that
/// can write to a folder the Mac sees reaches Arsen this way, with nothing installed and no credential shared.
@MainActor
final class DropWatcher {
    private let store: Store
    private var patterns: [String] = []
    private var ingested: Set<String> = []       // "<drop>/<id>"
    private var origin: [String: URL] = [:]      // ask id → drop folder
    private var timer: Timer?

    init(store: Store) { self.store = store }

    func start(patterns: [String]) {
        self.patterns = patterns
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        scan()
    }

    /// Current drop folders, for Settings to show.
    var folders: [URL] { patterns.flatMap(expand) }

    /// Expands a pattern to existing folders. When the last component is a plain name (no glob characters) under
    /// a matched parent, it is created: "~/worktrees/*/*/*/.zero" then makes a `.zero` drop inside every app
    /// folder the sync carries, so the other side finds the client without anyone creating it by hand.
    private func expand(_ pattern: String) -> [URL] {
        let path = (pattern as NSString).expandingTildeInPath
        let leaf = (path as NSString).lastPathComponent
        let leafIsPlain = leaf.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[{")) == nil
        let parents = leafIsPlain ? globDirectories((path as NSString).deletingLastPathComponent) : []
        for parent in parents {
            try? FileManager.default.createDirectory(at: parent.appendingPathComponent(leaf), withIntermediateDirectories: false)
        }
        return globDirectories(path)
    }

    private func globDirectories(_ path: String) -> [URL] {
        var glob = glob_t()
        defer { globfree(&glob) }
        guard Darwin.glob(path, GLOB_TILDE | GLOB_BRACE, nil, &glob) == 0 else { return [] }
        return (0..<Int(glob.gl_matchc)).compactMap { i in
            guard let raw = glob.gl_pathv[i] else { return nil }
            var isDirectory: ObjCBool = false
            let url = URL(fileURLWithPath: String(cString: raw))
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
        }
    }

    private func scan() {
        for drop in folders {
            prepare(drop)
            let asks = drop.appendingPathComponent("asks")
            guard let files = try? FileManager.default.contentsOfDirectory(at: asks, includingPropertiesForKeys: nil) else { continue }
            // `zero withdraw` from a drop: "<id>.withdraw", holding the reason.
            for file in files where file.pathExtension == "withdraw" {
                let reason = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                store.withdraw(file.deletingPathExtension().lastPathComponent, reason: reason?.isEmpty == false ? reason : nil)
                try? FileManager.default.removeItem(at: file)
            }
            for file in files where file.pathExtension == "json" {
                let key = drop.path + "/" + file.lastPathComponent
                guard !ingested.contains(key) else { continue }
                guard let data = try? Data(contentsOf: file), let incoming = try? jsonDecoder.decode(Ask.self, from: data) else { continue }
                ingested.insert(key)
                let ask = store.create(incoming, keepID: true)
                if ask.kind == .note {
                    try? FileManager.default.removeItem(at: file) // nobody waits for a note's answer
                } else {
                    origin[ask.id] = drop
                }
            }
            sweep(drop.appendingPathComponent("answers"))
        }
    }

    /// Answers nobody collected within a day (an `--async` ask whose agent never came back) are removed.
    private func sweep(_ answers: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: answers, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if modified < Date().addingTimeInterval(-86400) { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Makes the drop usable: the two folders, the client binaries from the app bundle, and the `zero` shim.
    /// Binaries are copied only when their size differs, so the sync is not asked to move them every second.
    private func prepare(_ drop: URL) {
        let fm = FileManager.default
        for name in ["asks", "answers"] { try? fm.createDirectory(at: drop.appendingPathComponent(name), withIntermediateDirectories: true) }
        for name in DropClient.binaries {
            guard let source = Bundle.main.url(forResource: name, withExtension: nil) else { continue }
            let target = drop.appendingPathComponent(name)
            let sourceSize = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int) ?? -1
            let targetSize = (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int) ?? -2
            guard sourceSize != targetSize else { continue }
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: source, to: target)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        let shim = drop.appendingPathComponent("zero")
        if (try? String(contentsOf: shim, encoding: .utf8)) != DropClient.shim {
            try? DropClient.shim.write(to: shim, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        }
    }

    /// Called on every store change: a final ask that came from a drop goes back as its answer file.
    func changed(_ ask: Ask) {
        guard ask.state.isFinal, origin[ask.id] != nil else { return }
        deliver(ask)
    }

    private func deliver(_ ask: Ask) {
        guard let drop = origin.removeValue(forKey: ask.id), let data = try? jsonEncoder.encode(ask) else { return }
        let answer = drop.appendingPathComponent("answers/\(ask.id).json")
        let tmp = drop.appendingPathComponent("answers/\(ask.id).json.tmp")
        try? data.write(to: tmp)
        try? FileManager.default.moveItem(at: tmp, to: answer)
        try? FileManager.default.removeItem(at: drop.appendingPathComponent("asks/\(ask.id).json"))
    }
}
