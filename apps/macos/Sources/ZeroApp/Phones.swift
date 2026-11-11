import AppKit
import CoreImage.CIFilterBuiltins
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import ZeroCore

/// Zero's phones: the Mac's end of the tunnel (ZeroCore's Tunnel). It keeps a WebSocket to the user's relay and, for
/// each phone that connects through it, runs the handshake and then passes lines between the phone and a socket of
/// its own to zerod, as the app's own link does. The Mac's key and its relay token live in the Keychain (through the
/// `security` tool, so no build of Zero has to ask for the password); the paired
/// phones (names and public keys) in the app's defaults.
@MainActor @Observable final class Phones {
    static let shared = Phones()

    /// `closed`: the relay said it's closed for good (its CLOSED message): not tried again until its address changes.
    /// `limited`: connected, but the relay passes nothing for now (its day's bytes for this Mac are used): its words.
    enum Status: Equatable { case off, connecting, connected, failed(String), closed(String), limited(String) }
    private(set) var status = Status.off
    private(set) var devices: [Tunnel.Device] = []
    /// The QR code's invite while Add a phone is showing.
    var invite: Tunnel.Invite?

    /// Zero's own relay, used until the user sets theirs. It can close (relay.js's CLOSED): then Zero says so and stops.
    static let hosted = "wss://relay.withzero.dev"

    /// The relay in use: the user's, else Zero's hosted one. Emptied, phones are off.
    var relay: String {
        get { UserDefaults.standard.string(forKey: "relay") ?? Self.hosted }
        set { UserDefaults.standard.set(newValue, forKey: "relay"); reconnect() }
    }

    func useHostedRelay() { UserDefaults.standard.removeObject(forKey: "relay"); reconnect() }

    @ObservationIgnored private let host: Tunnel.Host
    @ObservationIgnored private let mac: String
    @ObservationIgnored private let token: String
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var bridges: [String: Bridge] = [:]
    @ObservationIgnored private var retry = 1.0
    /// When the relay last answered: a socket gone dead (the Mac slept, its network changed) says nothing, and the relay
    /// keeps handing it phones it never hears.
    @ObservationIgnored private var heardAt = Date()
    /// The notifications on the phones, by task (or ask): kept across launches, so one sent before Zero restarted is
    /// still taken off when it's seen or moves on.
    @ObservationIgnored private var pushed = Set(UserDefaults.standard.stringArray(forKey: "phonesPushed") ?? []) {
        didSet { UserDefaults.standard.set(Array(pushed), forKey: "phonesPushed") }
    }

    private init() {
        // Through macOS's `security` tool (ZeroCore's Keychain), so a rebuilt Zero reads them without the password.
        let key =
            Keychain.loadString(service: "Zero tunnel", account: "key").flatMap { Data(base64Encoded: $0) }
            .flatMap { try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
            ?? {
                let fresh = Curve25519.KeyAgreement.PrivateKey()
                Keychain.saveString(fresh.rawRepresentation.base64EncodedString(), service: "Zero tunnel", account: "key")
                return fresh
            }()
        let kept = Keychain.loadString(service: "Zero tunnel", account: "token")
        token =
            kept
            ?? {
                let fresh = Self.random(32)
                Keychain.saveString(fresh, service: "Zero tunnel", account: "token")
                return fresh
            }()
        // A new token is a new Mac to the relay, which takes only the first token it saw for an id.
        if kept == nil { UserDefaults.standard.removeObject(forKey: "tunnel.mac") }
        mac =
            UserDefaults.standard.string(forKey: "tunnel.mac")
            ?? {
                let fresh = Self.random(16)
                UserDefaults.standard.set(fresh, forKey: "tunnel.mac")
                return fresh
            }()
        let paired =
            UserDefaults.standard.data(forKey: "tunnel.devices").flatMap { try? JSONDecoder().decode([Tunnel.Device].self, from: $0) } ?? []
        host = Tunnel.Host(key: key, devices: paired)
        devices = paired
        host.onChange = { [weak self] devices in
            UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: "tunnel.devices")
            Task { @MainActor in
                self?.devices = devices
                self?.register()
            }
        }
    }

    /// Letters and digits, URL-safe: the Mac's id and its relay token.
    static func random(_ bytes: Int) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func start() {
        if !relay.isEmpty { connect() }
        watchWake()
    }

