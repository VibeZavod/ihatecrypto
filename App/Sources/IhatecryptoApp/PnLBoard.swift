import IhatecryptoCore
import SwiftUI

/// The P/L on the canvas — «какой у меня P/L», «pnl за неделю», «сколько я заработал на нефти» — for the canvas it
/// was asked on.
@MainActor @Observable
final class PnLBoardState {
    static let shared = PnLBoardState()
    var command: PnLCommand?
    var reports: [PnL.Period: PnL.Report] = [:]
    var period: PnL.Period = .all
    var canvas: UUID?
    /// What the wallet holds of the asset asked about, on every network.
    var held: [HeldLine] = []
}

/// The asset on one network: how much, what it's worth, what it cost when that is known.
struct HeldLine: Equatable {
    let symbol: String
    let network: String
    let amount: Decimal
    let usd: Decimal?
    let cost: CostBasis?

    var place: String { WalletCommand.placeName(network) }
    /// What the tokens with a known cost were bought for, and their P/L now.
    var pnl: (paid: Decimal, usd: Decimal, pct: Decimal)? {
        guard let usd, amount > 0, let cost, let p = cost.pnl(held: amount, price: usd / amount) else { return nil }
        return (cost.usd * min(amount, cost.amount) / cost.amount, p.usd, p.pct)
    }
    /// Only part of it has a known cost: the rest came some other way.
    var partly: Bool { (cost?.amount ?? 0) > 0 && cost!.amount < amount * Decimal(string: "0.999")! }

    var english: String {
        "\(symbol) on \(place): \(Fmt.num(amount, maxFraction: 6))\(usd.map { " ≈ \(Fmt.usd($0))" } ?? ", no price")"
            + (pnl.map { ", bought for \(Fmt.usd($0.paid))\(partly ? " (\(Fmt.num(cost!.amount, maxFraction: 6)) of it)" : "") → \(signed($0.usd)) (\(PnLBoard.percent($0.pct)))" }
               ?? ", cost unknown (it came without a purchase in stablecoins)") + "."
    }
    var russian: String {
        "\(symbol) на \(place): \(Fmt.num(amount, maxFraction: 6))\(usd.map { " ≈ \(Fmt.usd($0))" } ?? ", без цены")"
            + (pnl.map { ", куплено за \(Fmt.usd($0.paid))\(partly ? " (\(Fmt.num(cost!.amount, maxFraction: 6)) из них)" : "") → \(signed($0.usd)) (\(PnLBoard.percent($0.pct)))" }
               ?? ", цена покупки неизвестна (пришёл не покупкой за стейблкоины)") + "."
    }
}

extension Workspace {
    /// The wallet the P/L belongs to: its EVM address, or its Solana one for a wallet without an EVM key.
    var pnlWallet: String { (hlAddress.isEmpty ? solanaAddress : hlAddress).lowercased() }

    /// Money that came from outside (+) or left for outside (−): the P/L leaves it out (flows.json, per wallet).
    func recordFlow(_ usd: Decimal, _ note: String) {
        guard usd != 0 else { return }
        let all: [PnL.Flow] = LocalStore.load("flows.json") ?? []
        LocalStore.save(Array((all + [PnL.Flow(at: Date(), usd: usd, note: note, wallet: pnlWallet)]).suffix(2000)), "flows.json")
    }

    /// The money `announceIncoming` reports, in dollars (SOL at Hyperliquid's price).
    func recordIncomingFlows(before: (usdc: Decimal?, sol: Decimal?, base: Decimal?)) {
        if let old = before.usdc, let new = solana?.usdc, new - old >= Decimal(string: "0.01")! { recordFlow(new - old, "USDC in on Solana") }
        if let old = before.sol, let new = solana?.sol, new - old >= Decimal(string: "0.0005")!, let px = markets["SOL"]?.markPx {
            recordFlow((new - old) * px, "SOL in on Solana")
        }
        if let old = before.base, let new = base?.usdc, new - old >= Decimal(string: "0.01")! { recordFlow(new - old, "USDC in on Base") }
    }

    /// The asset names the P/L understands: Hyperliquid's markets, and the tokens held that aren't one («pnl по AERO»).
    var pnlNames: Set<String> {
        let names = Set(markets.keys)
        let held = (holdings.map(\.symbol) + (robinhood?.stocks ?? []).map(\.symbol)).map { $0.uppercased() }
        return names.union(held.filter { s in !names.contains { $0 == s || $0 == "k" + s || $0.hasSuffix(":" + s) } })
    }

