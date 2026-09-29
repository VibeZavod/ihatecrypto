import Foundation
@testable import LalaCore
import Testing

@Test func solanaHoldingsShowBoughtTokensAndTuckAwayAirdrops() {
    let json = """
    [{"id": "RAYmint", "symbol": "RAY", "icon": "https://cdn/ray.png", "usdPrice": 1.88, "liquidity": 18801373, "isVerified": true, "tags": ["verified"]},
     {"id": "jlUSDCmint", "symbol": "jlUSDC", "usdPrice": 1.06, "isVerified": true, "tags": ["verified", "jup-lend-earn"]},
     {"id": "MEMEmint", "symbol": "POKEMON", "usdPrice": 0.0004, "liquidity": 36500, "isVerified": false, "tags": ["token-2022"]},
     {"id": "SPAMmint", "symbol": "USDC", "usdPrice": 0.000001, "liquidity": 12, "isVerified": false, "tags": []}]
    """
    let amounts: [String: Decimal] = ["RAYmint": Decimal(string: "1.065743")!, "jlUSDCmint": 5, "MEMEmint": 2500, "SPAMmint": 1000, "Unknownmint": 3]
    let held = Solana.holdings(amounts, jupiter: [Data(json.utf8)])

    // Jupiter Lend's shares are the Jupiter Lend row, not a token.
    #expect(!held.contains { $0.symbol == "jlUSDC" })
    // The most valuable first.
    #expect(held.first?.symbol == "RAY")
    #expect(held.first?.usd == Decimal(string: "1.88")! * Decimal(string: "1.065743")!)

    let bySymbol = Dictionary(uniqueKeysWithValues: held.map { ($0.contract, $0) })
    #expect(bySymbol["RAYmint"]?.looksReal == true)
    // Bought with Safe search off: unverified, but a real pool and ≈ $1 in it.
    #expect(bySymbol["MEMEmint"]?.looksReal == true)
    // A fake «USDC» airdrop: no pool to speak of.
    #expect(bySymbol["SPAMmint"]?.looksReal == false)
    // Jupiter doesn't know it: shown by mint, unpriced, tucked away.
    #expect(bySymbol["Unknownmint"]?.symbol == "Unkn…")
    #expect(bySymbol["Unknownmint"]?.usd == nil)
    #expect(bySymbol["Unknownmint"]?.looksReal == false)
}

@Test func evmHoldingsSkipWhatIsCountedAndPriceTheRestOffDexScreener() {
    let blockscout = """
    {"items": [
      {"token": {"address_hash": "0x940181a94A35A4569E4529A3CDfB74e38FD98631", "decimals": "18", "exchange_rate": "0.836101", "reputation": "ok", "symbol": "AERO", "icon_url": "https://cdn/aero.png"}, "value": "2400000000000000000"},
      {"token": {"address_hash": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", "decimals": "6", "exchange_rate": "1", "symbol": "USDC"}, "value": "5000000"},
      {"token": {"address_hash": "0xMEME", "decimals": "18", "exchange_rate": null, "symbol": "MEME"}, "value": "1000000000000000000000"},
      {"token": {"address_hash": "0xSPAM", "decimals": "18", "exchange_rate": null, "symbol": "Claim-USDC.com"}, "value": "1000000000000000000000"},
      {"token": {"address_hash": "0xFAKE", "decimals": "18", "exchange_rate": "1", "reputation": "scam", "symbol": "USDT"}, "value": "1000000000000000000000"}
    ]}
    """
    let items = (try? JSONSerialization.jsonObject(with: Data(blockscout.utf8)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
    let tokens = Holdings.evmTokens("base", items, skip: ["0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"])
    // USDC on Base is the Base row's; the rest are listed.
    #expect(tokens.map(\.symbol) == ["AERO", "MEME", "Claim-USDC.com", "USDT"])
    let dex = """
    [{"baseToken": {"address": "0xmeme"}, "priceUsd": "0.002", "liquidity": {"usd": 5000}},
     {"baseToken": {"address": "0xmeme"}, "priceUsd": "0.0021", "liquidity": {"usd": 80000}}]
    """
    let priced = Dictionary(uniqueKeysWithValues: Holdings.dexPrices(tokens, Data(dex.utf8)).map { ($0.symbol, $0) })
    #expect(priced["AERO"]?.usd == Decimal(string: "2.0066424")!)
    #expect(priced["AERO"]?.looksReal == true)
    // Not on CoinGecko, but the deepest pool prices it: bought, so shown.
    #expect(priced["MEME"]?.price == Decimal(string: "0.0021")!)
    #expect(priced["MEME"]?.looksReal == true)
    // An airdrop with no pool, and a scam-flagged fake: tucked away.
    #expect(priced["Claim-USDC.com"]?.looksReal == false)
    #expect(priced["USDT"]?.looksReal == false)
    #expect(priced["AERO"]?.id == "base:0x940181a94a35a4569e4529a3cdfb74e38fd98631")
}

@Test func hyperliquidSpotCountsUSDCAndPricesTokensOffTheBook() {
    let state = """
    {"balances": [{"coin": "USDC", "token": 0, "total": "3.5"}, {"coin": "HYPE", "token": 150, "total": "0.5"}, {"coin": "PURR", "token": 1, "total": "0"}]}
    """
    let meta = """
    [{"universe": [{"tokens": [1, 0], "index": 0}, {"tokens": [150, 0], "index": 1}]},
     [{"midPx": "0.143", "dayNtlVlm": "2830499"}, {"midPx": "87.77", "dayNtlVlm": "90000000"}]]
    """
    let spot = Holdings.hyperliquidSpot(Data(state.utf8), meta: Data(meta.utf8))
    #expect(spot.map(\.symbol) == ["USDC", "HYPE"])
    #expect(spot[0].usd == Decimal(string: "3.5")!)
    #expect(spot[1].usd == Decimal(string: "43.885")!)
    #expect(spot[1].looksReal == true)
}

@Test func nearTokensLeaveWrappedNearToTheNearRow() {
    let list = """
    {"tokens": [{"contract_id": "wrap.near", "balance": "1000000000000000000000000"},
                {"contract_id": "usdt.tether-token.near", "balance": "2500000"},
                {"contract_id": "junk.near", "balance": "5"}]}
    """
    let prices = """
    {"usdt.tether-token.near": {"price": "1.0", "symbol": "USDt", "decimal": 6}}
    """
    let tokens = Holdings.near(Data(list.utf8), prices: Data(prices.utf8), metadata: ["junk.near": ("JUNK", 0)])
    #expect(tokens.map(\.symbol) == ["USDt", "JUNK"])
    #expect(tokens[0].usd == Decimal(string: "2.5")!)
    #expect(tokens[0].looksReal == true)
    #expect(tokens[1].looksReal == false)
}
