import Foundation
import HyperliquidSigning
@testable import TradeExecution
import Testing

@Test func exchangeRepliesAreReadStrictly() {
    func reply(_ json: String) -> HLReply { HLReply.parse(Data(json.utf8)) }
    #expect(reply(#"{"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.012","avgPx":"2680.5","oid":1}}]}}}"#)
        == .filled(size: Decimal(string: "0.012")!, avgPx: Decimal(string: "2680.5")!))
    #expect(reply(#"{"status":"ok","response":{"type":"default"}}"#) == .ok)
    #expect(reply(#"{"status":"ok","response":{"type":"order","data":{"statuses":["waitingForTrigger",{"error":"Order has invalid price."}]}}}"#).isError)
    #expect(reply(#"{"status":"err","response":"User or API Wallet does not exist."}"#).isError)
    #expect(reply("not json").isError)
}

@Test func stopAndTakeFollowTheActualFill() throws {
    let long = Executor.protectionPrices(entry: 2000, stopPct: 3, takePct: 6, long: true, szDecimals: 4)
    #expect(long.stop == 1940 && long.take == 2120)
    let short = Executor.protectionPrices(entry: 2000, stopPct: 3, takePct: nil, long: false, szDecimals: 4)
    #expect(short.stop == 2060 && short.take == nil)

    // Market triggers close on the opposite side, reduce-only, and may fill up to 10% past the trigger.
    let action = try Executor.protectionAction(asset: 1, long: true, size: Decimal(string: "0.012")!, stop: 1940, take: 2120, szDecimals: 4)
    let json = action.json as! [String: Any]
    let orders = json["orders"] as! [[String: Any]]
    #expect(json["grouping"] as? String == "positionTpsl" && orders.count == 2)
    #expect(orders.allSatisfy { $0["b"] as? Bool == false && $0["r"] as? Bool == true })
    #expect(orders[0]["p"] as? String == "1746")
}

@Test func riskAtStopsUsesTheNearestStopAndFlagsAMissingOne() throws {
    let orders = try JSONDecoder().decode([HyperliquidAccount.Order].self, from: Data(#"""
    [{"coin":"ETH","oid":1,"isTrigger":true,"triggerPx":"1940","orderType":"Stop Market"},
     {"coin":"ETH","oid":2,"isTrigger":true,"triggerPx":"1960","orderType":"Stop Market"},
     {"coin":"ETH","oid":3,"isTrigger":true,"triggerPx":"2200","orderType":"Take Profit Market"}]
    """#.utf8))
    let long = HyperliquidAccount.Position(coin: "ETH", size: Decimal(string: "0.5")!, entry: 2000, unrealizedPnl: 0, liquidation: nil)
    #expect(HyperliquidAccount.riskAtStops(positions: [long], orders: orders) == 20)   // (2000 − 1960) × 0.5
    let naked = HyperliquidAccount.Position(coin: "BTC", size: -1, entry: 80000, unrealizedPnl: 0, liquidation: nil)
    #expect(HyperliquidAccount.riskAtStops(positions: [long, naked], orders: orders) == nil)
}

@Test func rentIsReadFromTheSimulationLines() {
    // The Kamino rule refuses a first deposit whose rent is over a tenth of the amount; it reads the SOL line.
    #expect(Executor.solSpent(["USDC: -1000000 (raw units)", "SOL: −0.029794 (fees and rent for new accounts)"]) == Decimal(string: "0.029794"))
    #expect(Executor.solSpent(["SOL: −1,250.5 (fees and rent for new accounts)"]) == Decimal(string: "1250.5"))
    #expect(Executor.solSpent(["SOL: 0.001479 (fees and rent for new accounts)"]) == 0)   // SOL came back, nothing spent
    #expect(Executor.solSpent([]) == 0)
}

@Test func aPickedSwapWayOnlyNarrowsTheQuotedOnes() {
    let relay = Executor.SwapWay(name: "relay", out: 100, worth: 1.90, line: "")
    let uniswap = Executor.SwapWay(name: "uniswap", out: 101, worth: 1.95, line: "")
    #expect(Executor.pick([relay, uniswap], prefer: nil)?.name == "uniswap")      // whichever leaves more
    #expect(Executor.pick([relay, uniswap], prefer: "relay")?.name == "relay")    // the one picked, even if it leaves less
    #expect(Executor.pick([uniswap], prefer: "relay") == nil)                     // picked but unquoted: nothing is signed
    #expect(Executor.pick([], prefer: nil) == nil)
}