    /// Back from sleep: the relay's socket checked at once. Asleep, it may have died without saying so, and the ping
    /// every 20 s took up to a minute to notice, the phones told the Mac isn't connected meanwhile.
    @ObservationIgnored private var wakeWatch: Any?
    private func watchWake() {
        guard wakeWatch == nil else { return }
        wakeWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// A ping now: no answer in 5 s and the socket is dropped, which connects again (at once: the wait starts over).
    private func check() {
        guard !relay.isEmpty else { return }
        retry = 1
        // Off the relay already (waiting to try again): now. The wait's own try sees a newer socket and stands down.
        let off: Bool = { if case .failed = status { true } else { false } }()
        guard let task = socket, !off else { connect(); return }
        let asked = Date.now
        task.sendPing { [weak self] error in Task { @MainActor in if error == nil, task === self?.socket { self?.heardAt = .now } } }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, task === self.socket, self.heardAt < asked else { return }
            Log.write("phones: the relay didn't answer after sleep")
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    func addPhone() { invite = host.invite(relay: relay, mac: mac) }

    /// The MCP servers, for a phone to list: each one's name, how it runs and where, never its values.
    var mcpServers: (() async -> [[String: Any]])?

    /// Where pushes go: the relay in use, which sends them to Apple for its Macs' phones (none set: the Mac's own key).
    private var pushVia: APNs.Via? {
        relay.isEmpty ? nil : URL(string: Self.https(relay) + "/push/" + mac).map { APNs.Via(url: $0, token: token) }
    }

    /// The phones' push tokens, told the relay: the only ones it sends this Mac's pushes to.
    private func register() {
        guard let text = try? String(data: JSONEncoder().encode(["push": devices.compactMap(\.push)]), encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    /// A task's notification on every phone that takes them: its words sealed for each, so Apple carries only a
    /// generic line. One per task (its collapse id), replaced by the next.
    func push(_ alert: TaskAlert, sound: String) {
        for device in devices {
            guard let token = device.push, let note = try? JSONEncoder().encode(["title": alert.title, "body": alert.body]),
                let sealed = try? host.seal(note, for: device)
            else { continue }
            var aps: [String: Any] = ["alert": ["title": "Zero", "body": "A task has news"], "mutable-content": 1]
            if !sound.isEmpty { aps["sound"] = sound + ".aiff" }
            APNs.send(["aps": aps, "zero": sealed.base64EncodedString()], to: token, collapse: alert.session, via: pushVia)
            pushed.insert(alert.session)
        }
    }

    /// Takes tasks' notifications off the phones (seen, or moved on): told now to a phone that's connected, and a quiet
    /// push for the rest, which iOS delivers when it chooses (it rations them, and drops them for an app closed).
    func clear(_ ids: [String]) {
        for bridge in bridges.values { bridge.event("clear", ["ids": ids]) }
        let ids = ids.filter { pushed.contains($0) }
        guard !ids.isEmpty else { return }
        pushed.subtract(ids)
        for token in devices.compactMap(\.push) {
            APNs.send(["aps": ["content-available": 1], "clear": ids], to: token, collapse: nil, quiet: true, via: pushVia)
        }
    }

    func remove(_ device: Tunnel.Device) {
        host.remove(device.id)
        // Its connections end with it.
        for (conn, bridge) in bridges where bridge.device?.id == device.id { close(conn) }
    }

    private func reconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        for conn in bridges.keys { bridges[conn]?.end() }
        bridges = [:]
        status = .off
        start()
    }

    /// The relay's word that it has closed, from its /status: its message, or nil while it's open (or can't be asked:
    /// then connecting says what's wrong).
    private static func closedMessage(_ relay: String) async -> String? {
        guard let url = URL(string: https(relay) + "/status") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
            let said = try? JSONSerialization.jsonObject(with: data) as? [String: Any], said["open"] as? Bool == false
        else { return nil }
        return said["message"] as? String ?? "This relay has closed."
    }

    /// The relay's address over HTTPS, for its /status and /push.
    private static func https(_ relay: String) -> String {
        relay.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func connect() {
        let relay = relay
        Task { [weak self] in
            // Closed for good: said, and not tried again (a closed relay refuses every connection with 410).
            if let message = await Self.closedMessage(relay) {
                guard let self, self.relay == relay else { return }
                Log.write("phones: the relay has closed")
                self.socket = nil
                self.status = .closed(message)
                return
            }
            self?.open()
        }
    }

    private func open() {
        guard
            let url = URL(
                string: relay.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "https://", with: "wss://")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/mac/" + mac)
        else {
            status = .failed("That isn't a relay's address")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        Log.write("phones: connecting to the relay")
        socket = task
        status = .connecting
        task.resume()
        register()
        receive(on: task)
        heardAt = .now
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(20))
                guard let self, task === self.socket else { return }
                if Date.now.timeIntervalSince(self.heardAt) > 50 {
                    // Failing its receive, which connects again.
                    Log.write("phones: the relay went quiet")
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
                task.sendPing { [weak self] error in Task { @MainActor in if error == nil, task === self?.socket { self?.heardAt = .now } }
                }
            }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.socket else { return }
                switch result {
                case .success(.string(let text)):
                    self.heardAt = .now
                    // Not over the relay's limit: only a phone getting through again says that's past (heard).
                    if self.status == .connecting { self.status = .connected; self.retry = 1 }
                    self.heard(text)
                    self.receive(on: task)
                case .success: self.receive(on: task)
                case .failure(let error):
                    Log.write("phones: relay connection failed, \(error.localizedDescription)")
                    self.status = .failed(error.localizedDescription)
                    for conn in self.bridges.keys { self.bridges[conn]?.end() }
                    self.bridges = [:]
                    // Again, a little later each time, up to a minute (connect asks first whether it has closed).
                    let wait = self.retry
                    self.retry = min(self.retry * 2, 60)
                    try? await Task.sleep(for: .seconds(wait))
                    if task === self.socket { self.connect() }
                }
            }
        }
        // The relay says nothing until a phone connects: a ping says the socket is up. Up, the wait before the next
        // try starts over: it grew with each drop and was only reset by a phone's frame, so after a few (sleep, a
        // network change) the Mac stayed off the relay a minute each time.
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard error == nil, let self, task === self.socket else { return }
                self.heardAt = .now
                self.retry = 1
                if self.status == .connecting { self.status = .connected }
            }
        }
    }

