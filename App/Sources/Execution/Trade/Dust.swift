import EVMChain
import Foundation
import IhatecryptoCore

extension Executor {
    /// A token to sweep: on which network, its contract and symbol, and what the portfolio says it's worth.
    public struct Dust: Sendable {
        public let chain: String
        public let contract: String
        public let symbol: String
        public let usd: Decimal
        public init(chain: String, contract: String, symbol: String, usd: Decimal) {
            self.chain = chain; self.contract = contract; self.symbol = symbol; self.usd = usd
        }
    }

    /// The networks dust is swept on: their gas costs cents, so a dollar of a token is worth selling there.
    public static let dustNetworks = ["base", "arbitrum", "polygon"]

    /// Leftover tokens into USDC on their own networks, one sale each (Uniswap, the USDC kept there): each one quoted first,
    /// and left alone when there's no route or its gas would take half of what it brings. What was swept and what was left,
    /// in a line each.
    public func sweepDust(_ tokens: [Dust]) async throws -> String {
        var swept: [String] = [], left: [String] = [], got: Decimal = 0
        for t in tokens {
            guard let net = EVMNetwork.named(t.chain), let uni = UniswapV3.on(net.rpc.chainId) else { left.append("\(t.symbol): not on a network dust is swept on"); continue }
            do {
                let token = try await evmToken(t.contract, on: net)
                let held = try await balance(token.address, on: net.rpc)
                guard held > 0, let best = await bestUniswap(on: net, uni, from: token.address, to: net.usdc, amountIn: held) else {
                    left.append("\(t.symbol) on \(net.name): no Uniswap route to USDC"); continue
                }
                let out = best.out / 1_000_000, gas = try await gasUSD(best.gas, on: net, uni)
                guard gas * 2 < out else { left.append("\(t.symbol) on \(net.name): \(Fmt.usd(out)) would cost \(Fmt.usd(gas)) of gas"); continue }
                report("Dust: \(t.symbol) on \(net.name) → ≈ \(Fmt.num(out)) USDC on \(best.title), \(Fmt.usd(gas)) of gas.")
                let line = try await sellOn(net, token.address, amount: nil, keep: true)
                got += out
                swept.append("\(t.symbol) on \(net.name)")
                report(line)
            } catch {
                left.append("\(t.symbol) on \(t.chain): \(error.localizedDescription)")
            }
        }
        guard !swept.isEmpty else {
            throw ExecutionError(tokens.isEmpty ? "No dust to sweep: no verified token under the limit on Base, Arbitrum or Polygon." :
                "Nothing swept: " + left.joined(separator: "; ") + ".")
        }
        return "Swept \(swept.count) token\(swept.count == 1 ? "" : "s") into ≈ \(Fmt.num(got)) USDC: \(swept.joined(separator: ", "))."
            + (left.isEmpty ? "" : " Left: " + left.joined(separator: "; ") + ".")
    }
}
