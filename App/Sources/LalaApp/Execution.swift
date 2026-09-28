import DeFiYields
import EVMChain
import ExecutionCore
import Foundation
import GuardJev
import HyperliquidSigning
import LalaCore
import SignerAPI
import SwiftUI
import TradeExecution
@preconcurrency import UserNotifications
import WalletCore

/// The app's side of signing: every request goes to the signing process, which runs the guard itself.
/// Signatures waiting on the signer right now: while there are any, the running move's card asks for Touch ID.
@MainActor @Observable
final class SignerActivity {
    static let shared = SignerActivity()
    var waiting = 0
}

nonisolated struct XPCTradeSigner: TradeSigner {
    /// Counts the signature while the signer has it: Touch ID or the password may be up, and the canvas says so.
    private static func signing<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        await MainActor.run { SignerActivity.shared.waiting += 1 }
        defer { Task { @MainActor in SignerActivity.shared.waiting -= 1 } }
        return try await body()
    }

    func signSolana(_ wire: Data, accounts: [String], recipients: [String], tokenOwners: [String: String]) async throws -> Data {
        let reply = try await Self.signing { try await SignerClient().send(.signSolana(wire: wire, accounts: accounts, recipients: recipients, tokenOwners: tokenOwners)) }
        guard reply.ok, let signed = reply.signedWire else { throw ExecutionError(Self.reason(reply)) }
        return signed
    }

    func signHyperliquid(_ action: MsgPack, nonce: UInt64) async throws -> EVMSignature {
        let reply = try await Self.signing { try await SignerClient().send(.signHyperliquidL1(action: action, nonce: nonce, mainnet: true)) }
        guard reply.ok, let signature = reply.signature else { throw ExecutionError(Self.reason(reply)) }
        return signature
    }

    func signHyperliquidUser(_ action: MsgPack, recipients: [String]) async throws -> EVMSignature {
        let reply = try await Self.signing { try await SignerClient().send(.signHyperliquidUser(action: action, mainnet: true, recipients: recipients)) }
        guard reply.ok, let signature = reply.signature else { throw ExecutionError(Self.reason(reply)) }
        return signature
    }

    func signRelayMapping(wallet: String, depositor: String, id: Data, nonce: UInt64) async throws -> EVMSignature {
        let reply = try await Self.signing { try await SignerClient().send(.signRelayNonceMapping(wallet: wallet, depositor: depositor, id: id, nonce: nonce)) }
        guard reply.ok, let signature = reply.signature else { throw ExecutionError(Self.reason(reply)) }
        return signature
    }

    func signEVM(chainId: UInt64, nonce: UInt64, maxPriorityFee: UInt64, maxFee: UInt64, gasLimit: UInt64,
                 to: String, data: Data, recipients: [String]) async throws -> Data {
        let reply = try await Self.signing { try await SignerClient().send(.signEVMTransaction(chainId: chainId, nonce: nonce, maxPriorityFee: maxPriorityFee, maxFee: maxFee,
                                                                      gasLimit: gasLimit, to: to, value: 0, data: data, recipients: recipients)) }
        guard reply.ok, let raw = reply.signedRaw else { throw ExecutionError(Self.reason(reply)) }
        return raw
    }

    func signNearIntentDeposit(amount: UInt128, depositAddress: String, nonce: UInt64, blockHash: Data) async throws -> Data {
        let reply = try await Self.signing { try await SignerClient().send(.signNearIntentDeposit(amount: "\(amount)", depositAddress: depositAddress, nonce: nonce, blockHash: blockHash)) }
        guard reply.ok, let raw = reply.signedRaw else { throw ExecutionError(Self.reason(reply)) }
        return raw
    }

    func signNearTransfer(amount: UInt128, receiver: String, recipients: [String], nonce: UInt64, blockHash: Data) async throws -> Data {
        let reply = try await Self.signing { try await SignerClient().send(.signNearTransfer(amount: "\(amount)", receiver: receiver, recipients: recipients, nonce: nonce, blockHash: blockHash)) }
        guard reply.ok, let raw = reply.signedRaw else { throw ExecutionError(Self.reason(reply)) }
        return raw
    }

    func signNearDeleteAccount(beneficiary: String, recipients: [String], nonce: UInt64, blockHash: Data) async throws -> Data {
        let reply = try await Self.signing { try await SignerClient().send(.signNearDeleteAccount(beneficiary: beneficiary, recipients: recipients, nonce: nonce, blockHash: blockHash)) }
        guard reply.ok, let raw = reply.signedRaw else { throw ExecutionError(Self.reason(reply)) }
        return raw
    }

    static func reason(_ reply: SignerReply) -> String {
        ([reply.error ?? "The signer refused."] + reply.problems).joined(separator: " ")
    }
}

