import DeFiJupiterLend
import DeFiKamino
import DeFiYields
import EVMChain
import ExecutionCore
import Foundation
import HyperliquidSigning
import JupiterSwap
import LalaCore
import OneClickKit
import RelayBridge
import SolanaChain
import TxGuard
import WalletCore

/// Moving money between the user's own places: Hyperliquid back to Solana, Solana USDC into a vault and out.
extension Executor {
    /// Relay from the Hyperliquid perp balance to our Solana address. `usdc: nil` = everything withdrawable.
    public func withdrawToSolana(usdc requested: Decimal?) async throws -> String {
        var free = try await Hyperliquid.balance(user: wallet.evm).withdrawable
        // Margin left on a HIP-3 exchange (xyz, after an oil or stock trade) comes back to the main balance first;
        // what an open position there uses stays (only the withdrawable part moves).
        if requested.map({ $0 > free }) ?? true {
            for dex in Hyperliquid.hip3Dexes {
                let idle = (try await Hyperliquid.dexBalance(user: wallet.evm, dex: dex).withdrawable).rounded(2, .down)
                guard idle > 0 else { continue }
                try await moveMargin(from: dex, to: "", usdc: idle)
            }
            free = try await Hyperliquid.balance(user: wallet.evm).withdrawable
        }
        let usdc = (requested ?? free).rounded(2, .down)
        guard usdc > 0, usdc <= free else { throw ExecutionError("\(Fmt.usd(free)) free on Hyperliquid; can't withdraw \(Fmt.num(usdc)).") }
        let units = NSDecimalNumber(decimal: usdc * 100_000_000).uint64Value // Hyperliquid perp USDC: 8 decimals in Relay
        let quote = try await Relay.quote(user: wallet.evm, recipient: wallet.solana, originChain: Relay.Chain.hyperliquid,
                                          destinationChain: Relay.Chain.solana, originCurrency: Relay.Currency.hyperliquidUSDC,
                                          destinationCurrency: Relay.Currency.solanaUSDC, amount: units)
        guard let hl = quote.hyperliquid else { throw ExecutionError("The Relay quote has no Hyperliquid steps.") }
        let published = try await Relay.depository(chainId: Relay.Chain.hyperliquid)?.lowercased()
        var verdict = BindingGuard.check(
            ["sender": quote.sender, "recipient": quote.recipient, "amountIn": quote.amountIn, "wallet": hl.wallet, "depositor": hl.depositor,
             "destination": hl.destination, "published depository": published ?? "none", "token": hl.token],
            expected: ["sender": wallet.evm, "recipient": wallet.solana, "amountIn": "\(units)", "wallet": wallet.evm, "depositor": wallet.evm,
                       "destination": Relay.hyperliquidDepository, "published depository": Relay.hyperliquidDepository,
                       "token": "USDC:0x6d1e7cde53ba9467b783cb7c530ce054"],
            subject: "Relay quote")
        if Decimal(string: hl.amount) != usdc { verdict.problems.append("sendAsset amount \(hl.amount) instead of \(usdc).") }
        let arriving = Decimal(string: quote.amountOutFormatted) ?? 0
        if usdc - arriving > min(usdc * Decimal(string: "0.03")!, 1) { verdict.problems.append("Relay charges \(Fmt.num(usdc - arriving)) USDC: more than allowed.") }
        guard verdict.ok else { throw ExecutionError("The guard stopped the withdrawal: " + verdict.problems.joined(separator: " ")) }
        report("Relay withdrawal: \(Fmt.num(usdc)) USDC from Hyperliquid → \(Fmt.num(arriving)) USDC on Solana, fee \(Decimal(string: quote.feesUSD).map { Fmt.usd($0) } ?? quote.feesUSD).")

        guard let id = Data(hex: hl.mappingId) else { throw ExecutionError("Invalid Relay mapping id.") }
        let mapping = try await signer.signRelayMapping(wallet: hl.wallet, depositor: hl.depositor, id: id, nonce: hl.mappingNonce)
        try await Relay.authorize(body: hl.authorizeBody, signature: "0x" + mapping.r.hex + mapping.s.hex + String(format: "%02x", mapping.v))

        let action = HLSigner.sendAssetAction(destination: hl.destination, sourceDex: hl.sourceDex, destinationDex: hl.destinationDex,
                                              token: hl.token, amount: hl.amount, nonce: hl.nonce, mainnet: true)
        let signature = try await signer.signHyperliquidUser(action, recipients: [Relay.hyperliquidDepository])
        let before = try await rpc.tokenBalance(owner: wallet.solana, mint: Relay.Currency.solanaUSDC)
        try journal.append(.init(chain: "relay", id: quote.requestId, kind: .signed, note: "Hyperliquid→Solana USDC \(usdc)"))
        let started = Date()
        let reply = HLReply.parse(try await HLExchange.send(action: action, nonce: hl.nonce, signature: signature, mainnet: true))
        if case .error(let e) = reply {
            try journal.append(.init(chain: "relay", id: quote.requestId, kind: .failed, note: e))
            throw ExecutionError("Hyperliquid rejected the transfer: \(e).")
        }
        while Date().timeIntervalSince(started) < 180 {
            let status = try await Relay.status(requestId: quote.requestId).status
            if status == "success" {
                try journal.append(.init(chain: "relay", id: quote.requestId, kind: .settled, note: status))
                let after = try await rpc.tokenBalance(owner: wallet.solana, mint: Relay.Currency.solanaUSDC)
                let line = "Withdrawal done in \(Int(Date().timeIntervalSince(started))) s: Solana USDC +\(Fmt.num(Decimal(Int64(after) - Int64(before)) / 1_000_000, maxFraction: 6))."
                report(line)
                return line
            }
            if ["refund", "failure"].contains(status) {
                try journal.append(.init(chain: "relay", id: quote.requestId, kind: .failed, note: status))
                throw ExecutionError("Relay returned \(status): the money should come back to Hyperliquid.")
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ExecutionError("Relay didn't finish the withdrawal within 3 minutes. Order \(quote.requestId) is in the journal.")
    }

    /// Jupiter Lend Earn, USDC vault. `usdc: nil` on withdraw = the whole position.
    public func lend(usdc requested: Decimal?, deposit: Bool) async throws -> String {
        try await lend("USDC", amount: requested, deposit: deposit)
    }

    /// Jupiter Lend Earn for any of its assets: USDC, SOL (the jlWSOL vault), USDT, JupUSD… `amount` in the asset;
    /// withdraw with nil takes everything. After a full withdraw the empty share account is closed and its rent returns.
    public func lend(_ symbol: String, amount requested: Decimal?, deposit: Bool) async throws -> String {
        let wanted = symbol.uppercased() == "SOL" ? "WSOL" : symbol.uppercased()
        guard let vault = try await JupiterLend.vaults().first(where: { $0.assetSymbol.uppercased() == wanted }) else {
            throw ExecutionError("Jupiter Lend has no \(symbol) vault.")
        }
        let native = vault.assetMint == "So11111111111111111111111111111111111111112"
        let name = native ? "SOL" : vault.assetSymbol
        let scale = Decimal(sign: .plus, exponent: vault.decimals, significand: 1)
        let myAsset = try SPL.associatedAccount(owner: wallet.solana, mint: vault.assetMint)
        let myShares = try SPL.associatedAccount(owner: wallet.solana, mint: vault.address)
        let owners = [myAsset: wallet.solana, myShares: wallet.solana]
        let position = try await JupiterLend.positions(user: wallet.solana).first { $0.vault == vault.symbol }
        let inVault = position?.assets ?? 0
        var units: UInt64
        if let requested { units = NSDecimalNumber(decimal: (requested * scale).rounded(0, .down)).uint64Value }
        else if deposit { throw ExecutionError("How much should go into the vault?") }
        else { units = inVault }
        if deposit {
            let have = native ? try await rpc.balance(wallet.solana) : try await rpc.tokenBalance(owner: wallet.solana, mint: vault.assetMint)
            let spendable = native ? (have > 12_000_000 ? have - 12_000_000 : 0) : have   // SOL: keep fees and account rent
            guard units > 0, units <= spendable else {
                throw ExecutionError("You have \(Fmt.num(Decimal(spendable) / scale, maxFraction: 6)) \(name)\(native ? " (0.012 SOL is kept for fees and the account)" : ""); can't deposit \(Fmt.num(Decimal(units) / scale, maxFraction: 6)).")
            }
            // The API's deposit expects our share account to exist; Jupiter's own site creates it first.
            if (try? await rpc.call("getAccountInfo", [myShares, ["encoding": "base64"]]) as? [String: Any])?["value"] is NSNull {
                let create = SolanaInstruction(program: SPL.associatedTokenProgram, accounts: [
                    .init(pubkey: wallet.solana, isSigner: true, isWritable: true), .init(pubkey: myShares, isSigner: false, isWritable: true),
                    .init(pubkey: wallet.solana, isSigner: false, isWritable: false), .init(pubkey: vault.address, isSigner: false, isWritable: false),
                    .init(pubkey: SolanaGuard.system, isSigner: false, isWritable: false), .init(pubkey: SPL.tokenProgram, isSigner: false, isWritable: false),
                ], data: Data([1])) // CreateIdempotent
                let (hash, lastValid) = try await rpc.latestBlockhash()
                let wire = SolanaTransaction.unsigned(try SolanaTransaction.compileMessage([create], payer: wallet.solana, blockhash: hash))
                try await signAndSend(wire, lastValid: lastValid, owners: owners, rules: [], note: "\(vault.symbol) share account")
            }
            if native {
                // Jupiter Lend takes wrapped SOL from our wSOL account; it does not wrap by itself.
                let wrap = [
                    SolanaInstruction(program: SPL.associatedTokenProgram, accounts: [
                        .init(pubkey: wallet.solana, isSigner: true, isWritable: true), .init(pubkey: myAsset, isSigner: false, isWritable: true),
                        .init(pubkey: wallet.solana, isSigner: false, isWritable: false), .init(pubkey: vault.assetMint, isSigner: false, isWritable: false),
                        .init(pubkey: SolanaGuard.system, isSigner: false, isWritable: false), .init(pubkey: SPL.tokenProgram, isSigner: false, isWritable: false),
                    ], data: Data([1])),
                    SolanaInstruction(program: SolanaGuard.system, accounts: [
                        .init(pubkey: wallet.solana, isSigner: true, isWritable: true), .init(pubkey: myAsset, isSigner: false, isWritable: true),
                    ], data: Data([2, 0, 0, 0]) + withUnsafeBytes(of: units.littleEndian) { Data($0) }),
                    SolanaInstruction(program: SPL.tokenProgram, accounts: [.init(pubkey: myAsset, isSigner: false, isWritable: true)], data: Data([17])), // SyncNative
                ]
                let (hash, lastValid) = try await rpc.latestBlockhash()
                try await signAndSend(SolanaTransaction.unsigned(try SolanaTransaction.compileMessage(wrap, payer: wallet.solana, blockhash: hash)),
                                      lastValid: lastValid, owners: owners, rules: [(myAsset, "wSOL", true, Int64(units))], note: "wrap SOL",
                                      lamportsAtLeast: -Int64(units) - 8_000_000)
            }
        } else {
            units = min(units, inVault)
            guard units > 0 else {
                // Nothing in the vault; an empty share account left from an earlier attempt still holds rent.
                let line = "The \(vault.symbol) vault is empty." + (try await closeIfEmpty(myShares, mint: vault.address, label: "\(vault.symbol) share account") ?? "")
                report(line)
                return line
            }
        }
        // Everything out goes by shares: withdrawing the reported amount fails by a rounding unit.
        let all = !deposit && units >= inVault
        let wire = deposit
            ? try await JupiterLend.depositTransaction(asset: vault.assetMint, user: wallet.solana, amount: units)
            : all ? try await JupiterLend.redeemTransaction(asset: vault.assetMint, user: wallet.solana, shares: position?.shares ?? 0)
            : try await JupiterLend.withdrawTransaction(asset: vault.assetMint, user: wallet.solana, amount: units)
        let lastValid = try await rpc.latestBlockhash().lastValidBlockHeight
        // SOL goes through our wSOL account (wrapped before the deposit, unwrapped after the withdraw), so the rule
        // is the same token rule for every asset.
        let before = Int64(try await rpc.tokenBalance(owner: wallet.solana, mint: vault.assetMint))
        var rules: [(String, String, Bool, Int64)] = deposit ? [(myShares, "\(vault.symbol) shares", true, 1)] : []
        rules.append((myAsset, native ? "wSOL" : name, true, deposit ? -Int64(units) : Int64(units) - (all ? 2 : 1)))
        try await signAndSend(wire, lastValid: lastValid, owners: owners, rules: rules, note: "Jupiter Lend \(deposit ? "deposit" : "withdraw") \(name)")
        let after = Int64(try await rpc.tokenBalance(owner: wallet.solana, mint: vault.assetMint))
        var line = deposit
            ? "Deposited \(Fmt.num(Decimal(units) / scale, maxFraction: 9)) \(name) into the \(vault.symbol) vault (\(Fmt.num(vault.apy))% APY)."
            : "Withdrawn from the \(vault.symbol) vault: \(name) +\(Fmt.num(Decimal(after - before) / scale, maxFraction: 9))\(native ? " (net of fees)" : "")."
        if !deposit {
            // Emptied the vault: the share account's rent comes back. For SOL, closing the wSOL account unwraps it.
            line += try await closeIfEmpty(myShares, mint: vault.address, label: "\(vault.symbol) share account") ?? ""
            if native { line += try await closeWrappedSOL(myAsset) }
        }
        report(line)
        return line
    }

    /// Closes our token account when it holds nothing; returns the line saying how much rent came back.
    private func closeIfEmpty(_ account: String, mint: String, label: String) async throws -> String? {
        guard (try? await rpc.call("getAccountInfo", [account, ["encoding": "base64"]]) as? [String: Any])?["value"] is [String: Any],
              try await rpc.tokenBalance(owner: wallet.solana, mint: mint) == 0 else { return nil }
        return try await close(account, label: label, least: 1_000_000)
    }

    /// Closing the wSOL account turns the wrapped SOL and its rent back into ordinary SOL.
    private func closeWrappedSOL(_ account: String) async throws -> String {
        guard (try? await rpc.call("getAccountInfo", [account, ["encoding": "base64"]]) as? [String: Any])?["value"] is [String: Any] else { return "" }
        return try await close(account, label: "wSOL account (SOL unwrapped)", least: 0)
    }

    private func close(_ account: String, label: String, least: Int64) async throws -> String {
        let instruction = SolanaInstruction(program: SPL.tokenProgram, accounts: [
            .init(pubkey: account, isSigner: false, isWritable: true), .init(pubkey: wallet.solana, isSigner: false, isWritable: true),
            .init(pubkey: wallet.solana, isSigner: true, isWritable: false),
        ], data: Data([9])) // CloseAccount
        let (hash, lastValid) = try await rpc.latestBlockhash()
        let before = try await rpc.balance(wallet.solana)
        try await signAndSend(SolanaTransaction.unsigned(try SolanaTransaction.compileMessage([instruction], payer: wallet.solana, blockhash: hash)),
                              lastValid: lastValid, owners: [account: wallet.solana], rules: [], note: "close \(label)", lamportsAtLeast: least)
        return " Closed \(label): +\(Fmt.num(Decimal(Int64(try await rpc.balance(wallet.solana)) - Int64(before)) / 1_000_000_000, maxFraction: 6)) SOL."
    }

    /// Spot on Solana through Jupiter: `buy` spends USDC on the coin, otherwise the coin is sold for USDC.
    /// The simulated balances must show at least Jupiter's minimum output arriving in our own account.
    /// Buy (from USDC) or sell (for USDC); kept for the chat commands.
    public func swap(_ asset: SpotAsset, buy: Bool, amount requested: Decimal?, equity: Decimal? = nil) async throws -> String {
        try await convert(from: buy ? .usdc : asset, to: buy ? asset : .usdc, amount: requested, equity: equity)
    }

    /// Any verified token into any other through Jupiter: buying and selling, and staking SOL into JitoSOL and back.
    /// The simulated balances must show at least Jupiter's minimum output arriving in our own account. `amount` in the
    /// input token; nil = all of it (SOL keeps 0.01 for fees). Spending USDC on one coin obeys the concentration rule.
    public func convert(from: SpotAsset, to: SpotAsset, amount requested: Decimal?, equity: Decimal? = nil, dryRun: Bool = false) async throws -> String {
        guard from != to else { throw ExecutionError("That's the same token.") }
        let nativeIn = from.symbol == "SOL", nativeOut = to.symbol == "SOL"
        let scale = Decimal(sign: .plus, exponent: from.decimals, significand: 1)
        let outScale = Decimal(sign: .plus, exponent: to.decimals, significand: 1)
        if from == .usdc, let equity, equity > 0 {
            let share = (requested ?? 0) / equity * 100
            guard share <= 50 else {
                throw ExecutionError("That's \(Fmt.pct(share.rounded(0, .plain))) of your capital in one coin. The rule: no more than half at once — buy in parts, e.g. \(Fmt.usd((equity / 10).rounded(2, .down))) a week.")
            }
            if share > 25 { report("That's \(Fmt.pct(share.rounded(0, .plain))) of your capital in \(to.symbol): big buys are usually split over time (DCA).") }
        }
        let have: UInt64 = nativeIn ? try await rpc.balance(wallet.solana) : try await rpc.tokenBalance(owner: wallet.solana, mint: from.mint)
        let spendable = nativeIn ? (have > 10_000_000 ? have - 10_000_000 : 0) : have
        let units = requested.map { NSDecimalNumber(decimal: ($0 * scale).rounded(0, .down)).uint64Value } ?? spendable
        guard units > 0, units <= spendable else {
            throw ExecutionError("You have \(Fmt.num(Decimal(spendable) / scale, maxFraction: 6)) \(from.symbol)\(nativeIn ? " (0.01 SOL is kept for fees)" : ""); need \(Fmt.num(Decimal(units) / scale, maxFraction: 6)).")
        }
        let quote = try await Jupiter.quote(input: from.mint, output: to.mint, amount: units)
        report("\(from.symbol) → \(to.symbol) via Jupiter: \(Fmt.num(Decimal(units) / scale, maxFraction: 8)) → ≈ \(Fmt.num(Decimal(quote.outAmount) / outScale, maxFraction: 8)), at least \(Fmt.num(Decimal(quote.minOut) / outScale, maxFraction: 8)). Route: \(quote.route).")
        let tx = try await Jupiter.swapTransaction(quote, user: wallet.solana)
        let inAccount = try SPL.associatedAccount(owner: wallet.solana, mint: from.mint, program: from.token2022 ? SPL.token2022Program : SPL.tokenProgram)
        let outAccount = try SPL.associatedAccount(owner: wallet.solana, mint: to.mint, program: to.token2022 ? SPL.token2022Program : SPL.tokenProgram)
        let owners = [inAccount: wallet.solana, outAccount: wallet.solana]   // wSOL accounts too, for the native side
        var rules: [(String, String, Bool, Int64)] = []
        if !nativeIn { rules.append((inAccount, from.symbol, true, -Int64(units))) }
        if !nativeOut { rules.append((outAccount, "\(to.symbol) (quote minimum)", true, Int64(quote.minOut))) }
        let fee: Int64 = 5_000_000
        // Up to ~0.0021 SOL more when the output token's account is created (rent, returned when it is closed).
        let lamportsAtLeast: Int64 = nativeIn ? -Int64(units) - fee : nativeOut ? Int64(quote.minOut) - fee : -fee
        let outBefore = nativeOut ? try await rpc.balance(wallet.solana) : try await rpc.tokenBalance(owner: wallet.solana, mint: to.mint)
        let changes = try await signAndSend(tx.wire, lastValid: tx.lastValidBlockHeight, owners: owners, rules: rules, note: "Jupiter \(from.symbol)→\(to.symbol)",
                                            lamportsAtLeast: lamportsAtLeast, dryRun: dryRun)
        if dryRun { return "Simulation (nothing signed): " + changes.joined(separator: "; ") }
        let outAfter = nativeOut ? try await rpc.balance(wallet.solana) : try await rpc.tokenBalance(owner: wallet.solana, mint: to.mint)
        var line = "Swapped \(Fmt.num(Decimal(units) / scale, maxFraction: 8)) \(from.symbol) → \(to.symbol) +\(Fmt.num(Decimal(Int64(outAfter) - Int64(outBefore)) / outScale, maxFraction: 8))\(nativeOut ? " (net of fees)" : "")."
        swapped?(from, to, Decimal(units) / scale, Decimal(Int64(outAfter) - Int64(outBefore)) / outScale)
        // Out of a token entirely: its empty account still holds ~0.002 SOL of rent; closing returns it. A Token-2022
        // account would need that program, which the guard doesn't allow: its rent stays.
        if !nativeIn, !from.token2022, try await rpc.tokenBalance(owner: wallet.solana, mint: from.mint) == 0 {
            let close = SolanaInstruction(program: SPL.tokenProgram, accounts: [
                .init(pubkey: inAccount, isSigner: false, isWritable: true), .init(pubkey: wallet.solana, isSigner: false, isWritable: true),
                .init(pubkey: wallet.solana, isSigner: true, isWritable: false),
            ], data: Data([9])) // CloseAccount
            let (hash, lastValid) = try await rpc.latestBlockhash()
            let before = try await rpc.balance(wallet.solana)
            try await signAndSend(SolanaTransaction.unsigned(try SolanaTransaction.compileMessage([close], payer: wallet.solana, blockhash: hash)),
                                  lastValid: lastValid, owners: [inAccount: wallet.solana], rules: [], note: "close empty \(from.symbol) account",
                                  lamportsAtLeast: 1_000_000)
            line += " Empty \(from.symbol) account closed: +\(Fmt.num(Decimal(Int64(try await rpc.balance(wallet.solana)) - Int64(before)) / 1_000_000_000, maxFraction: 6)) SOL of rent returned."
        }
        report(line)
        return line
    }

    /// Guard and simulation here, the signer's own guard, then send and wait. `rules`: (account, label, token?, least change).
    /// Returns the simulated change per watched balance; `dryRun` stops before signing.
    @discardableResult
    private func signAndSend(_ unsigned: Data, lastValid: UInt64, owners: [String: String], rules: [(String, String, Bool, Int64)], note: String,
                             lamportsAtLeast: Int64 = -5_000_000, dryRun: Bool = false) async throws -> [String] {
        let message = try SolanaMessage.parse(transaction: unsigned)
        let accounts = try await rpc.resolveAccounts(message)
        var verdict = SolanaGuard.check(message, accounts: accounts, policy: SolanaPolicy(owner: wallet.solana), tokenOwners: owners)
        let watch = rules.map(\.0) + [wallet.solana]
        var before: [String: Int64] = [:]
        for (account, _, token, _) in rules {
            if token {
                let r = try? await rpc.call("getTokenAccountBalance", [account, ["commitment": "confirmed"]]) as? [String: Any]
                before[account] = ((r?["value"] as? [String: Any])?["amount"] as? String).flatMap(Int64.init) ?? 0
            }
        }
        before[wallet.solana] = Int64(try await rpc.balance(wallet.solana))
        let simulation = try await rpc.simulate(unsigned, watch: watch, sigVerify: false)
        // A failed simulation says nothing about balances: stop here rather than quote made-up changes.
        if let error = simulation.error { throw ExecutionError("The simulation failed, so nothing was signed: \(error)") }
        verdict.merge(SolanaGuard.balances(rules.map { account, label, token, least in
            .init(label: label, before: before[account] ?? 0, after: Int64(token ? simulation.after[account]?.token ?? 0 : simulation.after[account]?.lamports ?? 0), atLeast: least)
        } + [.init(label: "lamports", before: before[wallet.solana] ?? 0, after: Int64(simulation.after[wallet.solana]?.lamports ?? 0), atLeast: lamportsAtLeast)]))
        guard verdict.ok else { throw ExecutionError("The guard stopped \(note): " + verdict.problems.joined(separator: " ")) }
        var changes = rules.map { account, label, token, _ in
            let after = Int64(token ? simulation.after[account]?.token ?? 0 : simulation.after[account]?.lamports ?? 0)
            return "\(label): \(after - (before[account] ?? 0)) (raw units)"
        }
        let solDelta = Decimal(Int64(simulation.after[wallet.solana]?.lamports ?? 0) - (before[wallet.solana] ?? 0)) / 1_000_000_000
        changes.append("SOL: \(Fmt.num(solDelta, maxFraction: 6)) (\(solDelta < 0 ? "fee and rent for new accounts" : "rent back from closed accounts"))")
        if dryRun { return changes }
        let signed = try await signer.signSolana(unsigned, accounts: accounts, recipients: [], tokenOwners: owners)
        guard signed.count == unsigned.count, signed.subdata(in: 65..<signed.count) == unsigned.subdata(in: 65..<unsigned.count) else {
            throw ExecutionError("What was signed isn't what was checked.")
        }
        let signature = Base58.encode(signed.subdata(in: 1..<65))
        try journal.append(.init(chain: "solana", id: signature, kind: .signed, note: "\(note); valid until block \(lastValid)"))
        _ = try await rpc.send(signed)
        switch try await rpc.waitForConfirmation(signature, lastValidBlockHeight: lastValid) {
        case .confirmed: try journal.append(.init(chain: "solana", id: signature, kind: .confirmed))
        case .failed(let e):
            try journal.append(.init(chain: "solana", id: signature, kind: .failed, note: e))
            throw ExecutionError("The transaction failed: \(e).")
        case .expired:
            try journal.append(.init(chain: "solana", id: signature, kind: .expired))
            throw ExecutionError("The transaction didn't make it into a block; you can retry.")
        }
        return changes
    }

    /// Native NEAR for Solana USDC through NEAR Intents 1Click, delivered to `account` — the wallet's own NEAR implicit
    /// account, which only the signer derives. The first quote is what the user approved; the live one must stay within
    /// 1% of it, and 1Click itself must have the deposit address bound to our recipient, refund address and amount.
    public func buyNear(usdc: Decimal, account: String) async throws -> String {
        let units = NSDecimalNumber(decimal: (usdc * 1_000_000).rounded(0, .down)).uint64Value
        guard usdc >= 1 else { throw ExecutionError("Buy NEAR from 1 USDC: below that 1Click's fee eats too much.") }
        guard account.wholeMatch(of: /[0-9a-f]{64}/) != nil else { throw ExecutionError("That is not a NEAR implicit account.") }
        let shown = try await OneClick.quote(dry: true, origin: OneClick.Asset.solanaUSDC, destination: OneClick.Asset.near,
                                             amount: "\(units)", refundTo: wallet.solana, recipient: account)
        var envelope = Envelope.approve(input: usdc, quotedOutput: Decimal(string: shown.amountOutFormatted) ?? 0)
        let quote = try await OneClick.quote(dry: false, origin: OneClick.Asset.solanaUSDC, destination: OneClick.Asset.near,
                                             amount: "\(units)", refundTo: wallet.solana, recipient: account)
        guard let deposit = quote.depositAddress else { throw ExecutionError("1Click gave no deposit address.") }
        envelope.destination = deposit
        let problems = envelope.violations(input: Decimal(string: quote.amountInFormatted) ?? .greatestFiniteMagnitude,
                                           output: Decimal(string: quote.amountOutFormatted) ?? 0, destination: deposit)
        guard problems.isEmpty else { throw ExecutionError("The price moved past what was approved: " + problems.joined(separator: " ")) }
        let binding = DepositGuard.check(bound: try await OneClick.boundRequest(depositAddress: deposit), recipient: account, refundTo: wallet.solana,
                                         origin: OneClick.Asset.solanaUSDC, destination: OneClick.Asset.near, amount: "\(units)")
        guard binding.ok else { throw ExecutionError("The guard stopped the deposit: " + binding.problems.joined(separator: " ")) }
        report("NEAR Intents: \(Fmt.num(usdc)) USDC → ≈ \(Fmt.num(Decimal(string: quote.amountOutFormatted) ?? 0, maxFraction: 4)) NEAR to your NEAR account.")
        let sent = try await sendSolanaUSDC(units, to: deposit, label: "the 1Click deposit")
        try journal.append(.init(chain: "1click", id: deposit, kind: .signed, note: "USDC→NEAR \(Fmt.num(usdc)) to \(account)"))
        if let tx = sent.split(separator: "/").last { try? await OneClick.submitDeposit(txHash: String(tx), depositAddress: deposit) }
        let started = Date()
        while Date().timeIntervalSince(started) < 600 {
            let s = try await OneClick.status(depositAddress: deposit)
            if s.isFinal {
                try journal.append(.init(chain: "1click", id: deposit, kind: s.status == "SUCCESS" ? .settled : .failed, note: s.status))
                guard s.status == "SUCCESS" else { throw ExecutionError("1Click \(s.status.lowercased()): \(s.refundedFormatted.map { "\($0) USDC went back to Solana" } ?? "see the journal").") }
                let line = "Bought \(Fmt.num(Decimal(string: s.amountOutFormatted ?? "") ?? 0, maxFraction: 4)) NEAR for \(Fmt.num(usdc)) USDC in \(Int(Date().timeIntervalSince(started))) s — native NEAR on your NEAR account."
                report(line)
                return line
            }
            try await Task.sleep(for: .seconds(3))
        }
        throw ExecutionError("1Click hasn't finished within 10 minutes. The deposit \(deposit) is in the journal; it settles or refunds on its own.")
    }

    /// Native NEAR from the wallet's NEAR account → USDC on our Solana address, through NEAR Intents 1Click (the reverse
    /// of `buyNear`). nil = all the account can give: its storage stays, and so does what the transaction may need
    /// (`NearTransaction.intentDepositOverhead`, mostly refunded). The live quote must stay within 1% of the one shown;
    /// 1Click must have the deposit address bound to our Solana address as recipient and our NEAR account for refunds;
    /// the signer builds the wrap.near transaction itself from the amount and the deposit address.
    public func sellNear(amount requested: Decimal?, account: String) async throws -> String {
        guard account.wholeMatch(of: /[0-9a-f]{64}/) != nil else { throw ExecutionError("That is not a NEAR implicit account.") }
        let context = try await Near.txContext(account: account)
        let micro: UInt128 = 1_000_000_000_000_000_000   // 10⁻⁶ NEAR: amounts are whole micro-NEAR
        let storage = UInt128(context.storageBytes) * 10_000_000_000_000_000_000   // 10¹⁹ yocto a byte
        let balance = UInt128(context.balance) ?? 0
        let keep = storage + NearTransaction.intentDepositOverhead(gasPrice: UInt128(context.gasPrice) ?? 100_000_000)
        let free = balance > keep ? (balance - keep) / micro * micro : 0
        let yocto = requested.flatMap { UInt128(NSDecimalNumber(decimal: ($0 * 1_000_000).rounded(0, .down)).stringValue) }.map { $0 * micro } ?? free
        guard yocto >= 50_000 * micro else { throw ExecutionError("Sell NEAR from 0.05: below that 1Click's fee eats too much.") }
        guard yocto <= free else {
            throw ExecutionError("\(NearTransaction.near(free)) NEAR can be sold: the account keeps \(NearTransaction.near(keep)) for its storage and the transaction.")
        }
        let near = Decimal(string: NearTransaction.near(yocto)) ?? 0, units = "\(yocto)"
        let shown = try await OneClick.quote(dry: true, origin: OneClick.Asset.near, destination: OneClick.Asset.solanaUSDC,
                                             amount: units, refundTo: account, recipient: wallet.solana)
        var envelope = Envelope.approve(input: near, quotedOutput: Decimal(string: shown.amountOutFormatted) ?? 0)
        let quote = try await OneClick.quote(dry: false, origin: OneClick.Asset.near, destination: OneClick.Asset.solanaUSDC,
                                             amount: units, refundTo: account, recipient: wallet.solana)
        guard let deposit = quote.depositAddress, deposit.wholeMatch(of: /[0-9a-f]{64}/) != nil else {
            throw ExecutionError("1Click gave no NEAR deposit account.")
        }
        envelope.destination = deposit
        var problems = envelope.violations(input: Decimal(string: quote.amountInFormatted) ?? .greatestFiniteMagnitude,
                                           output: Decimal(string: quote.amountOutFormatted) ?? 0, destination: deposit)
        if let d = quote.deadline.flatMap({ try? Date($0, strategy: .iso8601) }), d < Date().addingTimeInterval(300) {
            problems.append("The quote expires in less than 5 minutes.")
        }
        guard problems.isEmpty else { throw ExecutionError("The price moved past what was approved: " + problems.joined(separator: " ")) }
        let binding = DepositGuard.check(bound: try await OneClick.boundRequest(depositAddress: deposit), recipient: wallet.solana, refundTo: account,
                                         origin: OneClick.Asset.near, destination: OneClick.Asset.solanaUSDC, amount: units)
        guard binding.ok else { throw ExecutionError("The guard stopped the deposit: " + binding.problems.joined(separator: " ")) }
        report("NEAR Intents: \(Fmt.num(near, maxFraction: 6)) NEAR → ≈ \(Fmt.num(Decimal(string: quote.amountOutFormatted) ?? 0)) USDC to your Solana address.")
        let signed = try await signer.signNearIntentDeposit(amount: yocto, depositAddress: deposit, nonce: context.nonce, blockHash: context.blockHash)
        try journal.append(.init(chain: "1click", id: deposit, kind: .signed, note: "NEAR→USDC \(Fmt.num(near, maxFraction: 6)) to \(wallet.solana)"))
        let hash = try await Near.send(signed)
        try journal.append(.init(chain: "near", id: hash, kind: .confirmed, note: "wNEAR to 1Click \(deposit)"))
        try? await OneClick.submitDeposit(txHash: hash, depositAddress: deposit)
        let started = Date()
        while Date().timeIntervalSince(started) < 600 {
            let s = try await OneClick.status(depositAddress: deposit)
            if s.isFinal {
                try journal.append(.init(chain: "1click", id: deposit, kind: s.status == "SUCCESS" ? .settled : .failed, note: s.status))
                guard s.status == "SUCCESS" else { throw ExecutionError("1Click \(s.status.lowercased()): \(s.refundedFormatted.map { "\($0) wNEAR went back to your NEAR account" } ?? "see the journal").") }
                let line = "Sold \(Fmt.num(near, maxFraction: 6)) NEAR for \(Fmt.num(Decimal(string: s.amountOutFormatted ?? "") ?? 0)) USDC in \(Int(Date().timeIntervalSince(started))) s — on your Solana address. https://nearblocks.io/txns/\(hash)"
                report(line)
                return line
            }
            try await Task.sleep(for: .seconds(3))
        }
        throw ExecutionError("1Click hasn't finished within 10 minutes. The deposit \(deposit) is in the journal; it settles or refunds on its own. https://nearblocks.io/txns/\(hash)")
    }

    /// Hyperliquid's HLP vault from the main perp balance. Deposits are locked for 4 days; withdraw with nil takes
    /// everything that can be withdrawn now.
    public func hlp(deposit: Bool, amount requested: Decimal?) async throws -> String {
        var free = try await Hyperliquid.balance(user: wallet.evm).withdrawable
        let equity = try await HyperliquidAccount.vaultEquity(user: wallet.evm, vault: HLGuard.hlpVault)
        let amount: Decimal
        if deposit {
            // Hyperliquid refuses vault deposits under $5 (checked live 2026-09-25); say so before signing.
            guard let requested, requested >= 5 else { throw ExecutionError("Hyperliquid accepts vault deposits from $5.") }
            // Margin left on a HIP-3 exchange (after an oil or stock trade) comes back to the main balance first.
            for dex in Hyperliquid.hip3Dexes where free < requested {
                let there = try await Hyperliquid.dexBalance(user: wallet.evm, dex: dex).withdrawable
                let pull = min(there, requested - free).rounded(2, .up)
                guard pull > 0, pull <= there else { continue }
                try await moveMargin(from: dex, to: "", usdc: pull)
                free = try await Hyperliquid.balance(user: wallet.evm).withdrawable
            }
            guard requested <= free else { throw ExecutionError("\(Fmt.usd(free)) free on Hyperliquid; can't deposit \(Fmt.usd(requested)).") }
            amount = requested
        } else {
            guard equity.withdrawable > 0 else {
                throw ExecutionError(equity.equity > 0 ? "\(Fmt.usd(equity.equity)) in HLP, locked for 4 days after a deposit: withdrawable from \(equity.lockedUntil.map(Fmt.date) ?? "soon")." : "Nothing in HLP.")
            }
            amount = min(requested ?? equity.withdrawable, equity.withdrawable)
        }
        let units = NSDecimalNumber(decimal: (amount * 1_000_000).rounded(0, .down)).uint64Value
        let action = MsgPack.map([("type", .string("vaultTransfer")), ("vaultAddress", .string(HLGuard.hlpVault)),
                                  ("isDeposit", .bool(deposit)), ("usd", .uint(units))])
        let reply = try await post(action, label: deposit ? "HLP deposit" : "HLP withdraw")
        guard !reply.isError else { throw ExecutionError("Hyperliquid rejected it: \(reply).") }
        let line = deposit
            ? "Deposited \(Fmt.usd(amount)) into HLP (\(Fmt.num(((try? await Yields.hyperliquidVaultAPR(HLGuard.hlpVault)) ?? 0).rounded(2, .plain)))% APY historically). You can withdraw after 4 days; there are losing periods."
            : "Withdrew \(Fmt.usd(amount)) from HLP to the main Hyperliquid balance."
        report(line)
        return line
    }

    /// "Spread USDC across the best rates": plans with `Allocation.plan` over the live rates and what is already
    /// deposited, and with `execute` carries the slices out one by one through the same checked paths.
    /// USDC is counted in dollars, SOL in SOL; SOL keeps 0.02 for fees and account rent.
    /// Returns the text and whether there is anything to confirm.
    public func allocate(_ symbol: String, maxShare: Decimal = 50, limit: Decimal? = nil, execute: Bool) async throws -> (text: String, ready: Bool, preview: AllocationPreview) {
        let isSOL = symbol.uppercased() == "SOL"
        let asset = isSOL ? "SOL" : "USDC"
        let onSolana: Decimal = isSOL
            ? max(0, Decimal(try await rpc.balance(wallet.solana)) / 1_000_000_000 - Decimal(string: "0.02")!)
            : Decimal(try await rpc.tokenBalance(owner: wallet.solana, mint: Relay.Currency.solanaUSDC)) / 1_000_000
        // USDC idle on the EVM networks is free too: a slice there takes it where it is, and what Solana's slices lack
        // comes over from them (below). Before, «spread USDC» saw only Solana's and left 2,960 idle on Base out.
        let idle = isSOL ? [] : await idleUSDC()
        let held = onSolana + idle.reduce(0) { $0 + $1.usdc }
        // «spread 2 USDC»: at most that much of what is free.
        let free = limit.map { min(held, $0) } ?? held
        async let optionsCall = Yields.options(for: asset)
        async let vaultsCall = try? JupiterLend.vaults()
        async let jupCall = try? JupiterLend.positions(user: wallet.solana)
        async let kamCall = try? Kamino.positions(wallet: wallet.solana)
        let solPrice = try await Hyperliquid.markets()["SOL"]?.markPx ?? 0
        let options = await optionsCall
        let vault = (await vaultsCall ?? []).first { $0.assetSymbol.uppercased() == (isSOL ? "WSOL" : "USDC") }
        let jupPositions = await jupCall ?? []
        let jupiter = vault.flatMap { v in jupPositions.first { $0.vault == v.symbol }.map { Decimal($0.assets) / Decimal(sign: .plus, exponent: v.decimals, significand: 1) } } ?? 0
        let kaminoUSD = (await kamCall ?? []).filter { $0.symbol.uppercased() == asset }.reduce(0) { $0 + $1.valueUSD }
        let kamino = isSOL ? (solPrice > 0 ? kaminoUSD / solPrice : 0) : kaminoUSD
        var jito: Decimal = 0
        if isSOL, let held = try? await rpc.tokenBalance(owner: wallet.solana, mint: SpotAsset.jitoSOL.mint), held > 0,
           let q = try? await Jupiter.quote(input: SpotAsset.jitoSOL.mint, output: SpotAsset.all[0].mint, amount: held) {
            jito = Decimal(q.outAmount) / 1_000_000_000
        }
        // Aave and Morpho on the EVM networks, USDC only: rates and balances from the pools and vaults themselves.
        let evm = isSOL ? [] : await evmPlaces()
        let total = free + jupiter + kamino + jito + evm.reduce(0) { $0 + $1.supplied }
        let kaminoRentUSD = Decimal(string: "0.0298")! * solPrice
        // A vault switched off in Settings › Modules is skipped, with the reason in the notes.
        let modules = Modules.current
        let places: [Allocation.Place] = options.compactMap { o in
            switch o.place {
            case "Jupiter Lend": return .init(name: o.place, apy: o.apy, existing: jupiter, blocked: modules.refusal(vault: o.place))
            case "JitoSOL staking": return .init(name: o.place, apy: o.apy, existing: jito, blocked: modules.refusal(vault: o.place))
            case "Kamino Lend":
                // The first deposit's rent is a cost, not a refundable deposit: worth it only for a big enough slice.
                let slice = min(free, total * maxShare / 100 - kamino) * (isSOL ? solPrice : 1)
                let blocked = kamino == 0 && kaminoRentUSD > slice / 10
                    ? "the first deposit creates Kamino accounts for ≈ \(Fmt.usd(kaminoRentUSD)) of rent, more than 10% of the \(Fmt.usd(slice)) slice" : nil
                return .init(name: o.place, apy: o.apy, existing: kamino, blocked: modules.refusal(vault: o.place) ?? blocked)
            case "HLP (Hyperliquid)":
                return .init(name: o.place, apy: o.apy, blocked: "another network: bridge, $5 minimum and a 4-day lock — use a separate command, «deposit 5 USDC to HLP»")
            default: return nil
            }
        }
        var all = places
        // A known place whose rate, balance or gas didn't answer this time is named with why, not left out silently:
        // Morpho on Ethereum vanished from a spread between two messages, and nothing said so.
        if !isSOL {
            let read = Set(evm.map(\.name))
            for name in AaveV3.markets.map(\.place) + MorphoVault.vaults.map(\.place) where !read.contains(name) && modules.refusal(vault: name) == nil {
                all.append(.init(name: name, apy: options.first { $0.place == name }?.apy ?? 0, blocked: "its rate, balance or gas couldn't be read just now — ask again in a minute"))
            }
        }
        for p in evm {
            // Worth it only when the round trip costs less than half a year of the slice's interest: on Ethereum that
            // takes a large slice, on the L2s a few dollars.
            let slice = max(0, min(free, total * maxShare / 100 - p.supplied))
            all.append(.init(name: p.name, apy: p.apy, existing: p.supplied,
                             blocked: modules.refusal(vault: p.name) ?? p.tooCostly(yearly: slice * p.apy / 100), protocol: p.protocolName))
        }
        let plan = Allocation.plan(free: free, places: all, maxShare: maxShare, minSlice: isSOL ? Decimal(string: "0.003")! : Decimal(string: "0.5")!)
        func amount(_ d: Decimal) -> String { Fmt.num(d, maxFraction: isSOL ? 6 : 2) + " " + asset }
        var lines = ["Spread \(amount(free)) free (\(amount(total)) total in \(asset)), at most \(Fmt.pct(maxShare)) per protocol:"]
        let sources = (onSolana > 0 ? [("Solana", onSolana)] : []) + idle.map { ($0.net.name, $0.usdc) }
        if !idle.isEmpty { lines.append("· free now: " + sources.map { "\(amount($0.1)) on \($0.0)" }.joined(separator: ", ")) }
        lines += plan.slices.map { "· \($0.place): \(amount($0.amount)) at \(Fmt.num($0.apy.rounded(2, .plain)))%" }
        if plan.slices.isEmpty { lines.append("· nowhere to put it: everything is at its limit or unavailable.") }
        lines += plan.notes.map { "· " + $0 }
        if plan.leftover > 0 { lines.append("Left free: \(amount(plan.leftover)).") }
        if plan.yearly > 0 { lines.append("Income from the new deposits ≈ \(amount(plan.yearly)) a year\(isSOL && solPrice > 0 ? " (≈ \(Fmt.usd(plan.yearly * solPrice)))" : "").") }
        let preview = AllocationPreview(asset: asset, free: free, maxShare: maxShare, slices: plan.slices,
                                        skipped: all.compactMap { p in p.blocked.map { (p.name, p.apy, $0) } },
                                        leftover: plan.leftover, yearly: plan.yearly, yearlyUSD: isSOL && solPrice > 0 ? plan.yearly * solPrice : nil,
                                        sources: sources.map { (place: $0.0, amount: $0.1) })
        // The preview goes back to the caller, which adds how to confirm.
        guard execute, !plan.slices.isEmpty else { return (lines.joined(separator: "\n"), !plan.slices.isEmpty, preview) }
        report(lines.joined(separator: "\n"))
        var done: [String] = []
        // A slice on an EVM network first takes the USDC idle there (ensureEVM brings only what's short, from Solana).
        // Solana needs its own slices plus those shortfalls; what it lacks comes over from networks whose USDC no slice uses.
        // ponytail: idle USDC for a slice on another EVM network goes through Solana; a straight EVM→EVM bridge saves a hop.
        func network(_ place: String) -> String? { AaveV3.market(place: place)?.chain ?? MorphoVault.vault(place: place)?.chain }
        let pulls = Self.pullToSolana(slices: plan.slices.map { (network($0.place), $0.amount) },
                                      idle: idle.map { ($0.net.key, $0.usdc) }, onSolana: onSolana)
        for (key, send) in pulls {
            guard let net = EVMNetwork.named(key) else { continue }
            try await ensureEVM(net, usdc: 0)
            done.append(try await evmToSolana(net, usdc: send))
        }
        // EVM slices first: their shortfall leaves Solana before Solana's own slices spend it.
        for slice in plan.slices.sorted(by: { network($0.place) != nil && network($1.place) == nil }) {
            var piece = slice.amount.rounded(isSOL ? 6 : 2, .down)
            if !isSOL, network(slice.place) == nil {
                // Relay's fees on the way leave Solana a few cents under the plan: a slice takes at most what is there.
                let there = Decimal(try await rpc.tokenBalance(owner: wallet.solana, mint: Relay.Currency.solanaUSDC)) / 1_000_000
                piece = min(piece, there.rounded(2, .down))
            }
            switch slice.place {
            case "Jupiter Lend": done.append(try await lend(asset, amount: piece, deposit: true))
            case "Kamino Lend": done.append(try await self.kamino(asset, amount: piece, deposit: true))
            case "JitoSOL staking": done.append(try await convert(from: SpotAsset.all[0], to: .jitoSOL, amount: piece))
            default:
                if let m = AaveV3.market(place: slice.place) { done.append(try await self.aave(deposit: true, usdc: piece, market: m)) }
                else if let v = MorphoVault.vault(place: slice.place) { done.append(try await self.morpho(deposit: true, usdc: piece, vault: v)) }
            }
        }
        let line = "Spread across \(done.count) \(done.count == 1 ? "protocol" : "protocols")."
        report(line)
        return (line, false, preview)
    }

    /// What comes over to Solana from each EVM network before a spread: a slice on an EVM network (`network` set) takes the
    /// USDC idle there first, Solana needs its own slices plus the rest, and what it lacks comes from the idle USDC no
    /// slice uses, in the order given — a dime over each for Relay's fee, nothing under a bridge's half dollar.
    static func pullToSolana(slices: [(network: String?, amount: Decimal)], idle: [(network: String, usdc: Decimal)],
                             onSolana: Decimal) -> [(network: String, usdc: Decimal)] {
        var spare = Dictionary(idle.map { ($0.network, $0.usdc) }, uniquingKeysWith: +)
        var needs: Decimal = 0
        for slice in slices {
            let use = slice.network.map { min(spare[$0] ?? 0, slice.amount) } ?? 0
            if let key = slice.network { spare[key, default: 0] -= use }
            needs += slice.amount - use
        }
        var short = needs - onSolana, out: [(network: String, usdc: Decimal)] = []
        for (key, _) in idle where short > 0 {
            let send = min(spare[key] ?? 0, short + Decimal(string: "0.1")!).rounded(2, .down)
            guard send >= Decimal(string: "0.5")! else { continue }
            out.append((key, send))
            short -= send
        }
        return out
    }

    /// SOL spent according to a simulation's change lines (the «SOL: −0.0298» line), as a positive number.
    static func solSpent(_ changes: [String]) -> Decimal {
        guard let line = changes.first(where: { $0.hasPrefix("SOL: ") }) else { return 0 }
        let number = line.dropFirst(5).prefix { !$0.isWhitespace }.replacingOccurrences(of: ",", with: "")   // en_US: «,» only groups thousands
            .replacingOccurrences(of: "−", with: "-")
        return max(0, -(Decimal(string: number) ?? 0))
    }

    /// Kamino Lend, main market. `symbol`: USDC, SOL, USDT… `amount` in tokens; withdraw with nil takes the whole
    /// position (USD value for stablecoins). `dryRun` only simulates: the first deposit's rent shows up here.
    /// `acceptRent`: the user asked for Kamino knowing the first deposit's rent, so the 10% rule does not stop it.
    public func kamino(_ symbol: String, amount requested: Decimal?, deposit: Bool, dryRun: Bool = false, acceptRent: Bool = false) async throws -> String {
        guard let reserve = try await Kamino.reserves().first(where: { $0.symbol.uppercased() == symbol.uppercased() }) else {
            throw ExecutionError("Kamino has no \(symbol) market.")
        }
        let native = reserve.mint == "So11111111111111111111111111111111111111112"
        let supply = try await rpc.call("getTokenSupply", [reserve.mint]) as? [String: Any]
        let decimals = ((supply?["value"] as? [String: Any])?["decimals"] as? NSNumber)?.intValue ?? 6
        let scale = Decimal(sign: .plus, exponent: decimals, significand: 1)
        let position = try await Kamino.positions(wallet: wallet.solana).first { $0.reserve == reserve.address }
        // Everything: ask for 1% over the value — Kamino caps a withdrawal at what is there (checked live), so no dust stays.
        let all = !deposit && requested == nil
        guard let amount = requested ?? (deposit ? nil : position.map { ($0.valueUSD * Decimal(string: "1.01")!).rounded(6, .up) }), amount > 0 else {
            throw ExecutionError(deposit ? "How much should go into Kamino?" : "No \(symbol) position in Kamino.")
        }
        let units = NSDecimalNumber(decimal: (amount * scale).rounded(0, .down)).uint64Value
        /// What should come out: the position's value when taking everything, else what was asked.
        let expected = Int64(all ? units * 100 / 101 : units)
        let myToken = try SPL.associatedAccount(owner: wallet.solana, mint: reserve.mint)
        if deposit {
            let have = native ? try await rpc.balance(wallet.solana) : try await rpc.tokenBalance(owner: wallet.solana, mint: reserve.mint)
            guard have >= units else { throw ExecutionError("You have \(Fmt.num(Decimal(have) / scale, maxFraction: 6)) \(symbol); need \(Fmt.num(amount, maxFraction: 6)).") }
        }
        let wire = deposit
            ? try await Kamino.depositTransaction(wallet: wallet.solana, reserve: reserve.address, amount: amount)
            : try await Kamino.withdrawTransaction(wallet: wallet.solana, reserve: reserve.address, amount: amount)
        let lastValid = try await rpc.latestBlockhash().lastValidBlockHeight
        // The first deposit pays rent for the user's Kamino accounts and lookup table; later ones only the fee.
        let firstTime = position == nil && deposit
        var rules: [(String, String, Bool, Int64)] = []
        if !native { rules.append((myToken, symbol, true, deposit ? -Int64(units) : expected * 99 / 100)) }
        let lamports: Int64 = native ? (deposit ? -Int64(units) - (firstTime ? 60_000_000 : 5_000_000) : expected * 99 / 100 - 5_000_000)
                                     : (firstTime ? -60_000_000 : -5_000_000)
        if firstTime, !dryRun, !acceptRent {
            // The first deposit pays ~0.03 SOL of rent for Kamino's user accounts and lookup table. Not worth it for
            // a small amount: simulate first and refuse when the rent is over a tenth of what goes in.
            let preview = try await signAndSend(wire, lastValid: lastValid, owners: [myToken: wallet.solana], rules: rules,
                                                note: "Kamino \(symbol)", lamportsAtLeast: lamports, dryRun: true)
            let solPrice = try await Hyperliquid.markets()["SOL"]?.markPx ?? 0
            let rentSOL = Self.solSpent(preview)
            let valueUSD = native ? amount * solPrice : amount
            if rentSOL * solPrice > valueUSD / 10 {
                throw ExecutionError("The first Kamino deposit creates your accounts: rent ≈ \(Fmt.num(rentSOL, maxFraction: 4)) SOL (≈ \(Fmt.usd(rentSOL * solPrice))) on a \(Fmt.usd(valueUSD)) deposit — over 10% of the amount. For small amounts Jupiter Lend is better; Kamino makes sense from ≈ \(Fmt.usd((rentSOL * solPrice * 10).rounded(0, .up))).")
            }
        }
        let changes = try await signAndSend(wire, lastValid: lastValid, owners: [myToken: wallet.solana], rules: rules,
                                            note: "Kamino \(deposit ? "deposit" : "withdraw") \(symbol)", lamportsAtLeast: lamports, dryRun: dryRun)
        let line = (dryRun ? "Kamino simulation (nothing signed): " : "Kamino \(symbol) \(Fmt.num(reserve.supplyAPY.rounded(2, .plain)))% APY: \(deposit ? "deposited \(Fmt.num(amount, maxFraction: 6)) \(symbol)" : all ? "withdrew everything" : "withdrew \(Fmt.num(amount, maxFraction: 6)) \(symbol)"). ")
            + changes.joined(separator: "; ") + "."
        report(line)
        return line
    }
}

/// «Spread USDC across the best rates» as data, for the studio canvas: where each slice goes and what was skipped.
public struct AllocationPreview: Sendable {
    public let asset: String
    public let free: Decimal
    public let maxShare: Decimal
    public let slices: [Allocation.Slice]
    public let skipped: [(place: String, apy: Decimal, reason: String)]
    public let leftover: Decimal
    public let yearly: Decimal
    public let yearlyUSD: Decimal?
    /// Where the free money is: Solana and each EVM network with idle USDC.
    public var sources: [(place: String, amount: Decimal)] = []
}
