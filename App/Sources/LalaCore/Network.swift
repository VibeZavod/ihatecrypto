import Foundation
import LLMCore
import OneClickKit
import RelayBridge

func dec(_ s: String?) throws -> Decimal {
    guard let s, let d = Decimal(string: s) else { throw NetError(message: "Unexpected number format: \(s ?? "nil")") }
    return d
}

// MARK: - Hyperliquid (read-only `info`)

public enum Hyperliquid {
    static let info = "https://api.hyperliquid.xyz/info"

    /// HIP-3 exchanges whose markets LALA shows: xyz carries the liquid commodities and stocks (oil, gold,
    /// Tesla…); the others had no volume on 2026-09-25.
    public static let hip3Dexes = ["xyz"]

    /// All live perp markets keyed by name: the main exchange ("ETH") and HIP-3 ones ("xyz:CL").
    public static func markets() async throws -> [String: Market] {
        async let main = markets(dex: nil, dexIndex: 0)
        async let order = try? HTTP.post(info, json: ["type": "perpDexs"])
        var out = try await main
        // Asset ids of HIP-3 markets depend on the exchange's position in perpDexs.
        let dexes = ((await order).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] } ?? [])
            .map { ($0 as? [String: Any])?["name"] as? String }
        for dex in hip3Dexes {
            guard let i = dexes.firstIndex(of: dex), let extra = try? await markets(dex: dex, dexIndex: i) else { continue }
            out.merge(extra) { a, _ in a }
        }
        return out
    }

    static func markets(dex: String?, dexIndex: Int) async throws -> [String: Market] {
        struct Asset: Decodable { let name: String; let szDecimals: Int; let maxLeverage: Int; let isDelisted: Bool? }
        struct Meta: Decodable { let universe: [Asset] }
        struct Ctx: Decodable { let markPx: String?; let prevDayPx: String?; let funding: String?; let dayNtlVlm: String? }
        // The response is a two-element array: [meta, contexts].
        struct Response: Decodable {
            let meta: Meta, ctxs: [Ctx]
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                meta = try c.decode(Meta.self)
                ctxs = try c.decode([Ctx].self)
            }
        }
        var body: [String: Any] = ["type": "metaAndAssetCtxs"]
        if let dex { body["dex"] = dex }
        let r = try JSONDecoder().decode(Response.self, from: try await HTTP.post(info, json: body))
        let (meta, ctxs) = (r.meta, r.ctxs)
        var out: [String: Market] = [:]
        for (index, (asset, ctx)) in zip(meta.universe, ctxs).enumerated() where asset.isDelisted != true {
            guard let px = ctx.markPx.flatMap({ Decimal(string: $0) }) else { continue }
            out[asset.name] = Market(name: asset.name, markPx: px, szDecimals: asset.szDecimals, maxLeverage: asset.maxLeverage,
                                     index: dex == nil ? index : 100_000 + dexIndex * 10_000 + index,
                                     prevDayPx: ctx.prevDayPx.flatMap { Decimal(string: $0) }, funding: ctx.funding.flatMap { Decimal(string: $0) }, dex: dex)
            out[asset.name]?.volume24h = ctx.dayNtlVlm.flatMap { Decimal(string: $0) } ?? 0
        }
        return out
    }

    /// ATR(14) of 4-hour candles as % of the last close: the market's ordinary move, for stops.
    public static func atrPct(coin: String, now: Date = Date()) async throws -> Decimal {
        struct Candle: Decodable { let h: String; let l: String; let c: String }
        let end = Int(now.timeIntervalSince1970 * 1000)
        let body: [String: Any] = ["type": "candleSnapshot", "req": ["coin": coin, "interval": "4h", "startTime": end - 16 * 4 * 3_600_000, "endTime": end]]
        let candles = try JSONDecoder().decode([Candle].self, from: try await HTTP.post(info, json: body))
        let bars = try candles.map { (h: try dec($0.h), l: try dec($0.l), c: try dec($0.c)) }
        guard bars.count >= 15 else { throw NetError(message: "Not enough \(coin) candles for ATR.") }
        let ranges = (1..<bars.count).map { i in max(bars[i].h - bars[i].l, abs(bars[i].h - bars[i - 1].c), abs(bars[i].l - bars[i - 1].c)) }
        let atr = ranges.suffix(14).reduce(0, +) / 14
        return atr / bars[bars.count - 1].c * 100
    }

    public struct Balance: Sendable {
        public let accountValue: Decimal
        public let withdrawable: Decimal
        public let spotUSDC: Decimal
    }

    /// A HIP-3 exchange's own margin balance: account value and what is free.
    public static func dexBalance(user: String, dex: String) async throws -> (accountValue: Decimal, withdrawable: Decimal) {
        struct Summary: Decodable { let accountValue: String }
        struct Perp: Decodable { let marginSummary: Summary; let withdrawable: String }
        let perp = try JSONDecoder().decode(Perp.self, from: try await HTTP.post(info, json: ["type": "clearinghouseState", "user": user, "dex": dex]))
        return (try dec(perp.marginSummary.accountValue), try dec(perp.withdrawable))
    }

    /// Perp and spot are separate balances on HyperCore; they are shown apart, never summed.
    public static func balance(user: String) async throws -> Balance {
        struct Summary: Decodable { let accountValue: String }
        struct Perp: Decodable { let marginSummary: Summary; let withdrawable: String }
        struct SpotRow: Decodable { let coin: String; let total: String }
        struct Spot: Decodable { let balances: [SpotRow] }
        async let perpData = HTTP.post(info, json: ["type": "clearinghouseState", "user": user])
        async let spotData = HTTP.post(info, json: ["type": "spotClearinghouseState", "user": user])
        let perp = try JSONDecoder().decode(Perp.self, from: try await perpData)
        let spot = try JSONDecoder().decode(Spot.self, from: try await spotData)
        return Balance(
            accountValue: try dec(perp.marginSummary.accountValue),
            withdrawable: try dec(perp.withdrawable),
            spotUSDC: try dec(spot.balances.first { $0.coin == "USDC" }?.total ?? "0")
        )
    }
}

