import XCTest
@testable import ZeroCore

final class HealthTests: XCTestCase {
    let app = "/Applications/Zero.app"
    let zerod = "/Applications/Zero.app/Contents/MacOS/zerod"

    func selfCheck(
        parent: (Int, String?) = (501, "/Applications/Zero.app/Contents/MacOS/Zero"), quarantined: Bool = false, open: Int = 40,
        exe: String? = "/Applications/Zero.app/Contents/MacOS/zerod", replaced: Bool = false
    ) -> ZerodSelfCheck {
        ZerodSelfCheck(
            pid: 900, parent: .init(pid: parent.0, path: parent.1), quarantined: quarantined,
            descriptors: .init(open: open, limit: 10240), exe: exe, replaced: replaced)
    }

    func judge(_ zerod: ZerodSelfCheck?, cli: Bool = true, reports: [CrashReport] = [], hang: AppHang? = nil, seen: Date = .distantPast)
        -> [Health.Kind: HealthCheck]
    {
        Dictionary(
            uniqueKeysWithValues: Health.judge(
                zerod, cliAnswers: cli, app: app, appZerod: self.zerod, reports: reports, hang: hang, seen: seen
            ).map { ($0.id, $0) })
    }

    func testAllWellIsAllOk() {
        let checks = judge(selfCheck())
        XCTAssertEqual(checks.count, Health.Kind.allCases.count)
        XCTAssertTrue(checks.values.allSatisfy { $0.state == .ok }, "\(checks.values.filter { $0.state != .ok })")
    }

    func testStartedByLaunchdIsFine() {
        XCTAssertEqual(judge(selfCheck(parent: (1, "/sbin/launchd")))[.zerod]?.state, .ok)
    }

    func testStartedUnderABrowserIsNamedAndRestartedCleanly() {
        let check = judge(selfCheck(parent: (77, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")))[.zerod]!
        XCTAssertEqual(check.state, .failing)
        XCTAssertTrue(check.detail.contains("Google Chrome"), check.detail)
        XCTAssertEqual(check.fix, .restartZerod)
    }

    func testStartedFromAShellIsAWarning() {
        let check = judge(selfCheck(parent: (77, "/bin/zsh")))[.zerod]!
        XCTAssertEqual(check.state, .warning)
        XCTAssertTrue(check.detail.contains("zsh"), check.detail)
    }

    func testNotAnsweringOffersToStartIt() {
        let checks = judge(nil)
        XCTAssertEqual(checks[.zerod]?.state, .failing)
        XCTAssertEqual(checks[.zerod]?.fix, .startZerod)
        // What zerod would have said is unknown, not failing on its own account.
        XCTAssertEqual(checks[.quarantine]?.state, .unknown)
    }

    func testADeadCliSocketIsFailing() {
        let check = judge(selfCheck(), cli: false)[.cli]!
        XCTAssertEqual(check.state, .failing)
        XCTAssertEqual(check.fix, .restartZerod)
    }

    func testQuarantineIsFailing() {
        XCTAssertEqual(judge(selfCheck(quarantined: true))[.quarantine]?.state, .failing)
    }

    func testDescriptorsNearTheLimit() {
        XCTAssertEqual(judge(selfCheck(open: 8500))[.descriptors]?.state, .warning)
        XCTAssertEqual(judge(selfCheck(open: 9900))[.descriptors]?.state, .failing)
    }

    func testAnOlderBuildOrAnotherAppsZerod() {
        XCTAssertEqual(judge(selfCheck(replaced: true))[.build]?.state, .warning)
        let other = judge(selfCheck(exe: "/Users/me/zero/target/debug/zerod"))[.build]!
        XCTAssertEqual(other.state, .warning)
        XCTAssertTrue(other.detail.contains("target/debug/zerod"), other.detail)
    }

    func testOnlyReportsSinceSeenCountAndTheLatestIsNamed() {
        let old = CrashReport(url: URL(fileURLWithPath: "/r/Zero-2026-11-01-100000.ips"), date: Date(timeIntervalSince1970: 100))
        let new = CrashReport(url: URL(fileURLWithPath: "/r/zerod-2026-11-11-100000.ips"), date: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(judge(selfCheck(), reports: [old], seen: Date(timeIntervalSince1970: 200))[.crashes]?.state, .ok)
        let check = judge(selfCheck(), reports: [old, new], seen: Date(timeIntervalSince1970: 200))[.crashes]!
        XCTAssertEqual(check.state, .warning)
        XCTAssertTrue(check.detail.contains("zerod"), check.detail)
        XCTAssertEqual(check.fix, .openReport(new.url))
    }

    func testAFrozenWindowSinceSeen() {
        let hang = AppHang(at: Date(timeIntervalSince1970: 300), seconds: 12)
        XCTAssertEqual(judge(selfCheck(), hang: hang, seen: Date(timeIntervalSince1970: 200))[.app]?.state, .warning)
        XCTAssertEqual(judge(selfCheck(), hang: hang, seen: Date(timeIntervalSince1970: 400))[.app]?.state, .ok)
    }

    func testReportsAreZerosOwnOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("health-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in [
            "Zero-2026-11-11-142542.ips", "zerod-2026-11-11-142542.ips", "Zero_2026-11-11-142542.hang", "Zero-full-2026-11-11.ips",
            "ZeroX-2026-11-11-142542.ips", "Safari-2026-11-11-142542.ips", "Zero-2026-11-11-142542.txt",
        ] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        let names = Set(Health.reports(in: dir).map(\.url.lastPathComponent))
        XCTAssertEqual(names, ["Zero-2026-11-11-142542.ips", "zerod-2026-11-11-142542.ips", "Zero_2026-11-11-142542.hang"])
    }
}
