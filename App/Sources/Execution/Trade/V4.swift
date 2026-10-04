import EVMChain
import Foundation
import IhatecryptoCore
import RelayBridge

/// Uniswap v4 on Robinhood Chain, for the stock and token buys and sales (Stocks.swift): the pool without hooks for a
/// pair, its quote, and the swap — the input to Permit2 (exact), Permit2 to the Universal Router (exact, for half an hour),
/// then one V4_SWAP that pays this wallet (the signer reads it back field by field: UniswapV4.refusal).
/// Every way a trade on Robinhood Chain can go, quoted for one amount: Uniswap v4's pool without hooks, v3's best pool,
/// Relay's swap (only for a token DexScreener lists: its checks need that price).
struct StockWays {
    var v4: Executor.V4Route?
    var v3: (fee: UInt64, out: Decimal)?
    var relay: Decimal?
    /// What each gives, the most first: «v4», «v3», «relay».
    var ranked: [(name: String, out: Decimal)] {
        [("v4", v4?.out), ("v3", v3?.out), ("relay", relay)].compactMap { name, out in out.map { (name, $0) } }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }
    static func title(_ way: String) -> String { way == "v4" ? "Uniswap v4" : way == "v3" ? "Uniswap v3" : "Relay's swap" }
}

extension Executor {
    typealias V4Route = (key: UniswapV4.PoolKey, zeroForOne: Bool, out: Decimal)

    /// All three ways for `units` of what goes in (USDG for a buy, the token for a sale), quoted at once.
    func stockWays(_ token: RobinhoodStocks.Token, buy: Bool, units: Decimal, listing: TokenLookup.Info?) async -> StockWays {
        let usdg = EVMRPC.robinhoodUSDG, me = wallet.evm
        let (tokenIn, tokenOut) = buy ? (usdg, token.address) : (token.address, usdg)
        async let v4 = v4Route(tokenIn, tokenOut, amountIn: units)
        async let v3 = try? bestPool(tokenIn, tokenOut, amountIn: units)
        async let relay: Decimal? = listing == nil ? nil : (try? await Relay.quote(user: me, recipient: me, originChain: Relay.Chain.robinhood,
                                                                                     destinationChain: Relay.Chain.robinhood, originCurrency: tokenIn,
                                                                                     destinationCurrency: tokenOut, amount: 0, units: "\(units)"))
            .flatMap { Decimal(string: $0.amountOut) }
        return StockWays(v4: await v4, v3: await v3 ?? nil, relay: await relay)
    }

    /// The ways for the card while it waits for Confirm, the best first, nothing signed: what each gives and its worth
    /// in dollars (a buy: the dollars in, scaled by what each gives against the best).
    public func stockQuotes(_ symbolOrContract: String, usdc: Decimal?, sell: Decimal?) async throws -> [(way: String, gets: String, worth: Decimal)] {
        let (token, listing) = try await RobinhoodStocks.resolve(symbolOrContract)
        let scale = Decimal(sign: .plus, exponent: token.decimals, significand: 1)
        if let usdc {
            var units = NSDecimalNumber(decimal: (usdc * 1_000_000).rounded(0, .down)).uint64Value
            let there = try await EVMRPC.robinhood.tokenBalance(EVMRPC.robinhoodUSDG, owner: wallet.evm)
            if there < units, there > 0, units - there <= max(1_000_000, units / 50) { units = there }
            let ranked = await stockWays(token, buy: true, units: Decimal(units), listing: listing).ranked
            guard let top = ranked.first?.out else { return [] }
            return ranked.map { ($0.name, "\(Fmt.num($0.out / scale, maxFraction: 2)) \(token.symbol)", Decimal(units) / 1_000_000 * $0.out / top) }
        }
        let held = try await balance(token.address, on: EVMRPC.robinhood)
        let wanted = (sell.map { min($0 * scale, held) } ?? held).rounded(0, .down)
        guard wanted > 0 else { return [] }
        return await stockWays(token, buy: false, units: wanted, listing: listing).ranked.map { ($0.name, "\(Fmt.num($0.out / 1_000_000)) USDG", $0.out / 1_000_000) }
    }