extension Workspace {
    /// Balances and previews work with any addresses; signing needs the key in the signing process.
    var previewWallet: TradeWallet? {
        signerWallet ?? (isSolanaAddress(solanaAddress) && isEVMAddress(hlAddress) ? TradeWallet(solana: solanaAddress, evm: hlAddress) : nil)
    }

    var planIsReady: Bool {
        !blocks.isEmpty && blocks.allSatisfy { [.ready, .warning, .info].contains($0.status) }
    }

    func executor(_ wallet: TradeWallet) -> Executor {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "LALA")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Executor(wallet: wallet, signer: XPCTradeSigner(), journal: Journal(url: folder.appending(path: "journal.jsonl"))) { [weak self] text in
            Task { @MainActor in
                self?.reply(text, note: "execution")
                self?.runningAction?.lines.append(text)
            }
        }
    }

    /// The plan in a few plain lines for Jev: it judged short summaries reliably and long block text poorly.
    var planLines: [String] {
        let intent = resolved.intent
        let e = evaluation
        var out = ["\(intent.side == .long ? "Long" : "Short") \(intent.asset) on Hyperliquid, leverage \(Fmt.num(intent.leverage ?? 1))×."]
        if let s = e.sizing {
            out.append("Size \(Fmt.num(s.size, maxFraction: 6)) \(intent.asset) at ≈ \(Fmt.price(s.entry)), notional \(Fmt.usd(s.notional)), margin \(Fmt.usd(s.margin)).")
            out.append("Stop \(Fmt.pct(intent.stopPct ?? 0)) → \(Fmt.price(s.stopPrice)), loss ≈ \(Fmt.usd(s.lossAtStopUSD)) (risk \(Fmt.usd(intent.riskUSD ?? 0))).")
            if let t = s.takePrice { out.append("Take-profit \(Fmt.pct(intent.takePct ?? 0)) → \(Fmt.price(t)), profit ≈ \(Fmt.usd(s.profitAtTakeUSD ?? 0)).") }
        }
        if !resolved.notes.isEmpty { out.append("The user asked to fill in the rest by the rules: " + resolved.notes.joined(separator: " ")) }
        if let a = intent.amountUSDC { out.append("Move \(Fmt.num(a)) USDC from Solana to Hyperliquid.") }
        else if let q = quote { out.append("Bridge \(q.provider): \(Fmt.num(q.amountIn)) USDC from Solana to Hyperliquid.") }
        return out
    }

    /// Jev reads each ready plan against the user's words. It can only warn.
    func reviewPlan() async {
        guard planIsReady, intent != reviewedIntent || planReview == nil else { return }
        guard jevScreening, let key = openRouterKey else {
            planReview = nil
            jevNote = jevScreening ? "Jev isn't connected: sign in to OpenRouter in Settings. Only code checks apply." : nil
            return
        }
        reviewedIntent = intent
        let requests = messages.filter(\.fromUser).map(\.text)
        do {
            planReview = try await JevReviewer.plan(requests: requests, plan: planLines, apiKey: key)
            jevNote = nil
        } catch {
            planReview = nil
            jevNote = "Jev is unavailable: \(error.localizedDescription). Only code checks apply."
        }
    }

    /// Fresh quote, the bridge transaction and its simulation, and Jev's reading of all of it. Nothing is signed.
    func prepareExecution() async {
        guard let wallet = previewWallet else { return }
        if let missing = missingTradingKey { executionError = missing; return }
        preparing = true
        executionError = nil
        txReview = nil
        defer { preparing = false }
        do {
            let p = try await executor(wallet).prepare(intent, policy: policy)
            prepared = p
            if jevScreening, let key = openRouterKey {
                txReview = try? await JevReviewer.transactions(plan: planLines, signatures: p.steps, changes: p.changes, apiKey: key)
            }
        } catch {
            prepared = nil
            executionError = error.localizedDescription
        }
    }

    func confirmExecution() async {
        guard let p = prepared, let wallet = signerWallet else { return }
        guard p.isFresh else {
            // The bridge transaction's blockhash is about to expire: show fresh numbers and ask again.
            await prepareExecution()
            executionError = "Numbers refreshed: the confirmation was older than 45 seconds."
            return
        }
        // The signature gets its own activity, with the plan exactly as it was signed.
        let signedPlan = canvasBubbles()
        beginActivity(.execution, title: "Signed: \(p.intent.side == .long ? "long" : "short") \(IntentParser.pretty(p.market.name))", coin: p.market.name)
        updateActivity { $0.bubbles = signedPlan?.bubbles ?? []; $0.lines = p.steps }
        prepared = nil
        executing = true
        defer { executing = false }
        do {
            let opened = try await executor(wallet).execute(p)
            executed = intent
            // Always replaced: rules left from an earlier position in the same coin must not steer this one.
            let partial = opened.partialTake != nil || (opened.pending && p.intent.partialTake == true)
            if partial || p.intent.trailingPct != nil {
                var rules = ExitRules(openedSize: opened.size, entry: opened.entry, long: p.intent.side == .long,
                                      breakevenAfterPartial: partial, trailingPct: p.intent.trailingPct)
                rules.partialOrderPending = opened.pending && p.intent.partialTake == true
                exitRules[opened.asset] = rules
            } else {
                exitRules[opened.asset] = nil
            }
            reply("Done: \(opened.asset) \(Fmt.num(opened.size, maxFraction: 6)) at \(Fmt.price(opened.entry)), stop \(Fmt.price(opened.stop))\(opened.take.map { ", take-profit \(Fmt.price($0))" } ?? "").")
        } catch {
            reply("Execution stopped: \(error.localizedDescription)")
        }
        await refresh()
    }

    /// After execution «take closer» or «stop 2%» are about the open position: its orders move on the exchange
    /// instead of a new plan starting. Only stop and take may change; anything else is a new plan.
    func editExecuted(from before: TradeIntent, to next: TradeIntent) async -> Bool {
        guard let p = positions.first(where: { $0.coin == before.asset }) else { return false }
        var same = next
        same.stopPct = before.stopPct; same.takePct = before.takePct; same.takeR = before.takeR
        guard same == before, next != before else { return false }
        let long = p.size > 0
        let dir: Decimal = long ? 1 : -1
        let resolvedNext = Plan.resolve(next, market: market, equity: equity, policy: policy).intent
        if let stopPct = resolvedNext.stopPct, stopPct != before.stopPct {
            let stop = p.entry * (1 - dir * stopPct / 100)
            // A wider stop may not break the per-trade limit.
            let loss = abs(p.entry - stop) * abs(p.size) + abs(p.size) * (p.entry + stop) * RiskCalc.takerFee
            if let equity, equity > 0, loss / equity * 100 > policy.maxRiskPct {
                reply("A \(Fmt.pct(stopPct)) stop means −\(Fmt.usd(loss)), \(Fmt.pct((loss / equity * 100).rounded(1, .plain))) of capital. The rule: at most \(Fmt.pct(policy.maxRiskPct)). Stop not moved.")
                return true
            }
            await manage(.stopTo(stop), coin: p.coin)
        }
        if let takePct = resolvedNext.takePct, takePct != before.takePct {
            await manage(.takeTo(p.entry * (1 + dir * takePct / 100)), coin: p.coin)
        }
        intent = next
        executed = next
        return true
    }

    /// «withdraw to Solana», «put 1 USDC in the vault», «take it out of the vault».
    /// `confirmed`: the user said «do it» after the allocation plan.
    func move(_ command: WalletCommand, confirmed: Bool = false) async {
        guard let wallet = signerWallet else {
            reply("Transfers work in LALA.app once the key is in secure storage.")
            return
        }
        if case .yields(let asset) = command {
            // Read-only: the rates are drawn on the canvas.
            yieldOptions = await Yields.options(for: asset)
            // Aave on Base, from the pool itself: LALA bridges there and supplies with «lend N USDC on Aave».
            if asset != "SOL", aaveAPY == nil { aaveAPY = try? await AaveV3.verifyBase() }
            if asset != "SOL", let apy = aaveAPY {
                yieldOptions?.append(Yields.Option(asset: "USDC", place: "Aave · Base", apy: apy, tvlUSD: nil, how: "lend 2 USDC on Aave",
                                                   note: "on Base: bridged from Solana with a little ETH for gas"))
                yieldOptions?.sort { $0.apy > $1.apy }
            }
            reply(yieldOptions?.isEmpty == false ? "Rates are on the canvas — the bigger the bubble, the higher the rate." : "Yield sources didn't respond right now.", note: "DeFi")
            return
        }
        // The route as confirmed, before any balance moves: the canvas keeps it with the outcome and the time.
        let confirmedRoute = route(command)
        func finish(_ ok: Bool) {
            runningAction = nil
            guard movesMoney(command, confirmed: confirmed) else { return }
            finishedAction = (confirmedRoute?.title ?? readable(Self.canvasTitle(command)), CanvasOutcome(at: Date(), ok: ok), confirmedRoute?.steps ?? [])
            // The outcome board comes from the saved canvas: save now, not after the balance refresh that follows,
            // or the canvas stays blank for those seconds.
            saveCanvas()
        }
        if movesMoney(command, confirmed: confirmed) {
            withAnimation(StudioView.spring) {
                runningAction = (confirmedRoute?.title ?? readable(Self.canvasTitle(command)), confirmedRoute?.steps ?? [], [], Date())
            }
        }
        switch command {
        case .schedule, .stopSchedules: break
        default:
            executing = true
        }
        defer { executing = false; runningAction = nil }
        do {
            let e = executor(wallet)
            switch command {
            case .withdrawToSolana(let usdc): _ = try await e.withdrawToSolana(usdc: usdc)
            case .lendDeposit(let symbol, let amount): _ = try await e.lend(symbol, amount: amount, deposit: true)
            case .lendWithdraw(let symbol, let amount): _ = try await e.lend(symbol, amount: amount, deposit: false)
            case .kamino(let deposit, let symbol, let amount): _ = try await e.kamino(symbol, amount: amount, deposit: deposit)
            case .stake(let sol): _ = try await e.convert(from: SpotAsset.all[0], to: .jitoSOL, amount: sol)
            case .unstake(let jito): _ = try await e.convert(from: .jitoSOL, to: SpotAsset.all[0], amount: jito)
            case .yields: break   // drawn on the canvas above
            case .hlp(let deposit, let amount): _ = try await e.hlp(deposit: deposit, amount: amount)
            case .buyNear(let usdc):
                // The NEAR address comes from the signer alone; the first time it unlocks the seed to derive it.
                guard let account = try await SignerClient().send(.nearAddress).nearAddress else { throw ExecutionError("The signer has no NEAR address.") }
                nearAddress = account
                reply(try await e.buyNear(usdc: usdc ?? 0, account: account), note: "NEAR Intents · 1Click")
            case .sellNear(let amount):
                guard let account = try await SignerClient().send(.nearAddress).nearAddress else { throw ExecutionError("The signer has no NEAR address.") }
                reply(try await e.sellNear(amount: amount, account: account), note: "NEAR Intents · 1Click")
            case .sendNear(let name, let amount):
                guard let entry = savedAddress(name, on: .near) else { throw ExecutionError("There’s no NEAR address “\(name)” in Addresses.") }
                guard let account = try await SignerClient().send(.nearAddress).nearAddress else { throw ExecutionError("The signer has no NEAR address.") }
                reply(try await e.sendNear(amount, to: entry.address, account: account, label: entry.name), note: "NEAR")
                markSent(entry)
            case .closeNear(let name):
                guard let entry = savedAddress(name, on: .near) else { throw ExecutionError("There’s no NEAR address “\(name)” in Addresses.") }
                guard let account = try await SignerClient().send(.nearAddress).nearAddress else { throw ExecutionError("The signer has no NEAR address.") }
                reply(try await e.closeNear(into: entry.address, account: account, label: entry.name), note: "NEAR")
                markSent(entry)
            case .sendSol(let name, let amount):
                guard let entry = savedAddress(name, on: .solana) else { throw ExecutionError("There’s no Solana address “\(name)” in Addresses.") }
                reply(try await e.sendSOL(amount, to: entry.address, label: entry.name), note: "Solana")
                markSent(entry)
            case .aave(let deposit, let amount): reply(try await e.aave(deposit: deposit, usdc: amount), note: "Aave · Base")
            case .morpho(let deposit, let amount): reply(try await e.morpho(deposit: deposit, usdc: amount), note: "Morpho · Base")
            case .baseToSolana(let amount): reply(try await e.baseToSolana(usdc: amount), note: "Relay · Base → Solana")
            case .arbitrumToSolana(let amount): reply(try await e.evmToSolana(.arbitrum, usdc: amount), note: "Relay · Arbitrum → Solana")
            case .buyStock(let symbol, let usdc):
                reply(try await e.buyStock(symbol, usdc: usdc ?? 0), note: "Robinhood Chain · Uniswap")
                // A token bought by its contract shows among the favorites, with what the wallet holds of it.
                if !symbol.hasPrefix("0x") { rememberStock(symbol) }
                else if favoriteTokens.contains(where: { $0.address.lowercased() == symbol.lowercased() }) { await loadRobinhood() }
                else { await tokenCommand(.favorite(address: symbol, chain: "robinhood")); await loadRobinhood() }
            case .sellStock(let symbol, let amount): reply(try await e.sellStock(symbol, amount: amount), note: "Robinhood Chain · Uniswap")
            case .robinhoodToSolana(let amount): reply(try await e.evmToSolana(.robinhood, usdc: amount), note: "Relay · Robinhood → Solana")
            case .solanaTo(let place, let amount):
                let net: EVMNetwork = place == "base" ? .base : place == "arbitrum" ? .arbitrum : .robinhood
                reply(try await e.solanaToEVM(net, usdc: amount ?? 0), note: "Relay · Solana → \(net.name)")
            case .sendTo(let name, let amount): prepareTransfer(amount, to: name)
            case .receive: showReceive = true
            case .allocate(let symbol, let share):
                // Two steps: the plan first, the deposits only after «do it».
                let (_, ready, preview) = try await e.allocate(symbol, maxShare: share ?? 50, execute: confirmed)
                pendingAllocation = ready ? command : nil
                allocationPreview = confirmed ? nil : preview
                if !confirmed {
                    reply(ready ? "The plan is on the canvas. Sign it, or ask for another limit, e.g. “max \(share.map { $0 == 70 ? 50 : 70 } ?? 70)% per protocol”." : "Nowhere to put it now — see the canvas.", note: "DeFi")
                }
            case .rebalance(let share):
                // Like «spread»: the plan first, the moves only after «do it».
                let (_, ready, plan) = try await e.rebalance(maxShare: share ?? 50, execute: confirmed)
                pendingAllocation = ready ? command : nil
                if canvasID == nil { saveCanvas() }   // a new canvas gets its id on its first save: the card belongs to it
                rebalancePlan = confirmed ? nil : (canvasID, plan, share ?? 50)
                if !confirmed {
                    reply(ready ? "The moves are on the canvas with their math. Sign them, or ask for another limit, e.g. “rebalance, max \(share.map { $0 == 70 ? 50 : 70 } ?? 70)% per protocol”."
                                : plan.notes.first ?? "Nothing worth moving now — see the canvas.", note: "DeFi")
                }
            case .schedule(let asset, let usdc, let days):
                // The per-purchase rule applies to each run; a schedule adds up, so it is shown per month too.
                schedules.removeAll { $0.symbol == asset.symbol }
                schedules.append(Schedule(symbol: asset.symbol, usdc: usdc, days: days, next: Date()))
                let monthly = usdc * Decimal(30) / Decimal(days)
                reply("Scheduled purchases: \(asset.symbol) for \(Fmt.usd(usdc)) \(days == 1 ? "daily" : days == 7 ? "weekly" : "every \(days) days") — ≈ \(Fmt.usd(monthly)) a month. The first one is now. Runs while LALA is open; each purchase goes through the same checks and signing.")
                await runSchedules()
                return
            case .stopSchedules:
                let n = schedules.count
                schedules = []
                reply(n == 0 ? "There were no scheduled purchases." : "Scheduled purchases stopped (\(n)).")
                return
            case .buy(let asset, let usdc): _ = try await e.swap(asset, buy: true, amount: usdc, equity: equity)
            case .sell(let asset, let amount): _ = try await e.swap(asset, buy: false, amount: amount)
            }
            finish(true)
        } catch {
            reply("Failed: \(error.localizedDescription)")
            finish(false)
        }
        await refresh()
    }

    private func movesMoney(_ command: WalletCommand, confirmed: Bool) -> Bool {
        switch command {
        case .yields, .sendTo, .receive, .schedule, .stopSchedules: false
        case .allocate, .rebalance: confirmed
        default: true
        }
    }

    /// A move that can't go through with what the wallet holds is said so at once, instead of a card whose Confirm
    /// could only fail («Sell 0 NEAR»).
    func refusalBeforeCard(_ command: WalletCommand) -> String? {
        switch command {
        case .sellNear(let asked):
            // What a sale keeps on the account while it is sent: storage and prepaid gas (sellNearRoute, intentDepositOverhead).
            let sellable = max(0, near - Decimal(string: "0.09")!)
            let amount = asked ?? sellable
            guard amount < Decimal(string: "0.05")! || amount > sellable else { return nil }
            return "You have \(Fmt.num(near, maxFraction: 4)) NEAR. A sale needs at least 0.05 NEAR, and ≈ 0.09 NEAR stays on the account for storage and gas while it is sent, so \(sellable < Decimal(string: "0.05")! ? "there is nothing to sell now" : "at most \(Fmt.num(sellable, maxFraction: 4)) NEAR can be sold")."
        default:
            return nil
        }
    }

    /// «Buy the token 0x… for 2 USDC on Robinhood Chain»: the summary as a canvas title.
    static func canvasTitle(_ command: WalletCommand) -> String { command.summary.prefix(1).uppercased() + command.summary.dropFirst() }

    func manage(_ command: PositionCommand, coin: String) async {
        if let missing = missingTradingKey { reply(missing); return }
        updateActivity { a in
            a.coin = coin
            if a.title == nil { a.title = "\(IntentParser.pretty(coin)): \(Self.describe(command))" }
            if a.bubbles.isEmpty { a.bubbles = [ActivityBubble(kind: "position", label: "Position · Hyperliquid", title: Self.describe(command), asset: coin)] }
        }
        guard let wallet = signerWallet else {
            reply("Managing a position works in LALA.app once the key is in secure storage.")
            return
        }
        if case .trail(let pct) = command {
            guard let p = positions.first(where: { $0.coin == coin }) else { reply("There is no open \(IntentParser.pretty(coin)) position to trail."); return }
            var rules = exitRules[coin] ?? ExitRules(openedSize: abs(p.size), entry: p.entry, long: p.size > 0, breakevenAfterPartial: false, trailingPct: nil)
            rules.trailingPct = pct
            exitRules[coin] = rules
            reply("LALA now keeps the \(IntentParser.pretty(coin)) stop \(Fmt.pct(pct)) behind the best price and only ever tightens it — while LALA is open or in the menu bar.")
            await guardPositions()
            return
        }
        executing = true
        defer { executing = false }
        do { _ = try await executor(wallet).manage(command, asset: coin) } catch { reply("Failed: \(error.localizedDescription)") }
        await refresh()
    }

    /// The card shows the position instead of a plan: just executed, or a position in this asset is already open
    /// (after a restart too). One plan per asset: the rest is done with position commands.
    var managesPosition: Bool { executed == intent || positions.contains { $0.coin == intent.asset } }

    /// The market picker: sets the plan's instrument as if the user had typed it.
    func choose(_ market: Market) async {
        guard market.name != intent.asset else { return }
        let before = intent
        intent.asset = market.name
        reply("Market: \(IntentParser.pretty(market.name)) · Hyperliquid\(market.dex.map { " \($0)" } ?? "") — \(market.group.rawValue.lowercased()). " + (intent.changes(from: before).isEmpty ? "" : "Plan recalculated.") + outcomeLine)
        await refreshQuote()
        await reviewPlan()
    }

    /// Markets of one group, most traded first.
    func markets(_ group: Market.Group, limit: Int) -> [Market] {
        Array(markets.values.filter { $0.group == group }.sorted { $0.volume24h > $1.volume24h }.prefix(limit))
    }

    /// «Lock — Touch ID again»: the next signature asks for Touch ID, and orders stop going through the trading key.
    func lockSigner() async {
        guard SignerClient.isAvailable else { return }
        let ok = (try? await SignerClient().send(.lock))?.ok ?? false
        await loadSigner()
        reply(ok ? "🔒 Locked. The next signature asks for Touch ID, and the trading key is paused — resume it from the profile menu."
                 : "Couldn’t reach the signing process to lock it.")
    }

    /// Turns the paused trading key back on; the signer asks for Touch ID first.
    func resumeTradingKey() async {
        do {
            let r = try await SignerClient().send(.setAgentActive(true))
            await loadSigner()
            reply(r.ok && r.agentActive == true ? "Trading key on again: orders skip Touch ID, withdrawals still need it." : "The trading key stayed off.")
        } catch {
            reply("The trading key stayed off: \(error.localizedDescription)")
        }
    }

    /// The signer makes an agent key and signs its approval with the main key; the approval goes to Hyperliquid,
    /// and only when the exchange accepts it do orders switch to the agent.
    func enableAgent() async {
        executing = true
        defer { executing = false }
        do {
            let answer = try await SignerClient().send(.enableAgent)
            guard answer.ok, let action = answer.action, let signature = answer.signature, let nonce = answer.nonce, let agent = answer.agentAddress else {
                throw ExecutionError(XPCTradeSigner.reason(answer))
            }
            let result = HLReply.parse(try await HLExchange.send(action: action, nonce: nonce, signature: signature, mainnet: true))
            guard !result.isError else { throw ExecutionError("Hyperliquid rejected the agent: \(result).") }
            _ = try await SignerClient().send(.setAgentActive(true))
            await loadSigner()
            reply("Trading key on: \(agent.prefix(10))…. Orders, stops and closes now skip Touch ID; this key can't withdraw money — withdrawals still go through the main key.")
        } catch {
            reply("Trading key not turned on: \(error.localizedDescription)")
        }
    }

    /// The app-long loop: refresh, exit rules, regular purchases. Faster while exit rules exist, so a trailing
    /// stop does not lag a minute behind the price.
    func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(exitRules.isEmpty && alerts.isEmpty ? 30 : 10))
            await refresh()
            checkAlerts()
            await guardPositions()
            await runSchedules()
        }
    }

    /// Due regular purchases, one run each; the next date moves on even after a failure, so it does not retry in a loop.
    func runSchedules() async {
        guard let wallet = signerWallet, !executing else { return }
        for index in schedules.indices where schedules[index].next <= Date() {
            guard let asset = schedules[index].asset else { continue }
            let usdc = schedules[index].usdc
            schedules[index].advance()
            executing = true
            do {
                let line = try await executor(wallet).swap(asset, buy: true, amount: usdc, equity: equity)
                notify("LALA: \(asset.symbol) purchase", line)
            } catch {
                reply("Scheduled \(asset.symbol) purchase failed: \(error.localizedDescription). Next one: \(Fmt.date(schedules[index].next)).")
            }
            executing = false
        }
    }

    /// Runs after each refresh while the app is open: breakeven after the partial take, trailing stops.
    func guardPositions() async {
        guard signerWallet != nil, !executing else { return }
        // Rules live exactly as long as their position (or its waiting limit), however it was closed.
        for coin in exitRules.keys where !positions.contains(where: { $0.coin == coin }) && !orders.contains(where: { $0.coin == coin && !$0.isTrigger }) {
            exitRules[coin] = nil
        }
        for (coin, var rules) in exitRules {
            guard let p = positions.first(where: { $0.coin == coin }), let mark = markets[coin]?.markPx else { continue }
            if rules.partialOrderPending, let wallet = signerWallet {
                // The limit filled: the half at 1R goes on now, sized from the real fill.
                rules.partialOrderPending = false
                rules.openedSize = abs(p.size)
                rules.entry = p.entry
                rules.peak = p.entry
                exitRules[coin] = rules
                _ = try? await executor(wallet).addPartialTake(asset: coin)
                continue
            }
            let stop = orders.first { $0.coin == coin && $0.isTrigger && ($0.orderType ?? "").contains("Stop") }?.triggerPx
            let action = Guardian.step(&rules, size: p.size, stop: stop, mark: mark)
            exitRules[coin] = rules
            switch action {
            case .stopToBreakeven?: await manage(.stopToBreakeven, coin: coin); notify("Partial profit taken on \(coin)", "Stop moved to breakeven.")
            case .stopTo(let price)?: await manage(.stopTo(price), coin: coin)
            case nil: break
            }
        }
    }

    /// A position closed outside LALA (its stop or take, or by hand elsewhere): say so in the chat and as a notification.
    func closedByExchange(_ coin: String) async {
        exitRules[coin] = nil
        guard let close = try? await HyperliquidAccount.lastClose(hlAddress, coin: coin), Date().timeIntervalSince(close.time) < 600 else { return }
        // HyperCore fills do not say whether a trigger or a person closed it; only that it was not LALA.
        let text = "\(coin) position closed outside LALA (stop, take-profit or by hand) at \(Fmt.price(close.price)): \(close.pnl >= 0 ? "profit" : "loss") \(Fmt.usd(abs(close.pnl)))."
        reply(text, note: "exchange")
        notify("LALA: \(coin)", text)
    }

    /// «stop to breakeven», «close half» — for the history.
    static func describe(_ command: PositionCommand) -> String {
        switch command {
        case .close(let share): share >= 1 ? "close" : "close \(Fmt.num(share * 100, maxFraction: 0))%"
        case .stopToBreakeven: "stop to breakeven"
        case .stopTo(let px): "stop to \(Fmt.price(px))"
        case .takeTo(let px): "take-profit to \(Fmt.price(px))"
        case .trail(let pct): "trail the stop \(Fmt.pct(pct))"
        case .cancelOrders: "cancel orders"
        }
    }

    func notify(_ title: String, _ body: String) {
        // What LALA did on its own (guardian, schedules) is an activity too.
        beginActivity(.automatic, title: title)
        updateActivity { $0.lines.append(body) }
        // Asked the first time something actually happens, never at launch. Needs an app bundle:
        // the `swift run` build has none and would crash, so there the chat line is all.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func closePosition() async {
        guard let wallet = signerWallet, let coin = position?.coin ?? pendingEntry?.coin else { return }
        executing = true
        defer { executing = false }
        do { _ = try await executor(wallet).close(asset: coin) } catch { reply("Couldn't close: \(error.localizedDescription)") }
        await refresh()
    }
}

