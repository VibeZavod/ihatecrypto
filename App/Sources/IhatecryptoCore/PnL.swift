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
        // A ticker no market or holding knows («pnl по AERO» with no AERO left) is still the asset asked about: the answer
        // says there's none, not the whole portfolio's P/L.
        let named = IntentParser.namedAsset(text, markets: markets) ?? text.firstMatch(of: /(?i)\b(?:for|on|по|на)\s+([a-z][a-z0-9]{1,9})\b/)
            .map { String($0.1).uppercased() }.flatMap { notTickers.contains($0) ? nil : $0 }
        return PnLCommand(period: period, coin: named)
    }

    static let notTickers: Set<String> = ["THE", "MY", "AN", "ALL", "THIS", "LAST", "PAST", "WEEK", "WEEKS", "TODAY", "DAY", "DAYS", "MONTH",
                                          "MONTHS", "YEAR", "TIME", "EVERYTHING", "TOTAL", "IT", "ME", "EACH", "EVERY",
                                          // Networks and places: «pnl on base» is the network, not a token.
                                          "BASE", "SOLANA", "ARBITRUM", "ETHEREUM", "POLYGON", "ROBINHOOD", "TEMPO", "KAMINO", "JUPITER"]
}

/// What a token bought in the app cost, for the P/L on its holding row: the average cost. A buy with USDC adds its
/// tokens and dollars; a sale takes out the same share of both. Tokens that came some other way have no cost here and
/// count for nothing in the P/L; a token with no known cost shows none.
public struct CostBasis: Codable, Equatable, Sendable {
    public var amount: Decimal = 0
    public var usd: Decimal = 0

    public init() {}

    public mutating func bought(_ tokens: Decimal, for dollars: Decimal) {
        guard tokens > 0, dollars > 0 else { return }
        amount += tokens
        usd += dollars
    }

    public mutating func sold(_ tokens: Decimal) {
        guard amount > 0, tokens > 0 else { return }
        let left = max(0, amount - tokens)
        usd = usd * left / amount
        amount = left
    }

    /// The P/L of what's held now at `price`: only the tokens with a known cost (at most what was bought here).
    public func pnl(held: Decimal, price: Decimal) -> (usd: Decimal, pct: Decimal)? {
        guard amount > 0, usd > 0, held > 0 else { return nil }
        let counted = min(held, amount)
        let cost = usd * counted / amount
        return (counted * price - cost, (counted * price - cost) / cost * 100)
    }

    /// Dollars, as far as a cost goes.
    static let stablecoins: Set<String> = ["USDC", "USDG", "USDT", "USDT0", "USDC.E", "USDBC", "DAI", "PYUSD", "PATHUSD"]

    /// What an EVM wallet paid for a token, from Blockscout's token transfers of each transaction that moved it, oldest
    /// first: tokens in with stablecoins leaving the wallet in the same transaction were bought for them; tokens out
    /// (sold or sent) take their share of the cost. Tokens in with no dollars out (a transfer, an airdrop, a cross-chain
    /// order's fill) have no cost here.
    public static func replay(wallet: String, contract: String, transactions: [[[String: Any]]]) -> CostBasis {
        let me = wallet.lowercased(), token = contract.lowercased()
        var basis = CostBasis()
        for transfers in transactions {
            var tokens: Decimal = 0, dollars: Decimal = 0
            for t in transfers {
                guard let info = t["token"] as? [String: Any], let raw = Holdings.number((t["total"] as? [String: Any])?["value"]),
                      let decimals = Int(info["decimals"] as? String ?? "") else { continue }
                let side = { (key: String) in ((t[key] as? [String: Any])?["hash"] as? String)?.lowercased() }
                let sign: Decimal = side("to") == me ? 1 : side("from") == me ? -1 : 0
                let amount = sign * raw / pow(10, decimals)
                if (info["address_hash"] as? String)?.lowercased() == token { tokens += amount }
                else if stablecoins.contains((info["symbol"] as? String ?? "").uppercased()) { dollars -= amount }
            }
            if tokens > 0 { basis.bought(tokens, for: dollars) } else if tokens < 0 { basis.sold(-tokens) }
        }
        return basis
    }
}
