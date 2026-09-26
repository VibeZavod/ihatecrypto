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
        /// Another Hyperliquid account: USDC from the perp balance, no bridge.
        case hyperliquid(String)
    }

    public func sendUSDC(_ amount: Decimal, to destination: Destination, label: String) async throws -> String {
        let units = NSDecimalNumber(decimal: (amount * 1_000_000).rounded(0, .down)).uint64Value
        guard units > 0 else { throw ExecutionError("Nothing to send.") }
        switch destination {
        case .solana(let owner): return try await sendSolanaUSDC(units, to: owner, label: label)
        case .base(let recipient): return try await sendEVMUSDC(units, on: .base, to: recipient, label: label)
        case .arbitrum(let recipient): return try await sendEVMUSDC(units, on: .arbitrum, to: recipient, label: label)
        case .hyperliquid(let recipient): return try await sendHyperliquidUSDC(amount, to: recipient, label: label)
        }
    }

    private func sendEVMUSDC(_ units: UInt64, on net: EVMNetwork, to recipient: String, label: String) async throws -> String {
        try await ensureEVM(net, usdc: units)
        let hash = try await sendEVM(net.rpc, to: net.usdc, data: try ERC20.transfer(to: recipient, amount: units),
                                     note: "Send \(Self.usdc(units)) USDC to \(label)", recipients: [recipient])
        return "Sent \(Self.usdc(units)) USDC to \(label) on \(net.name). \(net.explorer)/tx/\(hash)"
    }

    /// usdSend from the perp balance, signed by the main key (the trading key can't move money out); the guard and the
    /// signer accept only this destination.
    private func sendHyperliquidUSDC(_ amount: Decimal, to destination: String, label: String) async throws -> String {
        let usdc = amount.rounded(2, .down)
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

    private func sendSolanaUSDC(_ units: UInt64, to owner: String, label: String) async throws -> String {
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
        if let error = simulation.error { verdict.problems.append("Simulation failed: \(error)") }
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
