import Foundation
import ZeroCore

@MainActor func labelCommand() async {
    guard let session = targetSession() else { fail("zero: label which session? (--session ID)") }
    // --where alone names where it runs and leaves its name and ticket be.
    if let place = flag("where") { await zerod { try await $0.place(session: session, place: place) } }
    if flag("where") == nil || !positional.isEmpty || flag("ticket") != nil {
        await zerod { try await $0.label(session: session, label: positional.isEmpty ? nil : positional.joined(separator: " "), ticket: flag("ticket")) }
    }
}

@MainActor func tableCommand() async {
    guard let session = targetSession() else { fail("zero: a table of which session? (--session ID)") }
    var title = positional.joined(separator: " ")
    var columns = flags["column"] ?? []
    var rows: [[String]] = (flags["row"] ?? []).map { $0.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
    if columns.isEmpty, let data = try? FileHandle.standardInput.readToEnd(), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        title = json["title"] as? String ?? title
        columns = json["columns"] as? [String] ?? []
        rows = (json["rows"] as? [[Any]] ?? []).map { $0.map { "\($0)" } }
    }
    guard !columns.isEmpty else { fail("zero: a table needs columns (--column NAME, or JSON on stdin)") }
    await zerod { try await $0.table(session: session, title: title, columns: columns, rows: rows) }
}

@MainActor func issueCommand() async {
    guard positional.count >= 2, let session = targetSession() else {
        fail("zero: which issue, and who has it? (zero issue TICKET you|working|waiting|parked|done [\"what it needs, where it stands, or why\"] [--session ID])")
    }
    let text = positional.dropFirst(2).joined(separator: " ")
    await zerod { try await $0.issue(session: session, ticket: positional[0], state: positional[1], text: text) }
}

@MainActor func attrCommand() async {
    guard let name = positional.first, let session = targetSession() else {
        fail("zero: which attribute, of which session? (zero attr NAME [VALUE] [--session ID])")
    }
    let value = positional.dropFirst().joined(separator: " ")
    await zerod { try await $0.attribute(session: session, name: name, value: value.isEmpty ? nil : value) }
}
