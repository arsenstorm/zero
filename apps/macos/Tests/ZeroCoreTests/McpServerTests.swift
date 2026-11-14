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

/// Switched on or off for one workspace: one every workspace has, turned off in one, is given to the rest; given back
/// to the last, it's every workspace's again; off in its only one, it's off, kept as that workspace's.
@Test func anMcpServerIsSwitchedOnAndOffWorkspaceByWorkspace() throws {
    let json = #"{"id":"a","name":"CVE","command":"npx","args":[],"env":[],"headers":[],"workspaces":[],"enabled":true}"#
    var server = try JSONDecoder().decode(ZerodLink.McpServer.self, from: Data(json.utf8))
    let all = ["zero", "home", "work"]
    #expect(server.isOn(in: "home"))
    server.set(false, in: "home", all: all)
    #expect(server.workspaces == ["zero", "work"] && server.enabled)
    #expect(!server.isOn(in: "home") && server.isOn(in: "work"))
    server.set(true, in: "home", all: all)
    #expect(server.workspaces.isEmpty && server.enabled, "in all of them: every workspace's again")
    server.set(false, in: "zero", all: ["zero"])
    #expect(!server.enabled && server.workspaces == ["zero"] && !server.isOn(in: "zero"), "off in its only one")
    server.set(true, in: "home", all: all)
    #expect(server.enabled && server.workspaces == ["home"], "on again where switched on")
}

/// Every workspace's: none named, or all of them named. A new workspace starts with those on; made, it's given them,
/// and one that named all the others is every workspace's again.
@Test func anMcpServerInEveryWorkspaceIsOnInANewOne() throws {
    let json = #"{"id":"a","name":"CVE","command":"npx","args":[],"env":[],"headers":[],"workspaces":["zero","home"],"enabled":true}"#
    var server = try JSONDecoder().decode(ZerodLink.McpServer.self, from: Data(json.utf8))
    #expect(server.isShared(among: ["zero", "home"]) && !server.isShared(among: ["zero", "home", "work"]))
    #expect(server.standing(in: "", among: ["zero", "home"]), "on for a new one, before it's made")
    #expect(!server.standing(in: "work", among: ["zero", "home", "work"]), "off where it isn't given")
    server.set(true, in: "new", all: ["zero", "home", "new"])
    #expect(server.workspaces.isEmpty)
}