// MARK: - Solana (public RPC)

public enum Solana {
    // ponytail: public mainnet RPC is rate-limited; add a user-chosen RPC field when it starts failing.
    static let rpc = "https://api.mainnet-beta.solana.com"
    static let usdcMint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

    public struct Balance: Sendable {
        public let sol: Decimal
        public let usdc: Decimal
    }

    public static func balance(owner: String) async throws -> Balance {
        struct RPCError: Decodable { let message: String }
        struct Lamports: Decodable { struct R: Decodable { let value: UInt64 }; let result: R?; let error: RPCError? }
        struct Tokens: Decodable {
            struct Amount: Decodable { let amount: String; let decimals: Int }
            struct Info: Decodable { let tokenAmount: Amount }
            struct Parsed: Decodable { let info: Info }
            struct DataField: Decodable { let parsed: Parsed }
            struct Account: Decodable { let data: DataField }
            struct Item: Decodable { let account: Account }
            struct R: Decodable { let value: [Item] }
            let result: R?
            let error: RPCError?
        }
        async let lamportsData = HTTP.post(rpc, json: ["jsonrpc": "2.0", "id": 1, "method": "getBalance", "params": [owner]])
        async let tokensData = HTTP.post(rpc, json: [
            "jsonrpc": "2.0", "id": 2, "method": "getTokenAccountsByOwner",
            "params": [owner, ["mint": usdcMint], ["encoding": "jsonParsed"]],
        ])
        let lamports = try JSONDecoder().decode(Lamports.self, from: try await lamportsData)
        let tokens = try JSONDecoder().decode(Tokens.self, from: try await tokensData)
        guard let l = lamports.result, let t = tokens.result else {
            throw NetError(message: "Solana RPC: \(lamports.error?.message ?? tokens.error?.message ?? "empty response")")
        }
        var usdc = Decimal()
        for item in t.value {
            let a = item.account.data.parsed.info.tokenAmount
            usdc += try dec(a.amount) / pow(10, a.decimals)
        }
        return Balance(sol: Decimal(l.value) / 1_000_000_000, usdc: usdc)
    }
}

/// The NEAR chain: native NEAR and wNEAR on an account. 1Click delivers «wrap.near», so both are counted.
public enum Near {
    static let rpc = "https://rpc.mainnet.fastnear.com"

    public static func balance(account: String) async throws -> (near: Decimal, wrapped: Decimal) {
        func query(_ params: [String: Any]) async throws -> [String: Any]? {
            let data = try await HTTP.post(rpc, json: ["jsonrpc": "2.0", "id": 1, "method": "query", "params": params])
            let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let e = j?["error"] as? [String: Any] {
                // An implicit account exists only after NEAR first arrives; before that it simply holds nothing.
                if "\(e)".contains("UNKNOWN_ACCOUNT") || "\(e)".contains("does not exist") { return nil }
                throw NetError(message: "NEAR RPC: \(e["message"] ?? e)")
            }
            return j?["result"] as? [String: Any]
        }
        let yocto = pow(Decimal(10), 24)
        let view = try await query(["request_type": "view_account", "finality": "final", "account_id": account])
        let native = (view?["amount"] as? String).flatMap { Decimal(string: $0) } ?? 0
        let args = try JSONSerialization.data(withJSONObject: ["account_id": account]).base64EncodedString()
        let call = try await query(["request_type": "call_function", "finality": "final", "account_id": "wrap.near",
                                    "method_name": "ft_balance_of", "args_base64": args])
        // The view returns the JSON string «"123"» as bytes.
        let text = String(decoding: (call?["result"] as? [Int] ?? []).map { UInt8($0) }, as: UTF8.self)
        let wrapped = Decimal(string: text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) ?? 0
        return (native / yocto, wrapped / yocto)
    }
}

