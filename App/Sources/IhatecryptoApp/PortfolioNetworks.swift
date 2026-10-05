import ExecutionCore
import IhatecryptoCore
import SwiftUI

/// The portfolio by network (the user's pick of ten, P01 on the design canvas): each network is one card holding
/// everything on it — idle money, deposits, gas, tokens, positions. Solana, Hyperliquid and Robinhood Chain lead;
/// the others follow by money, and those with $100 or less fold under «Other networks» (PortfolioSplit.networkCards).
struct NetworkLine: Identifiable {
    enum Kind { case earning, idle, gas, held }
    var id: String { title + detail }
    let kind: Kind
    let logo: String
    let title: String
    let detail: String
    let usd: Decimal
    /// Shown as USDC (its logo and the amount) rather than in dollars.
    var usdc = false
    /// The amount in its own coin when that says more than dollars («0.0766 NEAR»), with the dollars under it.
    var amount: String? = nil
    /// The details a click opens (Openable).
    var place: String? = nil
    var help: String? = nil
}

extension Workspace {
    /// What each network holds in dollars: its places, its gas, the tokens on show there, Hyperliquid's account and
    /// Robinhood's stock tokens. Adds up to `total`.
    var networkUSD: [ModuleNetwork: Decimal] {
        var out: [ModuleNetwork: Decimal] = [:]
        for n in ModuleNetwork.allCases { out[n] = networkLines(n).reduce(0) { $0 + $1.usd } }
        for t in shownTokens { if let n = ModuleNetwork(rawValue: t.chain) { out[n, default: 0] += t.usd ?? 0 } }
        out[.hyperliquid, default: 0] += hlTotal ?? 0
        out[.robinhood, default: 0] += (robinhood?.stocks ?? []).reduce(0) { $0 + $1.usd }
        return out
    }

    /// A network's places beyond its tokens and stocks, the most money first.
    func networkLines(_ n: ModuleNetwork) -> [NetworkLine] {
        let cent = Decimal(string: "0.01")!
        func idle(_ amount: Decimal?, _ symbol: String = "USDC") -> [NetworkLine] {
            guard let amount, amount >= cent else { return [] }
            return [NetworkLine(kind: .idle, logo: symbol.lowercased(), title: symbol, detail: "idle · not earning", usd: amount, usdc: symbol == "USDC")]
        }
        func gas(_ coin: Decimal?, _ symbol: String) -> [NetworkLine] {
            guard let coin, coin > 0 else { return [] }
            let price = markets[symbol]?.markPx
            return [NetworkLine(kind: .gas, logo: symbol.lowercased(), title: symbol, detail: "\(Fmt.num(coin, maxFraction: 6)) · gas", usd: coin * (price ?? 0),
                                amount: price == nil ? "\(Fmt.num(coin, maxFraction: 6)) \(symbol)" : nil, help: "\(symbol) here pays the network fees on \(n.name)")]
        }
        func earning(_ logo: String, _ title: String, apy: Decimal?, usdc: Decimal, place: String? = nil, help: String? = nil) -> NetworkLine {
            NetworkLine(kind: .earning, logo: logo, title: title, detail: "earning" + (apy.map { " \(Fmt.num($0.rounded(2, .plain)))%" } ?? ""),
                        usd: usdc, usdc: true, place: place, help: help)
        }
        // Aave and Morpho off Base.
        let elsewhere = lendingElsewhere.filter { ModuleNetwork(place: $0.network) == n }.map { p in
            let protocolName = p.place.hasPrefix("Morpho") ? "Morpho" : "Aave"
            return earning(protocolName.lowercased(), protocolName, apy: p.apy, usdc: p.usdc,
                           help: "Say “withdraw USDC from \(protocolName) on \(p.network)” to bring it back to Solana")
        }
        var lines: [NetworkLine]
        switch n {
        case .solana:
            lines = idle(solana?.usdc) + gas(solana?.sol, "SOL")
            if lendTotal > 0 { lines.append(earning("jup", "Jupiter Lend", apy: nil, usdc: lendTotal, place: "jupiter")) }
            if kamino > 0 { lines.append(NetworkLine(kind: .earning, logo: "kamino", title: "Kamino Lend", detail: "earning", usd: kamino, place: "kamino")) }
            // Deposits made on a site: Kamino's vaults, Jupiter's other platforms.
            lines += protocolPositions.map { p in
                NetworkLine(kind: .earning, logo: p.logo, title: p.platform, detail: p.name + (p.apy.map { " · \(Fmt.num($0.rounded(2, .plain)))%" } ?? ""),
                            usd: p.usd, amount: p.amount, help: "Managed on \(p.site): say “открой сайт \(p.site)” to open it beside the chat")
            }
        case .base:
            lines = idle(base?.usdc) + gas(base?.eth, "ETH")
            if let b = base, b.morpho > 0 { lines.append(earning("morpho", "Morpho", apy: morphoAPY, usdc: b.morpho, place: "morpho")) }
            if let b = base, b.aave > 0 { lines.append(earning("aave", "Aave", apy: aaveAPY, usdc: b.aave, place: "aave")) }
        case .arbitrum:
            lines = idle(arbitrumUSDC) + elsewhere
        case .robinhood:
            lines = idle(robinhood?.usdg, "USDG") + gas(robinhood?.eth, "ETH")
        case .near:
            lines = near > 0 ? [NetworkLine(kind: .held, logo: "near", title: "NEAR", detail: "native NEAR", usd: nearUSD, amount: "\(Fmt.num(near, maxFraction: 4)) NEAR")] : []
        case .ethereum, .polygon:
            lines = elsewhere
        case .hyperliquid, .tempo:
            lines = []
        }
        return lines.sorted { $0.usd > $1.usd }
    }
}

