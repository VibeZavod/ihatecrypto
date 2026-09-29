import ExecutionCore
import Foundation
import LalaCore
import SwiftUI
import TradeExecution

/// Everything LALA did and everything that happened to the money, on the canvas:
/// «Agent» — each activity with the bubbles it had; «Positions» — each position from open to close, from the exchange;
/// «All» — every fill, transfer, signature and request in one timeline.
struct HistoryView: View {
    @Environment(Workspace.self) private var ws
    @AppStorage("historyTab") private var tab = "agent"
    @State private var fills: [TradeHistory.Fill] = []
    @State private var transfers: [TradeHistory.Transfer] = []
    @State private var journal: [Journal.Entry] = []
    /// Sessions of signatures from before the agent history was kept.
    @State private var earlier: [Activity] = []
    @State private var loading = false
    @State private var loadError: String?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "History", close: close) {
                Picker("", selection: $tab) {
                    Text("Agent").tag("agent")
                    Text("Positions").tag("positions")
                    Text("All").tag("all")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.hoverIcon).help("Refresh")
            }
            if let loadError { Text(loadError).font(.ui(10)).foregroundStyle(Brand.loss).padding(.horizontal, 28) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case "positions": positions
                    case "all": everything
                    default: agent
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 28)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        // Full width: the chat floats above the page, as it does over the canvas.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.canvas)
        .task { await load() }
    }

    // MARK: Agent

    @ViewBuilder private var agent: some View {
        let items = ws.activities.reversed().filter { !$0.lines.isEmpty || !$0.bubbles.isEmpty || $0.request != nil }
        if items.isEmpty, earlier.isEmpty {
            empty("Nothing yet. Every request from now on is kept here with the bubbles it had on the canvas.")
        }
        ForEach(Array(items)) { ActivityCard(activity: $0) }
        if !earlier.isEmpty {
            Label("Earlier — from the signature journal. The chat of that time wasn’t kept; from now on every request is.", systemImage: "clock.arrow.circlepath")
                .font(.ui(10)).foregroundStyle(.secondary).padding(.top, 6)
            ForEach(earlier) { ActivityCard(activity: $0) }
        }
    }

    // MARK: Positions

    @ViewBuilder private var positions: some View {
        let stories = TradeHistory.stories(fills)
        if stories.isEmpty, !loading {
            empty(ws.hlAddress.isEmpty ? "No Hyperliquid address yet." : "No trades on Hyperliquid yet.")
        }
        ForEach(stories) { story in
            StoryCard(story: story, activities: ws.activities.filter { a in
                a.coin == story.coin && a.at >= story.opened.addingTimeInterval(-900) && a.at <= (story.closed ?? .distantFuture).addingTimeInterval(120)
            })
        }
    }

    // MARK: All

    private struct Row: Identifiable {
        let id: String
        let at: Date
        let icon: String
        let tint: Color
        let text: String
        var detail: String?
        var link: URL?
    }

    @ViewBuilder private var everything: some View {
        let rows = allRows()
        if rows.isEmpty, !loading { empty("Nothing yet.") }
        ForEach(rows) { r in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Fmt.date(r.at)).font(.ui(10)).monospacedDigit().foregroundStyle(.secondary).frame(width: 118, alignment: .leading)
                Image(systemName: r.icon).foregroundStyle(r.tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.text).font(.ui(13))
                    if let d = r.detail { Text(ChatText.styled(d)).font(.ui(10)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                if let link = r.link { Link(destination: link) { Image(systemName: "arrow.up.right.square") }.help(link.absoluteString) }
            }
            .padding(.vertical, 6)
            Divider()
        }
    }

    private func allRows() -> [Row] {
        var rows: [Row] = []
        for a in ws.activities {
            if let q = a.request { rows.append(Row(id: "q\(a.id)", at: a.at, icon: "person.fill", tint: Brand.accent, text: "You: “\(q)”", detail: a.lines.first)) }
            else if let t = a.title { rows.append(Row(id: "a\(a.id)", at: a.at, icon: a.kind == .execution ? "signature" : "gearshape.2", tint: Brand.accent, text: t, detail: a.lines.last)) }
        }
        for f in fills {
            let pnl = f.closedPnl != 0 ? " · \(signed(f.closedPnl))" : ""
            rows.append(Row(id: "f\(f.time.timeIntervalSince1970)\(f.coin)\(f.dir)", at: f.time, icon: f.dir.hasPrefix("Open") ? "arrow.up.right.circle" : "arrow.down.left.circle",
                            tint: f.closedPnl < 0 ? Brand.loss : Brand.profit,
                            text: "\(f.dir) \(IntentParser.pretty(f.coin)) \(Fmt.num(f.sz, maxFraction: 6)) at \(Fmt.price(f.px))\(pnl)",
                            detail: "fee \(Fmt.usd(f.fee))",
                            link: f.hash.flatMap { URL(string: "https://app.hyperliquid.xyz/explorer/tx/\($0)") }))
        }
        for t in transfers {
            rows.append(Row(id: "t\(t.id)", at: t.time, icon: t.amount > 0 ? "arrow.down.circle" : t.amount < 0 ? "arrow.up.circle" : "arrow.left.arrow.right.circle",
                            tint: .secondary, text: t.text))
        }
        for e in journal where e.kind == .signed || e.kind == .settled || e.kind == .failed {
            let link: URL? = switch e.chain {
            case "solana": URL(string: "https://solscan.io/tx/\(e.id)")
            case "relay": URL(string: "https://relay.link/transaction/\(e.id)")
            default: nil
            }
            rows.append(Row(id: "j\(e.at.timeIntervalSince1970)\(e.id)\(e.kind.rawValue)", at: e.at, icon: e.kind == .failed ? "xmark.octagon" : "signature",
                            tint: e.kind == .failed ? Brand.loss : .secondary,
                            text: "\(e.kind == .settled ? "Settled" : e.kind == .failed ? "Failed" : "Signed") · \(e.chain.capitalized): \(Self.english(e.note))", link: link))
        }
        return rows.sorted { $0.at > $1.at }.prefix(400).map { $0 }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.ui(12)).foregroundStyle(.secondary)
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).strokeBorder(Brand.dots, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }

    // MARK: Data

    private func load() async {
        loading = true
        defer { loading = false }
        loadError = nil
        // Signatures from the app and from the terminal tool, which trades from the same wallet.
        let appJournal = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "LALA/journal.jsonl")
        let cliJournal = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".lala/journal.jsonl")
        journal = [appJournal, cliJournal].flatMap { (try? Journal(url: $0).entries()) ?? [] }
        earlier = Self.sessions(journal, before: ws.activities.first?.at ?? .distantFuture)
        guard !ws.hlAddress.isEmpty else { return }
        do {
            async let f = TradeHistory.fills(user: ws.hlAddress)
            async let t = TradeHistory.transfers(user: ws.hlAddress)
            fills = try await f
            transfers = try await t
        } catch {
            loadError = "Hyperliquid history didn't load: \(error.localizedDescription)"
        }
    }

    /// Signatures grouped into sessions (a pause of 10 minutes starts a new one), newest first; each is an activity whose
    /// bubbles are its signatures with what came of them.
    static func sessions(_ journal: [Journal.Entry], before start: Date) -> [Activity] {
        let outcome = Dictionary(journal.filter { $0.kind != .signed }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var groups: [[Journal.Entry]] = []
        for e in journal.filter({ $0.kind == .signed && $0.at < start }).sorted(by: { $0.at < $1.at }) {
            if let last = groups.last?.last, e.at.timeIntervalSince(last.at) < 600 { groups[groups.count - 1].append(e) } else { groups.append([e]) }
        }
        return groups.reversed().map { group in
            let bubbles = group.map { e in
                let result = outcome[e.id].map { $0.kind == .failed ? "failed: \(english($0.note))" : english($0.note) }
                return ActivityBubble(kind: "signed", label: e.chain.capitalized, title: english(e.note).components(separatedBy: " · valid until").first ?? e.note,
                                      lines: result.flatMap { ["", "ok", "success"].contains($0) ? nil : [$0] } ?? [],
                                      status: outcome[e.id]?.kind == .failed ? "blocked" : "info",
                                      logo: ["solana": "sol", "hyperliquid": "hype", "relay": "relay"][e.chain])
            }
            var titles: [String] = []
            for b in bubbles where !titles.contains(b.title) { titles.append(b.title) }
            return Activity(at: group[0].at, kind: .execution, title: titles.prefix(3).joined(separator: ", ") + (titles.count > 3 ? "…" : ""),
                            bubbles: bubbles, lines: ["\(group.count) signature\(group.count == 1 ? "" : "s") · \(Set(group.map(\.chain.capitalized)).sorted().joined(separator: ", "))"])
        }
    }

    /// Journal notes written before the app switched to English.
    static func english(_ note: String) -> String {
        let words: [(String, String)] = [
            ("плечо", "leverage"), ("вход", "entry"), ("стоп и тейк", "stop and take-profit"), ("отмена ордеров", "cancel orders"),
            ("закрытие", "close"), ("новый стоп", "new stop"), ("снять старый стоп", "remove old stop"), ("частичный тейк", "partial take-profit"),
            ("частичное закрытие", "partial close"), ("новый тейк", "new take-profit"), ("снять старый тейк", "remove old take-profit"),
            ("стоит в стакане", "resting on the book"), ("HLP депозит", "HLP deposit"), ("лимит со стопом и тейком", "limit with stop and take-profit"),
            ("обернуть SOL", "wrap SOL"),
        ]
        if let hit = words.first(where: { note == $0.0 }) { return hit.1 }
        if let m = note.firstMatch(of: /исполнено\s+([\d.]+)\s+по\s+([\d.]+)/) { return "filled \(m.1) at \(m.2)" }
        return note
            .replacingOccurrences(of: "закрыть пустой счёт", with: "close the empty account")
            .replacingOccurrences(of: "закрыть счёт wSOL (SOL развёрнут)", with: "close the wSOL account (SOL unwrapped)")
            .replacingOccurrences(of: "закрыть счёт долей", with: "close the share account")
            .replacingOccurrences(of: "счёт долей", with: "share account")
            .replacingOccurrences(of: "; valid until block", with: " · valid until block")
            .replacingOccurrences(of: "; действует до блока", with: " · valid until block")
    }
}

