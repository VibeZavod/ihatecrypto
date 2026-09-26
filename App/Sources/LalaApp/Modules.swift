import AppKit
import Charts
import ExecutionCore
import Foundation
import LalaCore
import SwiftUI
import WalletCore

/// A market's candles on the canvas, with the levels that matter for it.
struct ChartState: Equatable {
    var coin: String
    var range: ChartCommand.Range
    var candles: [Hyperliquid.Candle] = []
    var error: String?
}

extension Workspace {
    func openChart(_ coin: String, range: ChartCommand.Range = .day) async {
        withAnimation(StudioView.spring) { chart = ChartState(coin: coin, range: range) }
        UserDefaults.standard.set("plan", forKey: "canvasMode")
        do {
            let candles = try await Hyperliquid.candles(coin: coin, range: range)
            if chart?.coin == coin { chart?.candles = candles; chart?.range = range }
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
                reply("\(name) on the canvas: \(Fmt.price(last.close)), \(signedPct((last.close - first.close) / first.close * 100)) over \(range.title).", note: note)
            } else {
                reply("The \(name) chart didn’t load\(chart?.error.map { ": \($0)" } ?? ".")", note: note)
            }
        case .movers:
            withAnimation(StudioView.spring) { showMovers = true }
            UserDefaults.standard.set("plan", forKey: "canvasMode")
            let list = moverList()
            let up = list.first.map { "\(IntentParser.pretty($0.coin)) \(signedPct($0.change))" } ?? "—"
            let down = list.last.map { "\(IntentParser.pretty($0.coin)) \(signedPct($0.change))" } ?? "—"
            reply("Today’s movers are on the canvas: up the most \(up), down the most \(down). Tap one for its chart.", note: note)
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
                    Text(IntentParser.pretty(state.coin)).font(.system(size: 15, weight: .bold))
                    HStack(spacing: 6) {
                        Text(state.candles.last.map { Fmt.price($0.close) } ?? "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        if let first = closes.first, let last = closes.last, first > 0 {
                            Text(signedPct(Decimal((last - first) / first * 100))).font(.caption.weight(.bold))
                                .foregroundStyle(up ? Brand.profit : Brand.loss)
                        }
                    }
                }
                Spacer()
                Picker("", selection: Binding(get: { state.range }, set: { r in Task { await ws.openChart(state.coin, range: r) } })) {
                    ForEach(ChartCommand.Range.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button { withAnimation(StudioView.spring) { ws.chart = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
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
                                Text("\(l.label) \(Fmt.price(Decimal(l.price)))").font(.system(size: 9.5, weight: .bold)).foregroundStyle(l.color)
                            }
                    }
                }
                .chartYScale(domain: (bottom - pad)...(top + pad))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .frame(height: 210)
            } else if let error = state.error {
                Text("The chart didn’t load: \(error)").font(.caption).foregroundStyle(Brand.loss)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            Text("Hyperliquid candles · \(state.range.interval)\(levels.isEmpty ? "" : " · lines: your position, its orders and alerts")")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 470, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card).shadow(color: .black.opacity(0.06), radius: 14, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.cardBorder))
        .transition(.scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity))
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

// MARK: Movers

