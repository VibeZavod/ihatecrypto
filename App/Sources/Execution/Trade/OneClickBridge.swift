import EVMChain
import ExecutionCore
import Foundation
import IhatecryptoCore
import OneClickKit
import TxGuard
import WalletCore

/// USDC between Solana, Base, Arbitrum and Ethereum through NEAR Intents' 1Click, beside Relay: each bridge quotes both
/// and takes the one that lands more (`bridge`, `solanaToEVM`). 1Click is a deposit to an address its quote names; the
/// live quote must stay within 1% of the one compared, and 1Click itself must have that address bound to our recipient,
/// our refund address, the asset and the amount (DepositGuard) before anything is sent.
extension Executor {
    /// 1Click's asset for USDC on a place: an EVM network's key, or nil for Solana.
    static func oneClickUSDC(_ place: String?) -> String? {
        place.map { OneClick.Asset.usdc(onEVM: $0) } ?? OneClick.Asset.solanaUSDC
    }

    /// What 1Click lands for `units` of USDC from `from` to `to` (nil = Solana), dry: nothing is issued. nil when it doesn't
    /// quote the pair.
    func oneClickQuote(from: String?, to: String?, units: UInt64) async -> OneClick.Quote? {
        guard let origin = Self.oneClickUSDC(from), let destination = Self.oneClickUSDC(to) else { return nil }
        return try? await OneClick.quote(dry: true, origin: origin, destination: destination, amount: "\(units)",
                                         refundTo: from == nil ? wallet.solana : wallet.evm, recipient: to == nil ? wallet.solana : wallet.evm)
    }

    /// The move through 1Click: a fresh quote (within 1% of `compared`), the deposit address checked against what 1Click
    /// bound to it, the USDC sent there from `from` (Solana's own transfer, or an exact ERC-20 transfer the signer asks to
    /// allow in person), then 1Click's states on the running card until it lands. Returns what arrived.
    func oneClickMove(from: String?, to: String?, units: UInt64, compared: Decimal, label: String) async throws -> Decimal {
        guard let origin = Self.oneClickUSDC(from), let destination = Self.oneClickUSDC(to) else { throw ExecutionError("1Click doesn't move USDC there.") }
        let refundTo = from == nil ? wallet.solana : wallet.evm, recipient = to == nil ? wallet.solana : wallet.evm
        let quote = try await OneClick.quote(dry: false, origin: origin, destination: destination, amount: "\(units)", refundTo: refundTo, recipient: recipient)
        guard let deposit = quote.depositAddress else { throw ExecutionError("1Click gave no deposit address. Nothing was sent.") }
        var envelope = Envelope.approve(input: Decimal(units) / 1_000_000, quotedOutput: compared)
        envelope.destination = deposit
        let problems = envelope.violations(input: Decimal(string: quote.amountInFormatted) ?? .greatestFiniteMagnitude,
                                           output: Decimal(string: quote.amountOutFormatted) ?? 0, destination: deposit)
        guard problems.isEmpty else { throw ExecutionError("1Click's price moved past the one compared: " + problems.joined(separator: " ") + " Nothing was sent.") }
        let binding = DepositGuard.check(bound: try await OneClick.boundRequest(depositAddress: deposit), recipient: recipient, refundTo: refundTo,
                                         origin: origin, destination: destination, amount: "\(units)")
        guard binding.ok else { throw ExecutionError("The guard stopped the deposit: " + binding.problems.joined(separator: " ")) }
        let tx: String
        if let from, let net = EVMNetwork.named(from) {
            try await ensureEVM(net, usdc: units)
            tx = try await sendEVM(net.rpc, to: net.usdc, data: try ERC20.transfer(to: deposit, amount: units),
                                   note: "Send \(label) to the 1Click deposit", recipients: [deposit])
        } else {
            tx = String(try await sendSolanaUSDC(units, to: deposit, label: "the 1Click deposit").split(separator: "/").last ?? "")
        }
        try journal.append(.init(chain: "1click", id: deposit, kind: .signed, note: "USDC \(from ?? "solana")→\(to ?? "solana") \(label)"))
        if !tx.isEmpty { try? await OneClick.submitDeposit(txHash: tx, depositAddress: deposit) }
        let s = try await oneClickSettled(deposit, refund: "USDC went back to \(from.map(WalletCommand.placeName) ?? "Solana")", estimate: quote.timeEstimate)
        return Decimal(string: s.amountOutFormatted ?? "") ?? Decimal(string: quote.amountOutFormatted) ?? 0
    }

    /// Whether 1Click is worth taking over Relay for this move: it must land more than Relay's `relayOut` by at least
    /// `oneClickEdge` — its fresh deposit address is one more address to allow by Touch ID, and it takes ≈ 20–30 s against
    /// Relay's few (live 2026-10-05: 1Click landed 1–3 cents more on 5 to 200 USDC). Said either way on the card.
    func oneClickBeats(from: String?, to: String?, units: UInt64, relayOut: Decimal) async -> OneClick.Quote? {
        guard let q = await oneClickQuote(from: from, to: to, units: units), let out = Decimal(string: q.amountOutFormatted) else { return nil }
        let edge = Self.oneClickEdge(Decimal(units) / 1_000_000), better = out - relayOut >= edge
        report("Relay lands ≈ \(Fmt.num(relayOut, maxFraction: 4)) USDC, NEAR Intents' 1Click ≈ \(Fmt.num(out, maxFraction: 4))\(q.timeEstimate.map { " in ≈ \($0) s" } ?? ""): taking "
               + (better ? "1Click — it allows its fresh deposit address by Touch ID first." : "Relay\(out > relayOut ? " (1Click's \(Fmt.usd(out - relayOut)) more isn't worth another Touch ID and the wait)" : "")."))
        return better ? q : nil
    }

    /// What 1Click must land beyond Relay to be taken: 10 cents, or 0.05% of a bigger move.
    static func oneClickEdge(_ usdc: Decimal) -> Decimal { max(Decimal(string: "0.10")!, usdc * Decimal(string: "0.0005")!) }
}
