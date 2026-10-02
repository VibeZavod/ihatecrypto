import Foundation
@testable import IhatecryptoCore
import Testing

@Test func anyTokenTransferParses() {
    #expect(WalletCommand.parse("send all RAY on solana to Bybit") == .sendToken(name: "Bybit", token: "RAY", amount: nil, network: "solana"))
    #expect(WalletCommand.parse("send 1973.719299 AI on robinhood to New wallet")
            == .sendToken(name: "New wallet", token: "AI", amount: Decimal(string: "1973.719299")!, network: "robinhood"))
    #expect(WalletCommand.parse("send all jlUSDC to New wallet") == .sendToken(name: "New wallet", token: "jlUSDC", amount: nil, network: nil))
    #expect(WalletCommand.parse("send 0.001 ETH on base to Mom") == .sendToken(name: "Mom", token: "ETH", amount: Decimal(string: "0.001")!, network: "base"))
    #expect(WalletCommand.parse("send all USDC on base to New wallet") == .sendToken(name: "New wallet", token: "USDC", amount: nil, network: "base"))
    #expect(WalletCommand.parse("send all 6GmAFSYs4gk3FDao5FzzySQpPZaWsa4rUJHacpMpUNgx to Bybit")
            == .sendToken(name: "Bybit", token: "6GmAFSYs4gk3FDao5FzzySQpPZaWsa4rUJHacpMpUNgx", amount: nil, network: nil))
    #expect(WalletCommand.parse("отправь все RAY на солане на New wallet") == .sendToken(name: "New wallet", token: "RAY", amount: nil, network: "solana"))
    #expect(WalletCommand.parse("переведи 0,5 TSLA в робинхуде на Маму") == .sendToken(name: "Маму", token: "TSLA", amount: Decimal(string: "0.5")!, network: "robinhood"))
}

@Test func anyTokenTransferLeavesTheOtherFormsAlone() {
    // USDC with a number and a network is the USDC transfer; without a network it's parsed as before.
    #expect(WalletCommand.parse("send 5 USDC on base to Mom") == .sendTo(name: "Mom", amount: 5, network: "base"))
    #expect(WalletCommand.parse("send 5 USDC to Mom") == .sendTo(name: "Mom", amount: 5))
    #expect(WalletCommand.parse("send 0.01 SOL to Bybit") == .sendSol(name: "Bybit", amount: Decimal(string: "0.01")!))
    #expect(WalletCommand.parse("send all NEAR to Bybit") == .sendNear(name: "Bybit", amount: nil))
    // A pasted address is never a recipient; «all the money» names no token; our own places aren't names.
    if case .sendToken? = WalletCommand.parse("send all RAY to 0x1234567890abcdef1234567890abcdef12345678") { Issue.record("pasted address") }
    if case .sendToken? = WalletCommand.parse("send all the money to Bybit") { Issue.record("no token") }
    if case .sendToken? = WalletCommand.parse("send all RAY to the vault") { Issue.record("a place") }
}

@Test func anyTokenTransferReadsBackFromItsSummary() {
    for command: WalletCommand in [
        .sendToken(name: "New wallet", token: "AI", amount: Decimal(string: "1973.719299")!, network: "robinhood"),
        .sendToken(name: "Bybit", token: "RAY", amount: nil, network: "solana"),
        .sendToken(name: "New wallet", token: "gtUSDCp", amount: Decimal(string: "133.242014")!, network: "base"),
    ] {
        #expect(WalletCommand.parse(command.summary) == command, "\(command.summary)")
    }
}

@Test func aTransferPicksTheTokenItNames() {
    let real = Holding(chain: "base", contract: "0xaaaa000000000000000000000000000000000001", amount: 3, symbol: "AERO", verified: true)
    let fake = Holding(chain: "base", contract: "0xbbbb000000000000000000000000000000000002", amount: 9, symbol: "AERO")
    let eth = Holding(chain: "base", contract: "native", amount: 1, symbol: "ETH", verified: true, native: true)
    let fakeETH = Holding(chain: "base", contract: "0xcccc000000000000000000000000000000000003", amount: 5, symbol: "ETH")
    let other = Holding(chain: "base", contract: "0xdddd000000000000000000000000000000000004", amount: 4, symbol: "AERO")
    #expect(Holdings.pick("0xAAAA000000000000000000000000000000000001", in: [real, fake]) == .one(real))
    #expect(Holdings.pick("aero", in: [real, fake]) == .one(real))          // the one that looks real
    #expect(Holdings.pick("ETH", in: [fakeETH, eth]) == .one(eth))         // the network's own coin
    #expect(Holdings.pick("AERO", in: [fake, other]) == .several([fake, other]))
    #expect(Holdings.pick("DEGEN", in: [real, eth]) == .none)
}
