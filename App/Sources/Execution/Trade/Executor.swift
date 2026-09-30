import ExecutionCore
import Foundation
import HyperliquidSigning
import LalaCore
import RelayBridge
import SolanaChain
import TxGuard
import WalletCore

/// Whoever holds the keys. The app's is the signing process over XPC; the terminal check signs with the
/// test wallet's key. Both run the guard before signing, so the executor cannot talk either into more.
public protocol TradeSigner: Sendable {
    /// `accounts`: the message's full account list; `recipients`: addresses the user approved besides their own.
    func signSolana(_ wire: Data, accounts: [String], recipients: [String], tokenOwners: [String: String]) async throws -> Data
    /// Orders, cancels, leverage.
    func signHyperliquid(_ action: MsgPack, nonce: UInt64) async throws -> EVMSignature
    /// Transfers signed by the main key (sendAsset to Relay's depository); `recipients` as approved.
    func signHyperliquidUser(_ action: MsgPack, recipients: [String]) async throws -> EVMSignature
    /// Relay's binding of a Hyperliquid deposit to an order.
    func signRelayMapping(wallet: String, depositor: String, id: Data, nonce: UInt64) async throws -> EVMSignature
    /// An EIP-1559 transaction; the signer decodes the calldata itself (no unlimited approvals, no transfers to others).
    /// `recipients`: addresses the user approved for a token transfer (from the address book), besides their own.
    func signEVM(chainId: UInt64, nonce: UInt64, maxPriorityFee: UInt64, maxFee: UInt64, gasLimit: UInt64,
                 to: String, data: Data, recipients: [String]) async throws -> Data
    /// Native NEAR into a 1Click deposit: the signer builds the one wrap.near transaction itself
    /// (`NearTransaction.intentDeposit`) and returns it signed, in borsh.
    func signNearIntentDeposit(amount: UInt128, depositAddress: String, nonce: UInt64, blockHash: Data) async throws -> Data
    /// A native NEAR transfer of exactly `amount` yocto to `receiver`, which must be among `recipients` (saved addresses).
    func signNearTransfer(amount: UInt128, receiver: String, recipients: [String], nonce: UInt64, blockHash: Data) async throws -> Data
    /// Deletes the wallet's NEAR account; NEAR sends all that is on it to `beneficiary` (one of `recipients`).
    func signNearDeleteAccount(beneficiary: String, recipients: [String], nonce: UInt64, blockHash: Data) async throws -> Data
}

extension TradeSigner {
    public func signNearTransfer(amount: UInt128, receiver: String, recipients: [String], nonce: UInt64, blockHash: Data) async throws -> Data {
        throw ExecutionError("NEAR transfers are signed in the ihatecrypto app.")
    }
    public func signNearDeleteAccount(beneficiary: String, recipients: [String], nonce: UInt64, blockHash: Data) async throws -> Data {
        throw ExecutionError("Closing the NEAR account is signed in the ihatecrypto app.")
    }
}

public struct TradeWallet: Sendable {
    public let solana: String
    public let evm: String
    public init(solana: String, evm: String) {
        self.solana = solana
        self.evm = evm
    }
}

