import CryptoKit
import Foundation

/// Noise_XX_25519_ChaChaPoly_SHA256 (noiseprotocol.org, revision 34): the tunnel's encryption between the phone and
/// the Mac, end to end through a relay that sees only ciphertext. XX: each side learns the other's static key during
/// the handshake (the phone checks the Mac's against the QR code it scanned; the Mac checks the phone's against its
/// paired devices). Everything here is CryptoKit's; this file is the protocol's bookkeeping, the same on both devices.
public enum Noise {
    public enum Failure: Error { case outOfTurn, short, badKey, decrypt, tooLong }

    /// What one direction's messages are sealed with after the handshake: a key, and a counter that is each message's
    /// nonce, so a message replayed or dropped fails to open.
    public struct Cipher: Sendable {
        var key: SymmetricKey?
        var n: UInt64 = 0

        func nonce() throws -> ChaChaPoly.Nonce {
            var bytes = Data(count: 4)
            withUnsafeBytes(of: n.littleEndian) { bytes.append(contentsOf: $0) }
            return try ChaChaPoly.Nonce(data: bytes)
        }

        mutating func encrypt(_ plain: Data, ad: Data) throws -> Data {
            guard let key else { return plain }
            let box = try ChaChaPoly.seal(plain, using: key, nonce: nonce(), authenticating: ad)
            n += 1
            // Indexed from zero: the box's ciphertext is a slice of its combined bytes.
            return Data(box.ciphertext) + box.tag
        }

        mutating func decrypt(_ sealed: Data, ad: Data) throws -> Data {
            guard let key else { return sealed }
            guard sealed.count >= 16 else { throw Failure.short }
            let box = try ChaChaPoly.SealedBox(nonce: nonce(), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            guard let plain = try? ChaChaPoly.open(box, using: key, authenticating: ad) else { throw Failure.decrypt }
            n += 1
            return plain
        }

        public mutating func seal(_ plain: Data) throws -> Data { try encrypt(plain, ad: Data()) }
        public mutating func open(_ sealed: Data) throws -> Data { try decrypt(sealed, ad: Data()) }
    }

    /// The two directions once the handshake is done.
    public struct Transport: Sendable {
        public var send: Cipher
        public var receive: Cipher
    }

    public struct Handshake {
        let initiator: Bool
        let key: Curve25519.KeyAgreement.PrivateKey
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
        /// The other side's static key, once it has been sent.
        public private(set) var remote: Data?
        var ck: Data
        var h: Data
        var cipher = Cipher()
        /// Messages written or read so far: XX has three, the initiator writing the first and third.
        var step = 0

        public init(initiator: Bool, key: Curve25519.KeyAgreement.PrivateKey, prologue: Data = Data()) {
            self.initiator = initiator
            self.key = key
            // The protocol's name is exactly 32 bytes: it is the hash's starting value as it is.
            h = Data("Noise_XX_25519_ChaChaPoly_SHA256".utf8)
            ck = h
            mixHash(prologue)
        }

        public var done: Bool { step == 3 }

        mutating func mixHash(_ data: Data) { h = Data(SHA256.hash(data: h + data)) }

        mutating func mixKey(_ ikm: Data) {
            let (ck, k) = hkdf(ck, ikm)
            self.ck = ck
            cipher = Cipher(key: SymmetricKey(data: k))
        }

        mutating func encryptAndHash(_ plain: Data) throws -> Data {
            let sealed = try cipher.encrypt(plain, ad: h)
            mixHash(sealed)
            return sealed
        }

        mutating func decryptAndHash(_ sealed: Data) throws -> Data {
            let plain = try cipher.decrypt(sealed, ad: h)
            mixHash(sealed)
            return plain
        }

        func dh(_ mine: Curve25519.KeyAgreement.PrivateKey, _ theirs: Curve25519.KeyAgreement.PublicKey) throws -> Data {
            try mine.sharedSecretFromKeyAgreement(with: theirs).withUnsafeBytes { Data($0) }
        }

        func theirs() throws -> Curve25519.KeyAgreement.PublicKey {
            guard let remote else { throw Failure.outOfTurn }
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote)
        }