/// The network cards in the portfolio frame, in their order, with the small networks folded.
struct NetworkCards: View {
    @Environment(Workspace.self) private var ws
    @State private var unfolded = false

    var body: some View {
        let held = ws.networkUSD
        let present = Set([ws.solana != nil ? ModuleNetwork.solana : nil, ws.hl != nil ? .hyperliquid : nil].compactMap { $0 })
        let order = PortfolioSplit.networkCards(held, present: present)
        VStack(spacing: 10) {
            if !ws.inTransit.isEmpty { InTransit(entries: ws.inTransit) }
            ForEach(order.cards, id: \.self) { NetworkCard(network: $0, usd: held[$0] ?? 0) }
            if !order.folded.isEmpty {
                Button { withAnimation(.snappy) { unfolded.toggle() } } label: {
                    HStack(spacing: 10) {
                        HStack(spacing: -6) { ForEach(order.folded.prefix(4), id: \.self) { TokenLogo(name: $0.logo, size: 22) } }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Other networks").font(.ui(12, .semibold))
                            Text(order.folded.map(\.name).joined(separator: " · ")).font(.ui(10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(Fmt.usd(order.folded.reduce(0) { $0 + (held[$1] ?? 0) })).font(.ui(12, .bold)).monospacedDigit().fixedSize()
                        Image(systemName: unfolded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.cardBorder))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(HoverLift(radius: 16))
                .help(unfolded ? "Fold them again" : "Networks with $100 or less: open to see what's on them")
                if unfolded {
                    ForEach(order.folded, id: \.self) { NetworkCard(network: $0, usd: held[$0] ?? 0) }.transition(.opacity)
                }
            }
        }
    }
}

/// One network: its logo, name, what its money does, its total; then everything on it.
struct NetworkCard: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.colorScheme) private var scheme
    let network: ModuleNetwork
    let usd: Decimal

    /// The networks whose details board exists (PlaceDetailBoard).
    static let opens: Set<ModuleNetwork> = [.solana, .hyperliquid, .robinhood, .base, .arbitrum, .near]

    /// The card's fill, the line under its name, and its color on the ring.
    static func style(_ n: ModuleNetwork) -> (tint: Color, ink: Color, dot: Color) {
        switch n {
        case .solana: (Brand.solanaTint, Brand.solanaInk, Color(hex: 0x9945FF))
        case .hyperliquid: (Brand.hl, Brand.hlMint, Color(hex: 0x2FB39A))
        case .robinhood: (Color(light: 0xF3FFD6, dark: 0x1D2608), Color(light: 0x5A7A00, dark: 0xA8CC3C), Color(light: 0x7FA600, dark: 0xB5D94A))
        case .base: (Color(light: 0xEEF3FF, dark: 0x151C2E), Color(light: 0x0052FF, dark: 0x7EA2FF), Color(hex: 0x0052FF))
        case .arbitrum: (Color(light: 0xEAF5FF, dark: 0x12243A), Color(light: 0x1A6FB0, dark: 0x7CC8FF), Color(hex: 0x28A0F0))
        case .ethereum: (Color(light: 0xEEF0FB, dark: 0x1A1D33), Color(light: 0x4C5FD5, dark: 0xA5B4FC), Color(hex: 0x627EEA))
        case .polygon: (Color(light: 0xF3EDFF, dark: 0x221A36), Color(light: 0x6B32C9, dark: 0xC4A7FF), Color(hex: 0x8247E5))
        case .near: (Color(light: 0xE6FBF3, dark: 0x0E2A20), Color(light: 0x05785A, dark: 0x00EC97), Color(hex: 0x00C08B))
        case .tempo: (Color(light: 0xF1F2F5, dark: 0x22252C), Color(light: 0x5F6470, dark: 0xC5CAD3), Color(hex: 0x8A8F98))
        }
    }

    var body: some View {
        let lines = ws.networkLines(network), style = Self.style(network)
        let card = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TokenLogo(name: network.logo, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    // «Robinhood Chain» beside its amount takes two lines rather than ending in «…».
                    Text(network.name).font(.ui(14, .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    // Wraps rather than ends in «…» next to a wide amount.
                    Text(subtitle(lines)).font(.ui(10)).foregroundStyle(style.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text(Fmt.usd(usd)).font(.ui(13, .bold)).monospacedDigit().lineLimit(1).fixedSize()
            }
            if network == .hyperliquid { positions }
            if network == .robinhood { stocks }
            ForEach(lines) { NetworkLineRow(line: $0, chain: network.rawValue) }
            TokenList(chain: network.rawValue)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(style.tint))
        // Hyperliquid's card is dark green in both modes: its text and rows read as on a dark page.
        .environment(\.colorScheme, network == .hyperliquid ? .dark : scheme)
        if Self.opens.contains(network) { card.modifier(Openable(place: network.rawValue)) } else { card }
    }

    /// What the network's money does («idle $2,532.82 · earning $150.10»), or what it is.
    private func subtitle(_ lines: [NetworkLine]) -> String {
        switch network {
        case .hyperliquid:
            return ws.hlMargin.map { "\(Fmt.usd($0)) · margin" + (ws.hlp.equity > 0 ? " · HLP \(Fmt.usd(ws.hlp.equity))" : "") } ?? "no address"
        case .tempo:
            return "USDC for paid services"
        default:
            let sums = [("earning", NetworkLine.Kind.earning), ("idle", .idle)]
                .map { name, kind in (name, lines.filter { $0.kind == kind }.reduce(Decimal(0)) { $0 + $1.usd }) }
                .filter { $0.1 >= Decimal(string: "0.01")! }.sorted { $0.1 > $1.1 }
            let stocks = ws.robinhood?.stocks.count ?? 0
            // Stock tokens and tokens bought by contract alike.
            let parts = (network == .robinhood && stocks > 0 ? ["\(stocks) token\(stocks == 1 ? "" : "s")"] : [])
                + sums.map { "\($0.0) \(Fmt.usd($0.1))" }
            let tokens = ws.shownTokens.contains { $0.chain == network.rawValue }
            return parts.isEmpty ? (lines.first?.detail ?? (tokens ? "tokens" : "nothing here yet")) : parts.joined(separator: " · ")
        }
    }

    /// Hyperliquid's open positions (a click opens the chart) and a limit entry waiting on the book.
    @ViewBuilder private var positions: some View {
        ForEach(ws.positions, id: \.coin) { p in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(p.size > 0 ? "Long" : "Short") \(IntentParser.pretty(p.coin))").font(.ui(13, .semibold)).lineLimit(1)
                    Spacer()
                    Text(signed(p.unrealizedPnl)).font(.ui(13, .bold)).monospacedDigit()
                        .foregroundStyle(p.unrealizedPnl < 0 ? Color(hex: 0xFF9C8F) : Brand.hlMint)
                }
                Text(ws.positionSummary(p)).font(.ui(10)).foregroundStyle(Brand.hlSoft).lineLimit(2)
                if let rules = ws.exitRules[p.coin] {
                    Label(rules.duties.joined(separator: " "), systemImage: "shield.lefthalf.filled")
                        .font(.ui(10)).foregroundStyle(Brand.hlMint).lineLimit(2)
                }
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.hlChip))
            .contentShape(Rectangle())
            .modifier(HoverLift(radius: 12))
            .onTapGesture { Task { await ws.chartCommand(.chart(coin: p.coin, range: .day)) } }
            .help("Open the \(IntentParser.pretty(p.coin)) chart")
        }
        if let o = ws.pendingEntry {
            Text("Limit waiting: \(o.side == "B" ? "long" : "short") \(IntentParser.pretty(o.coin)) at \(o.limitPx.map(Fmt.price) ?? "?")")
                .font(.ui(10)).foregroundStyle(Brand.hlSoft)
        }
    }

