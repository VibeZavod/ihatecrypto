import AppKit
import DeFiYields
import LalaCore
import LLMCatalog
import LLMCore
import SwiftUI
import TradeExecution

// «Студия» (R4 on the design canvas): the wallet rail on the left, the portfolio and the plan on one canvas,
// the chat floating on top of it. The classic layout (chat + route) stays behind a switch in the profile menu.

extension Color {
    /// One color for light and one for dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
    init(hex: UInt32) { self.init(light: hex, dark: hex) }
}

/// The chains' and protocols' own colors, so a block reads as «Solana» or «Hyperliquid» before its text does.
enum Brand {
    static let accent = Color(hex: 0x2F5BFF)
    static let canvas = Color(light: 0xF3F4F7, dark: 0x101216)
    static let dots = Color(light: 0xD3D8E3, dark: 0x2A2D33)
    static let card = Color(light: 0xFFFFFF, dark: 0x1B1E24)
    static let cardBorder = Color(light: 0xE1E4EC, dark: 0x2C3038)
    static let solanaTint = Color(light: 0xF4ECFF, dark: 0x2A2140)
    static let solanaInk = Color(light: 0x5B3AA8, dark: 0xC9B3FF)
    static let relay = Color(hex: 0x4615C8)
    static let relayInk = Color(hex: 0xDCD0FF)
    static let hl = Color(hex: 0x072723)
    static let hlChip = Color(hex: 0x0D3B35)
    static let hlMint = Color(hex: 0x97FCE4)
    static let hlSoft = Color(hex: 0xB6E8DC)
    static let jupiterTint = Color(light: 0xEEF8E0, dark: 0x1E2A16)
    static let jupiterInk = Color(light: 0x3D6B12, dark: 0xC7F284)
    static let riskTint = Color(light: 0xF3EDFF, dark: 0x241F36)
    static let riskInk = Color(light: 0x5B3AA8, dark: 0xC9B3FF)
    static let blockedTint = Color(light: 0xFDECEA, dark: 0x3A1D1A)
    static let blockedInk = Color(light: 0xB42318, dark: 0xFF9C8F)
    static let jevTint = Color(light: 0xFFF7E6, dark: 0x33290F)
    static let jevInk = Color(light: 0x7A4A0C, dark: 0xF5C451)
    static let outcome = Color(light: 0x0F1222, dark: 0x2A2E3A)
    static let profit = Color(light: 0x0B7A55, dark: 0x6FF0B4)
    static let loss = Color(light: 0xB42318, dark: 0xFF9C8F)
    static let secondCursor = Color(hex: 0x7C3AED)
    static let jevCursor = Color(hex: 0xF59E0B)
}

/// A chain or token logo from the app bundle (Logos/); a lettered circle when the file is missing (`swift run`).
struct TokenLogo: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        if let (color, sign) = Self.drawn[name] {
            Circle().fill(Color(hex: color)).frame(width: size, height: size)
                .overlay(Text(sign).font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(.white))
        } else if name == "hype" {
            RoundedRectangle(cornerRadius: size * 0.3).fill(Brand.hl).frame(width: size, height: size)
                .overlay(logo(size: size * 0.72))
        } else {
            logo(size: size)
        }
    }

    @ViewBuilder private func logo(size: CGFloat) -> some View {
        if let image = Self.image(name) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.28))
        } else {
            Circle().fill(.quaternary).frame(width: size, height: size)
                .overlay(Text(name.prefix(1).uppercased()).font(.system(size: size * 0.45, weight: .bold)))
        }
    }

    /// Chains without a bundled image: their color and sign.
    /// Chains without a bundled image (Base, Aave and Robinhood have theirs in Logos/).
    static let drawn: [String: (UInt32, String)] = ["eth": (0x627EEA, "Ξ"), "arb": (0x28A0F0, "A")]
    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        for ext in ["png", "svg"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext), let image = NSImage(contentsOf: url) {
                cache[name] = image
                return image
            }
        }
        return nil
    }

    /// The logo for a traded asset; nil for assets that have none (oil, stocks).
    /// By ticker: «xrp.png», «tsla.png» (HIP-3 «xyz:TSLA» too) when bundled, ETH drawn; nil when there's none.
    static func name(forAsset coin: String) -> String? {
        let ticker = (coin.split(separator: ":").last.map(String.init) ?? coin).lowercased()
        return drawn[ticker] != nil || image(ticker) != nil ? ticker : nil
    }
}

struct StudioView: View {
    @Environment(Workspace.self) private var ws
    /// Full-height chat; by default it sits compact on the lower half and grows on demand.
    @AppStorage("chatFull") private var chatOpen = false
    /// «plan» — the canvas; «history» — everything that happened.
    @AppStorage("canvasMode") private var mode = "plan"
    /// The chat's width, set by dragging its left edge: from a column up to half the window.
    @AppStorage("chatWidth") private var chatWidth = 350.0
    /// The width while the edge is being dragged; nil when resting.
    @State private var resizing: CGFloat?
    @State private var edgeHover = false
    /// Where the chat sits, as an offset from its docked corner (bottom right); both ≤ 0.
    @AppStorage("chatX") private var chatX = 0.0
    @AppStorage("chatY") private var chatY = 0.0
    /// The header's pull while the chat is being moved.
    @State private var moving: CGSize = .zero
    @AppStorage("railCollapsed") private var railCollapsed = true
    @State private var railFoldedForRoom = false
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let minChat: CGFloat = 320
    /// Below this window width the wide rail (280) and the chat (350) would leave the canvas too little room.
    static let crampedWidth: CGFloat = 1140

    /// Keeps the chat inside the canvas: offsets from the docked corner, never past the left or top edge.
    static func clamp(_ s: CGSize, room: CGSize) -> CGSize {
        CGSize(width: min(0, max(-room.width, s.width)), height: min(0, max(-room.height, s.height)))
    }

    var body: some View {
        HStack(spacing: 0) {
            StudioRail()
            GeometryReader { geo in
                let maxWidth = max(Self.minChat, geo.size.width / 2)
                let width = min(resizing ?? CGFloat(chatWidth), maxWidth)
                // Full height, or compact (half the window); the header moves the chat anywhere inside the canvas.
                let full = max(200, geo.size.height - 32)
                let small = min(full, max(260, geo.size.height * 0.5))
                let height = chatOpen ? full : small
                let room = CGSize(width: max(0, geo.size.width - width - 32), height: max(0, geo.size.height - height - 32))
                let place = Self.clamp(CGSize(width: chatX + moving.width, height: chatY + moving.height), room: room)
                // Docked, the canvas keeps clear of the chat; moved away, the chat floats over it.
                let docked = place.width > -40 && place.height > -40
                ZStack(alignment: .topTrailing) {
                    if mode == "history" {
                        HistoryView(inset: docked ? width + 32 : 0) { withAnimation(.snappy) { mode = "plan" } }
                    } else if mode == "book" {
                        AddressBookView(inset: docked ? width + 32 : 0) { withAnimation(.snappy) { mode = "plan" } }
                    } else {
                        StudioCanvas(inset: docked ? width + 32 : 0)
                    }
                    FloatingChat(
                        compact: !chatOpen,
                        wide: width >= maxWidth - 1,
                        toggleCompact: { withAnimation(Self.spring) { chatOpen.toggle() } },
                        toggleWide: { withAnimation(Self.spring) { chatWidth = width >= maxWidth - 1 ? 350 : Double(maxWidth) } },
                        drag: $moving,
                        endDrag: { pull in
                            let end = Self.clamp(CGSize(width: chatX + pull.width, height: chatY + pull.height), room: room)
                            // Close to its corner it snaps home.
                            let home = end.width > -40 && end.height > -40
                            chatX = home ? 0 : end.width
                            chatY = home ? 0 : end.height
                            moving = .zero
                        },
                        dock: { chatX = 0; chatY = 0 }
                    )
                    .frame(width: width, height: height)
                    .overlay(alignment: .leading) { edge(width: width, maxWidth: maxWidth) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ws.chatFrame = $0 }
                    .shadow(color: .black.opacity(docked ? 0 : 0.22), radius: 26, y: 16)
                    .offset(place)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                // @AppStorage changes skip withAnimation, so the spring is tied to the values themselves.
                .animation(Self.spring, value: chatOpen)
                .animation(Self.spring, value: chatX)
                .animation(Self.spring, value: chatY)
            }
        }
        // A window getting narrow folds the rail, and widening again brings back what it folded; by hand it still opens.
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.crampedWidth } action: { cramped in
            withAnimation(Self.spring) {
                if cramped, !railCollapsed { railCollapsed = true; railFoldedForRoom = true }
                else if !cramped, railFoldedForRoom { railCollapsed = false; railFoldedForRoom = false }
            }
        }
        .sheet(isPresented: Binding(get: { ws.preparing || ws.prepared != nil || (ws.executionError != nil && !ws.executing) },
                                    set: { if !$0 { ws.prepared = nil; ws.executionError = nil } })) {
            ConfirmSheet().environment(ws)
        }
    }

    /// The chat's left edge: drag to widen up to half the window, double-click to switch between narrow and half.
    private func edge(width: CGFloat, maxWidth: CGFloat) -> some View {
        Capsule().fill(edgeHover || resizing != nil ? Brand.accent.opacity(0.7) : .clear)
            .frame(width: 4, height: 56)
            .frame(width: 14)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .offset(x: -7)
            .onHover { inside in
                edgeHover = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in resizing = min(maxWidth, max(Self.minChat, CGFloat(chatWidth) - v.translation.width)) }
                .onEnded { _ in
                    if let r = resizing { chatWidth = Double(r) }
                    resizing = nil
                })
            .onTapGesture(count: 2) { withAnimation(Self.spring) { chatWidth = width >= maxWidth - 1 ? 350 : Double(maxWidth) } }
            .help("Drag to resize the chat · double-click: half the window")
    }
}

// MARK: Rail

struct StudioRail: View {
    @Environment(Workspace.self) private var ws
    @AppStorage("railCollapsed") private var collapsed = true
    /// The width while the edge is being dragged; nil when resting.
    @State private var dragWidth: CGFloat?
    @State private var edgeHover = false
    @State private var canvasesOpen = false
    @State private var balanceHover = false
    static let narrowWidth: CGFloat = 76, wideWidth: CGFloat = 280

