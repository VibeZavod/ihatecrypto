import EVMChain
import Foundation
import LalaCore
import SwiftUI
import TradeExecution

/// USDC in an Aave market or a Morpho vault off Base (Base's own are in `Workspace.base`).
struct LendingPosition: Equatable, Identifiable {
    var id: String { place }
    /// «Aave · Arbitrum», «Morpho · Ethereum».
    let place: String
    let usdc: Decimal
    /// % a year; read only for a position with money in it.
    let apy: Decimal?

    var network: String { place.components(separatedBy: " · ").last ?? "" }
}

extension Workspace {
    var lendingElsewhereUSD: Decimal { lendingElsewhere.reduce(0) { $0 + $1.usdc } }

    /// Aave's aUSDC and Morpho's vault value on Arbitrum, Polygon and Ethereum, read at once. A place that doesn't
    /// answer keeps its last reading instead of dropping out of the total.
    func loadLending() async {
        guard isEVMAddress(hlAddress) else { return }
        let me = hlAddress
        let read = await withTaskGroup(of: (String, LendingPosition?).self) { group in
            for m in AaveV3.markets where m.chain != "base" {
                group.addTask {
                    guard let units = try? await m.rpc.tokenBalance(m.aUSDC, owner: me) else { return (m.place, nil) }
                    return (m.place, LendingPosition(place: m.place, usdc: Decimal(units) / 1_000_000, apy: units > 0 ? (try? await AaveV3.verify(m)) : nil))
                }
            }
            for v in MorphoVault.vaults where v.chain != "base" {
                group.addTask {
                    guard let units = try? await MorphoVault.value(me, v) else { return (v.place, nil) }
                    return (v.place, LendingPosition(place: v.place, usdc: Decimal(units) / 1_000_000, apy: units > 0 ? await MorphoRates.netAPY(v) : nil))
                }
            }
            var out: [(String, LendingPosition?)] = []
            for await r in group { out.append(r) }
            return out
        }
        let found = read.compactMap { place, p in p ?? lendingElsewhere.first { $0.place == place } }
            .filter { $0.usdc > 0 }.sorted { $0.place < $1.place }
        if found != lendingElsewhere { lendingElsewhere = found }
    }
}

/// A lending position off Base on the portfolio card: the protocol's logo with the network's, the rate, the USDC.
struct LendingRow: View {
    let position: LendingPosition

    var body: some View {
        let morpho = position.place.hasPrefix("Morpho")
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                TokenLogo(name: morpho ? "morpho" : "aave", size: 34)
                TokenLogo(name: ["Arbitrum": "arb", "Polygon": "pol", "Ethereum": "eth"][position.network] ?? "base", size: 15).offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(position.place).font(.ui(14, .semibold))
                Text("earning" + (position.apy.map { " \(Fmt.num($0.rounded(2, .plain)))%" } ?? "")).font(.ui(10)).foregroundStyle(Color(hex: 0x2F6FEB))
            }
            Spacer()
            HStack(spacing: 4) {
                TokenLogo(name: "usdc", size: 15)
                Text(Fmt.num(position.usdc)).font(.ui(13, .bold)).monospacedDigit()
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(light: 0xE6EEFF, dark: 0x0F1C3A)))
        .help("Say “withdraw USDC from \(morpho ? "Morpho" : "Aave") on \(position.network)” to bring it back to Solana")
    }
}