    /// Robinhood Chain's stock tokens and tokens bought by contract, the most money first; a click opens the token,
    /// right-click asks the chat about it or trades it.
    private var stocks: some View {
        ForEach((ws.robinhood?.stocks ?? []).sorted { $0.usd > $1.usd }) { s in
            HStack(spacing: 8) {
                StockLogo(symbol: s.symbol, url: s.logo, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.symbol).font(.ui(12, .semibold)).lineLimit(1)
                    Text("\(Fmt.num(s.amount, maxFraction: 6)) · \(s.price.map { Fmt.usd($0) } ?? "—")").font(.ui(9.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(Fmt.usd(s.usd)).font(.ui(12, .bold)).monospacedDigit()
            }
            .modifier(RowLink(action: { ws.openToken(s.address) }, help: "\(s.symbol): details and chart · right-click to ask the chat, buy or sell"))
            .modifier(TokenMenu(chain: "robinhood", address: s.address, symbol: s.symbol, stock: TokenBoard.isStock(s.symbol), verified: true))
        }
    }
}

/// A row that opens something: the hand cursor and the accent edge a little off the row (the user's rule for anything
/// clickable), then the click. Without an action it's just the row.
struct RowLink: ViewModifier {
    let action: (() -> Void)?
    var help = ""

    func body(content: Content) -> some View {
        if let action {
            content.padding(.horizontal, 5).padding(.vertical, 3)
                .contentShape(Rectangle())
                .modifier(HoverLift(radius: 8))
                .onTapGesture(perform: action)
                .help(help)
                .padding(.horizontal, -5).padding(.vertical, -3)
        } else {
            content
        }
    }
}

/// A place on a network's card: logo, name, what it does, the money. A deposit with a details board opens it; a
/// network's own coin (SOL, ETH, NEAR) opens its chart, and right-click asks the chat about it.
struct NetworkLineRow: View {
    @Environment(Workspace.self) private var ws
    let line: NetworkLine
    let chain: String

    var body: some View {
        let row = HStack(spacing: 8) {
            TokenLogo(name: line.logo, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(line.title).font(.ui(12, .semibold)).lineLimit(1)
                Text(line.detail).font(.ui(9.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                if line.usdc {
                    HStack(spacing: 3) {
                        TokenLogo(name: "usdc", size: 12)
                        Text(Fmt.num(line.usd)).font(.ui(12, .bold)).monospacedDigit()
                    }
                } else {
                    Text(line.amount ?? Fmt.usd(line.usd)).font(.ui(12, .bold)).monospacedDigit().lineLimit(1)
                }
                if line.amount != nil, line.usd > 0 { Text("≈ \(Fmt.usd(line.usd))").font(.ui(9)).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
        .contentShape(Rectangle())
        .help(line.help ?? "")
        // The accent edge a little off the row, so it doesn't touch the logo and the amount.
        if let place = line.place {
            row.padding(.horizontal, 5).padding(.vertical, 3).modifier(Openable(place: place)).padding(.horizontal, -5).padding(.vertical, -3)
        } else if line.kind == .gas || line.kind == .held {
            row.modifier(RowLink(action: ws.opener(chain: chain, contract: "native", symbol: line.title), help: "\(line.title): chart · right-click to ask the chat"))
                .modifier(TokenMenu(chain: chain, address: nil, symbol: line.title))
        } else {
            row
        }
    }
}

/// Money between networks: each bridge order signed and not landed yet (Journal.inTransit), with how long it's been on
/// its way; it leaves the list once its bridge says it settled or went back.
struct InTransit: View {
    let entries: [Journal.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("In transit", systemImage: "arrow.triangle.swap").font(.ui(12, .semibold))
            ForEach(entries, id: \.id) { e in
                HStack(spacing: 8) {
                    TokenLogo(name: e.chain == "1click" ? "near" : e.chain == "cctp" ? "usdc" : "relay", size: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.what(e.note)).font(.ui(11.5)).lineLimit(1)
                        Text("\(e.chain == "1click" ? "NEAR Intents" : e.chain == "cctp" ? "Circle's CCTP" : "Relay") · on its way \(Self.since(e.at))").font(.ui(9.5)).foregroundStyle(.secondary)
                    }
                }
                .help("Signed at \(Fmt.date(e.at)); it shows here until the bridge says it landed or went back. Order \(e.id)")
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.accent.opacity(0.5)))
    }

    /// The journal's note without its transaction: «Base USDC→Solana 5, tx 0x…» → «Base USDC→Solana 5».
    static func what(_ note: String) -> String { note.components(separatedBy: ", tx ").first ?? note }

    static func since(_ at: Date, now: Date = Date()) -> String {
        let minutes = Int(now.timeIntervalSince(at) / 60)
        return minutes < 1 ? "for under a minute" : minutes < 60 ? "for \(minutes) min" : "for \(minutes / 60) h \(minutes % 60) min"
    }
}
