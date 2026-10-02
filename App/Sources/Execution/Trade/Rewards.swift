import EVMChain
import ExecutionCore
import Foundation
import IhatecryptoCore
import WalletCore

/// Rewards on Merkl claimed to this wallet: on each chain, one Distributor call paying every token owed there. The
/// proofs are asked for again right before signing and must be for the root the Distributor holds; the signer checks
/// every reward is paid to this wallet, and each token's balance must grow.
extension Executor {
    public func claimRewards() async throws -> String {
        let me = wallet.evm
        let owed = try await Merkl.rewards(user: me)
        guard !owed.isEmpty else { throw ExecutionError("Nothing to claim on Merkl for this wallet. Nothing was signed.") }
        var lines: [String] = [], claimed = 0
        for chain in Merkl.chains {
            let here = owed.filter { $0.chainId == chain }
            guard !here.isEmpty, let net = EVMNetwork.of(chainId: chain) else { continue }
            let names = here.map { "\(Fmt.num($0.claimable, maxFraction: 6)) \($0.symbol)" }.joined(separator: ", ")
            // Merkl moves its root every few hours: proofs for another one would revert.
            let root = try await Merkl.root(net.rpc)
            guard here.allSatisfy({ $0.root.lowercased() == root.lowercased() }) else {
                lines.append("\(net.name): Merkl is updating its rewards right now; ask again in a few hours. Nothing was signed there.")
                continue
            }
            // A claim is ≈ 265k gas for two tokens (Base, simulated 2026-09-30): Morpho's heavier floor covers it.
            try await ensureEVM(net, usdc: 0, gas: Self.morphoGas)
            let before = try await balances(net.rpc, here, owner: me)
            let hash = try await sendEVM(net.rpc, to: Merkl.distributor, data: try Merkl.claim(user: me, here),
                                         note: "Claim \(names) from Merkl on \(net.name)")
            // A node can answer from a block before the receipt's for a moment: give it up to ten seconds.
            var after = try await balances(net.rpc, here, owner: me)
            for _ in 0..<10 where zip(before, after).contains(where: { $0 >= $1 }) {
                try await Task.sleep(for: .seconds(1))
                after = try await balances(net.rpc, here, owner: me)
            }
            guard zip(before, after).allSatisfy({ $0 < $1 }) else {
                throw ExecutionError("The claim on \(net.name) went through but a balance didn't grow. \(net.explorer)/tx/\(hash)")
            }
            claimed += 1
            lines.append("Claimed \(names) on \(net.name) to this wallet. \(net.explorer)/tx/\(hash)")
        }
        guard claimed > 0 else { throw ExecutionError(lines.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }

    /// «sweep rewards over $10 into USDC»: once Merkl's rewards together are worth the floor (Merkl.sweepFloor), they're
    /// claimed, and each worth a dollar or more is sold for USDC on Solana (Relay's swap, or Uniswap and the bridge — what
    /// leaves more; paying only this wallet); `into` a token, that USDC then buys it. Under the floor nothing is signed and the
    /// line says so, so a schedule of it just waits for its next run. A token that can't be sold doesn't stop the others.
    public func sweepRewards(minUSD: Decimal?, into: String?) async throws -> String {
        let floor = Merkl.sweepFloor(minUSD), me = wallet.evm
        let owed = try await Merkl.rewards(user: me)
        let worth = owed.compactMap(\.worthUSD).reduce(0, +)
        guard worth >= floor else {
            return "Merkl rewards ≈ \(Fmt.usd(worth)), under \(Fmt.usd(floor)): nothing claimed yet, the gas would eat them."
        }
        var lines = [try await claimRewards()]
        for r in Merkl.toSell(owed, into: into) {
            guard let net = EVMNetwork.of(chainId: r.chainId) else { continue }
            do {
                let before = try await rpc.tokenBalance(owner: wallet.solana, mint: SpotAsset.usdc.mint)
                lines.append(try await sellOn(net, r.token, amount: r.claimable))
                guard let into else { continue }
                let after = try await rpc.tokenBalance(owner: wallet.solana, mint: SpotAsset.usdc.mint)
                lines.append(try await buyOn(net, into, usdc: Decimal(after > before ? after - before : 0) / 1_000_000))
            } catch {
                lines.append("\(r.symbol) on \(net.name) stays as it is: \(error.localizedDescription)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Each reward token's balance, in its smallest units (256-bit: an 18-decimal token passes 64 bits at 18.4 tokens).
    private func balances(_ rpc: EVMRPC, _ rewards: [Merkl.Reward], owner: String) async throws -> [Decimal] {
        var out: [Decimal] = []
        for r in rewards {
            let data = try await rpc.read(r.token, try ERC20.balanceOf(owner))
            guard let units = ABI.decimal(in: data, word: 0) else { throw ExecutionError("\(r.symbol) gave no balance on chain \(rpc.chainId).") }
            out.append(units)
        }
        return out
    }
}