    private struct Frame: Codable { var conn: String; var open: Bool?; var data: String?; var close: Bool? }
    /// The relay's {"limit": why}: said until a phone reaches this Mac again.
    private struct Limit: Decodable { var limit: String }

    private func heard(_ text: String) {
        if let said = try? JSONDecoder().decode(Limit.self, from: Data(text.utf8)) {
            Log.write("phones: the relay's limit, \(said.limit)")
            status = .limited(said.limit)
            return
        }
        guard let frame = try? JSONDecoder().decode(Frame.self, from: Data(text.utf8)) else {
            Log.write("phones: unreadable frame"); return
        }
        if frame.open == true {
            Log.write("phones: a phone opened \(frame.conn.prefix(8))")
            status = .connected
            bridges[frame.conn] = Bridge(
                link: host.link(), send: { [weak self] data in self?.send(data, to: frame.conn) },
                close: { [weak self] in self?.close(frame.conn) },
                pushToken: { [weak self] token, device in self?.host.setPush(token, for: device) })
        } else if frame.close == true {
            bridges.removeValue(forKey: frame.conn)?.end()
        } else if let data = frame.data.flatMap({ Data(base64Encoded: $0) }) {
            bridges[frame.conn]?.receive(data)
        }
    }

    private func send(_ data: Data, to conn: String) {
        guard let text = try? String(data: JSONEncoder().encode(Frame(conn: conn, data: data.base64EncodedString())), encoding: .utf8)
        else { return }
        socket?.send(.string(text)) { error in if let error { Log.write("phones: couldn't send, \(error)") } }
    }

    private func close(_ conn: String) {
        bridges.removeValue(forKey: conn)?.end()
        if let text = try? String(data: JSONEncoder().encode(Frame(conn: conn, close: true)), encoding: .utf8) {
            socket?.send(.string(text)) { _ in }
        }
    }
}

/// One phone's connection: its handshake, then its lines to zerod on a socket of their own, and zerod's back.
@MainActor private final class Bridge {
    private var link: Tunnel.Link
    private let send: (Data) -> Void
    private let close: () -> Void
    private var zerod: UnixSocket?
    var device: Tunnel.Device? { link.device }

