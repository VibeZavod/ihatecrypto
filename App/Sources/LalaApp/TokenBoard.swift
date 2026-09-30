import AppKit
import Charts
import LalaCore
import SwiftUI

extension Workspace {
    /// A token held on Robinhood Chain, opened on the canvas in place of the chain's card.
    func openToken(_ address: String, chain: String = "robinhood") {
        withAnimation(StudioView.spring) { detail = TokenBoard.place(chain: chain, address: address) }
        UserDefaults.standard.set("plan", forKey: "canvasMode")
    }
}

/// One token on the canvas: its price and chart, the market around it (DexScreener's deepest pair, GeckoTerminal's
/// history of that pool) and what you hold. It lives in `ws.detail` as «token:<chain>:<contract>».
struct TokenBoard: View {
    @Environment(Workspace.self) private var ws
    let chain: String
    let address: String
    @State private var market: TokenMarket.Info?
    @State private var points: [TokenMarket.Point] = []
    @State private var range: ChartCommand.Range = .day
    @State private var error: String?
    /// The chart point under the pointer. The board holds it but never reads it: only the price line and the marker
    /// do, so a mouse move over the chart redraws those two, not the chart, the stats and the rest of the board.
    @State private var pointer = ChartPointer()
    @State private var copied = false
    /// Checked by a list a copy can't get onto: Jupiter's on Solana, Robinhood's registry for its stock tokens.
    @State private var verified: (by: String, ok: Bool)?

    static func place(chain: String, address: String) -> String { "token:\(chain):\(address)" }

    static func parse(_ place: String) -> (chain: String, address: String)? {
        let parts = place.split(separator: ":")
        return parts.count == 3 && parts[0] == "token" ? (String(parts[1]), String(parts[2])) : nil
    }