    private var width: CGFloat { dragWidth ?? (collapsed ? Self.narrowWidth : Self.wideWidth) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Past the middle the wide rail shows; below it, the strip. Both fade and slide into place.
            if width < 170 {
                narrow.frame(width: Self.narrowWidth)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            } else {
                wide.frame(width: max(width, 220))
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .animation(StudioView.spring, value: collapsed)
        .background(Brand.card)
        .overlay(alignment: .trailing) {
            // The edge: drag to collapse or expand; a spring settles it on the nearer width.
            Rectangle().fill(edgeHover || dragWidth != nil ? Brand.accent.opacity(0.6) : Brand.cardBorder)
                .frame(width: edgeHover || dragWidth != nil ? 3 : 1)
                .frame(width: 10)
                .contentShape(Rectangle())
                .onHover { inside in
                    edgeHover = inside
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { v in
                        let base = collapsed ? Self.narrowWidth : Self.wideWidth
                        withAnimation(.interactiveSpring) { dragWidth = min(340, max(Self.narrowWidth, base + v.translation.width)) }
                    }
                    .onEnded { v in
                        let base = collapsed ? Self.narrowWidth : Self.wideWidth
                        let landing = base + v.predictedEndTranslation.width
                        withAnimation(StudioView.spring) {
                            collapsed = landing < (Self.narrowWidth + Self.wideWidth) / 2
                            dragWidth = nil
                        }
                    })
                .help("Drag to collapse or expand the wallet")
        }
    }

    private var wide: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                LalaLogo(size: 34)
                Text("lala").font(.system(size: 20, weight: .heavy)).tracking(-0.5)
                Spacer()
                HistoryButton()
                BookButton()
                Button { withAnimation(StudioView.spring) { collapsed = true } } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.hoverIcon).help("Collapse wallet")
            }
            // Everything between the header and the profile scrolls as one: balances, positions, closed trades,
            // favorites and canvases, however many there are.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Balance").font(.caption).foregroundStyle(.secondary)
                            BalanceFreshness(hovering: balanceHover)
                            Spacer()
                            Button { withAnimation(StudioView.spring) { ws.showReceive.toggle(); if ws.showReceive { UserDefaults.standard.set("plan", forKey: "canvasMode") } } } label: {
                                Label("Top up", systemImage: "arrow.down.circle.fill").font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderless).help("Your addresses: where to send money into LALA")
                        }
                        Text(ws.equity.map(Fmt.usd) ?? "—").font(.system(size: 34, weight: .bold)).monospacedDigit().tracking(-1)
                        if !ws.positions.isEmpty {
                            Text("\(signed(ws.positionsPnl)) in positions").font(.caption.weight(.semibold))
                                .foregroundStyle(ws.positionsPnl < 0 ? Brand.loss : Brand.profit)
                        }
                    }
                    .onHover { balanceHover = $0 }
                    VStack(spacing: 2) {
                        account("solana", logo: "sol", name: "Solana", value: ws.solana.map { "\(Fmt.num($0.usdc)) USDC" } ?? "—")
                        account("hyperliquid", logo: "hype", name: "Hyperliquid", value: ws.hlTotal.map(Fmt.usd) ?? "—")
                        if ws.lendTotal > 0 {
                            account("jupiter", logo: "jup", name: "Jupiter Lend", value: "\(Fmt.num(ws.lendTotal)) USDC")
                        }
                        if ws.kamino > 0 {
                            account("kamino", logo: "kamino", name: "Kamino", value: Fmt.usd(ws.kamino))
                        }
                        if ws.near > 0 {
                            account("near", logo: "near", name: "NEAR", value: "\(Fmt.num(ws.near, maxFraction: 4)) NEAR")
                        }
                        if let b = ws.base, b.aave + b.usdc > 0 {
                            account("aave", logo: "aave", name: "Aave · Base", value: "\(Fmt.num(b.aave + b.usdc)) USDC")
                        }
                        if ws.robinhoodTotal > 0 {
                            account("robinhood", logo: "robinhood", name: "Robinhood Chain", value: Fmt.usd(ws.robinhoodTotal))
                        }
                    }
                    if !ws.positions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Positions · Hyperliquid").font(.caption).foregroundStyle(.secondary)
                            ForEach(ws.positions, id: \.coin) { p in
                                Button { Task { await ws.chartCommand(.chart(coin: p.coin, range: .day)) } } label: { PositionChip(position: p) }
                                    .buttonStyle(.plain).pointerStyle(.link).help("Open the \(IntentParser.pretty(p.coin)) chart")
                            }
                        }
                    }
                    if let closed = ws.recentlyClosed, !closed.isEmpty {
                        ClosedTrades(stories: closed)
                    }
                    FavoriteChips()
                    CanvasList(scrolls: false)
                }
            }
            .scrollIndicators(.never)
            ProfileMenu(compact: false)
        }
        .padding(18)
    }

    private var narrow: some View {
        VStack(spacing: 14) {
            LalaLogo(size: 38)
            Button { withAnimation(StudioView.spring) { collapsed = false } } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.hoverIcon).help("Expand wallet")
            HistoryButton()
            BookButton()
            Button { withAnimation(StudioView.spring) { ws.showReceive.toggle(); if ws.showReceive { UserDefaults.standard.set("plan", forKey: "canvasMode") } } } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.hoverIcon).help("Top up: your addresses")
            Button { withAnimation(StudioView.spring) { ws.newCanvas() } } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.hoverIcon).help("New canvas").disabled(ws.busy)
            Button { canvasesOpen.toggle() } label: { Image(systemName: "rectangle.stack") }
                .buttonStyle(.hoverIcon).help("Canvases")
                .popover(isPresented: $canvasesOpen, arrowEdge: .trailing) {
                    CanvasList { canvasesOpen = false }.frame(width: 280, height: 380).padding(14)
                }
            // The balances and positions scroll when the window is too low for all of them.
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 1) {
                        Text(ws.equity.map(Fmt.usd) ?? "—").font(.system(size: 12, weight: .heavy)).monospacedDigit()
                        if !ws.positions.isEmpty {
                            Text(signed(ws.positionsPnl)).font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(ws.positionsPnl < 0 ? Brand.loss : Brand.profit)
                        }
                    }
                    Divider().frame(width: 36)
                    icon("sol", ws.solana.map { Fmt.num($0.usdc) } ?? "—", help: "Solana, USDC").onTapGesture { ws.toggleDetail("solana") }
                    icon("hype", ws.hlTotal.map(Fmt.usd) ?? "—", help: "Hyperliquid").onTapGesture { ws.toggleDetail("hyperliquid") }
                    if ws.lendTotal > 0 { icon("jup", Fmt.num(ws.lendTotal), help: "Jupiter Lend, USDC").onTapGesture { ws.toggleDetail("jupiter") } }
                    if ws.kamino > 0 { icon("kamino", Fmt.usd(ws.kamino), help: "Kamino Lend").onTapGesture { ws.toggleDetail("kamino") } }
                    if ws.near > 0 { icon("near", Fmt.num(ws.near, maxFraction: 3), help: "NEAR on the NEAR chain").onTapGesture { ws.toggleDetail("near") } }
                    if let b = ws.base, b.aave + b.usdc > 0 { icon("aave", Fmt.num(b.aave + b.usdc), help: "Aave on Base, USDC").onTapGesture { ws.toggleDetail("aave") } }
                    if !ws.positions.isEmpty {
                        Divider().frame(width: 36)
                        ForEach(ws.positions, id: \.coin) { p in
                            VStack(spacing: 3) {
                                AssetBadge(coin: p.coin, size: 34, dark: true)
                                Text(signed(p.unrealizedPnl)).font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(p.unrealizedPnl < 0 ? Brand.loss : Brand.profit)
                            }
                            .help("\(p.size > 0 ? "Long" : "Short") \(IntentParser.pretty(p.coin))")
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            ProfileMenu(compact: true)
        }
        .padding(.vertical, 16)
    }

    /// A place in the rail: a click opens its details on the canvas, the open one is highlighted.
    private func account(_ place: String, logo: String, name: String, value: String) -> some View {
        Button { ws.toggleDetail(place) } label: {
            HStack(spacing: 10) {
                TokenLogo(name: logo, size: 28)
                Text(name).font(.system(size: 13))
                Spacer()
                Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(ws.detail == place ? Brand.accent.opacity(0.14) : place == "solana" ? Brand.solanaTint : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Details: \(name)")
    }

    private func icon(_ logo: String, _ value: String, help: String) -> some View {
        VStack(spacing: 3) {
            TokenLogo(name: logo, size: 34)
            Text(value).font(.system(size: 10, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.vertical, 4)
        .frame(width: 66)
        .modifier(HoverLift())
        .contentShape(Rectangle())
        .help(help)
    }
}

/// «+$0,48» / «−$0,25».
func signed(_ d: Decimal) -> String { d < 0 ? Fmt.usd(d) : "+" + Fmt.usd(d) }

/// «l·l·»: two tall strokes and two dots on the baseline, read as "la la" and as a tiny bar chart.
struct LalaLogo: View {
    var size: CGFloat = 34

    var body: some View {
        Canvas { context, s in
            let k = s.width / 36
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: s), cornerRadius: 11 * k, style: .continuous), with: .color(Color(hex: 0x16161A)))
            let w = 4.6 * k, gap = 2.4 * k, baseline = 27 * k
            let colors = [Color.white, Color(hex: 0x97FCE4), Color.white, Color(hex: 0xC7A6FF)]
            for (i, color) in colors.enumerated() {
                let h = i.isMultiple(of: 2) ? 19 * k : w
                let rect = CGRect(x: 5.2 * k + CGFloat(i) * (w + gap), y: baseline - h, width: w, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: w / 2), with: .color(color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("LALA")
    }
}

/// The asset of a position: its logo, or a drawn sign for oil and other HIP-3 markets.
struct AssetBadge: View {
    let coin: String
    var size: CGFloat = 30
    var dark = false

    var body: some View {
        if let logo = TokenLogo.name(forAsset: coin) {
            TokenLogo(name: logo, size: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.3).fill(dark ? Brand.hl : Brand.hlChip).frame(width: size, height: size)
                .overlay(Image(systemName: Self.sign(coin)).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(Self.tint(coin)))
        }
    }
}

extension AssetBadge {
    /// Markets without a brand: oil a drop, metals a bar, indices bars, anything else a chart line.
    static func sign(_ coin: String) -> String {
        let t = coin.split(separator: ":").last.map(String.init)?.uppercased() ?? coin
        if ["CL", "BRENTOIL", "NATGAS"].contains(t) { return t == "NATGAS" ? "flame.fill" : "drop.fill" }
        if ["GOLD", "SILVER", "PLATINUM", "PALLADIUM", "COPPER"].contains(t) { return "rectangle.stack.fill" }
        if t.contains("500") || t.contains("100") || t.hasPrefix("SOX") { return "chart.bar.fill" }
        return "chart.line.uptrend.xyaxis"
    }

    static func tint(_ coin: String) -> Color {
        switch coin.split(separator: ":").last.map(String.init)?.uppercased() ?? coin {
        case "GOLD": Color(hex: 0xF5C542)
        case "SILVER", "PLATINUM", "PALLADIUM": Color(hex: 0xD9DEE7)
        case "COPPER": Color(hex: 0xE08A5A)
        default: Brand.hlMint
        }
    }
}

struct PositionChip: View {
    @Environment(Workspace.self) private var ws
    let position: HyperliquidAccount.Position

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                AssetBadge(coin: position.coin, size: 22)
                Text("\(position.size > 0 ? "Long" : "Short") \(IntentParser.pretty(position.coin))").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(signed(position.unrealizedPnl)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                    .foregroundStyle(position.unrealizedPnl < 0 ? Color(hex: 0xFF9C8F) : Brand.hlMint)
            }
            Text(ws.positionSummary(position)).font(.caption2).foregroundStyle(Brand.hlSoft).lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.hl))
    }
}

/// Positions closed in the last week with their result after fees; a click opens them in the history.
struct ClosedTrades: View {
    let stories: [TradeHistory.Story]

    var body: some View {
        let total = stories.reduce(Decimal(0)) { $0 + $1.realized }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Closed · 7 days").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(signed(total)).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(total < 0 ? Brand.loss : Brand.profit)
            }
            ForEach(stories.prefix(3)) { s in
                Button {
                    UserDefaults.standard.set("positions", forKey: "historyTab")
                    withAnimation(.snappy) { UserDefaults.standard.set("history", forKey: "canvasMode") }
                } label: {
                    HStack(spacing: 8) {
                        AssetBadge(coin: s.coin, size: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(s.long ? "Long" : "Short") \(IntentParser.pretty(s.coin))").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(s.closed.map(Fmt.date) ?? "").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(signed(s.realized)).font(.system(size: 12, weight: .bold)).monospacedDigit()
                            .foregroundStyle(s.realized < 0 ? Brand.loss : Brand.profit)
                    }
                    .padding(.vertical, 3).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerStyle(.link).help("Open in History → Positions")
            }
            if stories.count > 3 {
                Text("+\(stories.count - 3) more in History").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Who is signed in and where settings are: the rail's bottom corner. Opens LALA's own menu (S14).
struct ProfileMenu: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage("layout") private var layout = "studio"
    @State private var open = false
    @State private var confirmSignOut = false
    let compact: Bool

    var body: some View {
        Button { open.toggle() } label: {
            if compact {
                avatar
            } else {
                HStack(spacing: 10) {
                    avatar
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Profile").font(.system(size: 13, weight: .semibold))
                        Text(signedIn).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Brand.cardBorder))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help("Profile, settings, sign out")
        .popover(isPresented: $open, arrowEdge: compact ? .trailing : .top) { menu }
        .confirmationDialog("Sign out of \(ws.provider.info.name)?", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) { ws.setCredential(nil) }
        } message: {
            Text("The chat stops using the model until you sign in again. Your wallet key stays in secure storage.")
        }
    }

    private var signedIn: String { ws.credential == nil ? "no model connected" : "signed in with \(ws.provider.info.name)" }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text("Profile").font(.system(size: 14, weight: .bold))
                    Text("\(signedIn) · wallet \(ws.signerWallet == nil ? "not on this Mac yet" : "on this Mac")")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            Divider().padding(.vertical, 4)
            MenuRow(title: "Settings", icon: "gearshape", shortcut: "⌘,") { go { openSettings() } }
            MenuRow(title: "Models and sign-ins", detail: "\(ws.provider.info.name) · \(ws.model)", icon: "sparkles") { go { openSettings() } }
            MenuRow(title: "Key and signing", detail: ws.signerWallet == nil ? "import a wallet" : "Touch ID, key in a separate process", icon: "key") { go { openWindow(id: "import") } }
            MenuRow(title: "Risk rules", detail: "at most \(Fmt.pct(ws.policy.maxRiskPct)) per trade", icon: "shield.lefthalf.filled") { go { openSettings() } }
            MenuRow(title: "dApp browser", icon: "globe") { go { openWindow(id: "browser") } }
            MenuRow(title: "Layout: classic", detail: "chat beside the route", icon: "rectangle.split.2x1") { go { layout = "classic" } }
            Divider().padding(.vertical, 4)
            if ws.signerWallet != nil {
                MenuRow(title: "Lock — Touch ID again", detail: "the next signature asks; the trading key pauses", icon: "lock") {
                    go { Task { await ws.lockSigner() } }
                }
                if ws.agentAddress != nil, !ws.agentActive {
                    MenuRow(title: "Resume the trading key", detail: "orders without Touch ID · asks Touch ID once", icon: "key.horizontal") {
                        go { Task { await ws.resumeTradingKey() } }
                    }
                }
            }
            MenuRow(title: "Sign out of \(ws.provider.info.name)", detail: "the wallet key stays in secure storage", icon: "rectangle.portrait.and.arrow.right", tint: Brand.loss) {
                go { confirmSignOut = true }
            }
            .disabled(ws.credential == nil)
            .opacity(ws.credential == nil ? 0.5 : 1)
        }
        .padding(8)
        .frame(width: 290)
    }

    private func go(_ action: () -> Void) {
        open = false
        action()
    }

    private var avatar: some View {
        Circle().fill(Brand.accent.opacity(0.14)).frame(width: 36, height: 36)
            .overlay(Image(systemName: "person.fill").foregroundStyle(Brand.accent))
    }
}

// MARK: Canvas

/// The portfolio frame and the plan beside it; LALA AI's cursor places the blocks one by one.
struct StudioCanvas: View {
    @Environment(Workspace.self) private var ws
    /// Width covered by the floating chat on the right; the content is scaled to fit left of it.
    var inset: CGFloat = 0
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    /// A trackpad pinch in progress, and the point between the fingers that stays put.
    @GestureState private var pinch: CGFloat = 1
    @State private var pinchAt: CGPoint = .zero
    /// Two-finger scrolling pans the canvas while the pointer is over it (not over the chat).
    @State private var hovering = false
    @State private var pointer: CGPoint = .zero
    @State private var scrollMonitor: Any?
    static let zoomRange: ClosedRange<CGFloat> = 0.4...2.5
    @State private var frames: [String: CGRect] = [:]
    /// How many plan blocks are on the canvas; grows one by one when a new plan arrives.
    @State private var shown = 0
    @State private var assembling = false

    /// Portfolio frame + gap + plan + leading padding.
    private static let contentWidth: CGFloat = 28 + 270 + 36 + 470 + 24

    var body: some View {
        GeometryReader { geo in
            let fit = min(1, max(0.55, (geo.size.width - inset) / Self.contentWidth))
            canvas(scale: fit * zoom)
        }
    }

    private func canvas(scale base: CGFloat) -> some View {
        // Zooming about a point P keeps it still: the offset becomes P − (P − pan)·k.
        let k = Self.zoomRange.clamped(zoom * pinch) / zoom
        let scale = base * k
        let live = CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
        let moved = CanvasZoom.pan(keeping: (pinchAt.x, pinchAt.y), from: (live.width, live.height), by: k)
        let shown = CGSize(width: moved.x, height: moved.y)
        return ZStack(alignment: .topLeading) {
            Brand.canvas
            Canvas { context, size in
                for x in stride(from: CGFloat(11), through: size.width, by: 22) {
                    for y in stride(from: CGFloat(11), through: size.height, by: 22) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(Brand.dots))
                    }
                }
            }
            .accessibilityHidden(true)

            content
                .scaleEffect(scale, anchor: .topLeading)
                .offset(shown)
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 6)
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in pan.width += value.translation.width; pan.height += value.translation.height })
        // Pinch with two fingers: in and out around the point between them.
        .simultaneousGesture(MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onChanged { value in pinchAt = value.startLocation }
            .onEnded { value in zoomAbout(value.startLocation, by: value.magnification) })
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hovering = true; pointer = p
            case .ended: hovering = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lalaCanvasZoom)) { note in
            if let f = note.userInfo?["factor"] as? CGFloat { zoomAbout(pointer, by: f) }
        }
        .onAppear(perform: watchScrolling)
        .onDisappear { if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil } }
        .overlay(alignment: .bottomLeading) { zoomBar(scale).padding(18) }
        .task(id: planKey) { await assemble() }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 36) {
            StudioPortfolio(onFrame: record)
            plan.frame(width: 470, alignment: .topLeading)
        }
        .padding(.leading, 28).padding(.top, 24)
        // Full height even when the canvas is shorter: blocks never squeeze their text; drag to see the rest.
        .fixedSize(horizontal: false, vertical: true)
        .coordinateSpace(.named("studio"))
        .backgroundPreferenceValue(EmptyPreferenceKey.self) { _ in connectors }
    }

    // MARK: Plan

    private var hasRoute: Bool { ws.intent != TradeIntent() || ws.managesPosition }
    /// Changes only when the plan itself changes, not on every price refresh: the assembly replays per plan.
    private var planKey: String { hasRoute ? String(describing: ws.intent) : "" }
    /// Once the plan is on the exchange, the canvas shows the position itself instead of the old route.
    private var nodes: [StudioNode] { hasRoute && !ws.managesPosition ? StudioNode.build(ws) : [] }

    @ViewBuilder private var plan: some View {
        let nodes = nodes
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(ws.allocationPreview.map { "Plan · spread \($0.asset) across the best rates" }
                     ?? (hasRoute ? "\(ws.managesPosition ? "Position" : "Plan") · \(ws.intent.side == .long ? "long" : "short") \(IntentParser.pretty(ws.intent.asset))" : ws.savedBoard?.title ?? "Plan"))
                    .font(.system(size: 14, weight: .semibold))
                StatusChip(text: statusText(nodes), tint: statusTint(nodes))
                if hasRoute { MarketPicker() }
            }
            if let place = ws.detail { PlaceDetailBoard(place: place) }
            if ws.showReceive { ReceiveBoard() }
            if let chart = ws.chart { ChartBoard(state: chart) }
            if ws.showMovers { MoversBoard() }
            if let yields = ws.yieldOptions, !yields.isEmpty {
                YieldBubbles(options: yields)
            }
            if let allocation = ws.allocationPreview {
                AllocationBoard(preview: allocation)
            }
            WithdrawBoard()
            PendingAddressBoard()
            TransferBoard()
            if nodes.isEmpty {
                ForEach(ws.positions, id: \.coin) { PositionBoard(position: $0) }
                if ws.yieldOptions == nil, ws.allocationPreview == nil {
                    ForEach(ws.schedules, id: \.symbol) { ScheduleBoard(schedule: $0) }
                    if let saved = ws.savedBoard { SavedBoard(canvas: saved) } else if ws.positions.isEmpty, ws.schedules.isEmpty { placeholder }
                }
            } else {
                let left = nodes.filter { $0.column == 0 }, right = nodes.filter { $0.column == 1 }
                HStack(alignment: .top, spacing: 30) {
                    VStack(spacing: 18) { ForEach(left) { node($0, nodes: nodes) } }.frame(width: 220)
                    VStack(spacing: 18) { ForEach(right) { node($0, nodes: nodes) } }.frame(width: 220)
                }
                ForEach(nodes.filter { $0.column == 2 }) { node($0, nodes: nodes) }
                if nodes.contains(where: { $0.status == .blocked }), !assembling { FixChoices() }
                if let choices = ws.takeChoices, !assembling {
                    TakeChoices(choices: choices, risk: ws.evaluation.sizing?.lossAtStopUSD)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
        .overlay(alignment: .topLeading) { cursors(nodes) }
    }

    private func node(_ n: StudioNode, nodes: [StudioNode]) -> some View {
        let index = nodes.firstIndex { $0.id == n.id } ?? 0
        let visible = index < shown
        let current = assembling && index == shown - 1
        return StudioNodeView(node: n)
            .overlay { if current { RoundedRectangle(cornerRadius: 20).strokeBorder(cursorColor(index, n), lineWidth: 3) } }
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.86)
            .offset(y: visible ? 0 : 14)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("studio")) } action: { record(n.id, $0) }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            LalaLogo(size: 40).opacity(0.5)
            Text("LALA AI builds the plan here").font(.system(size: 17, weight: .bold))
            Text("next to your portfolio: where the money comes from, where it goes, the checks and the result in dollars.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            LazyVGrid(columns: [GridItem(.fixed(200)), GridItem(.fixed(200))], spacing: 8) {
                ForEach(TemplatesPanel.templates.prefix(6), id: \.title) { t in
                    Button { ws.draft = t.phrase } label: {
                        HStack(spacing: 8) {
                            HStack(spacing: 2) {
                                ForEach(t.colors.indices, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(Color(hex: t.colors[$0])).frame(width: 9, height: 9) }
                            }
                            Text(t.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.card))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.cardBorder))
                    }
                    .buttonStyle(.plain)
                    .help("Puts “\(t.phrase)” into the chat")
                }
            }
            .padding(.top, 6)
        }
        .frame(width: 470, height: 400)
        .background(RoundedRectangle(cornerRadius: 26).strokeBorder(Brand.dots, style: StrokeStyle(lineWidth: 2, dash: [6, 6])))
    }

    private func statusText(_ nodes: [StudioNode]) -> String {
        if ws.allocationPreview != nil { return ws.pendingAllocation != nil ? "ready to sign" : "nothing to place" }
        guard hasRoute else { return ws.savedBoard != nil ? "saved canvas" : "waiting for a task" }
        if assembling { return "building · \(shown) of \(nodes.count)" }
        if ws.managesPosition { return ws.positions.contains { $0.coin == ws.intent.asset } ? "position open" : "done · position closed" }
        if nodes.contains(where: { $0.status == .blocked }) { return "stopped by the rules" }
        return ws.planIsReady ? "ready to sign" : "needs details"
    }

    private func statusTint(_ nodes: [StudioNode]) -> Color {
        if ws.allocationPreview != nil { return ws.pendingAllocation != nil ? Brand.profit : .secondary }
        guard hasRoute, !assembling else { return .secondary }
        if nodes.contains(where: { $0.status == .blocked }) { return Brand.blockedInk }
        return ws.planIsReady || ws.managesPosition ? Brand.profit : Brand.jevInk
    }

    // MARK: Assembly

    private func assemble() async {
        let count = nodes.count
        guard count > 0 else { shown = 0; assembling = false; ws.assembly = nil; return }
        shown = 0
        assembling = true
        for i in 1...count {
            try? await Task.sleep(for: .milliseconds(420))
            if Task.isCancelled { ws.assembly = nil; return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) { shown = i }
            ws.assembly = (i, count)
        }
        try? await Task.sleep(for: .milliseconds(700))
        withAnimation(.easeOut(duration: 0.3)) { assembling = false; ws.assembly = nil }
    }

    /// LALA AI carries the blocks; a second cursor joins when the plan is long, Jev carries his own check.
    private func carrier(_ index: Int, _ n: StudioNode) -> (String, Color) {
        if n.kind == .jev { return ("Jev", Brand.jevCursor) }
        if index >= 3, index % 2 == 1 { return ("LALA AI · 2", Brand.secondCursor) }
        return ("LALA AI", Brand.accent)
    }

    private func cursorColor(_ index: Int, _ n: StudioNode) -> Color { carrier(index, n).1 }

    @ViewBuilder private func cursors(_ nodes: [StudioNode]) -> some View {
        if assembling, shown > 0, shown <= nodes.count {
            let n = nodes[shown - 1]
            let (label, color) = carrier(shown - 1, n)
            if let f = frames[n.id], let origin = frames["plan.origin"] {
                StudioCursor(label: label, color: color)
                    .offset(x: f.maxX - origin.minX - 34, y: f.maxY - origin.minY - 20)
                    .animation(.easeInOut(duration: 0.4), value: shown)
            }
        }
        Color.clear.frame(width: 1, height: 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("studio")) } action: { record("plan.origin", $0) }
    }

    // MARK: Lines

    private var connectors: some View {
        let pairs: [(String, String, Color)] = [
            ("pf.solana", "source", Color(hex: 0x9945FF)), ("source", "bridge", Color(hex: 0x9945FF)),
            ("bridge", "position", Brand.relay), ("position", "protection", Color(hex: 0x0F6B5D)),
            ("protection", "jev", Brand.jevCursor), ("risk", "outcome", .primary), ("jev", "outcome", .primary)
        ]
        let visible = Set(nodes.prefix(shown).map(\.id)).union(["pf.solana"])
        return Canvas { context, _ in
            for (a, b, color) in pairs where visible.contains(a) && visible.contains(b) {
                guard let fa = frames[a], let fb = frames[b] else { continue }
                var path = Path()
                let start = fb.minY > fa.maxY + 4 && abs(fb.midX - fa.midX) < 60 ? CGPoint(x: fa.midX, y: fa.maxY) : CGPoint(x: fa.maxX, y: fa.midY)
                let end = fb.minY > fa.maxY + 4 && abs(fb.midX - fa.midX) < 60 ? CGPoint(x: fb.midX, y: fb.minY) : CGPoint(x: fb.minX, y: fb.midY)
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: (start.x + end.x) / 2, y: start.y), control2: CGPoint(x: (start.x + end.x) / 2, y: end.y))
                context.stroke(path, with: .color(color.opacity(0.8)), lineWidth: 2.5)
            }
        }
        .allowsHitTesting(false)
    }

    private func record(_ id: String, _ frame: CGRect) {
        if frames[id] != frame { frames[id] = frame }
    }

    /// Changes the zoom by `factor`, keeping `point` (in the canvas) where it is.
    private func zoomAbout(_ point: CGPoint, by factor: CGFloat) {
        let next = Self.zoomRange.clamped(zoom * factor)
        let k = next / zoom
        let moved = CanvasZoom.pan(keeping: (point.x, point.y), from: (pan.width, pan.height), by: k)
        pan = CGSize(width: moved.x, height: moved.y)
        zoom = next
        pinchAt = .zero
    }

    /// Trackpad two-finger scrolling pans; ⌘ + scroll zooms (for a mouse wheel). Over the chat, scrolling stays the chat's.
    private func watchScrolling() {
        guard scrollMonitor == nil else { return }
        let hovering = $hovering, pan = $pan
        let ws = ws
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard hovering.wrappedValue, let window = event.window else { return event }
            let height = window.contentView?.bounds.height ?? 0
            let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
            if ws.chatFrame.contains(point) { return event }
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            if event.modifierFlags.contains(.command) {
                NotificationCenter.default.post(name: .lalaCanvasZoom, object: nil, userInfo: ["factor": 1 + event.scrollingDeltaY * step * 0.01])
            } else {
                pan.wrappedValue.width += event.scrollingDeltaX * step
                pan.wrappedValue.height += event.scrollingDeltaY * step
            }
            return nil
        }
    }

    private func zoomBar(_ scale: CGFloat) -> some View {
        HStack(spacing: 4) {
            Button { withAnimation { zoom = Self.zoomRange.clamped(zoom - 0.1) } } label: { Image(systemName: "minus") }.help("Zoom out · or pinch")
            Text("\(Int((scale * 100).rounded()))%").font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 44)
            Button { withAnimation { zoom = Self.zoomRange.clamped(zoom + 0.1) } } label: { Image(systemName: "plus") }.help("Zoom in · or pinch")
            Button("Fit") { withAnimation { zoom = 1; pan = .zero } }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.cardBorder))
    }
}

