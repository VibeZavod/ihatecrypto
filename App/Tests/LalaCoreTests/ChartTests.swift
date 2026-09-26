import Foundation
@testable import LalaCore
import Testing

@Test(arguments: [
    ("chart ETH", ChartCommand.chart(coin: "ETH", range: .day)),
    ("график нефти за неделю", .chart(coin: "xyz:CL", range: .week)),
    ("покажи эфир", .chart(coin: "ETH", range: .day)),
    ("show me BTC for a month", .chart(coin: "BTC", range: .month)),
    ("how's SOL doing?", .chart(coin: "SOL", range: .day)),
    ("свечи золота", .chart(coin: "xyz:GOLD", range: .day)),
    ("what's moving?", .movers),
    ("что растёт сегодня", .movers),
    ("top gainers", .movers),
] as [(String, ChartCommand)])
func chartPhrases(_ phrase: String, _ expected: ChartCommand) {
    #expect(ChartCommand.parse(phrase, markets: ["ETH", "BTC", "SOL", "xyz:CL", "xyz:GOLD"]) == expected, "«\(phrase)»")
}

@Test(arguments: ["long ETH risk $5", "сколько стоит нефть", "show my addresses", "покажи адреса", "задепозить"])
func notCharts(_ phrase: String) {
    #expect(ChartCommand.parse(phrase, markets: ["ETH", "xyz:CL"]) == nil, "«\(phrase)»")
}

@Test func candlesFromHyperliquidJSON() throws {
    let json = #"[{"t":1790000000000,"T":1790000899999,"s":"ETH","i":"15m","o":"2690.1","c":"2688.0","h":"2695.5","l":"2680.2","v":"12.3","n":40},{"t":1789999100000,"T":1789999999999,"s":"ETH","i":"15m","o":"2685.0","c":"2690.1","h":"2692.0","l":"2684.0","v":"8.1","n":22}]"#
    let candles = try Hyperliquid.parseCandles(Data(json.utf8))
    #expect(candles.count == 2)
    #expect(candles[0].close == Decimal(string: "2690.1")!)   // sorted oldest first
    #expect(candles[1].high == Decimal(string: "2695.5")!)
    #expect(ChartCommand.Range.week.interval == "1h" && ChartCommand.Range.week.span / 3_600_000 == 168)
}

@Test func allocationShares() {
    let s = PortfolioSplit.slices([("Solana", 2), ("Hyperliquid", 10), ("Jupiter", 3), ("Aave", 0), ("Base", -1)])
    #expect(s.map(\.name) == ["Hyperliquid", "Jupiter", "Solana"])
    #expect(s.reduce(0) { $0 + $1.share } == 100)
    #expect(s[0].share == Decimal(string: "66.7")!)
    #expect(PortfolioSplit.slices([]).isEmpty && PortfolioSplit.slices([("x", 0)]).isEmpty)
}

@Test func marketNames() {
    #expect(IntentParser.pretty("xyz:TSLA") == "Tesla (xyz:TSLA)")
    #expect(IntentParser.pretty("xyz:CL") == "WTI oil (xyz:CL)")
    #expect(IntentParser.pretty("ETH") == "ETH")
}
