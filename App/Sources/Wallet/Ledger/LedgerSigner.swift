import CryptoKit
import EVMChain
import Foundation
import HyperliquidSigning
import SolanaChain
import TradeExecution
import TxGuard
import WalletCore

/// A Ledger as the wallet a move signs with. The same guard the signing process runs checks each request first, then
/// the device shows it and waits for the person's buttons. What comes back is checked against the Ledger's own
/// address before it is used, so a swapped or confused device can't slip a stranger's signature into a move.
public struct LedgerSigner: TradeSigner {
    public let device: LedgerDevice
    public let wallet: TradeWallet
    public var evmPath = LedgerDevice.evmPath
    public var solanaPath = LedgerDevice.solanaPath
    /// What the person has to do on the device now («Open the Solana app…», «Review … on your Ledger»); nil when done.
    public let prompt: @Sendable (String?) -> Void

    public init(device: LedgerDevice, wallet: TradeWallet, evmPath: String = LedgerDevice.evmPath, solanaPath: String = LedgerDevice.solanaPath,
                prompt: @escaping @Sendable (String?) -> Void = { _ in }) {
        (self.device, self.wallet, self.evmPath, self.solanaPath, self.prompt) = (device, wallet, evmPath, solanaPath, prompt)
    }

    /// `hash`: what the device shows when it can't show the details (blind signing), so the person can compare it
    /// with the one ihatecrypto checked: the Solana message's SHA-256 in base58, the EVM transaction's hash, the
    /// typed data's message hash.
    func onDevice<T: Sendable>(_ app: String, _ what: String, hash: String, _ body: () async throws -> T) async throws -> T {
        defer { prompt(nil) }
        prompt("Open the \(app) app on your Ledger (allow it on the device if it asks).")
        try await device.open(app)
        prompt("Review on your Ledger and approve: \(what). If it shows a hash, it is \(hash.prefix(6))…\(hash.suffix(4)).")
        return try await body()
    }

    static func refuse(_ verdict: Verdict) -> ExecutionError { ExecutionError(verdict.problems.joined(separator: " ")) }

    public func signSolana(_ wire: Data, accounts: [String], recipients: [String], tokenOwners: [String: String]) async throws -> Data {
        let verdict = SolanaGuard.check(try SolanaMessage.parse(transaction: wire), accounts: accounts,
                                        policy: SolanaPolicy(owner: wallet.solana, recipients: Set(recipients)), tokenOwners: tokenOwners)
        guard verdict.ok else { throw Self.refuse(verdict) }
        let payer = try Base58.decode(wallet.solana)
        let (message, slot) = try SolanaTransaction.unsigned(wire, payer: payer)
        let what = verdict.checks.first { $0.contains("→") } ?? "a Solana transaction"
        let hash = Base58.encode(Data(SHA256.hash(data: message)))
        let signature = try await onDevice("Solana", what, hash: hash) { try await device.signSolana(message, path: solanaPath) }
        guard try Curve25519.Signing.PublicKey(rawRepresentation: payer).isValidSignature(signature, for: message) else {
            throw LedgerError("The Ledger's signature isn't from \(wallet.solana): is it the Ledger you connected?")
        }
        var signed = wire
        signed.replaceSubrange(slot, with: signature)
        return signed
    }

    /// The same calldata rules as the signing process: known networks, no unlimited approvals, tokens only to us or
    /// to an approved address.
    public func signEVM(chainId: UInt64, nonce: UInt64, maxPriorityFee: UInt64, maxFee: UInt64, gasLimit: UInt64,
                        to: String, data: Data, recipients: [String]) async throws -> Data {
        guard EVMRPC.signable.contains(chainId) else { throw ExecutionError("ihatecrypto doesn't sign for network \(chainId).") }
        let call = EVMCall.decode(data)
        if let refusal = call.refusal(sender: wallet.evm) { throw ExecutionError(refusal) }
        if case .transfer(let recipient, _) = call, !(recipients + [wallet.evm]).contains(where: { $0.lowercased() == recipient.lowercased() }) {
            throw ExecutionError("Tokens would go to an unapproved address \(recipient).")
        }
        let tx = EVMTransaction(chainId: chainId, nonce: nonce, maxPriorityFeePerGas: maxPriorityFee, maxFeePerGas: maxFee,
                                gasLimit: gasLimit, to: to, value: 0, data: data)
        let hash = try tx.signingHash()
        let raw = try await onDevice("Ethereum", call.summary(chainId: chainId, to: to, value: 0), hash: "0x" + hash.hex) {
            try await device.signEVMTransaction(try tx.unsignedPayload(), path: evmPath)
        }
        // The device's first byte is the parity for a typed transaction; recovering both settles it either way.
        for parity in [Int(raw.v & 1), Int(raw.v & 1) ^ 1] {
            let signature = EVMSignature(r: raw.r, s: raw.s, v: 27 + parity)
            if try EVMSigner.recover(digest: hash, signature: signature).lowercased() == wallet.evm.lowercased() {
                return try tx.signed(with: signature).raw
            }
        }
        throw LedgerError("The Ledger's signature isn't from \(wallet.evm): is it the Ledger you connected?")
    }

    /// Typed data by hash; the signature must recover to the Ledger's address.
    func typed(_ parts: EIP712.Parts, _ what: String) async throws -> EVMSignature {
        let signature = try await onDevice("Ethereum", what, hash: "0x" + parts.message.hex) { try await device.signTypedDataHashes(parts, path: evmPath) }
        guard try EVMSigner.recover(digest: parts.digest, signature: signature).lowercased() == wallet.evm.lowercased() else {
            throw LedgerError("The Ledger's signature isn't from \(wallet.evm): is it the Ledger you connected?")
        }
        return signature
    }

    public func signHyperliquid(_ action: MsgPack, nonce: UInt64) async throws -> EVMSignature {
        let verdict = HLGuard.check(action, owner: wallet.evm, recipients: [])
        guard verdict.ok else { throw Self.refuse(verdict) }
        return try await typed(try HLSigner.l1Parts(action, nonce: nonce, mainnet: true), "a Hyperliquid order (hashes)")
    }

    public func signHyperliquidUser(_ action: MsgPack, recipients: [String]) async throws -> EVMSignature {
        let verdict = HLGuard.check(action, owner: wallet.evm, recipients: Set(recipients))
        guard verdict.ok else { throw Self.refuse(verdict) }
        let (type, fields) = try HLSigner.userAction(action)
        return try await typed(try HLSigner.userParts(type, fields: fields, mainnet: true), "a Hyperliquid transfer (hashes)")
    }

    public func signRelayMapping(wallet w: String, depositor: String, id: Data, nonce: UInt64) async throws -> EVMSignature {
        guard w.lowercased() == wallet.evm.lowercased(), depositor.lowercased() == wallet.evm.lowercased() else {
            throw ExecutionError("The deposit mapping isn't for your Ledger: \(w), \(depositor).")
        }
        return try await typed(try HLSigner.relayNonceMappingParts(wallet: w, depositor: depositor, id: id, nonce: nonce), "link a withdrawal to a Relay order (hashes)")
    }

    public func signNearIntentDeposit(amount: UInt128, depositAddress: String, nonce: UInt64, blockHash: Data) async throws -> Data {
        throw ExecutionError("NEAR isn't signed on a Ledger in ihatecrypto yet: switch to one of ihatecrypto's own wallets for NEAR.")
    }
}
