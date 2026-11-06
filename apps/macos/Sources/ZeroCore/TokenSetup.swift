import Foundation

/// `claude setup-token` under a pseudo-terminal (it is an interactive screen), with its input kept open so the
/// code from the browser can be typed into it, and its output collected to read the token from.
public final class TokenSetup: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var text = ""

    public init() {}

    func start() -> Bool {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // Wide enough that the token, about 110 characters, prints on one line instead of wrapping.
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-lc", "stty cols 400 rows 50; claude setup-token"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            self?.lock.withLock { self?.text += chunk }
        }
        return (try? process.run()) != nil
    }

    var running: Bool { process.isRunning }

    func send(_ code: String) {
        try? input.fileHandleForWriting.write(contentsOf: Data((code + "\r").utf8))
    }

    /// The token once Claude Code has printed it, on one line of its (wide) screen. Control sequences (colours,
    /// cursor moves, links) are taken out first, so none can cut it short.
    func token() -> String? {
        let screen = lock.withLock { text }
        let plain = screen
            .replacingOccurrences(of: #"\u{1B}\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\u{1B}\[[0-9;?<>=]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\u{1B}[()][A-Za-z0-9]"#, with: "", options: .regularExpression)
        return plain.range(of: #"sk-ant-oat[0-9]{2}-[A-Za-z0-9_-]{40,}"#, options: .regularExpression).map { String(plain[$0]) }
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}