private struct EmptyPreferenceKey: PreferenceKey {
    static let defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) {}
}

struct StatusChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text).font(.caption).foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

struct StudioCursor: View {
    let label: String
    let color: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(systemName: "cursorarrow").font(.system(size: 22, weight: .bold)).foregroundStyle(color)
                .shadow(color: .white, radius: 0.5)
            Text(label).font(.system(size: 11, weight: .heavy)).foregroundStyle(color == Brand.jevCursor ? Color(hex: 0x0F1222) : .white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 10, bottomTrailingRadius: 10, topTrailingRadius: 10).fill(color))
                .offset(x: 16, y: 18)
                .fixedSize()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: Portfolio frame

struct StudioPortfolio: View {
    @Environment(Workspace.self) private var ws
    let onFrame: (String, CGRect) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("PORTFOLIO").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Text(ws.equity.map(Fmt.usd) ?? "—").font(.system(size: 20, weight: .heavy)).monospacedDigit()
                    let series = ws.equitySeries()
                    if series.count > 2, let first = series.first, let last = series.last {
                        Text("\(signed(last.usd - first.usd)) · \(Int((last.at.timeIntervalSince(first.at) / 86_400).rounded(.up))) d")
                            .font(.caption2.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(last.usd >= first.usd ? Brand.profit : Brand.loss)
                    }
                }
                Spacer()
                if !ws.positions.isEmpty {
                    Text(signed(ws.positionsPnl)).font(.caption.weight(.bold))
                        .foregroundStyle(ws.positionsPnl < 0 ? Brand.loss : Brand.profit)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill((ws.positionsPnl < 0 ? Brand.loss : Brand.profit).opacity(0.12)))
                }
            }
            if ws.equitySeries().count > 2 {
                EquitySparkline(points: ws.equitySeries(), height: 30)
            }
            PortfolioRing()
            HStack(spacing: 10) {
                TokenLogo(name: "sol", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Solana").font(.system(size: 14, weight: .semibold))
                    Text(ws.solana.map { "\(Fmt.num($0.sol, maxFraction: 4)) SOL" } ?? "no address").font(.caption).foregroundStyle(Brand.solanaInk)
                }
                Spacer()
                HStack(spacing: 4) {
                    TokenLogo(name: "usdc", size: 15)
                    Text(ws.solana.map { Fmt.num($0.usdc) } ?? "—").font(.system(size: 13, weight: .bold)).monospacedDigit()
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 16).fill(Brand.solanaTint))
            .modifier(Openable(place: "solana"))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("studio")) } action: { onFrame("pf.solana", $0) }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    TokenLogo(name: "hype", size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hyperliquid").font(.system(size: 14, weight: .semibold))
                        Text(ws.hlMargin.map { "\(Fmt.usd($0)) · margin" + (ws.hlp.equity > 0 ? " · HLP \(Fmt.usd(ws.hlp.equity))" : "") } ?? "no address").font(.caption).foregroundStyle(Brand.hlMint)
                    }
                }
                ForEach(ws.positions, id: \.coin) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(p.size > 0 ? "Long" : "Short") \(IntentParser.pretty(p.coin))").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text(signed(p.unrealizedPnl)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                                .foregroundStyle(p.unrealizedPnl < 0 ? Color(hex: 0xFF9C8F) : Brand.hlMint)
                        }
                        Text(ws.positionSummary(p)).font(.caption2).foregroundStyle(Brand.hlSoft).lineLimit(2)
                        if let rules = ws.exitRules[p.coin] {
                            Label(ScheduleView.duties(rules).joined(separator: " "), systemImage: "shield.lefthalf.filled")
                                .font(.caption2).foregroundStyle(Brand.hlMint).lineLimit(2)
                        }
                    }
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Brand.hlChip))
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await ws.chartCommand(.chart(coin: p.coin, range: .day)) } }
                    .help("Open the \(IntentParser.pretty(p.coin)) chart")
                }
                if let o = ws.pendingEntry {
                    Text("Limit waiting: \(o.side == "B" ? "long" : "short") \(IntentParser.pretty(o.coin)) at \(o.limitPx.map(Fmt.price) ?? "?")")
                        .font(.caption).foregroundStyle(Brand.hlSoft)
                }
            }
            .foregroundStyle(.white)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Brand.hl))
            .modifier(Openable(place: "hyperliquid"))

            if ws.lendTotal > 0 {
                HStack(spacing: 10) {
                    TokenLogo(name: "jup", size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Jupiter Lend").font(.system(size: 14, weight: .semibold))
                        Text("earning").font(.caption).foregroundStyle(Brand.jupiterInk)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        TokenLogo(name: "usdc", size: 15)
                        Text(Fmt.num(ws.lendTotal)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 16).fill(Brand.jupiterTint))
                .modifier(Openable(place: "jupiter"))
            }

            if let b = ws.base, b.aave > 0 || b.usdc > 0 {
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        TokenLogo(name: "aave", size: 34)
                        TokenLogo(name: "base", size: 15).offset(x: 3, y: 3)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aave · Base").font(.system(size: 14, weight: .semibold))
                        Text(b.aave > 0 ? "earning" + (ws.aaveAPY.map { " \(Fmt.num($0.rounded(2, .plain)))%" } ?? "") : "\(Fmt.num(b.usdc)) USDC idle on Base")
                            .font(.caption).foregroundStyle(Color(hex: 0x0052FF))
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        TokenLogo(name: "usdc", size: 15)
                        Text(Fmt.num(b.aave > 0 ? b.aave : b.usdc)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(light: 0xEAF0FF, dark: 0x14213F)))
                .modifier(Openable(place: "aave"))
            }

            if ws.kamino > 0 { place("kamino", "Kamino", "earning", Fmt.usd(ws.kamino), tint: Color(light: 0xE8F0FF, dark: 0x0B1B33), ink: Color(hex: 0x3B82F6)) }
            if ws.near > 0 {
                place("near", "NEAR", ws.markets["NEAR"] != nil ? "≈ \(Fmt.usd(ws.nearUSD))" : "native NEAR",
                      "\(Fmt.num(ws.near, maxFraction: 4)) NEAR", tint: Color(light: 0xE6FBF3, dark: 0x0E2A20), ink: Color(light: 0x05785A, dark: 0x00EC97))
            }

            RobinhoodCard()
            AlertsCard()

            if !ws.schedules.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Recurring buys", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.semibold))
                    ForEach(ws.schedules, id: \.symbol) { s in
                        Text("\(s.symbol) for \(Fmt.usd(s.usdc)) · \(Fmt.date(s.next))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.cardBorder))
            }
        }
        .padding(14)
        .frame(width: 270)
        .background(RoundedRectangle(cornerRadius: 26).fill(Brand.card).shadow(color: .black.opacity(0.08), radius: 18, y: 10))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Brand.cardBorder))
    }
}

