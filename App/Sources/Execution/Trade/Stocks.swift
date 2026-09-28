import EVMChain
import ExecutionCore
import Foundation
import LalaCore
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
    /// Tokens of 18 decimals: amounts up to ≈ 18 tokens fit the 64-bit amounts used here.
    // ponytail: 64-bit token amounts; switch to 256-bit words before trading more than ~18 whole tokens at once.
    func balance(_ token: String, on rpc: EVMRPC) async throws -> Decimal {
        ABI.decimal(in: try await rpc.read(token, try ERC20.balanceOf(wallet.evm)), word: 0) ?? 0
    }

    /// The Uniswap v3 pool with the most output for this trade, and that output.
    func bestPool(_ tokenIn: String, _ tokenOut: String, amountIn: UInt64) async throws -> (fee: UInt64, out: UInt64)? {
        var best: (UInt64, UInt64)?
        for fee in UniswapV3.fees {
            guard let answer = try? await EVMRPC.robinhood.read(UniswapV3.robinhoodQuoter,
                    try UniswapV3.quoteExactInputSingle(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: fee)),
                  let out = ABI.uint(in: answer, word: 0), out > (best?.1 ?? 0) else { continue }
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
        guard let pool = try await bestPool(usdg, token.address, amountIn: units) else { throw ExecutionError(noPool(symbol, listing)) }
        let scale = Decimal(sign: .plus, exponent: token.decimals, significand: 1)
        let price = (Decimal(units) / 1_000_000) / (Decimal(pool.out) / scale)
        var band = listing?.priceUSD.map { (bid: $0, ask: $0) }
        if listing == nil { band = try await RobinhoodStocks.quote(symbol) }
        if let q = band, price > q.ask * Decimal(string: "1.05")! || price < q.bid * Decimal(string: "0.95")! {
            throw ExecutionError("Uniswap's price \(Fmt.usd(price)) is outside \(listing == nil ? "Robinhood's own" : "DexScreener's") \(Fmt.usd(q.bid))–\(Fmt.usd(q.ask)). Nothing was signed.")
        }
        report("\(token.name) (\(symbol)): ≈ \(Fmt.usd(price)) a token on Uniswap (pool fee \(Fmt.num(Decimal(pool.fee) / 10_000))%).")
        try await ensureEVM(.robinhood, usdc: units)
        // Quote again with the money there: the price may have moved while the bridge ran.
        guard let fresh = try await bestPool(usdg, token.address, amountIn: units) else { throw ExecutionError(noPool(symbol, listing)) }
        let minimum = fresh.out / 100 * 99
        try await approve(rpc, token: usdg, spender: UniswapV3.robinhoodRouter, amount: units, note: "Approve exactly \(Fmt.num(Decimal(units) / 1_000_000)) USDG to Uniswap")
        let before = try await balance(token.address, on: rpc)
        let hash = try await sendEVM(rpc, to: UniswapV3.robinhoodRouter,
                                     data: try UniswapV3.exactInputSingle(tokenIn: usdg, tokenOut: token.address, fee: fresh.fee, recipient: me,
                                                                          amountIn: units, amountOutMinimum: minimum),
                                     note: "Buy \(symbol) for \(Fmt.num(Decimal(units) / 1_000_000)) USDG")
        var after = try await balance(token.address, on: rpc)
        for _ in 0..<10 where after <= before {
            try await Task.sleep(for: .seconds(1))
            after = try await balance(token.address, on: rpc)
        }
        let got = (after - before) / scale
        return "Bought \(Fmt.num(got, maxFraction: 6)) \(symbol) (\(token.name)) for \(Fmt.num(Decimal(units) / 1_000_000)) USDG — ≈ \(Fmt.usd(got > 0 ? (Decimal(units) / 1_000_000) / got : price)) a token. You hold \(Fmt.num(after / scale, maxFraction: 6)) \(symbol) on Robinhood Chain. \(EVMNetwork.robinhood.explorer)/tx/\(hash)"
    }

    private func noPool(_ symbol: String, _ listing: TokenLookup.Info?) -> String {
        listing == nil ? "No Uniswap pool trades \(symbol) for USDG."
            // ponytail: amounts are 64-bit (≈ 18 whole tokens of 18 decimals); 256-bit words lift it.
            : "No Uniswap v3 pool on Robinhood Chain trades \(symbol) for USDG at this size (ihatecrypto handles up to ≈ 18 whole tokens a trade for now)."
    }

    /// Sells a Stock Token for USDG on Robinhood Chain; nil = all of it.
    public func sellStock(_ symbolOrContract: String, amount: Decimal?) async throws -> String {
        let rpc = EVMRPC.robinhood, usdg = EVMRPC.robinhoodUSDG, me = wallet.evm
        let (token, listing) = try await RobinhoodStocks.resolve(symbolOrContract)
        let symbol = token.symbol
        let scale = Decimal(sign: .plus, exponent: token.decimals, significand: 1)
        let held = try await balance(token.address, on: rpc)
        let wanted = amount.map { min($0 * scale, held) } ?? held
        guard wanted > 0, wanted < Decimal(UInt64.max) else { throw ExecutionError(held == 0 ? "No \(symbol) on Robinhood Chain." : "Too many tokens for one sale here.") }
        let units = NSDecimalNumber(decimal: wanted.rounded(0, .down)).uint64Value
        guard let pool = try await bestPool(token.address, usdg, amountIn: units) else { throw ExecutionError(noPool(symbol, listing)) }
        try await ensureEVM(.robinhood, usdc: 0)
        try await approve(rpc, token: token.address, spender: UniswapV3.robinhoodRouter, amount: units, note: "Approve exactly \(Fmt.num(wanted / scale, maxFraction: 6)) \(symbol) to Uniswap")
        let before = try await rpc.tokenBalance(usdg, owner: me)
        let hash = try await sendEVM(rpc, to: UniswapV3.robinhoodRouter,
                                     data: try UniswapV3.exactInputSingle(tokenIn: token.address, tokenOut: usdg, fee: pool.fee, recipient: me,
                                                                          amountIn: units, amountOutMinimum: pool.out / 100 * 99),
                                     note: "Sell \(Fmt.num(wanted / scale, maxFraction: 6)) \(symbol)")
        var after = try await rpc.tokenBalance(usdg, owner: me)
        for _ in 0..<10 where after <= before {
            try await Task.sleep(for: .seconds(1))
            after = try await rpc.tokenBalance(usdg, owner: me)
        }
        return "Sold \(Fmt.num(wanted / scale, maxFraction: 6)) \(symbol) for \(Fmt.num(Decimal(after - before) / 1_000_000)) USDG. Say “move USDG from Robinhood to Solana” to bring it back. \(EVMNetwork.robinhood.explorer)/tx/\(hash)"
    }
}
