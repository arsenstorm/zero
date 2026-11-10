import AppKit
import SwiftUI
import ZeroCore

/// One of zero-host's terminals in the window, as `zero attach` shows it in a terminal: the screen as it is, then the
/// program's output as it comes, drawn by GhosttyView; what you type goes to the program. zero-host keeps the program
/// running; letting go (leaving the page) doesn't end it.
struct HostTerminal: NSViewRepresentable {
    let id: String
    /// The program is Claude Code: ⌘C after a drag and ⌘V with an image use its Ctrl+C and Ctrl+V (GhosttyView).
    var claudeCode = false

    func makeCoordinator() -> Attachment { Attachment(id: id) }

    func makeNSView(context: Context) -> GhosttyView {
        let view = GhosttyView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let attachment = context.coordinator
        attachment.view = view
        view.claudeCode = claudeCode
        view.input = { attachment.send($0) }
        view.resized = { columns, rows in
            let request = HostLink.Request(op: "resize", id: attachment.id, columns: columns, rows: rows)
            Task.detached { _ = HostLink.call(request) }
        }
        attachment.attach(columns: view.columns, rows: view.rows)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: GhosttyView, context: Context) {}

    /// Exactly the space it's given: a terminal fits its grid to the page, never the page to the grid.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GhosttyView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    static func dismantleNSView(_ view: GhosttyView, coordinator: Attachment) { coordinator.letGo() }

    final class Attachment: @unchecked Sendable {
        let id: String
        weak var view: GhosttyView?
        private var socket: UnixSocket?
        private let lock = NSLock()

        init(id: String) { self.id = id }

        func attach(columns: Int, rows: Int) {
            let id = id
            Thread.detachNewThread { [weak self] in
                guard let socket = try? UnixSocket.connect(path: HostLink.socket) else { return }
                try? socket.send(HostLink.Request(op: "attach", id: id, columns: columns, rows: rows))
                guard socket.receive(HostLink.Response.self)?.ok == true else { socket.close(); return }
                guard let self else { socket.close(); return }
                self.lock.withLock { self.socket = socket }
                self.show(Array(socket.takeBuffered()))
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = read(socket.fd, &buffer, buffer.count)
                    guard count > 0 else { break }
                    self.show(Array(buffer[0..<count]))
                }
            }
        }

        private func show(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in self?.view?.feed(bytes) }
        }

        func send(_ data: Data) {
            lock.withLock {
                guard let socket else { return }
                data.withUnsafeBytes { _ = Darwin.write(socket.fd, $0.baseAddress!, $0.count) }
            }
        }

        func letGo() {
            lock.withLock {
                socket?.close(); socket = nil
            }
        }
    }
}
