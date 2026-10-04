import Foundation
import Testing
@testable import IhatecryptoCore

private func d(_ s: String) -> Decimal { Decimal(string: s)! }
private let base = FundingPlan.Place(key: "base", name: "Base", usdc: 100)

@Test func fundingTakesSolanaThenEVMThenHyperliquidThroughSolana() throws {
    let legs = try #require(FundingPlan.legs(short: 300, target: "robinhood", targetName: "Robinhood", solana: 9, evm: [base], hyperliquid: 250, near: 0, nearPrice: nil))
    #expect(legs == ["move 100 USDC from Base to Robinhood", "withdraw 194 USDC to Solana", "move 202 USDC from Solana to Robinhood"])
    // Each leg is a command the chat reads back as the right move.
    #expect(WalletCommand.parse(legs[0]) == .bridge(from: "base", to: "robinhood", 100))
    #expect(WalletCommand.parse(legs[1]) == .withdrawToSolana(194))
    #expect(WalletCommand.parse(legs[2]) == .solanaTo("robinhood", 202))
}

@Test func fundingForSolanaLandsEachSourceThereAndSellsNEARLast() throws {
    let legs = try #require(FundingPlan.legs(short: 50, target: "solana", targetName: "Solana", solana: 0,
                                             evm: [FundingPlan.Place(key: "base", name: "Base", usdc: 20)], hyperliquid: 40, near: 0, nearPrice: nil))
    #expect(legs == ["move 20 USDC from Base to Solana", "withdraw 32 USDC to Solana"])
    let near = try #require(FundingPlan.legs(short: 10, target: "solana", targetName: "Solana", solana: 0, evm: [], hyperliquid: 0, near: 5, nearPrice: 3))
    #expect(near == ["sell 3.74 NEAR"] && WalletCommand.parse(near[0]) == .sellNear(amount: d("3.74")))
    // Not enough anywhere: no plan, the move's own check says so; under $2 a place isn't worth a leg.
    #expect(FundingPlan.legs(short: 500, target: "solana", targetName: "Solana", solana: 0, evm: [base], hyperliquid: 40, near: 0, nearPrice: nil) == nil)
    #expect(FundingPlan.legs(short: 1, target: "solana", targetName: "Solana", solana: 0, evm: [FundingPlan.Place(key: "base", name: "Base", usdc: d("1.5"))],
                             hyperliquid: 0, near: 0, nearPrice: nil) == nil)
}

/// A buy run again as a chain's last step reads back from its own words, thousands and a contract included.
@Test func aBuyByContractReadsBackFromItsSummary() {
    let c = WalletCommand.buyStock(symbol: "0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18", usdc: 1722)
    #expect(WalletCommand.parse(c.summary) == c, "\(c.summary) → \(String(describing: WalletCommand.parse(c.summary)))")
}

/// Cents count: a leg rounded down left this plan a cent short (1721.109778 USDC more on Robinhood).
@Test func fundingCoversTheLastCent() throws {
    let legs = try #require(FundingPlan.legs(short: Decimal(string: "1721.109778")!, target: "robinhood", targetName: "Robinhood",
                                             solana: Decimal(string: "9.008635")!, evm: [FundingPlan.Place(key: "base", name: "Base", usdc: Decimal(string: "1712.67116")!)],
                                             hyperliquid: Decimal(string: "4.007817")!, near: 0, nearPrice: nil))
    #expect(legs == ["move 1712.67 USDC from Base to Robinhood", "withdraw 2.44 USDC to Solana", "move 10.44 USDC from Solana to Robinhood"])
}
