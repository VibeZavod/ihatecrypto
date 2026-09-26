import DeFiYields
import Foundation
import LalaCore
import TradeExecution
import LLMCore

/// One thing that happened with LALA: what the user asked, how it was understood, the bubbles on the canvas at that
/// moment, and what LALA said and did. Kept on this Mac only (Application Support/LALA/activity.json, owner-only).
struct Activity: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case request, execution, automatic }
    var id = UUID()
    var at = Date()
    var kind: Kind
    var request: String?
    var understood: String?
    var title: String?
    var coin: String?
    var bubbles: [ActivityBubble] = []
    var lines: [String] = []
}

/// A canvas bubble frozen in time: enough to draw it again the same way in the history.
struct ActivityBubble: Codable, Hashable, Sendable {
    /// A plan node kind (source, bridge, position, …) or deposit / skipped / yield / choice / free / result.
    var kind: String
    var label: String
    var title: String
    var lines: [String] = []
    var status: String = "info"
    var asset: String = ""
    var logo: String?
    var signature: Int?
    /// For position bubbles: long or short.
    var long: Bool?
}

extension Workspace {
    /// Starts a new activity; replies that follow are added to it.
    func beginActivity(_ kind: Activity.Kind, request: String? = nil, title: String? = nil, coin: String? = nil) {
        activities.append(Activity(kind: kind, request: request, title: title, coin: coin))
        currentActivity = activities.last?.id
    }

    func updateActivity(_ change: (inout Activity) -> Void) {
        guard let id = currentActivity, let i = activities.lastIndex(where: { $0.id == id }) else { return }
        change(&activities[i])
    }

    /// The canvas as it is now, as bubbles: the plan, an allocation, rates or take-profit choices.
    func canvasBubbles() -> (title: String, coin: String?, bubbles: [ActivityBubble])? {
        // A move waiting for «do it»: the canvas and the history name it the way the route does.
        switch pendingAction {
        case .wallet(let c)?:
            let title = c.summary.prefix(1).uppercased() + c.summary.dropFirst()
            return (title, nil, [ActivityBubble(kind: "deposit", label: "Waiting for the signature", title: title, logo: Self.logo(for: title))])
        case .transfer(let entry, let amount)?:
            return ("Send \(Fmt.num(amount)) USDC to \(entry.name)", nil,
                    [ActivityBubble(kind: "deposit", label: "Send · \(entry.network.title)", title: entry.name, lines: ["\(Fmt.num(amount)) USDC"], logo: entry.network.logo)])
        case .address(let entry)?:
            return ("Save “\(entry.name)” to Addresses", nil, [ActivityBubble(kind: "free", label: "Save · \(entry.network.title)", title: entry.name, logo: entry.network.logo)])
        default: break
        }
        if let c = chart, intent == TradeIntent(), allocationPreview == nil, yieldOptions == nil {
            let name = IntentParser.pretty(c.coin)
            return ("Chart · \(name)", c.coin, [ActivityBubble(kind: "position", label: "Chart · \(c.range.title)", title: name,
                                                               lines: c.candles.last.map { ["\(Fmt.price($0.close))"] } ?? [], asset: c.coin)])
        }
        if showReceive, intent == TradeIntent(), allocationPreview == nil, yieldOptions == nil {
            return ("Top up LALA", nil, [ActivityBubble(kind: "free", label: "Receive · Solana", title: "USDC and SOL", logo: "sol"),
                                         ActivityBubble(kind: "free", label: "Receive · Base", title: "USDC and ETH", logo: "base")])
        }
        if let a = allocationPreview {
            func amount(_ d: Decimal) -> String { Fmt.num(d, maxFraction: a.asset == "SOL" ? 6 : 2) + " " + a.asset }
            var out = [ActivityBubble(kind: "free", label: "Take from · Solana", title: "\(amount(a.free)) free", logo: a.asset == "SOL" ? "sol" : "usdc")]
            out += a.slices.map { ActivityBubble(kind: "deposit", label: "Deposit", title: $0.place, lines: ["\(amount($0.amount)) at \(Fmt.num($0.apy.rounded(2, .plain)))%"], logo: Self.logo(for: $0.place)) }
            out += a.skipped.map { ActivityBubble(kind: "skipped", label: "Skipped", title: "\($0.place) · \(Fmt.num($0.apy.rounded(2, .plain)))%", lines: [$0.reason], logo: Self.logo(for: $0.place)) }
            out.append(ActivityBubble(kind: "result", label: "Result", title: "≈ \(amount(a.yearly)) a year"))
            return ("Spread \(a.asset) across the best rates", nil, out)
        }
        if let y = yieldOptions, !y.isEmpty {
            return ("Rates", nil, y.prefix(8).map { ActivityBubble(kind: "yield", label: $0.asset, title: $0.place, lines: ["\(Fmt.num($0.apy.rounded(2, .plain)))%"], logo: Self.logo(for: $0.place)) })
        }
        if let choices = takeChoices {
            let risk = evaluation.sizing?.lossAtStopUSD
            return ("Take-profit choices", intent.asset, choices.map { ActivityBubble(kind: "choice", label: $0.title, title: risk.map($0.payoff) ?? $0.title, lines: [$0.detail]) })
        }
        if intent != TradeIntent(), !managesPosition {
            let nodes = StudioNode.build(self).map {
                ActivityBubble(kind: $0.kind.rawValue, label: $0.label, title: $0.title, lines: $0.lines, status: "\($0.status)",
                               asset: $0.asset, signature: $0.signature, long: $0.long)
            }
            return ("Plan · \(intent.side == .long ? "long" : "short") \(IntentParser.pretty(intent.asset))", intent.asset, nodes)
        }
        return nil
    }

