import SwiftUI
import VisionKit

/// Before pairing: the mark over the dots, three steps on the Mac, and the two ways in (scanning its code, or its link).
struct PairView: View {
    let model: PhoneModel
    @State private var scanning = false
    @State private var wrong = false

    var body: some View {
        Welcome(title: "Pair with your Mac", words: "Your phone talks to Zero on your Mac, end to end encrypted.") {
            Panel {
                ForEach(Array(["Open Zero on your Mac", "Settings › Phone › Add a phone", "Scan the code it shows"].enumerated()), id: \.offset) { n, step in
                    HStack(spacing: 14) {
                        Text("\(n + 1)").font(.subheadline.weight(.semibold)).monospacedDigit()
                            .frame(width: 28, height: 28).background(Color.primary.opacity(0.1), in: Circle())
                        Text(step).font(.body.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 52)
                }
            }
            VStack(spacing: 10) {
                WideButton(title: "Scan the code", prominent: true) { scanning = true }
                    .disabled(!DataScannerViewController.isSupported)
                WideButton(title: "Paste a pairing link") { wrong = !model.pair(UIPasteboard.general.string ?? "") }
                // Its room kept, so the buttons don't move when it shows.
                Text("That isn't a Zero pairing link.").font(.footnote).foregroundStyle(.red).opacity(wrong ? 1 : 0)
            }
        } foot: { EmptyView() }
        .sheet(isPresented: $scanning) {
            Scanner { text in
                scanning = false
                wrong = !model.pair(text)
            }
            .ignoresSafeArea()
        }
    }
}

/// Paired, before the first board: as the Mac starts, only the mark, where the launch screen put it, until the app is
/// ready. Not ready in 5 s, or a try missed: connecting to the Mac, the relay's state in a card. Once a try has missed it says so, and why, and keeps saying so while it tries
/// again on its own: flipping back to Connecting each time moved everything.
struct Splash: View {
    let model: PhoneModel
    @State private var missed = false
    @State private var slow = false

    var body: some View {
        ZStack {
            if missed || slow {
                details.transition(.opacity)
            } else {
                // The launch screen's own image, at its size, centred on the whole screen as it is there.
                Image("launch-mark").frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
            }
        }
        .animation(.easeOut(duration: 0.25), value: missed || slow)
        .task {
            try? await Task.sleep(for: .seconds(5))
            slow = true
        }
        .onChange(of: model.status, initial: true) { if case .offline = model.status { missed = true } }
    }

    private var mac: String { model.pairing?.name ?? "your Mac" }

    private var details: some View {
        Welcome(title: missed ? "Can't reach \(mac)" : "Connecting to \(mac)", words: words) {
            Panel {
                ForEach(model.routes) { route in
                    HStack(spacing: 14) {
                        Group {
                            switch route.state {
                            case .trying: Spinner().frame(width: 18, height: 18)
                            case .waiting: Circle().fill(.secondary.opacity(0.6)).frame(width: 10, height: 10)
                            case .connected: Circle().fill(.green).frame(width: 10, height: 10)
                            case .missed: Circle().fill(.orange).frame(width: 10, height: 10)
                            }
                        }
                        .frame(width: 20)
                        Text(route.id).font(.body.weight(.semibold))
                        Spacer(minLength: 12)
                        Text(route.detail).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(height: 52)
                }
            }
            // Its room kept while connecting, so nothing moves when it's needed.
            WideButton(title: "Try again", prominent: true) { model.connect() }
                .opacity(missed ? 1 : 0).disabled(!missed)
        } foot: {
            Menu {
                Button("Unpair this phone", role: .destructive) { model.unpair() }
            } label: {
                HStack(spacing: 6) {
                    Text("Paired with \(mac)").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Image("chevron-down-outline").resizable().frame(width: 12, height: 12).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).frame(height: 40)
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var words: String {
        guard missed else { return "Zero on your Mac, through your relay." }
        let seen = model.pairing?.seen.map { "Last connected \($0.formatted(.relative(presentation: .named))). " } ?? ""
        return seen + "Zero needs to be open on your Mac, and the Mac online. Still trying."
    }
}

/// The pairing screens' page: the dots behind, the mark, a title and its words, what the page holds, and a foot.
private struct Welcome<Content: View, Foot: View>: View {
    let title: String
    let words: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let foot: () -> Foot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            DitherBackdrop(animated: false).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 10) {
                    Logo(size: 64).padding(.bottom, 26)
                    Text(title).font(.title.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(words).font(.body).foregroundStyle(scheme == .dark ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(scheme == .dark ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .modifier(Halo(color: scheme == .dark ? .black : .white, strength: scheme == .dark ? 0.25 : 1))
                .padding(.bottom, 32)
                VStack(spacing: 16) { content() }
                Spacer()
                foot()
            }
            .padding(.horizontal, 24).padding(.bottom, 8)
        }
    }
}

/// A card of rows over the dots.
private struct Panel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 20).padding(.vertical, 6)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// A button the page's width: the page's own colour inverted when it's the one to press, glass when it isn't.
private struct WideButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold))
                .foregroundStyle(prominent ? Color(.systemBackground) : .primary)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background { if prominent { Capsule().fill(Color.primary) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(prominent ? .identity : .regular.interactive(), in: Capsule())
    }
}
