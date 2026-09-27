import LalaCore
import TradeExecution

/// What a plan still needs, and what «by the book» would make of a trade: the chat asks for the missing risk and stop
/// with these numbers, and answers «should I short oil now?» with them.
extension Workspace {
    /// What stops Execute for lack of details: nil when the plan has a risk and a stop (its own or by the book).
    var missingDetails: String? {
        guard intent != TradeIntent(), !managesPosition else { return nil }
        let r = resolved.intent
        let parts = [r.riskUSD == nil ? "the risk in $" : nil, r.stopPct == nil ? "a stop" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    /// The trade by the book (stop from 4h volatility, take at 2R, 1 % of capital at risk) in numbers, and what the
    /// rules say about entering it now: the day's move, funding, liquidation, the risk limits.
    func bookPlan(asset: String, side: Side) -> (line: String, advice: [Advice])? {
        guard var m = markets[asset] else { return nil }
        m.atrPct = atr[asset]
        var trial = TradeIntent()
        trial.asset = asset
        trial.side = side
        trial.autoRules = true
        let r = Plan.resolve(trial, market: m, equity: equity, policy: policy).intent
        guard let s = Plan.evaluate(r, market: m).sizing, let stop = r.stopPct else { return nil }
        var line = "risk \(Fmt.usd(s.lossAtStopUSD)), stop \(Fmt.pct(stop)) at \(Fmt.price(s.stopPrice))"
        if let take = r.takePct, let tp = s.takePrice, let p = s.profitAtTakeUSD {
            line += ", take \(Fmt.pct(take)) at \(Fmt.price(tp)) → +\(Fmt.usd(p))"
        }
        let advice = RiskRules.check(r, s, market: m, equity: equity, policy: policy,
                                     openRisk: HyperliquidAccount.riskAtStops(positions: positions, orders: orders))
        return (line, advice)
    }

    /// After a plan change that left the risk or the stop open: the question, with LALA's suggestion in numbers.
    var detailsQuestion: String? {
        guard let missing = missingDetails else { return nil }
        let book = bookPlan(asset: intent.asset, side: intent.side)
        return "\nExecute needs \(missing). " + (book.map { "By the book: \($0.line). " } ?? "")
            + "Tap “By the book” or say your own, e.g. “risk $1 stop 3%”."
    }
}
