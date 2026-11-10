import Foundation
import Testing
@testable import ZeroCore

@Test func claudeSessionsFindsByFirstPromptAndReadsTitle() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zero-sessions-\(UUID().uuidString)")
    ClaudeSessions.root = root
    let cwd = "/Users/x/proj.app"
    let folder = ClaudeSessions.folder(for: cwd)
    #expect(folder.lastPathComponent == "-Users-x-proj-app")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let a = folder.appendingPathComponent("aaaa.jsonl"), b = folder.appendingPathComponent("bbbb.jsonl")
    try #"{"type":"user","message":{"role":"user","content":"say \"hi\" please"}}"#.write(to: a, atomically: true, encoding: .utf8)
    try (#"{"type":"user","message":{"role":"user","content":"other"}}"# + "\n" + #"{"aiTitle":"Other task"}"#).write(
        to: b, atomically: true, encoding: .utf8)
    #expect(ClaudeSessions.find(prompt: "say \"hi\" please", cwd: cwd) == "aaaa")
    #expect(ClaudeSessions.find(prompt: "other", cwd: cwd) == "bbbb")
    #expect(ClaudeSessions.find(prompt: "missing", cwd: cwd) == nil)
    #expect(ClaudeSessions.title(of: "bbbb", cwd: cwd) == "Other task")
    #expect(ClaudeSessions.title(of: "aaaa", cwd: cwd) == nil)
}