    /// «Uniswap v4 ≈ 1,906 AI · Relay's swap ≈ 1,880 · Uniswap v3 ≈ 1,372»: what the report says before the best is taken.
    func waysLine(_ ways: StockWays, _ unit: (Decimal) -> String) -> String {
        ways.ranked.map { "\(StockWays.title($0.name)) ≈ \(unit($0.out))" }.joined(separator: " · ")
    }

    /// The v4 pool for tokenIn → tokenOut and what it gives for `amountIn`; nil when there's none without hooks.
    func v4Route(_ tokenIn: String, _ tokenOut: String, amountIn: Decimal) async -> V4Route? {
        guard let key = await Self.v4Pool(tokenIn, tokenOut) else { return nil }
        let zeroForOne = tokenIn.lowercased() == key.currency0
        guard let out = await v4Quote(key, zeroForOne: zeroForOne, amount: amountIn), out > 0 else { return nil }
        return (key, zeroForOne, out)
    }

    /// V4Quoter on the chain itself.
    func v4Quote(_ key: UniswapV4.PoolKey, zeroForOne: Bool, amount: Decimal) async -> Decimal? {
        guard let call = try? UniswapV4.quoteExactInputSingle(key, zeroForOne: zeroForOne, amount: amount),
              let answer = try? await EVMRPC.robinhood.read(UniswapV4.robinhoodQuoter, call) else { return nil }
        return ABI.decimal(in: answer, word: 0)
    }

