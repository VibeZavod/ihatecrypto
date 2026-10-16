import Foundation

/// One journal entry (JournalCommand): the trader's words and what the market was doing as they wrote them, so the
/// trading study can set the reasoning against what happened next.
public struct JournalEntry: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public let at: Date
    /// Hyperliquid's name for the market: «HYPE», «xyz:GOLD».
    public let asset: String
    public let words: String
    public var price: Decimal?
    /// Hourly; positive means longs pay shorts.
    public var funding: Decimal?
    public var openInterestUSD: Decimal?
    public var volume24h: Decimal?
    public var change24h: Decimal?
    /// «BTC $67,120 (24h +1.2%)», «ETH …».
    public var market: [String] = []
    /// Their position in it then, as the portfolio says it.
    public var position: String?

    public init(at: Date, asset: String, words: String) { self.at = at; self.asset = asset; self.words = words }

    /// What was kept with it, in a line.
    public var snapshot: String {
        [price.map { "price \(Fmt.price($0))" }, change24h.map { "24h \(change($0))" },
         funding.map { "funding \(Fmt.num(($0 * 100).rounded(4, .plain), maxFraction: 4))% an hour" },
         openInterestUSD.map { "open interest \(big($0))" }, volume24h.map { "24h volume \(big($0))" }].compactMap { $0 }
            .joined(separator: ", ") + (market.isEmpty ? "" : "; " + market.joined(separator: ", "))
            + (position.map { "; their position: \($0)" } ?? "")
    }

    /// The entry for the study's review: when, their words, the snapshot, and what the price did since.
    public func review(now price: Decimal?, at now: Date = Date()) -> String {
        let since: String = {
            guard let then = self.price, then > 0, let price else { return "" }
            return " → since: \(Fmt.price(then)) → \(Fmt.price(price)) (\(change((price - then) / then * 100))) in \(TradeStudy.held(now.timeIntervalSince(at) / 3600))"
        }()
        return "\(Fmt.date(at)) \(asset): «\(words)» [\(snapshot)]\(since)"
    }

    /// Open interest in dollars now, from Hyperliquid (a HIP-3 market from its own exchange: «xyz:GOLD» → dex xyz).
    public static func openInterestUSD(coin: String) async -> Decimal? {
        var body: [String: Any] = ["type": "metaAndAssetCtxs"]
        if coin.contains(":") { body["dex"] = String(coin.split(separator: ":")[0]) }
        return (try? await TradeHistory.info(body)).flatMap { openInterestUSD($0, coin: coin) }
    }

    /// Open interest in dollars from a `metaAndAssetCtxs` answer: the coins open × the mark price.
    public static func openInterestUSD(_ json: Data, coin: String) -> Decimal? {
        guard let pair = try? JSONSerialization.jsonObject(with: json) as? [Any], pair.count == 2,
              let universe = (pair[0] as? [String: Any])?["universe"] as? [[String: Any]], let ctxs = pair[1] as? [[String: Any]],
              let i = universe.firstIndex(where: { $0["name"] as? String == coin }), i < ctxs.count,
              let oi = (ctxs[i]["openInterest"] as? String).flatMap({ Decimal(string: $0) }),
              let px = (ctxs[i]["markPx"] as? String).flatMap({ Decimal(string: $0) }) else { return nil }
        return oi * px
    }
}

/// «$1.64B», «$585.3M».
private func big(_ d: Decimal) -> String {
    d >= 1_000_000_000 ? "$" + Fmt.num((d / 1_000_000_000).rounded(2, .plain)) + "B" : "$" + Fmt.num((d / 1_000_000).rounded(1, .plain)) + "M"
}

private func change(_ d: Decimal) -> String { (d >= 0 ? "+" : "−") + Fmt.num(abs(d).rounded(2, .plain)) + "%" }
