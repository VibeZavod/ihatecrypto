import Foundation

/// A trader's Hyperliquid record measured the way the trading study skill asks (the owner's prompt, 2026-10-16): edge
/// or luck. Closed positions only, each after fees and the funding paid or received while it was open; every number
/// here comes from the exchange's fills, the model only reads them.
public enum TradeStudy {
    public struct Trade: Sendable, Equatable {
        public let coin: String
        public let long: Bool
        public let opened: Date
        public let closed: Date
        /// After fees and funding.
        public let net: Decimal
        public let fees: Decimal
        public let funding: Decimal
        /// The largest the position got, in dollars at the average entry.
        public let peakUSD: Decimal
        public let entry: Decimal
        public let adds: Int
        /// Adds made at a worse price than the average so far: adding to a loser.
        public let addsLosing: Int
        public let liquidated: Bool
        public var hours: Double { closed.timeIntervalSince(opened) / 3600 }
    }

    public static func trades(_ stories: [TradeHistory.Story], funding: [PnL.Funding]) -> [Trade] {
        stories.compactMap { s in
            // A position already open when the history begins has no entry to measure from (`cut`).
            guard let closed = s.closed, let first = s.fills.first, first.startPosition == 0 else { return nil }
            // A flip (long straight to short) closes this story: its fill counts as a close to zero here.
            func sizes(_ f: TradeHistory.Fill) -> (before: Decimal, after: Decimal) {
                let flips = f.startPosition != 0 && f.endPosition != 0 && (f.startPosition > 0) != (f.endPosition > 0)
                return (abs(f.startPosition), flips ? 0 : abs(f.endPosition))
            }
            var size: Decimal = 0, cost: Decimal = 0, adds = 0, addsLosing = 0, peak: Decimal = 0
            for (i, f) in s.fills.enumerated() {
                let (before, after) = sizes(f)
                if after > before {
                    let avg = size > 0 ? cost / size : f.px
                    if i > 0 { adds += 1; if s.long ? f.px < avg : f.px > avg { addsLosing += 1 } }
                    cost += (after - before) * f.px; size += after - before
                    peak = max(peak, after * cost / size)
                } else if size > 0 {
                    cost -= cost / size * (before - after); size = after
                }
            }
            let paid = funding.filter { $0.coin == s.coin && $0.time >= first.time && $0.time <= closed }.reduce(0) { $0 + $1.usdc }
            let entries = s.fills.map { (sizes($0), $0.px) }.filter { $0.0.after > $0.0.before }
            let bought = entries.reduce(Decimal(0)) { $0 + $1.0.after - $1.0.before }
            let entry = bought > 0 ? entries.reduce(Decimal(0)) { $0 + ($1.0.after - $1.0.before) * $1.1 } / bought : first.px
            return Trade(coin: s.coin, long: s.long, opened: first.time, closed: closed, net: s.realized + paid, fees: s.fees,
                         funding: paid, peakUSD: peak, entry: entry, adds: adds, addsLosing: addsLosing,
                         liquidated: s.fills.contains { $0.dir.localizedCaseInsensitiveContains("liquidat") })
        }
        .sorted { $0.closed < $1.closed }
    }

    public struct Stats: Sendable, Equatable {
        public let count: Int, wins: Int
        public let total: Decimal, avgWin: Decimal, avgLoss: Decimal
        /// Won ÷ lost; nil with no losses.
        public let profitFactor: Decimal?
        /// The deepest fall of the running result from its high, in dollars.
        public let maxDrawdown: Decimal
        public var winRate: Decimal { count > 0 ? Decimal(wins) / Decimal(count) * 100 : 0 }
        public var expectancy: Decimal { count > 0 ? total / Decimal(count) : 0 }
    }

    public static func stats(_ trades: [Trade]) -> Stats {
        let won = trades.filter { $0.net > 0 }, lost = trades.filter { $0.net <= 0 }
        let plus = won.reduce(Decimal(0)) { $0 + $1.net }, minus = lost.reduce(Decimal(0)) { $0 + $1.net }
        var running: Decimal = 0, high: Decimal = 0, drawdown: Decimal = 0
        for t in trades.sorted(by: { $0.closed < $1.closed }) {
            running += t.net; high = max(high, running); drawdown = max(drawdown, high - running)
        }
        return Stats(count: trades.count, wins: won.count, total: plus + minus,
                     avgWin: won.isEmpty ? 0 : plus / Decimal(won.count), avgLoss: lost.isEmpty ? 0 : minus / Decimal(lost.count),
                     profitFactor: minus < 0 ? plus / -minus : nil, maxDrawdown: drawdown)
    }

    /// How few winners make most of the profit: «72% of the profit came from 4 trades».
    public static func concentration(_ trades: [Trade]) -> (trades: Int, share: Decimal)? {
        let wins = trades.map(\.net).filter { $0 > 0 }.sorted(by: >)
        let plus = wins.reduce(0, +)
        guard plus > 0, wins.count >= 3 else { return nil }
        var sum: Decimal = 0
        for (i, w) in wins.enumerated() {
            sum += w
            if sum >= plus / 2 { return (i + 1, sum / plus * 100) }
        }
        return nil
    }

