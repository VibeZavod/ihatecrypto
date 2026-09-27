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

@Test func favoriteTokenPhrases() {
    let ai = "0x2e8c31162b855a2ffa90f6f8634643ad6f111e18"
    #expect(TokenCommand.parse("и добавь в favorite вот этот токен на робингуде \(ai)") == .favorite(address: ai, chain: "robinhood"))
    #expect(TokenCommand.parse("watch token \(ai) on Base") == .favorite(address: ai, chain: "base"))
    #expect(TokenCommand.parse("add \(ai) to favorites") == .favorite(address: ai, chain: nil))
    #expect(TokenCommand.parse("remove token AI from favorites") == .unfavorite(symbol: "AI"))
    // An address for the book, or a transfer, is not a token.
    #expect(TokenCommand.parse("save \(ai) as Bybit on Base") == nil)
    // «купи 0x… токен на $2» is a trade, not a favorite.
    #expect(TokenCommand.parse("купи \(ai) токен на $2") == nil)
    #expect(WalletCommand.parse("купи \(ai) токен на $2") == .buyStock(symbol: ai, usdc: 2))
    #expect(WalletCommand.parse("sell 3 tokens \(ai)") == .sellStock(symbol: ai, amount: 3))
    #expect(WalletCommand.parse("send 2 USDC to \(ai)") != .buyStock(symbol: ai, usdc: 2))
    #expect(TokenCommand.parse("send 1 USDC to \(ai)") == nil)
}

@Test func dexscreenerPairsToTokenInfo() {
    let json = #"{"pairs":[{"chainId":"robinhood","url":"https://dexscreener.com/robinhood/0xpool1","baseToken":{"address":"0x2E8C31162B855A2FFA90F6F8634643AD6F111E18","name":"Artificial Inu","symbol":"AI"},"priceUsd":"0.2366","priceChange":{"h24":-3.5},"liquidity":{"usd":1369513.5},"info":{"imageUrl":"https://cdn.dexscreener.com/cms/images/x"}},{"chainId":"robinhood","baseToken":{"address":"0x2e8c31162b855a2ffa90f6f8634643ad6f111e18","name":"Artificial Inu","symbol":"AI"},"priceUsd":"0.2352","liquidity":{"usd":3301648.7}},{"chainId":"robinhood","baseToken":{"address":"0xother","name":"X","symbol":"X"},"priceUsd":"9","liquidity":{"usd":9999999}}]}"#
    let infos = TokenLookup.parse(Data(json.utf8), address: "0x2e8c31162b855a2ffa90f6f8634643ad6f111e18")
    #expect(infos.count == 1)
    #expect(infos[0].symbol == "AI" && infos[0].liquidityUSD == Decimal(string: "3301648.7")!)   // the deepest pair wins
    #expect(infos[0].priceUSD == Decimal(string: "0.2352")!)
}

@Test func pinchKeepsThePointUnderTheFingers() {
    let pan = (x: 40.0, y: -30.0), scale = 0.8, fingers = (x: 300.0, y: 220.0)
    // The content point under the fingers before the pinch…
    let c = (x: (fingers.x - pan.x) / scale, y: (fingers.y - pan.y) / scale)
    for k in [0.5, 1.7, 2.5] {
        let next = CanvasZoom.pan(keeping: fingers, from: pan, by: k)
        // …is still under them after it.
        #expect(abs(next.x + c.x * scale * k - fingers.x) < 0.0001)
        #expect(abs(next.y + c.y * scale * k - fingers.y) < 0.0001)
    }
}