struct MoversBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        let list = ws.moverList()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "flame.fill").foregroundStyle(.orange)
                Text("Movers · 24 h").font(.system(size: 15, weight: .bold))
                Spacer()
                Button { withAnimation(StudioView.spring) { ws.showMovers = false } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            HStack(alignment: .top, spacing: 12) {
                column("UP", Array(list.prefix(6)), up: true)
                column("DOWN", Array(list.suffix(6).reversed()), up: false)
            }
            Text("Hyperliquid markets with over $1M traded today: crypto, stocks, commodities. Tap one for its chart.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 470, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card).shadow(color: .black.opacity(0.06), radius: 14, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.cardBorder))
        .transition(.scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity))
    }

    private func column(_ title: String, _ rows: [(coin: String, price: Decimal, change: Decimal)], up: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9.5, weight: .heavy)).tracking(0.6).foregroundStyle(up ? Brand.profit : Brand.loss)
            ForEach(rows, id: \.coin) { r in
                Button { Task { await ws.chartCommand(.chart(coin: r.coin, range: .day)) } } label: {
                    HStack(spacing: 8) {
                        AssetBadge(coin: r.coin, size: 24, dark: true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(IntentParser.pretty(r.coin).components(separatedBy: " (").first ?? r.coin).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            Text(Fmt.price(r.price)).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(signedPct(r.change)).font(.system(size: 12, weight: .bold)).monospacedDigit()
                            .foregroundStyle(r.change < 0 ? Brand.loss : Brand.profit)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill((r.change < 0 ? Brand.loss : Brand.profit).opacity(0.07)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TokenLogo(name: logo, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 16, weight: .bold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { withAnimation(StudioView.spring) { ws.detail = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            content
            if let link {
                Link(destination: link) { Label("Open in the explorer", systemImage: "arrow.up.right.square") }.font(.caption)
            }
            actions
        }
        .padding(16)
        .frame(width: 470, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card).shadow(color: .black.opacity(0.06), radius: 14, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.accent.opacity(0.4), lineWidth: 1.5))
        .transition(.scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity))
    }

    private var logo: String { ["solana": "sol", "hyperliquid": "hype", "jupiter": "jup", "aave": "aave"][place] ?? "usdc" }
    private var title: String { ["solana": "Solana wallet", "hyperliquid": "Hyperliquid account", "jupiter": "Jupiter Lend", "aave": "Aave v3 · Base"][place] ?? place }
    private var subtitle: String {
        switch place {
        case "solana": "USDC and SOL you hold; every move starts here"
        case "hyperliquid": "margin for perps, stocks and commodities"
        case "jupiter": "lending vaults on Solana · withdraw any time"
        default: "lending on Base · bridged from Solana"
        }
    }
    private var link: URL? {
        switch place {
        case "solana": isSolanaAddress(ws.solanaAddress) ? URL(string: "https://solscan.io/account/\(ws.solanaAddress)") : nil
        case "hyperliquid": isEVMAddress(ws.hlAddress) ? URL(string: "https://app.hyperliquid.xyz/explorer/address/\(ws.hlAddress)") : nil
        case "jupiter": URL(string: "https://jup.ag/lend/earn")
        default: isEVMAddress(ws.hlAddress) ? URL(string: "https://basescan.org/address/\(ws.hlAddress)") : nil
        }
    }

    @ViewBuilder private var content: some View {
        switch place {
        case "solana":
            if isSolanaAddress(ws.solanaAddress) { addressRow(ws.solanaAddress) }
            row("usdc", "USDC", ws.solana.map { Fmt.num($0.usdc) } ?? "—", "≈ \(ws.solana.map { Fmt.usd($0.usdc) } ?? "—")")
            row("sol", "SOL", ws.solana.map { Fmt.num($0.sol, maxFraction: 4) } ?? "—",
                ws.solana.flatMap { s in ws.markets["SOL"].map { "≈ \(Fmt.usd(s.sol * $0.markPx)) · fees need ≈ 0.02" } } ?? "")
        case "hyperliquid":
            if isEVMAddress(ws.hlAddress) { addressRow(ws.hlAddress) }
            row("hype", "Account value", ws.hl.map { Fmt.usd($0.accountValue) } ?? "—", "free to withdraw \(ws.hl.map { Fmt.usd($0.withdrawable) } ?? "—")")
            ForEach(ws.dexBalances.keys.sorted(), id: \.self) { dex in
                row("hype", "\(dex) exchange (stocks, commodities)", Fmt.usd(ws.dexBalances[dex]?.accountValue ?? 0), "free \(Fmt.usd(ws.dexBalances[dex]?.withdrawable ?? 0))")
            }
            if let spot = ws.hl?.spotUSDC, spot > 0 { row("usdc", "Spot USDC", Fmt.num(spot), "separate from the perp margin") }
            ForEach(ws.positions, id: \.coin) { p in
                Button { Task { await ws.chartCommand(.chart(coin: p.coin, range: .day)) } } label: { PositionChip(position: p) }
                    .buttonStyle(.plain).help("Open the \(IntentParser.pretty(p.coin)) chart")
            }
            if ws.positions.isEmpty { Text("No open positions.").font(.caption).foregroundStyle(.secondary) }
            Label(ws.agentActive ? "Trading key on: orders skip Touch ID, withdrawals still need it" : "Trading key paused: every order asks for Touch ID",
                  systemImage: ws.agentActive ? "key.horizontal.fill" : "lock").font(.caption).foregroundStyle(.secondary)
        case "jupiter":
            ForEach(ws.lend, id: \.vault) { v in row("jup", v.vault, "\(Fmt.num(v.usdc)) USDC", "earning · withdraw any time") }
            if ws.lend.isEmpty { Text("Nothing in Jupiter Lend yet.").font(.caption).foregroundStyle(.secondary) }
            if let rate = ws.yieldOptions?.first(where: { $0.place.contains("Jupiter") && $0.asset == "USDC" })?.apy {
                Text("USDC rate now ≈ \(Fmt.num(rate.rounded(2, .plain)))% a year.").font(.caption).foregroundStyle(.secondary)
            }
        default:
            if isEVMAddress(ws.hlAddress) { addressRow(ws.hlAddress) }
            row("aave", "Supplied", "\(ws.base.map { Fmt.num($0.aave) } ?? "—") USDC", ws.aaveAPY.map { "≈ \(Fmt.num($0.rounded(2, .plain)))% a year" } ?? "")
            row("base", "Idle on Base", "\(ws.base.map { Fmt.num($0.usdc) } ?? "—") USDC", "gas: \(ws.base.map { Fmt.num($0.eth, maxFraction: 7) } ?? "—") ETH")
        }
    }

    @ViewBuilder private var actions: some View {
        let phrases: [(String, String)] = switch place {
        case "solana": [("Top up", "top up"), ("Stake SOL", "stake 0.01 SOL"), ("Send to a saved address", "send 1 USDC to ")]
        case "hyperliquid": [("Withdraw to Solana", "withdraw 1 USDC to Solana"), ("Trade by the book", "long ETH by the book"), ("What’s moving", "what's moving?")]
        case "jupiter": [("Deposit", "deposit 1 USDC into Jupiter"), ("Withdraw", "withdraw 1 USDC from Jupiter"), ("Best rates", "where to keep USDC")]
        default: [("Lend more", "lend 1 USDC on Aave"), ("Withdraw to Solana", "withdraw USDC from Aave"), ("Best rates", "where to keep USDC")]
        }
        HStack(spacing: 6) {
            ForEach(phrases, id: \.0) { p in
                Button {
                    if p.1 == "top up" { withAnimation(StudioView.spring) { ws.showReceive = true } } else { ws.draft = p.1 }
                } label: {
                    Text(p.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.accent)
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
                Text(name).font(.system(size: 13, weight: .semibold))
                if !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(value).font(.system(size: 13, weight: .bold)).monospacedDigit()
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func addressRow(_ address: String) -> some View {
        let ends = AddressCheck.ends(address)
        return HStack(spacing: 6) {
            Text("\(ends.start) … \(ends.end)").font(.system(size: 12, weight: .semibold, design: .monospaced))
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            .buttonStyle(.borderless).font(.caption)
        }
        .help(address)
    }
}

/// A portfolio card that opens its place's details: a pointer and a lift on hover, an outline while open.
struct Openable: ViewModifier {
    @Environment(Workspace.self) private var ws
    let place: String
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.accent, lineWidth: ws.detail == place ? 2 : 0))
            .scaleEffect(hover ? 1.015 : 1)
            .animation(.snappy(duration: 0.18), value: hover)
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onTapGesture { ws.toggleDetail(place) }
            .help("Details")
    }
}

/// Where the money sits, as a ring: Solana, Hyperliquid, Jupiter Lend, Aave on Base.
struct PortfolioRing: View {
    @Environment(Workspace.self) private var ws

    static let colors: [String: Color] = ["Solana": Color(hex: 0x9945FF), "Hyperliquid": Color(hex: 0x2FB39A), "Jupiter Lend": Color(hex: 0xC7F284), "Aave · Base": Color(hex: 0xB6509E)]

    var body: some View {
        let slices = PortfolioSplit.slices([
            ("Solana", (ws.solana?.usdc ?? 0) + (ws.solana.flatMap { s in ws.markets["SOL"].map { s.sol * $0.markPx } } ?? 0)),
            ("Hyperliquid", ws.hlTotal ?? 0),
            ("Jupiter Lend", ws.lendTotal),
            ("Aave · Base", ws.base.map { $0.aave + $0.usdc } ?? 0),
        ])
        if slices.count > 1 {
            HStack(spacing: 12) {
                Chart(slices, id: \.name) { s in
                    SectorMark(angle: .value("Share", NSDecimalNumber(decimal: s.share).doubleValue), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(Self.colors[s.name] ?? .gray)
                        .cornerRadius(3)
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(slices, id: \.name) { s in
                        HStack(spacing: 6) {
                            Circle().fill(Self.colors[s.name] ?? .gray).frame(width: 7, height: 7)
                            Text(s.name).font(.system(size: 11))
                            Spacer(minLength: 4)
                            Text("\(Fmt.num(s.share.rounded(0, .plain)))%").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        }
                    }
                }
            }
            .help("Where the money is now")
        }
    }
}
