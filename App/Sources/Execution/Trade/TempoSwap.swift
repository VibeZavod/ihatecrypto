import EVMChain
import ExecutionCore
import Foundation
import IhatecryptoCore
import RelayBridge
import WalletCore

/// Stablecoins for one another on Tempo through its own exchange (Tempo.exchange): USDC (Stargate's USDC.e there),
/// pathUSD, OUSD and USDT0. An exact approve to the exchange, then the swap at no less than 0.1% under its quote; what
/// comes out pays this wallet. Fees come out of the USDC, as every Tempo call's do. Measured 2026-10-06: USDC ↔ OUSD
/// 1 bp and USDC ↔ pathUSD 2 bp, the same at $1000; USDT0 had no liquidity.
extension Executor {
    static func tempoStable(_ ref: String) -> (symbol: String, address: String)? {
        let key = ref.uppercased() == "USDC.E" ? "USDC" : (Stablecoins.find(ref, on: "tempo")?.symbol ?? ref).uppercased()
        return Tempo.stables[key].map { (key == "PATHUSD" ? "pathUSD" : key, $0) }
    }

    /// What the exchange gives now for `amount` of one dollar in another (nil = all of it; all of USDC leaves a cent
    /// for fees). Nothing is signed. `quoteOnly`: for the card, priced at the amount asked even when the wallet holds less.
    public func tempoQuote(from a: String, to b: String, amount: Decimal?, quoteOnly: Bool = false) async throws -> (units: UInt64, out: UInt64, from: String, to: String) {
        guard let x = Self.tempoStable(a), let y = Self.tempoStable(b), x.address != y.address else {
            throw ExecutionError("Tempo's exchange trades USDC, pathUSD, OUSD and USDT0 for one another.")
        }
        let rpc = EVMNetwork.tempo.rpc
        let held = try await rpc.tokenBalance(x.address, owner: wallet.evm)
        let units = amount.map { NSDecimalNumber(decimal: ($0 * 1_000_000).rounded(0, .down)).uint64Value } ?? (x.symbol == "USDC" ? held - min(held, 10_000) : held)
        guard units > 0 else { throw ExecutionError("No \(x.symbol) on Tempo to swap.") }
        guard units <= held || quoteOnly && amount != nil else { throw ExecutionError("\(Fmt.num(Decimal(held) / 1_000_000)) \(x.symbol) on Tempo: \(Fmt.num(Decimal(units) / 1_000_000)) is more. Nothing was signed.") }
        let answer: Data
        do { answer = try await rpc.read(Tempo.exchange, try Tempo.quote(x.address, y.address, units: units)) } catch {
            throw ExecutionError("Tempo's exchange has no \(x.symbol) → \(y.symbol) liquidity for \(Fmt.num(Decimal(units) / 1_000_000)) now. Nothing was signed.")
        }
        guard let out = ABI.uint(in: answer, word: 0), out > 0 else { throw ExecutionError("Tempo's exchange didn't quote \(x.symbol) → \(y.symbol).") }
        return (units, out, x.symbol, y.symbol)
    }

    /// Relay's swap on Tempo where Tempo's own exchange has no liquidity for the pair (USDT0, 2026-10-08): what goes in,
    /// in units, and Relay's checked quote. nil when Relay doesn't quote it either.
    func tempoRelay(from a: String, to b: String, amount: Decimal?, quoteOnly: Bool) async throws -> (units: UInt64, x: (symbol: String, address: String), y: (symbol: String, address: String), out: Decimal, quote: Relay.Quote, call: Relay.EVMStep, proxy: String)? {
        guard let x = Self.tempoStable(a), let y = Self.tempoStable(b), x.address != y.address else { return nil }
        let held = try await EVMNetwork.tempo.rpc.tokenBalance(x.address, owner: wallet.evm)
        let units = amount.map { NSDecimalNumber(decimal: ($0 * 1_000_000).rounded(0, .down)).uint64Value } ?? (x.symbol == "USDC" ? held - min(held, 10_000) : held)
        guard units > 0, units <= held || quoteOnly && amount != nil,
              let r = try? await relayPairQuote(.tempo, from: x.address, to: y.address, units: Decimal(units), capped: !quoteOnly) else { return nil }
        return (units, x, y, r.out, r.quote, r.call, r.proxy)
    }

    public func tempoSwap(from a: String, to b: String, amount: Decimal?) async throws -> String {
        let q: (units: UInt64, out: UInt64, from: String, to: String)
        do { q = try await tempoQuote(from: a, to: b, amount: amount) } catch {
            guard let r = try await tempoRelay(from: a, to: b, amount: amount, quoteOnly: false) else { throw error }
            let net = EVMNetwork.tempo, what = "\(Fmt.num(Decimal(r.units) / 1_000_000, maxFraction: 6)) \(r.x.symbol)"
            report("\(what) → \(r.y.symbol) on Tempo through Relay's swap (Tempo's exchange has no liquidity for it): ≈ \(Fmt.num(r.out / 1_000_000, maxFraction: 6)) \(r.y.symbol).")
            let before = try await net.rpc.tokenBalance(r.y.address, owner: wallet.evm)
            let hash = try await approveAndSend(net.rpc, token: r.x.address, spender: r.proxy, units: Decimal(r.units), approveNote: "Approve exactly \(what) to Relay",
                                                to: r.call.to, data: r.call.data, note: "Relay: swap \(what) for \(r.y.symbol) on Tempo")
            try journal.append(.init(chain: "relay", id: r.quote.requestId, kind: .signed, note: "Tempo \(r.x.symbol)→\(r.y.symbol), tx \(hash)"))
            var after = before
            for _ in 0..<20 where after <= before {
                try await Task.sleep(for: .seconds(1))
                after = try await net.rpc.tokenBalance(r.y.address, owner: wallet.evm)
            }
            return "Swapped \(what) for \(Fmt.num(Decimal(after > before ? after - before : 0) / 1_000_000, maxFraction: 6)) \(r.y.symbol) on Tempo through Relay's swap. \(net.explorer)/tx/\(hash)"
        }
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
