import EVMChain
import ExecutionCore
import Foundation
import LalaCore
import RelayBridge
import TxGuard
import WalletCore

/// Robinhood Stock Tokens on Robinhood Chain: the registry says which contract is the real one; the chain confirms it.
public enum RobinhoodStocks {
    public struct Token: Sendable, Equatable {
        public let symbol: String
        public let name: String
        public let address: String
        public let decimals: Int
        public let logo: URL?
    }

    /// Robinhood's own asset registry (api.robinhood.com/rhj/assets, documented at docs.robinhood.com/chain):
    /// active tokens deployed on chain 4663.
    public static func registry() async throws -> [Token] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://api.robinhood.com/rhj/assets")!)
        return parse(data)
    }

    public static func parse(_ data: Data) -> [Token] {
        guard let assets = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["assets"] as? [[String: Any]] else { return [] }
        return assets.compactMap { a in
            guard a["status"] as? String == "ASSET_STATUS_ACTIVE", let symbol = a["tokenSymbol"] as? String,
                  let d = (a["deployments"] as? [[String: Any]])?.first(where: { ($0["chainId"] as? NSNumber)?.intValue == 4663 }),
                  let address = d["contractAddress"] as? String else { return nil }
            return Token(symbol: symbol, name: (a["tokenName"] as? String ?? symbol).replacingOccurrences(of: " • Robinhood Token", with: ""),
                         address: address, decimals: (a["tokenDecimals"] as? NSNumber)?.intValue ?? 18, logo: (a["logoUrl"] as? String).flatMap(URL.init))
        }
    }

    /// Robinhood's own bid and ask for the token (api.robinhood.com/rhj/prices/{symbol}).
    public static func quote(_ symbol: String) async throws -> (bid: Decimal, ask: Decimal)? {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://api.robinhood.com/rhj/prices/\(symbol)")!)
        guard let q = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["quotes"] as? [[String: Any]])?.first,
              let bid = (q["bid"] as? String).flatMap({ Decimal(string: $0) }), let ask = (q["ask"] as? String).flatMap({ Decimal(string: $0) }) else { return nil }
        return (bid, ask)
    }

    /// The registry's token, confirmed on-chain: same symbol and decimals at that address.
    public static func verified(_ symbol: String, rpc: EVMRPC = .robinhood) async throws -> Token {
        guard let token = try await registry().first(where: { $0.symbol.uppercased() == symbol.uppercased() }) else {
            throw ExecutionError("\(symbol) isn't an active Robinhood Stock Token.")
        }
        let onChainSymbol = ABI.string(try await rpc.read(token.address, Data([0x95, 0xd8, 0x9b, 0x41])))
        let onChainDecimals = ABI.uint(in: try await rpc.read(token.address, Data([0x31, 0x3c, 0xe5, 0x67])), word: 0)
        guard onChainSymbol == token.symbol, onChainDecimals == UInt64(token.decimals) else {
            throw ExecutionError("The \(symbol) contract on Robinhood Chain doesn't match Robinhood's registry. Nothing was signed.")
        }
        return token
    }

    /// A registry symbol, or any token by its contract («купи 0x… на $2»): it must trade on Robinhood Chain with at
    /// least $50k of liquidity (DexScreener), and its symbol and decimals are read from the contract itself.
    public static func resolve(_ symbolOrContract: String, rpc: EVMRPC = .robinhood) async throws -> (token: Token, listing: TokenLookup.Info?) {
        guard symbolOrContract.hasPrefix("0x") else { return (try await verified(symbolOrContract, rpc: rpc), nil) }
        let address = symbolOrContract
        guard let info = try await TokenLookup.lookup(address).first(where: { $0.chain == "robinhood" }) else {
            throw ExecutionError("This contract doesn't trade on Robinhood Chain, and by contract ihatecrypto buys only there for now.")
        }
        guard let liquidity = info.liquidityUSD, liquidity >= 50_000 else {
            throw ExecutionError("\(info.symbol) has only \(Fmt.usd(info.liquidityUSD ?? 0)) of liquidity: too thin to trade safely.")
        }
        guard let decimals = ABI.uint(in: try await rpc.read(address, Data([0x31, 0x3c, 0xe5, 0x67])), word: 0), decimals <= 36 else {
            throw ExecutionError("The contract doesn't answer decimals(): not a token ihatecrypto can trade.")
        }
        let symbol = ABI.string(try await rpc.read(address, Data([0x95, 0xd8, 0x9b, 0x41]))) ?? info.symbol
        let name = ABI.string(try await rpc.read(address, Data([0x06, 0xfd, 0xde, 0x03]))) ?? info.name
        return (Token(symbol: symbol, name: name, address: address, decimals: Int(decimals), logo: info.imageURL), info)
    }
}

