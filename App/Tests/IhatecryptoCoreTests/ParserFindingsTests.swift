import Foundation
@testable import IhatecryptoCore
import Testing

/// Phrases a review found read wrong (C2–C13, M4, R1–R9), and the normal forms beside them that must keep reading the same.
private func d(_ s: String) -> Decimal { Decimal(string: s)! }
private let sol = SpotAsset.all[0]

@Test func thousandsAndLeadingDotsReadAsWritten() {   // C4
    #expect(PositionCommand.parse("move stop to 2,500") == .stopTo(2500))
    #expect(PositionCommand.parse("stop at 2500") == .stopTo(2500))
    #expect(PositionCommand.parse("take profit at 3,100.5") == .takeTo(d("3100.5")))
    #expect(PositionCommand.parse("закрой 33,333%") == .close(d("0.33333")))
    #expect(WalletCommand.parse("send 1,500 USDC to Mom") == .sendTo(name: "Mom", amount: 1500))
    #expect(WalletCommand.parse("move 1,234.56 USDC from Base to Solana") == .baseToSolana(d("1234.56")))
    #expect(WalletCommand.parse("deposit .5 USDC to kamino") == .kamino(deposit: true, symbol: "USDC", amount: d("0.5")))
    let plan = IntentParser.apply("long ETH 1,000 USDC limit 2,650", to: TradeIntent())
    #expect(plan?.amountUSDC == 1000 && plan?.entryPx == 2650)
    #expect(IntentParser.apply("long ETH risk $1,000", to: TradeIntent())?.riskUSD == 1000)
    // A decimal comma stays one.
    #expect(WalletCommand.parse("deposit 1,5 USDC to kamino") == .kamino(deposit: true, symbol: "USDC", amount: d("1.5")))
    #expect(WalletCommand.parse("положи 0,500 SOL в хранилище") == .lendDeposit("SOL", d("0.5")))
    #expect(WalletCommand.parse("buy SOL for 5 USDC") == .buy(sol, usdc: 5))
}
