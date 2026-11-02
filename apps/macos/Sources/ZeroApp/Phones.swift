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

    enum Status: Equatable { case off, connecting, connected, failed(String) }
    private(set) var status = Status.off
    private(set) var devices: [Tunnel.Device] = []
    /// The QR code's invite while Add a phone is showing.
    var invite: Tunnel.Invite?

    var relay: String {
        get { UserDefaults.standard.string(forKey: "relay") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "relay"); reconnect() }
    }

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
        let key = Keychain.loadString(service: "Zero tunnel", account: "key").flatMap { Data(base64Encoded: $0) }
            .flatMap { try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) } ?? {
                let fresh = Curve25519.KeyAgreement.PrivateKey()
                Keychain.saveString(fresh.rawRepresentation.base64EncodedString(), service: "Zero tunnel", account: "key")
                return fresh
            }()
        let kept = Keychain.loadString(service: "Zero tunnel", account: "token")
        token = kept ?? {
            let fresh = Self.random(32)
            Keychain.saveString(fresh, service: "Zero tunnel", account: "token")
            return fresh
        }()
        // A new token is a new Mac to the relay, which takes only the first token it saw for an id.
        if kept == nil { UserDefaults.standard.removeObject(forKey: "tunnel.mac") }
        mac = UserDefaults.standard.string(forKey: "tunnel.mac") ?? {
            let fresh = Self.random(16)
            UserDefaults.standard.set(fresh, forKey: "tunnel.mac")
            return fresh
        }()
        let paired = UserDefaults.standard.data(forKey: "tunnel.devices").flatMap { try? JSONDecoder().decode([Tunnel.Device].self, from: $0) } ?? []
        host = Tunnel.Host(key: key, devices: paired)
        devices = paired
        host.onChange = { [weak self] devices in
            UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: "tunnel.devices")
            Task { @MainActor in self?.devices = devices }
        }
    }

    /// Letters and digits, URL-safe: the Mac's id and its relay token.
    static func random(_ bytes: Int) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func start() { if !relay.isEmpty { connect() } }

    func addPhone() { invite = host.invite(relay: relay, mac: mac) }

    /// A task's notification on every phone that takes them: its words sealed for each, so Apple carries only a
    /// generic line. One per task (its collapse id), replaced by the next.
    /// A workspace chosen on a phone, for the Mac to show.
    var onSetWorkspace: ((String) -> Void)?

    /// The Mac's workspace changed: the phones follow (they ask for the sidebar again on "workspaces").
    func workspaceChanged() {
        for bridge in bridges.values { bridge.event("workspaces") }
    }

    func push(_ alert: TaskAlert, sound: String) {
        for device in devices {
            guard let token = device.push, let note = try? JSONEncoder().encode(["title": alert.title, "body": alert.body]),
                  let sealed = try? host.seal(note, for: device) else { continue }
            var aps: [String: Any] = ["alert": ["title": "Zero", "body": "A task has news"], "mutable-content": 1]
            if !sound.isEmpty { aps["sound"] = sound + ".aiff" }
            APNs.send(["aps": aps, "zero": sealed.base64EncodedString()], to: token, collapse: alert.session)
            pushed.insert(alert.session)
        }
    }

    /// Takes tasks' notifications off the phones (seen, or moved on): a quiet push the app wakes for.
    func clear(_ ids: [String]) {
        let ids = ids.filter { pushed.contains($0) }
        guard !ids.isEmpty else { return }
        pushed.subtract(ids)
        for token in devices.compactMap(\.push) { APNs.send(["aps": ["content-available": 1], "clear": ids], to: token, collapse: nil, quiet: true) }
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

    private func connect() {
        guard let url = URL(string: relay.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "https://", with: "wss://")
                                .trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/mac/" + mac) else {
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
                task.sendPing { [weak self] error in Task { @MainActor in if error == nil, task === self?.socket { self?.heardAt = .now } } }
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
                    if self.status != .connected { self.status = .connected; self.retry = 1 }
                    self.heard(text)
                    self.receive(on: task)
                case .success: self.receive(on: task)
                case .failure(let error):
                    Log.write("phones: relay connection failed, \(error.localizedDescription)")
                    self.status = .failed(error.localizedDescription)
                    for conn in self.bridges.keys { self.bridges[conn]?.end() }
                    self.bridges = [:]
                    // Again, a little later each time, up to a minute.
                    let wait = self.retry
                    self.retry = min(self.retry * 2, 60)
                    try? await Task.sleep(for: .seconds(wait))
                    if task === self.socket { self.connect() }
                }
            }
        }
        // The relay says nothing until a phone connects: a ping says the socket is up.
        task.sendPing { [weak self] error in
            Task { @MainActor in if error == nil, task === self?.socket, self?.status == .connecting { self?.status = .connected } }
        }
    }

    private struct Frame: Codable { var conn: String; var open: Bool?; var data: String?; var close: Bool? }

    private func heard(_ text: String) {
        guard let frame = try? JSONDecoder().decode(Frame.self, from: Data(text.utf8)) else { Log.write("phones: unreadable frame"); return }
        if frame.open == true {
            Log.write("phones: a phone opened \(frame.conn.prefix(8))")
            bridges[frame.conn] = Bridge(link: host.link(), send: { [weak self] data in self?.send(data, to: frame.conn) }, close: { [weak self] in self?.close(frame.conn) },
                                         pushToken: { [weak self] token, device in self?.host.setPush(token, for: device) })
        } else if frame.close == true {
            bridges.removeValue(forKey: frame.conn)?.end()
        } else if let data = frame.data.flatMap({ Data(base64Encoded: $0) }) {
            bridges[frame.conn]?.receive(data)
        }
    }

    private func send(_ data: Data, to conn: String) {
        guard let text = try? String(data: JSONEncoder().encode(Frame(conn: conn, data: data.base64EncodedString())), encoding: .utf8) else { return }
        socket?.send(.string(text)) { error in if let error { Log.write("phones: couldn't send, \(error)") } }
    }

    private func close(_ conn: String) {
        bridges.removeValue(forKey: conn)?.end()
        if let text = try? String(data: JSONEncoder().encode(Frame(conn: conn, close: true)), encoding: .utf8) { socket?.send(.string(text)) { _ in } }
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
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let op = request["op"] as? String else { return nil }
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
        case "projects":
            result = Projects.folders
        case "image":
            // An image in a message (an upload, a screenshot): a JPEG of it no bigger than asked, for the phone to show.
            // Only images: anything else isn't read.
            guard let path = request["path"] as? String, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let type = CGImageSourceGetType(source) as String?, UTType(type)?.conforms(to: .image) == true,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: min(request["side"] as? Int ?? 600, 2400), kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                  let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
            result = jpeg.base64EncodedString()
        case "setWorkspace":
            // Chosen on the phone: the Mac shows it too, as the phone follows the Mac's.
            guard let id = request["workspace"] as? String else { return nil }
            Phones.shared.onSetWorkspace?(id)
            result = NSNull()
        case "looked":
            // A task opened on the phone: its notification goes from the Mac (and the other phones) too.
            guard let session = request["session"] as? String else { return nil }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [session])
            Phones.shared.clear([session])
            result = NSNull()
        case "sidebar":
            // How the Mac's sidebar orders and filters tasks, for the phone to show them the same way.
            let defaults = UserDefaults.standard
            result = ["sort": defaults.string(forKey: "taskSort") ?? BoardRow.Sort.state.rawValue, "order": defaults.string(forKey: "taskOrder") ?? "",
                      "workspace": defaults.string(forKey: "currentWorkspace") ?? "zero"]
        case "models":
            // A provider's models as the Mac's selector offers them, from its CLI's own cache.
            guard let provider = (request["provider"] as? String).flatMap(Provider.init(rawValue:)) else { return nil }
            result = ComposerRows.catalogue(provider).map { model in
                ["id": model.id, "name": model.name, "defaultLevel": model.defaultLevel ?? "",
                 "detail": model.detail ?? "", "context": model.context ?? "", "provider": model.provider ?? "", "icon": model.icon ?? "",
                 "levels": model.levels.map { ["id": $0.id, "name": $0.name] }] as [String: Any]
            }
        default:
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: ["id": request["id"] ?? NSNull(), "ok": true, "result": result])
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
                for line in lines {
                    if let reply = answered(line) { toPhone(reply); continue }
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
    func event(_ name: String) {
        if let line = try? JSONSerialization.data(withJSONObject: ["event": name]) { toPhone(line) }
    }

    private func toPhone(_ line: Data) {
        guard let frames = try? link.send(line) else { return }
        frames.forEach(send)
    }

    func end() { zerod?.shutdown(); zerod = nil }
}

