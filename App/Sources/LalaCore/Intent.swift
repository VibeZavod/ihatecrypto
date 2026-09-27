import Foundation
import WalletCore

public enum Side: String, Codable, Sendable {
    case long, short
}

/// What the user wants. Only words and numbers from the chat; never addresses or keys.
public struct TradeIntent: Codable, Equatable, Sendable {
    public var asset = "ETH"
    public var side = Side.long
    public var riskUSD: Decimal?
    public var stopPct: Decimal?
    public var takePct: Decimal?
    public var leverage: Decimal?
    /// USDC to send from Solana. nil = exactly what the position needs.
    public var amountUSDC: Decimal?
    /// Take as a multiple of the stop distance («тейк 2R», «1:3»); used when takePct is not set.
    public var takeR: Decimal?
    /// «как учат»: what the user left out is filled by the risk rules (stop from volatility, 2R take, 1% risk).
    public var autoRules: Bool?
    /// Limit entry price («лимит 2650»); nil = market entry.
    public var entryPx: Decimal?
    /// Limit entry this far from the mark in the trade's favour («вход на откате 2%»); resolved to entryPx.
    public var pullbackPct: Decimal?
    /// «тейк частями»: half at 1R, then the stop goes to breakeven and the rest runs to the take.
    public var partialTake: Bool?
    /// «трейлинг 2%»: the stop follows the best price at this distance while the app is open.
    public var trailingPct: Decimal?

    public init() {}

    /// Human-readable list of fields that differ from `old`.
    public func changes(from old: TradeIntent) -> [String] {
        func opt(_ v: Decimal?, _ f: (Decimal) -> String) -> String { v.map(f) ?? "—" }
        var out: [String] = []
        if asset != old.asset { out.append("market \(asset)") }
        if side != old.side { out.append(side == .long ? "long" : "short") }
        if riskUSD != old.riskUSD { out.append("risk \(opt(riskUSD, Fmt.usd))") }
        if stopPct != old.stopPct { out.append("stop \(opt(stopPct, Fmt.pct))") }
        if takePct != old.takePct { out.append("take \(opt(takePct, Fmt.pct))") }
        if leverage != old.leverage { out.append("leverage \(opt(leverage) { Fmt.num($0) + "×" })") }
        if amountUSDC != old.amountUSDC { out.append("from Solana \(opt(amountUSDC) { Fmt.num($0) + " USDC" })") }
        if takeR != old.takeR { out.append("take \(opt(takeR) { Fmt.num($0) + "R" })") }
        if autoRules != old.autoRules, autoRules == true { out.append("the rest by the risk rules") }
        if partialTake != old.partialTake, partialTake == true { out.append("take in parts: half at 1R, then stop to breakeven") }
        if trailingPct != old.trailingPct { out.append("trailing \(opt(trailingPct, Fmt.pct))") }
        if entryPx != old.entryPx || pullbackPct != old.pullbackPct {
            out.append(entryPx.map { "limit entry at \(Fmt.price($0))" } ?? pullbackPct.map { "entry on a \(Fmt.pct($0)) pullback" } ?? "market entry")
        }
        return out
    }
}

/// Deterministic parsing of the phrases a trader actually types. The cloud model only sees what this misses.
public enum IntentParser {
    static let fallbackMarkets: Set<String> = ["BTC", "ETH", "SOL"]
    /// Words for markets that are not tickers: commodities on HIP-3 exchanges.
    nonisolated(unsafe) static let aliases: [(Regex<Substring>, String)] = [
        (try! Regex("нефт|\\boil\\b|\\bwti\\b|crude"), "CL"), (try! Regex("брент|brent"), "BRENTOIL"),
        (try! Regex("золот|\\bgold\\b"), "GOLD"), (try! Regex("серебр|silver"), "SILVER"),
        // Names people say instead of tickers. Not «Solana»: «с соланы» in a trade names the network.
        (try! Regex("\\bэфир\\w*|\\bethereum\\b|\\bэфириум\\w*"), "ETH"), (try! Regex("биткоин\\w*|биткойн\\w*|\\bбиток\\w*|\\bbitcoin\\b"), "BTC"),
    ]

    /// «xyz:CL» → «WTI oil (xyz:CL)» for the plan's headings.
    public static func pretty(_ asset: String) -> String {
        let names = ["CL": "WTI oil", "BRENTOIL": "Brent oil", "GOLD": "gold", "SILVER": "silver", "TSLA": "Tesla", "NVDA": "Nvidia",
                     "GOOGL": "Google", "META": "Meta", "AAPL": "Apple", "MSFT": "Microsoft", "AMZN": "Amazon", "MU": "Micron",
                     "COIN": "Coinbase", "CRCL": "Circle", "SNDK": "Sandisk", "SP500": "S&P 500", "XYZ100": "tech 100 index"]
        guard let colon = asset.firstIndex(of: ":"), let name = names[String(asset[asset.index(after: colon)...])] else { return asset }
        return "\(name) (\(asset))"
    }
    static let notTickers: Set<String> = ["LONG", "SHORT", "STOP", "TAKE", "RISK", "SL", "TP", "USDC", "USD", "LEV"]
    /// Hyperliquid tickers that are everyday words: in lowercase they are words («move stop», «not now»), not markets.
    static let everydayWords: Set<String> = [
        "ACE", "ALT", "APE", "AR", "BABY", "BANANA", "BLUR", "CAKE", "CHIP", "DASH", "DOT", "GAS", "GOAT", "GRASS", "HYPER", "IO",
        "LAYER", "LINK", "LIT", "ME", "MET", "MON", "MOVE", "NEAR", "NIL", "NOT", "PEOPLE", "PROVE", "PUMP", "RENDER", "SAND", "SKY",
        "STABLE", "SUPER", "TURBO", "USELESS", "USUAL", "VIRTUAL", "ZEN",
    ]

