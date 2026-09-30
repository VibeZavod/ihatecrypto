import EVMChain
import ExecutionCore
import HyperliquidSigning
import Foundation
import LalaCore
import RelayBridge
import SolanaChain
import TxGuard
import WalletCore

/// USDC to an address from the user's address book: on Solana directly, on Base from Base USDC (bridged from Solana
/// when short). The recipient is passed to the guard and the signer as the one approved address; nothing else may
/// receive money, and the simulation must show exactly the amount leaving.
extension Executor {
    public enum Destination: Sendable {
        case solana(String)
        case base(String)
        case arbitrum(String)
        /// USDG on Robinhood Chain.
        case robinhood(String)
        /// Another Hyperliquid account: USDC from the perp balance, no bridge.
        case hyperliquid(String)
        case tempo(String)
        case ethereum(String)
        case polygon(String)
    }

    public func sendUSDC(_ amount: Decimal, to destination: Destination, label: String) async throws -> String {
        let units = NSDecimalNumber(decimal: (amount * 1_000_000).rounded(0, .down)).uint64Value
        guard units > 0 else { throw ExecutionError("Nothing to send.") }
        switch destination {
        case .solana(let owner): return try await sendSolanaUSDC(units, to: owner, label: label)
        case .base(let recipient): return try await sendEVMUSDC(units, on: .base, to: recipient, label: label)
        case .arbitrum(let recipient): return try await sendEVMUSDC(units, on: .arbitrum, to: recipient, label: label)
        case .robinhood(let recipient): return try await sendEVMUSDC(units, on: .robinhood, to: recipient, label: label)
        case .hyperliquid(let recipient): return try await sendHyperliquidUSDC(amount, to: recipient, label: label)
        case .tempo(let recipient): return try await sendEVMUSDC(units, on: .tempo, to: recipient, label: label)
        case .ethereum(let recipient): return try await sendEVMUSDC(units, on: .ethereum, to: recipient, label: label)
        case .polygon(let recipient): return try await sendEVMUSDC(units, on: .polygon, to: recipient, label: label)
        }
    }

    /// A payment for a service on Tempo (MPP «charge», push mode): USDC to the payee named in the service's challenge,
    /// with the memo it asked for; what's missing comes from Solana first. The hash is the proof the service checks.
    public func payTempo(_ units: UInt64, to payee: String, memo: Data?, label: String) async throws -> String {
        guard units > 0 else { throw ExecutionError("Nothing to pay.") }
        let net = EVMNetwork.tempo
        // Short there: a dollar comes over (or the price, if more), so the next requests don't each pay a bridge.
        let there = try await net.rpc.tokenBalance(net.usdc, owner: wallet.evm)
        try await ensureEVM(net, usdc: there >= units + net.feeReserve ? units : max(units, Self.tempoFloat))
        let data = try memo.map { try ERC20.transfer(to: payee, amount: units, memo: $0) } ?? ERC20.transfer(to: payee, amount: units)
        return try await sendEVM(net.rpc, to: net.usdc, data: data, note: "Pay \(Self.usdc(units)) USDC to \(label)", recipients: [payee])
    }

    /// What a payment brings to Tempo when it's short there: a dollar, the user's ask (2026-09-30: «предлагай сразу
    /// перевести 1 бакс… чтобы по многу раз не переводить»).
    public static let tempoFloat: UInt64 = 1_000_000

    private func sendEVMUSDC(_ units: UInt64, on net: EVMNetwork, to recipient: String, label: String) async throws -> String {
        try await ensureEVM(net, usdc: units)
        let hash = try await sendEVM(net.rpc, to: net.usdc, data: try ERC20.transfer(to: recipient, amount: units),
                                     note: "Send \(Self.usdc(units)) USDC to \(label)", recipients: [recipient])
        return "Sent \(Self.usdc(units)) USDC to \(label) on \(net.name). \(net.explorer)/tx/\(hash)"
    }