    private let pushToken: (String, String) -> Void

    init(link: Tunnel.Link, send: @escaping (Data) -> Void, close: @escaping () -> Void, pushToken: @escaping (String, String) -> Void) {
        self.link = link
        self.send = send
        self.close = close
        self.pushToken = pushToken
    }

    /// The phone's own requests, answered here rather than by zerod: where its pushes go, an image it sends (kept
    /// where zerod can read it, its path given back), and the projects a new task can start in.
    private func answered(_ line: Data) -> Data? {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let op = request["op"] as? String else {
            return nil
        }
        let result: Any
        switch op {
        case "pushToken":
            guard let token = request["token"] as? String, let device = device?.id else { return nil }
            pushToken(token, device)
            result = NSNull()
        case "upload":
            guard let data = (request["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
            let name = URL(fileURLWithPath: request["name"] as? String ?? "image.jpg").lastPathComponent
            let folder = Paths.dir.appendingPathComponent("uploads")
            let file = folder.appendingPathComponent(UUID().uuidString.prefix(8) + "-" + name)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? data.write(to: file)) != nil else { return nil }
            result = file.path
        case "name":
            // The Mac's own name (System Settings › General › Sharing), for the phone to say which it's paired with.
            result = Host.current().localizedName ?? "your Mac"
        case "projects":
            result = Projects.folders
        case "image":
            // An image in a message (an upload, a screenshot): a JPEG of it no bigger than asked, for the phone to show.
            // Only images: anything else isn't read.
            guard let path = request["path"] as? String, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                let type = CGImageSourceGetType(source) as String?, UTType(type)?.conforms(to: .image) == true,
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: min(request["side"] as? Int ?? 600, 2400),
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary),
                let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            else { return nil }
            result = jpeg.base64EncodedString()
        case "looked":
            // A task opened on the phone: its notification goes from the Mac (and the other phones) too.
            guard let session = request["session"] as? String else { return nil }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [session])
            Phones.shared.clear([session])
            result = NSNull()
        case "sidebar":
            // How the Mac's sidebar orders tasks, for the phone to order them the same way. Which workspace each shows
            // is its own: one task watched on the phone, another worked on at the Mac.
            let defaults = UserDefaults.standard
            result = [
                "sort": defaults.string(forKey: "taskSort") ?? BoardRow.Sort.state.rawValue,
                "order": defaults.string(forKey: "taskOrder") ?? "",
            ]
        case "models":
            // A provider's models as the Mac's selector offers them, from its CLI's own cache.
            guard let provider = (request["provider"] as? String).flatMap(Provider.init(rawValue:)) else { return nil }
            result = ComposerRows.catalogue(provider).map { model in
                [
                    "id": model.id, "name": model.name, "defaultLevel": model.defaultLevel ?? "",
                    "detail": model.detail ?? "", "context": model.context ?? "", "provider": model.provider ?? "",
                    "icon": model.icon ?? "",
                    "levels": model.levels.map { ["id": $0.id, "name": $0.name] },
                ] as [String: Any]
            }
        default:
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: ["id": request["id"] ?? NSNull(), "ok": true, "result": result])
    }

    /// The phone's requests answered once the Mac has looked: the MCP servers (zerod's own list has their values).
    private func answeredLater(_ line: Data) -> Bool {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any], request["op"] as? String == "mcpServers" else {
            return false
        }
        Task {
            let servers = await Phones.shared.mcpServers?() ?? []
            if let reply = try? JSONSerialization.data(withJSONObject: ["id": request["id"] ?? NSNull(), "ok": true, "result": servers]) {
                toPhone(reply)
            }
        }
        return true
    }

    func receive(_ frame: Data) {
        do {
            switch try link.receive(frame) {
            case .send(let reply): send(reply)
            case .ready(let device):
                Log.write("phone: \(device.name) connected")
                open()
            case .refused(let why):
                Log.write("phone: refused, \(why)")
                close()
            case .lines(let lines):
                PhoneUse.touched()
                for line in lines {
                    if let reply = answered(line) { toPhone(reply); continue }
                    if answeredLater(line) { continue }
                    let (pass, reply) = Tunnel.screen(line)
                    if let reply { toPhone(reply) }
                    if let pass, let text = String(data: pass, encoding: .utf8) { try? zerod?.write(line: text) }
                }
            }
        } catch {
            Log.write("phone: dropped, \(error)")
            close()
        }
    }

    private func open() {
        guard let socket = try? UnixSocket.connect(path: ZerodLink.socket) else { close(); return }
        zerod = socket
        // zerod's lines, read off the main thread, sealed and sent on it.
        Thread.detachNewThread { [weak self] in
            while let line = socket.readLine() {
                Task { @MainActor in self?.toPhone(Data(line.utf8)) }
            }
            Task { @MainActor in self?.close() }
        }
    }

    /// Something changed that isn't zerod's to say (the Mac's workspace): told as its event.
    func event(_ name: String, _ fields: [String: Any] = [:]) {
        if let line = try? JSONSerialization.data(withJSONObject: fields.merging(["event": name]) { a, _ in a }) { toPhone(line) }
    }

    private func toPhone(_ line: Data) {
        guard let frames = try? link.send(line) else { return }
        frames.forEach(send)
    }

    func end() { zerod?.shutdown(); zerod = nil }
}

