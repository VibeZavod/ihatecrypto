import EVMChain
import ExecutionCore
import Foundation
import IhatecryptoCore
import RelayBridge
import TxGuard
import WalletCore

/// Tokens on Base and Arbitrum by ticker: Uniswap's default token list (tokens.uniswap.org), the curated list its own
/// app offers. A ticker outside it is bought by its contract.
public enum EVMTokens {
    public struct Token: Sendable, Equatable {
        public let symbol: String
        public let name: String
        public let address: String
        public let decimals: Int
    }

    public static func find(_ symbol: String, chainId: UInt64) async throws -> Token? {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://tokens.uniswap.org")!)
        return find(data, symbol: symbol, chainId: chainId)
    }

    static func find(_ data: Data, symbol: String, chainId: UInt64) -> Token? {
        let tokens = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tokens"] as? [[String: Any]]) ?? []
        let want = symbol.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "$"))
        guard let t = tokens.first(where: { ($0["chainId"] as? NSNumber)?.uint64Value == chainId && ($0["symbol"] as? String)?.uppercased() == want }),
              let address = t["address"] as? String, let decimals = (t["decimals"] as? NSNumber)?.intValue else { return nil }
        return Token(symbol: t["symbol"] as? String ?? symbol, name: t["name"] as? String ?? symbol, address: address.lowercased(), decimals: decimals)
    }
}

/// Buying and selling tokens on Base and Arbitrum with the money on Solana. Two ways each time, and the one that
/// leaves more is taken: Relay swaps on the way in one step, or Relay bridges USDC and Uniswap swaps on the chain
/// (its gas, and a gas top-up when there's none, counted against it).
extension Executor {
    /// One way to do the trade: what comes out in the target's smallest units, and what it's worth after its gas, in USD.
    struct SwapWay {
        let name: String
        let out: Decimal
        let worth: Decimal
        let line: String
    }

    /// A ticker from Uniswap's list, or a contract that trades on the chain with $50k+ of liquidity; decimals are read
    /// from the contract itself.
    func evmToken(_ ref: String, on net: EVMNetwork) async throws -> EVMTokens.Token {
        let rpc = net.rpc
        if !ref.hasPrefix("0x") {
            guard let t = try await EVMTokens.find(ref, chainId: rpc.chainId) else {
                throw ExecutionError("\(ref.uppercased()) isn't on Uniswap's token list for \(net.name). To buy it anyway, name it by its contract: “buy token 0x… on \(net.key) for 5 USDC”.")
            }
            guard ABI.uint(in: try await rpc.read(t.address, Data([0x31, 0x3c, 0xe5, 0x67])), word: 0) == UInt64(t.decimals) else {
                throw ExecutionError("The \(t.symbol) contract on \(net.name) doesn't match Uniswap's list. Nothing was signed.")
            }
            return t
        }
        guard let info = try await TokenLookup.lookup(ref).first(where: { $0.chain == net.key }) else {
            throw ExecutionError("This contract doesn't trade on \(net.name).")
        }
        guard let liquidity = info.liquidityUSD, liquidity >= 50_000 else {
            throw ExecutionError("\(info.symbol) has only \(Fmt.usd(info.liquidityUSD ?? 0)) of liquidity on \(net.name): too thin to trade safely.")
        }
        guard let decimals = ABI.uint(in: try await rpc.read(ref, Data([0x31, 0x3c, 0xe5, 0x67])), word: 0), decimals <= 36 else {
            throw ExecutionError("The contract doesn't answer decimals(): not a token ihatecrypto can trade.")
        }
        let symbol = ABI.string(try await rpc.read(ref, Data([0x95, 0xd8, 0x9b, 0x41]))) ?? info.symbol
        return EVMTokens.Token(symbol: symbol, name: info.name, address: ref.lowercased(), decimals: Int(decimals))
    }

