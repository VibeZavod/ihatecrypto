import Foundation

/// Profit and loss, from what is known for sure and what is only approximate:
/// - trading (exact, from Hyperliquid itself): realized P/L of the fills in the period after fees, funding paid or
///   received, and the unrealized P/L of the positions open now;
/// - the portfolio's change: its value now minus its value when the period began, minus money that came in or left
///   (top-ups, transfers out) — prices, lending yield and trading all end up in it.
/// Lending yield isn't tracked on its own: it is inside the portfolio change.
public enum PnL {
    public enum Period: String, CaseIterable, Sendable {
        case day, week, month, all

        public var title: String { switch self { case .day: "24 h"; case .week: "7 days"; case .month: "30 days"; case .all: "all time" } }
        public func since(_ now: Date) -> Date? {
            switch self {
            case .day: now.addingTimeInterval(-86_400)
            case .week: now.addingTimeInterval(-7 * 86_400)
            case .month: now.addingTimeInterval(-30 * 86_400)
            case .all: nil
            }
        }
    }

    /// Money that came into the wallet from outside (+) or left it (−), in dollars at the time. Kept per wallet.
    public struct Flow: Codable, Sendable, Equatable {
        public let at: Date
        public let usd: Decimal
        public let note: String
        public let wallet: String
        public init(at: Date, usd: Decimal, note: String, wallet: String) {
            self.at = at; self.usd = usd; self.note = note; self.wallet = wallet
        }
    }

    /// A funding payment on a Hyperliquid position: − paid, + received.
    public struct Funding: Sendable, Equatable {
        public let time: Date
        public let coin: String
        public let usdc: Decimal
        public init(time: Date, coin: String, usdc: Decimal) { self.time = time; self.coin = coin; self.usdc = usdc }
    }

    public struct AssetLine: Sendable, Equatable {
        public let coin: String
        public let realized: Decimal
        public let closedTrades: Int
    }

    public struct TradeLine: Sendable, Equatable {
        public let coin: String
        public let long: Bool
        public let closed: Date
        public let realized: Decimal
    }

    public struct Report: Sendable, Equatable {
        public let period: Period
        public let coin: String?
        /// Closed P/L of the period's fills minus all their fees.
        public let realized: Decimal
        public let funding: Decimal
        /// Positions open now (the period doesn't apply).
        public let unrealized: Decimal
        /// Portfolio value change without money moved in or out; nil without history for the period (or for one asset).
        public let change: Decimal?
        /// From when the change is measured: the period's start, or the oldest point kept when history is shorter.
        public let changeSince: Date?
        /// Net money moved in (+) or out (−) during the change's span.
        public let flows: Decimal
        public let byAsset: [AssetLine]
        public let closedTrades: Int
        public let wins: Int
        public let best: TradeLine?
        public let worst: TradeLine?

        /// What trading made in the period: realized after fees, plus funding.
        public var trading: Decimal { realized + funding }
    }

