import LalaCore
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

    /// Every period at once, so the board's period switch needs no new request.
    func pnlReports(coin: String?) async -> [PnL.Period: PnL.Report] {
        async let fillsCall = TradeHistory.fills(user: hlAddress)
        async let fundingCall = TradeHistory.funding(user: hlAddress)
        let fills = (try? await fillsCall) ?? [], funding = (try? await fundingCall) ?? []
        let unrealized = Dictionary(positions.map { ($0.coin, $0.unrealizedPnl) }, uniquingKeysWith: +)
        // This wallet's points only (older, untagged ones may be another wallet's), and the value now.
        let equity = (equityHistory.filter { $0.wallet == pnlWallet } + (self.equity.map { [EquityPoint(at: Date(), usd: $0)] } ?? []))
            .map { (at: $0.at, usd: $0.usd) }
        let flows = ((LocalStore.load("flows.json") as [PnL.Flow]?) ?? []).filter { $0.wallet == pnlWallet }
        var out: [PnL.Period: PnL.Report] = [:]
        for period in PnL.Period.allCases {
            out[period] = PnL.report(period, coin: coin, fills: fills, funding: funding, unrealized: unrealized, equity: equity, flows: flows)
        }
        return out
    }

    func showPnL(_ command: PnLCommand, note: String? = nil) async {
        busy = true
        defer { busy = false }
        let reports = await pnlReports(coin: command.coin)
        withAnimation(StudioView.spring) {
            let state = PnLBoardState.shared
            state.command = command
            state.reports = reports
            state.period = command.period
        }
        guard let report = reports[command.period] else { return }
        reply(pnlReply(report), note: note ?? say("P/L · from Hyperliquid and your portfolio", "P/L · из Hyperliquid и твоего портфеля"))
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
        let reports = await pnlReports(coin: nil)
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
                    Text("P/L" + (command.coin.map { " · \(IntentParser.pretty($0))" } ?? "")).font(.system(size: 15, weight: .bold))
                    Spacer(minLength: 4)
                    Picker("Period", selection: Binding(get: { state.period }, set: { p in withAnimation(.snappy) { state.period = p } })) {
                        ForEach(PnL.Period.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Button { withAnimation(StudioView.spring) { state.command = nil } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.hoverIcon).help("Close").accessibilityLabel("Close P/L")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Trading · \(r.period.title)").font(.caption).foregroundStyle(.secondary)
                    Text(signed(r.trading)).font(.system(size: 30, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(r.trading < 0 ? Brand.loss : Brand.profit)
                    Text("realized after fees \(signed(r.realized)) · funding \(signed(r.funding)) · \(r.closedTrades) closed, \(r.wins) in profit")
                        .font(.caption).foregroundStyle(.secondary)
                }
                line("Open positions now", r.unrealized, detail: "not realized yet")
                if command.coin == nil {
                    if let change = r.change, let since = r.changeSince {
                        line("Portfolio since \(Fmt.date(since))", change,
                             detail: r.flows == 0 ? "prices, yield and trading together" : "without \(signed(r.flows)) you moved in or out")
                    } else {
                        Text("No portfolio history for this period yet: it builds up every ten minutes while the app is open.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !r.byAsset.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("BY MARKET").font(.system(size: 10, weight: .heavy)).tracking(0.6).foregroundStyle(.secondary)
                        ForEach(r.byAsset.prefix(6), id: \.coin) { a in
                            HStack(spacing: 8) {
                                AssetBadge(coin: a.coin, size: 22, dark: false)
                                Text(IntentParser.pretty(a.coin)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text("\(a.closedTrades) closed").font(.caption).foregroundStyle(.secondary)
                                Spacer(minLength: 4)
                                Text(signed(a.realized)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(a.realized < 0 ? Brand.loss : Brand.profit)
                            }
                        }
                    }
                }
                if let best = r.best, best.realized > 0 { trade("Best", best) }
                if let worst = r.worst, worst.realized < 0 { trade("Worst", worst) }
                Text("Trading comes from Hyperliquid itself. Lending yield isn't counted separately: it's inside the portfolio change. Money that arrived while the app was closed can look like gain.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 470, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Brand.cardBorder))
            .transition(.opacity)
        }
    }

    private func line(_ title: String, _ value: Decimal, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(signed(value)).font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(value < 0 ? Brand.loss : Brand.profit)
        }
    }

    private func trade(_ label: String, _ t: PnL.TradeLine) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.6).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Text("\(t.long ? "Long" : "Short") \(IntentParser.pretty(t.coin)) · \(Fmt.date(t.closed))").font(.caption).lineLimit(1)
            Spacer(minLength: 4)
            Text(signed(t.realized)).font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(t.realized < 0 ? Brand.loss : Brand.profit)
        }
    }
}
