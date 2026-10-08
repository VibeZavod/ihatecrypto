import Foundation
@testable import IhatecryptoCore
import Testing

/// The big five stablecoins (USDT, USDC, USDS, USDe, DAI) on every network they're on: the ticker finds the coin, and a
/// swap of one for another reads as a swap there, in English and in Russian.
@Test func stablecoinsAreFoundByTicker() {
    #expect(Stablecoins.find("usdt", on: "arbitrum")?.address == "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9")
    #expect(Stablecoins.find("USD₮0", on: "arbitrum")?.symbol == "USDT")
    #expect(Stablecoins.find("USDT", on: "hyperliquid")?.symbol == "USDT0")
    #expect(Stablecoins.find("USDe", on: "hyperliquid")?.symbol == "USDE")
    #expect(Stablecoins.find("$USDS", on: "solana")?.address == "USDSwr9ApdHk5bvJKMjzff41FfuX8bSxdKcR81vTwcA")
    #expect(Stablecoins.find("USDT0", on: "optimism")?.address != Stablecoins.find("USDT", on: "optimism")?.address)
    #expect(Stablecoins.find("DAI", on: "solana") == nil && Stablecoins.find("USDS", on: "polygon") == nil)
    // Every network has USDC, and every coin is one of the five or USDT0, on a network ihatecrypto has.
    for (network, coins) in Stablecoins.byNetwork {
        #expect(coins.contains { $0.symbol == "USDC" }, "\(network)")
        #expect(coins.allSatisfy { ["USDT", "USDT0", "USDC", "USDS", "USDE", "DAI"].contains($0.symbol.uppercased()) }, "\(network)")
    }
    #expect(["USDS", "USDE", "DAI", "USDT0", "USD₮0", "USDG"].allSatisfy(Stablecoins.isDollar) && !Stablecoins.isDollar("ETH"))
}

@Test func stablecoinSwapsParse() {
    // A stablecoin for USDC on an EVM network is a sale kept there; USDC for one, a buy with the USDC already there.
    #expect(WalletCommand.parse("swap 5 USDT for USDC on arbitrum") == .sellOn("arbitrum", token: "USDT", amount: 5, keep: true))
    #expect(WalletCommand.parse("swap 2 USDC for USDe on base") == .buyOn("base", token: "USDe", usdc: 2, from: "base"))
    #expect(WalletCommand.parse("swap all DAI for USDC on polygon") == .sellOn("polygon", token: "DAI", amount: nil, keep: true))
    #expect(WalletCommand.parse("swap 4 USDC for DAI on bnb") == .buyOn("bnb", token: "DAI", usdc: 4, from: "bnb"))
    #expect(WalletCommand.parse("swap 2 USDT for DAI on ethereum") == .swapOn("ethereum", from: "USDT", to: "DAI", amount: 2))
    #expect(WalletCommand.parse("swap 2 USDC for USDT0 on tempo") == .swapOn("tempo", from: "USDC", to: "USDT0", amount: 2))
    #expect(WalletCommand.parse("swap 11 USDC for USDT on hyperliquid") == .hlSpotBuy(symbol: "USDT", usdc: 11))
    // The brief's own examples.
    #expect(WalletCommand.parse("buy USDe on base for 5 USDC from base") == .buyOn("base", token: "USDe", usdc: 5, from: "base"))
    #expect(WalletCommand.parse("sell all DAI on polygon and keep the USDC there") == .sellOn("polygon", token: "DAI", amount: nil, keep: true))
    #expect(WalletCommand.parse("buy USDT0 on hyperliquid spot for 11 USDC") == .hlSpotBuy(symbol: "USDT0", usdc: 11))
    #expect(ChatRouter.forms.contains("Arbitrum: USDC, USDT, USDS, USDe, DAI"))
    if case .buy(let asset, 3) = WalletCommand.parse("buy USDT on solana for 3 USDC") { #expect(asset.symbol == "USDT") } else { Issue.record("buy USDT on solana") }
    #expect(WalletCommand.parse("swap 2 USDC for USDT on near") == .swapOn("near", from: "USDC", to: "USDT", amount: 2))
    if case .buy(let asset, let usdc) = WalletCommand.parse("swap 3 USDC for USDT on solana") { #expect(asset.symbol == "USDT" && usdc == 3) } else { Issue.record("USDT on Solana") }
}

@Test func stablecoinSendsAndMovesParse() {
    #expect(WalletCommand.parse("send 5 USDT on arbitrum to Mom") == .sendToken(name: "Mom", token: "USDT", amount: 5, network: "arbitrum"))
    #expect(WalletCommand.parse("send 3 DAI on polygon to Mom") == .sendToken(name: "Mom", token: "DAI", amount: 3, network: "polygon"))
    #expect(WalletCommand.parse("swap 5 USDT on arbitrum for USDC on solana") == .crossSwap(from: "USDT", on: "arbitrum", to: "USDC", at: "solana", amount: 5))
    #expect(WalletCommand.parse("swap 2 USDe on base for USDe on solana") == .crossSwap(from: "USDe", on: "base", to: "USDe", at: "solana", amount: 2))
    #expect(Stablecoins.isGenuine("0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9", on: "arbitrum") && !Stablecoins.isGenuine("0xdead", on: "arbitrum"))
}
