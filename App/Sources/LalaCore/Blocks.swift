import Foundation

/// The blocks the agent builds a request from: each is one of ChatRouter.forms, drawn as the route card it becomes.
/// «Add block» on the canvas lists them; a pick puts its example into the chat to finish and send. The `automatic` ones
/// the agent adds to every trade by itself (the rules, Jev, the result): they're shown, not picked.
public enum BlockCatalog {
    public struct Block: Sendable, Identifiable, Equatable {
        public var id: String { label }
        public let group: String
        /// The route card's label; its first word picks the drawing (StepKind).
        public let label: String
        public let title: String
        /// The router's form, as the card says it.
        public let form: String
        /// What a pick puts into the chat. Every example parses (BlocksTests).
        public let example: String
        /// A RouteFill's raw value: the card's colour.
        public let fill: String
        public let logo: String?
        public var automatic = false
    }

    public static let groups = ["Trade", "Triggers", "Move money", "Buy and sell", "Earn", "Tempo"]

    public static let all: [Block] = [
        Block(group: "Trade", label: "OPEN LONG · HYPERLIQUID", title: "Long or short", form: "long|short ASSET · risk $N · stop N% · take N% · leverage Nx",
              example: "long SOL by the book", fill: "hyperliquid", logo: "hype"),
        Block(group: "Trade", label: "PROTECT", title: "Stop and take", form: "take NR · take in parts · trailing N% · move stop to breakeven",
              example: "take in parts", fill: "hyperliquid", logo: "hype"),
        Block(group: "Trade", label: "CHECK RULES", title: "Risk rules", form: "risk ≤ 2% of capital · reward/risk ≥ 1.5 · leverage ≤ 5×",
              example: "", fill: "check", logo: nil, automatic: true),
        Block(group: "Trade", label: "SECOND CHECK", title: "Second check", form: "the plan against your words, then every signature",
              example: "", fill: "check", logo: nil, automatic: true),
        Block(group: "Trade", label: "RESULT · ESTIMATE", title: "Loss or profit", form: "at the stop and at the take, in $ and % of capital",
              example: "", fill: "check", logo: nil, automatic: true),

        Block(group: "Triggers", label: "WHEN · PRICE FALLS TO", title: "Price alert", form: "when ASSET is above|below PRICE: a trade or a move",
              example: "alert me when SOL is below 115", fill: "check", logo: "sol"),
        Block(group: "Triggers", label: "LATER · SCHEDULE", title: "Later or on repeat", form: "in N days: … · at HH:MM: … · every week: … · every month on the 1st: …",
              example: "in 1 week: rebalance USDC", fill: "check", logo: nil),

        Block(group: "Move money", label: "BRIDGE · RELAY", title: "Between networks", form: "move N USDC from Solana to Base|Arbitrum|Polygon|Ethereum|Robinhood|Tempo, and back",
              example: "move 5 USDC from Solana to Base", fill: "relay", logo: "relay"),
        Block(group: "Move money", label: "FROM · HYPERLIQUID", title: "Back to Solana", form: "withdraw N USDC to Solana",
              example: "withdraw 1 USDC to Solana", fill: "hyperliquid", logo: "hype"),
        Block(group: "Move money", label: "TO · ADDRESS BOOK", title: "Send", form: "send N USDC|SOL|NEAR to NAME from the address book",
              example: "send 1 USDC to Bybit", fill: "solana", logo: "usdc"),

        Block(group: "Buy and sell", label: "SWAP · JUPITER", title: "Tokens on Solana", form: "buy|sell SOL, BTC, ETH, JUP, BONK… for N USDC",
              example: "buy SOL for 2 USDC", fill: "jupiter", logo: "jup"),
        Block(group: "Buy and sell", label: "BUY · ON BASE", title: "Base and Arbitrum", form: "buy TICKER on base|arbitrum for N USDC · Relay or Uniswap, the better",
              example: "buy AERO on base for 2 USDC", fill: "base", logo: "base"),
        Block(group: "Buy and sell", label: "BUY · ROBINHOOD CHAIN", title: "Stock tokens", form: "buy TSLA, NVDA, SpaceX… stock for N USDC",
              example: "buy TSLA stock for 2 USDC", fill: "robinhood", logo: "robinhood"),
        Block(group: "Buy and sell", label: "SWAP · NEAR INTENTS", title: "NEAR", form: "buy NEAR for N USDC · sell NEAR",
              example: "buy NEAR for 2 USDC", fill: "near", logo: "near"),

        Block(group: "Earn", label: "INTO · JUPITER LEND", title: "Lend on Solana", form: "lend N USDC|SOL · withdraw N USDC from the vault",
              example: "lend 1 USDC", fill: "jupiter", logo: "jup"),
        Block(group: "Earn", label: "INTO · KAMINO", title: "Kamino", form: "deposit N USDC|SOL to kamino · withdraw from kamino",
              example: "deposit 1 USDC to kamino", fill: "kamino", logo: "kamino"),
        Block(group: "Earn", label: "INTO · AAVE", title: "Aave", form: "lend N USDC on Aave on Base|Arbitrum|Polygon|Ethereum",
              example: "lend 2 USDC on Aave", fill: "aave", logo: "aave"),
        Block(group: "Earn", label: "INTO · MORPHO", title: "Morpho", form: "deposit N USDC into Morpho on Base|Arbitrum|Ethereum",
              example: "deposit 2 USDC into Morpho", fill: "morpho", logo: "morpho"),
        Block(group: "Earn", label: "INTO · HLP", title: "Hyperliquid's vault", form: "deposit N USDC to HLP · from $5, locked 4 days",
              example: "deposit 5 USDC to HLP", fill: "hlp", logo: "hype"),
        Block(group: "Earn", label: "STAKE · JITO", title: "Stake SOL", form: "stake N SOL · unstake N JitoSOL",
              example: "stake 0.01 SOL", fill: "jito", logo: "jitosol"),
        Block(group: "Earn", label: "INTO · BEST RATES", title: "The best rates", form: "spread N USDC across the best rates · rebalance USDC",
              example: "spread USDC across the best rates", fill: "jupiter", logo: "usdc"),

        // Tempo: its money moves, then services paid per request in USDC there (MPP). Each example is a real endpoint
        // from mpp.dev's directory with the body its docs give, priced live by its 402 (2026-09-30); the card shows the price
        // before paying. Tempo's own proxies (*.mpp.tempo.xyz: fal, OpenAI, Anthropic) take only sponsored transactions
        // the service sends, which the signer doesn't make yet, and StableStudio's pictures come later behind a sign-in.
        Block(group: "Tempo", label: "BRIDGE · TO TEMPO", title: "USDC to Tempo", form: "move N USDC from Solana to Tempo · and back to Solana",
              example: "move 2 USDC from Solana to Tempo", fill: "tempo", logo: "tempo"),
        Block(group: "Tempo", label: "SEND · ON TEMPO", title: "Send on Tempo", form: "send N USDC to NAME saved on Tempo · fee ≈ $0.001 in USDC",
              example: "send 5 USDC to Mom", fill: "tempo", logo: "tempo"),
        Block(group: "Tempo", label: "EVERY MONTH · 1ST", title: "Monthly transfer", form: "every month on the 1st…28th [at HH:MM]: send N USDC to NAME",
              example: "every month on the 1st at 10:00: send 20 USDC to Mom", fill: "tempo", logo: "tempo"),
        Block(group: "Tempo", label: "PAY · WEB SEARCH", title: "Search the web", form: "Brave Search · $0.035 a search · web, news, images, video",
              example: #"pay POST https://brave.mpp.paywithlocus.com/brave/web-search {"q":"Tempo MPP payments"}"#, fill: "tempo", logo: "tempo"),
        Block(group: "Tempo", label: "PAY · CRYPTO PRICE", title: "Crypto prices", form: "CoinGecko · $0.06 a request · prices, markets, coin data",
              example: #"pay POST https://coingecko.mpp.paywithlocus.com/coingecko/simple-price {"ids":"bitcoin","vs_currencies":"usd"}"#, fill: "tempo", logo: "tempo"),
        Block(group: "Tempo", label: "PAY · WEATHER", title: "Weather", form: "OpenWeather · $0.006 · now, 5 days, air quality by lat/lon",
              example: #"pay POST https://openweather.mpp.paywithlocus.com/openweather/current-weather {"lat":55.7558,"lon":37.6173}"#, fill: "tempo", logo: "tempo"),
        Block(group: "Tempo", label: "PAY · TRANSLATE", title: "Translate", form: "DeepL · priced per text · 30+ languages",
              example: #"pay POST https://deepl.mpp.paywithlocus.com/deepl/translate {"text":["Hello from ihatecrypto"],"target_lang":"RU"}"#, fill: "tempo", logo: "tempo"),
        Block(group: "Tempo", label: "PAY · EMAIL", title: "Send an email", form: "StableEmail · $0.02 a letter · to, subject, text",
              example: #"pay POST https://stableemail.dev/api/send {"to":["you@example.com"],"subject":"Hi","text":"Sent from ihatecrypto"}"#, fill: "tempo", logo: "tempo"),
        Block(group: "Tempo", label: "PAY · PHONE CALL", title: "AI phone call", form: "StablePhone · $0.54 a call · a number and what to say",
              example: #"pay POST https://stablephone.dev/api/call {"phone_number":"+14155551234","task":"Ask if the table for two at 8 pm is still free."}"#,
              fill: "tempo", logo: "tempo"),
        Block(group: "Tempo", label: "PAY · FLIGHTS", title: "Cheapest flights", form: "StableTravel · $0.02 · Google Flights by airports and date",
              example: "pay GET https://stabletravel.dev/api/google-flights/search?departure_id=SVO&arrival_id=IST&outbound_date=2026-10-15&type=2",
              fill: "tempo", logo: "tempo"),
    ]
}
