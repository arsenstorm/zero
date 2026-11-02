import CryptoKit
import Foundation

/// Zero's tunnel between a phone and the Mac, through a relay that passes frames it can't read (apps/relay): pairing
/// by a code in a QR, then Noise (Noise.swift) end to end, then zerod's own lines, as the Mac app sends them on the
/// socket. The Mac's side is `Host` and a `Link` per phone; the phone's is `Phone`. The relay's WebSocket and zerod's
/// socket are the apps'.
public enum Tunnel {
    public enum Failure: Error, Equatable { case wrongMac, notReady }

    /// What the QR code says: where the relay is, which Mac, its key, and a one-time code to pair with.
    public struct Invite: Codable, Equatable, Sendable {
        public var relay: String
        public var mac: String
        public var key: Data
        public var code: String

        /// As a link: zero://pair?relay=…&mac=…&key=…&code=…
        public var link: String {
            var parts = URLComponents()
            parts.scheme = "zero"; parts.host = "pair"
            parts.queryItems = [.init(name: "relay", value: relay), .init(name: "mac", value: mac),
                                .init(name: "key", value: key.base64EncodedString()), .init(name: "code", value: code)]
            return parts.string ?? ""
        }

        public init(relay: String, mac: String, key: Data, code: String) { self.relay = relay; self.mac = mac; self.key = key; self.code = code }

        public init?(link: String) {
            guard let parts = URLComponents(string: link), parts.scheme == "zero", parts.host == "pair" else { return nil }
            let value = { (name: String) in parts.queryItems?.first { $0.name == name }?.value }
            guard let relay = value("relay"), let mac = value("mac"), let key = value("key").flatMap({ Data(base64Encoded: $0) }), let code = value("code") else { return nil }
            self.init(relay: relay, mac: mac, key: key, code: code)
        }
    }

    /// A paired phone: its name and its public key, which is who it is.
    public struct Device: Codable, Equatable, Identifiable, Sendable {
        public var id: String { Data(SHA256.hash(data: key)).prefix(8).map { String(format: "%02x", $0) }.joined() }
        public var name: String
        public var key: Data
        public var added: Date
        /// Where Apple's push reaches it, once it has said.
        public var push: String?
    }

    /// What a phone says in the handshake's last message, encrypted: its name, and the code when it's pairing.
    struct Hello: Codable { var name: String; var code: String? }

    /// How long a pairing code is good for.
    public static let codeLife: TimeInterval = 5 * 60

    /// The Mac's side: its key, the phones paired with it, the codes on offer.
    public final class Host {
        let key: Curve25519.KeyAgreement.PrivateKey
        public private(set) var devices: [Device]
        var codes: [String: Date] = [:]
        /// Told the devices whenever they change, to keep them.
        public var onChange: (([Device]) -> Void)?

        public init(key: Curve25519.KeyAgreement.PrivateKey, devices: [Device] = []) {
            self.key = key
            self.devices = devices
        }

        public var publicKey: Data { key.publicKey.rawRepresentation }

        /// A new code, good once for `codeLife`, in an invite for the QR code.
        public func invite(relay: String, mac: String, now: Date = Date()) -> Invite {
            codes = codes.filter { $0.value > now }
            let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
            codes[code] = now + Tunnel.codeLife
            return Invite(relay: relay, mac: mac, key: publicKey, code: code)
        }

        public func link() -> Link { Link(host: self) }

        /// A note only `device` can read.
        public func seal(_ note: Data, for device: Device) throws -> Data { try Tunnel.seal(note, from: key, to: device.key) }

        public func remove(_ id: String) {
            devices.removeAll { $0.id == id }
            onChange?(devices)
        }

        /// The phone's token for Apple's push.
        public func setPush(_ token: String, for id: String) {
            guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].push != token else { return }
            devices[index].push = token
            onChange?(devices)
        }

