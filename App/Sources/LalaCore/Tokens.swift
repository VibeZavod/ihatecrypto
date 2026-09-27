import Foundation

/// Any token by its contract: name, symbol, price, 24 h move, liquidity and its icon, from DexScreener's public API
/// (api.dexscreener.com, no key). The chain is the one with the most liquidity for it.
public enum TokenLookup {
    public struct Info: Codable, Equatable, Sendable {
        /// DexScreener's chain id: «robinhood», «base», «arbitrum», «solana», «ethereum»…
        public let chain: String
        public let address: String
        public let name: String
        public let symbol: String
        public let priceUSD: Decimal?
        public let change24h: Decimal?
        public let liquidityUSD: Decimal?
        public let imageURL: URL?
        public let pairURL: URL?
    }

    public static func lookup(_ address: String) async throws -> [Info] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://api.dexscreener.com/latest/dex/tokens/\(address)")!)
        return parse(data, address: address)
    }

    /// One entry per chain, from the deepest pair where the token is the base; deepest chain first.
    public static func parse(_ data: Data, address: String) -> [Info] {
        guard let pairs = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["pairs"] as? [[String: Any]] else { return [] }
        func dec(_ v: Any?) -> Decimal? { (v as? String).flatMap { Decimal(string: $0) } ?? (v as? NSNumber).map { $0.decimalValue } }
        var best: [String: (Decimal, Info)] = [:]
        for p in pairs {
            guard let base = p["baseToken"] as? [String: Any], (base["address"] as? String)?.lowercased() == address.lowercased(),
                  let chain = p["chainId"] as? String else { continue }
            let liquidity = dec((p["liquidity"] as? [String: Any])?["usd"]) ?? 0
            guard liquidity > (best[chain]?.0 ?? -1) else { continue }
            let info = Info(chain: chain, address: base["address"] as? String ?? address, name: base["name"] as? String ?? "?", symbol: base["symbol"] as? String ?? "?",
                            priceUSD: dec(p["priceUsd"]), change24h: dec((p["priceChange"] as? [String: Any])?["h24"]), liquidityUSD: liquidity,
                            imageURL: ((p["info"] as? [String: Any])?["imageUrl"] as? String).flatMap(URL.init), pairURL: (p["url"] as? String).flatMap(URL.init))
            best[chain] = (liquidity, info)
        }
        return best.values.sorted { $0.0 > $1.0 }.map(\.1)
    }
}

/// «добавь в favorite вот этот токен на робингуде 0x…», «watch token 0x… on Base», «remove token AI from favorites».
public enum TokenCommand: Equatable, Sendable {
    /// `chain`: as the user named it (DexScreener's id), nil = wherever it trades most.
    case favorite(address: String, chain: String?)
    case unfavorite(symbol: String)

    public static func parse(_ text: String) -> TokenCommand? {
        let q = text.lowercased()
        if let m = text.firstMatch(of: /(?i)(?:remove|unstar|убери|удали)\s+(?:the\s+)?(?:token|токен)\s+\$?([a-z0-9]{1,12})\s+(?:from|из)\s+(?:my\s+)?(?:favou?rites?|избранн\w*|watchlist)/) {
            return .unfavorite(symbol: String(m.1).uppercased())
        }
        guard let address = AddressBookCommand.address(in: text),
              q.contains(/\btoken|токен|\bcoin\b|монет|watch|следи|favou?rite|избранн|watchlist/),
              // «save 0x… as Bybit» is an address for the book, not a token.
              !q.contains(/\bas\s|\bcalled\b|\bnamed\b|\bкак\s|под\s+именем/) else { return nil }
        let chain: String? = q.contains(/robinhood|робинхуд|робингуд/) ? "robinhood" : q.contains(/\bbase\b|бейс/) ? "base"
            : q.contains(/arbitrum|арбитрум/) ? "arbitrum" : q.contains(/ethereum|эфириум|\beth\s+mainnet/) ? "ethereum"
            : q.contains(/solana|солан/) || !address.hasPrefix("0x") ? "solana" : nil
        return .favorite(address: address, chain: chain)
    }
}
