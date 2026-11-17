import XCTest
@testable import ZeroCore

final class UpdatesTests: XCTestCase {
    func testVersionsCompareByNumberNotText() {
        XCTAssertTrue(Updates.newer("0.10", than: "0.9"))
        XCTAssertTrue(Updates.newer("1.0", than: "0.9.9"))
        XCTAssertTrue(Updates.newer("0.2.1", than: "0.2"))
        XCTAssertFalse(Updates.newer("0.2", than: "0.2"))
        XCTAssertFalse(Updates.newer("0.2", than: "0.2.0"))
        XCTAssertFalse(Updates.newer("0.1", than: "0.2"))
    }

    func testAReleaseAsGitHubGivesIt() throws {
        let json = """
            {"tag_name": "v0.2", "body": "Fixes", "assets": [
              {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
              {"name": "Zero.dmg", "browser_download_url": "https://example.com/Zero.dmg"},
              {"name": "Zero.dmg.sha256", "browser_download_url": "https://example.com/Zero.dmg.sha256"},
              {"name": "Zero.slim", "browser_download_url": "https://example.com/Zero.slim"},
              {"name": "Zero.zip", "browser_download_url": "https://example.com/Zero.zip"}]}
            """
        let release = try JSONDecoder().decode(Release.self, from: Data(json.utf8))
        XCTAssertEqual(release.version, "0.2")
        XCTAssertEqual(release.app?.name, "Zero.zip")
        XCTAssertEqual(release.slim?.name, "Zero.slim")
    }

    /// The installed Zero's Chromium goes into a slim app, and only into one that has a place for it and none of its own.
    func testTheInstalledChromiumGoesIntoASlimApp() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("graft-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let (installed, slim) = (root.appendingPathComponent("Installed.app"), root.appendingPathComponent("Slim.app"))
        let chromium = installed.appendingPathComponent(Updates.chromium)
        try files.createDirectory(at: chromium.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try Data("cef".utf8).write(to: chromium.appendingPathComponent("Chromium Embedded Framework"))
        XCTAssertFalse(Updates.graft(from: installed, into: slim), "no Zero Browser in it")
        try files.createDirectory(
            at: slim.appendingPathComponent(Updates.chromium).deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(Updates.graft(from: installed, into: slim))
        let copied = slim.appendingPathComponent(Updates.chromium).appendingPathComponent("Chromium Embedded Framework")
        XCTAssertEqual(try Data(contentsOf: copied), Data("cef".utf8))
        XCTAssertFalse(Updates.graft(from: installed, into: slim), "it has one already")
        XCTAssertFalse(Updates.graft(from: root.appendingPathComponent("Old.app"), into: root), "no Chromium installed")
    }
}