    /// Freezes the canvas into the current activity (the plan is kept as it was when it was acted on).
    func snapshotCanvas() {
        guard let (title, coin, bubbles) = canvasBubbles() else { return }
        updateActivity { a in
            if a.bubbles.isEmpty || a.kind == .request { a.bubbles = bubbles }
            if a.title == nil { a.title = title }
            if a.coin == nil { a.coin = coin }
        }
    }

    static func logo(for place: String) -> String {
        place.contains("Jupiter") || place.contains("JUP") ? "jup" : place.contains("Kamino") ? "kamino" : place.contains("Jito") ? "jitosol"
            : place.contains("HLP") || place.contains("Hyperliquid") ? "hype" : place.contains("Aave") ? "aave" : "usdc"
    }
}

extension Workspace {
    /// Answers from what LALA knows: balances, open positions, closed ones from the exchange, recent activity.
    /// With a model the answer is written by it from these facts only; without one, from the same facts directly.
    func answer(_ question: String) async {
        busy = true
        defer { busy = false }
        let stories = (try? await TradeHistory.fills(user: hlAddress)).map(TradeHistory.stories) ?? []
        var facts = answerFacts(stories)
        // The market the question names (and those of open positions): price, the day's move, funding.
        let named = IntentParser.namedAsset(question, markets: Set(markets.keys))
        for coin in Set([named].compactMap { $0 } + positions.map(\.coin)) {
            guard let m = markets[coin] else { continue }
            var line = "Market \(IntentParser.pretty(coin)): mark \(Fmt.price(m.markPx))"
            if let prev = m.prevDayPx, prev > 0 { line += ", 24h \(signedPct((m.markPx - prev) / prev * 100))" }
            if let f = m.funding { line += ", funding \(Fmt.num((f * 100).rounded(4, .plain)))% an hour" }
            if let atr = atr[coin] { line += ", 4h ATR \(Fmt.num(atr.rounded(2, .plain)))%" }
            facts.append(line + ".")
        }
        updateActivity { $0.title = "Question" }
        if let client = llmClient() {
            let system = """
            You are LALA, the user's crypto trading assistant. Answer the question using ONLY the facts below — balances, open positions, \
            closed positions with results, and recent activity. The user may write in any language; answer in English, in 1–3 short \
            sentences with the numbers. If the facts don't contain the answer, say so and point to History (clock button in the rail). \
            Never invent trades, prices or addresses, and don't propose a new trade unless asked.
            """
            do {
                let text = try await client.complete(LLMRequest(model: model, messages: [
                    LLMMessage(.system, system), LLMMessage(.user, "Facts:\n" + facts.joined(separator: "\n") + "\n\nQuestion: " + question),
                ]))
                if !text.isEmpty {
                    reply(text.trimmingCharacters(in: .whitespacesAndNewlines), note: "\(model) · from your portfolio and history")
                    return
                }
            } catch {
                FileHandle.standardError.write(Data("LALA answer: model failed: \(error)\n".utf8))
            }
        }
        if llmClient() == nil { FileHandle.standardError.write(Data("LALA answer: no model connected (\(providerID))\n".utf8)) }
        reply(localAnswer(question, stories: stories), note: "from your portfolio and history")
    }

