import Foundation
import ZeroCore

/// Zero's updates: checked now and then, installed only when the user says (Settings › General, or the menu bar).
@MainActor @Observable final class Updater {
    static let shared = Updater()

    enum State: Equatable { case unchecked, checking, upToDate, available(Release), installing(Release), failed(String) }
    private(set) var state = State.unchecked
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    var available: Release? { if case .available(let release) = state { release } else { nil } }

    /// Checks at launch, then every six hours.
    func watch() {
        Task {
            while true {
                await check()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func check() async {
        if case .installing = state { return }
        state = .checking
        do {
            let release = try await Updates.latest()
            state = Updates.newer(release.version, than: current) ? .available(release) : .upToDate
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Downloads it, checks it's signed as this build, and installs it: Zero quits and opens again as the new build.
    func install(_ release: Release) async {
        state = .installing(release)
        do { try Updates.install(try await Updates.download(release)) } catch { state = .failed(error.localizedDescription) }
    }
}
