import Foundation
@testable import LalaCore
import Testing

@Test func tokenMarketTakesTheDeepestPairOnTheChain() throws {
    let json = """
    {"pairs": [
      {"chainId": "robinhood", "dexId": "uniswap", "labels": ["v4"], "pairAddress": "0xpool1", "url": "https://dexscreener.com/robinhood/0xpool1",
       "baseToken": {"address": "0xAbC", "symbol": "AI"}, "quoteToken": {"symbol": "USDG"}, "priceUsd": "0.2185",
       "priceChange": {"m5": -0.33, "h24": -12.17}, "liquidity": {"usd": 1296765.77}, "fdv": 216361860, "marketCap": 218686541,
       "volume": {"h24": 3438123.08}, "txns": {"h24": {"buys": 2621, "sells": 2107}}, "pairCreatedAt": 1788444274000,
       "info": {"imageUrl": "https://cdn/ai.png", "websites": [{"url": "https://artificialinu.com/", "label": "Website"}],
                "socials": [{"url": "https://x.com/artificiallyinu", "type": "twitter"}]}},
      {"chainId": "robinhood", "dexId": "ramses", "pairAddress": "0xpool2", "baseToken": {"address": "0xabc"}, "liquidity": {"usd": 121830}},
      {"chainId": "base", "dexId": "aerodrome", "pairAddress": "0xpool3", "baseToken": {"address": "0xabc"}, "liquidity": {"usd": 9000000}},
      {"chainId": "robinhood", "dexId": "uniswap", "pairAddress": "0xpool4", "baseToken": {"address": "0xother"}, "liquidity": {"usd": 9000000}}
    ]}
    """
    let info = try #require(TokenMarket.parse(Data(json.utf8), address: "0xabc", chain: "robinhood"))
    #expect(info.pool == "0xpool1")
    #expect(info.dex == "uniswap v4")
    #expect(info.quote == "USDG")
    #expect(info.priceUSD == Decimal(string: "0.2185"))
    #expect(info.changes["h24"] == Decimal(string: "-12.17"))
    #expect(info.buys24h == 2621 && info.sells24h == 2107)
    #expect(info.links.map(\.label) == ["Website", "X"])
    #expect(info.created == Date(timeIntervalSince1970: 1_788_444_274))
    #expect(TokenMarket.parse(Data(json.utf8), address: "0xabc", chain: "solana") == nil)
}

@Test func tokenHistoryIsOldestFirst() {
    let json = #"{"data": {"attributes": {"ohlcv_list": [[1790532000, 0.22, 0.23, 0.21, 0.2185, 100], [1790528400, 0.21, 0.22, 0.2, 0.22, 90]]}}}"#
    let points = TokenMarket.parseHistory(Data(json.utf8))
    #expect(points.map(\.time.timeIntervalSince1970) == [1_790_528_400, 1_790_532_000])
    #expect(points.last?.close == Decimal(string: "0.2185"))
}
