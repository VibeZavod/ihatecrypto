import EVMChain
import ExecutionCore
import Foundation
import WalletCore

/// Safe multisigs: making one, and paying out of one with its owners' signatures.
extension Executor {
    /// Makes the multisig on `net`: one call from this wallet to Safe's factory, the fee paid here. Its address is known
    /// before (Safe.address); one already there is left as it is. Returns that address.
    public func createMultisig(_ net: EVMNetwork, owners: [String], threshold: Int, salt: UInt64) async throws -> String {
        let address = try Safe.address(owners: owners, threshold: threshold, salt: salt)
        if try await Self.deployed(address, on: net) {
            report("The multisig \(address) is on \(net.name) already.")
            return address
        }
        _ = try await sendEVM(net.rpc, to: Safe.factory, data: try Safe.create(owners: owners, threshold: threshold, salt: salt),
                              note: "Create the multisig on \(net.name)")
        // The receipt can come from a node a few seconds ahead of the one asked next (Base's public nodes, 2026-10-09).
        for _ in 0..<20 {
            if try await Self.deployed(address, on: net) { return address }
            try await Task.sleep(for: .seconds(1))
        }
        throw ExecutionError("The multisig isn't at \(address) on \(net.name) 20 s after its transaction went through: check \(net.explorer)/address/\(address).")
    }

    /// Whether a contract is at `address` on `net`.
    public static func deployed(_ address: String, on net: EVMNetwork) async throws -> Bool {
        ((try await net.rpc.call("eth_getCode", [address, "latest"]) as? String) ?? "0x").count > 2
    }

    /// Whether `address` is a contract rather than a key a person signs with. A wallet delegated by EIP-7702 (its code is
    /// 0xef0100 ‖ the delegate: MetaMask's smart account, Batch7702) still signs with its own key, so it counts as a person's.
    public static func isContract(_ address: String, on net: EVMNetwork) async throws -> Bool {
        let code = ((try await net.rpc.call("eth_getCode", [address, "latest"]) as? String) ?? "0x").lowercased()
        return code.count > 2 && !(code.hasPrefix("0xef0100") && code.count == 2 + 46)
    }

    /// A payment out of the multisig `safe` on `net` — `value` wei of the coin to `to`, or a token's transfer as `data` to
    /// the token `to`. Each of `cosigners` that holds one of its keys signs the move (Touch ID, a Ledger's buttons) until
    /// enough have; then this wallet sends it with their signatures and pays its gas: the multisig needs none of the coin.
    public func multisigPay(_ net: EVMNetwork, safe: String, to: String, value: UInt64, data: Data, cosigners: [any TradeSigner],
                            recipients: [String], note: String) async throws -> String {
        let rpc = net.rpc
        guard let nonce = ABI.uint(in: try await rpc.read(safe, Safe.nonceCall), word: 0),
              let threshold = ABI.uint(in: try await rpc.read(safe, Safe.thresholdCall), word: 0),
              let owners = Safe.owners(in: try await rpc.read(safe, Safe.ownersCall)) else {
            throw ExecutionError("\(safe) doesn't answer as a multisig on \(net.name). Nothing was signed.")
        }
        // What it pays must be there before anyone signs.
        if case .transfer(_, let amount) = EVMCall.decode(data) {
            let held = ABI.decimal(in: try await rpc.read(to, try ERC20.balanceOf(safe)), word: 0) ?? 0
            let units = amount.reduce(Decimal(0)) { $0 * 256 + Decimal($1) }
            guard held >= units else { throw ExecutionError("The multisig holds less of that token on \(net.name) than this move pays. Nothing was signed.") }
        } else if value > (try await rpc.balance(safe)) {
            throw ExecutionError("The multisig holds less \(net.gasCoin) on \(net.name) than this move pays. Nothing was signed.")
        }
        let move = Safe.Move(chainId: rpc.chainId, safe: safe, to: to, value: value, data: data, nonce: nonce)
        let hash = try move.hash()
        let keys = Set(owners.map { $0.lowercased() })
        var signatures: [(owner: String, signature: EVMSignature)] = []
        for cosigner in cosigners where signatures.count < Int(threshold) {
            let signature = try await cosigner.signSafeMove(move, recipients: recipients)
            let owner = try EVMSigner.recover(digest: hash, signature: signature).lowercased()
            guard keys.contains(owner) else { throw ExecutionError("\(owner) isn't one of the multisig's keys. Nothing was sent.") }
            if !signatures.contains(where: { $0.owner == owner }) { signatures.append((owner, signature)) }
        }
        guard signatures.count >= Int(threshold) else {
            throw ExecutionError("The multisig needs \(threshold) signatures and only \(signatures.count) of its keys are here. Nothing was sent.")
        }
        report("Signed by \(signatures.count) of its keys, as many as it needs: sending the move.")
        return try await sendEVM(rpc, to: safe, data: try move.exec(signatures), note: note, recipients: recipients)
    }
}