    /// What the wallet holds of an asset on every network («xyz:SPCX» is SPCX on Robinhood Chain too), with its cost:
    /// on Solana what the app's swaps recorded, on an EVM network what the wallet paid on-chain (Holdings.costBasis).
    func heldLines(_ coin: String?) async -> [HeldLine] {
        guard let coin else { return [] }
        let symbol = (coin.split(separator: ":").last.map(String.init) ?? coin).uppercased()
        var found: [(network: String, contract: String, amount: Decimal, usd: Decimal?)] = []
        if symbol == "SOL", let sol = solana?.sol, sol > 0 {
            found.append(("solana", "So11111111111111111111111111111111111111112", sol, markets["SOL"].map { $0.markPx * sol }))
        }
        for s in robinhood?.stocks ?? [] where s.symbol.uppercased() == symbol && s.amount > 0 {
            found.append(("robinhood", s.address, s.amount, s.price.map { $0 * s.amount }))
        }
        for h in holdings where h.symbol.uppercased() == symbol && h.amount > 0 { found.append((h.chain, h.contract, h.amount, h.usd)) }
        var out: [HeldLine] = []
        for f in found {
            // On an EVM network: what ihatecrypto's own buys recorded, or what the chain shows, whichever covers more of it
            // (a Relay buy pays in one transaction and delivers in another: only the record knows its cost).
            let chain = f.network == "solana" || !isEVMAddress(hlAddress) ? nil : await Holdings.costBasis(f.network, address: hlAddress, contract: f.contract)
            let cost = f.network == "solana" ? costBasis[f.contract]
                : [costBasis["\(f.network):\(f.contract.lowercased())"], chain].compactMap { $0 }.filter { $0.amount > 0 }.max { $0.amount < $1.amount }
            out.append(HeldLine(symbol: symbol, network: f.network, amount: f.amount, usd: f.usd, cost: cost))
        }
        return out
    }

    /// The periods asked for; every one by default, so the board's period switch needs no new request.
    func pnlReports(coin: String?, periods: [PnL.Period] = PnL.Period.allCases) async -> [PnL.Period: PnL.Report] {
        async let fillsCall = TradeHistory.fills(user: hlAddress)
        async let fundingCall = TradeHistory.funding(user: hlAddress)
        let fills = (try? await fillsCall) ?? [], funding = (try? await fundingCall) ?? []
        let unrealized = Dictionary(positions.map { ($0.coin, $0.unrealizedPnl) }, uniquingKeysWith: +)
        // This wallet's points only (older, untagged ones may be another wallet's), and the value now.
        let equity = (equityHistory.filter { $0.wallet == pnlWallet } + (self.equity.map { [EquityPoint(at: Date(), usd: $0)] } ?? []))
            .map { (at: $0.at, usd: $0.usd) }
        let flows = ((LocalStore.load("flows.json") as [PnL.Flow]?) ?? []).filter { $0.wallet == pnlWallet }
        // Off the main thread: each period goes over every fill (up to 2,000) again.
        return await Task.detached {
            var out: [PnL.Period: PnL.Report] = [:]
            for period in periods {
                out[period] = PnL.report(period, coin: coin, fills: fills, funding: funding, unrealized: unrealized, equity: equity, flows: flows)
            }
            return out
        }.value
    }

    func showPnL(_ command: PnLCommand, note: String? = nil) async {
        busy = true
        defer { busy = false }
        async let reportsCall = pnlReports(coin: command.coin)
        async let heldCall = heldLines(command.coin)
        let (reports, held) = await (reportsCall, heldCall)
        // Asked about an asset that's in no wallet and was never traded: say so, not a board of zeros.
        if let coin = command.coin, held.isEmpty, !reports.values.contains(where: PnLBoard.traded) {
            let name = IntentParser.pretty(coin)
            reply(say("No \(name) in the wallet on any network, and no Hyperliquid trades in it: nothing to count.",
                      "\(name) нет в кошельке ни в одной сети, и сделок по нему на Hyperliquid не было — считать нечего."),
                  note: note ?? say("P/L · from Hyperliquid and your portfolio", "P/L · из Hyperliquid и твоего портфеля"))
            return
        }
        withAnimation(StudioView.spring) {
            let state = PnLBoardState.shared
            state.command = command
            state.reports = reports
            state.period = command.period
            state.held = held
        }
        guard let report = reports[command.period] else { return }
        // An asset only held, never traded on Hyperliquid: what is held is the answer, not a row of zeros.
        let text = held.isEmpty || reports.values.contains(where: PnLBoard.traded) ? pnlReply(report) : ""
        reply([text, say(held.map(\.english).joined(separator: " "), held.map(\.russian).joined(separator: " "))].filter { !$0.isEmpty }.joined(separator: " "),
              note: note ?? say("P/L · from Hyperliquid and your portfolio", "P/L · из Hyperliquid и твоего портфеля"))
        // After the reply: a fresh canvas gets its id when it is first saved, and the reply saves it.
        PnLBoardState.shared.canvas = canvasID
    }