extension StudioPortfolio {
    /// One more place on the portfolio card: logo, name, a line under it, the amount; a click opens its details.
    func place(_ id: String, _ name: String, _ line: String, _ amount: String, tint: Color, ink: Color) -> some View {
        HStack(spacing: 10) {
            TokenLogo(name: id, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14, weight: .semibold))
                Text(line).font(.caption).foregroundStyle(ink).lineLimit(1)
            }
            Spacer()
            Text(amount).font(.system(size: 13, weight: .bold)).monospacedDigit().lineLimit(1).fixedSize()
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 16).fill(tint))
        .modifier(Openable(place: id))
    }
}

// MARK: Plan nodes

struct StudioNode: Identifiable {
    enum Kind: String { case source, bridge, position, protection, risk, jev, outcome, other }
    let id: String
    let kind: Kind
    let label: String
    let title: String
    let lines: [String]
    let status: Block.Status
    var asset: String = ""
    var long = true
    /// Which signature this step is (1, 2, …); nil for checks and for steps that move nothing.
    var signature: Int?

    /// 0 — left column, 1 — right, 2 — full width under both.
    var column: Int {
        switch kind {
        case .source, .bridge, .risk, .other: 0
        case .position, .protection, .jev: 1
        case .outcome: 2
        }
    }

