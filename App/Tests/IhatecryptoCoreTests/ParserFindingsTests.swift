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

@Test func aSaleInDollarsIsNeverSellAll() {   // C3
    let m: Set<String> = ["BTC", "ETH", "SOL"]
    for text in ["продай сол на 10 баксов", "sell SOL for 10 USDC", "sell BONK on solana for 10 USDC", "sell DEGEN on base for 10 USDC",
                 "sell TSLA stock for 10 USDC", "sell NEAR for 10 USDC", "sell 0x742d35Cc6634C0532925a3b844Bc454e4438f44e for $5"] {
        #expect(WalletCommand.parse(text) == nil, "\(text)")
    }
    // Unparsed all the way: the model is asked again, and no long of 10 USDC is drawn.
    #expect(IntentParser.apply("sell SOL for 10 USDC", to: TradeIntent(), markets: m) == nil)
    #expect(!ChatRouter.parses("sell SOL for 10 USDC", markets: m))
    #expect(WalletCommand.parse("sell 2 TSLA stock for 10 USDC") == .sellStock(symbol: "TSLA", amount: 2))
    #expect(WalletCommand.parse("sell TSLA stock") == .sellStock(symbol: "TSLA", amount: nil))
    #expect(WalletCommand.parse("sell SOL") == .sell(sol, amount: nil))
    #expect(WalletCommand.parse("sell 0.1 SOL") == .sell(sol, amount: d("0.1")))
    #expect(WalletCommand.parse("sell all DEGEN on base") == .sellOn("base", token: "DEGEN", amount: nil))
    #expect(WalletCommand.parse("sell 1000 BONK on solana") == .sell(.bySymbol("BONK"), amount: 1000))
    #expect(IntentParser.apply("short ETH risk $5", to: TradeIntent(), markets: m)?.side == .short)
}

@Test func aQuestionOrADontNeverClosesThePosition() {   // C5
    for text in ["не закрывай позицию", "don't close it", "should I close ETH?", "закрыть?", "what if I close half?", "do not move the stop to 2500"] {
        #expect(PositionCommand.parse(text) == nil, "\(text)")
    }
    #expect(PositionCommand.parse("закрой половину") == .close(d("0.5")))
    #expect(PositionCommand.parse("close ETH") == .close(1))
    #expect(PositionCommand.parse("стоп в безубыток") == .stopToBreakeven)
    #expect(PositionCommand.parse("отмени ордер") == .cancelOrders)
}

@Test func anAnswerInAnotherUnitDoesNotFillTheQuestion() {   // C8, R1, R2, R3
    #expect(WalletCommand.amountAnswer("$5", for: .stake(nil)) == nil)
    #expect(WalletCommand.amountAnswer("на 5 долларов", for: .stake(nil)) == nil)
    #expect(WalletCommand.amountAnswer("$0.05", for: .stake(nil)) == nil)
    #expect(WalletCommand.amountAnswer("5 usdc", for: .kamino(deposit: true, symbol: "SOL", amount: nil)) == nil)
    #expect(WalletCommand.amountAnswer("1 sol", for: .lendDeposit("USDC", nil)) == nil)
    #expect(WalletCommand.amountAnswer("$5 sol", for: .stake(nil)) == nil)
    #expect(WalletCommand.amountAnswer("0.0000001", for: .lendDeposit("USDC", nil)) == nil)
    #expect(WalletCommand.amountAnswer("0.0000000001", for: .stake(nil)) == nil)
    #expect(WalletCommand.amountAnswer("1,000", for: .lendDeposit("USDC", nil)) == 1000)
    #expect(WalletCommand.amountAnswer("5", for: .stake(nil)) == 5)
    #expect(WalletCommand.amountAnswer("0.5 SOL", for: .stake(nil)) == d("0.5"))
    #expect(WalletCommand.amountAnswer("0.000000001", for: .stake(nil)) == d("0.000000001"))
    #expect(WalletCommand.amountAnswer("0.5 сол", for: .lendDeposit("SOL", nil)) == d("0.5"))
    #expect(WalletCommand.amountAnswer("$5", for: .buy(sol, usdc: nil)) == 5)
    #expect(WalletCommand.amountAnswer("да, 2", for: .aave(deposit: true, amount: nil)) == 2)
    #expect(WalletCommand.amountAnswer("10 usdc", for: .solanaTo("base", nil)) == 10)
    #expect(WalletCommand.amountAnswer("5 баксов", for: .hlp(deposit: true, amount: nil)) == 5)
    // The old reader, which the app still calls, reads numbers the same way.
    #expect(WalletCommand.amountAnswer("1,5 USDC") == d("1.5"))
    #expect(WalletCommand.amountAnswer("1,000") == 1000)
    #expect(WalletCommand.amountAnswer(".5") == d("0.5"))
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

@Test func everyZeroDaysIsNoSchedule() {   // M4
    #expect(WalletCommand.parse("buy SOL for 5 USDC every 0 days") == nil)
    #expect(WalletCommand.parse("покупай SOL на 5 USDC каждые 0 дней") == nil)
    #expect(!ChatRouter.parses("buy SOL for 5 USDC every 0 days", markets: ["SOL"]))
    #expect(WalletCommand.parse("buy SOL for 5 USDC every 3 days") == .schedule(sol, usdc: 5, days: 3))
    // One stored before the parser refused it moves a day at a time instead of spinning forever.
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var s = Schedule(symbol: "SOL", usdc: 5, days: 0, next: start)
    s.advance(now: start)
    #expect(s.next == start.addingTimeInterval(86_400))
}
