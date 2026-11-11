import Foundation
import Testing
@testable import ZeroCore

/// An MCP server as zerod sends it: started when first used or not ("lazy"), which an older zerod doesn't send, and
/// which goes back with every save (left out, saving it from Settings would turn it off).
@Test func anMcpServerKeepsWhetherItStartsWhenFirstUsed() throws {
    let old = #"{"id":"a","name":"CVE","command":"npx","args":[],"env":[],"headers":[],"workspaces":[],"enabled":true}"#
    #expect(try JSONDecoder().decode(ZerodLink.McpServer.self, from: Data(old.utf8)).lazy == false)
    let new = old.replacingOccurrences(of: "}", with: #","lazy":true}"#)
    let server = try JSONDecoder().decode(ZerodLink.McpServer.self, from: Data(new.utf8))
    #expect(server.lazy)
    let sent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(server)) as? [String: Any]
    #expect(sent?["lazy"] as? Bool == true)
}