/// The latest of what LALA did, on the canvas with its bubbles; the whole history is one click away.
struct HistoryBoard: View {
    @Environment(Workspace.self) private var ws
    @AppStorage("canvasMode") private var mode = "plan"

    var body: some View {
        let items = ws.activities.reversed().filter { !$0.lines.isEmpty || !$0.bubbles.isEmpty || $0.request != nil }.prefix(5)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Brand.accentInk).font(.system(size: 16, weight: .semibold))
                Text("History · latest").font(.ui(16, .bold))
                Spacer()
                Button { withAnimation(StudioView.spring) { ws.showHistory = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.hoverIcon).help("Close")
            }
            if let closed = ws.recentlyClosed, !closed.isEmpty {
                ClosedTrades(stories: closed)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Brand.card))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Brand.cardBorder))
            }
            if items.isEmpty {
                Text("Nothing yet. Every request from now on is kept here with the bubbles it had on the canvas.")
                    .font(.ui(12)).foregroundStyle(.secondary)
            }
            ForEach(Array(items)) { ActivityCard(activity: $0) }
            Button { withAnimation(.snappy) { mode = "history" } } label: {
                Label("All history: positions, transfers, signatures", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.borderless).font(.ui(10, .semibold))
        }
        .frame(width: 470, alignment: .leading)
    }
}