/// Settings › Phone: the relay, the phones paired, and Add a phone's QR code.
struct DevicesPage: View {
    @Bindable private var phones = Phones.shared
    /// Your own relay's address, being written in its dialog.
    @State private var editing = false
    /// Pairing a phone, in its wizard.
    @State private var pairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            SettingsSection(title: "Relay") {
                Rows {
                    // Which relay and how it's doing, in one row: Zero's own chip on the right, not a text box.
                    SettingRow(title: "Relay", detail: statusDetail) {
                        SettingChoice(
                            id: "phones.relay", choices: relayChoices,
                            selection: Binding(
                                get: { phones.relay == Phones.hosted ? "hosted" : "own" },
                                set: { picked in
                                    if picked == "hosted" { phones.useHostedRelay() } else if picked == "edit" { editing = true }
                                }))
                    }
                }
                Text(
                    "It passes your phone's messages to this Mac, end-to-end encrypted: it can't read them. You can run your own from apps/relay."
                )
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // Pairing as Accounts adds an account: a quiet button by the heading, its steps in a dialog.
            SettingsSection(
                title: "Phones",
                accessory: AnyView(
                    GhostButton(title: "Pair phone", icon: "plus", open: pairing) { pairing = true }
                        .disabled(phones.relay.isEmpty))
            ) {
                Rows {
                    ForEach(phones.devices) { device in
                        SettingRow(title: device.name, detail: "Paired \(device.added.formatted(date: .abbreviated, time: .omitted))") {
                            RowButton(title: "Remove") { phones.remove(device) }
                        }
                    }
                    if phones.devices.isEmpty {
                        Text("None yet. Pair your iPhone, and your tasks come with you.").font(.system(size: 13)).foregroundStyle(
                            .secondary
                        )
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
                    }
                }
            }
        }
        .zeroDialog(isPresented: $editing) { RelaySheet(address: phones.relay == Phones.hosted ? "" : phones.relay) { phones.relay = $0 } }
        .zeroDialog(isPresented: $pairing) { PairPhone() }
    }

    private var relayChoices: [[(title: String, value: String)]] {
        let own = phones.relay == Phones.hosted ? nil : URL(string: phones.relay)?.host ?? phones.relay
        return [
            [("Zero's relay", "hosted")] + (own.map { [($0, "own")] } ?? []),
            [(own == nil ? "Your own relay…" : "Change address…", "edit")],
        ]
    }

    private var statusDetail: String {
        switch phones.status {
        case .off: phones.relay.isEmpty ? "Off: no relay set" : "Off"
        case .connecting: "Connecting…"
        case .connected: "Connected: your phones can reach this Mac"
        case .failed(let why): "Can't reach it: \(why)"
        case .closed(let message): "It has closed: " + message
        case .limited(let why): why
        }
    }
}

enum QRCode {
    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Apple's push service, through the relay: it holds the APNs key and sends to the phones this Mac registered. A relay
/// that can't (a self-hosted one without the key, or one from before) leaves it to the Mac's own key, kept in the
/// Keychain beside the tunnel's: token auth, a JWT signed with it, good for up to an hour, so made again after fifty
/// minutes.
enum APNs {
    /// The relay's /push for this Mac, and the Mac's token for it.
    struct Via: Sendable { let url: URL; let token: String }