public struct ExecutionError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Runs an approved plan on mainnet: bridge if the trading balance is short, leverage, entry, stop and take,
/// then checks on the exchange that the position is protected. A position is never left without its stop:
/// if the stop cannot be placed, the position is closed at once.
public actor Executor {
    let wallet: TradeWallet
    let signer: any TradeSigner
    let journal: Journal
    let rpc: SolanaRPC
    let report: @Sendable (String) -> Void
    /// A Jupiter swap that went through: from, to, how much went in and how much arrived (the app keeps spot costs).
    let swapped: (@Sendable (SpotAsset, SpotAsset, Decimal, Decimal) -> Void)?
    private var lastNonce: UInt64 = 0

    /// Worst price accepted for a market entry or exit, from the mark.
    /// Smallest bridge worth its fee (Relay ≈ $0.02 flat).
    static let minBridgeUSDC: Decimal = 2
    static let slippage = Decimal(string: "0.01")!
    /// Market stop and take fill up to this far past the trigger, as Hyperliquid's own interface does.
    static let triggerSlippage = Decimal(string: "0.1")!

    public init(wallet: TradeWallet, signer: any TradeSigner, journal: Journal, rpc: SolanaRPC = SolanaRPC(),
                report: @escaping @Sendable (String) -> Void, swapped: (@Sendable (SpotAsset, SpotAsset, Decimal, Decimal) -> Void)? = nil) {
        self.wallet = wallet
        self.signer = signer
        self.journal = journal
        self.rpc = rpc
        self.report = report
        self.swapped = swapped
    }

    public struct Opened: Sendable {
        public let asset: String
        public let size: Decimal
        public let entry: Decimal
        public let stop: Decimal
        public let take: Decimal?
        /// A limit entry still waiting on the book; its stop and take switch on when it fills.
        public var pending = false
        /// First partial take (half at 1R), when the plan asked for one.
        public var partialTake: Decimal?
    }

    /// The bridge transaction exactly as it will be signed, with its simulated effect.
    public struct BridgeStep: Sendable {
        public let requestId: String
        public let unsigned: Data
        public let accounts: [String]
        public let tokenOwners: [String: String]
        public let lastValid: UInt64
        public let spend: Decimal
        public let arriving: Decimal
        public let feesUSD: String
        /// Where the USDC goes: Hyperliquid for trades, Base for Aave.
        public var chain: UInt64 = Relay.Chain.hyperliquid
        /// Part of the fee that is Hyperliquid's one-time charge for opening the account; 0 for an existing one.
        public var opening: Decimal = 0
    }

    /// Everything the user confirms: what will be signed, in order, and what it does to each balance.
    public struct Prepared: Sendable {
        public let intent: TradeIntent
        public let market: Market
        public let sizing: Sizing
        public let leverage: Int
        public let bridge: BridgeStep?
        /// USDC to move from the main Hyperliquid balance to a HIP-3 exchange's margin («xyz»).
        public var dexTransfer: (dex: String, usdc: Decimal)?
        /// Solana was short: this much USDC goes straight from an EVM network to Hyperliquid instead of `bridge`.
        public var fundFrom: (net: EVMNetwork, usdc: Decimal)?
        /// «Solana USDC: 5.80 → 3.75 (−2.05)», one line per balance.
        public let changes: [String]
        /// One line per signature, in order.
        public let steps: [String]
        public let preparedAt: Date

        /// The bridge transaction's blockhash lives about a minute; after that the preview is redone.
        public var isFresh: Bool { Date().timeIntervalSince(preparedAt) < 45 }
    }

    // MARK: Prepare

    /// Fresh prices and balances, the bridge quote and transaction, and a simulation of it. Nothing is signed.
    /// The risk rules are applied here too, on fresh balances: the UI showing a green plan is not enough.
    public func prepare(_ requested: TradeIntent, policy: RiskPolicy = RiskPolicy()) async throws -> Prepared {
        let markets = try await Hyperliquid.markets()
        guard var market = markets[requested.asset], market.index >= 0 else { throw ExecutionError("No \(requested.asset) market on Hyperliquid.") }
        market.atrPct = try? await Hyperliquid.atrPct(coin: market.name)
        let hl = try await Hyperliquid.balance(user: wallet.evm)
        let solanaUSDC = Decimal(try await rpc.tokenBalance(owner: wallet.solana, mint: Relay.Currency.solanaUSDC)) / 1_000_000
        var equity = hl.accountValue + solanaUSDC
        for dex in Hyperliquid.hip3Dexes { equity += (try? await Hyperliquid.dexBalance(user: wallet.evm, dex: dex).accountValue) ?? 0 }
        // Idle USDC on the EVM networks is capital too, and the trade can be paid from it when Solana is short.
        var held: [String: Decimal] = [:]
        for net in EVMNetwork.searched {
            held[net.key] = (try? await net.rpc.tokenBalance(net.usdc, owner: wallet.evm)).map { Decimal($0) / 1_000_000 }
        }
        equity += held.values.reduce(0, +)
        let intent = Plan.resolve(requested, market: market, equity: equity, policy: policy).intent
        let evaluation = Plan.evaluate(intent, market: market)
        guard evaluation.missing.isEmpty, evaluation.problem == nil, let sizing = evaluation.sizing, intent.stopPct != nil else {
            throw ExecutionError(evaluation.problem ?? "The plan isn't ready: missing \(evaluation.missing.joined(separator: ", ")).")
        }
        // One plan per asset: a second entry would merge into the open position and its stop.
        let positions = try await HyperliquidAccount.positions(wallet.evm).filter { $0.size != 0 }
        let orders = try await HyperliquidAccount.openOrders(wallet.evm)
        if positions.contains(where: { $0.coin == market.name }) || orders.contains(where: { $0.coin == market.name }) {
            throw ExecutionError("There's already a position or order on \(market.name). Manage it in chat («stop to breakeven», «close half», «cancel the limit») or pick another asset.")
        }
        let openRisk = HyperliquidAccount.riskAtStops(positions: positions, orders: orders)
        let blocked = RiskRules.check(intent, sizing, market: market, equity: equity, policy: policy, openRisk: openRisk).filter { $0.level == .block }
        guard blocked.isEmpty else { throw ExecutionError(blocked.map(\.text).joined(separator: " ")) }
        let leverage = NSDecimalNumber(decimal: intent.leverage ?? 1).intValue

        // HIP-3 markets («xyz:CL») keep margin on their own exchange: what is free there counts, and the rest
        // moves over from the main balance before the order.
        var dexFree: Decimal = 0
        if let dex = market.dex { dexFree = try await Hyperliquid.dexBalance(user: wallet.evm, dex: dex).withdrawable }
        var dexTransfer: (dex: String, usdc: Decimal)?
        if let dex = market.dex {
            let needed = sizing.margin * (1 + Self.slippage) + sizing.feesUSD
            if needed > dexFree { dexTransfer = (dex, (needed - dexFree).rounded(2, .up)) }
        }
        var amount: Bridge.Amount?
        if let usdc = intent.amountUSDC {
            amount = .send(usdc)
        } else if let need = Plan.bridgeNeed(intent, evaluation, hlWithdrawable: hl.withdrawable + dexFree) {
            // A little over the plan: the entry may fill up to 1% worse than the mark the plan used. A tiny top-up
            // would pay about as much in bridge fees as it moves (and the guard refuses that), so bring at least
            // `minBridgeUSDC` when Solana has it; the rest stays free on Hyperliquid.
            var arrive = (need + sizing.margin * Self.slippage).rounded(2, .up)
            if arrive < Self.minBridgeUSDC {
                let onSolana = Decimal(try await rpc.tokenBalance(owner: wallet.solana, mint: Relay.Currency.solanaUSDC)) / 1_000_000
                arrive = max(arrive, min(Self.minBridgeUSDC, (onSolana - Decimal(string: "0.05")!).rounded(2, .down)))
            }
            amount = .arrive(arrive)
        }
        var prepared: (step: BridgeStep, changes: [String])?
        var fund: (net: EVMNetwork, usdc: Decimal, quote: BridgeQuote, gas: Bool, have: Decimal)?
        if let amount {
            // Solana first. Short there, the money goes straight from an EVM network that holds it — the same choice,
            // from the same dry quote, as the plan's card.
            let newAccount = (try? await Hyperliquid.isNewAccount(wallet.evm)) ?? false
            let viaSolana = switch amount {
            case .send(let v): v
            case .arrive: try await Bridge.dryQuote(amount, newAccount: newAccount).amountIn
            }
            if viaSolana > solanaUSDC, let net = EVMNetwork.funding(viaSolana, held: { held[$0] }) {
                let q = try await Bridge.dryQuote(.send(viaSolana), newAccount: newAccount, from: (net.relayChain, net.usdc))
                // No gas coin there: a little comes from Solana first (ensureEVM), which needs half a dollar there.
                let gas = net.feeToken == nil ? try await net.rpc.balance(wallet.evm) >= net.gasFloor : true
                guard gas || solanaUSDC >= Decimal(string: "0.7")! else {
                    throw ExecutionError("\(net.name) has the USDC but no \(net.gasCoin) for gas, and Solana has too little USDC to bring it. Send a little \(net.gasCoin) to \(net.name) or USDC to Solana.")
                }
                fund = (net, viaSolana, q, gas, held[net.key] ?? 0)
            } else {
                prepared = try await prepareBridge(amount)
            }
        }
        let bridge = prepared?.step
        var changes = prepared?.changes ?? []
        var steps: [String] = []
        if let b = bridge {
            steps.append("Relay bridge: \(Fmt.num(b.spend)) USDC from Solana → \(Fmt.num(b.arriving)) USDC on Hyperliquid, fee \(Decimal(string: b.feesUSD).map { Fmt.usd($0) } ?? "$" + b.feesUSD)"
                         + (b.opening > 0 ? ", of it \(Fmt.usd(b.opening)) once for opening your Hyperliquid account." : "."))
        }
        if let f = fund {
            if !f.gas { steps.append("\(f.net.gasCoin) for gas on \(f.net.name) first: 0.5 USDC from Solana over Relay, the \(f.net.gasCoin) arrives with it.") }
            steps.append("Relay bridge straight from \(f.net.name): approve exactly \(Fmt.num(f.usdc)) USDC, then Relay's deposit → ≈ \(Fmt.num(f.quote.amountOut)) USDC on Hyperliquid, "
                         + "fee ≈ \(Fmt.usd(f.quote.amountIn - f.quote.amountOut)). Solana has \(Fmt.num(solanaUSDC)) USDC, less than the trade needs.")
            changes.append("\(f.net.name) USDC: \(Fmt.num(f.have)) → \(Fmt.num(f.have - f.usdc)) (−\(Fmt.num(f.usdc))).")
        }
        let arriving = bridge?.arriving ?? fund?.quote.amountOut ?? 0
        let side = intent.side == .long ? "Long" : "Short"
        if let t = dexTransfer {
            steps.append("Transfer \(Fmt.num(t.usdc)) USDC from the main Hyperliquid balance to the \(t.dex) exchange — its markets have their own margin.")
            changes.append("Hyperliquid \(t.dex), free: \(Fmt.usd(dexFree)) → \(Fmt.usd(dexFree + t.usdc)) before entry.")
        }
        steps.append("Leverage \(leverage)×, isolated margin.")
        if let limit = intent.entryPx {
            steps.append("\(side) \(Fmt.num(sizing.size, maxFraction: market.szDecimals)) \(market.name) as a limit at \(Fmt.price(HLAction.price(limit, szDecimals: market.szDecimals))) (now \(Fmt.price(market.markPx))), waiting on the exchange, with stop −\(Fmt.pct(intent.stopPct ?? 0))\(intent.takePct.map { " and take-profit +\(Fmt.pct($0))" } ?? ""), active once it fills.")
        } else {
            steps.append("\(side) \(Fmt.num(sizing.size, maxFraction: market.szDecimals)) \(market.name) at market, no worse than \(Fmt.price(HLAction.price(market.markPx * (intent.side == .long ? 1 + Self.slippage : 1 - Self.slippage), szDecimals: market.szDecimals))).")
            steps.append("Stop \(Fmt.pct(intent.stopPct ?? 0))\(intent.takePct.map { " and take-profit \(Fmt.pct($0))" } ?? "") from the entry price (\(intent.side == .long ? "stop below, take above" : "stop above, take below")), on the exchange.")
        }
        if intent.partialTake == true, intent.entryPx == nil { steps.append("Partial take-profit: half the position at 1R, as a separate order on the exchange; then the stop moves to breakeven.") }
        if let trail = intent.trailingPct { steps.append("Trailing \(Fmt.pct(trail)): ihatecrypto moves the stop while the app is open (each move is a signature).") }
        changes.append("Hyperliquid, free: \(Fmt.usd(hl.withdrawable)) → ≈ \(Fmt.usd(hl.withdrawable + arriving - sizing.margin - sizing.feesUSD / 2)) (margin \(Fmt.usd(sizing.margin)) goes into the position).")
        changes.append("Position: \(side.lowercased()) \(Fmt.num(sizing.size, maxFraction: market.szDecimals)) \(market.name), at the stop ≈ −\(Fmt.usd(sizing.lossAtStopUSD))\(sizing.profitAtTakeUSD.map { ", at the take ≈ +\(Fmt.usd($0))" } ?? "").")
        var p = Prepared(intent: intent, market: market, sizing: sizing, leverage: leverage, bridge: bridge,
                         changes: changes, steps: steps, preparedAt: Date())
        p.dexTransfer = dexTransfer
        p.fundFrom = fund.map { ($0.net, $0.usdc) }
        return p
    }

    // MARK: Open

    /// Signs and sends what `prepare` showed. Prices may move inside the approved limits; outside them it stops.
    public func execute(_ p: Prepared) async throws -> Opened {
        guard p.isFresh else { throw ExecutionError("This confirmation is stale: the numbers need a refresh.") }
        let market = try await Hyperliquid.markets()[p.market.name] ?? p.market
        guard abs(market.markPx - p.market.markPx) / p.market.markPx <= Self.slippage else {
            throw ExecutionError("\(market.name) moved more than 1% since you confirmed. Nothing was signed.")
        }
        let long = p.intent.side == .long
        if let b = p.bridge { try await sendBridge(b) }
        if let f = p.fundFrom {
            try await ensureEVM(f.net, usdc: 0)
            report(try await bridge(f.net, to: nil, hyperliquid: true, usdc: f.usdc))
        }
        if let t = p.dexTransfer { try await moveMargin(from: "", to: t.dex, usdc: t.usdc) }

        let lev = try await post(Self.leverageAction(asset: p.market.index, leverage: p.leverage), label: "leverage")
        guard case .ok = lev else { throw ExecutionError("Hyperliquid rejected leverage \(p.leverage)×: \(lev).") }
        report("Leverage \(p.leverage)×, isolated margin.")

        if let limit = p.intent.entryPx { return try await placeLimit(p, market: market, limit: limit) }

        let entryPx = HLAction.price(market.markPx * (long ? 1 + Self.slippage : 1 - Self.slippage), szDecimals: market.szDecimals)
        let entry = try await post(try HLAction.order([HLOrder(asset: market.index, isBuy: long, price: entryPx, size: p.sizing.size,
                                                               reduceOnly: false, kind: .limit(tif: "Ioc"))]), label: "entry")
        guard case .filled(let size, let avgPx) = entry else {
            throw ExecutionError("The entry didn't fill (\(entry)). No position; the money is on your Hyperliquid balance.")
        }
        report("\(long ? "Long" : "Short") \(Fmt.num(size, maxFraction: market.szDecimals)) \(market.name) at \(Fmt.price(avgPx)).")

        // Stop and take from the actual fill, so the loss at the stop stays the approved risk.
        let (stop, take) = Self.protectionPrices(entry: avgPx, stopPct: p.intent.stopPct ?? 0, takePct: p.intent.takePct, long: long,
                                                 szDecimals: market.szDecimals)
        do {
            let placed = try await post(try Self.protectionAction(asset: market.index, long: long, size: size, stop: stop, take: take,
                                                                  szDecimals: market.szDecimals), label: "stop and take-profit")
            if case .error(let e) = placed { throw ExecutionError(e) }
            try await verifyProtection(coin: market.name, stop: stop, take: take)
        } catch {
            report("The stop didn't go through: \(error.localizedDescription). Closing the position so it isn't left unprotected.")
            _ = try? await close(asset: market.name)
            throw ExecutionError("Position closed: the exchange didn't confirm the stop.")
        }
        report("On the exchange: stop \(Fmt.price(stop))\(take.map { " and take-profit \(Fmt.price($0))" } ?? ""). The position is protected.")
        var opened = Opened(asset: market.name, size: size, entry: avgPx, stop: stop, take: take)
        if p.intent.partialTake == true { opened.partialTake = try? await placePartialTake(market: market, long: long, size: size, entry: avgPx, stop: stop) }
        return opened
    }

    /// For a limit entry that has filled: half at 1R from the actual entry and stop on the exchange.
    public func addPartialTake(asset: String) async throws -> Decimal? {
        let market = try await market(asset)
        guard let p = try await HyperliquidAccount.positions(wallet.evm).first(where: { $0.coin == asset && $0.size != 0 }),
              let stop = try await HyperliquidAccount.openOrders(wallet.evm).first(where: { $0.coin == asset && $0.isTrigger && ($0.orderType ?? "").contains("Stop") })?.triggerPx
        else { return nil }
        return try await placePartialTake(market: market, long: p.size > 0, size: abs(p.size), entry: p.entry, stop: stop)
    }

    /// Half the position at 1R as a separate reduce-only take. The position stays protected if this fails.
    private func placePartialTake(market: Market, long: Bool, size: Decimal, entry: Decimal, stop: Decimal) async throws -> Decimal? {
        let half = HLAction.size(size / 2, szDecimals: market.szDecimals)
        guard half * entry >= 10 else {
            report("Partial take-profit skipped: half the position is below the $10 minimum order.")
            return nil
        }
        let oneR = HLAction.price(entry + (entry - stop), szDecimals: market.szDecimals)
        let worst = HLAction.price(oneR * (long ? 1 - Self.triggerSlippage : 1 + Self.triggerSlippage), szDecimals: market.szDecimals)
        let reply = try await post(try HLAction.order([HLOrder(asset: market.index, isBuy: !long, price: worst, size: half, reduceOnly: true,
                                                               kind: .trigger(price: oneR, isMarket: true, tpsl: "tp"))]), label: "partial take-profit")
        guard !reply.isError else {
            report("Partial take-profit didn't go through (\(reply)); the stop and full take-profit are still in place.")
            return nil
        }
        report("Partial take-profit: \(Fmt.num(half, maxFraction: market.szDecimals)) \(market.name) at 1R → \(Fmt.price(oneR)). After it fills, the stop moves to breakeven.")
        return oneR
    }

    /// A resting limit entry with its stop and take in one normalTpsl group: the exchange arms them when the
    /// entry fills, so there is no moment with a position and no stop.
    private func placeLimit(_ p: Prepared, market: Market, limit: Decimal) async throws -> Opened {
        let long = p.intent.side == .long
        let px = HLAction.price(limit, szDecimals: market.szDecimals)
        let (stop, take) = Self.protectionPrices(entry: px, stopPct: p.intent.stopPct ?? 0, takePct: p.intent.takePct, long: long,
                                                 szDecimals: market.szDecimals)
        let entry = HLOrder(asset: market.index, isBuy: long, price: px, size: p.sizing.size, reduceOnly: false, kind: .limit(tif: "Gtc"))
        let action = try HLAction.order([entry] + Self.protectionOrders(asset: market.index, long: long, size: p.sizing.size, stop: stop, take: take,
                                                                         szDecimals: market.szDecimals), grouping: "normalTpsl")
        let reply = try await post(action, label: "limit with stop and take-profit")
        switch reply {
        case .resting, .ok:
            let orders = try await HyperliquidAccount.openOrders(wallet.evm).filter { $0.coin == market.name }
            guard orders.contains(where: { !$0.isTrigger && $0.limitPx == px }) else { throw ExecutionError("The limit isn't among open orders: \(reply).") }
            report("Limit placed: \(long ? "long" : "short") \(Fmt.num(p.sizing.size, maxFraction: market.szDecimals)) \(market.name) at \(Fmt.price(px)). Stop \(Fmt.price(stop))\(take.map { " and take-profit \(Fmt.price($0))" } ?? ""): active once it fills.")
            return Opened(asset: market.name, size: p.sizing.size, entry: px, stop: stop, take: take, pending: true)
        case .filled(let size, let avgPx):
            // The price was already there: the group armed its stop and take at once.
            try await verifyProtection(coin: market.name, stop: stop, take: take)
            report("The limit filled at once: \(Fmt.num(size, maxFraction: market.szDecimals)) \(market.name) at \(Fmt.price(avgPx)); stop and take-profit are on the exchange.")
            return Opened(asset: market.name, size: size, entry: avgPx, stop: stop, take: take)
        case .error(let e):
            throw ExecutionError("Limit rejected: \(e). No position.")
        }
    }

    // MARK: Close

    /// Cancels the asset's stop and take and closes the position at market. Returns a line for the user.
    public func close(asset: String) async throws -> String {
        let markets = try await Hyperliquid.markets()
        guard let market = markets[asset], market.index >= 0 else { throw ExecutionError("No \(asset) market.") }
        let triggers = try await HyperliquidAccount.openOrders(wallet.evm).filter { $0.coin == asset }
        if !triggers.isEmpty {
            _ = try await post(HLAction.cancel(triggers.map { (market.index, $0.oid) }), label: "cancel orders")
        }
        guard let position = try await HyperliquidAccount.positions(wallet.evm).first(where: { $0.coin == asset }), position.size != 0 else {
            let line = triggers.isEmpty ? "No open \(asset) position." : "\(asset) orders cancelled (\(triggers.count)); there was no position."
            report(line)
            return line
        }
        let buy = position.size < 0
        let px = HLAction.price(market.markPx * (buy ? 1 + 2 * Self.slippage : 1 - 2 * Self.slippage), szDecimals: market.szDecimals)
        let result = try await post(try HLAction.order([HLOrder(asset: market.index, isBuy: buy, price: px, size: abs(position.size),
                                                                reduceOnly: true, kind: .limit(tif: "Ioc"))]), label: "close")
        guard case .filled(let size, let avgPx) = result else { throw ExecutionError("The close didn't fill: \(result).") }
        let line = "\(asset) position closed: \(Fmt.num(size, maxFraction: market.szDecimals)) at \(Fmt.price(avgPx)); PnL before the close \(Fmt.usd(position.unrealizedPnl))."
        report(line)
        return line
    }

    /// sendAsset to our own address between perp balances — "" is the main one, "xyz" a HIP-3 exchange — then wait
    /// for the credit.
    public func moveMargin(from source: String, to dex: String, usdc: Decimal) async throws {
        func free() async throws -> Decimal {
            dex.isEmpty ? try await Hyperliquid.balance(user: wallet.evm).withdrawable : try await Hyperliquid.dexBalance(user: wallet.evm, dex: dex).withdrawable
        }
        let name = { (d: String) in d.isEmpty ? "the main balance" : d }
        let before = try await free()
        let action = HLSigner.sendAssetAction(destination: wallet.evm, sourceDex: source, destinationDex: dex,
                                              token: "USDC:0x6d1e7cde53ba9467b783cb7c530ce054", amount: try HLAction.number(usdc),
                                              nonce: nonce(), mainnet: true)
        guard case .map(let pairs) = action, case .uint(let n)? = pairs.first(where: { $0.0 == "nonce" })?.1 else { throw ExecutionError("No nonce.") }
        let signature = try await signer.signHyperliquidUser(action, recipients: [])
        try journal.append(.init(chain: "hyperliquid", id: "\(n)", kind: .signed, note: "sendAsset \(name(source)) → \(name(dex)) \(usdc)"))
        let reply = HLReply.parse(try await HLExchange.send(action: action, nonce: n, signature: signature, mainnet: true))
        try journal.append(.init(chain: "hyperliquid", id: "\(n)", kind: reply.isError ? .failed : .confirmed, note: "\(reply)"))
        guard !reply.isError else { throw ExecutionError("Transfer to \(name(dex)) rejected: \(reply).") }
        for _ in 0..<20 {
            if try await free() >= before + usdc * Decimal(string: "0.99")! {
                report("Margin on \(name(dex)): +\(Fmt.num(usdc)) USDC from \(name(source)).")
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ExecutionError("Transfer to \(name(dex)) wasn't credited within 10 s.")
    }

    // MARK: Manage

    /// Carries out a command about an open position. Returns a line for the user.
    public func manage(_ command: PositionCommand, asset: String) async throws -> String {
        switch command {
        case .cancelOrders, .close(1): return try await close(asset: asset)
        case .close(let fraction): return try await closePart(asset: asset, fraction: fraction)
        case .stopToBreakeven: return try await moveStop(asset: asset, to: nil)
        case .stopTo(let price): return try await moveStop(asset: asset, to: price)
        case .takeTo(let price): return try await moveTake(asset: asset, to: price)
        case .trail: throw ExecutionError("A trailing stop is kept by the ihatecrypto app, not placed on the exchange.")
        }
    }

    /// New take first, then the old one is cancelled.
    private func moveTake(asset: String, to target: Decimal) async throws -> String {
        let market = try await market(asset)
        guard let position = try await HyperliquidAccount.positions(wallet.evm).first(where: { $0.coin == asset && $0.size != 0 }) else {
            return "No open \(asset) position."
        }
        let long = position.size > 0
        let take = HLAction.price(target, szDecimals: market.szDecimals)
        guard long ? take > market.markPx : take < market.markPx else {
            throw ExecutionError("Take-profit \(Fmt.price(take)) is \(long ? "below" : "above") the current price \(Fmt.price(market.markPx)): it would trigger at once. To exit, type «close».")
        }
        let old = try await HyperliquidAccount.openOrders(wallet.evm).filter { $0.coin == asset && $0.isTrigger && ($0.orderType ?? "").contains("Take") }
        func worst(_ p: Decimal) -> Decimal { HLAction.price(p * (long ? 1 - Self.triggerSlippage : 1 + Self.triggerSlippage), szDecimals: market.szDecimals) }
        let order = HLOrder(asset: market.index, isBuy: !long, price: worst(take), size: abs(position.size), reduceOnly: true,
                            kind: .trigger(price: take, isMarket: true, tpsl: "tp"))
        let placed = try await post(try HLAction.order([order], grouping: "positionTpsl"), label: "new take-profit")
        if case .error(let e) = placed { throw ExecutionError("New take-profit rejected: \(e). The old one stays.") }
        let stale = old.filter { $0.triggerPx != take }
        if !stale.isEmpty { _ = try await post(HLAction.cancel(stale.map { (market.index, $0.oid) }), label: "cancel old take-profit") }
        let line = "Take-profit moved to \(Fmt.price(take))."
        report(line)
        return line
    }

    private func closePart(asset: String, fraction: Decimal) async throws -> String {
        let market = try await market(asset)
        guard let position = try await HyperliquidAccount.positions(wallet.evm).first(where: { $0.coin == asset && $0.size != 0 }) else {
            return "No open \(asset) position."
        }
        let size = HLAction.size(abs(position.size) * fraction, szDecimals: market.szDecimals)
        guard size > 0, size < abs(position.size) else { return try await close(asset: asset) }
        let buy = position.size < 0
        let px = HLAction.price(market.markPx * (buy ? 1 + 2 * Self.slippage : 1 - 2 * Self.slippage), szDecimals: market.szDecimals)
        let result = try await post(try HLAction.order([HLOrder(asset: market.index, isBuy: buy, price: px, size: size, reduceOnly: true,
                                                                kind: .limit(tif: "Ioc"))]), label: "partial close")
        guard case .filled(let filled, let avgPx) = result else { throw ExecutionError("The partial close didn't fill: \(result).") }
        let left = abs(position.size) - filled
        let line = "Closed \(Fmt.num(filled, maxFraction: market.szDecimals)) \(asset) at \(Fmt.price(avgPx)); \(Fmt.num(left, maxFraction: market.szDecimals)) left, stop and take-profit in place."
        report(line)
        return line
    }

    /// New stop first, then the old one is cancelled: the position is never without a stop.
    /// `to: nil` = breakeven: the entry plus both taker fees, so a stop-out costs nothing.
    private func moveStop(asset: String, to target: Decimal?) async throws -> String {
        let market = try await market(asset)
        guard let position = try await HyperliquidAccount.positions(wallet.evm).first(where: { $0.coin == asset && $0.size != 0 }) else {
            return "No open \(asset) position."
        }
        let long = position.size > 0
        let fees = position.entry * 2 * RiskCalc.takerFee
        let stop = HLAction.price(target ?? (long ? position.entry + fees : position.entry - fees), szDecimals: market.szDecimals)
        guard long ? stop < market.markPx : stop > market.markPx else {
            throw ExecutionError("Stop \(Fmt.price(stop)) is \(long ? "above" : "below") the current price \(Fmt.price(market.markPx)): it would trigger at once. To exit, type «close».")
        }
        let old = try await HyperliquidAccount.openOrders(wallet.evm).filter { $0.coin == asset && $0.isTrigger && ($0.orderType ?? "").contains("Stop") }
        let orders = Self.protectionOrders(asset: market.index, long: long, size: abs(position.size), stop: stop, take: nil, szDecimals: market.szDecimals)
        let placed = try await post(try HLAction.order(orders, grouping: "positionTpsl"), label: "new stop")
        if case .error(let e) = placed { throw ExecutionError("New stop rejected: \(e). The old one stays.") }
        try await verifyProtection(coin: asset, stop: stop, take: nil)
        let stale = old.filter { $0.triggerPx != stop }
        if !stale.isEmpty { _ = try await post(HLAction.cancel(stale.map { (market.index, $0.oid) }), label: "cancel old stop") }
        let line = target == nil
            ? "Stop at breakeven: \(Fmt.price(stop)) (entry \(Fmt.price(position.entry)) plus fees). The trade can no longer end in a loss, barring slippage."
            : "Stop moved to \(Fmt.price(stop))."
        report(line)
        return line
    }

    private func market(_ asset: String) async throws -> Market {
        guard let m = try await Hyperliquid.markets()[asset], m.index >= 0 else { throw ExecutionError("No \(asset) market.") }
        return m
    }

    // MARK: Hyperliquid

    private func nonce() -> UInt64 {
        lastNonce = max(UInt64(Date().timeIntervalSince1970 * 1000), lastNonce + 1)
        return lastNonce
    }

    /// Signs, journals before sending, sends, journals the reply.
    func post(_ action: MsgPack, label: String) async throws -> HLReply {
        let nonce = nonce()
        let signature = try await signer.signHyperliquid(action, nonce: nonce)
        try journal.append(.init(chain: "hyperliquid", id: "\(nonce)", kind: .signed, note: label))
        let data = try await HLExchange.send(action: action, nonce: nonce, signature: signature, mainnet: true)
        let reply = HLReply.parse(data)
        try journal.append(.init(chain: "hyperliquid", id: "\(nonce)", kind: reply.isError ? .failed : .confirmed, note: "\(reply)"))
        return reply
    }

    private func verifyProtection(coin: String, stop: Decimal, take: Decimal?) async throws {
        // The exchange lists new trigger orders within a moment; ask a few times.
        for attempt in 0..<5 {
            let triggers = try await HyperliquidAccount.openOrders(wallet.evm).filter { $0.coin == coin && $0.isTrigger }
            let prices = Set(triggers.compactMap(\.triggerPx))
            if prices.contains(stop), take.map(prices.contains) ?? true { return }
            if attempt < 4 { try await Task.sleep(for: .milliseconds(600)) }
        }
        throw ExecutionError("the stop isn't among open orders")
    }

    static func leverageAction(asset: Int, leverage: Int) -> MsgPack {
        .map([("type", .string("updateLeverage")), ("asset", .uint(UInt64(asset))), ("isCross", .bool(false)), ("leverage", .uint(UInt64(leverage)))])
    }

    static func protectionPrices(entry: Decimal, stopPct: Decimal, takePct: Decimal?, long: Bool, szDecimals: Int) -> (stop: Decimal, take: Decimal?) {
        let dir: Decimal = long ? 1 : -1
        let stop = HLAction.price(entry * (1 - dir * stopPct / 100), szDecimals: szDecimals)
        let take = takePct.map { HLAction.price(entry * (1 + dir * $0 / 100), szDecimals: szDecimals) }
        return (stop, take)
    }

    /// Stop and take as one positionTpsl group: reduce-only market triggers on the opposite side.
    static func protectionAction(asset: Int, long: Bool, size: Decimal, stop: Decimal, take: Decimal?, szDecimals: Int) throws -> MsgPack {
        try HLAction.order(protectionOrders(asset: asset, long: long, size: size, stop: stop, take: take, szDecimals: szDecimals), grouping: "positionTpsl")
    }

    static func protectionOrders(asset: Int, long: Bool, size: Decimal, stop: Decimal, take: Decimal?, szDecimals: Int) -> [HLOrder] {
        func worst(_ trigger: Decimal) -> Decimal {
            HLAction.price(trigger * (long ? 1 - triggerSlippage : 1 + triggerSlippage), szDecimals: szDecimals)
        }
        var orders = [HLOrder(asset: asset, isBuy: !long, price: worst(stop), size: size, reduceOnly: true,
                              kind: .trigger(price: stop, isMarket: true, tpsl: "sl"))]
        if let take {
            orders.append(HLOrder(asset: asset, isBuy: !long, price: worst(take), size: size, reduceOnly: true,
                                  kind: .trigger(price: take, isMarket: true, tpsl: "tp")))
        }
        return orders
    }

    // MARK: Bridge (Relay, Solana USDC → Hyperliquid perp or USDC on an EVM chain)

    /// The bridge transaction and the balance lines its simulation gives. `decimals` are the destination's;
    /// `topupGasUSD` adds that much native coin for gas on an EVM destination.
    /// `swap`: the destination is another token (Relay swaps on the way), so the cost is judged by USD in against USD out.
    func prepareBridge(_ amount: Bridge.Amount, to chain: UInt64 = Relay.Chain.hyperliquid, currency: String = Relay.Currency.hyperliquidUSDC,
                       decimals: Int = 8, topupGasUSD: Decimal? = nil, swap: Bool = false) async throws -> (step: BridgeStep, changes: [String]) {
        let usdcMint = Relay.Currency.solanaUSDC
        let (units, exactOutput): (UInt64, Bool) = switch amount {
        case .arrive(let v): (NSDecimalNumber(decimal: (v * Decimal(sign: .plus, exponent: decimals, significand: 1)).rounded(0, .up)).uint64Value, true)
        case .send(let v): (NSDecimalNumber(decimal: (v * 1_000_000).rounded(0, .down)).uint64Value, false)
        }
        let quote = try await Relay.quote(user: wallet.solana, recipient: wallet.evm, originChain: Relay.Chain.solana,
                                          destinationChain: chain, originCurrency: usdcMint,
                                          destinationCurrency: currency, amount: units, exactOutput: exactOutput, topupGasUSD: topupGasUSD)
        let binding = BindingGuard.check(["sender": quote.sender, "recipient": quote.recipient],
                                         expected: ["sender": wallet.solana, "recipient": wallet.evm], subject: "Relay quote")
        guard binding.ok else { throw ExecutionError(binding.problems.joined(separator: " ")) }
        guard let spendUnits = UInt64(quote.amountIn), spendUnits > 0 else { throw ExecutionError("Relay didn't give the amount to send.") }
        let spend = Decimal(spendUnits) / 1_000_000
        let arriving = Decimal(string: quote.amountOutFormatted) ?? 0
        // Hyperliquid charges once for opening an account and Relay passes it on as its gas. It's allowed on top of the
        // cap only while Hyperliquid says the account doesn't exist, and only up to $1.50 (measured 2026-09-28: $1.20).
        var opening: Decimal = 0
        if chain == Relay.Chain.hyperliquid, (try? await Hyperliquid.isNewAccount(wallet.evm)) == true {
            opening = min(Decimal(string: quote.relayerGasUSD) ?? 0, Decimal(string: "1.5")!)
        }
        // Bridge costs are capped: over what arrives (and the gas asked for) at most 3%, never more than $1; small bridges
        // may cost up to $0.15, Relay's floor for delivering gas (measured 2026-09-26: ≈ $0.10 on a $2 bridge to Base).
        let worth = swap ? Decimal(string: quote.amountOutUSD) ?? 0 : arriving
        guard spend - worth - (topupGasUSD ?? 0) - opening <= min(max(worth * Decimal(string: "0.03")!, Decimal(string: "0.15")!), 1) else {
            throw ExecutionError(swap ? "Relay's swap gives \(Fmt.usd(worth)) worth for \(Fmt.num(spend)) USDC: more lost than allowed."
                                      : "The Relay bridge wants \(Fmt.num(spend)) USDC for \(Fmt.num(arriving)): more than allowed.")
        }
        let have = try await rpc.tokenBalance(owner: wallet.solana, mint: usdcMint)
        guard have >= spendUnits else { throw ExecutionError("\(Fmt.num(Decimal(have) / 1_000_000)) USDC on Solana; the bridge needs \(Fmt.num(spend)).") }

        let (blockhash, lastValid) = try await rpc.latestBlockhash()
        let unsigned = SolanaTransaction.unsigned(try SolanaTransaction.compileMessage(quote.solanaInstructions, payer: wallet.solana, blockhash: blockhash))
        let message = try SolanaMessage.parse(transaction: unsigned)
        let myUSDC = try SPL.associatedAccount(owner: wallet.solana, mint: usdcMint)
        let owners = [myUSDC: wallet.solana]
        // Checked here for a readable reason and for the preview; the signer checks again on its own.
        var verdict = SolanaGuard.check(message, accounts: message.staticKeys, policy: SolanaPolicy(owner: wallet.solana), tokenOwners: owners)
        let solBefore = try await rpc.balance(wallet.solana)
        let simulation = try await rpc.simulate(unsigned, watch: [myUSDC, wallet.solana], sigVerify: false)
        // A failed simulation says nothing about balances: stop here rather than quote made-up changes.
        if let error = simulation.error { throw ExecutionError("The simulation failed, so nothing was signed: \(error)") }
        let usdcAfter = simulation.after[myUSDC]?.token ?? 0
        let solAfter = simulation.after[wallet.solana]?.lamports ?? 0
        verdict.merge(SolanaGuard.balances([
            .init(label: "USDC", before: Int64(have), after: Int64(usdcAfter), atLeast: -Int64(spendUnits)),
            .init(label: "lamports", before: Int64(solBefore), after: Int64(solAfter), atLeast: -5_000_000),
        ]))
        guard verdict.ok else { throw ExecutionError("The guard stopped the bridge: " + verdict.problems.joined(separator: " ")) }
        func usdc(_ u: UInt64) -> String { Fmt.num(Decimal(u) / 1_000_000, maxFraction: 6) }
        func sol(_ l: UInt64) -> String { Fmt.num(Decimal(l) / 1_000_000_000, maxFraction: 6) }
        var changes = [
            "Solana USDC: \(usdc(have)) → \(usdc(usdcAfter)) (−\(usdc(have - min(have, usdcAfter)))), simulated.",
            "Solana SOL: \(sol(solBefore)) → \(sol(solAfter)) (network fee), simulated.",
        ]
        if !quote.gasTopup.isEmpty { changes.append("Gas for the destination: +\(quote.gasTopup) ETH arrives with the USDC.") }
        return (BridgeStep(requestId: quote.requestId, unsigned: unsigned, accounts: message.staticKeys, tokenOwners: owners,
                           lastValid: lastValid, spend: spend, arriving: arriving, feesUSD: quote.feesUSD, chain: chain, opening: opening), changes)
    }

    func sendBridge(_ b: BridgeStep) async throws {
        let signed = try await signer.signSolana(b.unsigned, accounts: b.accounts, recipients: [], tokenOwners: b.tokenOwners)
        guard signed.count == b.unsigned.count, signed.subdata(in: 65..<signed.count) == b.unsigned.subdata(in: 65..<b.unsigned.count) else {
            throw ExecutionError("What was signed isn't what was checked.")
        }
        let signature = Base58.encode(signed.subdata(in: 1..<65))
        let toHyperliquid = b.chain == Relay.Chain.hyperliquid
        let hlBefore = toHyperliquid ? try await Hyperliquid.balance(user: wallet.evm).withdrawable : 0
        try journal.append(.init(chain: "relay", id: b.requestId, kind: .signed, note: "Solana USDC→\(toHyperliquid ? "Hyperliquid" : "chain \(b.chain)"), tx \(signature)"))
        try journal.append(.init(chain: "solana", id: signature, kind: .signed, note: "Relay deposit \(b.requestId); valid until block \(b.lastValid)"))
        let started = Date()
        _ = try await rpc.send(signed)
        switch try await rpc.waitForConfirmation(signature, lastValidBlockHeight: b.lastValid) {
        case .confirmed: try journal.append(.init(chain: "solana", id: signature, kind: .confirmed))
        case .failed(let e):
            try journal.append(.init(chain: "solana", id: signature, kind: .failed, note: e))
            throw ExecutionError("The bridge transaction failed: \(e). The money stayed on Solana.")
        case .expired:
            try journal.append(.init(chain: "solana", id: signature, kind: .expired))
            throw ExecutionError("The bridge transaction didn't make it into a block. The money stayed on Solana; you can retry.")
        }
        while Date().timeIntervalSince(started) < 180 {
            let status = try await Relay.status(requestId: b.requestId).status
            if status == "success" {
                try journal.append(.init(chain: "relay", id: b.requestId, kind: .settled, note: status))
                break
            }
            if ["refund", "failure"].contains(status) {
                try journal.append(.init(chain: "relay", id: b.requestId, kind: .failed, note: status))
                throw ExecutionError("Relay returned \(status). Check your Solana balance.")
            }
            try await Task.sleep(for: .seconds(1))
        }
        // An EVM destination: the caller waits for the tokens on its own chain.
        guard toHyperliquid else { return }
        // Wait for the credit itself: the trade needs it on the balance, not just in Relay's status.
        let target = hlBefore + b.arriving * Decimal(string: "0.99")!
        while Date().timeIntervalSince(started) < 240 {
            if try await Hyperliquid.balance(user: wallet.evm).withdrawable >= target {
                report("Bridge done in \(Int(Date().timeIntervalSince(started))) s: \(Fmt.num(b.arriving)) USDC on Hyperliquid. https://solscan.io/tx/\(signature)")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ExecutionError("Relay didn't credit the USDC within 4 minutes. Order \(b.requestId) is in the journal; the trade wasn't opened.")
    }
}

// MARK: - Replies and account state

/// What /exchange answered for one action (the first order status for order actions).
public enum HLReply: Equatable, Sendable, CustomStringConvertible {
    case ok
    case filled(size: Decimal, avgPx: Decimal)
    case resting
    case error(String)

    public var isError: Bool { if case .error = self { true } else { false } }

    public var description: String {
        switch self {
        case .ok: "ok"
        case .filled(let s, let p): "filled \(s) at \(p)"
        case .resting: "resting on the book"
        case .error(let e): e
        }
    }

    public static func parse(_ data: Data) -> HLReply {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .error(String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard j["status"] as? String == "ok" else { return .error("\(j["response"] ?? j)") }
        let statuses = ((j["response"] as? [String: Any])?["data"] as? [String: Any])?["statuses"] as? [Any] ?? []
        // Several statuses (stop and take): any error wins, otherwise the first one describes the action.
        for case let s as [String: Any] in statuses {
            if let e = s["error"] as? String { return .error(e) }
        }
        guard let first = statuses.first else { return .ok }
        if let f = (first as? [String: Any])?["filled"] as? [String: Any],
           let size = (f["totalSz"] as? String).flatMap({ Decimal(string: $0) }), let px = (f["avgPx"] as? String).flatMap({ Decimal(string: $0) }) {
            return .filled(size: size, avgPx: px)
        }
        if (first as? [String: Any])?["resting"] != nil { return .resting }
        return .ok
    }
}

public enum HyperliquidAccount {
    public struct Order: Decodable, Sendable, Equatable {
        public let coin: String
        public let oid: UInt64
        public let isTrigger: Bool
        public let triggerPx: Decimal?
        public let limitPx: Decimal?
        public let size: Decimal?
        /// "B" buy, "A" sell.
        public let side: String?
        /// "Limit", "Stop Market", "Take Profit Market"…
        public let orderType: String?

        enum CodingKeys: String, CodingKey { case coin, oid, isTrigger, triggerPx, limitPx, sz, side, orderType }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            coin = try c.decode(String.self, forKey: .coin)
            oid = try c.decode(UInt64.self, forKey: .oid)
            isTrigger = try c.decodeIfPresent(Bool.self, forKey: .isTrigger) ?? false
            triggerPx = try c.decodeIfPresent(String.self, forKey: .triggerPx).flatMap { Decimal(string: $0) }
            limitPx = try c.decodeIfPresent(String.self, forKey: .limitPx).flatMap { Decimal(string: $0) }
            size = try c.decodeIfPresent(String.self, forKey: .sz).flatMap { Decimal(string: $0) }
            side = try c.decodeIfPresent(String.self, forKey: .side)
            orderType = try c.decodeIfPresent(String.self, forKey: .orderType)
        }
    }

    public struct Position: Sendable, Equatable {
        public let coin: String
        /// Signed: negative for a short.
        public let size: Decimal
        public let entry: Decimal
        public let unrealizedPnl: Decimal
        public let liquidation: Decimal?
    }

    /// What the open positions lose if every stop fills; nil when some position has no stop.
    public static func riskAtStops(positions: [Position], orders: [Order]) -> Decimal? {
        var total: Decimal = 0
        for p in positions where p.size != 0 {
            let stops = orders.filter { $0.coin == p.coin && $0.isTrigger && ($0.orderType ?? "").contains("Stop") }.compactMap(\.triggerPx)
            // The stop that fills first is the one nearest the entry on the losing side.
            guard let stop = p.size > 0 ? stops.max() : stops.min() else { return nil }
            total += max(0, (p.size > 0 ? p.entry - stop : stop - p.entry) * abs(p.size))
        }
        return total
    }

    /// What the user has in a vault: its equity and what can be withdrawn now (lockups hold the rest).
    public static func vaultEquity(user: String, vault: String) async throws -> (equity: Decimal, withdrawable: Decimal, lockedUntil: Date?) {
        struct Row: Decodable { let vaultAddress: String; let equity: String; let lockedUntilTimestamp: Double? }
        let rows = try JSONDecoder().decode([Row].self, from: try await info(["type": "userVaultEquities", "user": user]))
        guard let row = rows.first(where: { $0.vaultAddress.lowercased() == vault.lowercased() }) else { return (0, 0, nil) }
        let equity = Decimal(string: row.equity) ?? 0
        let until = row.lockedUntilTimestamp.map { Date(timeIntervalSince1970: $0 / 1000) }
        let unlocked = (until ?? .distantPast) <= Date()
        return (equity, unlocked ? equity : 0, unlocked ? nil : until)
    }

    /// The latest fill that closed (part of) a position in `coin`: price and realised PnL.
    public static func lastClose(_ user: String, coin: String) async throws -> (price: Decimal, pnl: Decimal, time: Date)? {
        struct Fill: Decodable { let coin: String; let px: String; let closedPnl: String; let dir: String; let time: Double }
        let fills = try JSONDecoder().decode([Fill].self, from: try await info(["type": "userFills", "user": user]))
        guard let f = fills.filter({ $0.coin == coin && $0.dir.hasPrefix("Close") }).max(by: { $0.time < $1.time }) else { return nil }
        return (Decimal(string: f.px) ?? 0, Decimal(string: f.closedPnl) ?? 0, Date(timeIntervalSince1970: f.time / 1000))
    }

    /// Open orders on the main exchange and the HIP-3 ones LALA shows; coins are unique («xyz:CL»).
    public static func openOrders(_ user: String) async throws -> [Order] {
        var out: [Order] = []
        for dex in [nil] + Hyperliquid.hip3Dexes.map(Optional.some) {
            var body = ["type": "frontendOpenOrders", "user": user]
            body["dex"] = dex
            out += try JSONDecoder().decode([Order].self, from: try await info(body))
        }
        return out
    }

    /// Positions on the main exchange and the HIP-3 ones.
    public static func positions(_ user: String) async throws -> [Position] {
        var out: [Position] = []
        for dex in [nil] + Hyperliquid.hip3Dexes.map(Optional.some) { out += try await positions(user, dex: dex) }
        return out
    }

    static func positions(_ user: String, dex: String?) async throws -> [Position] {
        struct P: Decodable { let coin: String; let szi: String; let entryPx: String?; let unrealizedPnl: String; let liquidationPx: String? }
        struct Row: Decodable { let position: P }
        struct State: Decodable { let assetPositions: [Row] }
        var body = ["type": "clearinghouseState", "user": user]
        body["dex"] = dex
        let state = try JSONDecoder().decode(State.self, from: try await info(body))
        return state.assetPositions.map { r in
            Position(coin: r.position.coin, size: Decimal(string: r.position.szi) ?? 0, entry: Decimal(string: r.position.entryPx ?? "") ?? 0,
                     unrealizedPnl: Decimal(string: r.position.unrealizedPnl) ?? 0, liquidation: r.position.liquidationPx.flatMap { Decimal(string: $0) })
        }
    }

    static func info(_ body: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.hyperliquid.xyz/info")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await URLSession.shared.data(for: request).0
    }
}
