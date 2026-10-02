import Foundation

/// «Take profit the way the best investors do»: three common ways to take profit on the same stop.
/// The stop never changes between them; only how the profit is taken does.
public enum TakeStyle: String, CaseIterable, Sendable {
    /// All of it at twice the risk.
    case classic
    /// Half at 1R, the stop to breakeven, the rest at 2R. ihatecrypto's default «by the book».
    case partial
    /// Half at 1R, the rest follows the price with a 2% trailing stop; a far take at 4R as a cap.
    case trend

    /// The user asks for the take-profit «like the best investors / pros», in Russian or English.
    public static func asksForChoice(_ text: String) -> Bool {
        let q = text.lowercased()
        guard q.contains(/тейк|профит|take|profit|выход|exit/) else { return false }
        return q.contains(/как\s+советуют|как\s+(?:делают|ставят)\s+(?:лучшие|профи|про\b)|лучши[ех]\s+(?:инвестор|трейдер)|(?:best|top|pro)\s+(?:investors|traders)|like\s+(?:the\s+)?pros|how\s+(?:the\s+)?pros|take[- ]?profit\s+options|take\s+options|варианты\s+тейк/)
    }

    public func apply(to intent: TradeIntent) -> TradeIntent {
        var i = intent
        i.takePct = nil
        switch self {
        case .classic: i.takeR = 2; i.partialTake = false; i.trailingPct = nil
        case .partial: i.takeR = 2; i.partialTake = true; i.trailingPct = nil
        case .trend: i.takeR = 4; i.partialTake = true; i.trailingPct = 2
        }
        return i
    }

    public var title: String {
        switch self {
        case .classic: "Classic 2R"
        case .partial: "In parts"
        case .trend: "Ride the trend"
        }
    }

    public var detail: String {
        switch self {
        case .classic: "All of it at 2× the risk."
        case .partial: "Half at 1R, stop to breakeven, the rest at 2R."
        case .trend: "Half at 1R, the rest follows the price with a 2% trailing stop."
        }
    }

    public var note: String {
        switch self {
        case .classic: "Profitable if you win more than a third of your trades."
        case .partial: "After the first half the risk is almost zero."
        case .trend: "No ceiling, but you give some back on the reversal."
        }
    }

    /// What it pays at the take for a trade that loses `risk` at the stop.
    public func payoff(risk: Decimal) -> String {
        switch self {
        case .classic: "+" + Fmt.usd(risk * 2)
        case .partial: "+" + Fmt.usd(risk / 2 + risk)
        case .trend: "no cap"
        }
    }
}