    @MainActor static func build(_ ws: Workspace) -> [StudioNode] {
        var out = ws.blocks.map { b in
            let kind: Kind = switch b.id {
            case "source": .source
            case "bridge": .bridge
            case "position": .position
            case "protection": .protection
            case "risk": .risk
            default: .other
            }
            return StudioNode(id: b.id, kind: kind, label: b.label, title: b.title, lines: Array(b.lines.prefix(4)), status: b.status,
                              asset: ws.intent.asset, long: ws.intent.side == .long)
        }
        // What the user signs: the bridge (when there is one), the entry, and the stop and take on the exchange.
        var n = 0
        for i in out.indices where [.bridge, .position, .protection].contains(out[i].kind) && out[i].status != .info {
            n += 1
            out[i].signature = n
        }
        if let r = ws.planReview {
            out.append(StudioNode(id: "jev", kind: .jev, label: "Jev", title: r.concern ? "Has doubts" : "Matches your request",
                                  lines: [r.text], status: r.concern ? .warning : .ready))
        }
        if let s = ws.evaluation.sizing {
            var line = "If stopped: −\(Fmt.usd(s.lossAtStopUSD))"
            if let profit = s.profitAtTakeUSD { line += "   ·   if take: +\(Fmt.usd(profit))" }
            out.append(StudioNode(id: "outcome", kind: .outcome, label: "Result", title: line, lines: [], status: .info))
        }
        return out
    }
}

struct StudioNodeView: View {
    let node: StudioNode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let action { tag(action.icon, action.verb) }
                Spacer(minLength: 0)
                if let n = node.signature {
                    HStack(spacing: 3) { Image(systemName: "signature"); Text("\(n)") }
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().strokeBorder(labelColor.opacity(0.6)))
                        .foregroundStyle(labelColor)
                        .help("This step is signed — signature \(n)")
                }
                if node.status == .warning || node.status == .needsInput || node.status == .blocked {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                }
            }
            if node.kind != .outcome {
                HStack(spacing: 7) {
                    header
                    if node.label != "Source" { Text(node.label).font(.caption).foregroundStyle(labelColor).lineLimit(1) }
                }
            }
            Text(node.title).font(.system(size: node.kind == .outcome ? 15 : 15, weight: .bold)).lineLimit(3)
            ForEach(node.lines.indices, id: \.self) { i in
                Text(node.lines[i]).font(.caption).foregroundStyle(lineColor).lineLimit(3).monospacedDigit()
            }
        }
        .foregroundStyle(textColor)
        .padding(.leading, 14).padding(.vertical, 14).padding(.trailing, node.kind == .bridge ? 28 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(background))
        .overlay(shape.stroke(border, style: StrokeStyle(lineWidth: node.status == .blocked ? 2 : 1, dash: isCheck ? [5, 4] : [])))
    }

    /// Money that moves is an arrow, checks are soft capsules, the rest are cards.
    private var shape: AnyShape {
        switch node.kind {
        case .bridge: AnyShape(ArrowCard())
        case .risk, .jev: AnyShape(RoundedRectangle(cornerRadius: 30))
        default: AnyShape(RoundedRectangle(cornerRadius: 20))
        }
    }

    private var isCheck: Bool { node.kind == .risk || node.kind == .jev }

    /// The verb on top of each block: what this step does, readable before the numbers.
    private var action: (icon: String, verb: String)? {
        switch node.kind {
        case .source: ("tray.and.arrow.up.fill", "TAKE FROM")
        case .bridge: ("arrow.left.arrow.right", "BRIDGE")
        case .position: (node.long ? "arrow.up.right" : "arrow.down.right", node.long ? "OPEN LONG" : "OPEN SHORT")
        case .protection: ("shield.fill", "PROTECT")
        case .risk: ("checklist", "CHECK RULES")
        case .jev: ("checkmark.shield.fill", "JEV CHECKS")
        case .outcome: ("equal.circle.fill", "RESULT")
        case .other: nil
        }
    }

    private func tag(_ icon: String, _ verb: String) -> some View {
        let dark = [.bridge, .position, .outcome].contains(node.kind) && node.status != .blocked
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(verb).font(.system(size: 9.5, weight: .heavy)).tracking(0.5)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .foregroundStyle(dark ? .white : labelColor)
        .background(Capsule().fill(dark ? Color.white.opacity(0.16) : labelColor.opacity(0.13)))
    }

    @ViewBuilder private var header: some View {
        switch node.kind {
        case .source:
            HStack(spacing: -6) { TokenLogo(name: node.title.contains("Hyperliquid") ? "hype" : "sol", size: 20); TokenLogo(name: "usdc", size: 20) }
        case .bridge: TokenLogo(name: node.title.contains("1Click") ? "usdc" : "relay", size: 20)
        case .position: HStack(spacing: 4) { TokenLogo(name: "hype", size: 20); AssetBadge(coin: node.asset, size: 20) }
        case .jev: Image(systemName: "checkmark.shield").foregroundStyle(Brand.jevInk)
        case .risk: Image(systemName: "gauge.with.dots.needle.50percent").foregroundStyle(labelColor)
        case .protection: Image(systemName: "shield.lefthalf.filled").foregroundStyle(.secondary)
        case .outcome, .other: EmptyView()
        }
    }

    private var background: Color {
        if node.status == .blocked { return Brand.blockedTint }
        switch node.kind {
        case .source: return Brand.solanaTint
        case .bridge: return Brand.relay
        case .position: return Brand.hl
        case .risk: return Brand.riskTint
        case .jev: return Brand.jevTint
        case .outcome: return Brand.outcome
        case .protection, .other: return Brand.card
        }
    }

    private var border: Color {
        if node.status == .blocked { return Brand.blockedInk }
        switch node.kind {
        case .protection, .other, .source: return Brand.cardBorder
        default: return .clear
        }
    }

    private var textColor: Color {
        switch node.kind {
        case .bridge, .position, .outcome: node.status == .blocked ? Brand.blockedInk : .white
        default: .primary
        }
    }

    private var labelColor: Color {
        if node.status == .blocked { return Brand.blockedInk }
        switch node.kind {
        case .source: return Brand.solanaInk
        case .bridge: return Brand.relayInk
        case .position: return Brand.hlMint
        case .risk: return Brand.riskInk
        case .jev: return Brand.jevInk
        case .outcome: return Color(hex: 0xB9C1DC)
        case .protection, .other: return .secondary
        }
    }

    private var lineColor: Color {
        switch node.kind {
        case .bridge: Brand.relayInk
        case .position: Brand.hlSoft
        case .outcome: Color(hex: 0xB9C1DC)
        default: .secondary
        }
    }

    private var dotColor: Color {
        switch node.status {
        case .blocked: .red
        case .warning: .yellow
        default: .orange
        }
    }
}

// MARK: Floating chat

