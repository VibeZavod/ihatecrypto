import Foundation

/// The five biggest dollar stablecoins — USDT ($184B), USDC ($74B), USDS ($7.1B), USDe ($4.9B), DAI ($4.8B) by DefiLlama on
/// 2026-10-08 — where each really is on a network ihatecrypto has a wallet on. Addresses, symbols, decimals and supply read
/// on-chain 2026-10-08; a deployment with under ≈ $1M out (USDS and USDe on Optimism, DAI on Solana) is left out.
public enum Stablecoins {
    public struct Coin: Sendable, Equatable {
        /// The ticker people use: USDT for USD₮0 too.
        public let symbol: String
        /// The contract, the Solana mint, the NEAR token account, or Hyperliquid's spot name.
        public let address: String
        public let decimals: Int
        /// The other tickers it answers to («USDT0», «USD₮0»).
        public var also: [String] = []
    }

    public static let top = ["USDT", "USDC", "USDS", "USDe", "DAI"]

    static let usde = "0x5d3a1ff2b6bab83b63cd9ad0787074081a52ef34" // the same address on every EVM network Ethena is on
    static let usdt0 = ["USDT0", "USD₮0"]

    public static let byNetwork: [String: [Coin]] = [
        "solana": [Coin(symbol: "USDC", address: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", decimals: 6),
                   Coin(symbol: "USDT", address: "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB", decimals: 6),
                   Coin(symbol: "USDS", address: "USDSwr9ApdHk5bvJKMjzff41FfuX8bSxdKcR81vTwcA", decimals: 6),
                   Coin(symbol: "USDe", address: "DEkqHyPN7GMRJ5cArtQFAWefqbZb33Hyf6s5iCwjEonT", decimals: 9)],
        "ethereum": [Coin(symbol: "USDC", address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", decimals: 6),
                     Coin(symbol: "USDT", address: "0xdac17f958d2ee523a2206206994597c13d831ec7", decimals: 6),
                     Coin(symbol: "USDS", address: "0xdc035d45d973e3ec169d2276ddab16f1e407384f", decimals: 18),
                     Coin(symbol: "USDe", address: "0x4c9edd5852cd905f086c759e8383e09bff1e68b3", decimals: 18),
                     Coin(symbol: "DAI", address: "0x6b175474e89094c44da98b954eedeac495271d0f", decimals: 18)],
        "base": [Coin(symbol: "USDC", address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", decimals: 6),
                 Coin(symbol: "USDT", address: "0xfde4c96c8593536e31f229ea8f37b2ada2699bb2", decimals: 6),
                 Coin(symbol: "USDS", address: "0x820c137fa70c8691f0e44dc420a5e53c168921dc", decimals: 18),
                 Coin(symbol: "USDe", address: usde, decimals: 18),
                 Coin(symbol: "DAI", address: "0x50c5725949a6f0c72e6c4a641f24049a917db0cb", decimals: 18)],
        "arbitrum": [Coin(symbol: "USDC", address: "0xaf88d065e77c8cc2239327c5edb3a432268e5831", decimals: 6),
                     Coin(symbol: "USDT", address: "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9", decimals: 6, also: usdt0),
                     Coin(symbol: "USDS", address: "0x6491c05a82219b8d1479057361ff1654749b876b", decimals: 18),
                     Coin(symbol: "USDe", address: usde, decimals: 18),
                     Coin(symbol: "DAI", address: "0xda10009cbd5d07dd0cecc66161fc93d7c9000da1", decimals: 18)],
        "optimism": [Coin(symbol: "USDC", address: "0x0b2c639c533813f4aa9d7837caf62653d097ff85", decimals: 6),
                     Coin(symbol: "USDT", address: "0x94b008aa00579c1307b0ef2c499ad98a8ce58e58", decimals: 6),
                     Coin(symbol: "USDT0", address: "0x01bff41798a0bcf287b996046ca68b395dbc1071", decimals: 6, also: ["USD₮0"]),
                     Coin(symbol: "DAI", address: "0xda10009cbd5d07dd0cecc66161fc93d7c9000da1", decimals: 18)],
        "polygon": [Coin(symbol: "USDC", address: "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359", decimals: 6),
                    Coin(symbol: "USDT", address: "0xc2132d05d31c914a87c6611c10748aeb04b58e8f", decimals: 6, also: usdt0),
                    Coin(symbol: "DAI", address: "0x8f3cf7ad23cd3cadbd9735aff958023239c6a063", decimals: 18)],
        // Binance-Peg: 18 decimals, USDC too.
        "bnb": [Coin(symbol: "USDC", address: "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d", decimals: 18),
                Coin(symbol: "USDT", address: "0x55d398326f99059ff775485246999027b3197955", decimals: 18),
                Coin(symbol: "USDe", address: usde, decimals: 18),
                Coin(symbol: "DAI", address: "0x1af3f329e8be154074d8769d1ffa4ee058b1dbc3", decimals: 18)],
        "hyperevm": [Coin(symbol: "USDC", address: "0xb88339cb7199b77e23db6e890353e22632ba630f", decimals: 6),
                     Coin(symbol: "USDT0", address: "0xb8ce59fc3717ada4c02eadf9682a9e934f625ebb", decimals: 6, also: ["USDT", "USD₮0"]),
                     Coin(symbol: "USDe", address: usde, decimals: 18)],
        "tempo": [Coin(symbol: "USDC", address: "0x20c000000000000000000000b9537d11c60e8b50", decimals: 6),
                  Coin(symbol: "USDT0", address: "0x20c00000000000000000000014f22ca97301eb73", decimals: 6, also: ["USDT", "USD₮0"])],
        "hyperliquid": [Coin(symbol: "USDC", address: "USDC", decimals: 8),
                        Coin(symbol: "USDT0", address: "USDT0", decimals: 8, also: ["USDT", "USD₮0"]),
                        Coin(symbol: "USDE", address: "USDE", decimals: 8, also: ["USDe"])],
        "near": [Coin(symbol: "USDC", address: "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1", decimals: 6),
                 Coin(symbol: "USDT", address: "usdt.tether-token.near", decimals: 6)],
    ]

    /// The coin a ticker names on a network: «usdt» is USD₮0 on Arbitrum and Polygon, USDT0 on HyperEVM and Hyperliquid.
    public static func find(_ ticker: String, on network: String) -> Coin? {
        let want = ticker.trimmingCharacters(in: CharacterSet(charactersIn: "$ ")).uppercased()
        return byNetwork[network]?.first { $0.symbol.uppercased() == want || $0.also.contains { $0.uppercased() == want } }
    }

    /// Every dollar counted at $1: the five, their other tickers, and the networks' own (USDG, pathUSD, Tempo's OUSD).
    public static let dollars: Set<String> = Set(byNetwork.values.joined().flatMap { [$0.symbol] + $0.also }.map { $0.uppercased() })
        .union(["USDG", "PATHUSD", "OUSD", "USDC.E", "USDBC", "PYUSD", "USD1"])

    /// Whether a held token is one of the five on its own contract (or Hyperliquid spot name) there — not a lookalike.
    public static func isGenuine(_ contract: String, on network: String) -> Bool {
        byNetwork[network]?.contains { $0.address.lowercased() == contract.lowercased() } == true
    }

    /// Whether a ticker is a dollar stablecoin ihatecrypto counts at $1.
    public static func isDollar(_ ticker: String) -> Bool { dollars.contains(ticker.uppercased()) }

    /// Where each is, for the model's brief and the texts: «Solana: USDC, USDT, USDS, USDe · Ethereum: …».
    public static var brief: String {
        ["solana", "ethereum", "base", "arbitrum", "optimism", "polygon", "bnb", "hyperevm", "hyperliquid", "tempo", "near"].compactMap { k in
            byNetwork[k].map { "\(k == "hyperliquid" ? "Hyperliquid spot" : k == "solana" ? "Solana" : WalletCommand.placeName(k)): " + $0.map(\.symbol).joined(separator: ", ") }
        }.joined(separator: " · ")
    }

    /// The networks a stablecoin is on, as ihatecrypto knows them: for the texts.
    public static func networks(_ symbol: String) -> [String] {
        byNetwork.keys.sorted().filter { find(symbol, on: $0) != nil }
    }
}