    /// The Uniswap v3 route with the most output: one pool, or two through WETH.
    func bestPath(on rpc: EVMRPC, _ uni: UniswapV3.Deployment, from a: String, to b: String, amountIn: Decimal) async -> (path: Data, out: Decimal, hops: Int)? {
        var routes = UniswapV3.fees.map { ([a, b], [$0]) }
        if a.lowercased() != uni.weth, b.lowercased() != uni.weth {
            for f1: UInt64 in [500, 3000, 10000] { for f2: UInt64 in [500, 3000, 10000] { routes.append(([a, uni.weth, b], [f1, f2])) } }
        }
        return await withTaskGroup(of: (Data, Decimal, Int)?.self) { group in
            for (tokens, fees) in routes {
                group.addTask {
                    guard let path = try? UniswapV3.path(tokens, fees: fees),
                          let answer = try? await rpc.read(uni.quoter, try UniswapV3.quoteExactInput(path: path, amountIn: amountIn)),
                          let out = ABI.decimal(in: answer, word: 0), out > 0 else { return nil }
                    return (path, out, fees.count)
                }
            }
            var best: (path: Data, out: Decimal, hops: Int)?
            for await r in group { if let r, r.1 > (best?.out ?? 0) { best = (r.0, r.1, r.2) } }
            return best
        }
    }

    /// What `gas` units cost on the chain now, in USD (ETH priced through Uniswap's WETH/USDC pool).
    func gasUSD(_ gas: UInt64, on net: EVMNetwork, _ uni: UniswapV3.Deployment) async throws -> Decimal {
        let price = try await net.rpc.quantity("eth_gasPrice", [])
        // 0.001 ETH → USDC, times a thousand: the price of one ETH.
        let milli = Decimal(1_000_000_000_000_000)
        let usdc = await bestPath(on: net.rpc, uni, from: uni.weth, to: net.usdc, amountIn: milli)?.out ?? 0
        let ethUSD = usdc / 1_000_000 * 1000
        return Decimal(gas) * Decimal(price) / 1_000_000_000_000_000_000 * ethUSD
    }

    /// Which ways Settings › Modules allows: Relay's swap needs Relay; the other needs Relay and Uniswap.
    private func allowedWays(_ net: EVMNetwork) -> (relay: Bool, uniswap: Bool) {
        let place = ModuleNetwork(place: net.key).map { [$0] } ?? []
        let relay = Modules.current.refusal(.relay, via: place) == nil
        return (relay, relay && Modules.current.refusal(.uniswap, via: place) == nil)
    }

    /// The way a trade takes: the one that leaves more, or only the one the person picked on the route's step
    /// ("relay" = Relay's swap, "uniswap" = Relay's bridge + Uniswap). A pick only narrows the two quoted ways.
    static func pick(_ ways: [SwapWay], prefer: String?) -> SwapWay? {
        (prefer.map { p in ways.filter { $0.name == p } } ?? ways).max(by: { $0.worth < $1.worth })
    }