extension Executor {
    func balance(_ token: String, on rpc: EVMRPC) async throws -> Decimal {
        ABI.decimal(in: try await rpc.read(token, try ERC20.balanceOf(wallet.evm)), word: 0) ?? 0
    }

    /// The Uniswap v3 pool with the most output for this trade, and that output.
    /// Amounts in the tokens' smallest units, as 256-bit words: 54 AI of 18 decimals is past 64 bits.
    func bestPool(_ tokenIn: String, _ tokenOut: String, amountIn: Decimal) async throws -> (fee: UInt64, out: Decimal)? {
        var best: (UInt64, Decimal)?
        for fee in UniswapV3.fees {
            guard let answer = try? await EVMRPC.robinhood.read(UniswapV3.robinhoodQuoter,
                    try UniswapV3.quoteExactInputSingle(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: fee)),
                  let out = ABI.decimal(in: answer, word: 0), out > (best?.1 ?? 0) else { continue }
            best = (fee, out)
        }
        return best.map { (fee: $0.0, out: $0.1) }
    }

    /// Buys a Stock Token (or any token by its contract) with USDC from Solana: Relay brings USDG (and gas) to
    /// Robinhood Chain, Uniswap swaps it. The price must sit within Robinhood's own bid–ask, or DexScreener's price for a
    /// contract (±5%); the swap pays only this wallet (the signer checks).
    public func buyStock(_ symbolOrContract: String, usdc: Decimal) async throws -> String {
        let rpc = EVMRPC.robinhood, usdg = EVMRPC.robinhoodUSDG, me = wallet.evm
        let (token, listing) = try await RobinhoodStocks.resolve(symbolOrContract)
        let symbol = token.symbol
        let units = NSDecimalNumber(decimal: (usdc * 1_000_000).rounded(0, .down)).uint64Value
        guard units >= 500_000 else { throw ExecutionError("At least 0.5 USDC: less isn't worth the bridge.") }
        guard let pool = try await bestPool(usdg, token.address, amountIn: Decimal(units)) else {
            // No Uniswap v3 pool (MOO trades only on v4, against another token): Relay's swap on the chain itself.
            guard let listing else { throw ExecutionError(noPool(symbol, listing)) }
            return try await relayBuy(token, units: units, listing: listing)
        }
        let scale = Decimal(sign: .plus, exponent: token.decimals, significand: 1)
        let price = (Decimal(units) / 1_000_000) / (pool.out / scale)
        var band = listing?.priceUSD.map { (bid: $0, ask: $0) }
        if listing == nil { band = try await RobinhoodStocks.quote(symbol) }
        if let q = band, price > q.ask * Decimal(string: "1.05")! || price < q.bid * Decimal(string: "0.95")! {
            throw ExecutionError("Uniswap's price \(Fmt.usd(price)) is outside \(listing == nil ? "Robinhood's own" : "DexScreener's") \(Fmt.usd(q.bid))–\(Fmt.usd(q.ask)). Nothing was signed.")
        }
        report("\(token.name) (\(symbol)): ≈ \(Fmt.usd(price)) a token on Uniswap (pool fee \(Fmt.num(Decimal(pool.fee) / 10_000))%).")
        try await ensureEVM(.robinhood, usdc: units)
        // Quote again with the money there: the price may have moved while the bridge ran.
        guard let fresh = try await bestPool(usdg, token.address, amountIn: Decimal(units)) else { throw ExecutionError(noPool(symbol, listing)) }
        let minimum = (fresh.out * 99 / 100).rounded(0, .down)
        try await approve(rpc, token: usdg, spender: UniswapV3.robinhoodRouter, amount: units, note: "Approve exactly \(Fmt.num(Decimal(units) / 1_000_000)) USDG to Uniswap")
        let before = try await balance(token.address, on: rpc)
        let hash = try await sendEVM(rpc, to: UniswapV3.robinhoodRouter,
                                     data: try UniswapV3.exactInputSingle(tokenIn: usdg, tokenOut: token.address, fee: fresh.fee, recipient: me,
                                                                          amountIn: Decimal(units), amountOutMinimum: minimum),
                                     note: "Buy \(symbol) for \(Fmt.num(Decimal(units) / 1_000_000)) USDG")
        var after = try await balance(token.address, on: rpc)
        for _ in 0..<10 where after <= before {
            try await Task.sleep(for: .seconds(1))
            after = try await balance(token.address, on: rpc)
        }
        let got = (after - before) / scale
        return "Bought \(Fmt.num(got, maxFraction: 6)) \(symbol) (\(token.name)) for \(Fmt.num(Decimal(units) / 1_000_000)) USDG — ≈ \(Fmt.usd(got > 0 ? (Decimal(units) / 1_000_000) / got : price)) a token. You hold \(Fmt.num(after / scale, maxFraction: 6)) \(symbol) on Robinhood Chain. \(EVMNetwork.robinhood.explorer)/tx/\(hash)"
    }