    /// usdSend from the perp balance, signed by the main key (the trading key can't move money out); the guard and the
    /// signer accept only this destination.
    private func sendHyperliquidUSDC(_ amount: Decimal, to destination: String, label: String) async throws -> String {
        // To the micro-dollar, not the cent: «send all» leaves nothing behind.
        let usdc = amount.rounded(6, .down)
        let free = try await Hyperliquid.balance(user: wallet.evm).withdrawable
        guard usdc > 0, usdc <= free else { throw ExecutionError("\(Fmt.usd(free)) free on Hyperliquid; can't send \(Fmt.num(usdc)).") }
        let to = destination.lowercased()
        guard to != wallet.evm.lowercased() else { throw ExecutionError("That is this wallet's own Hyperliquid account.") }
        let time = UInt64(Date().timeIntervalSince1970 * 1000)
        let action = HLSigner.usdSendAction(destination: to, amount: "\(usdc)", time: time, mainnet: true)
        let signature = try await signer.signHyperliquidUser(action, recipients: [to])
        try journal.append(.init(chain: "hyperliquid", id: "\(time)", kind: .signed, note: "send \(Fmt.num(usdc)) USDC to \(label)"))
        let reply = HLReply.parse(try await HLExchange.send(action: action, nonce: time, signature: signature, mainnet: true))
        if case .error(let e) = reply {
            try journal.append(.init(chain: "hyperliquid", id: "\(time)", kind: .failed, note: e))
            throw ExecutionError("Hyperliquid refused the transfer: \(e).")
        }
        try journal.append(.init(chain: "hyperliquid", id: "\(time)", kind: .confirmed, note: "\(reply)"))
        return "Sent \(Fmt.num(usdc)) USDC to \(label) on Hyperliquid."
    }

    static func usdc(_ units: UInt64) -> String { Fmt.num(Decimal(units) / 1_000_000, maxFraction: 6) }

    func sendSolanaUSDC(_ units: UInt64, to owner: String, label: String) async throws -> String {
        let mint = Relay.Currency.solanaUSDC
        let have = try await rpc.tokenBalance(owner: wallet.solana, mint: mint)
        guard have >= units else { throw ExecutionError("\(Self.usdc(have)) USDC on Solana; the transfer needs \(Self.usdc(units)).") }
        let (blockhash, lastValid) = try await rpc.latestBlockhash()
        let unsigned = SolanaTransaction.unsigned(try SPL.transferMessage(payer: wallet.solana, to: owner, mint: mint, amount: units, decimals: 6, blockhash: blockhash))
        let message = try SolanaMessage.parse(transaction: unsigned)
        let mine = try SPL.associatedAccount(owner: wallet.solana, mint: mint)
        let owners = [mine: wallet.solana, try SPL.associatedAccount(owner: owner, mint: mint): owner]
        var verdict = SolanaGuard.check(message, accounts: message.staticKeys, policy: SolanaPolicy(owner: wallet.solana, recipients: [owner]), tokenOwners: owners)
        let solBefore = try await rpc.balance(wallet.solana)
        let simulation = try await rpc.simulate(unsigned, watch: [mine, wallet.solana], sigVerify: false)
        // A failed simulation says nothing about balances: stop here rather than quote made-up changes.
        if let error = simulation.error { throw ExecutionError("The simulation failed, so nothing was signed: \(error)") }
        verdict.merge(SolanaGuard.balances([
            .init(label: "USDC", before: Int64(have), after: Int64(simulation.after[mine]?.token ?? 0), atLeast: -Int64(units)),
            // The fee, plus the recipient's token account rent (≈ 0.002 SOL) when they have none yet.
            .init(label: "lamports", before: Int64(solBefore), after: Int64(simulation.after[wallet.solana]?.lamports ?? 0), atLeast: -3_000_000),
        ]))
        guard verdict.ok else { throw ExecutionError("The guard stopped the transfer: " + verdict.problems.joined(separator: " ")) }
        let signed = try await signer.signSolana(unsigned, accounts: message.staticKeys, recipients: [owner], tokenOwners: owners)
        guard signed.count == unsigned.count, signed.subdata(in: 65..<signed.count) == unsigned.subdata(in: 65..<unsigned.count) else {
            throw ExecutionError("What was signed isn't what was checked.")
        }
        let signature = Base58.encode(signed.subdata(in: 1..<65))
        try journal.append(.init(chain: "solana", id: signature, kind: .signed, note: "send \(Self.usdc(units)) USDC to \(label); valid until block \(lastValid)"))
        _ = try await rpc.send(signed)
        switch try await rpc.waitForConfirmation(signature, lastValidBlockHeight: lastValid) {
        case .confirmed:
            try journal.append(.init(chain: "solana", id: signature, kind: .confirmed))
            return "Sent \(Self.usdc(units)) USDC to \(label) on Solana. https://solscan.io/tx/\(signature)"
        case .failed(let e):
            try journal.append(.init(chain: "solana", id: signature, kind: .failed, note: e))
            throw ExecutionError("The transfer failed: \(e). The money stayed.")
        case .expired:
            try journal.append(.init(chain: "solana", id: signature, kind: .expired))
            throw ExecutionError("The transfer didn't make it into a block; nothing moved. You can retry.")
        }
    }
}

