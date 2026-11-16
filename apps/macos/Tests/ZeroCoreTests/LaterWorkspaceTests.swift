import Foundation
import Testing
@testable import ZeroCore

private func item(_ workspace: String?) throws -> ZerodLink.LaterItem {
    var fields: [String: Any] = [
        "id": "l1", "note": "n", "links": [], "files": [], "created": 0, "updated": 0, "done": false, "version": 1,
        "versions": [], "link": "zero://later/l1",
    ]
    if let workspace { fields["workspace"] = workspace }
    return try JSONDecoder().decode(ZerodLink.LaterItem.self, from: JSONSerialization.data(withJSONObject: fields))
}

/// Later's items by workspace, on the Mac and the phone alike: an item keeps its task's workspace; one with none, or
/// one since deleted, is Zero's, as tasks are.
@Test func aLaterItemIsInItsTasksWorkspaceElseZeros() throws {
    let known: Set<String> = ["zero", "work"]
    #expect(try item("work").workspace(among: known) == "work")
    #expect(try item(nil).workspace(among: known) == "zero")
    #expect(try item("gone").workspace(among: known) == "zero")
}