    /// The pair's v4 pools from DexScreener (a v4 pair's address is its pool id), the deepest first; the first whose key
    /// the PoolManager's Initialize event gives, hashes back to that id and has no hooks.
    static func v4Pool(_ a: String, _ b: String) async -> UniswapV4.PoolKey? {
        let pair = Set([a.lowercased(), b.lowercased()])
        let token = a.lowercased() == EVMRPC.robinhoodUSDG ? b : a
        guard let url = URL(string: "https://api.dexscreener.com/tokens/v1/robinhood/\(token)"),
              let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15)),
              let pairs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        func side(_ p: [String: Any], _ k: String) -> String? { ((p[k] as? [String: Any])?["address"] as? String)?.lowercased() }
        func depth(_ p: [String: Any]) -> Double { ((p["liquidity"] as? [String: Any])?["usd"] as? NSNumber)?.doubleValue ?? 0 }
        let ids = pairs.filter { p in
            p["dexId"] as? String == "uniswap" && (p["labels"] as? [String])?.contains("v4") == true
                && Set([side(p, "baseToken"), side(p, "quoteToken")].compactMap { $0 }) == pair
        }
        .sorted { depth($0) > depth($1) }.compactMap { ($0["pairAddress"] as? String)?.lowercased() }
        for id in ids.prefix(3) {
            if let key = await v4Key(id), key.id == id, !key.hasHooks { return key }
        }
        return nil
    }

    /// A v4 pool's key from the PoolManager's Initialize event (Robinhood Chain's Blockscout, which reads the whole history;
    /// the chain's node allows 10 million blocks a query).
    static func v4Key(_ id: String) async -> UniswapV4.PoolKey? {
        var url = URLComponents(string: "https://robinhoodchain.blockscout.com/api")
        url?.queryItems = [("module", "logs"), ("action", "getLogs"), ("fromBlock", "0"), ("toBlock", "latest"),
                           ("address", UniswapV4.robinhoodPoolManager), ("topic0", UniswapV4.initializeTopic), ("topic1", id),
                           ("topic0_1_opr", "and")].map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let link = url?.url else { return nil }
        var request = URLRequest(url: link, timeoutInterval: 20)
        // Blockscout turns away clients that don't look like a browser.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let log = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let topics = log["topics"] as? [String], topics.count == 4, let hex = log["data"] as? String,
              let words = Data(hex: String(hex.dropFirst(2))), words.count >= 96,
              let c0 = Data(hex: String(topics[2].dropFirst(2))).flatMap({ ABI.address(in: $0, word: 0) }),
              let c1 = Data(hex: String(topics[3].dropFirst(2))).flatMap({ ABI.address(in: $0, word: 0) }),
              let fee = ABI.uint(in: words, word: 0), fee < 1 << 24, let hooks = ABI.address(in: words, word: 2) else { return nil }
        let spacing = Int32(truncatingIfNeeded: words.subdata(in: 56..<64).reduce(Int64(0)) { $0 << 8 | Int64($1) })
        return UniswapV4.PoolKey(currency0: c0, currency1: c1, fee: UInt32(fee), tickSpacing: spacing, hooks: hooks)
    }

    /// The swap itself; returns its transaction. `rpc`: Robinhood Chain's node, or a fork of it in a test.
    func v4Swap(_ route: V4Route, tokenIn: String, units: Decimal, minOut: Decimal, what: String, note: String,
                rpc: EVMRPC = .robinhood) async throws -> String {
        let me = wallet.evm, router = UniswapV4.robinhoodRouter
        // Permit2's own allowance for the router: exactly this much, for half an hour, unless one that covers it is still on.
        func allowed() async throws -> (amount: Decimal, until: UInt64) {
            let answer = try await rpc.read(UniswapV4.permit2, try UniswapV4.permit2Allowance(owner: me, token: tokenIn, spender: router))
            return (ABI.decimal(in: answer, word: 0) ?? 0, ABI.uint(in: answer, word: 1) ?? 0)
        }
        let now = UInt64(Date().timeIntervalSince1970)
        let swap = try UniswapV4.execute(route.key, zeroForOne: route.zeroForOne, amountIn: units, amountOutMinimum: minOut, deadline: now + 600)
        // The three as one transaction where it batches: the approve to Permit2, Permit2's to the router, the swap.
        if canBatch(rpc) {
            var calls: [Batch7702.Call] = []
            let toPermit2 = ABI.decimal(in: try await rpc.read(tokenIn, try ERC20.allowance(owner: me, spender: UniswapV4.permit2)), word: 0) ?? 0
            if toPermit2 < units { calls.append(.init(to: tokenIn, data: try ERC20.approve(spender: UniswapV4.permit2, units: units))) }
            let current = try await allowed()
            if current.amount < units || current.until < now + 120 {
                calls.append(.init(to: UniswapV4.permit2, data: try UniswapV4.permit2Approve(token: tokenIn, spender: router, amount: units, expiration: now + 1800)))
            }
            guard calls.isEmpty else { return try await sendEVM(rpc, to: me, data: Data(), note: note, batch: calls + [.init(to: router, data: swap)]) }
            return try await sendEVM(rpc, to: router, data: swap, note: note)
        }
        try await approve(rpc, token: tokenIn, spender: UniswapV4.permit2, units: units, note: "Approve exactly \(what) to Permit2")
        let current = try await allowed()
        if current.amount < units || current.until < now + 120 {
            _ = try await sendEVM(rpc, to: UniswapV4.permit2,
                                  data: try UniswapV4.permit2Approve(token: tokenIn, spender: router, amount: units, expiration: now + 1800),
                                  note: "Permit2: let Uniswap's router take exactly \(what), for 30 minutes")
            var seen = false
            for _ in 0..<15 where !seen {
                let a = try await allowed()
                seen = a.amount >= units && a.until >= now + 120
                if !seen { try await Task.sleep(for: .seconds(1)) }
            }
            guard seen else { throw ExecutionError("Permit2's approval went through but the network doesn't show it yet. Try again in a minute; nothing was swapped.") }
        }
        return try await sendEVM(rpc, to: router, data: swap, note: note)
    }
}
