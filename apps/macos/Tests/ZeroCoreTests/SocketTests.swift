import Foundation
import Testing
@testable import ZeroCore

/// A long conversation's earlier items come as one line of megabytes: read in one pass, not searched again from its
/// start with every chunk (that took tens of seconds and froze the conversation).
@Test func aLineOfMegabytesIsReadInOnePassAndTheLinesAroundItStayWhole() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("zero-socket-\(getpid()).sock").path
    unlink(path)
    let server = try UnixSocket.listen(path: path)
    defer { server.close(); unlink(path) }
    let client = try UnixSocket.connect(path: path)
    let peer = try server.accept()
    let long = String(repeating: "x", count: 6_000_000)
    let writer = Thread {
        // Small pieces, as a busy socket delivers them.
        let bytes = Array(("a\n" + long + "\nb\nc").utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].prefix(4096).withUnsafeBytes { Darwin.write(peer.fd, $0.baseAddress!, $0.count) }
            if n <= 0 { break }
            offset += n
        }
        peer.shutdown()
    }
    writer.start()
    let started = Date()
    #expect(client.readLine() == "a")
    #expect(client.readLine()?.count == long.count)
    #expect(client.readLine() == "b")
    #expect(client.readLine() == "c", "the last, unended line at the stream's end")
    #expect(client.readLine() == nil)
    #expect(Date().timeIntervalSince(started) < 2, "one pass over the bytes")
}
