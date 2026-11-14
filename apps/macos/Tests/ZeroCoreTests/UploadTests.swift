import Foundation
import Testing
@testable import ZeroCore

/// The Mac's end of a phone's link, in one process: each line answered as Phones.swift answers an upload's. With
/// `drop`, the link ends at that many parts (that part and the ones after it never arrive), as a dropped link does.
private final class Mac: LineConnection, @unchecked Sendable {
    let folder: URL
    var drop: Int?
    private let lock = NSCondition()
    private var lines: [String] = []
    private var ended = false
    private(set) var parts = 0
    init(folder: URL, drop: Int? = nil) { self.folder = folder; self.drop = drop }

    func write(line: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { throw URLError(.networkConnectionLost) }
        let request = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        if request["op"] as? String == "uploadPart" || request["op"] as? String == "downloadPart" {
            parts += 1
            if let drop, parts >= drop { ended = true; lock.broadcast(); return }
        }
        let reply: [String: Any] =
            (request["op"] as? String == "downloadPart" ? ZerodLink.Download.answer(request) : ZerodLink.Upload.answer(request, in: folder))
            .map { ["id": request["id"] ?? 0, "ok": true, "result": $0] }
            ?? ["id": request["id"] ?? 0, "ok": false, "error": "refused"]
        lines.append(String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        lock.signal()
    }
    func readLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        while lines.isEmpty && !ended { lock.wait() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }
    func shutdown() { close() }
    func close() {
        lock.withLock {
            ended = true; lock.broadcast()
        }
    }
}

private func scratch() -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Test func aVideoGoesUpInPartsAndComesOutWhole() async throws {
    let folder = scratch()
    let video = folder.appendingPathComponent("in.mov")
    let bytes = Data((0..<(ZerodLink.Upload.part * 9 + 1234)).map { UInt8($0 % 251) })
    try bytes.write(to: video)
    let mac = Mac(folder: folder.appendingPathComponent("mac"))
    let link = ZerodLink(connection: mac)
    var seen: [Int] = []
    let path = try await ZerodLink.Upload.send(video, name: "video-1.mov", over: { link }) { seen.append($0) }
    #expect(path.hasSuffix("-video-1.mov"))
    #expect(FileManager.default.contents(atPath: path) == bytes)
    #expect(mac.parts == 10)
    #expect(seen.last == bytes.count)
    #expect(seen == seen.sorted())
}

@Test func aDroppedLinkSendsOnlyWhatDidntArriveOverTheNext() async throws {
    let folder = scratch()
    let video = folder.appendingPathComponent("in.mov")
    let bytes = Data((0..<(ZerodLink.Upload.part * 12)).map { UInt8($0 % 239) })
    try bytes.write(to: video)
    let macs = [Mac(folder: folder.appendingPathComponent("mac"), drop: 6), Mac(folder: folder.appendingPathComponent("mac"))]
    let links = macs.map { ZerodLink(connection: $0) }
    let used = Counter()
    let path = try await ZerodLink.Upload.send(video, name: "v.mov", over: { links[min(used.next(), 1)] }) { _ in }
    #expect(FileManager.default.contents(atPath: path) == bytes)
    // The first link took 5 parts before it went; the second, the other 7 (never all 12 again).
    #expect(macs[1].parts == 7)
}

@Test func partsOnlyNameAnUploadByItsId() {
    let folder = scratch()
    #expect(ZerodLink.Upload.answer(["op": "uploadPart", "upload": "../../x", "at": 0, "data": ""], in: folder) == nil)
    #expect(ZerodLink.Upload.answer(["op": "uploadDone", "upload": UUID().uuidString, "name": "v.mov", "size": 5], in: folder) == nil)
}

private final class Counter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()
    func next() -> Int {
        lock.withLock {
            defer { count += 1 }; return count
        }
    }
}

@Test func aVideoComesDownInPartsWhole() async throws {
    let folder = scratch()
    let video = folder.appendingPathComponent("on-the-mac.mp4")
    let bytes = Data((0..<(ZerodLink.Download.part * 5 + 77)).map { UInt8($0 % 233) })
    try bytes.write(to: video)
    let mac = Mac(folder: folder)
    let link = ZerodLink(connection: mac)
    let into = folder.appendingPathComponent("phone.mp4")
    var seen: [Double] = []
    try await ZerodLink.Download.fetch(video.path, into: into, over: { link }) { seen.append($0) }
    #expect(FileManager.default.contents(atPath: into.path) == bytes)
    #expect(mac.parts == 6)
    #expect(seen.last == 1)
    #expect(seen == seen.sorted())
}

@Test func aDroppedLinkFetchesOnlyWhatDidntArriveOverTheNext() async throws {
    let folder = scratch()
    let video = folder.appendingPathComponent("on-the-mac.mov")
    let bytes = Data((0..<(ZerodLink.Download.part * 10)).map { UInt8($0 % 241) })
    try bytes.write(to: video)
    let macs = [Mac(folder: folder, drop: 4), Mac(folder: folder)]
    let links = macs.map { ZerodLink(connection: $0) }
    let used = Counter()
    let into = folder.appendingPathComponent("phone.mov")
    try await ZerodLink.Download.fetch(video.path, into: into, over: { links[min(used.next(), 1)] }) { _ in }
    #expect(FileManager.default.contents(atPath: into.path) == bytes)
    #expect(macs[1].parts < 10)
}

@Test func onlyVideosAreServed() throws {
    let folder = scratch()
    let secret = folder.appendingPathComponent("notes.txt")
    try Data("private".utf8).write(to: secret)
    #expect(ZerodLink.Download.answer(["op": "downloadPart", "path": secret.path, "at": 0]) == nil)
    #expect(ZerodLink.Download.answer(["op": "downloadPart", "path": folder.appendingPathComponent("gone.mp4").path, "at": 0]) == nil)
}