/// What the wallet will sign and what happens to each balance, before anything is signed.
struct ConfirmSheet: View {
    @Environment(Workspace.self) private var ws
    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 22, weight: .heavy))
                    if let p = ws.prepared {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("numbers refreshed \(Int(context.date.timeIntervalSince(p.preparedAt))) s ago · after 45 s they are recalculated")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if ws.prepared != nil {
                    Text(concern ? "check the warning" : "all checks passed").font(.caption.weight(.semibold))
                        .foregroundStyle(concern ? Color.orange : Brand.profit)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill((concern ? Color.orange : Brand.profit).opacity(0.12)))
                }
            }
            if let p = ws.prepared {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WHAT WILL BE SIGNED · \(p.steps.count) \(p.steps.count == 1 ? "ACTION" : "ACTIONS")")
                        .font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                    ForEach(Array(p.steps.enumerated()), id: \.offset) { n, step in
                        HStack(spacing: 12) {
                            icon(for: step, asset: p.market.name)
                            Text(step).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Text("\(n + 1)").font(.caption.weight(.bold)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.fill.quaternary))
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    box("WHAT CHANGES") { ForEach(p.changes, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) } }
                    box("CHECKS") {
                        Label("Recipients are yours only, programs are on the list, the simulation matches the plan.", systemImage: "checkmark.shield")
                        ForEach([ws.planReview, ws.txReview].compactMap { $0 }, id: \.text) { r in
                            Label(r.text, systemImage: r.concern ? "exclamationmark.triangle.fill" : "checkmark.seal")
                                .foregroundStyle(r.concern ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                        }
                        if let note = ws.jevNote { Label(note, systemImage: "info.circle").foregroundStyle(.secondary) }
                    }
                }
                if concern {
                    Toggle("I understand Jev's warning and execute anyway", isOn: $acknowledged)
                }
            } else if ws.preparing {
                HStack { ProgressView().controlSize(.small); Text("Quote, transaction and simulation…").foregroundStyle(.secondary) }
            }
            if let error = ws.executionError {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Brand.loss)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Brand.blockedTint))
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Text(ws.signerWallet == nil
                     ? "Signing is available in LALA.app once the key is in secure storage. This is a preview only."
                     : "A separate process signs; the model and websites never see the key.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(ws.signerWallet == nil ? "Close" : "Cancel") { ws.prepared = nil; ws.executionError = nil }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                if ws.signerWallet != nil {
                    Button { Task { await ws.confirmExecution() } } label: {
                        Label("Sign · Touch ID", systemImage: "touchid").font(.system(size: 14, weight: .bold))
                            .padding(.horizontal, 6)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.accent)
                    .controlSize(.large)
                    .disabled(ws.prepared == nil || (concern && !acknowledged) || ws.executing)
                }
            }
        }
        .font(.system(size: 13))
        .padding(26)
        .frame(width: 680)
        .frame(minHeight: 460)
    }

    private var title: String {
        guard let p = ws.prepared else { return ws.executionError == nil ? "Preparing the trade" : "Couldn’t prepare the trade" }
        return "Sign: \(p.intent.side == .long ? "long" : "short") \(IntentParser.pretty(p.market.name))"
    }

    /// What each step touches, before the words: the bridge, the exchange, the asset, the protection.
    @ViewBuilder private func icon(for step: String, asset: String) -> some View {
        if step.hasPrefix("Relay") { TokenLogo(name: "relay", size: 28) }
        else if step.hasPrefix("NEAR") || step.contains("1Click") { TokenLogo(name: "usdc", size: 28) }
        else if step.hasPrefix("Leverage") || step.hasPrefix("Transfer") { TokenLogo(name: "hype", size: 28) }
        else if step.hasPrefix("Long") || step.hasPrefix("Short") { AssetBadge(coin: asset, size: 28, dark: true) }
        else if step.hasPrefix("Stop") { Image(systemName: "shield.lefthalf.filled").font(.system(size: 16)).frame(width: 28, height: 28).foregroundStyle(Brand.profit) }
        else if step.hasPrefix("Trailing") { Image(systemName: "arrow.up.forward").frame(width: 28, height: 28).foregroundStyle(Brand.jevCursor) }
        else { Image(systemName: "checkmark.circle").frame(width: 28, height: 28).foregroundStyle(.secondary) }
    }

    private func box(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.cardBorder))
    }

    private var concern: Bool { ws.planReview?.concern == true || ws.txReview?.concern == true }

}
