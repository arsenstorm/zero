import SwiftUI
import WidgetKit

// The watch face's Zero: what needs you (the blue hand and how many), what's in trouble, and the accounts' use as the
// Mac's rings. Read from what the watch app keeps (WatchState, in the app group), which reloads them as it changes.

@main struct ZeroComplications: WidgetBundle {
    var body: some Widget {
        NeedsYouWidget()
        TroubleWidget()
        UsageWidget()
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let state: WatchState
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, state: WatchState()) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now, state: .load())) }
    /// Read again within the quarter hour, so a ring whose window reset empties.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now, state: .load())], policy: .after(.now.addingTimeInterval(900))))
    }
}

struct Glyph: View {
    let name: String
    var size: CGFloat
    var body: some View { Image(name).resizable().renderingMode(.template).frame(width: size, height: size) }
}

// MARK: Needs you

struct NeedsYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "needsYou", provider: Provider()) { NeedsYouView(entry: $0) }
            .configurationDisplayName("Needs you")
            .description("How many tasks and asks are waiting on you.")
            .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct NeedsYouView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let count = entry.state.needingYou
        let color: Color = count > 0 ? .blue : .secondary
        switch family {
        case .accessoryInline:
            Text(count == 0 ? "Nothing needs you" : count == 1 ? "1 needs you" : "\(count) need you")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Glyph(name: "hand-3-glyph", size: 14).foregroundStyle(color).widgetAccentable()
                    Text(count == 0 ? "Nothing needs you" : count == 1 ? "1 needs you" : "\(count) need you").font(.headline)
                }
                if let ask = entry.state.asks.first {
                    Text(ask.title).font(.caption).lineLimit(2)
                } else if let task = entry.state.tasks.first(where: { $0.state == "needsYou" }) {
                    Text(task.name).font(.caption).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryCorner:
            Glyph(name: "hand-3-glyph", size: 20).foregroundStyle(color).widgetAccentable()
                .widgetLabel { Text("\(count)") }
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Glyph(name: "hand-3-glyph", size: 16).foregroundStyle(color).widgetAccentable()
                    Text("\(count)").font(.system(size: 17, weight: .semibold)).monospacedDigit()
                }
            }
        }
    }
}

// MARK: Trouble

struct TroubleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "trouble", provider: Provider()) { TroubleView(entry: $0) }
            .configurationDisplayName("In trouble")
            .description("Tasks that look stuck, failed or are blocked.")
            .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

struct TroubleView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let count = entry.state.inTrouble
        let color: Color = count > 0 ? .orange : .secondary
        switch family {
        case .accessoryInline:
            Text(count == 0 ? "No trouble" : "\(count) in trouble")
        case .accessoryCorner:
            Glyph(name: "triangle-warning-glyph", size: 20).foregroundStyle(color).widgetAccentable()
                .widgetLabel { Text("\(count)") }
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Glyph(name: "triangle-warning-glyph", size: 16).foregroundStyle(color).widgetAccentable()
                    Text("\(count)").font(.system(size: 17, weight: .semibold)).monospacedDigit()
                }
            }
        }
    }
}

// MARK: Usage

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "usage", provider: Provider()) { UsageView(entry: $0) }
            .configurationDisplayName("Usage")
            .description("Your accounts' use: the week inside, the 5 hours outside.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct UsageView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let accounts = entry.state.accounts.sorted { $0.fullest > $1.fullest }
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(accounts.prefix(3)) { account in
                    HStack(spacing: 6) {
                        Rings(account: account, now: entry.date, glyph: false).frame(width: 16, height: 16)
                        Text(account.label).font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(Int((account.fullest * 100).rounded()))%").font(.caption).monospacedDigit()
                    }
                }
            }
        } else if let account = accounts.first {
            ZStack {
                AccessoryWidgetBackground()
                Rings(account: account, now: entry.date, glyph: true).padding(3)
            }
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Text("–")
            }
        }
    }
}

/// The Mac's rings (SignInsView's UsageRing): the week inside, the 5 hours outside where the plan has them, each in the
/// colour of its use on a faint track of the same colour; the CLI's mark inside.
struct Rings: View {
    let account: WatchState.Account
    let now: Date
    let glyph: Bool

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let line = max(2, side * 0.09)
            ZStack {
                if let five = account.fiveUsed(now) { ring(five, line: line).frame(width: side, height: side) }
                ring(account.weekUsed(now), line: line).frame(width: side * 0.66, height: side * 0.66)
                if glyph {
                    Image(account.cli == "codex" ? "provider-openai" : "provider-claude").resizable().renderingMode(.template)
                        .scaledToFit().frame(width: side * 0.3, height: side * 0.3)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func ring(_ used: Double, line: CGFloat) -> some View {
        let color = Self.color(used)
        return ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: line)
            if used > 0 {
                Circle().trim(from: 0, to: used).stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .widgetAccentable()
    }

    /// Green, yellow from 40%, orange from 70%, red from 90% (UsageRing.levels).
    static func color(_ used: Double) -> Color { used >= 0.9 ? .red : used >= 0.7 ? .orange : used >= 0.4 ? .yellow : .green }
}