struct FloatingChat: View {
    @Environment(Workspace.self) private var ws
    @State private var templatesOpen = false
    var compact = false
    var wide = false
    let toggleCompact: () -> Void
    var toggleWide: () -> Void = {}
    /// The header moves the chat anywhere; a double-click brings it home. The header buttons still click.
    @Binding var drag: CGSize
    var endDrag: (CGSize) -> Void = { _ in }
    var dock: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LalaLogo(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LALA AI").font(.system(size: 14, weight: .bold))
                    ChatModelMenu()
                }
                Spacer()
                Button { withAnimation(StudioView.spring) { ws.newCanvas() } } label: { headerIcon("square.and.pencil") }
                    .buttonStyle(.hoverIcon).help("New canvas").disabled(ws.busy)
                Button(action: toggleWide) { headerIcon(wide ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.hoverIcon).help(wide ? "Narrow chat" : "Chat on half the window")
                Button(action: toggleCompact) { headerIcon(compact ? "chevron.up" : "minus") }
                    .buttonStyle(.hoverIcon).help(compact ? "Full-height chat" : "Compact chat")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            .background(Color.clear.contentShape(Rectangle()).pointerStyle(.grabIdle).gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { drag = $0.translation }
                .onEnded { endDrag($0.translation) })
                .simultaneousGesture(TapGesture(count: 2).onEnded { dock() }))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(ws.messages.dropFirst()) { MessageRow(message: $0) }
                        if ws.messages.count <= 1 {
                            Text("Your portfolio is on the canvas. Tell me what to do with your money — in any language — and I’ll build the plan next to it. Nothing moves without your signature.")
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                            Text("You can say:").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                            ForEach(["long ETH risk $0.25 by the book", "where to keep USDC", "buy SOL for 2 USDC every week", "withdraw 1 USDC to Solana"], id: \.self) { phrase in
                                Button { ws.draft = phrase } label: {
                                    Text(phrase).font(.system(size: 13)).foregroundStyle(Brand.accent)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(Capsule().fill(Brand.accent.opacity(0.1)))
                                }
                                .buttonStyle(.plain).pointerStyle(.link)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 8)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: ws.messages.count) {
                    if let id = ws.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }

            if let a = ws.assembly {
                HStack(spacing: 8) {
                    ProgressView(value: Double(a.shown), total: Double(a.total)).progressViewStyle(.linear).frame(width: 70)
                    Text("Building on the canvas · \(a.shown) of \(a.total)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 14).padding(.bottom, 4)
                .transition(.opacity)
            }
            actions.padding(.horizontal, 14)

            HStack(alignment: .bottom, spacing: 8) {
                Button { templatesOpen.toggle() } label: {
                    Image(systemName: "square.grid.2x2").font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.card))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .foregroundStyle(Brand.accent)
                .help("Plan templates")
                .popover(isPresented: $templatesOpen, arrowEdge: .top) {
                    TemplatesPanel { phrase in ws.draft = phrase; templatesOpen = false }
                }
                TextField("What should we do?", text: Bindable(ws).draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...5)
                    .padding(.vertical, 8)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 10).fill(ws.draft.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary)))
                }
                .buttonStyle(.plain)
                .pointerStyle(ws.draft.isEmpty || ws.busy ? nil : .link)
                .disabled(ws.draft.isEmpty || ws.busy)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 14).fill(.fill.tertiary))
            .padding(12)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card).shadow(color: .black.opacity(0.14), radius: 24, y: 14))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.cardBorder))
    }

    /// The one thing to do next: sign the allocation, execute the plan, or manage the open position.
    @ViewBuilder private var actions: some View {
        if let text = ws.pendingText {
            Button { Task { await ws.send("do it") } } label: { primary("Confirm: \(text)") }
                .buttonStyle(.plain).disabled(ws.executing).padding(.bottom, 4)
        } else if ws.pendingAllocation != nil {
            Button { Task { await ws.send("do it") } } label: { primary("Sign") }
                .buttonStyle(.plain).disabled(ws.executing).padding(.bottom, 4)
        } else if ws.managesPosition, ws.positions.contains(where: { $0.coin == ws.intent.asset }) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(["move stop to breakeven", "trail 2%", "close half", "close"], id: \.self) { phrase in
                        Button(phrase) { Task { await ws.send(phrase) } }
                            .buttonStyle(.plain).font(.system(size: 12))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Brand.accent.opacity(0.1)))
                            .foregroundStyle(phrase == "close" ? Brand.loss : Brand.accent)
                    }
                }
            }
            .padding(.bottom, 4)
        } else if ws.intent != TradeIntent(), !ws.managesPosition {
            VStack(alignment: .leading, spacing: 6) {
                if let r = ws.planReview {
                    Label(r.text, systemImage: r.concern ? "exclamationmark.triangle.fill" : "checkmark.seal")
                        .font(.caption).foregroundStyle(r.concern ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)).lineLimit(2)
                }
                HStack {
                    if ws.executing || ws.preparing { ProgressView().controlSize(.small) }
                    Button { Task { await ws.prepareExecution() } } label: {
                        primary(ws.signerWallet == nil ? "Preview" : "Execute", enabled: ws.planIsReady)
                    }
                    .buttonStyle(.plain)
                    .disabled(!ws.planIsReady || ws.previewWallet == nil || ws.executing || ws.preparing)
                }
                Text("Edit it in words: “take like the pros”, “risk $0.20”, “entry on a 1% pullback”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
        }
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .semibold))
    }

    private func primary(_ title: String, enabled: Bool = true) -> some View {
        Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 12).fill(enabled ? Brand.accent : Color.gray.opacity(0.5)))
    }

    private func send() {
        let text = ws.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !ws.busy else { return }
        ws.draft = ""
        Task { await ws.send(text) }
    }
}

