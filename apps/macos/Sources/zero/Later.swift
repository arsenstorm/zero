import Foundation
import ZeroCore

@MainActor func laterCommand() async {
    let sub = positional.first ?? "list"
    let rest = Array(positional.dropFirst())
    switch sub {
    case "save":
        let note = rest.joined(separator: " ")
        guard !note.isEmpty else { usage() }
        let item = await later("save", ["note": note, "artifact": artifact() ?? "", "links": flags["link"] ?? [], "files": paths("attach"), "asked": flag("asked") != nil]) as? [String: Any] ?? [:]
        print("zero: saved for later as \(item["link"] as? String ?? "?")")
    case "edit", "done", "open":
        guard let id = rest.first else { usage() }
        var args: [String: Any] = ["item": id, "links": flags["link"] ?? [], "files": paths("attach")]
        if let note = flag("note") { args["note"] = note }
        if let text = artifact() { args["artifact"] = text }
        if sub != "edit" { args["done"] = sub == "done" }
        let item = await later("edit", args) as? [String: Any] ?? [:]
        print("zero: \(item["link"] as? String ?? id) is at version \(item["version"] as? Int ?? 1)" + (item["done"] as? Bool == true ? ", done" : ""))
    case "view":
        guard let id = rest.first else { usage() }
        var args: [String: Any] = ["item": id]
        if let version = flag("version").flatMap(Int.init) { args["version"] = version }
        show(await later("view", args) as? [String: Any] ?? [:])
    case "delete":
        guard let id = rest.first else { usage() }
        _ = await later("delete", ["item": id])
        print("zero: deleted \(id)")
    case "list":
        let items = await later("list", ["query": rest.joined(separator: " ")]) as? [[String: Any]] ?? []
        if items.isEmpty { print("zero: nothing saved for later") }
        for item in items {
            let done = item["done"] as? Bool == true ? "done  " : ""
            print("\(item["id"] as? String ?? "?")  \(done)\(item["note"] as? String ?? "")" + ((item["task"] as? String).map { "  (\($0))" } ?? ""))
        }
    default: usage()
    }
}

/// --file's text, "-" being stdin.
@MainActor private func artifact() -> String? {
    guard let file = flag("file") else { return nil }
    if file == "-" { return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { fail("zero: can't read \(file)") }
    return text
}

/// Paths as zerod (elsewhere) can find them.
@MainActor private func paths(_ key: String) -> [String] { (flags[key] ?? []).map { URL(fileURLWithPath: $0).standardizedFileURL.path } }

@MainActor private func later(_ tool: String, _ args: [String: Any]) async -> Any {
    let session = ProcessInfo.processInfo.environment["ZERO_SESSION"]
    return await zerod { try await $0.call("later", ["tool": tool, "args": args, "session": session]) }
}

private func show(_ item: [String: Any]) {
    let id = item["id"] as? String ?? "?"
    let done = item["done"] as? Bool == true ? "  (done)" : ""
    print("\(item["link"] as? String ?? id)  v\(item["version"] as? Int ?? 1)\(done)")
    print(item["note"] as? String ?? "")
    if let task = item["task"] as? String { print("From: \(task)" + ((item["from"] as? String).map { " (\($0))" } ?? "")) }
    for link in item["links"] as? [String] ?? [] { print("Link: \(link)") }
    for file in item["files"] as? [String] ?? [] { print("File: \(file)") }
    if let artifact = item["artifact"] as? String, !artifact.isEmpty { print("\n" + artifact) }
}