    /// Where pushes are signed and sent with the Mac's own key, one at a time: off the main thread (the key's first
    /// read, the Keychain's `security`, cost 100 ms there, as a question's card slid in), and `made` and `sandboxed`
    /// only ever touched here.
    private static let queue = DispatchQueue(label: "zero.apns")
    nonisolated(unsafe) private static var made: (jwt: String, at: Date)?
    /// Tokens of development builds of the phone app, which only Apple's sandbox takes (it says BadDeviceToken to the
    /// other).
    nonisolated(unsafe) private static var sandboxed = Set<String>()

    private static func jwt() -> String? {
        if let made, Date().timeIntervalSince(made.at) < 50 * 60 { return made.jwt }
        let kept = { (account: String) in Keychain.loadString(service: "Zero tunnel", account: account) }
        guard let pem = kept("apns.key").flatMap({ Data(base64Encoded: $0) }).flatMap({ String(data: $0, encoding: .utf8) }),
            let key = try? P256.Signing.PrivateKey(pemRepresentation: pem), let id = kept("apns.keyid"), let team = kept("apns.team")
        else { return nil }
        let url = { (data: Data) in
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let input =
            url(Data(#"{"alg":"ES256","kid":"\#(id)"}"#.utf8)) + "."
            + url(Data(#"{"iss":"\#(team)","iat":\#(Int(Date().timeIntervalSince1970))}"#.utf8))
        guard let signature = try? key.signature(for: Data(input.utf8)) else { return nil }
        let jwt = input + "." + url(signature.rawRepresentation)
        made = (jwt, Date())
        return jwt
    }

    static func send(_ payload: [String: Any], to token: String, collapse: String?, quiet: Bool = false, via relay: Via?) {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        guard let relay,
            let ask = try? JSONSerialization.data(withJSONObject: [
                "token": token, "payload": payload, "collapse": collapse ?? NSNull(), "quiet": quiet,
            ])
        else {
            queue.async { post(body, to: token, collapse: collapse, quiet: quiet) }
            return
        }
        var request = URLRequest(url: relay.url)
        request.httpMethod = "POST"
        request.httpBody = ask
        request.setValue("Bearer " + relay.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { data, response, error in
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: break
            // A relay that doesn't send pushes (501), or from before it could (404): the Mac's own key, if it has one.
            case 404, 501: queue.async { post(body, to: token, collapse: collapse, quiet: quiet) }
            case let status:
                Log.write("push: the relay said \(status) \(error.map { "\($0)" } ?? String(decoding: data ?? Data(), as: UTF8.self))")
            }
        }.resume()
    }

    private static func post(_ body: Data, to token: String, collapse: String?, quiet: Bool, again: Bool = false) {
        guard let jwt = jwt() else { Log.write("push: the relay doesn't send pushes and there's no push key in the Keychain"); return }
        let sandbox = sandboxed.contains(token)
        guard let url = URL(string: "https://api.\(sandbox ? "sandbox." : "")push.apple.com/3/device/" + token) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("bearer " + jwt, forHTTPHeaderField: "authorization")
        request.setValue("com.arsen.zero.ios", forHTTPHeaderField: "apns-topic")
        request.setValue(quiet ? "background" : "alert", forHTTPHeaderField: "apns-push-type")
        request.setValue(quiet ? "5" : "10", forHTTPHeaderField: "apns-priority")
        if let collapse { request.setValue(collapse, forHTTPHeaderField: "apns-collapse-id") }
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let said = String(decoding: data ?? Data(), as: UTF8.self)
            if status == 400, said.contains("BadDeviceToken"), !again {
                queue.async {
                    if sandbox { sandboxed.remove(token) } else { sandboxed.insert(token) }
                    post(body, to: token, collapse: collapse, quiet: quiet, again: true)
                }
            } else if status != 200 {
                Log.write("push: \(status) \(error.map { "\($0)" } ?? said)")
            }
        }.resume()
    }
}

/// When a phone last asked something of the Mac (its app open and in use: it asks nothing in the background).
enum PhoneUse {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var at = Date.distantPast
    static func touched() { lock.lock(); at = Date(); lock.unlock() }
    static var last: Date { lock.lock(); defer { lock.unlock() }; return at }
}

/// Your own relay's address, in a dialog: the one Settings › Phone's chip offers instead of Zero's.
private struct RelaySheet: View {
    @State var address: String
    let done: (String) -> Void
    @Environment(\.closeDialog) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                DialogTitle(text: "Your own relay")
                Text("Where your relay runs, deployed from apps/relay. Phones paired before pair again with a new code.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField("", text: $address, prompt: Text("wss://zero-relay.you.workers.dev")).textFieldStyle(.dialog).onSubmit(save)
            HStack {
                Spacer()
                DialogButton(title: "Cancel") { dismiss() }
                DialogButton(
                    title: "Use it", kind: .primary, enabled: address.trimmingCharacters(in: .whitespaces).hasPrefix("wss://"), action: save
                )
            }
        }
        .frame(width: 400)
    }

    private func save() {
        let address = address.trimmingCharacters(in: .whitespaces)
        guard address.hasPrefix("wss://") else { return }
        done(address)
        dismiss()
    }
}

/// Pairing a phone, step by step: Zero on the iPhone, then this Mac's code to scan (it lasts five minutes), then the
/// phone that paired. Moves on to the last step by itself once the phone has.
private struct PairPhone: View {
    @Bindable private var phones = Phones.shared
    @Environment(\.closeDialog) private var dismiss
    @State private var step = 0
    @State private var codeAt = Date.now
    /// The phones paired when the code was made: one more is the one that just paired.
    @State private var before: Set<String> = []

    private static let steps = ["Get Zero", "Scan the code", "Paired"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, name in
                    Capsule().fill(index <= step ? Color.primary : Theme.row).frame(height: 3)
                        .accessibilityLabel("Step \(index + 1): \(name)")
                }
            }
            Group {
                switch step {
                case 0: getZero
                case 1: scan
                default: paired
                }
            }
            .frame(minHeight: 230, alignment: .top)
            HStack {
                if step == 1 { DialogButton(title: "Back") { step = 0 } }
                Spacer()
                switch step {
                case 0:
                    DialogButton(title: "Cancel") { close() }
                    DialogButton(title: "Next", kind: .primary) {
                        newCode(); step = 1
                    }
                case 1:
                    DialogButton(title: "Cancel") { close() }
                default:
                    DialogButton(title: "Done", kind: .primary) { close() }
                }
            }
        }
        .frame(width: 440)
        // The phone paired: on to the last step.
        .onChange(of: phones.devices.map(\.id)) { _, ids in if step == 1, !Set(ids).subtracting(before).isEmpty { step = 2 } }
    }

