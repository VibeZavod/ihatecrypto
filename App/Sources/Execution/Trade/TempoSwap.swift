import EVMChain
import ExecutionCore
import Foundation
import IhatecryptoCore
import WalletCore

/// Stablecoins for one another on Tempo through its own exchange (Tempo.exchange): USDC (Stargate's USDC.e there),
/// pathUSD, OUSD and USDT0. An exact approve to the exchange, then the swap at no less than 0.1% under its quote; what
/// comes out pays this wallet. Fees come out of the USDC, as every Tempo call's do. Measured 2026-10-06: USDC ↔ OUSD
/// 1 bp and USDC ↔ pathUSD 2 bp, the same at $1000; USDT0 had no liquidity.
extension Executor {
    static func tempoStable(_ ref: String) -> (symbol: String, address: String)? {
        let key = ref.uppercased() == "USDC.E" ? "USDC" : ref.uppercased()
        return Tempo.stables[key].map { (key == "PATHUSD" ? "pathUSD" : key, $0) }
    }

    /// What the exchange gives now for `amount` of one dollar in another (nil = all of it; all of USDC leaves a cent
    /// for fees). Nothing is signed.
    public func tempoQuote(from a: String, to b: String, amount: Decimal?) async throws -> (units: UInt64, out: UInt64, from: String, to: String) {
        guard let x = Self.tempoStable(a), let y = Self.tempoStable(b), x.address != y.address else {
            throw ExecutionError("Tempo's exchange trades USDC, pathUSD, OUSD and USDT0 for one another.")
        }
        let rpc = EVMNetwork.tempo.rpc
        let held = try await rpc.tokenBalance(x.address, owner: wallet.evm)
        let units = amount.map { NSDecimalNumber(decimal: ($0 * 1_000_000).rounded(0, .down)).uint64Value } ?? (x.symbol == "USDC" ? held - min(held, 10_000) : held)
        guard units > 0 else { throw ExecutionError("No \(x.symbol) on Tempo to swap.") }
        guard units <= held else { throw ExecutionError("\(Fmt.num(Decimal(held) / 1_000_000)) \(x.symbol) on Tempo: \(Fmt.num(Decimal(units) / 1_000_000)) is more. Nothing was signed.") }
        let answer: Data
        do { answer = try await rpc.read(Tempo.exchange, try Tempo.quote(x.address, y.address, units: units)) } catch {
            throw ExecutionError("Tempo's exchange has no \(x.symbol) → \(y.symbol) liquidity for \(Fmt.num(Decimal(units) / 1_000_000)) now. Nothing was signed.")
        }
        guard let out = ABI.uint(in: answer, word: 0), out > 0 else { throw ExecutionError("Tempo's exchange didn't quote \(x.symbol) → \(y.symbol).") }
        return (units, out, x.symbol, y.symbol)
    }

    public func tempoSwap(from a: String, to b: String, amount: Decimal?) async throws -> String {
        let q = try await tempoQuote(from: a, to: b, amount: amount)
        guard let x = Self.tempoStable(a), let y = Self.tempoStable(b) else { throw ExecutionError("Unknown dollar on Tempo.") }
        guard Decimal(q.out) >= Decimal(q.units) * Decimal(string: "0.99")! else {
            throw ExecutionError("Tempo's exchange gives \(Fmt.num(Decimal(q.out) / 1_000_000)) \(q.to) for \(Fmt.num(Decimal(q.units) / 1_000_000)) \(q.from): more than 1% off a dollar. Nothing was signed.")
        }
        let net = EVMNetwork.tempo, what = "\(Fmt.num(Decimal(q.units) / 1_000_000, maxFraction: 6)) \(q.from)"
        let before = try await net.rpc.tokenBalance(y.address, owner: wallet.evm)
        try await approve(net.rpc, token: x.address, spender: Tempo.exchange, units: Decimal(q.units), note: "Approve exactly \(what) to Tempo's exchange")
        let hash = try await sendEVM(net.rpc, to: Tempo.exchange, data: try Tempo.swap(x.address, y.address, units: q.units, minOut: q.out - q.out / 1000),
                                     note: "Swap \(what) for \(q.to) on Tempo")
        let after = try await net.rpc.tokenBalance(y.address, owner: wallet.evm)
        return "Swapped \(what) for \(Fmt.num(Decimal(after > before ? after - before : 0) / 1_000_000, maxFraction: 6)) \(q.to) on Tempo's exchange. \(net.explorer)/tx/\(hash)"
    }
}
