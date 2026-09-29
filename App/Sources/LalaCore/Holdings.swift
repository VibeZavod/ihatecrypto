import Foundation
import LLMCore

/// A token the wallet holds, on any network, beyond the balances the app reads one by one (USDC, lending positions,
/// stock tokens…). Found by listing the address on each network; priced where a market knows it.
public struct Holding: Sendable, Identifiable, Equatable {
    /// «solana», «base», «arbitrum», «ethereum», «robinhood», «hyperliquid» (spot) or «near».
    public let chain: String
    /// The mint, the contract, the spot token's name or the NEAR contract; «native» for the network's own coin.
    public let contract: String
    public let amount: Decimal
    public var symbol: String
    public var icon: URL?
    public var price: Decimal?
    /// A market list vouches for it: Jupiter's check, a CoinGecko rate on Blockscout, Ref's price list.
    public var verified = false
    /// The pool behind the price (or, on Hyperliquid's spot book, the day's volume).
    public var liquidity: Decimal?
    /// The network's own coin (ETH on Arbitrum and Ethereum): gas, in the balance but not in the risk rules' capital.
    public var native = false

    /// The key the user's show/hide choice is kept under: the mint on Solana, «chain:contract» elsewhere.
    public var id: String { chain == "solana" ? contract : "\(chain):\(contract.lowercased())" }
    public var usd: Decimal? { price.map { $0 * amount } }
    /// Airdropped look-alikes are unverified with no real pool behind them: they stay out of sight until the user
    /// asks. A token the user bought has a pool (or a market list's check) and shows.
    public var looksReal: Bool { verified || ((liquidity ?? 0) >= 10_000 && (usd ?? 0) >= 0.01) }
}

public enum Holdings {
    // Blockscout turns away clients that don't look like a browser (403 on Robinhood Chain's instance).
    static let browser = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"]
    static let blockscout = ["base": "base.blockscout.com", "arbitrum": "arbitrum.blockscout.com",
                             "ethereum": "eth.blockscout.com", "robinhood": "robinhoodchain.blockscout.com"]
    static let ethIcon = URL(string: "https://assets.coingecko.com/coins/images/279/small/ethereum.png")

    // MARK: EVM networks

    /// Every ERC-20 at the address on one network, and its ETH when `native` (Base's and Robinhood's ETH is already
    /// counted as gas). `skip`: contracts the app counts elsewhere (USDC, Aave's aUSDC, the Morpho vault…), lowercased.
    public static func evm(_ chain: String, address: String, native: Bool, skip: Set<String>) async -> [Holding] {
        guard let host = blockscout[chain] else { return [] }
        async let tokens = try? HTTP.get("https://\(host)/api/v2/addresses/\(address)/tokens?type=ERC-20", headers: browser)
        async let account: Data? = native ? (try? await HTTP.get("https://\(host)/api/v2/addresses/\(address)", headers: browser)) : nil
        var out = evmTokens(chain, await tokens, skip: skip)
        if let eth = nativeCoin(chain, await account) { out.append(eth) }
        // Tokens CoinGecko doesn't list get DexScreener's price and pool, so the scam check has something to go on.
        let unpriced = out.filter { $0.price == nil }.map(\.contract)
        guard !unpriced.isEmpty else { return out }
        // ponytail: DexScreener takes 30 contracts a call; a wallet flooded with more airdrops leaves the rest unpriced.
        let dex = try? await HTTP.get("https://api.dexscreener.com/tokens/v1/\(chain)/" + unpriced.prefix(30).joined(separator: ","))
        return dexPrices(out, dex)
    }

    static func evmTokens(_ chain: String, _ data: Data?, skip: Set<String>) -> [Holding] {
        let items = (json(data) as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let t = item["token"] as? [String: Any], let contract = (t["address_hash"] as? String)?.lowercased(), !skip.contains(contract),
                  let raw = number(item["value"]), raw > 0, let decimals = Int(t["decimals"] as? String ?? "") else { return nil }
            let rate = number(t["exchange_rate"])
            return Holding(chain: chain, contract: contract, amount: raw / pow(10, decimals), symbol: t["symbol"] as? String ?? "?",
                           icon: (t["icon_url"] as? String).flatMap(URL.init(string:)), price: rate,
                           verified: rate != nil && t["reputation"] as? String != "scam")
        }
    }

    static func nativeCoin(_ chain: String, _ data: Data?) -> Holding? {
        guard let a = json(data) as? [String: Any], let wei = number(a["coin_balance"]), wei > 0 else { return nil }
        return Holding(chain: chain, contract: "native", amount: wei / pow(10, 18), symbol: "ETH", icon: ethIcon,
                       price: number(a["exchange_rate"]), verified: true, native: true)
    }

    /// The deepest pool per token from DexScreener's pairs.
    static func dexPrices(_ tokens: [Holding], _ data: Data?) -> [Holding] {
        var best: [String: (price: Decimal, liquidity: Decimal)] = [:]
        for pair in json(data) as? [[String: Any]] ?? [] {
            guard let base = ((pair["baseToken"] as? [String: Any])?["address"] as? String)?.lowercased(),
                  let price = number(pair["priceUsd"]) else { continue }
            let liquidity = number((pair["liquidity"] as? [String: Any])?["usd"]) ?? 0
            if liquidity >= best[base]?.liquidity ?? -1 { best[base] = (price, liquidity) }
        }
        return tokens.map { t in
            guard t.price == nil, let b = best[t.contract] else { return t }
            var priced = t
            priced.price = b.price
            priced.liquidity = b.liquidity
            return priced
        }
    }