    /// The report in the chat's language; the model gets the English facts either way.
    private func pnlReply(_ r: PnL.Report) -> String {
        let period = ["day": "24 ч", "week": "7 дней", "month": "30 дней", "all": "всё время"][r.period.rawValue] ?? r.period.title
        var ru = ["P/L за \(period)\(r.coin.map { " по \(IntentParser.pretty($0))" } ?? ""): торговля \(signed(r.trading)) (реализовано после комиссий \(signed(r.realized)), фандинг \(signed(r.funding))), закрыто сделок \(r.closedTrades), в плюсе \(r.wins); открытые позиции сейчас \(signed(r.unrealized))."]
        if let c = r.change, let since = r.changeSince {
            ru.append("Портфель: \(signed(c)) с \(Fmt.date(since)), без учёта \(signed(r.flows)) пополнений и выводов (сюда входят доход от лендинга и движение цен).")
        }
        if let b = r.best, b.realized > 0 { ru.append("Лучшая сделка: \(b.long ? "лонг" : "шорт") \(IntentParser.pretty(b.coin)) \(signed(b.realized)).") }
        if let w = r.worst, w.realized < 0 { ru.append("Худшая сделка: \(w.long ? "лонг" : "шорт") \(IntentParser.pretty(w.coin)) \(signed(w.realized)).") }
        return say(PnL.facts(r, pretty: IntentParser.pretty).joined(separator: " "), ru.joined(separator: " "))
    }

    /// For the model's answers about money: the week and all time.
    func pnlFacts() async -> [String] {
        let reports = await pnlReports(coin: nil, periods: [.week, .all])
        return [PnL.Period.week, .all].compactMap { reports[$0] }.flatMap { PnL.facts($0, pretty: IntentParser.pretty) }
    }
}

