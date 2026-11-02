import Foundation

/// Blocking Unix-domain socket with newline-delimited JSON. Used by the app (listen) and the CLI (connect).
/// Lines of JSON to and from zerod, read blocking on a thread of their own: a Unix socket on the Mac, the tunnel on
/// the phone.
public protocol LineConnection: AnyObject {
    func write(line: String) throws
    /// The next line; nil once the connection has ended.
    func readLine() -> String?
    func shutdown()
    func close()
}

public final class UnixSocket: LineConnection {
    public let fd: Int32
    private var buffer = Data()
    private var closed = false

    private init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    private static func fail(_ what: String) -> Failure {
        Failure(description: "\(what): \(String(cString: strerror(errno)))")
    }

    private static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    public static func listen(path: String) throws -> UnixSocket {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw fail("socket") }
        guard withAddress(path, { Darwin.bind(fd, $0, $1) }) == 0 else { Darwin.close(fd); throw fail("bind \(path)") }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { Darwin.close(fd); throw fail("listen") }
        return UnixSocket(fd: fd)
    }

    public static func connect(path: String) throws -> UnixSocket {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw fail("socket") }
        guard withAddress(path, { Darwin.connect(fd, $0, $1) }) == 0 else { Darwin.close(fd); throw fail("connect \(path)") }
        return UnixSocket(fd: fd)
    }

    public func accept() throws -> UnixSocket {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { throw UnixSocket.fail("accept") }
        return UnixSocket(fd: client)
    }

    /// Next line without its newline; nil at end of stream.
    public func readLine() -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return String(decoding: buffer, as: UTF8.self)
            }
            buffer.append(chunk, count: n)
        }
    }

    /// Bytes read past the last line, for a connection that switches from lines to a raw stream.
    public func takeBuffered() -> Data {
        defer { buffer.removeAll() }
        return buffer
    }

    public func write(line: String) throws {
        let bytes = Array((line + "\n").utf8)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { throw UnixSocket.fail("write") }
                offset += n
            }
        }
    }

    public func send<T: Encodable>(_ value: T) throws {
        try write(line: String(decoding: try jsonEncoder.encode(value), as: UTF8.self))
    }

    public func receive<T: Decodable>(_ type: T.Type) -> T? {
        guard let line = readLine() else { return nil }
        return try? jsonDecoder.decode(T.self, from: Data(line.utf8))
    }

    /// Wakes a thread blocked in readLine on this socket.
    public func shutdown() { Darwin.shutdown(fd, SHUT_RDWR) }

    public func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}
