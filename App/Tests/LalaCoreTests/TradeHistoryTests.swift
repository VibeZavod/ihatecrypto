import Foundation
@testable import LalaCore
import Testing

private func fill(_ coin: String, _ px: String, _ sz: String, _ side: String, _ t: Double, start: String, _ dir: String,
                  pnl: String = "0", fee: String = "0.003") -> TradeHistory.Fill {
    TradeHistory.Fill(coin: coin, px: Decimal(string: px)!, sz: Decimal(string: sz)!, side: side, time: Date(timeIntervalSince1970: t),
                      startPosition: Decimal(string: start)!, dir: dir, closedPnl: Decimal(string: pnl)!, fee: Decimal(string: fee)!)
}

@Test func fillsBecomePositionStories() {
    // The real oil short of 2026-09-25 and the ETH test trade that overlapped nothing.
    let fills = [
        fill("xyz:CL", "93.417", "0.369", "A", 100, start: "0", "Open Short", fee: "0.003102"),
        fill("xyz:CL", "92.214", "0.369", "B", 200, start: "-0.369", "Close Short", pnl: "0.443907", fee: "0.003062"),
        fill("ETH", "2694.4", "0.0058", "B", 300, start: "0", "Open Long", fee: "0.007032"),
        fill("ETH", "2694.2", "0.0058", "A", 400, start: "0.0058", "Close Long", pnl: "-0.00116", fee: "0.007031"),
        // Still open: half taken, half running.
        fill("BTC", "60000", "0.0002", "B", 500, start: "0", "Open Long"),
        fill("BTC", "61000", "0.0001", "A", 600, start: "0.0002", "Close Long", pnl: "0.1"),
    ]
    let stories = TradeHistory.stories(fills.shuffled())
    #expect(stories.map(\.coin) == ["BTC", "ETH", "xyz:CL"])
    let oil = stories[2]
    #expect(!oil.long && !oil.isOpen && oil.fills.count == 2)
    #expect(oil.realized == Decimal(string: "0.443907")! - Decimal(string: "0.006164")!)
    #expect(stories[0].isOpen && stories[0].long && stories[0].closed == nil && stories[0].peakSize == Decimal(string: "0.0002")!)
}

@Test func ledgerInWords() {
    let me = "0x1523aaaa"
    let json = """
    [{"time": 1000, "delta": {"type": "send", "user": "0xrelay", "destination": "0x1523AAAA", "sourceDex": "spot", "destinationDex": "", "token": "USDC", "amount": "2.98", "usdcValue": "2.98", "fee": "0.0"}},
     {"time": 2000, "delta": {"type": "send", "user": "0x1523aaaa", "destination": "0x1523aaaa", "sourceDex": "", "destinationDex": "xyz", "token": "USDC", "amount": "1.2", "usdcValue": "1.2", "fee": "0.0"}},
     {"time": 3000, "delta": {"type": "send", "user": "0x1523aaaa", "destination": "0xrelaydepository", "sourceDex": "", "destinationDex": "spot", "token": "USDC", "amount": "1.0", "usdcValue": "1.0", "fee": "0.0"}}]
    """
    let items = TradeHistory.transfers(Data(json.utf8), user: me)
    #expect(items.map(\.amount) == [-1, 0, Decimal(string: "2.98")!])
    #expect(items[1].text == "Moved $1.20 to the xyz exchange")
    #expect(items[2].text == "Received $2.98 (bridge in)")
}
