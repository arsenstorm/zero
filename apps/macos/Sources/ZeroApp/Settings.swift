import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import ZeroCore

/// Everything configurable, persisted in UserDefaults and shown in the workspace window's Settings.
@MainActor @Observable
final class Settings {
    private let defaults = UserDefaults.standard

    var followActiveScreen: Bool { didSet { defaults.set(followActiveScreen, forKey: "followActiveScreen") } }
    /// The control bar in the workspace window: when the window fills its screen, always while it's open, or never.
    enum BarDock: String, CaseIterable { case auto, always, never }
    var barDock: BarDock { didSet { defaults.set(barDock.rawValue, forKey: "barDock"); onChange?() } }
    /// Agent names in the order the user dragged them into; agents not listed follow in first-seen order.
    var agentOrder: [String] { didSet { defaults.set(agentOrder, forKey: "agentOrder") } }
    /// Minutes before an ask that arrives without its own expiry is marked expired.
    var defaultTTLMinutes: Int { didSet { defaults.set(defaultTTLMinutes, forKey: "defaultTTLMinutes"); onChange?() } }
    /// Seconds in which Esc can take an answer back.
    var takeBackSeconds: Double { didSet { defaults.set(takeBackSeconds, forKey: "takeBackSeconds"); onChange?() } }
    /// The talk hotkey: a virtual key code and Carbon modifier flags, plus how to print it.
    var hotKeyCode: Int { didSet { defaults.set(hotKeyCode, forKey: "hotKeyCode"); onChange?() } }
    var hotKeyModifiers: Int { didSet { defaults.set(hotKeyModifiers, forKey: "hotKeyModifiers"); onChange?() } }
    var hotKeyLabel: String { didSet { defaults.set(hotKeyLabel, forKey: "hotKeyLabel") } }
    /// After an answer turns green, move on to the next waiting card a few seconds later.
    var autoAdvance: Bool { didSet { defaults.set(autoAdvance, forKey: "autoAdvance"); onChange?() } }
    /// Composer suggestions: commands and skills after "/" (on), project files after "@" (off unless wanted).
    var suggestCommands: Bool { didSet { defaults.set(suggestCommands, forKey: "suggestCommands"); onChange?() } }
    var suggestFiles: Bool { didSet { defaults.set(suggestFiles, forKey: "suggestFiles"); onChange?() } }
    /// Folder patterns Zero watches for asks as files (globs, ~ allowed).
    var dropPatterns: [String] { didSet { defaults.set(dropPatterns, forKey: "dropPatterns"); onChange?() } }
    /// Microphone for dictation, as a CoreAudio device UID; nil follows the system default.
    var inputDeviceUID: String? { didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID"); onChange?() } }
    /// Tasks' notifications (Notifications.swift): what needs you, what's in trouble, what finished; and their sounds.
    var notifyNeedsYou: Bool { didSet { defaults.set(notifyNeedsYou, forKey: "notifyNeedsYou") } }
    var notifyTrouble: Bool { didSet { defaults.set(notifyTrouble, forKey: "notifyTrouble") } }
    var notifyFinished: Bool { didSet { defaults.set(notifyFinished, forKey: "notifyFinished") } }
    var notificationSounds: Bool { didSet { defaults.set(notificationSounds, forKey: "notificationSounds") } }
    /// The sound each state a task can come to plays, by the state's name: a system sound's name, "" for none. Those
    /// not picked play the default for their kind.
    var stateSounds: [String: String] { didSet { defaults.set(stateSounds, forKey: "stateSounds") } }
    func sound(for state: BoardRow.State) -> String { stateSounds[state.rawValue] ?? Self.defaultSound(state) }
    static func defaultSound(_ state: BoardRow.State) -> String {
        switch state {
        case .needsYou: "Blow"
        case .trouble, .blocked: "Bottle"
        default: "Hero"
        }
    }
    /// The system's alert sounds, every one copied into Zero.app (the Makefile), where a notification's has to be.
    static let sounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]
    @ObservationIgnored var onChange: (() -> Void)?

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    init() {
        followActiveScreen = defaults.bool(forKey: "followActiveScreen")
        barDock = defaults.string(forKey: "barDock").flatMap(BarDock.init) ?? .auto
        agentOrder = defaults.stringArray(forKey: "agentOrder") ?? []
        defaultTTLMinutes = defaults.object(forKey: "defaultTTLMinutes") as? Int ?? 60
        takeBackSeconds = defaults.object(forKey: "takeBackSeconds") as? Double ?? 2
        hotKeyCode = defaults.object(forKey: "hotKeyCode") as? Int ?? kVK_Space
        hotKeyModifiers = defaults.object(forKey: "hotKeyModifiers") as? Int ?? optionKey
        hotKeyLabel = defaults.string(forKey: "hotKeyLabel") ?? "⌥ Space"
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID")
        autoAdvance = defaults.object(forKey: "autoAdvance") as? Bool ?? true
        suggestCommands = defaults.object(forKey: "suggestCommands") as? Bool ?? true
        suggestFiles = defaults.object(forKey: "suggestFiles") as? Bool ?? false
        notifyNeedsYou = defaults.object(forKey: "notifyNeedsYou") as? Bool ?? true
        notifyTrouble = defaults.object(forKey: "notifyTrouble") as? Bool ?? true
        notifyFinished = defaults.object(forKey: "notifyFinished") as? Bool ?? true
        notificationSounds = defaults.object(forKey: "notificationSounds") as? Bool ?? true
        stateSounds = defaults.dictionary(forKey: "stateSounds") as? [String: String] ?? [:]
        dropPatterns = defaults.stringArray(forKey: "dropPatterns") ?? []
    }

    /// In the user's order, the rest after in the order given. Positions looked up once: found inside the comparison,
    /// the control bar's every redraw spent a frame on it.
    func sorted(_ names: [String]) -> [String] {
        let ordered = Dictionary(agentOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return names.enumerated().sorted { (ordered[$0.1] ?? .max, $0.0) < (ordered[$1.1] ?? .max, $1.0) }.map(\.1)
    }

    func move(_ name: String, before target: String, shown: [String]) {
        var order = shown.filter { $0 != name }
        guard let index = order.firstIndex(of: target) else { return }
        order.insert(name, at: index)
        agentOrder = order
    }
}
