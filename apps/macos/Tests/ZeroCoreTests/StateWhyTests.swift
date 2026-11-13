import Foundation
import Testing
@testable import ZeroCore

private func row(
    _ state: String, asks: [String] = [], workerAsks: [String] = [], issues: [(String, String, String)] = [], needs: String? = nil
) -> BoardRow {
    let ask = { (id: String, title: String) in #"{"id":"\#(id)","title":"\#(title)"}"# }
    let own = asks.map { ask($0, $0) }, theirs = workerAsks.map { ask($0, $0) }
    let json = """
        {"session":"1","task":"T","workspace":"zero","place":"p","online":true,"state":"\(state)","workers":1,"asks":[\((own + theirs).joined(separator: ","))],
         "needs":\(needs.map { "\"\($0)\"" } ?? "null"),
         "team":[{"session":"w","state":"needsYou","place":"w","asks":[\(theirs.joined(separator: ","))]}],
         "issues":[\(issues.map { #"{"ticket":"\#($0.0)","state":"\#($0.1)","text":"\#($0.2)","since":0}"# }.joined(separator: ","))]}
        """
    return try! JSONDecoder().decode(BoardRow.self, from: Data(json.utf8))
}

@Test func theStateIconSaysWhy() {
    let over = [("U-1", "over", "merge on your go"), ("U-2", "over", "review"), ("U-3", "over", "deploy")]
    #expect(row("handed", issues: over).why == "U-1: merge on your go · 3 rows over to you")
    #expect(row("handed", needs: "merge #12").why == "merge #12")
    #expect(row("needsYou", asks: ["Ship it?"], issues: [("U-4", "you", "which fix?")]).why == "Ask: Ship it?")
    #expect(row("needsYou", workerAsks: ["Which DB?"], issues: [("U-4", "you", "which fix?")]).why == "U-4: which fix?")
    #expect(row("needsYou", workerAsks: ["Which DB?"]).why == "A worker's ask: Which DB?")
    #expect(row("working").why == "Working")
}
