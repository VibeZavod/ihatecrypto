import Foundation
@testable import IhatecryptoCore
import Testing

/// HyperEVM (Hyperliquid's EVM, chain 999) as a network: its money in and out, its gas, sends there — never mistaken for
/// the Hyperliquid trading account, in English and in Russian.
@Test func hyperEVMIsAPlaceOfItsOwn() {
    #expect(WalletCommand.parse("move 2 USDC from Solana to HyperEVM") == .solanaTo("hyperevm", 2))
    #expect(WalletCommand.parse("переведи 2 USDC из соланы на хайперевм") == .solanaTo("hyperevm", 2))
    #expect(WalletCommand.parse("move all USDC from HyperEVM to Solana") == .evmToSolana("hyperevm", nil))
    #expect(WalletCommand.parse("move 3 USDC from base to hyperevm") == .bridge(from: "base", to: "hyperevm", 3))
    #expect(WalletCommand.parse("move 3 USDC from hyperevm to hyperliquid") == .bridge(from: "hyperevm", to: "hyperliquid", 3))
    #expect(WalletCommand.parse("add gas on hyperevm") == .gas("hyperevm", usd: nil))
    #expect(WalletCommand.parse("send 5 USDC to Mom on hyperevm") == .sendTo(name: "Mom", amount: 5, network: "hyperevm"))
    #expect(WalletCommand.parse("move 2 USDC from Solana to Hyperliquid") != .solanaTo("hyperevm", 2))
    #expect(ModuleNetwork(place: "hyperevm") == .hyperevm && ModuleNetwork(place: "hyperliquid") == .hyperliquid)
    #expect(AddressBookCommand.parse("save 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC as Shop on HyperEVM")
            == .save(address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC", name: "Shop", network: "hyperevm"))
    for c in [WalletCommand.solanaTo("hyperevm", 2), .evmToSolana("hyperevm", 1), .bridge(from: "arbitrum", to: "hyperevm", 4), .gas("hyperevm", usd: 1)] {
        #expect(WalletCommand.parse(c.summary) == c, "\(c.summary)")
    }
}
