import Foundation
import Observation

/// OpenCode's models as its own CLI lists them (`opencode models`, a "provider/model" a line): read in the background
/// through the login shell, where the user's PATH finds it, kept, and read again at most once a minute. The ids are
/// those OpenCode's session takes for its model.
@MainActor @Observable public final class OpenCodeModels {
    public static let shared = OpenCodeModels()
    public private(set) var models: [SpawnChoice] = []
    @ObservationIgnored private var read: Date?

    public func refresh() {
        guard read.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        read = Date()
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "opencode models 2>/dev/null"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let found = OpenCodeModels.parse(String(decoding: data, as: UTF8.self))
            await MainActor.run { if !found.isEmpty, found != OpenCodeModels.shared.models { OpenCodeModels.shared.models = found } }
        }
    }

    nonisolated public static func parse(_ text: String) -> [SpawnChoice] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let id = line.trimmingCharacters(in: .whitespaces)
            guard let slash = id.firstIndex(of: "/"), !id.contains(" ") else { return nil }
            return SpawnChoice(id: id, name: String(id[id.index(after: slash)...]), provider: String(id[..<slash]))
        }
    }
}
