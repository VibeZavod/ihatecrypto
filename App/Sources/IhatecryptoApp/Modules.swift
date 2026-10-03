import AppKit
import Charts
import EVMChain
import ExecutionCore
import Foundation
import IhatecryptoCore
import SwiftUI
import WalletCore

/// A market's candles on the canvas, with the levels that matter for it. Kept with the canvas: reopened, it shows
/// the snapshot and when it was taken, until Refresh.
struct ChartState: Equatable, Codable {
    var coin: String
    var range: ChartCommand.Range
    var candles: [Hyperliquid.Candle] = []
    var error: String?
    /// When the candles were loaded.
    var at: Date?
}

extension Workspace {
    /// Opens a chart, or refreshes the one on the canvas: its old candles stay on screen until the new ones land.
    func openChart(_ coin: String, range: ChartCommand.Range = .day) async {
        if chart?.coin != coin || chart?.range != range { withAnimation(StudioView.spring) { chart = ChartState(coin: coin, range: range) } }
        chart?.error = nil
        UserDefaults.standard.set("plan", forKey: "canvasMode")
        do {
            let candles = try await Hyperliquid.candles(coin: coin, range: range)
            if chart?.coin == coin { chart?.candles = candles; chart?.range = range; chart?.at = Date() }
        } catch {
            chart?.error = error.localizedDescription
        }
    }

    /// «chart ETH», «what's moving».
    func chartCommand(_ command: ChartCommand, note: String? = nil) async {
        switch command {
        case .chart(let coin, let range):
            await openChart(coin, range: range)
            let name = IntentParser.pretty(coin)
            if let c = chart?.candles, let first = c.first, let last = c.last, first.close > 0 {
                let change = signedPct((last.close - first.close) / first.close * 100)
                let days = switch range { case .day: "24 ч"; case .week: "7 дней"; case .month: "30 дней" }
                reply(say("\(name) on the canvas: \(Fmt.price(last.close)), \(change) over \(range.title).",
                          "\(name) на холсте: \(Fmt.price(last.close)), \(change) за \(days)."), note: note)
            } else {
                let why = chart?.error.map { ": \($0)" } ?? "."
                reply(say("The \(name) chart didn’t load\(why)", "График \(name) не загрузился\(why)"), note: note)
            }
        case .movers:
            withAnimation(StudioView.spring) { showMovers = true }
            UserDefaults.standard.set("plan", forKey: "canvasMode")
            let list = moverList()
            let up = list.first.map { "\(IntentParser.pretty($0.coin)) \(signedPct($0.change))" } ?? "—"
            let down = list.last.map { "\(IntentParser.pretty($0.coin)) \(signedPct($0.change))" } ?? "—"
            reply(say("Today’s movers are on the canvas: up the most \(up), down the most \(down). Tap one for its chart.",
                      "Лидеры дня на холсте: сильнее всех вырос \(up), сильнее всех упал \(down). Нажми на любой — откроется график."), note: note)
        }
    }

    /// Markets with a real day of trading (> $1M), by the 24 h change.
    func moverList() -> [(coin: String, price: Decimal, change: Decimal)] {
        markets.values.compactMap { m -> (String, Decimal, Decimal)? in
            guard let prev = m.prevDayPx, prev > 0, m.volume24h > 1_000_000 else { return nil }
            return (m.name, m.markPx, (m.markPx - prev) / prev * 100)
        }
        .sorted { $0.2 > $1.2 }
        .map { (coin: $0.0, price: $0.1, change: $0.2) }
    }

    func toggleDetail(_ place: String) {
        withAnimation(StudioView.spring) { detail = detail == place ? nil : place }
        UserDefaults.standard.set("plan", forKey: "canvasMode")
    }
}

// MARK: Chart

struct ChartBoard: View {
    @Environment(Workspace.self) private var ws
    let state: ChartState
    @State private var refreshing = false

    private struct Level: Identifiable {
        let id: String
        let price: Double
        let label: String
        let color: Color
        let dashed: Bool
    }