    // MARK: Hyperliquid spot

    /// Everything on Hyperliquid's spot side, USDC included (the perp account doesn't count it), priced off its own book.
    public static func hyperliquidSpot(user: String) async -> [Holding] {
        async let state = try? HTTP.post("https://api.hyperliquid.xyz/info", json: ["type": "spotClearinghouseState", "user": user])
        async let meta = try? HTTP.post("https://api.hyperliquid.xyz/info", json: ["type": "spotMetaAndAssetCtxs"])
        return hyperliquidSpot(await state, meta: await meta)
    }

    static func hyperliquidSpot(_ state: Data?, meta: Data?) -> [Holding] {
        let balances = (json(state) as? [String: Any])?["balances"] as? [[String: Any]] ?? []
        let pair = json(meta) as? [Any] ?? []
        let universe = (pair.first as? [String: Any])?["universe"] as? [[String: Any]] ?? []
        let contexts = pair.count > 1 ? pair[1] as? [[String: Any]] ?? [] : []
        return balances.compactMap { b in
            guard let coin = b["coin"] as? String, let token = b["token"] as? Int, let amount = number(b["total"]), amount > 0 else { return nil }
            if token == 0 { return Holding(chain: "hyperliquid", contract: coin, amount: amount, symbol: "USDC", price: 1, verified: true) }
            // The token's market against USDC (token 0) on the spot book.
            let market = universe.first { ($0["tokens"] as? [Int]) == [token, 0] }
            let context = (market?["index"] as? Int).flatMap { $0 < contexts.count ? contexts[$0] : nil }
            return Holding(chain: "hyperliquid", contract: coin, amount: amount, symbol: coin,
                           price: number(context?["midPx"]) ?? number(context?["markPx"]), liquidity: number(context?["dayNtlVlm"]))
        }
    }

    // MARK: NEAR

    /// Fungible tokens on the NEAR account, wNEAR aside (counted with NEAR). Ref's price list names and prices them;
    /// a token it doesn't list is named by its own contract's metadata.
    public static func near(account: String) async -> [Holding] {
        async let list = try? HTTP.get("https://api.fastnear.com/v1/account/\(account)/ft")
        async let prices = try? HTTP.get("https://indexer.ref.finance/list-token-price")
        let listed = await list, priced = await prices
        var metadata: [String: (symbol: String, decimals: Int)] = [:]
        let ref = json(priced) as? [String: [String: Any]] ?? [:]
        for (contract, _) in nearBalances(listed) where ref[contract] == nil {
            if let m = await nearMetadata(contract) { metadata[contract] = m }
        }
        return near(listed, prices: priced, metadata: metadata)
    }

    static func nearBalances(_ data: Data?) -> [(contract: String, raw: Decimal)] {
        ((json(data) as? [String: Any])?["tokens"] as? [[String: Any]] ?? []).compactMap { t in
            guard let c = t["contract_id"] as? String, c != "wrap.near", let raw = number(t["balance"]), raw > 0 else { return nil }
            return (c, raw)
        }
    }

    static func near(_ list: Data?, prices: Data?, metadata: [String: (symbol: String, decimals: Int)]) -> [Holding] {
        let ref = json(prices) as? [String: [String: Any]] ?? [:]
        return nearBalances(list).compactMap { contract, raw in
            let listed = ref[contract]
            guard let decimals = (listed?["decimal"] as? Int) ?? metadata[contract]?.decimals else { return nil }
            let symbol = (listed?["symbol"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? metadata[contract]?.symbol ?? String(contract.prefix(8))
            let amount = raw / pow(10, decimals), price = number(listed?["price"])
            // Ref lists junk too: its price counts as a check only when the holding is worth a cent.
            return Holding(chain: "near", contract: contract, amount: amount, symbol: symbol, price: price,
                           verified: (price ?? 0) * amount >= 0.01)
        }
    }

    static func nearMetadata(_ contract: String) async -> (symbol: String, decimals: Int)? {
        let params: [String: Any] = ["request_type": "call_function", "finality": "final", "account_id": contract,
                                     "method_name": "ft_metadata", "args_base64": "e30="]
        guard let data = try? await HTTP.post("https://rpc.mainnet.fastnear.com", json: ["jsonrpc": "2.0", "id": 1, "method": "query", "params": params]),
              let bytes = ((json(data) as? [String: Any])?["result"] as? [String: Any])?["result"] as? [Int],
              let m = try? JSONSerialization.jsonObject(with: Data(bytes.map(UInt8.init))) as? [String: Any],
              let decimals = m["decimals"] as? Int else { return nil }
        return (m["symbol"] as? String ?? String(contract.prefix(8)), decimals)
    }

    // MARK: Helpers

    static func json(_ data: Data?) -> Any? { data.flatMap { try? JSONSerialization.jsonObject(with: $0) } }

    /// Through the number's text: a JSON double's decimalValue turns 1.88 into 1.8799999….
    static func number(_ v: Any?) -> Decimal? { ((v as? NSNumber)?.stringValue ?? v as? String).flatMap { Decimal(string: $0) } }
}
