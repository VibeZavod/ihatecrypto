import Foundation
import IhatecryptoCore
import JupiterSwap
import TradeExecution

/// `WalletCheck stables [network]`: every stablecoin of the big five ihatecrypto knows on each network (Stablecoins),
/// quoted live both ways against USDC — 2 USDC in, then 2 of the coin back — by the same code the cards use. Nothing is
/// signed; the wallet only prices the quotes. A line per pair, ✗ with the reason when there's no route.
func stablesCheck(_ only: String?) async {
    let executor = Executor(wallet: TradeWallet(solana: "7WktogJEd2wQ9eH2oWusmcoFTgeYi6rS632UviTBJ2jm", evm: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"),
                            signer: DryRunSigner(wallet: TradeWallet(solana: "", evm: "")), journal: journal, rpc: rpc) { _ in }
    var failed = 0
    for network in Stablecoins.byNetwork.keys.sorted() where only == nil || only == network {
        let usdc = Stablecoins.find("USDC", on: network)!
        for coin in Stablecoins.byNetwork[network]! where coin.symbol != "USDC" {
            for (a, b) in [(usdc, coin), (coin, usdc)] {
                let line: String
                do {
                    switch network {
                    case "solana":
                        let q = try await Jupiter.quote(input: a.address, output: b.address, amount: UInt64(2 * pow(10, Double(a.decimals))))
                        line = "\(Fmt.num(Decimal(q.outAmount) / pow(10, b.decimals), maxFraction: 4)) \(b.symbol) · Jupiter \(q.route)"
                    case "hyperliquid":
                        line = try await (a.symbol == "USDC" ? Executor.spotQuote(b.symbol, usdc: 2, sell: nil) : Executor.spotQuote(a.symbol, usdc: nil, sell: 2)) ?? "?"
                    case "near":
                        let q = try await executor.intentQuoteText(a.symbol, on: "near", for: b.symbol, on: "near", amount: 2, near: nil)
                        line = "\(q.gets) · \(q.way)"
                    default:
                        let q = try await executor.pairQuote(EVMNetwork.named(network)!, from: a.symbol, to: b.symbol, amount: 2)
                        line = "\(q.gets) · \(q.way)"
                    }
                    print("✓ \(network) 2 \(a.symbol) → \(line)")
                } catch {
                    failed += 1
                    print("✗ \(network) 2 \(a.symbol) → \(b.symbol): \(error.localizedDescription)")
                }
            }
        }
    }
    // Across networks (Relay's cross-chain swap, NEAR Intents where Relay has no route): each coin to its own kind on Solana.
    if only == nil || only == "across" {
        for (a, from, b, to) in [("USDT", "arbitrum", "USDT", "solana"), ("USDe", "base", "USDe", "solana"), ("USDS", "ethereum", "USDS", "solana"),
                                 ("DAI", "polygon", "USDC", "solana"), ("USDT", "bnb", "USDC", "base"), ("USDC", "solana", "USDT", "near")] {
            do {
                let q = try await executor.crossQuoteText(a, on: from, for: b, on: to, amount: 2)
                print("✓ across 2 \(a) on \(from) → \(q.gets) on \(to) · \(q.way)")
            } catch {
                failed += 1
                print("✗ across 2 \(a) on \(from) → \(b) on \(to): \(error.localizedDescription)")
            }
        }
    }
    print(failed == 0 ? "All quoted." : "\(failed) without a quote.")
}