    /// The record in lines for the model: the whole, without the best trades, by side, coin, holding time and weekday,
    /// adding, and the biggest winners and losers.
    /// Positions the history begins in the middle of: Hyperliquid serves only the last 10,000 fills.
    public static func cut(_ stories: [TradeHistory.Story]) -> Int { stories.filter { ($0.fills.first?.startPosition ?? 0) != 0 }.count }

    public static func report(_ trades: [Trade], open: Int, cut: Int = 0, timeZone: TimeZone = .current) -> String {
        guard let first = trades.first, let last = trades.last else {
            return "No closed Hyperliquid positions in this history\(open > 0 ? " (\(open) still open)" : "")."
        }
        func line(_ title: String, _ t: [Trade]) -> String {
            let s = stats(t)
            return "\(title): \(s.count) trade\(s.count == 1 ? "" : "s"), won \(Fmt.num(s.winRate, maxFraction: 0))%, net \(Fmt.usd(s.total)), avg win \(Fmt.usd(s.avgWin)), avg loss \(Fmt.usd(s.avgLoss))"
                + (s.profitFactor.map { ", profit factor \(Fmt.num($0))" } ?? "") + ", expectancy \(Fmt.usd(s.expectancy)) a trade"
        }
        let all = stats(trades)
        var out = ["Hyperliquid record, \(Fmt.date(first.opened)) – \(Fmt.date(last.closed)) (closed positions after fees and funding\(open > 0 ? "; \(open) still open, not counted" : "")\(cut > 0 ? "; \(cut) begun before the history, not counted" : "")):",
                   line("All", trades),
                   "Fees \(Fmt.usd(trades.reduce(0) { $0 + $1.fees })), funding \(Fmt.usd(trades.reduce(0) { $0 + $1.funding })), worst drawdown \(Fmt.usd(-all.maxDrawdown))."]
        if let c = concentration(trades) {
            out.append("\(Fmt.num(c.share, maxFraction: 0))% of the profit came from \(c.trades) trade\(c.trades == 1 ? "" : "s").")
        }
        let best = trades.sorted { $0.net > $1.net }
        for n in [1, 3] where best.count > n + 2 && best[n - 1].net > 0 {
            out.append(line("Without the best \(n)", Array(best.dropFirst(n))))
        }
        out.append(line("Longs", trades.filter(\.long)))
        out.append(line("Shorts", trades.filter { !$0.long }))
        for (coin, t) in Dictionary(grouping: trades, by: \.coin).sorted(by: { $0.value.count > $1.value.count }).prefix(8) {
            out.append(line(coin, t))
        }
        for (title, range) in [("Held under 1 h", 0.0..<1), ("Held 1–24 h", 1..<24), ("Held 1–7 days", 24..<168), ("Held over 7 days", 168..<Double.infinity)] {
            let t = trades.filter { range.contains($0.hours) }
            if !t.isEmpty { out.append(line(title, t)) }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = Dictionary(grouping: trades) { calendar.component(.weekday, from: $0.opened) }
        out.append("By the day opened: " + days.keys.sorted().map { d in
            let s = stats(days[d]!)
            return "\(calendar.shortWeekdaySymbols[d - 1]) \(s.count) / \(Fmt.usd(s.total))"
        }.joined(separator: ", ") + ".")
        let added = trades.filter { $0.adds > 0 }, losing = trades.filter { $0.addsLosing > 0 }
        if !added.isEmpty { out.append(line("With adds", added)) }
        if !losing.isEmpty { out.append(line("Added to a loser", losing)) }
        let liquidated = trades.filter(\.liquidated)
        if !liquidated.isEmpty { out.append("Liquidated \(liquidated.count) time\(liquidated.count == 1 ? "" : "s"), \(Fmt.usd(liquidated.reduce(0) { $0 + $1.net })).") }
        func story(_ t: Trade) -> String {
            "\(Fmt.date(t.opened)) \(t.long ? "long" : "short") \(t.coin) ≈ \(Fmt.usd(t.peakUSD)) at \(Fmt.price(t.entry))"
                + (t.adds > 0 ? ", \(t.adds) add\(t.adds == 1 ? "" : "s")" : "") + ", held \(held(t.hours)) → \(Fmt.usd(t.net))"
        }
        out.append("Biggest winners: " + best.prefix(5).filter { $0.net > 0 }.map(story).joined(separator: "; ") + ".")
        out.append("Biggest losers: " + best.reversed().prefix(5).filter { $0.net < 0 }.map(story).joined(separator: "; ") + ".")
        return out.joined(separator: "\n")
    }

    static func held(_ hours: Double) -> String {
        hours < 1 ? "\(max(1, Int(hours * 60))) min" : hours < 48 ? "\(Int(hours.rounded())) h" : "\(Int((hours / 24).rounded())) d"
    }
}
