import Foundation
import LLMCore

/// The model reads every message first, for its meaning in any language and in the context of the chat, the plan and
/// the portfolio, and says what it is: a command (rewritten as one English line in the forms below), a question, a
/// plan change, conversation or something to clarify. It never acts: a command goes through the same parsers, checks,
/// Jev and confirmations as a typed one, and an address may only come from the user's message or their own favorites.
public enum ChatRouter {
    public enum Route: Equatable, Sendable {
        case command(String)
        case question
        case plan
        case chat(String)
        case clarify(String)
    }

    /// What the model may know besides the message: never keys, never full balances history.
    public struct Context: Sendable {
        public var recent: [String] = []
        public var plan: String?
        public var positions: [String] = []
        /// «AI (Artificial Inu) = 0x… on Robinhood Chain»
        public var favorites: [String] = []
        public var addressBook: [String] = []
        public var balances: [String] = []
        public init() {}
    }

    /// Every example must parse locally (RouterTests): the model is told to produce exactly these.
    public static let forms = """
    TRADE PLAN (a perp on Hyperliquid; ASSET is a crypto ticker like BTC, ETH, SOL, HYPE, or oil, brent, gold, silver, or a stock ticker like TSLA, NVDA):
      long|short <ASSET> [risk $N] [stop N%] [take N% | take NR] [leverage Nx] [by the book] [on a N% pullback] [limit <PRICE>] [take in parts] [trailing N%]
      with a plan already on the canvas, a change alone: risk $N | stop N% | take N% | take NR | leverage Nx | limit <PRICE> | at market | by the book
      take profit options   (how pros take profit)
    OPEN POSITION (add the asset when there are several, e.g. "close ETH"):
      move stop to breakeven | stop at <PRICE> | take at <PRICE> | trail N% | close | close half | close N% | cancel orders
    SPOT ON SOLANA (Jupiter): buy <SOL|BTC|ETH|JUP|JitoSOL> for N USDC | sell [N] <SOL|BTC|ETH|JUP>
      buy <SOL|BTC|ETH|JUP> for N USDC every <day|week|N days> | stop recurring buys
      buy NEAR for N USDC
    STOCK TOKENS ON ROBINHOOD CHAIN: buy <COMPANY or TICKER> stock for N USDC | sell <TICKER> stock | move USDG from Robinhood to Solana
    ANY TOKEN BY ITS CONTRACT (Robinhood Chain): buy token <0xCONTRACT> for N USDC | sell [N] tokens <0xCONTRACT>
    EARNING: lend [N] <USDC|SOL|USDT> (Jupiter Lend, "the vault") | withdraw [N] <USDC|SOL> from the vault
      deposit N <USDC|SOL> to kamino | withdraw <USDC|SOL> from kamino | stake N SOL | unstake N JitoSOL
      deposit N USDC to HLP | withdraw from HLP | lend N USDC on Aave | withdraw USDC from Aave
      where to keep <USDC|SOL> | spread <USDC|SOL> across the best rates [max N% per protocol]
    MOVING MONEY: withdraw N USDC to Solana (from Hyperliquid) | move N USDC from Base to Solana | move N USDC from Arbitrum to Solana
      send N USDC to <NAME from the address book> | top up (where to send money into LALA)
    ADDRESSES AND WATCHLIST: save <ADDRESS> as <NAME> [on solana|base|arbitrum|ethereum|hyperliquid] | add <NAME> to favorites | remove <NAME> from favorites
      watch token <0xCONTRACT> [on robinhood|base|arbitrum|ethereum|solana] | remove token <SYMBOL> from favorites
    MARKET: chart <ASSET> [week|month] | what's moving | alert me when <ASSET> is above|below <PRICE> | cancel alerts
    APP: new canvas | clear the plan | lock
    """

    static let system = """
    You are the understanding layer of LALA, a crypto wallet and trading assistant. The user writes in ANY language and in their own words. \
    Understand what they mean from the message, the recent chat, the plan, the positions and their favorites, and return only a JSON object:
    {"route": "command" | "question" | "plan" | "chat" | "clarify", "command": "...", "reply": "..."}
    - "command": they want LALA to do something it can do. "command" is ONE line in exactly one of these English forms:
    \(forms)
      Keep numbers, tickers, prices and percentages as the user meant them; never invent an amount: leave it out and LALA asks.
      A token the user names by symbol that is among their favorites is written with that favorite's contract. Never write any other address.
      "$2", "2 бакса", "два доллара" are 2 USDC.
    - "question": about their money, positions, history, prices or whether something is a good idea now. LALA answers from live data.
    - "plan": a change to the trade plan the forms can't say, like "take closer", "less risk", "wider stop".
    - "chat": greetings, thanks, what LALA can do, what a DeFi term means. "reply": the answer, 1–3 short sentences in English. Never invent numbers or prices.
    - "clarify": the request is ambiguous or can't be done by LALA. "reply": one short question or a plain "LALA can't do X yet" in English.
    """

    public static func route(_ text: String, context: Context, client: any LLMClient, model: String) async throws -> Route {
        var lines: [String] = []
        if !context.recent.isEmpty { lines.append("Recent chat (oldest first):\n" + context.recent.joined(separator: "\n")) }
        lines.append("Plan on the canvas: " + (context.plan ?? "none"))
        lines.append("Open positions: " + (context.positions.isEmpty ? "none" : context.positions.joined(separator: "; ")))
        if !context.favorites.isEmpty { lines.append("Favorite tokens: " + context.favorites.joined(separator: "; ")) }
        if !context.addressBook.isEmpty { lines.append("Address book names: " + context.addressBook.joined(separator: ", ")) }
        if !context.balances.isEmpty { lines.append("Balances: " + context.balances.joined(separator: "; ")) }
        lines.append("Message: " + text)
        let reply = try await client.complete(LLMRequest(model: model, messages: [
            LLMMessage(.system, system), LLMMessage(.user, lines.joined(separator: "\n")),
        ], wantsJSON: true))
        guard let json = JSONText.object(in: reply) else { throw LLMError("The model did not reply with JSON: \(reply.prefix(120))") }
        return try decode(json)
    }

    static func decode(_ json: Data) throws -> Route {
        struct Answer: Decodable { let route: String; let command: String?; let reply: String? }
        let a = try JSONDecoder().decode(Answer.self, from: json)
        let command = a.command?.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'«» \n")) ?? ""
        let reply = a.reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch a.route {
        case "command" where !command.isEmpty && command.count <= 200: return .command(command)
        case "question": return .question
        case "plan": return .plan
        case "chat" where !reply.isEmpty: return .chat(reply)
        case "clarify" where !reply.isEmpty: return .clarify(reply)
        default: throw LLMError("The model's route makes no sense: \(a.route)")
        }
    }

    /// The model never supplies an address: each one in its command must be in the user's own message, character for
    /// character, or be the contract of one of their favorite tokens.
    public static func addressesAllowed(_ command: String, userText: String, known: [String]) -> Bool {
        let found = command.matches(of: /0x[0-9a-fA-F]{40}|[1-9A-HJ-NP-Za-km-z]{32,44}/).map { String($0.0) }
        let knownSet = Set(known.map { $0.lowercased() })
        return found.allSatisfy { userText.contains($0) || knownSet.contains($0.lowercased()) }
    }
}