    private var getZero: some View {
        VStack(alignment: .leading, spacing: 8) {
            DialogTitle(text: "Get Zero on your iPhone")
            Text(
                "Your tasks and questions come with you: answer what's waiting, write to a task, and get notified when something needs you."
            )
            .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Install Zero on your iPhone, open it, and choose Next here when it shows Scan the code.")
                .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
    }

    private var scan: some View {
        HStack(alignment: .top, spacing: 18) {
            if let invite = phones.invite, let code = QRCode.image(invite.link) {
                Image(nsImage: code).interpolation(.none).resizable().frame(width: 168, height: 168)
                    .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 8) {
                    DialogTitle(text: "Scan the code")
                    Text("In Zero on your iPhone, tap Scan the code and point the camera here.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, 300 - Int(context.date.timeIntervalSince(codeAt)))
                        Text(left == 0 ? "This code has expired" : String(format: "Expires in %d:%02d", left / 60, left % 60))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(left == 0 ? .red : .secondary)
                    }
                    Spacer(minLength: 0)
                    GhostButton(title: "New code", icon: "arrow-rotate-clockwise:glyph") { newCode() }
                    // For a phone without a camera to hand (a simulator): the same code as a link to open.
                    GhostButton(title: "Copy link", icon: "copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(invite.link, forType: .string)
                    }
                }
                .frame(height: 188, alignment: .top)
            }
        }
    }

    private var paired: some View {
        let phone = phones.devices.first { !before.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            DialogTitle(text: "\(phone?.name ?? "Your phone") is paired")
            Text("It reaches this Mac through the relay whenever Zero is open here. Remove it from this page any time.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func newCode() { before = Set(phones.devices.map(\.id)); phones.addPhone(); codeAt = .now }

    private func close() { phones.invite = nil; dismiss() }
}