    /// Returns the updated intent, or nil when nothing in `text` was recognised.
    public static func apply(_ text: String, to intent: TradeIntent, markets: Set<String> = []) -> TradeIntent? {
        let q = text.lowercased()
        var next = intent
        var hit = false

        if q.contains(/\b(?:лонг|long)/) { next.side = .long; hit = true }
        if q.contains(/\b(?:шорт|short)/) { next.side = .short; hit = true }

        let known = markets.isEmpty ? fallbackMarkets : markets
        // A ticker on the main exchange, else the same ticker on a HIP-3 one («xyz:TSLA»).
        func market(_ ticker: String) -> String? {
            if known.contains(ticker) { return ticker }
            return known.sorted().first { $0.hasSuffix(":" + ticker) }
        }
        if let m = q.firstMatch(of: /\$([a-z][a-z0-9]{1,9})\b/) {
            next.asset = market(m.1.uppercased()) ?? m.1.uppercased(); hit = true
        } else if let alias = Self.aliases.first(where: { q.contains($0.0) }) {
            next.asset = market(alias.1) ?? "xyz:" + alias.1; hit = true
        } else {
            // Typed as a ticker («ETH», «NOW») a word counts on any exchange; in lowercase only a main-exchange ticker
            // that isn't an everyday word, so «what is open now» or «move stop» never name a market.
            for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let ticker = word.uppercased()
                guard ticker.count >= 2, !notTickers.contains(ticker) else { continue }
                let name = word == ticker ? market(ticker) : known.contains(ticker) && !everydayWords.contains(ticker) ? ticker : nil
                if let name {
                    next.asset = name; hit = true
                    break
                }
            }
        }

        // «риск $10», «риск на сделку — не больше 10$». A percent after the number is not dollars.
        if let v = number(q, /(?:риск|risk)[^\d%]{0,30}?(\d+(?:[.,]\d+)?)(?!\d|[.,]\d|\s*%)/) { next.riskUSD = v; hit = true }
        if let v = number(q, /(?:стоп|stop|\bsl\b)[^\d]{0,15}?(\d+(?:[.,]\d+)?)\s*%/) { next.stopPct = v; hit = true }
        if let v = number(q, /(?:тейк|take|\btp\b)[^\d]{0,15}?(\d+(?:[.,]\d+)?)\s*%/) { next.takePct = v; hit = true }
        // «плечо 2», «2x», «3х» (Cyrillic х), «2×»
        if let v = number(q, /(?:плеч|leverage|\blev\b)[^\d]{0,10}?(\d+(?:[.,]\d+)?)/)
            ?? number(q, /(\d+(?:[.,]\d+)?)\s*[xх×](?!\p{L})/) { next.leverage = v; hit = true }
        if let v = number(q, /(\d+(?:[.,]\d+)?)\s*usdc/) { next.amountUSDC = v; hit = true }
        // «тейк 2R», «1:3», «один к трём» are ratios to the stop, not percents.
        if let v = number(q, /(?:^|[^\d.,])(\d+(?:[.,]\d+)?)\s*r\b/) ?? number(q, /\b1\s*[:к]\s*(\d+(?:[.,]\d+)?)/) {
            next.takeR = v; next.takePct = nil; hit = true
        }
        if q.contains(/как\s+учат|как\s+советуют|по\s+правилам|как\s+(?:лучше|правильно|положено)|по\s+уму|грамотн|риск[- ]?менеджмент|by\s+the\s+(?:book|rules)|best\s+practice|properly|risk[- ]?management|like\s+(?:the\s+)?pros/) {
            next.autoRules = true; hit = true
        }
        // «вход на откате 2%», «подожди откат 2%»; «лимит 2650», «вход 2650»; «по рынку» clears both.
        if let v = number(q, /(?:откат\w*|pullback|dip|retrace\w*)[^\d]{0,12}?(\d+(?:[.,]\d+)?)\s*%/)
            ?? number(q, /(\d+(?:[.,]\d+)?)\s*%\s*(?:pullback|dip|retrace\w*)/) {
            next.pullbackPct = v; next.entryPx = nil; hit = true
        } else if let v = number(q, /(?:лимит\w*|вход\w*|limit|entry|enter)\s*(?:по|на|at)?\s*\$?(\d+(?:[.,]\d+)?)(?!\s*%|[\d.,])/) {
            next.entryPx = v; next.pullbackPct = nil; hit = true
        }
        if q.contains(/по\s+рынку|market/) { next.entryPx = nil; next.pullbackPct = nil; hit = true }
        if q.contains(/частям|частичн|scale\s*out|in\s+parts|partial/) { next.partialTake = true; hit = true }
        if let v = number(q, /(?:трейл\w*|скользящ\w*|trail\w*)(?:[- ]?(?:стоп\w*|stop))?[^\d]{0,6}?(\d+(?:[.,]\d+)?)\s*%/) { next.trailingPct = v; hit = true }