    /// What the refusal says when the picked way has no quote: the other one is still there to choose.
    private static func unquoted(_ prefer: String?, _ what: String) -> String? {
        prefer.map { "\($0 == "relay" ? "Relay's swap" : "Relay + Uniswap") doesn't quote \(what) right now. Nothing was signed; pick «The best one» on the route's step to take the other way." }
    }

    /// Both ways of a buy (`usdc`) or a sale (`sell`, nil = all) quoted now for the route's card, the one that leaves
    /// more first; nothing is signed. `gets` is what arrives («2.41 AERO», «1.97 USDC»), `worth` its USD after gas.
    /// "here" is the one way when the trade runs on the network's own USDC (`buyHere`, or a sale that keeps the USDC).
    public func swapQuotes(_ net: EVMNetwork, _ ref: String, usdc: Decimal?, sell: Decimal?, from: String? = nil, keep: Bool = false) async throws
        -> [(way: String, gets: String, worth: Decimal)] {
        guard let uni = UniswapV3.on(net.rpc.chainId) else { return [] }
        let token = try await evmToken(ref, on: net)
        let scale = Decimal(sign: .plus, exponent: token.decimals, significand: 1)
        if let usdc {
            let units = NSDecimalNumber(decimal: (usdc * 1_000_000).rounded(0, .down)).uint64Value
            if let here = try await buyHere(net, token, units: units, from: from, uni) {
                return [("here", "\(Fmt.num(here.out / scale, maxFraction: 6)) \(token.symbol)", usdc)]
            }
            return try await buyWays(net, token, units: units, uni).ways.sorted { $0.worth > $1.worth }
                .map { ($0.name, "\(Fmt.num($0.out / scale, maxFraction: 6)) \(token.symbol)", $0.worth) }
        }
        let held = try await balance(token.address, on: net.rpc)
        let units = (sell.map { min($0 * scale, held) } ?? held).whole
        guard units > 0 else { return [] }
        if keep {
            guard let best = await bestPath(on: net.rpc, uni, from: token.address, to: net.usdc, amountIn: units) else { return [] }
            return [("here", "\(Fmt.num(best.out / 1_000_000)) USDC", best.out / 1_000_000)]
        }
        return try await sellWays(net, token, units: units, uni).ways.sorted { $0.worth > $1.worth }
            .map { ($0.name, "\(Fmt.num($0.out / 1_000_000)) USDC", $0.worth) }
    }

    /// Buys a token on an EVM network for `usdc`: with the USDC already there when it holds enough (or `from` names it),
    /// with another EVM network's USDC brought over first (`from`), else from Solana, the better of the two ways (or the
    /// one picked on the route's step).
    public func buyOn(_ net: EVMNetwork, _ ref: String, usdc: Decimal, prefer: String? = nil, from: String? = nil) async throws -> String {
        guard let uni = UniswapV3.on(net.rpc.chainId) else { throw ExecutionError("ihatecrypto swaps on Solana, Base, Arbitrum, Polygon and Ethereum.") }
        let token = try await evmToken(ref, on: net), me = wallet.evm
        let units = NSDecimalNumber(decimal: (usdc * 1_000_000).rounded(0, .down)).uint64Value
        guard units >= 500_000 else { throw ExecutionError("At least 0.5 USDC: less isn't worth the bridge.") }
        let scale = Decimal(sign: .plus, exponent: token.decimals, significand: 1)
        func amount(_ raw: Decimal) -> String { "\(Fmt.num(raw / scale, maxFraction: 6)) \(token.symbol)" }
        // A way picked on the route's step is one of Solana's: only then is the money on the network passed over.
        if prefer == nil || from != nil, let here = try await buyHere(net, token, units: units, from: from, uni) {
            var spend = units
            if let src = here.src {
                let before = try await net.rpc.tokenBalance(net.usdc, owner: me)
                report(try await bridge(src, to: net, usdc: usdc))
                // What arrived pays: Relay's fee comes out of it.
                let now = try await net.rpc.tokenBalance(net.usdc, owner: me)
                spend = min(units, now > before ? now - before : 0)
            }
            return try await buyThere(net, token, units: spend, uni)
        }
        let (ways, uniswap) = try await buyWays(net, token, units: units, uni)
        guard let way = Self.pick(ways, prefer: prefer) else {
            throw ExecutionError(Self.unquoted(prefer, "\(token.symbol) on \(net.name)")
                ?? "Neither Relay nor Uniswap quotes \(token.symbol) on \(net.name) for \(Fmt.num(usdc)) USDC right now. Nothing was signed.")
        }
        report("\(Fmt.num(usdc)) USDC → \(token.symbol) on \(net.name). " + ways.map(\.line).joined(separator: "; ") + ". Taking \(way.name == "relay" ? "Relay's swap" : "the bridge and Uniswap")\(prefer == nil ? "" : ", as picked").")

        let before = try await balance(token.address, on: net.rpc)
        var hash = ""
        if way.name == "relay" {
            let (step, changes) = try await prepareBridge(.send(usdc), to: net.relayChain, currency: token.address, decimals: token.decimals, swap: true)
            report(changes.joined(separator: " "))
            try await sendBridge(step)
        } else if let plan = uniswap {
            let there = try await net.rpc.tokenBalance(net.usdc, owner: me)
            try await ensureEVM(net, usdc: there + plan.arrive)
            // Quote again with the money there: the price may have moved while the bridge ran.
            guard let fresh = await bestPath(on: net.rpc, uni, from: net.usdc, to: token.address, amountIn: Decimal(plan.arrive)) else {
                throw ExecutionError("Uniswap no longer quotes \(token.symbol); the USDC waits on \(net.name).")
            }
            try await approve(net.rpc, token: net.usdc, spender: uni.router, amount: plan.arrive,
                              note: "Approve exactly \(Fmt.num(Decimal(plan.arrive) / 1_000_000)) USDC to Uniswap")
            hash = try await sendEVM(net.rpc, to: uni.router,
                                     data: try UniswapV3.exactInput(path: fresh.path, recipient: me, amountIn: Decimal(plan.arrive), amountOutMinimum: (fresh.out * Decimal(string: "0.99")!).whole),
                                     note: "Buy \(token.symbol) for \(Fmt.num(Decimal(plan.arrive) / 1_000_000)) USDC on Uniswap")
        }
        var after = try await balance(token.address, on: net.rpc)
        let started = Date()
        while after <= before, Date().timeIntervalSince(started) < 240 {
            try await Task.sleep(for: .seconds(2))
            after = try await balance(token.address, on: net.rpc)
        }
        guard after > before else { throw ExecutionError("\(token.symbol) didn't arrive on \(net.name) within 4 minutes. The order is in the journal.") }
        traded?("\(net.key):\(token.address.lowercased())", (after - before) / scale, usdc)
        return "Bought \(amount(after - before)) on \(net.name) for \(Fmt.num(usdc)) USDC via \(way.name == "relay" ? "Relay's swap" : "Relay + Uniswap"). "
            + "You hold \(amount(after)) there.\(hash.isEmpty ? "" : " \(net.explorer)/tx/\(hash)")"
    }

    /// Whether a buy is paid on the network itself, and Uniswap's path there: `from` nil = when the network holds the
    /// USDC and Uniswap has a pool (else nil: Solana's ways); «solana» = never; the network's key = it must; another EVM
    /// network's key = its USDC comes over first (`src`). A named place that can't pay is refused, never swapped for another.
    func buyHere(_ net: EVMNetwork, _ token: EVMTokens.Token, units: UInt64, from: String?, _ uni: UniswapV3.Deployment) async throws
        -> (path: Data, out: Decimal, src: EVMNetwork?)? {
        guard from != "solana" else { return nil }
        let me = wallet.evm, want = Fmt.num(Decimal(units) / 1_000_000)
        let src = from.flatMap(EVMNetwork.named).flatMap { $0.key == net.key ? nil : $0 }
        if from != nil, from != net.key, src == nil { throw ExecutionError("ihatecrypto doesn't pay for a buy on \(net.name) from \(from ?? "there"). Nothing was signed.") }
        let there = try await (src ?? net).rpc.tokenBalance((src ?? net).usdc, owner: me)
        let best = allowedWays(net).uniswap ? await bestPath(on: net.rpc, uni, from: net.usdc, to: token.address, amountIn: Decimal(units)) : nil
        if let best, there >= units { return (best.path, best.out, src) }
        guard from != nil else { return nil }
        throw ExecutionError(there < units
            ? "\(Fmt.num(Decimal(there) / 1_000_000)) USDC on \((src ?? net).name); the buy needs \(want). Nothing was signed."
            : "Uniswap has no pool for \(token.symbol) on \(net.name)\(allowedWays(net).uniswap ? "" : " (Uniswap is off in Settings › Modules)"); "
                + "“buy \(token.symbol) on \(net.key) for \(want) USDC from solana” takes Relay's swap. Nothing was signed.")
    }

    /// A buy with USDC already on the network: an exact approve and Uniswap's best path, which pays only this wallet.
    private func buyThere(_ net: EVMNetwork, _ token: EVMTokens.Token, units: UInt64, _ uni: UniswapV3.Deployment) async throws -> String {
        let me = wallet.evm, scale = Decimal(sign: .plus, exponent: token.decimals, significand: 1), usdc = Fmt.num(Decimal(units) / 1_000_000, maxFraction: 6)
        func amount(_ raw: Decimal) -> String { "\(Fmt.num(raw / scale, maxFraction: 6)) \(token.symbol)" }
        // Gas only: the USDC is there.
        try await ensureEVM(net, usdc: units)
        guard units > 0, let best = await bestPath(on: net.rpc, uni, from: net.usdc, to: token.address, amountIn: Decimal(units)) else {
            throw ExecutionError("Uniswap doesn't quote \(token.symbol) on \(net.name) now; the USDC stays there. Nothing was swapped.")
        }
        report("\(usdc) USDC on \(net.name) → \(token.symbol) on Uniswap: ≈ \(amount(best.out)), no bridge.")
        let before = try await balance(token.address, on: net.rpc)
        try await approve(net.rpc, token: net.usdc, spender: uni.router, amount: units, note: "Approve exactly \(usdc) USDC to Uniswap")
        let hash = try await sendEVM(net.rpc, to: uni.router,
                                     data: try UniswapV3.exactInput(path: best.path, recipient: me, amountIn: Decimal(units), amountOutMinimum: (best.out * Decimal(string: "0.99")!).whole),
                                     note: "Buy \(token.symbol) for \(usdc) USDC on Uniswap")
        var after = try await balance(token.address, on: net.rpc)
        for _ in 0..<10 where after <= before {
            try await Task.sleep(for: .seconds(1))
            after = try await balance(token.address, on: net.rpc)
        }
        // ponytail: the USDC swapped here is the cost; a bridge that brought it first adds its few cents of fee nowhere.
        if after > before { traded?("\(net.key):\(token.address.lowercased())", (after - before) / scale, Decimal(units) / 1_000_000) }
        return "Bought \(amount(after > before ? after - before : 0)) on \(net.name) for \(usdc) USDC that was there, on Uniswap. You hold \(amount(after)) there. \(net.explorer)/tx/\(hash)"
    }

    /// Both ways to buy for `units` of USDC from Solana, quoted and valued (nothing is signed): Relay's swap, and Relay's
    /// bridge (with a gas top-up when there's no ETH) followed by Uniswap's best path, its gas counted against it.
    func buyWays(_ net: EVMNetwork, _ token: EVMTokens.Token, units: UInt64, _ uni: UniswapV3.Deployment) async throws
        -> (ways: [SwapWay], uniswap: (arrive: UInt64, topup: Bool)?) {
        let me = wallet.evm, scale = Decimal(sign: .plus, exponent: token.decimals, significand: 1)
        let allowed = allowedWays(net)
        guard allowed.relay else { throw ExecutionError(Modules.current.refusal(.relay) ?? "Relay is off in Settings › Modules.") }
        func amount(_ raw: Decimal) -> String { "\(Fmt.num(raw / scale, maxFraction: 6)) \(token.symbol)" }

        // Relay: Solana USDC in, the token out on the chain.
        let relay = try? await Relay.quote(user: wallet.solana, recipient: me, originChain: Relay.Chain.solana, destinationChain: net.relayChain,
                                           originCurrency: Relay.Currency.solanaUSDC, destinationCurrency: token.address, amount: units)
        let relayOut = relay.flatMap { Decimal(string: $0.amountOut) } ?? 0
        let relayWorth = relay.flatMap { Decimal(string: $0.amountOutUSD) } ?? 0
        // The token's price for comparing: Relay's own valuation, else the Uniswap route's.
        var price = relayOut > 0 ? relayWorth / (relayOut / scale) : 0
        var ways: [SwapWay] = []
        if relayOut > 0 { ways.append(SwapWay(name: "relay", out: relayOut, worth: relayWorth, line: "Relay swap: \(amount(relayOut)) ≈ \(Fmt.usd(relayWorth))")) }

        // Relay bridge + Uniswap: the USDC that arrives (a gas top-up rides along when there's no ETH), then the best pool path.
        var uniswap: (arrive: UInt64, topup: Bool)?
        if allowed.uniswap {
            let topup = try await net.rpc.balance(me) < net.gasFloor
            if let bridge = try? await Relay.quote(user: wallet.solana, recipient: me, originChain: Relay.Chain.solana, destinationChain: net.relayChain,
                                                   originCurrency: Relay.Currency.solanaUSDC, destinationCurrency: net.usdc, amount: units,
                                                   topupGasUSD: topup ? net.topupUSD : nil),
               let arrive = UInt64(bridge.amountOut), arrive > 0,
               let best = await bestPath(on: net.rpc, uni, from: net.usdc, to: token.address, amountIn: Decimal(arrive)) {
                if price == 0 { price = Decimal(arrive) / 1_000_000 / (best.out / scale) }
                let gas = try await gasUSD(50_000 + (best.hops == 1 ? 160_000 : 240_000), on: net, uni)
                let worth = best.out / scale * price - gas + (topup ? net.topupUSD : 0)
                ways.append(SwapWay(name: "uniswap", out: best.out, worth: worth,
                                    line: "Relay bridge + Uniswap: \(amount(best.out)) ≈ \(Fmt.usd(worth)) after \(Fmt.usd(gas)) of gas\(topup ? " (\(net.gasCoin) for gas rides along)" : "")"))
                uniswap = (arrive, topup)
            }
        }
        return (ways, uniswap)
    }

    /// Sells a token on an EVM network back to USDC on Solana; nil = all of it. The better of Relay's swap-and-bridge
    /// and Uniswap on the chain followed by the Relay bridge. `keep`: Uniswap there, and the USDC stays on the network.
    public func sellOn(_ net: EVMNetwork, _ ref: String, amount: Decimal?, prefer: String? = nil, keep: Bool = false) async throws -> String {
        guard let uni = UniswapV3.on(net.rpc.chainId) else { throw ExecutionError("ihatecrypto swaps on Solana, Base, Arbitrum, Polygon and Ethereum.") }
        let token = try await evmToken(ref, on: net), me = wallet.evm
        let scale = Decimal(sign: .plus, exponent: token.decimals, significand: 1)
        let held = try await balance(token.address, on: net.rpc)
        let units = (amount.map { min($0 * scale, held) } ?? held).whole
        guard units > 0 else { throw ExecutionError("No \(token.symbol) on \(net.name).") }
        func tokens(_ raw: Decimal) -> String { "\(Fmt.num(raw / scale, maxFraction: 6)) \(token.symbol)" }
        if keep {
            guard allowedWays(net).uniswap, let best = await bestPath(on: net.rpc, uni, from: token.address, to: net.usdc, amountIn: units) else {
                throw ExecutionError("Uniswap has no pool to sell \(token.symbol) for USDC on \(net.name)\(allowedWays(net).uniswap ? "" : " (Uniswap is off in Settings › Modules)"); "
                                     + "without «keep», Relay's swap sells it for USDC on Solana. Nothing was signed.")
            }
            report("\(tokens(units)) on \(net.name) → ≈ \(Fmt.num(best.out / 1_000_000)) USDC there, on Uniswap.")
            try await ensureEVM(net, usdc: 0)
            let sold = try await sellThere(net, token, units: units, path: best.path, out: best.out, uni)
            traded?("\(net.key):\(token.address.lowercased())", -units / scale, sold.got)
            return sold.text
        }
        let (ways, uniswap) = try await sellWays(net, token, units: units, uni)
        guard let way = Self.pick(ways, prefer: prefer) else {
            throw ExecutionError(Self.unquoted(prefer, tokens(units) + " on " + net.name)
                ?? "Neither Relay nor Uniswap quotes \(tokens(units)) on \(net.name) right now. Nothing was signed.")
        }
        report("\(tokens(units)) on \(net.name) → USDC on Solana. " + ways.map(\.line).joined(separator: "; ") + ". Taking \(way.name == "relay" ? "Relay's swap" : "Uniswap and the bridge")\(prefer == nil ? "" : ", as picked").")
        // Both ways sign on the chain: ETH for gas first (a top-up from Solana when there's none).
        try await ensureEVM(net, usdc: 0)

        guard way.name == "relay" else {
            guard let plan = uniswap else { throw ExecutionError("Uniswap's route went away. Nothing was signed.") }
            let fresh = await bestPath(on: net.rpc, uni, from: token.address, to: net.usdc, amountIn: units)
            let sold = try await sellThere(net, token, units: units, path: fresh?.path ?? plan.path, out: fresh?.out ?? plan.out, uni)
            report(sold.text)
            traded?("\(net.key):\(token.address.lowercased())", -units / scale, sold.got)
            return try await evmToSolana(net, usdc: sold.got)
        }
        let text = try await relaySell(net, token: token, units: units)
        traded?("\(net.key):\(token.address.lowercased())", -units / scale, 0)
        return text
    }

    /// The Uniswap sale on the network: an exact approve of the tokens, then the swap to USDC at this wallet.
    private func sellThere(_ net: EVMNetwork, _ token: EVMTokens.Token, units: Decimal, path: Data, out: Decimal, _ uni: UniswapV3.Deployment) async throws
        -> (got: Decimal, text: String) {
        let me = wallet.evm, scale = Decimal(sign: .plus, exponent: token.decimals, significand: 1)
        let tokens = "\(Fmt.num(units / scale, maxFraction: 6)) \(token.symbol)"
        try await approve(net.rpc, token: token.address, spender: uni.router, units: units, note: "Approve exactly \(tokens) to Uniswap")
        let before = try await net.rpc.tokenBalance(net.usdc, owner: me)
        let hash = try await sendEVM(net.rpc, to: uni.router,
                                     data: try UniswapV3.exactInput(path: path, recipient: me, amountIn: units, amountOutMinimum: (out * Decimal(string: "0.99")!).whole),
                                     note: "Sell \(tokens) on Uniswap")
        var after = try await net.rpc.tokenBalance(net.usdc, owner: me)
        for _ in 0..<10 where after <= before {
            try await Task.sleep(for: .seconds(1))
            after = try await net.rpc.tokenBalance(net.usdc, owner: me)
        }
        let got = Decimal(after > before ? after - before : 0) / 1_000_000
        return (got, "Sold \(tokens) for \(Fmt.num(got)) USDC on \(net.name). \(net.explorer)/tx/\(hash)")
    }

    /// Both ways to sell `units` back to USDC on Solana, quoted and valued (nothing is signed): Relay's swap-and-bridge,
    /// and Uniswap's best path to USDC on the chain followed by Relay's bridge; each one's gas counted against it.
    func sellWays(_ net: EVMNetwork, _ token: EVMTokens.Token, units: Decimal, _ uni: UniswapV3.Deployment) async throws
        -> (ways: [SwapWay], uniswap: (path: Data, out: Decimal)?) {
        let me = wallet.evm
        let allowed = allowedWays(net)
        guard allowed.relay else { throw ExecutionError(Modules.current.refusal(.relay) ?? "Relay is off in Settings › Modules.") }
        var ways: [SwapWay] = []
        let relay = try? await Relay.quote(user: me, recipient: wallet.solana, originChain: net.relayChain, destinationChain: Relay.Chain.solana,
                                           originCurrency: token.address, destinationCurrency: Relay.Currency.solanaUSDC, amount: 0, units: "\(units)")
        if let relay, let out = Decimal(string: relay.amountOut), out > 0 {
            let gas = try await gasUSD(50_000 + 300_000, on: net, uni)
            ways.append(SwapWay(name: "relay", out: out, worth: out / 1_000_000 - gas,
                                line: "Relay swap: \(Fmt.num(out / 1_000_000)) USDC on Solana after \(Fmt.usd(gas)) of gas"))
        }
        var uniswap: (path: Data, out: Decimal)?
        if allowed.uniswap, let best = await bestPath(on: net.rpc, uni, from: token.address, to: net.usdc, amountIn: units),
           let bridge = try? await Relay.quote(user: me, recipient: wallet.solana, originChain: net.relayChain, destinationChain: Relay.Chain.solana,
                                               originCurrency: net.usdc, destinationCurrency: Relay.Currency.solanaUSDC, amount: 0, units: "\(best.out.whole)"),
           let out = Decimal(string: bridge.amountOut), out > 0 {
            let gas = try await gasUSD(100_000 + (best.hops == 1 ? 160_000 : 240_000) + 120_000, on: net, uni)
            ways.append(SwapWay(name: "uniswap", out: out, worth: out / 1_000_000 - gas,
                                line: "Uniswap + Relay bridge: \(Fmt.num(out / 1_000_000)) USDC on Solana after \(Fmt.usd(gas)) of gas"))
            uniswap = (best.path, best.out)
        }
        return (ways, uniswap)
    }

    /// Relay's own swap-and-bridge from a token on the chain: an exact approve to the approval proxy Relay publishes for
    /// that chain, then its call, which must go to that same proxy. The quote must be from this wallet to our Solana address.
    private func relaySell(_ net: EVMNetwork, token: EVMTokens.Token, units: Decimal) async throws -> String {
        let me = wallet.evm, scale = Decimal(sign: .plus, exponent: token.decimals, significand: 1)
        let quote = try await Relay.quote(user: me, recipient: wallet.solana, originChain: net.relayChain, destinationChain: Relay.Chain.solana,
                                          originCurrency: token.address, destinationCurrency: Relay.Currency.solanaUSDC, amount: 0, units: "\(units)")
        let binding = BindingGuard.check(["sender": quote.sender, "recipient": quote.recipient],
                                         expected: ["sender": me, "recipient": wallet.solana], subject: "Relay quote")
        guard binding.ok else { throw ExecutionError(binding.problems.joined(separator: " ")) }
        guard let proxy = try await Relay.approvalProxy(chainId: net.relayChain)?.lowercased(),
              let call = quote.evm.last, call.to.lowercased() == proxy, call.chainId == net.relayChain, call.value == "0" || call.value == "<null>",
              quote.evm.dropLast().allSatisfy({ $0.to.lowercased() == token.address && $0.data.prefix(4).hex == "095ea7b3"
                  && ABI.address(in: Data($0.data.dropFirst(4)), word: 0)?.lowercased() == proxy && ABI.decimal(in: Data($0.data.dropFirst(4)), word: 1) == units }) else {
            throw ExecutionError("Relay's transactions don't go to the approval proxy it publishes for \(net.name), for exactly this amount. Nothing was signed.")
        }
        let arriving = (Decimal(string: quote.amountOut) ?? 0) / 1_000_000
        let worthIn = Decimal(string: quote.amountInUSD) ?? 0
        guard arriving > 0, worthIn - arriving <= max(worthIn * Decimal(string: "0.03")!, Decimal(string: "0.15")!) else {
            throw ExecutionError("Relay gives \(Fmt.num(arriving)) USDC for \(Fmt.usd(worthIn)) of \(token.symbol): more lost than allowed. Nothing was signed.")
        }
        let mint = Relay.Currency.solanaUSDC
        let solBefore = try await rpc.tokenBalance(owner: wallet.solana, mint: mint)
        try await approve(net.rpc, token: token.address, spender: proxy, units: units, note: "Approve exactly \(Fmt.num(units / scale, maxFraction: 6)) \(token.symbol) to Relay")
        let hash = try await sendEVM(net.rpc, to: call.to, data: call.data, note: "Relay: sell \(Fmt.num(units / scale, maxFraction: 6)) \(token.symbol) on \(net.name)")
        try journal.append(.init(chain: "relay", id: quote.requestId, kind: .signed, note: "\(net.name) \(token.symbol)→Solana USDC, tx \(hash)"))
        let started = Date()
        let target = solBefore + NSDecimalNumber(decimal: arriving * 990_000).uint64Value
        while Date().timeIntervalSince(started) < 240 {
            let status = try await Relay.status(requestId: quote.requestId).status
            if ["refund", "failure"].contains(status) {
                try journal.append(.init(chain: "relay", id: quote.requestId, kind: .failed, note: status))
                throw ExecutionError("Relay returned \(status). Check \(token.symbol) on \(net.name). \(net.explorer)/tx/\(hash)")
            }
            let now = try await rpc.tokenBalance(owner: wallet.solana, mint: mint)
            if now >= target {
                try journal.append(.init(chain: "relay", id: quote.requestId, kind: .settled, note: status))
                return "Sold \(Fmt.num(units / scale, maxFraction: 6)) \(token.symbol) on \(net.name) via Relay: \(Fmt.num(Decimal(now - solBefore) / 1_000_000)) USDC arrived on Solana in \(Int(Date().timeIntervalSince(started))) s. \(net.explorer)/tx/\(hash)"
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw ExecutionError("Relay didn't credit Solana within 4 minutes. Order \(quote.requestId) is in the journal. \(net.explorer)/tx/\(hash)")
    }
}
