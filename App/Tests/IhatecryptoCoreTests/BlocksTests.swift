@testable import IhatecryptoCore
import Testing

// «Add block» puts a block's example into the chat: each must be a command the agent's forms parse.
@Test func everyBlockExampleParses() {
    let markets: Set<String> = ["SOL", "ETH", "BTC", "xyz:TSLA"]
    for block in BlockCatalog.all where !block.automatic {
        #expect(ChatRouter.parses(block.example, markets: markets), "\(block.label): «\(block.example)»")
    }
    #expect(Set(BlockCatalog.all.map(\.group)) == Set(BlockCatalog.groups))
    #expect(Set(BlockCatalog.all.map(\.id)).count == BlockCatalog.all.count)
}
