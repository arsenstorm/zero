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
              {"name": "Zero.zip", "browser_download_url": "https://example.com/Zero.zip"}]}
            """
        let release = try JSONDecoder().decode(Release.self, from: Data(json.utf8))
        XCTAssertEqual(release.version, "0.2")
        XCTAssertEqual(release.app?.name, "Zero.zip")
    }
}