/// «[logo] GPT 6 SOL ▾»: the model for the chat, right under LALA AI. The choice is kept per canvas.
/// The menu lists companies; one with several ways in (subscription, API key) opens in place to show them.
struct ChatModelMenu: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.openSettings) private var openSettings
    @State private var open = false
    /// The company opened in the menu; the current one's when the menu opens.
    @State private var expanded: String?
    /// Providers with a saved login, read once per opening: each Keychain read is a round trip to securityd.
    @State private var linked: Set<String> = []

    var body: some View {
        Button {
            linked = Set(LLMCatalog.all.map(\.info.id).filter { Keychain.load($0) != nil })
            expanded = ModelCompany.of(ws.providerID)?.name
            open.toggle()
        } label: {
            HStack(spacing: 4) {
                if let c = ModelCompany.of(ws.providerID) { ModelCompanyLogo(company: c, size: 15) }
                Text(ws.model.isEmpty ? ws.provider.info.name : LLMCatalog.displayName(model: ws.model)).lineLimit(1)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption).foregroundStyle(Brand.accent)
            .padding(.leading, 3).padding(.trailing, 6).padding(.vertical, 2)
            .background(Capsule().fill(Brand.accent.opacity(open ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("\(ws.provider.info.name) · \(ws.model). The model for this canvas; it never sees your wallet key.")
        .popover(isPresented: $open, arrowEdge: .bottom) { menu }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            caption("MODEL FOR THIS CANVAS")
            ForEach(ModelCompany.all.filter { !$0.local }) { company($0) }
            caption("ON THIS MAC · NO INTERNET").padding(.top, 6)
            ForEach(ModelCompany.all.filter(\.local)) { company($0) }
            Divider().padding(.vertical, 4)
            HStack {
                Label("The model never sees your wallet key.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Sign-ins…") { open = false; openSettings() }.buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 10).padding(.bottom, 4)
        }
        .padding(8)
        .frame(width: 340)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
    }

    /// A company's row; several ways in open under it, a single one is picked right away.
    @ViewBuilder private func company(_ c: ModelCompany) -> some View {
        let ways = c.ids.compactMap { LLMCatalog.provider(id: $0)?.info }
        let current = ways.first { $0.id == ws.providerID }
        let isOpen = ways.count > 1 && expanded == c.name
        CompanyRow(company: c, detail: summary(ways, current: isOpen ? nil : current), current: current != nil,
                   disclosure: ways.count > 1 ? isOpen : nil) {
            if ways.count > 1 { expanded = isOpen ? nil : c.name } else if let only = ways.first { pick(only) }
        }
        if isOpen {
            ForEach(ways) { info in
                MenuRow(title: info.name, detail: info.unavailable == nil ? detail(info) : "not open to apps yet — use the API key",
                        icon: info.kind == .subscription ? "person.crop.circle" : "key", checked: info.id == ws.providerID) { pick(info) }
                    .disabled(info.unavailable != nil)
                    .opacity(info.unavailable != nil ? 0.5 : 1)
                    .help(info.unavailable ?? info.note)
                    .padding(.leading, 26)
            }
        }
    }

    /// Under the company: what's in use, or else the ways in.
    private func summary(_ ways: [ProviderInfo], current: ProviderInfo?) -> String {
        if ways.count == 1, let only = ways.first { return detail(only) }
        if let current { return "\(current.kind == .subscription ? "Subscription" : "API key") · \(detail(current))" }
        return ways.filter { $0.unavailable == nil }.map { $0.kind == .subscription ? "Subscription" : "API key" }
            .joined(separator: " or ")
    }

    private func pick(_ info: ProviderInfo) {
        ws.providerID = info.id
        ws.saveCanvas()
        open = false
        if !connected(info) { openSettings() }
    }

    private func connected(_ info: ProviderInfo) -> Bool { info.kind == .local || linked.contains(info.id) }

    private func detail(_ info: ProviderInfo) -> String {
        let model = ws.modelChoices[info.id] ?? info.defaultModel
        let state = info.kind == .local ? "on this Mac" : connected(info) ? "connected" : "sign-in needed"
        let shown = info.takesKey && !connected(info) ? "any model by key" : model.isEmpty ? "" : LLMCatalog.displayName(model: model)
        return [shown, state].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A model maker in the chat's model menu: its logo on a brand tile and its ways in (catalog ids).
struct ModelCompany: Identifiable {
    let name: String
    /// Logos/<logo>.png
    let logo: String
    let tile: UInt32
    /// The color for a one-color logo; nil keeps the logo's own colors.
    var ink: UInt32?
    let ids: [String]
    var id: String { name }
    var local: Bool { LLMCatalog.provider(id: ids[0])?.info.kind == .local }

    static let known: [ModelCompany] = [
        .init(name: "OpenAI", logo: "llm-openai", tile: 0x000000, ink: 0xFFFFFF, ids: ["chatgpt", "openai"]),
        .init(name: "Anthropic", logo: "llm-claude", tile: 0xF4F3EE, ids: ["claude-code", "anthropic"]),
        .init(name: "Google", logo: "llm-gemini", tile: 0xFFFFFF, ids: ["gemini-subscription", "gemini"]),
        .init(name: "xAI", logo: "llm-grok", tile: 0x000000, ink: 0xFFFFFF, ids: ["grok-subscription", "xai"]),
        .init(name: "DeepSeek", logo: "llm-deepseek", tile: 0xFFFFFF, ids: ["deepseek"]),
        .init(name: "OpenRouter", logo: "llm-openrouter", tile: 0x6566F1, ink: 0xFFFFFF, ids: ["openrouter"]),
        .init(name: "Ollama", logo: "llm-ollama", tile: 0xFFFFFF, ink: 0x000000, ids: ["ollama"]),
        .init(name: "LM Studio", logo: "llm-lmstudio", tile: 0x4338CA, ink: 0xFFFFFF, ids: ["lmstudio"]),
    ]
    /// A provider added to the catalog but not to a company above still shows, as its own company with a lettered tile.
    static let all = known + LLMCatalog.all.map(\.info).filter { info in !known.contains { $0.ids.contains(info.id) } }
        .map { ModelCompany(name: $0.name, logo: "", tile: 0x8E8E93, ids: [$0.id]) }

    static func of(_ providerID: String) -> ModelCompany? { all.first { $0.ids.contains(providerID) } }
}

/// The company's logo on its brand tile, like an app icon.
struct ModelCompanyLogo: View {
    let company: ModelCompany
    var size: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        shape.fill(Color(hex: company.tile))
            .overlay { glyph.frame(width: size * 0.64, height: size * 0.64) }
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .frame(width: size, height: size)
    }

    @ViewBuilder private var glyph: some View {
        if let image = TokenLogo.image(company.logo) {
            if let ink = company.ink {
                Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color(hex: ink))
            } else {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            }
        } else {
            Text(company.name.prefix(1)).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
        }
    }
}

private struct CompanyRow: View {
    let company: ModelCompany
    let detail: String
    let current: Bool
    /// Open or closed for a company with several ways in; nil when a tap picks it.
    let disclosure: Bool?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ModelCompanyLogo(company: company)
                VStack(alignment: .leading, spacing: 2) {
                    Text(company.name).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let disclosure {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(disclosure ? 90 : 0))
                } else if current {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.accent)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(
                current && disclosure != true ? Brand.accent.opacity(0.09) : hover ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Ready phrases for the schemes LALA builds; a tap puts the phrase into the field.
struct TemplatesPanel: View {
    let pick: (String) -> Void

    static let templates: [(title: String, phrase: String, colors: [UInt32])] = [
        ("Trade by the book", "long ETH by the book", [0x9945FF, 0x4615C8, 0x072723]),
        ("Short on a pullback", "short oil on a 2% pullback by the book", [0x072723, 0x97FCE4]),
        ("Best rates", "spread USDC across the best rates", [0x2775CA, 0x131D27, 0x082A56]),
        ("Where to keep it", "where to keep USDC", [0x2775CA, 0xC7F284]),
        ("Every week", "buy SOL for 2 USDC every week", [0x2775CA, 0x9945FF]),
        ("Back to Solana", "withdraw 1 USDC to Solana", [0x072723, 0x4615C8, 0x9945FF]),
        ("Protect a position", "move stop to breakeven", [0x072723, 0xF59E0B]),
        ("Stake SOL", "stake 0.01 SOL", [0x9945FF, 0x1F9D6A]),
        ("Aave on Base", "lend 2 USDC on Aave", [0x2775CA, 0x0052FF, 0xB6509E]),
        ("Price alert", "alert me when ETH is below 2,500", [0x627EEA, 0xF59E0B]),
        ("Buy a stock token", "buy SpaceX stock for 2 USDC", [0x2775CA, 0x4615C8, 0xCCFF00])
    ]

    /// What each template's scheme looks like, for the preview beside the list (S15).
    static let steps: [String: [(String, String)]] = [
        "Trade by the book": [("From", "USDC on Solana"), ("Bridge", "Relay or 1Click — the cheaper"), ("Position", "long or short, up to 5×"),
                              ("Stop and take", "stop 1.5 ATR · take in parts"), ("Rules", "risk 1% of capital"), ("Jev", "checks the plan")],
        "Short on a pullback": [("Entry", "limit 2% above the market"), ("Position", "short oil · xyz exchange"), ("Stop and take", "by the book"),
                                ("Guardian", "breakeven after ½")],
        "Best rates": [("Free", "USDC on Solana"), ("Split", "best rates · ≤ 50% per protocol"), ("Deposit", "Jupiter Lend, Kamino"), ("Result", "a year’s yield in USDC")],
        "Where to keep it": [("Rates", "Jupiter Lend, Kamino, HLP, JitoSOL"), ("Conditions", "minimums, rent, lockups"), ("Advice", "at most half in one place")],
        "Every week": [("Buy", "SOL for 2 USDC via Jupiter"), ("Every", "week, while LALA runs"), ("Checks", "address, simulation, signature"), ("Warning", "when Solana runs short")],
        "Back to Solana": [("From", "Hyperliquid"), ("Bridge", "Relay"), ("To", "your Solana address"), ("Signature", "main key — the trading key can’t withdraw")],
        "Protect a position": [("Position", "open on Hyperliquid"), ("Stop", "to the entry — breakeven"), ("Result", "worst case ≈ $0 and fees")],
        "Stake SOL": [("From", "SOL on Solana"), ("Swap", "SOL → JitoSOL"), ("Earns", "the staking yield"), ("Exit", "swap back any time")],
        "Aave on Base": [("From", "USDC on Solana"), ("Bridge", "Relay to Base + a little gas"), ("Approve", "exactly the amount"), ("Supply", "Aave v3 · ≈ 4% a year")],
        "Price alert": [("Watch", "the mark price every 10–30 s"), ("Fire", "one notification at the level"), ("Then", "the alert is done")],
        "Buy a stock token": [("From", "USDC on Solana"), ("Bridge", "Relay → USDG on Robinhood Chain"), ("Swap", "Uniswap · Robinhood's registered token"), ("Hold", "SPCX, TSLA… in your wallet")],
    ]
    @State private var hovered: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            list
            preview(hovered ?? Self.templates[0].title)
        }
        .padding(16)
    }

    private func preview(_ title: String) -> some View {
        let t = Self.templates.first { $0.title == title } ?? Self.templates[0]
        let steps = Self.steps[title] ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Text("PREVIEW · \(title.uppercased())").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            Text("this is how the scheme will look").font(.caption).foregroundStyle(.tertiary)
            ForEach(steps.indices, id: \.self) { i in
                if i > 0 { Image(systemName: "arrow.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary).padding(.leading, 14) }
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: t.colors[i % t.colors.count])).frame(width: 6, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(steps[i].0.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(0.4).foregroundStyle(.secondary)
                        Text(steps[i].1).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(.fill.quaternary))
            }
            Text("Say just the asset and direction — LALA fills the rest from the rules.").font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
        }
        .frame(width: 230, alignment: .topLeading)
        .animation(.snappy, value: hovered)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plan templates").font(.headline)
            LazyVGrid(columns: [GridItem(.fixed(150)), GridItem(.fixed(150))], spacing: 8) {
                ForEach(Self.templates, id: \.title) { t in
                    Button { pick(t.phrase) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 3) {
                                ForEach(t.colors.indices, id: \.self) { i in
                                    if i > 0 { Rectangle().fill(.tertiary).frame(width: 6, height: 2) }
                                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: t.colors[i])).frame(width: 16, height: 11)
                                }
                            }
                            Text(t.title).font(.system(size: 13, weight: .semibold))
                            Text("«\(t.phrase)»").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.fill.quaternary))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hovered == t.title ? Brand.accent : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { hovered = t.title } }
                }
            }
        }
    }
}

extension Workspace {
    /// Unrealized PnL of all open positions.
    var positionsPnl: Decimal { positions.reduce(0) { $0 + $1.unrealizedPnl } }
    /// Hyperliquid main account plus HIP-3 margin.
    /// Trading margin: the main perp balance and the HIP-3 exchanges.
    var hlMargin: Decimal? { hl.map { $0.accountValue + dexBalances.values.reduce(0) { $0 + $1.accountValue } } }
    /// Everything on Hyperliquid: margin and the HLP vault.
    var hlTotal: Decimal? { hlMargin.map { $0 + hlp.equity } }
    var lendTotal: Decimal { lend.reduce(0) { $0 + $1.usdc } }
}

/// A card whose right side is an arrow: this step moves money on to the next one.
nonisolated struct ArrowCard: Shape {
    var radius: CGFloat = 18
    var tip: CGFloat = 16

    func path(in r: CGRect) -> Path {
        let body = r.maxX - tip
        let points = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: body, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                      CGPoint(x: body, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        for i in points.indices {
            p.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % points.count], radius: i == 2 ? 6 : radius)
        }
        p.closeSubpath()
        return p
    }
}