        return hit ? next : nil
    }

    /// Wording the parser cannot turn into numbers («тейк ближе», «плечо поменьше»). A message with it goes to
    /// the model whole, even if the parser recognised another part, so no part of it is silently dropped.
    public static func needsModel(_ text: String) -> Bool {
        text.lowercased().contains(/ближе|дальше|больше|меньше|выше|ниже|шире|увелич|уменьш|удво|вдвое|в \d+ раза|половин|чуть|немного|closer|further|wider|tighter|double|half|bigger|smaller|higher|lower|a bit|slightly/)
    }

    /// The market the text names («close ETH», «закрой нефть»), or nil when it names none.
    public static func namedAsset(_ text: String, markets: Set<String> = []) -> String? {
        var probe = TradeIntent()
        probe.asset = ""
        guard let found = apply(text, to: probe, markets: markets)?.asset, !found.isEmpty else { return nil }
        return found
    }

    /// A question to answer, not an order to carry out: «а где наш шорт по нефти?», «what did you do with ETH».
    public static func isQuestion(_ text: String) -> Bool {
        let q = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.hasSuffix("?") { return true }
        return q.contains(/^(?:а\s+|и\s+|so\s+|and\s+)?(?:где|что|сколько|почему|зачем|когда|какой|какая|какие|каким|куда\s+дел|кто|откуда|what|where|why|when|which|who|how\s+(?:much|many|is|are|did|was|were|do|come)|is\s+(?:my|the|there)|are\s+(?:my|there)|did\s+(?:you|i|we)|do\s+i|have\s+(?:i|you|we))\b/)
    }

    /// Whether the text has a trading word in Russian or English. Without one, a ticker and an amount alone
    /// («compra SOL por 1 USDC») are too weak to trust: the message may be another language asking for something else.
    public static func hasTradeWords(_ text: String) -> Bool {
        text.lowercased().contains(/лонг|шорт|\blong\b|\bshort\b|риск|\brisk\b|стоп|\bstop|тейк|\btake\b|\btp\b|\bsl\b|плеч|leverage|\d\s*[xх×]\b|откат|pullback|лимит|limit|по\s+рынку|market|как\s+учат|by\s+the\s+(?:book|rules)|трейл|trail|частям|in\s+parts|scale\s*out|\d\s*r\b|\b1\s*[:к]\s*\d/)
    }

    static func number(_ q: String, _ regex: Regex<(Substring, Substring)>) -> Decimal? {
        guard let m = q.firstMatch(of: regex) else { return nil }
        return Decimal(string: m.1.replacingOccurrences(of: ",", with: "."))
    }
}

/// Blocks a recovery phrase before it reaches the model, the chat history or a log.
public enum SeedGuard {
    /// True when the text has 12+ consecutive BIP-39 words. Numbers and punctuation between them
    /// («1. abandon 2. ability …») do not break the run; any other word does.
    public static func containsMnemonic(_ text: String) -> Bool {
        var run = 0
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            run = BIP39.index[String(word)] != nil ? run + 1 : 0
            if run >= 12 { return true }
        }
        return false
    }
}

public enum Fmt {
    static let locale = Locale(identifier: "en_US")
    public static func usd(_ d: Decimal) -> String {
        let text = abs(d).formatted(.number.precision(.fractionLength(2)).locale(locale))
        return (d < 0 && text != "0.00" ? "−$" : "$") + text
    }
    public static func num(_ d: Decimal, maxFraction: Int = 2) -> String {
        d.formatted(.number.precision(.fractionLength(0...maxFraction)).locale(locale))
    }
    public static func price(_ d: Decimal) -> String { d.formatted(.number.precision(.significantDigits(1...6)).locale(locale)) }
    public static func pct(_ d: Decimal) -> String { num(d) + "%" }
    /// «28 сент., 22:38»: no year, so a non-Gregorian system calendar does not show «2569 г. BE».
    public static func date(_ d: Date) -> String { d.formatted(Date.FormatStyle(locale: locale).day().month(.abbreviated).hour().minute()) }
    /// «23:48» — for the second end of a span on the same day.
    public static func time(_ d: Date) -> String { d.formatted(Date.FormatStyle(locale: locale).hour().minute()) }
}

extension Decimal {
    public func rounded(_ scale: Int, _ mode: NSDecimalNumber.RoundingMode) -> Decimal {
        var value = self, result = Decimal()
        NSDecimalRound(&result, &value, scale, mode)
        return result
    }
}
