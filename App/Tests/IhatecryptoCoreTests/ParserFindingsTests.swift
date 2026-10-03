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

@Test func solOnSolanaToANameIsASendNotAWithdrawal() {   // C2
    #expect(WalletCommand.parse("send 0.5 SOL on solana to New wallet") == .sendSol(name: "New wallet", amount: d("0.5")))
    #expect(WalletCommand.parse("send 0.5 SOL on solana to Bybit") == .sendSol(name: "Bybit", amount: d("0.5")))
    #expect(WalletCommand.parse("отправь 0.5 SOL в солане на Bybit") == .sendSol(name: "Bybit", amount: d("0.5")))
    #expect(WalletCommand.parse("send 0.01 SOL to Bybit") == .sendSol(name: "Bybit", amount: d("0.01")))
    // The catch-all wants a word for taking money out, or Solana as where it goes.
    #expect(WalletCommand.parse("send SOL on solana to New wallet") == nil)
    #expect(WalletCommand.parse("send 3 USDC to Solana") == .withdrawToSolana(3))
    #expect(WalletCommand.parse("withdraw 3 USDC to Solana") == .withdrawToSolana(3))
    #expect(WalletCommand.parse("верни всё в солану") == .withdrawToSolana(nil))
    #expect(WalletCommand.parse("move 2 USDC from Hyperliquid to Solana") == .withdrawToSolana(2))
}

@Test func theNetworkAfterFromIsWhereMoneyLeaves() {   // C13
    #expect(WalletCommand.parse("переведи 5 USDC с базы на солану") == .baseToSolana(5))
    #expect(WalletCommand.parse("переведи 5 USDC с бейза на солану") == .baseToSolana(5))
    #expect(WalletCommand.parse("move 5 USDC to Base from Solana") == nil)
    #expect(WalletCommand.parse("move 5 USDC to Robinhood from Solana") == nil)
    #expect(WalletCommand.parse("move 5 USDC to Arbitrum from Solana") == nil)
    #expect(WalletCommand.parse("move 5 USDC from Base to Solana") == .baseToSolana(5))
    #expect(WalletCommand.parse("move 5 USDC to Solana from Base") == .baseToSolana(5))
    #expect(WalletCommand.parse("move 5 USDC from Solana to Base") == .solanaTo("base", 5))
    #expect(WalletCommand.parse("верни USDG с робингуда на солану") == .robinhoodToSolana(nil))
}
