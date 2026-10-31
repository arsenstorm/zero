import Foundation

/// The app's log, ~/.zero/zero.log: what happened and when, for finding where something went wrong after the fact.
/// Plain lines (the system log redacts an app's interpolations as <private>); kept to a few megabytes, the previous
/// file beside it.
public enum Log {
    public static let file = Paths.dir.appendingPathComponent("zero.log")
    private static let limit = 5 * 1024 * 1024
    private static let lock = NSLock()
    private static let stamp: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    public nonisolated static func write(_ line: String) {
        lock.withLock {
            let data = Data((stamp.string(from: Date()) + " " + line + "\n").utf8)
            if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > limit {
                let old = file.appendingPathExtension("1")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: file, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: file) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
            else { try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try? data.write(to: file) }
        }
    }
}
