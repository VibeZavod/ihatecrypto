import Foundation
@testable import LalaCore
import Testing

private func d(_ s: String) -> Decimal { Decimal(string: s)! }

/// Many ways people ask for the same thing, in Russian and English, with the typos they make.
/// Each must land on exactly one command — or on none, when it's a trade or a question.
@Test(arguments: [
    // Jupiter Lend deposits: the one that went wrong («jupyter vault», «задепозити», no amount).
    ("добавь в jupyter vault 1 USDC", WalletCommand.lendDeposit("USDC", 1)),
    ("задепозити в джупитер USDC", .lendDeposit("USDC", nil)),
    ("задепозить 1 usdc в джупитер", .lendDeposit("USDC", 1)),
    ("депозитни 2 usdc в jupiter", .lendDeposit("USDC", 2)),
    ("положи 1 usdc в хранилище", .lendDeposit("USDC", 1)),
    ("положи 1 в джупитер", .lendDeposit("USDC", 1)),
    ("закинь 1,5 юсдс в юпитер", .lendDeposit("USDC", d("1.5"))),
    ("1 USDC в джупитер", .lendDeposit("USDC", 1)),
    ("пополни хранилище на 1 usdc", .lendDeposit("USDC", 1)),
    ("положи USDC с соланы в джупитер", .lendDeposit("USDC", nil)),
    ("put 1 USDC into the Jupiter vault", .lendDeposit("USDC", 1)),
    ("deposit 1 USDC to Jupiter Lend", .lendDeposit("USDC", 1)),
    ("add 1 USDC to jupyter vault", .lendDeposit("USDC", 1)),
    ("lend 1 USDC", .lendDeposit("USDC", 1)),
    ("jupiter vault 1 USDC", .lendDeposit("USDC", 1)),
    ("idk just deposit to vault on jupyter", .lendDeposit("USDC", nil)),
    ("vault deposit", .lendDeposit("USDC", nil)),
    ("положи 0.01 SOL в джупитер", .lendDeposit("SOL", d("0.01"))),
    // Jupiter Lend withdrawals.
    ("выведи 1 usdc из джупитера", .lendWithdraw("USDC", 1)),
    ("withdraw USDC from the vault", .lendWithdraw("USDC", nil)),
    ("забери всё из хранилища", .lendWithdraw("USDC", nil)),
    ("сними 0,5 usdc с джупитера", .lendWithdraw("USDC", d("0.5"))),
    ("take 1 USDC out of jupiter", .lendWithdraw("USDC", 1)),
    ("переведи 1 usdc из джупитера в солану", .lendWithdraw("USDC", 1)),
    // Kamino, staking, buys.
    ("положи 1 usdc в камино", .kamino(deposit: true, symbol: "USDC", amount: 1)),
    ("выведи usdc из kamino", .kamino(deposit: false, symbol: "USDC", amount: nil)),
    ("move 1 USDC from kamino to solana", .kamino(deposit: false, symbol: "USDC", amount: 1)),
    ("застейкай 0.01 sol", .stake(d("0.01"))),
    ("купи сол", .buy(SpotAsset.all[0], usdc: nil)),
    ("buy SOL for 2 USDC", .buy(SpotAsset.all[0], usdc: 2)),
    ("купи биткоин на $5", .buy(SpotAsset.all[1], usdc: 5)),
    // Own places elsewhere.
    ("выведи 1 USDC в Solana", .withdrawToSolana(1)),
    ("withdraw 3 USDC to Solana", .withdrawToSolana(3)),
    ("lend 2 USDC on Aave", .aave(deposit: true, amount: 2)),
    ("move USDC from Base to Solana", .baseToSolana(nil)),
    ("send 5 USDC to Bybit", .sendTo(name: "Bybit", amount: 5)),
    ("move USDC from Arbitrum to Solana", .arbitrumToSolana(nil)),
    ("верни 2 usdc с арбитрума в солану", .arbitrumToSolana(2)),
    // Topping up from outside: the addresses, not a trade.
    ("задепозить", .receive),
    ("хочу задепозить", .receive),
    ("задепозить 5 usdc", .receive),
    ("пополнить", .receive),
    ("пополни кошелек", .receive),
    ("top up", .receive),
    ("I want to deposit", .receive),
    ("где наши адреса?", .receive),
    ("мой адрес", .receive),
    ("what is my Solana address", .receive),
    ("куда отправить деньги?", .receive),
    ("how do I top up?", .receive),
    ("как пополнить баланс", .receive),
] as [(String, WalletCommand)])
func walletPhrases(_ phrase: String, _ expected: WalletCommand) {
    #expect(WalletCommand.parse(phrase) == expected, "«\(phrase)»")
}

@Test(arguments: [
    "лонг ETH риск $5 стоп 2%", "short oil by the book", "long ETH 5 USDC risk $1", "шорт нефть как учат",
    "what do I have on Aave?", "а где наш шорт по нефти?", "сколько сейчас стоит нефть", "move stop to breakeven",
    "что за параметр?", "1 USDC", "1",
])
func notWalletCommands(_ phrase: String) {
    #expect(WalletCommand.parse(phrase) == nil, "«\(phrase)»")
}

@Test func amountReplies() {
    #expect(WalletCommand.amountAnswer("1") == 1)
    #expect(WalletCommand.amountAnswer("1 USDC") == 1)
    #expect(WalletCommand.amountAnswer("да, 2") == 2)
    #expect(WalletCommand.amountAnswer("$1.5") == d("1.5"))
    #expect(WalletCommand.amountAnswer("на 3 доллара") == 3)
    #expect(WalletCommand.amountAnswer("0,5") == d("0.5"))
    #expect(WalletCommand.amountAnswer("long ETH") == nil)
    #expect(WalletCommand.amountAnswer("1 USDC в джупитер") == nil)
    #expect(WalletCommand.lendDeposit("USDC", nil).amountQuestion != nil)
    #expect(WalletCommand.lendDeposit("USDC", nil).with(amount: 1) == .lendDeposit("USDC", 1))
    #expect(WalletCommand.lendDeposit("USDC", 1).summary == "deposit 1 USDC into Jupiter Lend")
}

@Test func bareAmountsDontStartPlans() {
    #expect(!IntentParser.startsPlan("1 USDC"))
    #expect(!IntentParser.startsPlan("vault deposit"))
    #expect(!IntentParser.startsPlan("yes"))
    #expect(IntentParser.startsPlan("лонг"))
    #expect(IntentParser.startsPlan("ETH risk $5"))
    #expect(IntentParser.startsPlan("short oil", markets: ["xyz:CL"]))
}