    private var holding: StockHolding? { ws.robinhood?.stocks.first { $0.address.lowercased() == address.lowercased() } }
    private var favorite: FavoriteToken? { ws.favoriteTokens.first { $0.chain == chain && $0.address.lowercased() == address.lowercased() } }
    private var symbol: String { holding?.symbol ?? favorite?.symbol ?? market?.symbol ?? "Token" }
    private var fullName: String { holding?.name ?? favorite?.name ?? market?.name ?? symbol }
    /// «Space Exploration Technologies Corp. Class A Common Stock» → «Space Exploration Technologies».
    private var name: String {
        let cut = [" Corp", ", Inc", " Inc.", " Class ", " Common Stock", " Ltd"].compactMap { fullName.range(of: $0)?.lowerBound }.min()
        return cut.map { String(fullName[..<$0]) } ?? fullName
    }
    /// A Robinhood Stock Token (bought by its ticker); anything else here was bought by its contract.
    private var isStock: Bool { (UserDefaults.standard.stringArray(forKey: "stockTokens") ?? []).contains(symbol.uppercased()) }
    private var chainTitle: String { chain == "robinhood" ? "Robinhood Chain" : chain.capitalized }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            price
            chart
            if let m = market { stats(m) }
            if let h = holding { held(h) }
            links
            actions
        }
        .padding(16)
        .frame(width: 470, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card).shadow(color: .black.opacity(0.06), radius: 14, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.accent.opacity(0.4), lineWidth: 1.5))
        .transition(.opacity)
        .task(id: address) {
            market = try? await TokenMarket.info(address, chain: chain)
            if market == nil { error = "No pool trades this token on \(chainTitle)." }
            if chain == "solana" { verified = await TokenResearch.solanaToken(address).map { ("Jupiter", $0.verified) } }
            else if holding != nil || isStock { verified = ("Robinhood's registry", true) }
        }
        .task(id: "\(market?.pool ?? "")·\(range)") {
            guard let pool = market?.pool else { return }
            do {
                points = try await TokenMarket.history(chain: chain, pool: pool, range: range)
                // A point from the previous range isn't on this chart: the price line goes back to the price now.
                pointer.point = nil
                error = points.count > 1 ? nil : "No trades in this period."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 10) {
            if chain == "robinhood" {
                Button { withAnimation(StudioView.spring) { ws.detail = "robinhood" } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.hoverIcon).help("Back to Robinhood Chain")
            }
            if let h = holding {
                StockLogo(symbol: h.symbol, url: market?.imageURL ?? h.logo, size: 38)
            } else if let f = favorite {
                TokenIcon(token: f, size: 38)
            } else {
                StockLogo(symbol: symbol, url: market?.imageURL, size: 38)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(name).font(.ui(16, .bold)).lineLimit(1).help(fullName)
                    if let v = verified {
                        if v.ok { VerifiedBadge(size: 15, source: v.by) }
                        else { Text("not verified").font(.ui(10, .semibold)).foregroundStyle(Brand.jevInk).help("\(v.by) hasn't verified it: it may be a copy under a famous name") }
                    }
                }
                Text([symbol, chainTitle, market.map { "\($0.dex) · \($0.quote) pool" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.ui(10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { withAnimation(StudioView.spring) { ws.detail = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.hoverIcon)
        }
    }

    /// The price now, or at the pointer on the chart, and the move over the range.
    private var price: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PointerPrice(pointer: pointer, now: market?.priceUSD ?? points.last?.close ?? holding?.price, change: rangeChange, rangeTitle: range.title)
                .layoutPriority(1)
            Spacer()
            Picker("", selection: $range) {
                ForEach(ChartCommand.Range.allCases, id: \.self) { r in Text(["24h", "7d", "30d"][ChartCommand.Range.allCases.firstIndex(of: r) ?? 0]).tag(r) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private var rangeChange: Decimal? {
        guard let first = points.first?.close, let last = points.last?.close, first > 0 else { return market?.changes["h24"] }
        return (last - first) / first * 100
    }

    @ViewBuilder private var chart: some View {
        let closes = points.map { NSDecimalNumber(decimal: $0.close).doubleValue }
        if closes.count > 1, let lo = closes.min(), let hi = closes.max() {
            let pad = max((hi - lo) * 0.1, hi * 0.002)
            let tint = (rangeChange ?? 0) < 0 ? Brand.loss : Brand.profit
            Chart {
                ForEach(points, id: \.time) { p in
                    AreaMark(x: .value("Time", p.time), yStart: .value("Base", lo - pad), yEnd: .value("Price", NSDecimalNumber(decimal: p.close).doubleValue))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", p.time), y: .value("Price", NSDecimalNumber(decimal: p.close).doubleValue))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .priceAxes(range)
            .chartOverlay { proxy in TokenChartHover(proxy: proxy, points: points, pointer: pointer, tint: tint) }
            .frame(height: 190)
        } else if let error {
            Label(error, systemImage: "chart.xyaxis.line").font(.ui(10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 190)
        }
    }

    private func stats(_ m: TokenMarket.Info) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Flow(spacing: 6) {
                ForEach([("m5", "5m"), ("h1", "1h"), ("h6", "6h"), ("h24", "24h")], id: \.0) { key, title in
                    if let c = m.changes[key] {
                        HStack(spacing: 4) {
                            Text(title).foregroundStyle(.secondary)
                            Text(signedPct(c)).foregroundStyle(c < 0 ? Brand.loss : Brand.profit)
                        }
                        .font(.ui(11, .semibold)).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                    }
                }
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    stat(isStock ? "Tokenized value" : "Market cap", (m.marketCap ?? m.fdv).map(compact))
                    stat("Liquidity", m.liquidityUSD.map(compact))
                    stat("Volume 24h", m.volume24h.map(compact))
                }
                GridRow {
                    stat("Buys 24h", m.buys24h.map { Fmt.num(Decimal($0), maxFraction: 0) })
                    stat("Sells 24h", m.sells24h.map { Fmt.num(Decimal($0), maxFraction: 0) })
                    stat("Pool since", m.created.map { $0.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US")).day().month(.abbreviated)) })
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.ui(9.5, .semibold)).tracking(0.5).foregroundStyle(.secondary)
            Text(value ?? "—").font(.ui(14, .bold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func held(_ h: StockHolding) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wallet.pass.fill").foregroundStyle(Brand.accentInk)
            VStack(alignment: .leading, spacing: 1) {
                Text("You hold \(Fmt.num(h.amount, maxFraction: 6)) \(h.symbol)").font(.ui(13, .semibold))
                Text(isStock ? "valued at Robinhood’s bid \(h.price.map(tokenPrice) ?? "—")" : "valued at the pool price").font(.ui(10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Fmt.usd(h.usd)).font(.ui(15, .bold)).monospacedDigit()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.accent.opacity(0.08)))
    }

    /// Wraps: a token with many socials must not spill past the card.
    private var links: some View {
        Flow(spacing: 14) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Label(copied ? "Copied" : "\(address.prefix(6))…\(address.suffix(4))", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, design: .monospaced))
            }
            .help(address)
            ForEach(market?.links ?? [], id: \.url) { Link($0.label, destination: $0.url) }
            if let pair = market?.pairURL { Link("DexScreener", destination: pair) }
            if chain == "robinhood", let url = URL(string: "https://robinhoodchain.blockscout.com/token/\(address)") { Link("Explorer", destination: url) }
        }
        .buttonStyle(.borderless).font(.ui(10)).tint(Brand.accent).foregroundStyle(Brand.accentInk)
    }

    private var actions: some View {
        let buy = isStock ? "buy \(symbol) stock for 2 USDC" : "buy token \(address) for 2 USDC"
        let sell = isStock ? "sell \(symbol) stock" : "sell token \(address)"
        // Tokens by contract are bought on Robinhood Chain, and on Solana with Safe search off; elsewhere they can be watched.
        let phrases = chain == "robinhood" ? [("Buy \(symbol)", buy), ("Sell", sell)]
            : chain == "solana" && !ws.safeSearch ? [("Buy \(symbol)", "buy token \(address) for 2 USDC"), ("Sell", "sell tokens \(address)")]
            : favorite == nil ? [("Watch \(symbol)", "watch token \(address) on \(chain)")] : []
        return HStack(spacing: 6) {
            ForEach(phrases, id: \.0) { title, phrase in
                Button { ws.draft = phrase } label: {
                    Text(title).font(.ui(12, .semibold)).foregroundStyle(title == "Sell" ? Brand.loss : Brand.accentInk)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill((title == "Sell" ? Brand.loss : Brand.accent).opacity(0.1)))
                }
                .buttonStyle(.plain).pointerStyle(.link).help("Puts “\(phrase)” into the chat")
            }
            Spacer(minLength: 8)
            Text("DexScreener · GeckoTerminal").font(.ui(10)).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    /// $218.7M, $1.3M, $12K.
    private func compact(_ d: Decimal) -> String {
        d.formatted(.currency(code: "USD").notation(.compactName).precision(.significantDigits(3)).locale(Locale(identifier: "en_US")))
    }
}

/// The token chart's point under the pointer, shared by the marker on the chart and the price line above it.
@Observable final class ChartPointer {
    var point: TokenMarket.Point?
}

extension View {
    /// Both price charts' axes: times short enough to read whole under the chart — the hour on a day's chart, the date on a
    /// week's or a month's («Sep 29 at 1…» was cut) — and the prices on the right in the text's own colour, not faded.
    func priceAxes(_ range: ChartCommand.Range) -> some View {
        chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: range == .day ? Date.FormatStyle(locale: Locale(identifier: "en_US")).hour()
                                                         : Date.FormatStyle(locale: Locale(identifier: "en_US")).month(.abbreviated).day())
                            .font(.ui(10)).foregroundStyle(.secondary).fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel().font(.ui(10, .semibold)).foregroundStyle(.primary)
            }
        }
    }
}

/// The price at the pointer (or now) and under it the pointer's time (or the move over the range).
private struct PointerPrice: View {
    let pointer: ChartPointer
    let now: Decimal?
    let change: Decimal?
    let rangeTitle: String

    var body: some View {
        let shown = pointer.point
        VStack(alignment: .leading, spacing: 2) {
            Text((shown?.close ?? now).map(tokenPrice) ?? "—").font(.ui(28, .heavy)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5).layoutPriority(1)
            if let shown {
                Text(shown.time.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US")).day().month(.abbreviated).hour().minute()))
                    .font(.ui(10)).foregroundStyle(.secondary).lineLimit(1)
            } else if let change {
                Text("\(signedPct(change)) · \(rangeTitle)").font(.ui(10, .bold)).foregroundStyle(change < 0 ? Brand.loss : Brand.profit).lineLimit(1)
            }
        }
    }
}

/// A dashed line and a dot at the pointer. Its own view (like ChartHover), so moving the pointer redraws the marker,
/// not the chart's hundreds of marks.
private struct TokenChartHover: View {
    let proxy: ChartProxy
    let points: [TokenMarket.Point]
    let pointer: ChartPointer
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        var near: TokenMarket.Point?
                        if case .active(let p) = phase, let at: Date = proxy.value(atX: p.x - plot.minX) {
                            near = points.min { abs($0.time.timeIntervalSince(at)) < abs($1.time.timeIntervalSince(at)) }
                        }
                        // Moving within one point's slot changes nothing: no redraw.
                        if near != pointer.point { pointer.point = near }
                    }
                if let p = pointer.point, let x = proxy.position(forX: p.time), let y = proxy.position(forY: NSDecimalNumber(decimal: p.close).doubleValue) {
                    Path { $0.move(to: CGPoint(x: plot.minX + x, y: plot.minY)); $0.addLine(to: CGPoint(x: plot.minX + x, y: plot.maxY)) }
                        .stroke(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Circle().fill(tint).frame(width: 7, height: 7).position(x: plot.minX + x, y: plot.minY + y)
                }
            }
        }
    }
}
