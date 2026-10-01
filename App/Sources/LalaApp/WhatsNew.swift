import SwiftUI

/// «What's new» as stories: a version's cards from WhatsNew/whatsnew.json, the same file release.sh turns into the
/// update window's notes. Nothing opens by itself: after an update an orange ring goes around the rail's logo until the
/// stories are watched; «what's new» in the chat opens them any time.
@Observable
final class WhatsNew {
    static let shared = WhatsNew()

    struct Story: Decodable, Hashable {
        let title: String
        let text: String
        /// A phrase «Try it» puts into the chat's field.
        var `try`: String?
        let symbol: String
        /// The card's colour, hex: the brand's orange or a protocol's.
        let color: String
    }

    struct Release: Decodable {
        let version: String
        let stories: [Story]
    }

    /// Newest first.
    let releases: [Release] = {
        guard let url = Bundle.main.url(forResource: "whatsnew", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Release].self, from: data)) ?? []
    }()
    /// The stories on screen; nil when closed.
    var showing: Release?
    private var seen = UserDefaults.standard.string(forKey: "whatsNewSeen")

    /// This version's stories, not watched yet.
    var unseen: Release? {
        let running = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return releases.first { $0.version == running && $0.version != seen }
    }

    func open() { showing = unseen ?? releases.first }

    func close() {
        if let v = showing?.version, v == unseen?.version {
            seen = v
            UserDefaults.standard.set(v, forKey: "whatsNewSeen")
        }
        showing = nil
    }
}

/// The rail's logo. With this version's stories not watched yet, an orange ring around it opens them.
struct WhatsNewLogo: View {
    var body: some View {
        let news = WhatsNew.shared.unseen
        Button { WhatsNew.shared.open() } label: {
            LalaLogo(size: 30)
                .overlay(Circle().strokeBorder(Brand.accent, lineWidth: 2).padding(-3).opacity(news == nil ? 0 : 1))
        }
        .buttonStyle(.plain)
        // Not .disabled: a disabled button draws the logo faded.
        .allowsHitTesting(news != nil)
        .pointerStyle(news == nil ? nil : .link)
        .help(news.map { "What's new in \($0.version)" } ?? "")
    }
}

/// One card at a time over the dimmed window. Bars on top fill in 6 s and move on; a click on the left third goes back,
/// on the rest forward; ← → step, Space pauses, Esc closes. Cards fade in place (no slides); with Reduce Motion they just
/// switch.
struct StoriesView: View {
    let release: WhatsNew.Release
    /// «Try it»: the phrase goes into the chat's field.
    let tryIt: (String) -> Void
    @State private var index = 0
    /// Time watched on this card before the last pause; the clock runs from `resumed`.
    @State private var watched: TimeInterval = 0
    @State private var resumed = Date()
    @State private var paused = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let duration: TimeInterval = 6

    private var story: WhatsNew.Story { release.stories[index] }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { WhatsNew.shared.close() }
            card
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onKeyPress(.space) { pause(!paused); return .handled }
        .onKeyPress(.escape) { WhatsNew.shared.close(); return .handled }
        // Moves on when the card's time is up; a pause or a new card starts the wait again.
        .task(id: "\(index) \(paused)") {
            guard !paused else { return }
            try? await Task.sleep(for: .seconds(max(0, Self.duration - watched)))
            if !Task.isCancelled { go(1) }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color(hex: UInt32(story.color, radix: 16) ?? 0xFF7A2F)
                Image(systemName: story.symbol).font(.system(size: 76, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(index).transition(.opacity)
                // Back on the left third, forward on the rest.
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).frame(width: 126).onTapGesture { go(-1) }
                    Color.clear.contentShape(Rectangle()).onTapGesture { go(1) }
                }
                VStack(spacing: 10) {
                    bars
                    HStack {
                        Text("What's new in \(release.version)").font(.ui(12, .semibold)).foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Button { WhatsNew.shared.close() } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 28, height: 28).background(Circle().fill(.black.opacity(0.2)))
                        }
                        .buttonStyle(.plain).pointerStyle(.link).help("Close · Esc")
                    }
                }
                .padding(14)
            }
            .frame(height: 300)
            VStack(alignment: .leading, spacing: 8) {
                Text(story.title).font(.ui(22, .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(story.text).font(.ui(14)).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                HStack {
                    if let phrase = story.try {
                        Button { tryIt(phrase); WhatsNew.shared.close() } label: {
                            Label("Try it", systemImage: "text.cursor").font(.ui(13, .semibold)).foregroundStyle(Brand.onAccent)
                                .padding(.horizontal, 14).padding(.vertical, 8).background(Capsule().fill(Brand.accent))
                        }
                        .buttonStyle(.plain).pointerStyle(.link).help("Puts «\(phrase)» into the chat")
                    }
                    Spacer()
                    Text("\(index + 1) of \(release.stories.count)").font(.ui(11)).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .padding(20)
            .frame(maxHeight: .infinity, alignment: .top)
            .id(index).transition(.opacity)
        }
        .frame(width: 380, height: 560)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Brand.cardBorder))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 18)
    }

    /// One bar per card: past ones full, this one filling (a paused one holds), the rest empty.
    private var bars: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { context in
            let now = paused ? 0 : context.date.timeIntervalSince(resumed)
            let part = min(1, (watched + now) / Self.duration)
            HStack(spacing: 4) {
                ForEach(release.stories.indices, id: \.self) { i in
                    GeometryReader { g in
                        Capsule().fill(.white.opacity(0.35))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white).frame(width: g.size.width * (i < index ? 1 : i == index ? part : 0))
                            }
                    }
                    .frame(height: 3)
                }
            }
        }
    }

    private func go(_ step: Int) {
        let next = index + step
        guard release.stories.indices.contains(next) else {
            if step > 0 { WhatsNew.shared.close() } else { watched = 0; resumed = Date() }
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { index = next }
        watched = 0
        resumed = Date()
        paused = false
    }

    private func pause(_ on: Bool) {
        guard on != paused else { return }
        if on { watched += Date().timeIntervalSince(resumed) } else { resumed = Date() }
        paused = on
    }
}