/// Settings › Devices: the relay, the phones paired, and Add a phone's QR code.
struct DevicesPage: View {
    @Bindable private var phones = Phones.shared
    @State private var relay = Phones.shared.relay

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Relay").font(.system(size: 13, weight: .semibold))
                Rows {
                    SettingRow(title: "Address", detail: "Your Zero relay on Cloudflare (apps/relay in Zero's source): it passes your phone's encrypted messages and can't read them.") {
                        TextField("", text: $relay, prompt: Text("wss://zero-relay.you.workers.dev"))
                            .textFieldStyle(.roundedBorder).frame(width: 260)
                            .onSubmit { phones.relay = relay }
                    }
                    SettingRow(title: "Status", detail: statusDetail) { EmptyView() }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Phones").font(.system(size: 13, weight: .semibold))
                Rows {
                    ForEach(phones.devices) { device in
                        SettingRow(title: device.name, detail: "Paired \(device.added.formatted(date: .abbreviated, time: .omitted))") {
                            RowButton(title: "Remove") { phones.remove(device) }
                        }
                    }
                    SettingRow(title: "Add a phone", detail: "Scan the code with Zero on your phone. It's good once, for five minutes.") {
                        RowButton(title: phones.invite == nil ? "Show code" : "New code") { phones.addPhone() }
                            .disabled(phones.relay.isEmpty)
                    }
                }
                if let invite = phones.invite, let code = QRCode.image(invite.link) {
                    HStack(alignment: .bottom, spacing: 16) {
                        Image(nsImage: code).interpolation(.none).resizable().frame(width: 200, height: 200)
                            .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                        // For a phone without a camera to hand (a simulator): the same code as a link to open.
                        RowButton(title: "Copy link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(invite.link, forType: .string)
                        }
                    }
                }
            }
        }
    }

    private var statusDetail: String {
        switch phones.status {
        case .off: phones.relay.isEmpty ? "Not set up" : "Off"
        case .connecting: "Connecting…"
        case .connected: "Connected: your phones can reach this Mac"
        case .failed(let why): "Can't reach it: \(why)"
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

/// Apple's push service, with the user's key (Settings' push key, kept in the Keychain beside the tunnel's): token
/// auth, a JWT signed with it, good for up to an hour, so made again after fifty minutes.
enum APNs {
    private static var made: (jwt: String, at: Date)?

    private static func jwt() -> String? {
        if let made, Date().timeIntervalSince(made.at) < 50 * 60 { return made.jwt }
        let kept = { (account: String) in Keychain.loadString(service: "Zero tunnel", account: account) }
        guard let pem = kept("apns.key").flatMap({ Data(base64Encoded: $0) }).flatMap({ String(data: $0, encoding: .utf8) }),
              let key = try? P256.Signing.PrivateKey(pemRepresentation: pem), let id = kept("apns.keyid"), let team = kept("apns.team") else { return nil }
        let url = { (data: Data) in data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let input = url(Data(#"{"alg":"ES256","kid":"\#(id)"}"#.utf8)) + "." + url(Data(#"{"iss":"\#(team)","iat":\#(Int(Date().timeIntervalSince1970))}"#.utf8))
        guard let signature = try? key.signature(for: Data(input.utf8)) else { return nil }
        let jwt = input + "." + url(signature.rawRepresentation)
        made = (jwt, Date())
        return jwt
    }

    /// ponytail: the sandbox's address, as development builds of the phone app use; the production one once it ships
    /// through TestFlight or the App Store.
    static func send(_ payload: [String: Any], to token: String, collapse: String?, quiet: Bool = false) {
        guard let jwt = jwt() else { Log.write("push: no push key in the Keychain"); return }
        guard let body = try? JSONSerialization.data(withJSONObject: payload), let url = URL(string: "https://api.sandbox.push.apple.com/3/device/" + token) else { return }
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
            if status != 200 { Log.write("push: \(status) \(error.map { "\($0)" } ?? String(decoding: data ?? Data(), as: UTF8.self))") }
        }.resume()
    }
}
