import Foundation
import Testing
@testable import TradeExecution
import WalletCore

@Test func agentReadsEncodeAndDecodeContractCalls() throws {
    let owner = "0x1111111111111111111111111111111111111111"
    #expect(try AgentReads.encode("balanceOf", ["address"], [owner]).hex == "70a08231" + String(repeating: "0", count: 24) + owner.dropFirst(2))
    #expect(try AgentReads.encode("convertToAssets", ["uint256"], ["1000000"]).suffix(3).hex == "0f4240")
    #expect(throws: (any Error).self) { try AgentReads.encode("f", ["string"], ["x"]) }

    let max = Data(repeating: 0xff, count: 32)
    let abc = Data(count: 31) + [0x20] + Data(count: 31) + [3] + Data("abc".utf8) + Data(count: 29)
    #expect(AgentReads.decode(["uint256", "int256"], max + max) == ["max (2^256−1, unlimited)", "-1"])
    #expect(AgentReads.decode(["string"], abc) == ["«abc»"])
    #expect(AgentReads.decode(["address", "bool"], Data(count: 12) + Data(hex: owner)! + Data(count: 31) + [1]) == [owner, "true"])
}

@Test func agentReadsKeepOnlyMatchingItemsAndHideTheUsersAddress() {
    let pools = #"{"status":"ok","data":[{"project":"fluid-lending","chain":"Arbitrum","symbol":"USDC"},{"project":"aave-v3","chain":"Base","symbol":"USDC"}]}"#
    let out = AgentReads.shaped(Data(pools.utf8), find: ["fluid", "arbitrum"])
    #expect(out.hasPrefix("1 of 2 items hold «fluid arbitrum»:"))
    #expect(out.contains("fluid-lending") && !out.contains("aave-v3"))
    #expect(AgentReads.split("https://x.io/a find Morpho base") == ("https://x.io/a", ["morpho", "base"]))
    let me = AgentReads.Me(evm: "0xAbCdEf0000000000000000000000000000000001", solana: nil)
    #expect(AgentReads.masked("from 0xabcdef0000000000000000000000000000000001 to 0x2", me) == "from me to 0x2")
}
