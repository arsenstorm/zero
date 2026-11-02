import CryptoKit
import Foundation
import Testing
@testable import ZeroCore

/// Noise XX between the phone (initiator) and the Mac (responder): both learn each other's static key, and what they
/// send after is encrypted and authenticated.
private func handshake(phone: Curve25519.KeyAgreement.PrivateKey, mac: Curve25519.KeyAgreement.PrivateKey,
                       payload: Data = Data()) throws -> (Noise.Transport, Noise.Transport, Data, Data) {
    var initiator = Noise.Handshake(initiator: true, key: phone)
    var responder = Noise.Handshake(initiator: false, key: mac)
    let one = try initiator.write()
    _ = try responder.read(one)
    let two = try responder.write()
    _ = try initiator.read(two)
    let three = try initiator.write(payload)
    let heard = try responder.read(three)
    return (try initiator.split(), try responder.split(), try #require(initiator.remote), heard)
}

@Test func bothSidesLearnTheOthersKeyAndTalk() throws {
    let phone = Curve25519.KeyAgreement.PrivateKey(), mac = Curve25519.KeyAgreement.PrivateKey()
    var (toMac, toPhone, macKey, payload) = try handshake(phone: phone, mac: mac, payload: Data("pair 123456".utf8))
    #expect(macKey == mac.publicKey.rawRepresentation, "the phone pins what the QR code said")
    #expect(payload == Data("pair 123456".utf8), "the third message carries the pairing code, encrypted")
    let sealed = try toMac.send.seal(Data(#"{"op":"board"}"#.utf8))
    #expect(try toPhone.receive.open(sealed) == Data(#"{"op":"board"}"#.utf8))
    let back = try toPhone.send.seal(Data("rows".utf8))
    #expect(try toMac.receive.open(back) == Data("rows".utf8))
}

@Test func aTamperedMessageIsRefused() throws {
    let (toMac, toPhone, _, _) = try handshake(phone: .init(), mac: .init())
    var send = toMac.send, receive = toPhone.receive
    var sealed = try send.seal(Data("hello".utf8))
    sealed[0] ^= 1
    #expect(throws: (any Error).self) { try receive.open(sealed) }
}

@Test func messagesCantBeReplayed() throws {
    let (toMac, toPhone, _, _) = try handshake(phone: .init(), mac: .init())
    var send = toMac.send, receive = toPhone.receive
    let first = try send.seal(Data("one".utf8))
    _ = try receive.open(first)
    #expect(throws: (any Error).self) { try receive.open(first) }
}

@Test func aLongMessageGoesInPiecesAndComesBackWhole() throws {
    let (toMac, toPhone, _, _) = try handshake(phone: .init(), mac: .init())
    var send = toMac.send, receive = toPhone.receive
    let long = Data((0..<200_000).map { UInt8($0 % 251) })
    let pieces = try Noise.pieces(of: long, with: &send)
    #expect(pieces.count == 4 && pieces.allSatisfy { $0.count <= 65535 })
    var joined = Noise.Joiner()
    var whole: [Data] = []
    for piece in pieces { if let message = try joined.add(piece, with: &receive) { whole.append(message) } }
    #expect(whole == [long])
}