    var body: some View {
        let closes = state.candles.map { NSDecimalNumber(decimal: $0.close).doubleValue }
        let lo = closes.min() ?? 0, hi = closes.max() ?? 1
        let levels = self.levels.filter { $0.price > lo * 0.85 && $0.price < hi * 1.15 }
        let bottom = min(lo, levels.map(\.price).min() ?? lo), top = max(hi, levels.map(\.price).max() ?? hi)
        let pad = max((top - bottom) * 0.08, top * 0.001)
        let up = (closes.last ?? 0) >= (closes.first ?? 0)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AssetBadge(coin: state.coin, size: 32, dark: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(IntentParser.pretty(state.coin)).font(.ui(15, .bold))
                    HStack(spacing: 6) {
                        Text(state.candles.last.map { Fmt.price($0.close) } ?? "—").font(.ui(13, .semibold)).monospacedDigit()
                        if let first = closes.first, let last = closes.last, first > 0 {
                            Text(signedPct(Decimal((last - first) / first * 100))).font(.ui(10, .bold))
                                .foregroundStyle(up ? Brand.profit : Brand.loss)
                        }
                    }
                }
                Spacer()
                Picker("", selection: Binding(get: { state.range }, set: { r in Task { await ws.openChart(state.coin, range: r) } })) {
                    ForEach(ChartCommand.Range.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button { withAnimation(StudioView.spring) { ws.chart = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.hoverIcon)
            }
            HStack(spacing: 8) {
                if let at = state.at {
                    Label("As of \(Fmt.date(at))", systemImage: "clock").font(.ui(10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    refreshing = true
                    Task { await ws.openChart(state.coin, range: state.range); refreshing = false }
                } label: {
                    Label(refreshing ? "Updating…" : "Refresh", systemImage: "arrow.clockwise").font(.ui(10, .semibold))
                }
                .buttonStyle(.borderless).disabled(refreshing).help("Load fresh candles from Hyperliquid")
            }
            if closes.count > 1 {
                Chart {
                    ForEach(Array(state.candles.enumerated()), id: \.offset) { _, c in
                        AreaMark(x: .value("Time", c.time), yStart: .value("Base", bottom - pad), yEnd: .value("Price", NSDecimalNumber(decimal: c.close).doubleValue))
                            .foregroundStyle(LinearGradient(colors: [(up ? Brand.profit : Brand.loss).opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", c.time), y: .value("Price", NSDecimalNumber(decimal: c.close).doubleValue))
                            .foregroundStyle(up ? Brand.profit : Brand.loss)
                            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    }
                    ForEach(levels) { l in
                        RuleMark(y: .value(l.label, l.price))
                            .foregroundStyle(l.color)
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: l.dashed ? [4, 3] : []))
                            .annotation(position: .top, alignment: .leading) {
                                Text("\(l.label) \(Fmt.price(Decimal(l.price)))").font(.ui(9.5, .bold)).foregroundStyle(l.color)
                            }
                    }
                }
                .chartYScale(domain: (bottom - pad)...(top + pad))
                .priceAxes(state.range)
                .chartOverlay { proxy in ChartHover(proxy: proxy, points: state.candles.map { ($0.time, NSDecimalNumber(decimal: $0.close).doubleValue) }) }
                .frame(height: 210)
            } else if let error = state.error {
                Text("The chart didn’t load: \(error)").font(.ui(10)).foregroundStyle(Brand.loss)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            Text("Hyperliquid candles · \(state.range.interval)\(levels.isEmpty ? "" : " · lines: your position, its orders and alerts")")
                .font(.ui(10)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 470, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card).shadow(color: .black.opacity(0.06), radius: 14, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.cardBorder))
        .transition(.opacity)
    }

    private var levels: [Level] {
        func d(_ x: Decimal) -> Double { NSDecimalNumber(decimal: x).doubleValue }
        var out: [Level] = []
        if let p = ws.positions.first(where: { $0.coin == state.coin }) {
            out.append(Level(id: "entry", price: d(p.entry), label: p.size > 0 ? "Long entry" : "Short entry", color: Brand.accent, dashed: false))
        }
        for (i, o) in ws.orders.filter({ $0.coin == state.coin && $0.isTrigger }).enumerated() {
            guard let px = o.triggerPx else { continue }
            let stop = (o.orderType ?? "").contains("Stop")
            out.append(Level(id: "o\(i)", price: d(px), label: stop ? "Stop" : "Take", color: stop ? Brand.loss : Brand.profit, dashed: false))
        }
        for a in ws.alerts where a.coin == state.coin {
            out.append(Level(id: a.id.uuidString, price: d(a.price), label: "Alert", color: .orange, dashed: true))
        }
        return out
    }
}

/// The price under the pointer: a line down the chart, a dot on the price and its value and time. Its own view, so
/// moving the pointer redraws the marker, not the chart.
struct ChartHover: View {
    let proxy: ChartProxy
    let points: [(time: Date, price: Double)]
    @State private var index: Int?

    var body: some View {
        GeometryReader { geo in
            let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let p) = phase, let at: Date = proxy.value(atX: p.x - plot.minX) else { index = nil; return }
                        index = points.indices.min { abs(points[$0].time.timeIntervalSince(at)) < abs(points[$1].time.timeIntervalSince(at)) }
                    }
                // A refresh can bring fewer candles while the pointer stays put, so the index may be past the end.
                if let i = index, points.indices.contains(i), let x = proxy.position(forX: points[i].time), let y = proxy.position(forY: points[i].price) {
                    Group {
                        Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 1, height: plot.height).position(x: plot.minX + x, y: plot.midY)
                        Circle().fill(Color.primary).frame(width: 7, height: 7).position(x: plot.minX + x, y: plot.minY + y)
                        Text("\(Fmt.price(Decimal(points[i].price))) · \(Fmt.date(points[i].time))")
                            .font(.ui(11, .semibold)).monospacedDigit().fixedSize()
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Brand.card).shadow(color: .black.opacity(0.15), radius: 3, y: 1))
                            .position(x: min(max(plot.minX + x, plot.minX + 80), plot.maxX - 80), y: max(plot.minY + 10, plot.minY + y - 18))
                    }
                    // The marker must not take the pointer: under it the hover area below ends, the marker goes, the hover
                    // starts again — it blinked once per candle.
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: Movers

struct MoversBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        let list = ws.moverList()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "flame.fill").foregroundStyle(.orange)
                Text("Movers · 24 h").font(.ui(15, .bold))
                Spacer()
                Button { withAnimation(StudioView.spring) { ws.showMovers = false } } label: { Image(systemName: "xmark") }.buttonStyle(.hoverIcon)
            }
            HStack(alignment: .top, spacing: 12) {
                column("UP", Array(list.prefix(6)), up: true)
                column("DOWN", Array(list.suffix(6).reversed()), up: false)
            }
            Text("Hyperliquid markets with over $1M traded today: crypto, stocks, commodities. Tap one for its chart.")
                .font(.ui(10)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 470, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card).shadow(color: .black.opacity(0.06), radius: 14, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.cardBorder))
        .transition(.opacity)
    }

    private func column(_ title: String, _ rows: [(coin: String, price: Decimal, change: Decimal)], up: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(9.5, .heavy)).tracking(0.6).foregroundStyle(up ? Brand.profit : Brand.loss)
            ForEach(rows, id: \.coin) { r in
                Button { Task { await ws.chartCommand(.chart(coin: r.coin, range: .day)) } } label: {
                    HStack(spacing: 8) {
                        AssetBadge(coin: r.coin, size: 24, dark: true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(IntentParser.pretty(r.coin).components(separatedBy: " (").first ?? r.coin).font(.ui(12.5, .semibold)).lineLimit(1)
                            Text(Fmt.price(r.price)).font(.ui(10.5)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(signedPct(r.change)).font(.ui(12, .bold)).monospacedDigit()
                            .foregroundStyle(r.change < 0 ? Brand.loss : Brand.profit)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill((r.change < 0 ? Brand.loss : Brand.profit).opacity(0.07)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(HoverLift(radius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: Place details

/// What a place holds, in detail: the rail's and the portfolio's rows open this.
struct PlaceDetailBoard: View {
    @Environment(Workspace.self) private var ws
    let place: String

    var body: some View {
        // A board per token: another token opened here starts clean, without the last one's badge, market or chart.
        if let token = TokenBoard.parse(place) { TokenBoard(chain: token.chain, address: token.address).id(place) } else { board }
    }

    private var board: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TokenLogo(name: logo, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.ui(16, .bold))
                    Text(subtitle).font(.ui(10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { withAnimation(StudioView.spring) { ws.detail = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.hoverIcon)
            }
            content
            if let link {
                Link(destination: link) { Label("Open in the explorer", systemImage: "arrow.up.right.square") }.font(.ui(10))
            }
            actions
        }
        .padding(16)
        .frame(width: 470, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card).shadow(color: .black.opacity(0.06), radius: 14, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.accent.opacity(0.4), lineWidth: 1.5))
        .transition(.opacity)
    }

    private var logo: String { ["solana": "sol", "hyperliquid": "hype", "jupiter": "jup", "kamino": "kamino", "near": "near", "aave": "aave", "morpho": "morpho", "robinhood": "robinhood"][place] ?? ModuleNetwork(place: place)?.logo ?? "usdc" }
    private var title: String { ["solana": "Solana wallet", "hyperliquid": "Hyperliquid account", "jupiter": "Jupiter Lend", "kamino": "Kamino Lend", "near": "NEAR account", "aave": "Aave v3 · Base", "morpho": "Morpho · Base", "robinhood": "Robinhood Chain", "base": "Base", "arbitrum": "Arbitrum"][place] ?? place }
    private var subtitle: String {
        switch place {
        case "solana": "everything you hold on Solana; every move starts here"
        case "hyperliquid": "margin for perps, stocks and commodities"
        case "jupiter": "lending vaults on Solana · withdraw any time"
        case "kamino": "lending on Solana · withdraw any time"
        case "near": "native NEAR on the NEAR chain · bought through NEAR Intents"
        case "robinhood": "Robinhood Stock Tokens · economic exposure, not shares"
        case "morpho": "\(MorphoVault.name) vault · lending on Base · withdraw any time"
        case "base", "arbitrum": "USDC at your EVM address · free, not earning"
        default: "lending on Base · withdraw any time"
        }
    }
    private var link: URL? {
        switch place {
        case "solana": isSolanaAddress(ws.solanaAddress) ? URL(string: "https://solscan.io/account/\(ws.solanaAddress)") : nil
        case "hyperliquid": isEVMAddress(ws.hlAddress) ? URL(string: "https://app.hyperliquid.xyz/explorer/address/\(ws.hlAddress)") : nil
        case "jupiter": URL(string: "https://jup.ag/lend/earn")
        case "kamino": URL(string: "https://app.kamino.finance")
        case "near": ws.nearAddress.flatMap { URL(string: "https://nearblocks.io/address/\($0)") }
        case "robinhood": isEVMAddress(ws.hlAddress) ? URL(string: "https://robinhoodchain.blockscout.com/address/\(ws.hlAddress)") : nil
        case "morpho": URL(string: "https://app.morpho.org/base/vault/\(MorphoVault.gauntletUSDCPrime)")
        case "arbitrum": isEVMAddress(ws.hlAddress) ? URL(string: "https://arbiscan.io/address/\(ws.hlAddress)") : nil
        default: isEVMAddress(ws.hlAddress) ? URL(string: "https://basescan.org/address/\(ws.hlAddress)") : nil
        }
    }

    @ViewBuilder private var content: some View {
        switch place {
        case "solana":
            if isSolanaAddress(ws.solanaAddress) { addressRow(ws.solanaAddress) }
            networkRows(.solana)
        case "hyperliquid":
            if isEVMAddress(ws.hlAddress) { addressRow(ws.hlAddress) }
            row("hype", "Account value", ws.hl.map { Fmt.usd($0.accountValue) } ?? "—", "free to withdraw \(ws.hl.map { Fmt.usd($0.withdrawable) } ?? "—")")
            ForEach(ws.dexBalances.keys.sorted(), id: \.self) { dex in
                row("hype", "\(dex) exchange (stocks, commodities)", Fmt.usd(ws.dexBalances[dex]?.accountValue ?? 0), "free \(Fmt.usd(ws.dexBalances[dex]?.withdrawable ?? 0))")
            }
            if let spot = ws.hl?.spotUSDC, spot > 0 { row("usdc", "Spot USDC", Fmt.num(spot), "separate from the perp margin") }
            if ws.hlp.equity > 0 {
                row("hype", "HLP vault", Fmt.usd(ws.hlp.equity), ws.hlp.lockedUntil.map { "locked until \(Fmt.date($0)) · 4 days after a deposit" } ?? "earning · withdraw any time")
            }
            ForEach(ws.positions, id: \.coin) { p in
                Button { Task { await ws.chartCommand(.chart(coin: p.coin, range: .day)) } } label: { PositionChip(position: p) }
                    .buttonStyle(.plain).modifier(HoverLift(radius: 12)).help("Open the \(IntentParser.pretty(p.coin)) chart")
            }
            if ws.positions.isEmpty { Text("No open positions.").font(.ui(10)).foregroundStyle(.secondary) }
            Label(ws.agentActive ? (ws.ledgerActive ? "Trading key on: orders skip the Ledger, withdrawals still need it" : "Trading key on: orders skip Touch ID, withdrawals still need it")
                  : ws.ledgerActive ? "Trading key off: every order asks for the Ledger's buttons" : "Trading key paused: every order asks for Touch ID",
                  systemImage: ws.agentActive ? "key.horizontal.fill" : "lock").font(.ui(10)).foregroundStyle(.secondary)
        case "robinhood":
            if isEVMAddress(ws.hlAddress) { addressRow(ws.hlAddress) }
            ForEach(ws.robinhood?.stocks ?? []) { s in
                Button { ws.openToken(s.address) } label: {
                    HStack(spacing: 10) {
                        StockLogo(symbol: s.symbol, url: s.logo, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(s.symbol) · \(s.name)").font(.ui(13, .semibold)).lineLimit(1)
                            Text("\(Fmt.num(s.amount, maxFraction: 6)) tokens · \(s.price.map { Fmt.usd($0) } ?? "—")").font(.ui(10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Fmt.usd(s.usd)).font(.ui(13, .bold)).monospacedDigit()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                    }
                    .padding(9).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).modifier(HoverLift(radius: 12)).help("\(s.symbol): chart and details")
            }
            row("usdg", "USDG", "\(ws.robinhood.map { Fmt.num($0.usdg) } ?? "—")", "gas: \(ws.robinhood.map { Fmt.num($0.eth, maxFraction: 7) } ?? "—") ETH")
            Text("Stock Tokens aren’t offered to US persons, or in Canada, the UK and Switzerland; they give economic exposure, not the shares.")
                .font(.ui(10)).foregroundStyle(.secondary)
        case "near":
            if let a = ws.nearAddress { addressRow(a) }
            row("near", "NEAR", Fmt.num(ws.near, maxFraction: 6), ws.markets["NEAR"].map { "≈ \(Fmt.usd(ws.nearUSD)) at \(Fmt.price($0.markPx))" } ?? "")
            Text("The account is yours from the same phrase (m/44'/397'/0'). Selling NEAR back to USDC isn’t in ihatecrypto yet.")
                .font(.ui(10)).foregroundStyle(.secondary)
        case "morpho":
            if isEVMAddress(ws.hlAddress) { addressRow(ws.hlAddress) }
            row("morpho", "In the vault", "\(ws.base.map { Fmt.num($0.morpho) } ?? "—") USDC",
                ws.morphoAPY.map { "≈ \(Fmt.num($0))% a year after the vault’s fee" } ?? "earning")
            Text("Your USDC is lent by Gauntlet’s curated Morpho markets; the vault shares are only ever credited to this wallet.")
                .font(.ui(10)).foregroundStyle(.secondary)
        case "kamino":
            row("kamino", "USDC", Fmt.usd(ws.kamino), "earning · withdraw any time")
            if let rate = ws.yieldOptions?.first(where: { $0.place.contains("Kamino") && $0.asset == "USDC" })?.apy {
                Text("USDC rate now ≈ \(Fmt.num(rate.rounded(2, .plain)))% a year.").font(.ui(10)).foregroundStyle(.secondary)
            }
        case "jupiter":
            ForEach(ws.lend, id: \.vault) { v in row("jup", v.vault, "\(Fmt.num(v.usdc)) USDC", "earning · withdraw any time") }
            if ws.lend.isEmpty { Text("Nothing in Jupiter Lend yet.").font(.ui(10)).foregroundStyle(.secondary) }
            if let rate = ws.yieldOptions?.first(where: { $0.place.contains("Jupiter") && $0.asset == "USDC" })?.apy {
                Text("USDC rate now ≈ \(Fmt.num(rate.rounded(2, .plain)))% a year.").font(.ui(10)).foregroundStyle(.secondary)
            }
        case "base", "arbitrum":
            if isEVMAddress(ws.hlAddress) { addressRow(ws.hlAddress) }
            if let n = ModuleNetwork(rawValue: place) { networkRows(n) }
        default:
            if isEVMAddress(ws.hlAddress) { addressRow(ws.hlAddress) }
            row("aave", "Supplied", "\(ws.base.map { Fmt.num($0.aave) } ?? "—") USDC", ws.aaveAPY.map { "≈ \(Fmt.num($0.rounded(2, .plain)))% a year" } ?? "")
        }
    }

    /// A network in detail, like Robinhood's stock tokens: the same places and tokens as its card on the portfolio
    /// (idle money, gas, deposits, deposits made on a site, every token on show), a row each, a click opening its board.
    @ViewBuilder private func networkRows(_ n: ModuleNetwork) -> some View {
        ForEach(ws.networkLines(n)) { line in
            detailRow(TokenLogo(name: line.logo, size: 24), title: line.title, detail: line.detail,
                      value: line.usdc ? "\(Fmt.num(line.usd)) USDC" : line.amount ?? Fmt.usd(line.usd),
                      sub: line.amount != nil && line.usd > 0 ? "≈ \(Fmt.usd(line.usd))" : nil,
                      open: line.place.map { p in { withAnimation(StudioView.spring) { ws.detail = p } } })
        }
        ForEach(ws.shownTokens.filter { $0.chain == n.rawValue }) { t in
            // An unverified token's icon URL is its creator's pick: not fetched (HoldingRow's rule).
            detailRow(RemoteIcon(url: t.verified ? t.icon : nil, size: 24) {
                          Circle().fill(Brand.solanaInk.opacity(0.15)).overlay(Text(t.symbol.prefix(1)).font(.ui(10, .bold)).foregroundStyle(Brand.solanaInk))
                      }.frame(width: 24, height: 24).clipShape(Circle()),
                      title: t.symbol + (t.verified ? "" : " · unverified"),
                      detail: "\(Fmt.num(t.amount, maxFraction: 6)) · \(t.price.map { Fmt.usd($0) } ?? "no price")",
                      value: t.usd.map(Fmt.usd) ?? "—", sub: nil,
                      open: { ws.openToken(t.contract, chain: t.chain) })
        }
    }

    private func detailRow(_ logo: some View, title: String, detail: String, value: String, sub: String?, open: (() -> Void)?) -> some View {
        let row = HStack(spacing: 10) {
            logo
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(13, .semibold)).lineLimit(1)
                Text(detail).font(.ui(10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.ui(13, .bold)).monospacedDigit()
                if let sub { Text(sub).font(.ui(10)).foregroundStyle(.secondary).monospacedDigit() }
            }
            if open != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary) }
        }
        .padding(9).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        return Group {
            if let open { Button(action: open) { row }.buttonStyle(.plain).modifier(HoverLift(radius: 12)) } else { row }
        }
    }

    /// A picture for each action, so a button says what it does before it's read: money in, money out, rates, trade.
    static func icon(_ title: String) -> String {
        switch title {
        case "Top up": "arrow.down.circle"
        case "Deposit", "Deposit more", "Lend more", "Lend on Aave", "Buy more": "plus.circle"
        case "Withdraw", "Withdraw all", "Withdraw to Solana", "Move to Solana", "USDG to Solana": "arrow.up.circle"
        case "Best rates": "percent"
        case "Stake SOL": "lock.circle"
        case "Send to a saved address": "paperplane"
        case "Trade by the book": "chart.line.uptrend.xyaxis"
        case "What’s moving": "flame"
        case "Sell": "arrow.left.arrow.right"
        default: title.hasPrefix("Buy") ? "cart" : "arrow.right.circle"
        }
    }

    @ViewBuilder private var actions: some View {
        let phrases: [(String, String)] = switch place {
        case "solana": [("Top up", "top up"), ("Stake SOL", "stake 0.01 SOL"), ("Send to a saved address", "send 1 USDC to ")]
        case "hyperliquid": [("Withdraw to Solana", "withdraw 1 USDC to Solana"), ("Trade by the book", "long ETH by the book"), ("What’s moving", "what's moving?")]
        case "jupiter": [("Deposit", "deposit 1 USDC into Jupiter"), ("Withdraw", "withdraw 1 USDC from Jupiter"), ("Best rates", "where to keep USDC")]
        case "kamino": [("Withdraw all", "withdraw USDC from Kamino"), ("Best rates", "where to keep USDC")]
        case "near": [("Buy more", "buy NEAR for 3 USDC")]
        case "robinhood": [("Buy SpaceX", "buy SpaceX stock for 2 USDC"), ("Sell", "sell my SpaceX shares"), ("USDG to Solana", "move USDG from Robinhood to Solana")]
        case "morpho": [("Deposit more", "deposit 1 USDC into Morpho"), ("Withdraw to Solana", "withdraw USDC from Morpho"), ("Best rates", "where to keep USDC")]
        case "base", "arbitrum": [("Lend on Aave", "lend 1 USDC on Aave on \(title)"), ("Move to Solana", "move USDC from \(title) to Solana"), ("Best rates", "where to keep USDC")]
        default: [("Lend more", "lend 1 USDC on Aave"), ("Withdraw to Solana", "withdraw USDC from Aave"), ("Best rates", "where to keep USDC")]
        }
        // Buttons wrap to a new line rather than run past the card's edge.
        Flow(spacing: 6) {
            ForEach(phrases, id: \.0) { p in
                Button {
                    if p.1 == "top up" { withAnimation(StudioView.spring) { ws.showReceive = true } } else { ws.draft = p.1 }
                } label: {
                    Label(p.0, systemImage: Self.icon(p.0)).font(.ui(12, .semibold)).foregroundStyle(Brand.accentInk)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(Brand.accent.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help(p.1 == "top up" ? "Show your addresses" : "Puts “\(p.1)” into the chat")
            }
        }
    }

    private func row(_ logo: String, _ name: String, _ value: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            TokenLogo(name: logo, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.ui(13, .semibold))
                if !detail.isEmpty { Text(detail).font(.ui(10)).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(value).font(.ui(13, .bold)).monospacedDigit()
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func addressRow(_ address: String) -> some View {
        let ends = AddressCheck.ends(address)
        return HStack(spacing: 6) {
            Text("\(ends.start) … \(ends.end)").font(.system(size: 12, weight: .semibold, design: .monospaced))
            Spacer()
            CopyButton(title: "Copy", text: address, help: "Copy the address")
        }
        .help(address)
    }
}

/// A portfolio card that opens its place's details: a pointer and an accent edge on hover, a stronger one while open.
struct Openable: ViewModifier {
    /// The place a route step's logo names (Solana, Jupiter, Hyperliquid…): its details open from the step's.
    static func place(logo: String) -> String? {
        ["sol": "solana", "hype": "hyperliquid", "jup": "jupiter", "kamino": "kamino", "near": "near", "robinhood": "robinhood", "morpho": "morpho"][logo]
    }

    @Environment(Workspace.self) private var ws
    let place: String
    @State private var hover = false

    func body(content: Content) -> some View {
        let open = ws.detail == place
        let width: CGFloat = open ? 2 : 1.5
        // A fixed-color edge whose opacity fades: an opacity change doesn't re-render the layer (a color change would,
        // every frame, and at up to 4× on a zoomed canvas).
        content
            .overlay {
                RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.accent, lineWidth: width)
                    .opacity(open ? 1 : hover ? 0.6 : 0)
                    .animation(.snappy(duration: 0.18), value: hover)
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .pointerStyle(.link)
            .onTapGesture { ws.toggleDetail(place) }
            .help("Details")
    }
}

/// Where the money sits, as a ring: each network's share, in the colors of its card (NetworkCard).
struct PortfolioRing: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        let slices = PortfolioSplit.slices(ws.networkUSD.map { ($0.key.name, $0.value) })
        let colors = Dictionary(uniqueKeysWithValues: ModuleNetwork.allCases.map { ($0.name, NetworkCard.style($0).dot) })
        if slices.count > 1 {
            HStack(spacing: 12) {
                Chart(slices, id: \.name) { s in
                    SectorMark(angle: .value("Share", NSDecimalNumber(decimal: s.share).doubleValue), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(colors[s.name] ?? .gray)
                        .cornerRadius(3)
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(slices, id: \.name) { s in
                        HStack(spacing: 6) {
                            Circle().fill(colors[s.name] ?? .gray).frame(width: 7, height: 7)
                            Text(s.name).font(.ui(11))
                            Spacer(minLength: 4)
                            Text("\(Fmt.num(s.share.rounded(0, .plain)))%").font(.ui(11, .semibold)).monospacedDigit()
                        }
                    }
                }
            }
            .help("Where the money is now")
        }
    }
}

/// Icon buttons light up under the pointer: an accent wash behind and the accent color; a press deepens the wash.
struct HoverIconStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View { Lit(configuration: configuration, size: size) }

    private struct Lit: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let lit = hover && enabled
            // Only the wash animates, and only its opacity (a fixed-color layer fading isn't re-rendered each frame, even
            // on a zoomed canvas); the icon's color switches at once instead of re-drawing the glyph every frame.
            configuration.label
                .foregroundStyle(lit ? AnyShapeStyle(Brand.accentInk) : AnyShapeStyle(.secondary))
                .frame(minWidth: size, minHeight: size)
                .background {
                    RoundedRectangle(cornerRadius: 8).fill(Brand.accent)
                        .opacity(configuration.isPressed ? 0.24 : lit ? 0.13 : 0)
                        .animation(.snappy(duration: 0.16), value: lit)
                        .animation(.snappy(duration: 0.1), value: configuration.isPressed)
                }
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .pointerStyle(enabled ? .link : nil)
        }
    }
}

extension ButtonStyle where Self == HoverIconStyle {
    static var hoverIcon: HoverIconStyle { HoverIconStyle() }
}

/// Something clickable under the pointer: the hand cursor and an accent edge (a filled card hides the background
/// tint, so the edge is what shows it can be clicked). Cards never move: no lift, no scale — only the border (the user's rule).
/// Wash and edge are fixed colors whose opacity fades: that isn't a re-render per frame, even on a zoomed canvas.
struct HoverLift: ViewModifier {
    var radius: CGFloat = 12
    var enabled = true
    @State private var hover = false

    func body(content: Content) -> some View {
        let on = hover && enabled
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(Color.primary).opacity(on ? 0.07 : 0).animation(.snappy(duration: 0.16), value: on))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Brand.accent, lineWidth: 1.5).opacity(on ? 0.7 : 0).animation(.snappy(duration: 0.16), value: on))
            .onHover { hover = $0 }
            .pointerStyle(enabled ? .link : .default)
    }
}

/// Copies to the clipboard, the same everywhere: the copy icon and its word in a small framed button, then a green
/// check and «Copied» for a moment, so a click always shows it worked (the user: «у таких кнопок одинаковый флоу
/// всегда и стейты»). Without a title it's an icon button for a board's corner. The width never changes between the two.
struct CopyButton: View {
    var title: String?
    let text: String
    var icon = "doc.on.doc"
    var help = "Copy"
    @State private var copiedAt: Date?

    var body: some View {
        let copied = copiedAt != nil
        if let title {
            Button(action: copy) {
                ZStack {
                    face(title, icon).opacity(copied ? 0 : 1)
                    face("Copied", "checkmark").foregroundStyle(Brand.profit).opacity(copied ? 1 : 0)
                }
                .padding(.horizontal, 9).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(copied ? Brand.profit.opacity(0.6) : Brand.cardBorder))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(LitBlock(radius: 8)).help(help)
        } else {
            Button(action: copy) {
                if copied { Image(systemName: "checkmark").foregroundStyle(Brand.profit) } else { Image(systemName: icon) }
            }
            .buttonStyle(.hoverIcon).help(help)
        }
    }

    private func face(_ word: String, _ symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
            Text(word).font(.ui(11.5, .semibold)).lineLimit(1)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let now = Date()
        copiedAt = now
        // A second click restarts the moment rather than being cut short by the first one's end.
        Task { try? await Task.sleep(for: .seconds(1.5)); if copiedAt == now { copiedAt = nil } }
    }
}

extension ClosedRange where Bound == CGFloat {
    func clamped(_ x: CGFloat) -> CGFloat { Swift.min(upperBound, Swift.max(lowerBound, x)) }
}

extension Notification.Name {
    /// ⌘ + scroll wheel over the canvas: userInfo["factor"].
    static let canvasZoom = Notification.Name("canvasZoom")
    /// The rail's «Portfolio»: the canvas back to 100 % with the portfolio in view.
    static let canvasFit = Notification.Name("canvasFit")
    /// The debug API's pan (a measured drag without a hand): userInfo["dx"], ["dy"].
    static let canvasPan = Notification.Name("canvasPan")
}
