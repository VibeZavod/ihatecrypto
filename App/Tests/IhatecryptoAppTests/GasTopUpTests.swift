@testable import IhatecryptoApp
import Foundation
import IhatecryptoCore
import Testing

// «Top up gas» on the Schedule (Workspace.suggestGas): the amounts it works out, and the lines it types into the chat
// read back as the sends they say.

@Test func gasAmountsRoundUpToTwoDigits() {
    #expect(Workspace.gasRounded(Decimal(string: "0.0123")!) == Decimal(string: "0.013")!)
    #expect(Workspace.gasRounded(Decimal(string: "0.0000183")!) == Decimal(string: "0.000019")!)
    #expect(Workspace.gasRounded(Decimal(string: "0.005")!) == Decimal(string: "0.005")!)
    #expect(Workspace.gasRounded(Decimal(string: "0.0036001")!) == Decimal(string: "0.0037")!)
    #expect(Workspace.gasRounded(0) == 0)
}

@Test func gasIsAskedOnlyWhenItRunsLow() {
    func d(_ s: String) -> Decimal { Decimal(string: s)! }
    // Topped up to the target, then the fee rose a little: no dust asked for.
    #expect(Workspace.gasShort(held: d("0.000036"), target: d("0.000036044")) == 0)
    #expect(Workspace.gasShort(held: 0, target: d("0.000036")) == d("0.000036"))
    // Below half the target: back up to all of it.
    #expect(Workspace.gasShort(held: d("0.0055"), target: d("0.012"), floor: d("0.005")) == d("0.0065"))
    #expect(Workspace.gasShort(held: d("0.007"), target: d("0.012"), floor: d("0.005")) == 0)
    // Under SOL's floor its moves fail, however close to the target.
    #expect(Workspace.gasShort(held: d("0.0049"), target: d("0.006"), floor: d("0.005")) == d("0.0011"))
}

@Test func gasSendsParseAsTheyAreTyped() {
    let sol = Decimal(string: "0.013")!, eth = Decimal(string: "0.000019")!
    // As suggestGas writes them: «send <amount> <coin> on <network> to <wallet>».
    #expect(WalletCommand.parse("send \(Fmt.num(sol, maxFraction: 9)) SOL on solana to Automation") == .sendSol(name: "Automation", amount: sol))
    #expect(WalletCommand.parse("send \(Fmt.num(eth, maxFraction: 9)) ETH on base to Automation")
            == .sendToken(name: "Automation", token: "ETH", amount: eth, network: "base"))
    #expect(WalletCommand.parse("send \(Fmt.num(eth, maxFraction: 9)) POL on polygon to Automation")
            == .sendToken(name: "Automation", token: "POL", amount: eth, network: "polygon"))
}