        /// The next message, with `payload` (encrypted from the second message on).
        public mutating func write(_ payload: Data = Data()) throws -> Data {
            guard initiator == (step % 2 == 0), step < 3 else { throw Failure.outOfTurn }
            var out = Data()
            switch step {
            case 0: // -> e
                out += ephemeral.publicKey.rawRepresentation
                mixHash(ephemeral.publicKey.rawRepresentation)
            case 1: // <- e, ee, s, es
                guard let re = remoteEphemeral else { throw Failure.outOfTurn }
                out += ephemeral.publicKey.rawRepresentation
                mixHash(ephemeral.publicKey.rawRepresentation)
                mixKey(try dh(ephemeral, re))
                out += try encryptAndHash(key.publicKey.rawRepresentation)
                mixKey(try dh(key, re))
            default: // -> s, se
                guard let re = remoteEphemeral else { throw Failure.outOfTurn }
                out += try encryptAndHash(key.publicKey.rawRepresentation)
                mixKey(try dh(key, re))
            }
            out += try encryptAndHash(payload)
            step += 1
            return out
        }

        /// The other side's next message; gives its payload.
        public mutating func read(_ message: Data) throws -> Data {
            guard initiator != (step % 2 == 0), step < 3 else { throw Failure.outOfTurn }
            var rest = message[...]
            func take(_ count: Int) throws -> Data {
                guard rest.count >= count else { throw Failure.short }
                defer { rest = rest.dropFirst(count) }
                return Data(rest.prefix(count))
            }
            switch step {
            case 0: // -> e
                let re = try take(32)
                remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: re)
                mixHash(re)
            case 1: // <- e, ee, s, es
                let re = try take(32)
                let ephemeralKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: re)
                remoteEphemeral = ephemeralKey
                mixHash(re)
                mixKey(try dh(ephemeral, ephemeralKey))
                remote = try decryptAndHash(try take(48))
                mixKey(try dh(ephemeral, try theirs()))
            default: // -> s, se
                remote = try decryptAndHash(try take(48))
                mixKey(try dh(ephemeral, try theirs()))
            }
            let payload = try decryptAndHash(Data(rest))
            step += 1
            return payload
        }

        /// The handshake's two ciphers: the initiator sends with the first, the responder with the second.
        public func split() throws -> Transport {
            guard done else { throw Failure.outOfTurn }
            let (one, two) = hkdf(ck, Data())
            let first = Cipher(key: SymmetricKey(data: one)), second = Cipher(key: SymmetricKey(data: two))
            return initiator ? Transport(send: first, receive: second) : Transport(send: second, receive: first)
        }
    }

    static func hkdf(_ ck: Data, _ ikm: Data) -> (Data, Data) {
        let temp = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: ck))))
        let one = Data(HMAC<SHA256>.authenticationCode(for: Data([1]), using: temp))
        let two = Data(HMAC<SHA256>.authenticationCode(for: one + Data([2]), using: temp))
        return (one, two)
    }

    /// A Noise message is at most 65535 bytes: a longer one goes in pieces, each sealed on its own, its first plain
    /// byte saying whether more follow (0) or it's the last (1).
    static let piece = 65535 - 16 - 1

    public static func pieces(of message: Data, with cipher: inout Cipher) throws -> [Data] {
        var out: [Data] = [], at = message.startIndex
        repeat {
            let end = min(at + piece, message.endIndex)
            out.append(try cipher.seal(Data([end == message.endIndex ? 1 : 0]) + message[at..<end]))
            at = end
        } while at < message.endIndex
        return out
    }

    /// Pieces back into messages.
    public struct Joiner {
        var partial = Data()
        public init() {}
        /// A piece; gives the message once its last piece is in. ponytail: no cap on a message's size; cap it if a
        /// paired device ever needs distrusting.
        public mutating func add(_ sealed: Data, with cipher: inout Cipher) throws -> Data? {
            let plain = try cipher.open(sealed)
            guard let last = plain.first else { throw Failure.short }
            partial += plain.dropFirst()
            guard last == 1 else { return nil }
            defer { partial = Data() }
            return partial
        }
    }
}
