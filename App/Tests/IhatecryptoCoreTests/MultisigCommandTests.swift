import Foundation
@testable import IhatecryptoCore
import Testing

/// The multisig's forms parse as the chat writes them, round-trip through `summary`, and leave the Jupiter vault alone.
@Test func multisigFormsParse() {
    #expect(WalletCommand.parse("make a multisig") == .multisigCreate(threshold: nil, of: nil, keys: [], networks: []))
    #expect(WalletCommand.parse("make a multisig 2 of 3 with Phone on arbitrum, base")
            == .multisigCreate(threshold: 2, of: 3, keys: ["Phone"], networks: ["arbitrum", "base"]))
    #expect(WalletCommand.parse("create a multisig 3 of 4 with Phone, Mom and Office Mac on bnb and ethereum")
            == .multisigCreate(threshold: 3, of: 4, keys: ["Phone", "Mom", "Office Mac"], networks: ["bnb", "ethereum"]))
    #expect(WalletCommand.parse("make a multisig on hyperliquid") == nil)   // not an EVM network a multisig is made on
    #expect(WalletCommand.parse("send 200 USDC from the multisig to Alex on base") == .multisigSend(token: "USDC", amount: 200, to: "Alex", network: "base"))
    #expect(WalletCommand.parse("send all ETH from the multisig to Old wallet") == .multisigSend(token: "ETH", amount: nil, to: "Old wallet", network: nil))
    #expect(WalletCommand.parse("show the multisig") == .multisigShow)
    for c in ["make a multisig 2 of 3 with Phone on arbitrum, base", "send 0.5 ETH from the multisig to Alex on arbitrum", "show the multisig"] {
        #expect(ChatRouter.parses(c, markets: []), "\(c)")
        #expect(WalletCommand.parse(WalletCommand.parse(c)!.summary) == WalletCommand.parse(c), "\(c)")
    }
    #expect(ChatRouter.forms.contains("make a multisig [M of N]"))
    // «the vault» is still Jupiter Lend's.
    #expect(WalletCommand.parse("send 1 SOL to the vault") != .multisigShow)
    if case .multisigSend? = WalletCommand.parse("lend 5 USDC in the vault") { Issue.record("a Jupiter deposit read as a multisig move") }
}