/// Native NEAR and SOL to saved addresses, and closing the wallet's NEAR account. The receiver is passed to the
/// signer as the one approved address (a new one asks for Touch ID there); the signer builds NEAR transactions itself.
extension Executor {
    /// NEAR to a saved NEAR account; nil = all but the account's storage and 0.01 NEAR — a transfer that opens a new
    /// implicit account prepays ≈ 0.0076 NEAR of gas at NEAR's pessimistic price (measured 2026-09-28), refunded after.
    public func sendNear(_ requested: Decimal?, to receiver: String, account: String, label: String) async throws -> String {
        guard receiver != account else { throw ExecutionError("That is this wallet's own NEAR account.") }
        // A named account can't be created by a transfer: sending to one that doesn't exist would only fail.
        if receiver.wholeMatch(of: /[0-9a-f]{64}/) == nil, (try? await Near.balance(account: receiver))?.near ?? 0 == 0 {
            throw ExecutionError("\(receiver) doesn't exist on NEAR: check the name in Addresses.")
        }
        let context = try await Near.txContext(account: account)
        let micro: UInt128 = 1_000_000_000_000_000_000   // 10⁻⁶ NEAR
        let balance = UInt128(context.balance) ?? 0
        let keep = UInt128(context.storageBytes) * 10_000_000_000_000_000_000 + 10_000_000_000_000_000_000_000
        let free = balance > keep ? (balance - keep) / micro * micro : 0
        let yocto = requested.flatMap { UInt128(NSDecimalNumber(decimal: ($0 * 1_000_000).rounded(0, .down)).stringValue) }.map { $0 * micro } ?? free
        guard yocto > 0, yocto <= free else {
            throw ExecutionError("\(NearTransaction.near(free)) NEAR can be sent: the account keeps \(NearTransaction.near(keep)) for its storage and the fee.")
        }
        let signed = try await signer.signNearTransfer(amount: yocto, receiver: receiver, recipients: [receiver], nonce: context.nonce, blockHash: context.blockHash)
        let hash = try await Near.send(signed)
        try journal.append(.init(chain: "near", id: hash, kind: .confirmed, note: "send \(NearTransaction.near(yocto)) NEAR to \(label)"))
        return "Sent \(NearTransaction.near(yocto)) NEAR to \(label). https://nearblocks.io/txns/\(hash)"
    }

    /// Deletes the wallet's NEAR account; NEAR sends everything on it, storage included, to `beneficiary`. Refused
    /// unless the beneficiary exists: NEAR would burn the balance otherwise.
    public func closeNear(into beneficiary: String, account: String, label: String) async throws -> String {
        guard beneficiary != account else { throw ExecutionError("An account can't be closed into itself.") }
        guard (try? await Near.balance(account: beneficiary))?.near ?? 0 > 0 else {
            throw ExecutionError("\(label) doesn't exist on NEAR yet: closing into it would burn the NEAR. Send it a little NEAR first.")
        }
        let context = try await Near.txContext(account: account)
        let signed = try await signer.signNearDeleteAccount(beneficiary: beneficiary, recipients: [beneficiary], nonce: context.nonce, blockHash: context.blockHash)
        let hash = try await Near.send(signed)
        try journal.append(.init(chain: "near", id: hash, kind: .confirmed, note: "NEAR account closed into \(label)"))
        return "Closed your NEAR account: its \(NearTransaction.near(UInt128(context.balance) ?? 0)) NEAR went to \(label). https://nearblocks.io/txns/\(hash)"
    }