/// One activity: the request, how it was understood, the bubbles it had, what LALA said.
struct ActivityCard: View {
    let activity: Activity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Brand.accentInk)
                Text(activity.title ?? (activity.kind == .request ? "Request" : "ihatecrypto")).font(.ui(14, .semibold)).lineLimit(1)
                Spacer()
                Text(Fmt.date(activity.at)).font(.ui(10)).foregroundStyle(.secondary).monospacedDigit()
            }
            if let q = activity.request {
                Text(q).font(.ui(13)).foregroundStyle(Brand.onAccent)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14).fill(Brand.accent))
            }
            if let u = activity.understood {
                Label("understood as “\(u)”", systemImage: "character.bubble").font(.ui(10)).foregroundStyle(.secondary)
            }
            if !activity.bubbles.isEmpty {
                Flow {
                    ForEach(activity.bubbles, id: \.self) { HistoryBubble(bubble: $0) }
                }
            }
            let lines = expanded ? activity.lines : Array(activity.lines.suffix(2))
            ForEach(lines.indices, id: \.self) { i in
                Text(ChatText.styled(lines[i])).font(.ui(10)).foregroundStyle(.secondary).lineLimit(expanded ? nil : 3).textSelection(.enabled)
            }
            if activity.lines.count > 2 {
                Button(expanded ? "Less" : "All \(activity.lines.count) lines") { withAnimation { expanded.toggle() } }
                    .buttonStyle(.borderless).font(.ui(10))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Brand.cardBorder))
    }

    private var icon: String {
        switch activity.kind {
        case .request: "bubble.left.and.text.bubble.right"
        case .execution: "signature"
        case .automatic: "gearshape.2"
        }
    }
}

