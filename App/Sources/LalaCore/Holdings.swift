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
    /// nil when the network couldn't be read in full: the caller keeps what it had instead of showing a shorter list.
    public static func evm(_ chain: String, address: String, native: Bool, skip: Set<String>) async -> [Holding]? {
        guard let host = blockscout[chain] else { return [] }
        async let pages = tokenPages(host, address: address)
        async let account: [String: Any]?? = native
            ? .some(await retrying { json(try await HTTP.get("https://\(host)/api/v2/addresses/\(address)", headers: browser)) as? [String: Any] })
            : .none
        guard let items = await pages else { return nil }
        var out = evmTokens(chain, items, skip: skip)
        switch await account {
        case .some(nil): return nil
        case .some(let a?): if let eth = nativeCoin(chain, a) { out.append(eth) }
        case .none: break
        }
        // Tokens CoinGecko doesn't list get DexScreener's price and pool, so the scam check has something to go on.
        // DexScreener takes 30 contracts a call.
        // ponytail: 20 calls at most (600 tokens); past that the rest stays listed under «hidden», unpriced.
        let unpriced = out.filter { $0.price == nil }.map(\.contract)
        for start in stride(from: 0, to: min(unpriced.count, 600), by: 30) {
            let chunk = unpriced[start..<min(start + 30, unpriced.count)]
            out = dexPrices(out, try? await HTTP.get("https://api.dexscreener.com/tokens/v1/\(chain)/" + chunk.joined(separator: ",")))
        }
        return out
    }

    /// Every page of the address's ERC-20s. Blockscout serves 50 at a time, the most valuable first, and says where the
    /// next page starts; a page that fails is asked again (the API throws the odd 500). nil when even the first page
    /// never came; a later one that never comes ends the list there, losing only the least valuable tail.
    // ponytail: 20 pages at most (1000 tokens): past that the address is a spam dump and the tail is unpriced dust.
    static func tokenPages(_ host: String, address: String) async -> [[String: Any]]? {
        var items: [[String: Any]] = []
        var next: [String: Any]? = [:]
        for page in 0..<20 {
            guard let params = next else { break }
            var url = URLComponents(string: "https://\(host)/api/v2/addresses/\(address)/tokens")
            url?.queryItems = [URLQueryItem(name: "type", value: "ERC-20")]
                + params.sorted { $0.key < $1.key }.compactMap { k, v in v is NSNull ? nil : URLQueryItem(name: k, value: "\(v)") }
            guard let link = url?.string,
                  let body = await retrying({ json(try await HTTP.get(link, headers: browser)) as? [String: Any] }) else { return page == 0 ? nil : items }
            items += body["items"] as? [[String: Any]] ?? []
            next = body["next_page_params"] as? [String: Any]
        }
        return items
    }

    static func evmTokens(_ chain: String, _ items: [[String: Any]], skip: Set<String>) -> [Holding] {
        items.compactMap { item in
            guard let t = item["token"] as? [String: Any], let contract = (t["address_hash"] as? String)?.lowercased(), !skip.contains(contract),
                  let raw = number(item["value"]), raw > 0, let decimals = Int(t["decimals"] as? String ?? "") else { return nil }
            let rate = number(t["exchange_rate"])
            return Holding(chain: chain, contract: contract, amount: raw / pow(10, decimals), symbol: t["symbol"] as? String ?? "?",
                           icon: (t["icon_url"] as? String).flatMap(URL.init(string:)), price: rate,
                           verified: rate != nil && t["reputation"] as? String != "scam")
        }
    }

    static func nativeCoin(_ chain: String, _ a: [String: Any]) -> Holding? {
        guard let wei = number(a["coin_balance"]), wei > 0 else { return nil }
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
    /// nil when it couldn't be read.
    public static func hyperliquidSpot(user: String) async -> [Holding]? {
        async let state = retrying { try await HTTP.post("https://api.hyperliquid.xyz/info", json: ["type": "spotClearinghouseState", "user": user]) }
        async let meta = retrying { try await HTTP.post("https://api.hyperliquid.xyz/info", json: ["type": "spotMetaAndAssetCtxs"]) }
        guard let s = await state, let m = await meta else { return nil }
        return hyperliquidSpot(s, meta: m)
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
    /// a token it doesn't list is named by its own contract's metadata, all of them asked at once. nil when the
    /// account's list or the prices couldn't be read.
    public static func near(account: String) async -> [Holding]? {
        async let list = retrying { try await HTTP.get("https://api.fastnear.com/v1/account/\(account)/ft") }
        async let prices = retrying { try await HTTP.get("https://indexer.ref.finance/list-token-price") }
        guard let listed = await list, let priced = await prices else { return nil }
        let ref = json(priced) as? [String: [String: Any]] ?? [:]
        let unlisted = nearBalances(listed).map(\.contract).filter { ref[$0] == nil }
        let metadata = await withTaskGroup(of: (String, (symbol: String, decimals: Int)?).self) { group in
            for contract in unlisted { group.addTask { (contract, await nearMetadata(contract)) } }
            var out: [String: (symbol: String, decimals: Int)] = [:]
            for await (contract, m) in group { out[contract] = m }
            return out
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

    /// Up to three tries, a second apart: public APIs drop the odd request.
    static func retrying<T>(_ fetch: () async throws -> T?) async -> T? {
        for attempt in 0..<3 {
            if let value = try? await fetch() { return value }
            if attempt < 2 { try? await Task.sleep(for: .seconds(1)) }
        }
        return nil
    }

    /// Through the number's text: a JSON double's decimalValue turns 1.88 into 1.8799999….
    static func number(_ v: Any?) -> Decimal? { ((v as? NSNumber)?.stringValue ?? v as? String).flatMap { Decimal(string: $0) } }
}