    /// A token Uniswap v3 doesn't pool with USDG, bought by Relay's swap on Robinhood Chain: an exact USDG approve to the
    /// approval proxy Relay publishes for the chain, then its call to that same proxy, from and to this wallet; the price
    /// within 5% of DexScreener's and at most 3% (or $0.15) lost on the way.
    private func relayBuy(_ token: RobinhoodStocks.Token, units: UInt64, listing: TokenLookup.Info) async throws -> String {
        let rpc = EVMRPC.robinhood, usdg = EVMRPC.robinhoodUSDG, me = wallet.evm, chain = Relay.Chain.robinhood
        let scale = Decimal(sign: .plus, exponent: token.decimals, significand: 1), spend = Decimal(units) / 1_000_000
        try await ensureEVM(.robinhood, usdc: units)
        let quote = try await Relay.quote(user: me, recipient: me, originChain: chain, destinationChain: chain,
                                          originCurrency: usdg, destinationCurrency: token.address, amount: units)
        let binding = BindingGuard.check(["sender": quote.sender.lowercased(), "recipient": quote.recipient.lowercased()],
                                         expected: ["sender": me.lowercased(), "recipient": me.lowercased()], subject: "Relay quote")
        guard binding.ok else { throw ExecutionError(binding.problems.joined(separator: " ")) }
        guard let proxy = try await Relay.approvalProxy(chainId: chain)?.lowercased(),
              let call = quote.evm.last, call.to.lowercased() == proxy, call.chainId == chain, call.value == "0" || call.value == "<null>",
              quote.evm.dropLast().allSatisfy({ exactApprove($0, token: usdg, spender: proxy, units: Decimal(units)) }) else {
            throw ExecutionError("Relay's transactions don't go to the approval proxy it publishes for Robinhood Chain, for exactly this amount. Nothing was signed.")
        }
        let out = (Decimal(string: quote.amountOut) ?? 0) / scale, worthOut = Decimal(string: quote.amountOutUSD) ?? 0
        guard out > 0, spend - worthOut <= max(spend * Decimal(string: "0.03")!, Decimal(string: "0.15")!) else {
            throw ExecutionError("Relay gives \(Fmt.usd(worthOut)) of \(token.symbol) for \(Fmt.num(spend)) USDG: more lost than allowed. Nothing was signed.")
        }
        let price = spend / out
        if let p = listing.priceUSD, price > p * Decimal(string: "1.05")! || price < p * Decimal(string: "0.95")! {
            throw ExecutionError("Relay's price \(Fmt.usd(price)) is off DexScreener's \(Fmt.usd(p)) by more than 5%. Nothing was signed.")
        }
        report("\(token.name) (\(token.symbol)): no Uniswap v3 pool with USDG, so Relay swaps it on Robinhood Chain: ≈ \(Fmt.usd(price)) a token.")
        try await approve(rpc, token: usdg, spender: proxy, amount: units, note: "Approve exactly \(Fmt.num(spend)) USDG to Relay")
        let before = try await balance(token.address, on: rpc)
        let hash = try await sendEVM(rpc, to: call.to, data: call.data, note: "Relay: buy \(token.symbol) for \(Fmt.num(spend)) USDG")
        try journal.append(.init(chain: "relay", id: quote.requestId, kind: .signed, note: "Robinhood USDG→\(token.symbol), tx \(hash)"))
        var after = try await balance(token.address, on: rpc)
        for _ in 0..<30 where after <= before {
            try await Task.sleep(for: .seconds(1))
            after = try await balance(token.address, on: rpc)
        }
        guard after > before else { throw ExecutionError("Relay took the USDG but no \(token.symbol) arrived yet. Order \(quote.requestId) is in the journal. \(EVMNetwork.robinhood.explorer)/tx/\(hash)") }
        let got = (after - before) / scale
        return "Bought \(Fmt.num(got, maxFraction: 6)) \(token.symbol) (\(token.name)) for \(Fmt.num(spend)) USDG via Relay — ≈ \(Fmt.usd(spend / got)) a token. "
            + "You hold \(Fmt.num(after / scale, maxFraction: 6)) \(token.symbol) on Robinhood Chain. \(EVMNetwork.robinhood.explorer)/tx/\(hash)"
    }