// MARK: - NEAR Intents 1Click (dry quotes for the plan; execution lives in OneClickKit)

public enum Bridge {
    // Dry quotes do not depend on addresses, so the user's own addresses are not sent.
    static let placeholderRefund = "So11111111111111111111111111111111111111112"
    static let placeholderRecipient = "0x0000000000000000000000000000000000000001"

    /// `arrive` = exact USDC to land on HyperCore; `send` = exact USDC to spend from Solana.
    public enum Amount: Sendable { case arrive(Decimal), send(Decimal) }

    /// Both bridges in parallel; the cheaper one wins and the other is shown for comparison.
    public static func dryQuote(_ amount: Amount) async throws -> BridgeQuote {
        async let relay = try? relayQuote(amount)
        async let oneClick = try? oneClickQuote(amount)
        let options = [await relay, await oneClick].compactMap { $0 }
        let arriving: Bool = if case .arrive = amount { true } else { false }
        // Arriving amount fixed: least sent wins. Sent amount fixed: most received wins.
        let sorted = options.sorted { arriving ? $0.amountIn < $1.amountIn : $0.amountOut > $1.amountOut }
        guard var best = sorted.first else { throw NetError(message: "No bridge quotes: Relay and 1Click didn't respond.") }
        if let other = sorted.dropFirst().first {
            best.alternative = "\(other.provider): send \(Fmt.num(other.amountIn)) → receive \(Fmt.num(other.amountOut)), \(other.time.lowercased())"
        }
        return best
    }

    static func relayQuote(_ amount: Amount) async throws -> BridgeQuote {
        let (exactOutput, units): (Bool, Decimal) = switch amount {
        case .arrive(let v): (true, v * 100_000_000) // Hyperliquid perp USDC in Relay: 8 decimals
        case .send(let v): (false, v * 1_000_000)
        }
        let q = try await Relay.quote(user: placeholderRefund, recipient: placeholderRecipient, originChain: Relay.Chain.solana,
                                      destinationChain: Relay.Chain.hyperliquid, originCurrency: Relay.Currency.solanaUSDC,
                                      destinationCurrency: Relay.Currency.hyperliquidUSDC,
                                      amount: NSDecimalNumber(decimal: units.rounded(0, .up)).uint64Value, exactOutput: exactOutput)
        // Measured 2026-09-25: 4 s from send to credit on Hyperliquid.
        return BridgeQuote(provider: "Relay", amountIn: try dec(q.amountInFormatted), reserve: 0,
                           amountOut: try dec(q.amountOutFormatted), time: "Seconds: 4 s to credit in live runs.")
    }

    static func oneClickQuote(_ amount: Amount) async throws -> BridgeQuote {
        let (exactOutput, units): (Bool, Decimal) = switch amount {
        case .arrive(let v): (true, v * 100_000_000) // HyperCore USDC has 8 decimals
        case .send(let v): (false, v * 1_000_000)    // Solana USDC has 6 decimals
        }
        // EXACT_OUTPUT adds the slippage tolerance to amountIn; 0.1% is enough for USDC → USDC.
        let q = try await OneClick.quote(
            dry: true, exactOutput: exactOutput, origin: OneClick.Asset.solanaUSDC, destination: OneClick.Asset.hyperCoreUSDC,
            amount: "\(units.rounded(0, .up))", refundTo: placeholderRefund, recipient: placeholderRecipient, slippageBps: 10
        )
        let amountIn = try dec(q.amountInFormatted)
        let priceIn = try q.minAmountIn.map { try dec($0) / 1_000_000 } ?? amountIn
        // 1Click estimates ~30 s; live runs took 114–237 s from send to credit.
        return BridgeQuote(provider: "NEAR 1Click", amountIn: amountIn, reserve: max(0, amountIn - priceIn),
                           amountOut: try dec(q.amountOutFormatted), time: "Usually 2–4 min.")
    }
}