    private func answerFacts(_ stories: [TradeHistory.Story]) -> [String] {
        var facts: [String] = []
        if let s = solana { facts.append("Solana: \(Fmt.num(s.usdc)) USDC, \(Fmt.num(s.sol, maxFraction: 4)) SOL.") }
        if let e = equity { facts.append("Portfolio total: \(Fmt.usd(e)).") }
        let week = equitySeries()
        if week.count > 2, let first = week.first, let last = week.last {
            facts.append("Portfolio since \(Fmt.date(first.at)): \(Fmt.usd(first.usd)) → \(Fmt.usd(last.usd)) (\(signed(last.usd - first.usd))).")
        }
        if let h = hlTotal { facts.append("Hyperliquid account: \(Fmt.usd(h)).") }
        if lendTotal > 0 { facts.append("Jupiter Lend vault: \(Fmt.num(lendTotal)) USDC.") }
        if let b = base {
            facts.append("Aave v3 on Base: \(Fmt.num(b.aave)) USDC supplied\(aaveAPY.map { " at ≈ \(Fmt.num($0.rounded(2, .plain)))% a year" } ?? ""); \(Fmt.num(b.usdc)) USDC idle on Base; \(Fmt.num(b.eth, maxFraction: 7)) ETH for gas there.")
        }
        if positions.isEmpty { facts.append("Open positions: none.") }
        for p in positions {
            facts.append("Open: \(p.size > 0 ? "long" : "short") \(IntentParser.pretty(p.coin)), \(positionSummary(p)), unrealized \(signed(p.unrealizedPnl)).")
        }
        for s in stories.filter({ !$0.isOpen }).prefix(6) {
            let open = s.fills.first, close = s.fills.last
            facts.append("Closed: \(s.long ? "long" : "short") \(IntentParser.pretty(s.coin)), opened \(Fmt.date(s.opened)) at \(open.map { Fmt.price($0.px) } ?? "?"), closed \(s.closed.map(Fmt.date) ?? "?") at \(close.map { Fmt.price($0.px) } ?? "?"), realized \(signed(s.realized)) after fees.")
        }
        if intent != TradeIntent(), !managesPosition { facts.append("Plan on the canvas (not executed): \(intent.side == .long ? "long" : "short") \(IntentParser.pretty(intent.asset)).") }
        for a in activities.suffix(10) where a.request != nil || a.title != nil {
            facts.append("Activity \(Fmt.date(a.at)): \(a.request.map { "user said “\($0)”" } ?? a.title ?? "") → \(a.lines.first ?? "")")
        }
        // Names only: a model never sees or writes an address.
        if !addressBook.isEmpty {
            facts.append("Address book (names only; the addresses are in the Addresses tab): " + addressBook.map { "\($0.name) — \([$0.label?.lowercased(), $0.network.title].compactMap { $0 }.joined(separator: ", "))\($0.favorite ? ", favorite" : "")" }.joined(separator: "; ") + ".")
        }
        if let r = robinhood {
            let stocks = r.stocks.map { "\(Fmt.num($0.amount, maxFraction: 6)) \($0.symbol) (\($0.name)) ≈ \(Fmt.usd($0.usd))" }.joined(separator: ", ")
            facts.append("Robinhood Chain: \(stocks.isEmpty ? "no Stock Tokens" : "Stock Tokens " + stocks); \(Fmt.num(r.usdg)) USDG.")
        }
        for a in alerts { facts.append("Price alert: \(IntentParser.pretty(a.coin)) \(a.above ? "above" : "below") \(Fmt.price(a.price))\(markets[a.coin].map { ", now \(Fmt.price($0.markPx))" } ?? "").") }
        for s in schedules { facts.append("Recurring buy: \(s.symbol) for \(Fmt.usd(s.usdc)) every \(s.days) days, next \(Fmt.date(s.next)).") }
        return facts
    }

    /// Without a model: the questions that matter most — where is a position, what happened to it, what is open.
    private func localAnswer(_ question: String, stories: [TradeHistory.Story]) -> String {
        if let coin = IntentParser.namedAsset(question, markets: Set(markets.keys)) {
            if let p = positions.first(where: { $0.coin == coin }) {
                return "Your \(p.size > 0 ? "long" : "short") \(IntentParser.pretty(coin)) is open: \(positionSummary(p)), unrealized \(signed(p.unrealizedPnl))."
            }
            if let s = stories.first(where: { $0.coin == coin && !$0.isOpen }), let close = s.fills.last {
                return "The \(s.long ? "long" : "short") \(IntentParser.pretty(coin)) is closed: it closed \(s.closed.map(Fmt.date) ?? "") at \(Fmt.price(close.px)), realized \(signed(s.realized)) after fees. The whole story is in History → Positions."
            }
            return "There is no \(IntentParser.pretty(coin)) position, open or closed, on Hyperliquid."
        }
        if positions.isEmpty {
            let last = stories.first { !$0.isOpen }
            return "No open positions." + (last.map { " The last one: \($0.long ? "long" : "short") \(IntentParser.pretty($0.coin)), realized \(signed($0.realized))." } ?? "")
        }
        return "Open: " + positions.map { "\($0.size > 0 ? "long" : "short") \(IntentParser.pretty($0.coin)) \(signed($0.unrealizedPnl))" }.joined(separator: ", ") + ". For anything else, connect a model in Settings."
    }
}

/// «+1.2%» / «−0.4%».
func signedPct(_ d: Decimal) -> String { (d < 0 ? "−" : "+") + Fmt.num(abs(d).rounded(2, .plain)) + "%" }
