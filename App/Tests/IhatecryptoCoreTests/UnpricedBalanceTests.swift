import Foundation
import Testing
@testable import IhatecryptoCore

/// Jupiter didn't answer: the tokens keep the last read's prices, so their money stays in the balance.
@Test func unpricedTokensKeepTheLastPrice() {
    let usdt = Holding(chain: "solana", contract: "Es9v", amount: 25, symbol: "USDT", price: 1, verified: true)
    let came = Holding(chain: "solana", contract: "Es9v", amount: 24, symbol: "Es9v…")
    let read = Solana.Balance(sol: 0, usdc: 0, tokens: [came], unpriced: true)

    let kept = read.pricing(from: [usdt])
    #expect(kept.tokens.first?.usd == 24 && kept.tokens.first?.symbol == "USDT" && kept.tokens.first?.verified == true)
    #expect(!kept.unpriced)
    // A token the last read didn't have: still unpriced, so the balance waits for the next read.
    #expect(read.pricing(from: []).unpriced)
    // A priced read is left as it came.
    let priced = Solana.Balance(sol: 0, usdc: 0, tokens: [usdt.at(3)])
    #expect(priced.pricing(from: [usdt]) == priced)
}
