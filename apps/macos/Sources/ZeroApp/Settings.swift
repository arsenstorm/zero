import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import ZeroCore

/// Everything configurable, persisted in UserDefaults and shown in the workspace window's Settings.
@MainActor @Observable
final class Settings {
    private let defaults = UserDefaults.standard

    /// The control bar at the screen's edge. Off, asks reach the user through the window, notifications and the Dock.
    var showBar: Bool { didSet { defaults.set(showBar, forKey: "showBar"); onChange?() } }
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
    /// The inbox hotkey: a virtual key code and Carbon modifier flags, plus how to print it.
    var hotKeyCode: Int { didSet { defaults.set(hotKeyCode, forKey: "hotKeyCode"); onChange?() } }
    var hotKeyModifiers: Int { didSet { defaults.set(hotKeyModifiers, forKey: "hotKeyModifiers"); onChange?() } }
    var hotKeyLabel: String { didSet { defaults.set(hotKeyLabel, forKey: "hotKeyLabel") } }
    /// Composer suggestions of project files after "@" (off unless wanted); commands and skills after "/" always.
    var suggestFiles: Bool { didSet { defaults.set(suggestFiles, forKey: "suggestFiles"); onChange?() } }
    /// Tasks' notifications (Notifications.swift): what needs you, what's in trouble, what finished; and their sounds.
    var notifyNeedsYou: Bool { didSet { defaults.set(notifyNeedsYou, forKey: "notifyNeedsYou") } }
    var notifyTrouble: Bool { didSet { defaults.set(notifyTrouble, forKey: "notifyTrouble") } }
    var notifyFinished: Bool { didSet { defaults.set(notifyFinished, forKey: "notifyFinished") } }
    /// The sound each state a task can come to plays, by the state's name: a system sound's name, "" for none. Those
    /// not picked play the default for their kind.
    var stateSounds: [String: String] { didSet { defaults.set(stateSounds, forKey: "stateSounds") } }
    func sound(for state: BoardRow.State) -> String { stateSounds[state.rawValue] ?? Self.defaultSound(state) }
    static func defaultSound(_ state: BoardRow.State) -> String {
        switch state {
        case .needsYou, .handed: "Blow"
        case .trouble, .blocked: "Bottle"
        default: "Hero"
        }
    }
    /// The states each kind of notification covers (TaskAlerts.standing): a kind's sound is its states', one chip in
    /// Settings; "Each state's sound…" sets them one by one.
    static let soundKinds: [(kind: AlertKind, states: [BoardRow.State])] = [
        (.needsYou, [.needsYou, .handed]), (.trouble, [.trouble, .blocked]), (.finished, [.done, .answered, .waiting]),
    ]
    /// A kind's sound; nil when its states play different ones.
    func sound(for kind: AlertKind) -> String? {
        let sounds = Set(Self.soundKinds.first { $0.kind == kind }?.states.map(sound(for:)) ?? [])
        return sounds.count == 1 ? sounds.first : nil
    }
    func setSound(_ sound: String, for kind: AlertKind) {
        for state in Self.soundKinds.first(where: { $0.kind == kind })?.states ?? [] { stateSounds[state.rawValue] = sound }
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
        showBar = defaults.object(forKey: "showBar") as? Bool ?? true
        followActiveScreen = defaults.bool(forKey: "followActiveScreen")
        barDock = defaults.string(forKey: "barDock").flatMap(BarDock.init) ?? .auto
        agentOrder = defaults.stringArray(forKey: "agentOrder") ?? []
        defaultTTLMinutes = defaults.object(forKey: "defaultTTLMinutes") as? Int ?? 60
        takeBackSeconds = defaults.object(forKey: "takeBackSeconds") as? Double ?? 2
        hotKeyCode = defaults.object(forKey: "hotKeyCode") as? Int ?? kVK_Space
        hotKeyModifiers = defaults.object(forKey: "hotKeyModifiers") as? Int ?? optionKey
        hotKeyLabel = defaults.string(forKey: "hotKeyLabel") ?? "⌥ Space"
        suggestFiles = defaults.object(forKey: "suggestFiles") as? Bool ?? false
        notifyNeedsYou = defaults.object(forKey: "notifyNeedsYou") as? Bool ?? true
        notifyTrouble = defaults.object(forKey: "notifyTrouble") as? Bool ?? true
        notifyFinished = defaults.object(forKey: "notifyFinished") as? Bool ?? true
        stateSounds = defaults.dictionary(forKey: "stateSounds") as? [String: String] ?? [:]
        // The Sounds switch is gone, each kind's chip has None: switched off, every state's sound is None, so nothing
        // starts sounding.
        if defaults.object(forKey: "notificationSounds") as? Bool == false {
            for state in Self.soundKinds.flatMap(\.states) { stateSounds[state.rawValue] = "" }
            defaults.set(stateSounds, forKey: "stateSounds")
        }
        defaults.removeObject(forKey: "notificationSounds")
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