    /// An EVM step that is exactly «approve `units` of `token` to `spender`».
    private func exactApprove(_ step: Relay.EVMStep, token: String, spender: String, units: Decimal) -> Bool {
        let args = Data(step.data.dropFirst(4))
        return step.to.lowercased() == token && step.data.prefix(4).hex == "095ea7b3"
            && ABI.address(in: args, word: 0)?.lowercased() == spender && ABI.decimal(in: args, word: 1) == units
    }

    private func noPool(_ symbol: String, _ listing: TokenLookup.Info?) -> String {
        listing == nil ? "No Uniswap pool trades \(symbol) for USDG." : "No Uniswap v3 pool on Robinhood Chain trades \(symbol) for USDG."
    }

    /// Sells a Stock Token for USDG on Robinhood Chain; nil = all of it.
    public func sellStock(_ symbolOrContract: String, amount: Decimal?) async throws -> String {
        let rpc = EVMRPC.robinhood, usdg = EVMRPC.robinhoodUSDG, me = wallet.evm
        let (token, listing) = try await RobinhoodStocks.resolve(symbolOrContract)
        let symbol = token.symbol
        let scale = Decimal(sign: .plus, exponent: token.decimals, significand: 1)
        let held = try await balance(token.address, on: rpc)
        let wanted = (amount.map { min($0 * scale, held) } ?? held).rounded(0, .down)
        guard wanted > 0 else { throw ExecutionError("No \(symbol) on Robinhood Chain.") }
        guard let pool = try await bestPool(token.address, usdg, amountIn: wanted) else { throw ExecutionError(noPool(symbol, listing)) }
        try await ensureEVM(.robinhood, usdc: 0)
        try await approve(rpc, token: token.address, spender: UniswapV3.robinhoodRouter, units: wanted, note: "Approve exactly \(Fmt.num(wanted / scale, maxFraction: 6)) \(symbol) to Uniswap")
        let before = try await rpc.tokenBalance(usdg, owner: me)
        let hash = try await sendEVM(rpc, to: UniswapV3.robinhoodRouter,
                                     data: try UniswapV3.exactInputSingle(tokenIn: token.address, tokenOut: usdg, fee: pool.fee, recipient: me,
                                                                          amountIn: wanted, amountOutMinimum: (pool.out * 99 / 100).rounded(0, .down)),
                                     note: "Sell \(Fmt.num(wanted / scale, maxFraction: 6)) \(symbol)")
        var after = try await rpc.tokenBalance(usdg, owner: me)
        for _ in 0..<10 where after <= before {
            try await Task.sleep(for: .seconds(1))
            after = try await rpc.tokenBalance(usdg, owner: me)
        }
        return "Sold \(Fmt.num(wanted / scale, maxFraction: 6)) \(symbol) for \(Fmt.num(Decimal(after - before) / 1_000_000)) USDG. Say “move USDG from Robinhood to Solana” to bring it back. \(EVMNetwork.robinhood.explorer)/tx/\(hash)"
    }
}