    /// SOL to a saved Solana address: only that recipient (the guard and the signer check), and the simulation must
    /// show exactly this SOL leaving, plus the fee.
    public func sendSOL(_ sol: Decimal, to owner: String, label: String) async throws -> String {
        let lamports = NSDecimalNumber(decimal: (sol * 1_000_000_000).rounded(0, .down)).uint64Value
        guard lamports > 0, owner != wallet.solana else { throw ExecutionError(lamports == 0 ? "Nothing to send." : "That is this wallet's own address.") }
        let have = try await rpc.balance(wallet.solana)
        guard have >= lamports + 20_000 else {
            throw ExecutionError("\(Fmt.num(Decimal(have) / 1_000_000_000, maxFraction: 9)) SOL on Solana: not enough for \(Fmt.num(sol, maxFraction: 9)) and the fee.")
        }
        // An empty account opens only with Solana's rent minimum; less than that is refused by the network.
        if try await rpc.balance(owner) == 0, lamports < 890_880 {
            throw ExecutionError("\(label)'s Solana account is empty: Solana opens it only with at least 0.00089088 SOL (its rent minimum). Send at least that.")
        }
        let (blockhash, lastValid) = try await rpc.latestBlockhash()
        let transfer = SolanaInstruction(program: SolanaGuard.system, accounts: [
            .init(pubkey: wallet.solana, isSigner: true, isWritable: true), .init(pubkey: owner, isSigner: false, isWritable: true),
        ], data: Data([2, 0, 0, 0]) + withUnsafeBytes(of: lamports.littleEndian) { Data($0) })
        let unsigned = SolanaTransaction.unsigned(try SolanaTransaction.compileMessage([transfer], payer: wallet.solana, blockhash: blockhash))
        let message = try SolanaMessage.parse(transaction: unsigned)
        var verdict = SolanaGuard.check(message, accounts: message.staticKeys, policy: SolanaPolicy(owner: wallet.solana, recipients: [owner]), tokenOwners: [:])
        let simulation = try await rpc.simulate(unsigned, watch: [wallet.solana], sigVerify: false)
        if let error = simulation.error { throw ExecutionError("The simulation failed, so nothing was signed: \(error)") }
        verdict.merge(SolanaGuard.balances([
            .init(label: "lamports", before: Int64(have), after: Int64(simulation.after[wallet.solana]?.lamports ?? 0), atLeast: -Int64(lamports) - 20_000),
        ]))
        guard verdict.ok else { throw ExecutionError("The guard stopped the transfer: " + verdict.problems.joined(separator: " ")) }
        let signed = try await signer.signSolana(unsigned, accounts: message.staticKeys, recipients: [owner], tokenOwners: [:])
        guard signed.count == unsigned.count, signed.subdata(in: 65..<signed.count) == unsigned.subdata(in: 65..<unsigned.count) else {
            throw ExecutionError("What was signed isn't what was checked.")
        }
        let signature = Base58.encode(signed.subdata(in: 1..<65))
        try journal.append(.init(chain: "solana", id: signature, kind: .signed, note: "send \(Fmt.num(sol, maxFraction: 9)) SOL to \(label); valid until block \(lastValid)"))
        _ = try await rpc.send(signed)
        switch try await rpc.waitForConfirmation(signature, lastValidBlockHeight: lastValid) {
        case .confirmed:
            try journal.append(.init(chain: "solana", id: signature, kind: .confirmed))
            return "Sent \(Fmt.num(sol, maxFraction: 9)) SOL to \(label) on Solana. https://solscan.io/tx/\(signature)"
        case .failed(let e):
            try journal.append(.init(chain: "solana", id: signature, kind: .failed, note: e))
            throw ExecutionError("The transfer failed: \(e). The SOL stayed.")
        case .expired:
            try journal.append(.init(chain: "solana", id: signature, kind: .expired))
            throw ExecutionError("The transfer didn't make it into a block; nothing moved. You can retry.")
        }
    }
}