/// A bubble from the history, drawn like it was on the canvas, a bit smaller.
struct HistoryBubble: View {
    let bubble: ActivityBubble

    var body: some View {
        Group {
            if bubble.kind == "step" {
                RouteCard(step: bubble, state: .plain, width: 210)
            } else if let kind = StudioNode.Kind(rawValue: bubble.kind), !bubble.label.hasPrefix("Chart ·") {
                StudioNodeView(node: StudioNode(id: bubble.title, kind: kind, label: bubble.label, title: bubble.title, lines: Array(bubble.lines.prefix(3)),
                                                status: status, asset: bubble.asset, long: bubble.long ?? true, signature: bubble.signature))
            } else {
                generic
            }
        }
        .frame(idealWidth: 210, maxWidth: 210, alignment: .topLeading)
    }

    private var status: Block.Status {
        switch bubble.status {
        case "ready": .ready
        case "warning": .warning
        case "needsInput": .needsInput
        case "blocked": .blocked
        case "noData": .noData
        default: .info
        }
    }

    private var generic: some View {
        let dark = ["deposit", "result", "position"].contains(bubble.kind)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                if let logo = bubble.logo { TokenLogo(name: logo, size: 20) }
                if !bubble.asset.isEmpty { AssetBadge(coin: bubble.asset, size: 20, dark: true) }
                Text(bubble.label.uppercased()).font(.ui(9.5, .heavy)).tracking(0.5).opacity(0.8)
            }
            Text(bubble.title).font(.ui(14, .bold)).lineLimit(3)
            ForEach(bubble.lines.prefix(2), id: \.self) { Text(ChatText.styled($0)).font(.ui(10)).opacity(0.8).lineLimit(3) }
        }
        .foregroundStyle(dark ? Color.white : Color.primary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(fill))
        .overlay(shape.stroke(bubble.kind == "skipped" ? Brand.dots : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }

    private var shape: AnyShape {
        switch bubble.kind {
        case "deposit": AnyShape(ArrowCard(radius: 18, tip: 12))
        case "skipped", "yield": AnyShape(RoundedRectangle(cornerRadius: 28))
        default: AnyShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    private var fill: Color {
        switch bubble.kind {
        case "free": Brand.solanaTint
        case "deposit": bubble.logo == "jup" ? Color(hex: 0x131D27) : bubble.logo == "kamino" ? Color(hex: 0x082A56) : bubble.logo == "jitosol" ? Color(hex: 0x1F9D6A) : Brand.hl
        case "result": Brand.outcome
        case "position": Brand.hl
        case "skipped": .clear
        default: Brand.card
        }
    }
}

/// A position from the exchange: how it opened, what changed, how it closed and what it made.
struct StoryCard: View {
    let story: TradeHistory.Story
    let activities: [Activity]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AssetBadge(coin: story.coin, size: 34, dark: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(story.long ? "Long" : "Short") \(IntentParser.pretty(story.coin))").font(.ui(16, .heavy)).lineLimit(2)
                    Text(span).font(.ui(10)).foregroundStyle(.secondary)
                }
                Spacer()
                if story.isOpen {
                    StatusChip(text: "open", tint: Brand.accentInk)
                } else {
                    Text(signed(story.realized)).font(.ui(18, .heavy)).monospacedDigit()
                        .foregroundStyle(story.realized < 0 ? Brand.loss : Brand.profit)
                }
            }
            Flow {
                ForEach(events.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 10) {
                        if i > 0 { Image(systemName: "chevron.right").foregroundStyle(.tertiary).padding(.top, 30) }
                        events[i]
                    }
                }
            }
            if !story.isOpen {
                Text("Realized \(signed(story.realized)) after \(Fmt.usd(story.fees)) in fees · peak size \(Fmt.num(story.peakSize, maxFraction: 6))")
                    .font(.ui(10)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Brand.cardBorder))
    }

    /// «Sep 25, 11:47 PM → 11:48 PM»: the day once when both ends share it.
    private var span: String {
        guard let closed = story.closed else { return "\(Fmt.date(story.opened)) · open" }
        return "\(Fmt.date(story.opened)) → \(Calendar.current.isDate(story.opened, inSameDayAs: closed) ? Fmt.time(closed) : Fmt.date(closed))"
    }

    /// Fills and LALA's actions on this position, in time order, as bubbles.
    private var events: [AnyView] {
        var items: [(Date, AnyView)] = story.fills.map { f in
            let open = f.dir.hasPrefix("Open")
            return (f.time, AnyView(HistoryBubble(bubble: ActivityBubble(
                kind: open ? "position" : "result", label: f.dir, title: "\(Fmt.num(f.sz, maxFraction: 6)) at \(Fmt.price(f.px))",
                lines: [Fmt.date(f.time)] + (f.closedPnl != 0 ? [signed(f.closedPnl) + " · fee \(Fmt.usd(f.fee))"] : ["fee \(Fmt.usd(f.fee))"]),
                asset: open ? story.coin : "", long: story.long))))
        }
        items += activities.map { a in
            (a.at, AnyView(HistoryBubble(bubble: ActivityBubble(kind: "choice", label: a.kind == .automatic ? "Guardian" : a.request != nil ? "You asked" : "ihatecrypto",
                                                                 title: a.request ?? a.title ?? "", lines: Array(a.lines.suffix(1))))))
        }
        return items.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

/// A page's top line on the canvas. The title and the way back always stay on one line; when the pane is narrow
/// the controls move under them, and scroll sideways if even that is too tight.
struct PageHeader<Controls: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder let controls: Controls

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                name
                controls
                Spacer(minLength: 12)
                back
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack { name; Spacer(); back }
                // Room for a hovered icon button's lift, which the scroll view would clip; the row stays aligned.
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 10) { controls }.padding(3) }.padding(.horizontal, -3)
            }
        }
        .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 14)
    }

    private var name: some View { Text(title).font(.ui(22, .heavy)).lineLimit(1).fixedSize() }

    private var back: some View {
        Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.hoverIcon).help("Back to the canvas")
    }
}

/// Views left to right, a new line when the next one does not fit.
struct Flow: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(subviews, width: bounds.width)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        return subviews.map { view in
            var size = view.sizeThatFits(.unspecified)
            // Wider than the whole line: it gets the line and grows down instead.
            if size.width > width { size = view.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            defer { x += size.width + spacing; row = max(row, size.height) }
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }
}
