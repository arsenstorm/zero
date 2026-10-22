import Foundation
import GhosttyVt

/// One terminal's screen, kept by Ghostty's engine: the program's output goes in, the screen as text comes out,
/// and the engine's own answers to the program's questions (cursor position, device attributes) go back to it.
final class Screen {
    private var terminal: GhosttyTerminal?
    /// Where the engine's replies to the program go: the terminal's input.
    var reply: (Data) -> Void = { _ in }
    /// The latest status the program reported (Program Status Protocol, OSC 7501): idle, working, blocked, done, error.
    private(set) var status: (state: String, message: String)?

    init(columns: Int, rows: Int) {
        ghostty_terminal_new(nil, &terminal, UInt16(columns), UInt16(rows))
        let me = Unmanaged.passUnretained(self).toOpaque()
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, me)
        let write: GhosttyTerminalWritePtyFn = { _, user, bytes, length in
            guard let user, let bytes else { return }
            Unmanaged<Screen>.fromOpaque(user).takeUnretainedValue().reply(Data(bytes: bytes, count: length))
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(write, to: UnsafeRawPointer.self))
        let status: GhosttyTerminalProgramStatusFn = { _, user, report in
            guard let user, let report else { return }
            let states = ["idle", "working", "done", "blocked", "error", "clear"]
            let state = states.indices.contains(Int(report.pointee.state.rawValue)) ? states[Int(report.pointee.state.rawValue)] : "idle"
            let message = report.pointee.message
            let text = message.ptr.map { String(decoding: UnsafeBufferPointer(start: $0, count: message.len), as: UTF8.self) } ?? ""
            Unmanaged<Screen>.fromOpaque(user).takeUnretainedValue().status = state == "clear" ? nil : (state, text)
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, unsafeBitCast(status, to: UnsafeRawPointer.self))
    }

    deinit { ghostty_terminal_free(terminal) }

    func feed(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_terminal_vt_write(terminal, base, raw.count)
        }
    }

    func resize(columns: Int, rows: Int) {
        ghostty_terminal_resize(terminal, UInt16(columns), UInt16(rows), 8, 16)
    }

    /// The screen as plain text, trailing blanks trimmed. `unwrap` joins lines the terminal wrapped.
    func text(unwrap: Bool = false) -> String {
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.unwrap = unwrap
        options.trim = true
        return format(options)
    }

    /// The screen as escape sequences that draw it again, colours, modes and cursor included: what an attaching
    /// terminal is shown first.
    func redraw() -> String {
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_VT
        options.extra.size = MemoryLayout<GhosttyFormatterTerminalExtra>.size
        options.extra.modes = true
        options.extra.scrolling_region = true
        options.extra.keyboard = true
        options.extra.screen.size = MemoryLayout<GhosttyFormatterScreenExtra>.size
        options.extra.screen.cursor = true
        options.extra.screen.style = true
        options.extra.screen.hyperlink = true
        options.extra.screen.kitty_keyboard = true
        options.extra.screen.charsets = true
        return format(options)
    }

    private func format(_ options: GhosttyFormatterTerminalOptions) -> String {
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, terminal, options) == GHOSTTY_SUCCESS else { return "" }
        defer { ghostty_formatter_free(formatter) }
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &pointer, &length) == GHOSTTY_SUCCESS, let pointer else { return "" }
        defer { ghostty_free(nil, pointer, length) }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }
}
