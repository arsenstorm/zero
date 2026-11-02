import CryptoKit
import Foundation
import UIKit

/// zerod's lines through the tunnel: a WebSocket to the relay, the Noise handshake as the phone, then each line sealed
/// on the way out and opened on the way in. Read blocking, as ZerodLink reads a socket, on its own thread.
final class TunnelLines: LineConnection, @unchecked Sendable {
    private let lock = NSCondition()
    private var lines: [String] = []
    private var ended = false
    private var phone: Tunnel.Phone
    /// Lines written before the handshake is done: sent once it is.
    private var early: [String] = []
    private let socket: URLSessionWebSocketTask
    /// The handshake done and the first line in: the Mac knows this phone.
    var onHeard: (() -> Void)?

    init(pairing: Pairing) throws {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: pairing.key)
        let name = UIDevice.current.name
        phone = pairing.code.map { Tunnel.Phone(key: key, invite: Tunnel.Invite(relay: pairing.relay, mac: pairing.mac, key: pairing.macKey, code: $0), name: name) }
            ?? Tunnel.Phone(key: key, mac: pairing.macKey, name: name)
        let base = pairing.relay.replacingOccurrences(of: "https://", with: "wss://").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/phone/" + pairing.mac) else { throw URLError(.badURL) }
        socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()
        socket.send(.data(try phone.start())) { [weak self] error in if error != nil { self?.end() } }
        receive()
    }

    private func receive() {
        socket.receive { [weak self] result in
            guard let self else { return }
            guard case .success(.data(let frame)) = result else { return self.end() }
            do {
                self.lock.lock()
                if !self.phone.ready {
                    var frames = try self.phone.receive(frame)
                    for line in self.early { frames += try self.phone.send(Data(line.utf8)) }
                    self.early = []
                    self.lock.unlock()
                    frames.forEach { self.socket.send(.data($0)) { _ in } }
                } else {
                    let heard = try self.phone.lines(frame).compactMap { String(data: $0, encoding: .utf8) }
                    let first = self.lines.isEmpty && !heard.isEmpty
                    self.lines += heard
                    self.lock.signal()
                    self.lock.unlock()
                    if first { self.onHeard?() }
                }
                self.receive()
            } catch {
                self.lock.unlock()
                self.end()
            }
        }
    }

    func write(line: String) throws {
        lock.lock()
        guard phone.ready else { early.append(line); lock.unlock(); return }
        let frames: [Data]
        do { frames = try phone.send(Data(line.utf8)) } catch { lock.unlock(); throw error }
        lock.unlock()
        for frame in frames { socket.send(.data(frame)) { _ in } }
    }

    func readLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        while lines.isEmpty && !ended { lock.wait() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }

    private func end() {
        lock.lock()
        ended = true
        lock.broadcast()
        lock.unlock()
        socket.cancel(with: .goingAway, reason: nil)
    }

    func shutdown() { end() }
    func close() { end() }
}
