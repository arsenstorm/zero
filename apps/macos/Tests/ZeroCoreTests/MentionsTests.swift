import Testing
@testable import ZeroCore

@Test func filesMatchByNameThenPath() {
    let files = ["Sources/ZeroApp/Inbox.swift", "Sources/ZeroCore/Store.swift", "README.md", "Tests/InboxTests.swift"]
    #expect(
        ProjectFiles.match("inbox", in: files) == ["Tests/InboxTests.swift", "Sources/ZeroApp/Inbox.swift"].sorted { $0.count < $1.count })
    #expect(ProjectFiles.match("zcst", in: files) == ["Sources/ZeroCore/Store.swift"])
}

@Test func builtInsOpenTheScreenSkillsDoNot() {
    #expect(ClaudeCommands.isBuiltIn("/resume"))
    #expect(ClaudeCommands.isBuiltIn("/model claude-opus-5"))
    #expect(!ClaudeCommands.isBuiltIn("/commit tidy the log"))
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