struct PnLBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        let state = PnLBoardState.shared
        if let command = state.command, state.canvas == ws.canvasID, let r = state.reports[state.period] {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("P/L" + (command.coin.map { " · \(onlyHeld ? state.held[0].symbol : IntentParser.pretty($0))" } ?? "")).font(.ui(15, .bold))
                    Spacer(minLength: 4)
                    // What is held is now: no period to switch.
                    if !onlyHeld {
                        Picker("Period", selection: Binding(get: { state.period }, set: { p in withAnimation(.snappy) { state.period = p } })) {
                            ForEach(PnL.Period.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    Button { withAnimation(StudioView.spring) { state.command = nil } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.hoverIcon).help("Close").accessibilityLabel("Close P/L")
                }
                if onlyHeld {
                    heldHeadline
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Trading · \(r.period.title)").font(.ui(10)).foregroundStyle(.secondary)
                        Text(signed(r.trading)).font(.ui(30, .heavy)).monospacedDigit()
                            .foregroundStyle(r.trading < 0 ? Brand.loss : Brand.profit)
                        Text("realized after fees \(signed(r.realized)) · funding \(signed(r.funding)) · \(r.closedTrades) closed, \(r.wins) in profit")
                            .font(.ui(10)).foregroundStyle(.secondary)
                    }
                    line("Open positions now", r.unrealized, detail: "not realized yet")
                }
                if !state.held.isEmpty { heldSection }
                if command.coin == nil {
                    if let change = r.change, let since = r.changeSince {
                        line("Portfolio since \(Fmt.date(since))", change,
                             detail: r.flows == 0 ? "prices, yield and trading together" : "without \(signed(r.flows)) you moved in or out")
                    } else {
                        Text("No portfolio history for this period yet: it builds up every ten minutes while the app is open.")
                            .font(.ui(10)).foregroundStyle(.secondary)
                    }
                }
                if !r.byAsset.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("BY MARKET").font(.ui(10, .heavy)).tracking(0.6).foregroundStyle(.secondary)
                        ForEach(r.byAsset.prefix(6), id: \.coin) { a in
                            HStack(spacing: 8) {
                                AssetBadge(coin: a.coin, size: 22, dark: false)
                                Text(IntentParser.pretty(a.coin)).font(.ui(13, .semibold)).lineLimit(1)
                                Text("\(a.closedTrades) closed").font(.ui(10)).foregroundStyle(.secondary)
                                Spacer(minLength: 4)
                                Text(signed(a.realized)).font(.ui(13, .bold)).monospacedDigit()
                                    .foregroundStyle(a.realized < 0 ? Brand.loss : Brand.profit)
                            }
                        }
                    }
                }
                if let best = r.best, best.realized > 0 { trade("Best", best) }
                if let worst = r.worst, worst.realized < 0 { trade("Worst", worst) }
                Text(onlyHeld ? "The cost is what the wallet paid in stablecoins in the same transaction, read from the network (on Solana: swaps made here). A token that came some other way has no cost."
                     : "Trading comes from Hyperliquid itself. Lending yield isn't counted separately: it's inside the portfolio change. Money that arrived while the app was closed can look like gain.")
                    .font(.ui(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 470, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Brand.cardBorder))
            .transition(.opacity)
        }
    }

    private var heldHeadline: some View {
        let state = PnLBoardState.shared
        // Never traded on Hyperliquid: what the wallet holds of it is the P/L.
        let priced = state.held.compactMap(\.pnl)
        let worth = state.held.compactMap(\.usd).reduce(0, +), gain = priced.reduce(Decimal(0)) { $0 + $1.usd }
        return VStack(alignment: .leading, spacing: 3) {
            Text("Held now · every network").font(.ui(10)).foregroundStyle(.secondary)
            Text(priced.isEmpty ? Fmt.usd(worth) : signed(gain)).font(.ui(30, .heavy)).monospacedDigit()
                .foregroundStyle(priced.isEmpty ? Color.primary : gain < 0 ? Brand.loss : Brand.profit)
            Text("worth \(Fmt.usd(worth))" + (priced.isEmpty ? " · cost unknown" : " · bought for \(Fmt.usd(priced.reduce(Decimal(0)) { $0 + $1.paid }))"))
                .font(.ui(10)).foregroundStyle(.secondary)
        }
    }

    private var heldSection: some View {
        let state = PnLBoardState.shared
        return VStack(alignment: .leading, spacing: 6) {
            Text("HELD NOW").font(.ui(10, .heavy)).tracking(0.6).foregroundStyle(.secondary)
            ForEach(Array(state.held.enumerated()), id: \.offset) { _, h in
                HStack(spacing: 8) {
                    TokenLogo(name: HoldingRow.chainLogos[h.network] ?? "sol", size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(h.symbol) · \(h.place)").font(.ui(13, .semibold)).lineLimit(1)
                        Text("\(Fmt.num(h.amount, maxFraction: 6))\(h.usd.map { " ≈ \(Fmt.usd($0))" } ?? "")"
                             + (h.pnl.map { " · bought for \(Fmt.usd($0.paid))\(h.partly ? " (\(Fmt.num(h.cost!.amount, maxFraction: 6)) of it)" : "")" } ?? " · cost unknown"))
                            .font(.ui(10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let p = h.pnl {
                        Text("\(signed(p.usd)) · \(PnLBoard.percent(p.pct))").font(.ui(13, .bold)).monospacedDigit()
                            .foregroundStyle(p.usd < 0 ? Brand.loss : Brand.profit)
                    } else {
                        Text(h.usd.map(Fmt.usd) ?? "no price").font(.ui(13, .bold)).monospacedDigit()
                    }
                }
            }
        }
    }

    /// Asked about an asset the wallet holds and never traded on Hyperliquid.
    private var onlyHeld: Bool {
        let state = PnLBoardState.shared
        return !state.held.isEmpty && !state.reports.values.contains(where: Self.traded)
    }
    static func traded(_ r: PnL.Report) -> Bool { r.realized != 0 || r.funding != 0 || r.unrealized != 0 || !r.byAsset.isEmpty }
    static func percent(_ pct: Decimal) -> String { (pct < 0 ? "−" : "+") + Fmt.pct(abs(pct).rounded(1, .plain)) }

    private func line(_ title: String, _ value: Decimal, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(13, .semibold))
                Text(detail).font(.ui(10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(signed(value)).font(.ui(15, .bold)).monospacedDigit().foregroundStyle(value < 0 ? Brand.loss : Brand.profit)
        }
    }

    private func trade(_ label: String, _ t: PnL.TradeLine) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased()).font(.ui(10, .heavy)).tracking(0.6).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Text("\(t.long ? "Long" : "Short") \(IntentParser.pretty(t.coin)) · \(Fmt.date(t.closed))").font(.ui(10)).lineLimit(1)
            Spacer(minLength: 4)
            Text(signed(t.realized)).font(.ui(13, .bold)).monospacedDigit().foregroundStyle(t.realized < 0 ? Brand.loss : Brand.profit)
        }
    }
}
