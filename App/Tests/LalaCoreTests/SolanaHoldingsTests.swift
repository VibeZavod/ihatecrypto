import Foundation
@testable import LalaCore
import Testing

@Test func solanaHoldingsShowBoughtTokensAndTuckAwayAirdrops() {
    let json = """
    [{"id": "RAYmint", "symbol": "RAY", "icon": "https://cdn/ray.png", "usdPrice": 1.88, "liquidity": 18801373, "isVerified": true, "tags": ["verified"]},
     {"id": "jlUSDCmint", "symbol": "jlUSDC", "usdPrice": 1.06, "isVerified": true, "tags": ["verified", "jup-lend-earn"]},
     {"id": "MEMEmint", "symbol": "POKEMON", "usdPrice": 0.0004, "liquidity": 36500, "isVerified": false, "tags": ["token-2022"]},
     {"id": "SPAMmint", "symbol": "USDC", "usdPrice": 0.000001, "liquidity": 12, "isVerified": false, "tags": []}]
    """
    let amounts: [String: Decimal] = ["RAYmint": Decimal(string: "1.065743")!, "jlUSDCmint": 5, "MEMEmint": 2500, "SPAMmint": 1000, "Unknownmint": 3]
    let held = Solana.holdings(amounts, jupiter: Data(json.utf8))

    // Jupiter Lend's shares are the Jupiter Lend row, not a token.
    #expect(!held.contains { $0.symbol == "jlUSDC" })
    // The most valuable first.
    #expect(held.first?.symbol == "RAY")
    #expect(held.first?.usd == Decimal(string: "1.88")! * Decimal(string: "1.065743")!)

    let bySymbol = Dictionary(uniqueKeysWithValues: held.map { ($0.mint, $0) })
    #expect(bySymbol["RAYmint"]?.looksReal == true)
    // Bought with Safe search off: unverified, but a real pool and ≈ $1 in it.
    #expect(bySymbol["MEMEmint"]?.looksReal == true)
    // A fake «USDC» airdrop: no pool to speak of.
    #expect(bySymbol["SPAMmint"]?.looksReal == false)
    // Jupiter doesn't know it: shown by mint, unpriced, tucked away.
    #expect(bySymbol["Unknownmint"]?.symbol == "Unkn…")
    #expect(bySymbol["Unknownmint"]?.usd == nil)
    #expect(bySymbol["Unknownmint"]?.looksReal == false)
}