    public static func report(_ period: Period, coin: String? = nil, now: Date = Date(), fills: [TradeHistory.Fill],
                              funding: [Funding], unrealized: [String: Decimal], equity: [(at: Date, usd: Decimal)], flows: [Flow]) -> Report {
        let since = period.since(now)
        func inPeriod(_ d: Date) -> Bool { since.map { d >= $0 } ?? true }
        func forCoin(_ c: String) -> Bool { coin.map { $0 == c } ?? true }

        let periodFills = fills.filter { inPeriod($0.time) && forCoin($0.coin) }
        let realized = periodFills.reduce(Decimal(0)) { $0 + $1.closedPnl - $1.fee }
        let paid = funding.filter { inPeriod($0.time) && forCoin($0.coin) }.reduce(Decimal(0)) { $0 + $1.usdc }
        let open = unrealized.filter { forCoin($0.key) }.values.reduce(Decimal(0), +)

        let closed = TradeHistory.stories(fills).filter { !$0.isOpen && forCoin($0.coin) && $0.closed.map(inPeriod) == true }
        let lines = closed.map { TradeLine(coin: $0.coin, long: $0.long, closed: $0.closed ?? now, realized: $0.realized) }
        let byAsset = Dictionary(grouping: periodFills, by: \.coin).map { coin, fs in
            AssetLine(coin: coin, realized: fs.reduce(Decimal(0)) { $0 + $1.closedPnl - $1.fee },
                      closedTrades: closed.filter { $0.coin == coin }.count)
        }
        .sorted { abs($0.realized) > abs($1.realized) }

        // The portfolio change needs the whole wallet: not for one asset.
        var change: Decimal?, changeSince: Date?, moved: Decimal = 0
        let points = equity.sorted { $0.at < $1.at }
        if coin == nil, let end = points.last, let start = points.first(where: { inPeriod($0.at) }), start.at < end.at {
            moved = flows.filter { $0.at > start.at && $0.at <= end.at }.reduce(Decimal(0)) { $0 + $1.usd }
            change = end.usd - start.usd - moved
            changeSince = start.at
        }

        return Report(period: period, coin: coin, realized: realized, funding: paid, unrealized: open, change: change,
                      changeSince: changeSince, flows: moved, byAsset: byAsset, closedTrades: lines.count,
                      wins: lines.filter { $0.realized > 0 }.count,
                      best: lines.max { $0.realized < $1.realized }, worst: lines.min { $0.realized < $1.realized })
    }

    /// For the chat's answers: the facts, one line each, plainly labeled.
    public static func facts(_ r: Report, pretty: (String) -> String = { $0 }) -> [String] {
        func s(_ d: Decimal) -> String { d < 0 ? "−$\(Fmt.num(-d))" : "+$\(Fmt.num(d))" }
        var out = ["P/L \(r.period.title)\(r.coin.map { " on \(pretty($0))" } ?? ""): trading \(s(r.trading)) (realized after fees \(s(r.realized)), funding \(s(r.funding))), \(r.closedTrades) closed trades, \(r.wins) in profit; open positions now \(s(r.unrealized))."]
        if let c = r.change, let since = r.changeSince {
            out.append("Portfolio \(r.period.title): \(s(c)) since \(Fmt.date(since)), not counting \(s(r.flows)) of money moved in or out (lending yield and price moves are inside this).")
        }
        if let b = r.best, b.realized > 0 { out.append("Best trade: \(b.long ? "long" : "short") \(pretty(b.coin)) \(s(b.realized)).") }
        if let w = r.worst, w.realized < 0 { out.append("Worst trade: \(w.long ? "long" : "short") \(pretty(w.coin)) \(s(w.realized)).") }
        return out
    }
}

/// «какой у меня P/L», «pnl за неделю», «сколько я заработал на нефти», «profit and loss week for oil».
public struct PnLCommand: Equatable, Sendable {
    public let period: PnL.Period
    public let coin: String?
    public init(period: PnL.Period, coin: String?) { self.period = period; self.coin = coin }

    public static func parse(_ text: String, markets: Set<String> = []) -> PnLCommand? {
        let q = text.lowercased()
        guard q.contains(/profit\s+and\s+loss|\bp\s*[\/&]\s*l\b|\bpnl\b|пнл|прибыл\w*\s+и\s+убыт|сколько\s+(?:я\s+)?(?:заработал|потерял|наторговал)|how\s+much\s+(?:did\s+)?i\s+(?:make|made|earn|earned|lose|lost)/) else {
            return nil
        }
        let period: PnL.Period = q.contains(/today|24\s*h|\bday\b|сегодня|за\s+день|сутк|суток/) ? .day
            : q.contains(/week|7\s*d\b|недел/) ? .week : q.contains(/month|30\s*d\b|месяц/) ? .month : .all
        return PnLCommand(period: period, coin: IntentParser.namedAsset(text, markets: markets))
    }
}