        /// The phone with this key: known already, or paired now with a code on offer (spent by it).
        func admit(_ key: Data, _ hello: Hello, now: Date) -> Device? {
            if let known = devices.first(where: { $0.key == key }) { return known }
            guard let code = hello.code, let until = codes[code], until > now else { return nil }
            codes[code] = nil
            let device = Device(name: hello.name, key: key, added: now)
            devices.append(device)
            onChange?(devices)
            return device
        }
    }

    /// One phone's connection, on the Mac: the handshake, then its lines.
    public struct Link {
        public enum Event { case send(Data), ready(Device), refused(String), lines([Data]) }
        let host: Host
        var handshake: Noise.Handshake
        var transport: Noise.Transport?
        var joiner = Noise.Joiner()
        public private(set) var device: Device?

        init(host: Host) {
            self.host = host
            handshake = Noise.Handshake(initiator: false, key: host.key)
        }

        /// A frame from the relay.
        public mutating func receive(_ frame: Data, now: Date = Date()) throws -> Event {
            if var transport {
                defer { self.transport = transport }
                return .lines(try joiner.add(frame, with: &transport.receive).map { [$0] } ?? [])
            }
            if handshake.step == 0 {
                // The phone's first message: answered with the Mac's.
                _ = try handshake.read(frame)
                return .send(try handshake.write())
            }
            let payload = try handshake.read(frame)
            guard let key = handshake.remote, let hello = try? JSONDecoder().decode(Hello.self, from: payload) else { return .refused("No hello") }
            guard let device = host.admit(key, hello, now: now) else { return .refused("Not paired") }
            transport = try handshake.split()
            self.device = device
            return .ready(device)
        }

        /// A line for the phone, as the frames to send.
        public mutating func send(_ line: Data) throws -> [Data] {
            guard var transport else { throw Failure.notReady }
            defer { self.transport = transport }
            return try Noise.pieces(of: line, with: &transport.send)
        }
    }

    /// The phone's side: it starts the handshake, checks the Mac is the one it scanned, says who it is.
    public struct Phone {
        public let key: Curve25519.KeyAgreement.PrivateKey
        let mac: Data
        let hello: Hello
        var handshake: Noise.Handshake
        var transport: Noise.Transport?
        var joiner = Noise.Joiner()

        /// Pairing, with the invite's code.
        public init(key: Curve25519.KeyAgreement.PrivateKey, invite: Invite, name: String) {
            self.init(key: key, mac: invite.key, hello: Hello(name: name, code: invite.code))
        }

        /// Paired already: the Mac's key, kept from the invite.
        public init(key: Curve25519.KeyAgreement.PrivateKey, mac: Data, name: String) {
            self.init(key: key, mac: mac, hello: Hello(name: name, code: nil))
        }

        init(key: Curve25519.KeyAgreement.PrivateKey, mac: Data, hello: Hello) {
            self.key = key; self.mac = mac; self.hello = hello
            handshake = Noise.Handshake(initiator: true, key: key)
        }

        public var ready: Bool { transport != nil }

        public mutating func start() throws -> Data { try handshake.write() }

        /// The Mac's answer to the first message: gives the last, or throws if the Mac isn't the one paired with.
        public mutating func receive(_ frame: Data) throws -> [Data] {
            _ = try handshake.read(frame)
            guard handshake.remote == mac else { throw Failure.wrongMac }
            let last = try handshake.write(try JSONEncoder().encode(hello))
            transport = try handshake.split()
            return [last]
        }

        public mutating func send(_ line: Data) throws -> [Data] {
            guard var transport else { throw Failure.notReady }
            defer { self.transport = transport }
            return try Noise.pieces(of: line, with: &transport.send)
        }

        /// A frame from the Mac: the lines it completes.
        public mutating func lines(_ frame: Data) throws -> [Data] {
            guard var transport else { throw Failure.notReady }
            defer { self.transport = transport }
            return try joiner.add(frame, with: &transport.receive).map { [$0] } ?? []
        }
    }

    /// A note for one phone that only it can read (a push's words, through Apple): sealed with the key the Mac's and
    /// the phone's static keys agree on, a fresh nonce each time.
    public static func seal(_ plain: Data, from mine: Curve25519.KeyAgreement.PrivateKey, to theirs: Data) throws -> Data {
        try ChaChaPoly.seal(plain, using: noteKey(mine, theirs)).combined
    }

    public static func open(_ sealed: Data, with mine: Curve25519.KeyAgreement.PrivateKey, from theirs: Data) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: noteKey(mine, theirs))
    }

    static func noteKey(_ mine: Curve25519.KeyAgreement.PrivateKey, _ theirs: Data) throws -> SymmetricKey {
        try mine.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirs))
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("zero note".utf8), sharedInfo: Data(), outputByteCount: 32)
    }

    /// What needs the Mac in front of you: setting up Chrome, a provider's own terminal, pairing another phone.
    public static let macOnly: Set<String> = ["browserAttach", "browserAnswer", "browserSetup", "openTerminal", "closeTerminal"]

    /// A phone's request line: passed on to zerod, or (a Mac-only op) answered here with an error.
    public static func screen(_ line: Data) -> (pass: Data?, reply: Data?) {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let op = request["op"] as? String, macOnly.contains(op) else {
            return (line, nil)
        }
        let reply: [String: Any] = ["id": request["id"] ?? NSNull(), "ok": false, "error": "Only on the Mac: \(op)"]
        return (nil, try? JSONSerialization.data(withJSONObject: reply))
    }
}
