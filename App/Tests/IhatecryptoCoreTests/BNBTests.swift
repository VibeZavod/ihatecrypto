import Foundation
@testable import IhatecryptoCore
import Testing

/// BNB Chain (BSC, chain 56) as a network (2026-10-08): its money in and out, its gas, sends and swaps there, in English
/// and in Russian — «bnb», «bsc», «бнб» — and never taken for Base, which starts with a «b» too.
@Test func bnbChainIsAPlaceOfItsOwn() {
    #expect(WalletCommand.parse("move 5 USDC from Solana to BNB") == .solanaTo("bnb", 5))
    #expect(WalletCommand.parse("переведи 10 USDC из соланы на бнб") == .solanaTo("bnb", 10))
    #expect(WalletCommand.parse("move 2 USDC from Solana to BNB Chain") == .solanaTo("bnb", 2))
    #expect(WalletCommand.parse("move all USDC from BNB to Solana") == .evmToSolana("bnb", nil))
    #expect(WalletCommand.parse("верни всё с бнб на солану") == .evmToSolana("bnb", nil))
    #expect(WalletCommand.parse("move 3 USDC from base to bsc") == .bridge(from: "base", to: "bnb", 3))
    #expect(WalletCommand.parse("add gas on bnb") == .gas("bnb", usd: nil))
    #expect(WalletCommand.parse("send 5 USDC to Mom on bnb") == .sendTo(name: "Mom", amount: 5, network: "bnb"))
    #expect(WalletCommand.parse("move 2 USDC from Solana to Base") == .solanaTo("base", 2))
    #expect(ModuleNetwork(place: "bnb") == .bnb && ModuleNetwork(place: "base") == .base)
    #expect(AddressBookCommand.parse("save 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC as Shop on BNB")
            == .save(address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC", name: "Shop", network: "bnb"))
    for c in [WalletCommand.solanaTo("bnb", 2), .evmToSolana("bnb", 1), .bridge(from: "arbitrum", to: "bnb", 4), .gas("bnb", usd: 1)] {
        #expect(WalletCommand.parse(c.summary) == c, "\(c.summary)")
    }
}

/// Buys, sales and swaps on BNB Chain: a token for USDC, for another, BNB as the network's own coin; «BNB» as a token
/// on another network stays a token there.
@Test func swapsOnBNBChain() {
    #expect(WalletCommand.parse("buy CAKE on bnb for 5 USDC") == .buyOn("bnb", token: "CAKE", usdc: 5))
    #expect(WalletCommand.parse("купи CAKE на бнб на 5 USDC") == .buyOn("bnb", token: "CAKE", usdc: 5))
    #expect(WalletCommand.parse("sell all CAKE on bsc") == .sellOn("bnb", token: "CAKE", amount: nil))
    #expect(WalletCommand.parse("swap 0.01 BNB for CAKE on bnb") == .swapOn("bnb", from: "BNB", to: "CAKE", amount: Decimal(string: "0.01")!))
    // BNB is the network's coin: for USDC or back it stays a swap, not a buy that looks BNB up as a token.
    #expect(WalletCommand.parse("swap 5 USDC for BNB on bnb") == .swapOn("bnb", from: "USDC", to: "BNB", amount: 5))
    #expect(WalletCommand.parse("swap 5 USDC for CAKE on bnb") == .buyOn("bnb", token: "CAKE", usdc: 5, from: "bnb"))
    for c in [WalletCommand.buyOn("bnb", token: "CAKE", usdc: 5), .swapOn("bnb", from: "BNB", to: "CAKE", amount: 1)] {
        #expect(WalletCommand.parse(c.summary) == c, "\(c.summary)")
    }
}

/// Fees past a tenth of a small swap are said on its card (2026-10-08: $0.18 of a $1 UBTC buy); a fair swap says nothing.
@Test func feesEatingASwapAreSaid() {
    #expect(Fmt.feeWarning(paid: 1, worth: Decimal(string: "0.82")!) == "⚠️ fees take ≈ $0.18 (18%): a bigger amount loses less")
    #expect(Fmt.feeWarning(paid: 100, worth: Decimal(string: "99.5")!) == nil)
    #expect(Fmt.feeWarning(paid: 1, worth: 0) == nil)
}

/// A module a later version brings starts switched off until the user answers; what this Mac already knew stays as it was.
@Test func aNewModuleWaitsForTheUser() {
    let known = Set(Modules.allIDs).subtracting(["network.bnb", "protocol.oneClick"])
    var m = Modules(stored: "", known: known)
    #expect(!m.isOn(ModuleNetwork.bnb) && m.isOn(ModuleNetwork.base) && !m.isOn(ModuleProtocol.oneClick) && m.isOn(ModuleProtocol.relay))
    #expect(m.newIDs == ["network.bnb", "protocol.oneClick"])
    m.choices["network.bnb"] = true
    #expect(m.isOn(ModuleNetwork.bnb) && m.newIDs == ["protocol.oneClick"])
    // Nothing recorded yet: every module as before.
    #expect(Modules(stored: "", known: nil).isOn(ModuleNetwork.bnb) && Modules(stored: "", known: nil).newIDs.isEmpty)
    #expect(Modules.name("network.bnb") == "BNB Chain")
}
