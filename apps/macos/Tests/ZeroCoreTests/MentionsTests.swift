import Foundation
import Testing
@testable import ZeroCore

@Test func filesMatchByNameThenPath() {
    let files = ["Sources/ZeroApp/Inbox.swift", "Sources/ZeroCore/Store.swift", "README.md", "Tests/InboxTests.swift"]
    #expect(
        ProjectFiles.match("inbox", in: files) == ["Tests/InboxTests.swift", "Sources/ZeroApp/Inbox.swift"].sorted { $0.count < $1.count })
    #expect(ProjectFiles.match("zcst", in: files) == ["Sources/ZeroCore/Store.swift"])
}

@Test func aSkillsFrontmatterIsRead() {
    #expect(
        ClaudeCommands.frontmatter("---\nname: commit\ndescription: \"Write commits.\"\n---\nbody") == [
            "name": "commit", "description": "Write commits.",
        ])
}

@Test func frontmatterFoldsBlockScalars() {
    #expect(
        ClaudeCommands.frontmatter("---\nname: x\ndescription: >-\n  Design APIs\n  that compose.\n---\n")["description"]
            == "Design APIs that compose.")
}

@Test func aSlashWordIsASkillOnlyWhenOneHasThatName() {
    let there: Set = ["/tmp/zero-briefs/bar-shape-study.md", "/Users/me/code", "/Users/me/code/notes.md", "/tmp"]
    let find = { (text: String, skills: Set<String>) in
        SlashWord.find(in: text, skills: skills, cwd: "/Users/me/code", home: "/Users/me", exists: there.contains)
            .map { ((text as NSString).substring(with: $0.range), $0.word) }
    }
    let words = find("Use /commit, then read /tmp/zero-briefs/bar-shape-study.md.", ["commit"])
    #expect(words.map(\.0) == ["/commit", "/tmp/zero-briefs/bar-shape-study.md"])
    #expect(words.map(\.1) == [.skill, .path("/tmp/zero-briefs/bar-shape-study.md")])
    // No such skill and no such path: plain words.
    #expect(find("/commitx and /nowhere/file.md", ["commit"]).isEmpty)
    // A path that is a skill's name too is the skill; a further slash makes it a path.
    #expect(find("/tmp", ["tmp"]).map(\.1) == [.skill])
    #expect(find("/tmp", []).map(\.1) == [.path("/tmp")])
    // ~/ and ./ resolved; inside a URL or another word, nothing.
    #expect(
        find("(~/code/notes.md) ./notes.md ../code", []).map(\.1) == [
            .path("/Users/me/code/notes.md"), .path("/Users/me/code/notes.md"), .path("/Users/me/code"),
        ])
    #expect(find("https://x.dev/tmp and a/tmp", []).isEmpty)
}
