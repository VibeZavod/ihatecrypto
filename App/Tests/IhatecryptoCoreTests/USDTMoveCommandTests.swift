import Foundation
import Testing
@testable import IhatecryptoCore

/// USDT between USDT0's networks: Relay's swap unless LayerZero is named; each form reads back from its own summary.
@Test func usdtMoveFormsParse() {
    #expect(WalletCommand.parse("move 50 USDT from arbitrum to optimism") == .usdt(from: "arbitrum", to: "optimism", 50, layerZero: false))
    #expect(WalletCommand.parse("move 50 USDT from Arbitrum to Optimism via LayerZero") == .usdt(from: "arbitrum", to: "optimism", 50, layerZero: true))
    #expect(WalletCommand.parse("move all USDT from polygon to ethereum via LayerZero") == .usdt(from: "polygon", to: "ethereum", nil, layerZero: true))
    #expect(WalletCommand.parse("move 2.5 USDT from hyperevm to arbitrum via USDT0") == .usdt(from: "hyperevm", to: "arbitrum", Decimal(string: "2.5"), layerZero: true))
    for c in [WalletCommand.usdt(from: "ethereum", to: "polygon", 7, layerZero: true), .usdt(from: "polygon", to: "hyperevm", nil, layerZero: false)] {
        #expect(WalletCommand.parse(c.summary) == c)
    }
    // Optimism's own «USDT» is the old bridged token: a plain move from there is Relay's swap of that one.
    #expect(WalletCommand.parse("move 5 USDT from optimism to arbitrum") == .crossSwap(from: "USDT", on: "optimism", to: "USDT", at: "arbitrum", amount: 5))
    #expect(WalletCommand.parse("move 5 USDT from optimism to arbitrum via LayerZero") == .usdt(from: "optimism", to: "arbitrum", 5, layerZero: true))
    // Off USDT0's networks it's Relay's swap of USDT; named there all the same, the bridge says where it runs.
    #expect(WalletCommand.parse("move 5 USDT from base to arbitrum") == .crossSwap(from: "USDT", on: "base", to: "USDT", at: "arbitrum", amount: 5))
    let off = WalletCommand.usdt(from: "base", to: "arbitrum", 5, layerZero: true)
    #expect(WalletCommand.parse("move 5 USDT from base to arbitrum via LayerZero") == off)
    #expect(Modules().refusal(off)?.contains("Ethereum, Arbitrum, Optimism, Polygon and HyperEVM") == true)
    #expect(Modules().refusal(.usdt(from: "arbitrum", to: "optimism", 5, layerZero: true)) == nil)
    // USDC keeps its own forms.
    #expect(WalletCommand.parse("move 5 USDC from base to arbitrum") == .bridge(from: "base", to: "arbitrum", 5))
    #expect(WalletCommand.parse("move 5 USDC from base to arbitrum via CCTP") == .cctp(from: "base", to: "arbitrum", 5))
}