/// «Take profit like the best investors»: the three styles as cards with what each pays; a click puts it in the plan.
struct TakeChoices: View {
    @Environment(Workspace.self) private var ws
    let choices: [TakeStyle]
    let risk: Decimal?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PICK HOW TO TAKE PROFIT").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            ForEach(choices, id: \.self) { style in
                Button { Task { await ws.chooseTake(style) } } label: {
                    HStack(spacing: 14) {
                        TakeSketch(style: style).frame(width: 96, height: 64)
                            .background(RoundedRectangle(cornerRadius: 12).fill(.fill.quaternary))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(style.title).font(.system(size: 15, weight: .heavy))
                                if style == .partial {
                                    Text("LALA recommends").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(Capsule().fill(Brand.accent))
                                }
                            }
                            Text(style.detail).font(.caption).foregroundStyle(.secondary)
                            Text(style.note).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text(risk.map(style.payoff) ?? "").font(.system(size: 16, weight: .heavy)).foregroundStyle(Brand.profit)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Brand.card))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(style == .partial ? Brand.accent : Brand.cardBorder, lineWidth: style == .partial ? 2 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("The stop is the same in all three; only how the profit is taken changes.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// A tiny price path with the take lines of a style.
struct TakeSketch: View {
    let style: TakeStyle

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            func y(_ v: CGFloat) -> CGFloat { h * v }
            var price = Path()
            let points: [CGPoint] = [CGPoint(x: 0, y: y(0.72)), CGPoint(x: w * 0.18, y: y(0.66)), CGPoint(x: w * 0.3, y: y(0.72)),
                                     CGPoint(x: w * 0.46, y: y(0.52)), CGPoint(x: w * 0.62, y: y(0.45)), CGPoint(x: w * 0.8, y: y(0.28)),
                                     CGPoint(x: w, y: style == .trend ? y(0.08) : y(0.2))]
            price.addLines(points)
            let dash = StrokeStyle(lineWidth: 1.5, dash: [3, 3])
            func line(_ v: CGFloat, _ color: Color, from x0: CGFloat = 0) {
                var p = Path(); p.move(to: CGPoint(x: x0, y: y(v))); p.addLine(to: CGPoint(x: w, y: y(v)))
                context.stroke(p, with: .color(color), style: dash)
            }
            line(0.9, Brand.loss)
            switch style {
            case .classic: line(0.2, Brand.profit)
            case .partial: line(0.52, Brand.profit.opacity(0.6)); line(0.2, Brand.profit)
            case .trend:
                line(0.52, Brand.profit.opacity(0.6))
                var trail = Path()
                trail.addLines([CGPoint(x: w * 0.46, y: y(0.8)), CGPoint(x: w * 0.62, y: y(0.8)), CGPoint(x: w * 0.62, y: y(0.62)),
                                CGPoint(x: w * 0.8, y: y(0.62)), CGPoint(x: w * 0.8, y: y(0.45)), CGPoint(x: w, y: y(0.45))])
                context.stroke(trail, with: .color(Brand.jevCursor), style: dash)
            }
            context.stroke(price, with: .color(Brand.accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .padding(6)
        .accessibilityHidden(true)
    }
}

/// An open position on the canvas: the price between its stop and takes, and what can be done with it.
struct PositionBoard: View {
    @Environment(Workspace.self) private var ws
    let position: HyperliquidAccount.Position
    @State private var confirmClose: String?

    var body: some View {
        let long = position.size > 0
        let triggers = ws.orders.filter { $0.coin == position.coin && $0.isTrigger }
        let stop = triggers.first { ($0.orderType ?? "").contains("Stop") }?.triggerPx
        let takes = triggers.filter { ($0.orderType ?? "").contains("Take") }.compactMap(\.triggerPx)
        let mark = ws.markets[position.coin]?.markPx
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach([("breakeven", "Stop to breakeven", "move stop to breakeven"), ("trail", "Trailing 2%", "trail 2%"), ("half", "Close ½", "close half"), ("close", "Close", "close")], id: \.0) { item in
                    Button(item.1) {
                        switch item.0 {
                        case "breakeven": Task { await ws.manage(.stopToBreakeven, coin: position.coin) }
                        case "trail": Task { await ws.manage(.trail(2), coin: position.coin) }
                        default: confirmClose = item.2
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(item.0 == "breakeven" ? Brand.accent : Color.white.opacity(0.12)))
                    .foregroundStyle(item.0 == "close" ? Color(hex: 0xFF9C8F) : .white)
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 13).fill(Color(hex: 0x0F1222)))
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    AssetBadge(coin: position.coin, size: 40, dark: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(long ? "Long" : "Short") \(IntentParser.pretty(position.coin))").font(.system(size: 17, weight: .heavy))
                        Text("\(Fmt.num(abs(position.size), maxFraction: 6)) at \(Fmt.price(position.entry))\(mark.map { " · now \(Fmt.price($0))" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(signed(position.unrealizedPnl)).font(.system(size: 22, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(position.unrealizedPnl < 0 ? Brand.loss : Brand.profit)
                }
                PriceRuler(entry: position.entry, mark: mark, stop: stop, takes: takes)
                if let rules = ws.exitRules[position.coin] {
                    Label(rules.movedToBreakeven ? "Guardian: stop already at breakeven" : rules.breakevenAfterPartial ? "Guardian: stop to breakeven after the first half" : "Guardian is watching",
                          systemImage: "shield.lefthalf.filled").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 22).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color(hex: 0x0F6B5D), lineWidth: 2))
        }
        .confirmationDialog("\(confirmClose == "close" ? "Close" : "Close half of") \(IntentParser.pretty(position.coin)) at market?",
                            isPresented: Binding(get: { confirmClose != nil }, set: { if !$0 { confirmClose = nil } })) {
            Button(confirmClose == "close" ? "Close position" : "Close half", role: .destructive) {
                // This card's own position, never «the first one».
                let share: Decimal = confirmClose == "close" ? 1 : Decimal(string: "0.5")!
                Task { await ws.manage(.close(share), coin: position.coin) }
                confirmClose = nil
            }
        }
    }
}

/// Take, entry, now and stop on one line; green where the trade makes money, red where it loses.
struct PriceRuler: View {
    let entry: Decimal
    let mark: Decimal?
    let stop: Decimal?
    let takes: [Decimal]

    var body: some View {
        let values = ([entry, mark, stop].compactMap { $0 } + takes).map { NSDecimalNumber(decimal: $0).doubleValue }
        let low = (values.min() ?? 0), high = (values.max() ?? 1)
        let span = max(high - low, 0.0001)
        func x(_ d: Decimal, _ width: CGFloat) -> CGFloat { CGFloat((NSDecimalNumber(decimal: d).doubleValue - low) / span) * (width - 24) + 12 }
        return GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Capsule().fill(.fill.tertiary).frame(height: 8).offset(y: 14)
                if let stop {
                    let a = min(x(entry, w), x(stop, w)), b = max(x(entry, w), x(stop, w))
                    Capsule().fill(Brand.loss.opacity(0.35)).frame(width: b - a, height: 8).offset(x: a, y: 14)
                }
                if let far = takes.max(by: { abs($0 - entry) < abs($1 - entry) }) {
                    let a = min(x(entry, w), x(far, w)), b = max(x(entry, w), x(far, w))
                    Capsule().fill(Brand.profit.opacity(0.35)).frame(width: b - a, height: 8).offset(x: a, y: 14)
                }
                if let mark { RoundedRectangle(cornerRadius: 2).fill(.primary).frame(width: 4, height: 26).offset(x: x(mark, w) - 2, y: 5) }
                let labels = placed([("entry \(Fmt.price(entry))", x(entry, w), Color.secondary)]
                                    + (stop.map { [("stop \(Fmt.price($0))", x($0, w), Brand.loss)] } ?? [])
                                    + takes.map { ("take \(Fmt.price($0))", x($0, w), Brand.profit) })
                ForEach(labels.indices, id: \.self) { i in
                    Text(labels[i].text).font(.system(size: 10, weight: .semibold)).foregroundStyle(labels[i].color).fixedSize()
                        .offset(x: labels[i].x, y: 30 + CGFloat(labels[i].row) * 14)
                }
            }
        }
        .frame(height: 76)
    }

    /// Labels sorted along the bar, each in the first row where it doesn't overlap the previous one.
    private func placed(_ items: [(text: String, x: CGFloat, color: Color)]) -> [(text: String, x: CGFloat, color: Color, row: Int)] {
        var ends: [CGFloat] = []
        return items.sorted { $0.x < $1.x }.map { item in
            let width = CGFloat(item.text.count) * 5.6
            let start = max(0, item.x - width / 2)
            let row = ends.firstIndex { $0 + 6 < start } ?? ends.count
            if row == ends.count { ends.append(start + width) } else { ends[row] = start + width }
            return (item.text, start, item.color, row)
        }
    }
}

/// Where money earns most: one bubble per place, bigger for a higher rate, in the protocol's colors.
struct YieldBubbles: View {
    @Environment(Workspace.self) private var ws
    let options: [Yields.Option]

    var body: some View {
        let top = options.map(\.apy).max() ?? 1
        VStack(alignment: .leading, spacing: 10) {
            Text("RATES NOW · TAP TO PUT THE PHRASE IN THE CHAT").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(Array(options.prefix(8).enumerated()), id: \.offset) { _, o in
                    let size = 96 + 70 * CGFloat(NSDecimalNumber(decimal: o.apy / max(top, 0.0001)).doubleValue)
                    Button { if let how = o.how { ws.draft = how } } label: {
                        VStack(spacing: 3) {
                            TokenLogo(name: logo(o.place), size: 26)
                            Text("\(Fmt.num(o.apy.rounded(2, .plain)))%").font(.system(size: size > 140 ? 24 : 19, weight: .heavy)).monospacedDigit()
                            Text(o.place).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text(o.asset).font(.system(size: 10)).opacity(0.8)
                        }
                        .foregroundStyle(ink(o.place))
                        .frame(width: size, height: size)
                        .background(Circle().fill(fill(o.place)))
                        .overlay(Circle().strokeBorder(o.how == nil ? Brand.dots : .clear, style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .help(o.note)
                }
            }
            Text("Tip: don’t keep everything in one protocol — say “spread USDC across the best rates”.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Brand.cardBorder))
    }

    private func logo(_ place: String) -> String { Workspace.logo(for: place) }
    private func fill(_ place: String) -> Color {
        if place.contains("Jupiter") { return Color(hex: 0x131D27) }
        if place.contains("Kamino") { return Color(hex: 0x082A56) }
        if place.contains("Jito") { return Color(hex: 0x1F9D6A) }
        if place.contains("HLP") { return Brand.hl }
        return Brand.solanaTint
    }
    private func ink(_ place: String) -> Color {
        if place.contains("Jupiter") { return Color(hex: 0xC7F284) }
        if place.contains("HLP") { return Brand.hlMint }
        return place.contains("Kamino") || place.contains("Jito") ? .white : .primary
    }
}

/// «Spread USDC across the best rates»: the free money, where each slice goes, what was skipped and why.
struct AllocationBoard: View {
    @Environment(Workspace.self) private var ws
    let preview: AllocationPreview

    private var unit: String { preview.asset }
    private func amount(_ d: Decimal) -> String { Fmt.num(d, maxFraction: unit == "SOL" ? 6 : 2) + " " + unit }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TokenLogo(name: unit == "SOL" ? "sol" : "usdc", size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TAKE FROM · SOLANA").font(.system(size: 9.5, weight: .heavy)).tracking(0.5).foregroundStyle(Brand.solanaInk)
                    Text("\(amount(preview.free)) free").font(.system(size: 16, weight: .bold))
                }
                Spacer()
                Text("max \(Fmt.pct(preview.maxShare)) per protocol").font(.caption).foregroundStyle(Brand.solanaInk)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 20).fill(Brand.solanaTint))

            ForEach(preview.slices, id: \.place) { slice in
                HStack(spacing: 12) {
                    TokenLogo(name: logo(slice.place), size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DEPOSIT").font(.system(size: 9.5, weight: .heavy)).tracking(0.5).opacity(0.8)
                        Text(slice.place).font(.system(size: 15, weight: .bold))
                        Text(amount(slice.amount)).font(.caption).opacity(0.85)
                    }
                    Spacer()
                    Text("\(Fmt.num(slice.apy.rounded(2, .plain)))%").font(.system(size: 22, weight: .heavy)).monospacedDigit()
                }
                .foregroundStyle(ink(slice.place))
                .padding(14)
                .background(ArrowCard(radius: 20, tip: 14).fill(fill(slice.place)))
            }
            ForEach(preview.skipped, id: \.place) { s in
                HStack(alignment: .top, spacing: 12) {
                    TokenLogo(name: logo(s.place), size: 26).opacity(0.6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(s.place) · \(Fmt.num(s.apy.rounded(2, .plain)))% — skipped").font(.system(size: 13, weight: .semibold))
                        Text(s.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 30).strokeBorder(Brand.dots, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            }
            HStack {
                Text("≈ \(amount(preview.yearly)) a year\(preview.yearlyUSD.map { " (≈ \(Fmt.usd($0)))" } ?? "")").font(.system(size: 16, weight: .bold))
                Spacer()
                if preview.leftover > 0 { Text("stays free: \(amount(preview.leftover))").font(.caption).foregroundStyle(Color(hex: 0xB9C1DC)) }
            }
            .foregroundStyle(.white)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 20).fill(Brand.outcome))
        }
    }

    private func logo(_ place: String) -> String {
        place.contains("Jupiter") ? "jup" : place.contains("Kamino") ? "kamino" : place.contains("Jito") ? "jitosol" : place.contains("HLP") ? "hype" : "usdc"
    }
    private func fill(_ place: String) -> Color {
        place.contains("Jupiter") ? Color(hex: 0x131D27) : place.contains("Kamino") ? Color(hex: 0x082A56) : place.contains("Jito") ? Color(hex: 0x1F9D6A) : Brand.hl
    }
    private func ink(_ place: String) -> Color { place.contains("Jupiter") ? Color(hex: 0xC7F284) : .white }
}

/// Opens the history on the canvas, and back.
struct HistoryButton: View {
    @AppStorage("canvasMode") private var mode = "plan"

    var body: some View {
        Button { withAnimation(.snappy) { mode = mode == "history" ? "plan" : "history" } } label: {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(mode == "history" ? Brand.accent : .secondary)
        }
        .buttonStyle(.hoverIcon)
        .help(mode == "history" ? "Back to the canvas" : "History: what LALA did, positions, everything")
    }
}
