import CryptoKit
import Foundation
import Testing
@testable import ZeroCore

/// A phone's connection through the relay, both ends in one process: the phone (Tunnel.Phone) and the Mac's side of
/// it (Tunnel.Host and its Tunnel.Link), the relay's frames passed by hand.
private struct Clock { var now = Date(timeIntervalSince1970: 1_000_000) }

/// Runs the handshake to its end; gives the Mac's link and the phone, or what refused.
private func connect(_ host: Tunnel.Host, _ phone: inout Tunnel.Phone, at now: Date) throws -> Tunnel.Link? {
    var link = host.link()
    var toMac = [try phone.start()]
    while !toMac.isEmpty {
        let frame = toMac.removeFirst()
        switch try link.receive(frame, now: now) {
        case .send(let reply): toMac = try phone.receive(reply)
        case .ready: return link
        case .refused: return nil
        case .lines: Issue.record("lines before the handshake ended")
        }
    }
    return nil
}

private func invite(_ host: Tunnel.Host, at now: Date) -> Tunnel.Invite { host.invite(relay: "wss://relay.example", mac: "mac-1", now: now) }

@Test func aPhonePairsWithTheCodeAndIsKnownAfter() throws {
    let clock = Clock()
    let host = Tunnel.Host(key: .init())
    var phone = Tunnel.Phone(key: .init(), invite: invite(host, at: clock.now), name: "Arsen's iPhone")
    #expect(try connect(host, &phone, at: clock.now) != nil)
    #expect(host.devices.map(\.name) == ["Arsen's iPhone"])
    // Again, paired: no code needed (the invite's is spent).
    var again = Tunnel.Phone(key: phone.key, mac: host.publicKey, name: "Arsen's iPhone")
    #expect(try connect(host, &again, at: clock.now) != nil)
    #expect(host.devices.count == 1)
}

@Test func anUnknownPhoneWithoutACodeIsRefused() throws {
    let host = Tunnel.Host(key: .init())
    var stranger = Tunnel.Phone(key: .init(), mac: host.publicKey, name: "Someone")
    #expect(try connect(host, &stranger, at: Date()) == nil)
    #expect(host.devices.isEmpty)
}

@Test func aCodeIsGoodOnceAndForFiveMinutes() throws {
    var clock = Clock()
    let host = Tunnel.Host(key: .init())
    let code = invite(host, at: clock.now)
    var first = Tunnel.Phone(key: .init(), invite: code, name: "One")
    #expect(try connect(host, &first, at: clock.now) != nil)
    var second = Tunnel.Phone(key: .init(), invite: code, name: "Two")
    #expect(try connect(host, &second, at: clock.now) == nil, "spent")
    let late = invite(host, at: clock.now)
    clock.now += 6 * 60
    var third = Tunnel.Phone(key: .init(), invite: late, name: "Three")
    #expect(try connect(host, &third, at: clock.now) == nil, "expired")
}

@Test func aPhoneWontTalkToAMacThatIsntTheOneItScanned() throws {
    let host = Tunnel.Host(key: .init()), impostor = Tunnel.Host(key: .init())
    var phone = Tunnel.Phone(key: .init(), invite: invite(host, at: Date()), name: "Phone")
    #expect(throws: Tunnel.Failure.wrongMac) { try connect(impostor, &phone, at: Date()) }
}

@Test func aRemovedPhoneIsRefused() throws {
    let host = Tunnel.Host(key: .init())
    var phone = Tunnel.Phone(key: .init(), invite: invite(host, at: Date()), name: "Phone")
    _ = try connect(host, &phone, at: Date())
    host.remove(try #require(host.devices.first).id)
    var again = Tunnel.Phone(key: phone.key, mac: host.publicKey, name: "Phone")
    #expect(try connect(host, &again, at: Date()) == nil)
}

@Test func linesGoBothWaysOnceConnected() throws {
    let host = Tunnel.Host(key: .init())
    var phone = Tunnel.Phone(key: .init(), invite: invite(host, at: Date()), name: "Phone")
    var link = try #require(try connect(host, &phone, at: Date()))
    let request = Data(#"{"id":1,"op":"board"}"#.utf8)
    var toMac = try phone.send(request)
    var heard: [Data] = []
    for frame in toMac { if case .lines(let lines) = try link.receive(frame, now: Date()) { heard += lines } }
    #expect(heard == [request])
    toMac = try link.send(Data(#"{"id":1,"ok":true}"#.utf8))
    var back: [Data] = []
    for frame in toMac { back += try phone.lines(frame) }
    #expect(back == [Data(#"{"id":1,"ok":true}"#.utf8)])
}

@Test func whatOnlyTheMacMayDoIsAnsweredNotPassedOn() throws {
    let (pass, reply) = Tunnel.screen(Data(#"{"id":7,"op":"openTerminal","session":"x"}"#.utf8))
    #expect(pass == nil)
    let answer = try JSONSerialization.jsonObject(with: try #require(reply)) as? [String: Any]
    #expect(answer?["id"] as? Int == 7 && answer?["ok"] as? Bool == false)
    #expect(Tunnel.screen(Data(#"{"id":8,"op":"board"}"#.utf8)).pass != nil)
}

@Test func anInviteTravelsAsALink() throws {
    let host = Tunnel.Host(key: .init())
    let sent = invite(host, at: Date())
    #expect(Tunnel.Invite(link: sent.link) == sent)
}

@Test func aNoteForAPhoneOpensOnlyThere() throws {
    let host = Tunnel.Host(key: .init())
    let phone = Curve25519.KeyAgreement.PrivateKey(), stranger = Curve25519.KeyAgreement.PrivateKey()
    let device = Tunnel.Device(name: "Phone", key: phone.publicKey.rawRepresentation, added: Date())
    let sealed = try host.seal(Data("Merge it?".utf8), for: device)
    #expect(try Tunnel.open(sealed, with: phone, from: host.publicKey) == Data("Merge it?".utf8))
    #expect(throws: (any Error).self) { try Tunnel.open(sealed, with: stranger, from: host.publicKey) }
}
