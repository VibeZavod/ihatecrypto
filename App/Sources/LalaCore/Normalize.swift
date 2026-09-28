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
        /// «Russian» or «English»: the language chat and clarify replies are written in (ChatLanguage).
        public var replyLanguage = "English"
        /// Networks, kinds and protocols switched off in Settings › Modules (`Modules.offSummary`); empty when none.
        public var off = ""
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
      buy NEAR for N USDC | sell [N] NEAR   (native NEAR on the NEAR account → USDC on Solana; no N = all of it)
    STOCK TOKENS ON ROBINHOOD CHAIN: buy <COMPANY or TICKER> stock for N USDC | sell <TICKER> stock | move USDG from Robinhood to Solana
    ANY TOKEN BY ITS CONTRACT (Robinhood Chain): buy token <0xCONTRACT> for N USDC | sell [N] tokens <0xCONTRACT>
    EARNING: lend [N] <USDC|SOL|USDT> (Jupiter Lend, "the vault") | withdraw [N] <USDC|SOL> from the vault
      deposit N <USDC|SOL> to kamino | withdraw <USDC|SOL> from kamino | stake N SOL | unstake N JitoSOL
      deposit N USDC to HLP | withdraw from HLP | lend N USDC on Aave | withdraw USDC from Aave | deposit N USDC into Morpho | withdraw USDC from Morpho
      where to keep <USDC|SOL> | spread <USDC|SOL> across the best rates [max N% per protocol]
      rebalance USDC [max N% per protocol]   (moves money ALREADY in vaults to better rates: «переложи», «перекинь депозиты», «перебалансируй», «rebalance». «spread» / «разложи» / «распредели» is only for FREE USDC on Solana)
    MOVING MONEY: withdraw N USDC to Solana (from Hyperliquid) | move N USDC from Base to Solana | move N USDC from Arbitrum to Solana
      move N USDC from Solana to <Base|Arbitrum|Robinhood>   (arrives as USDG on Robinhood Chain)
      send N USDC to <NAME from the address book> | top up (where to send money into ihatecrypto)
      send N NEAR to <NAME from the address book> | send all NEAR to <NAME> | close the NEAR account into <NAME>
      send N SOL to <NAME from the address book>
    ADDRESSES AND WATCHLIST: save <ADDRESS> as <NAME> [on solana|base|arbitrum|ethereum|hyperliquid|near] | add <NAME> to favorites | remove <NAME> from favorites
      watch token <0xCONTRACT> [on robinhood|base|arbitrum|ethereum|solana] | remove token <SYMBOL> from favorites
    MARKET: chart <ASSET> [week|month] | what's moving | alert me when <ASSET> is above|below <PRICE> | cancel alerts
    P/L: profit and loss [today|week|month|all] [for <ASSET>]   (how much they made or lost, on trading and on the whole portfolio)
    APP: new canvas | clear the plan | lock
    """

    static let system = """
    You are ihatecrypto's mind: the user's own crypto wallet and trading agent. Understand what they want the way a sharp human \
    assistant would — from the whole conversation, not from keywords. They write in any language, casually, with typos \
    («робингуд»/«робинхуд» = Robinhood Chain, «хайпер» = Hyperliquid, «солана»/«сол» = the Solana wallet, «бакс» = a dollar).

    Where their money lives, all at their own addresses: the Solana wallet (USDC and SOL, the hub); Hyperliquid (perp margin \
    and the HLP vault); Jupiter Lend and Kamino on Solana; Base (Aave, Morpho, idle USDC); Arbitrum (idle USDC); Robinhood \
    Chain (USDG, stock tokens, tokens by contract); NEAR.
    How money moves: through Solana. Solana ⇄ Base, Arbitrum and Robinhood Chain over Relay; Hyperliquid → Solana; a trade \
    plan brings USDC from Solana to Hyperliquid by itself; NEAR ⇄ Solana USDC through NEAR Intents (buy NEAR / sell NEAR); every vault is entered from Solana and left back to Solana \
    in ONE command — Aave and Morpho too: «withdraw USDC from Aave» withdraws on Base and bridges to Solana by itself, so never \
    split it into two steps. Selling stock tokens or tokens by contract leaves USDG on Robinhood Chain; «move USDG from Robinhood \
    to Solana» brings it back. \
    Between two places that aren't Solana there is no direct move: it's two steps through Solana.

    Return only a JSON object: {"route": "command" | "question" | "plan" | "chat" | "clarify", "command": "...", "reply": "..."}
    - "command": they want ihatecrypto to do something it can do. "command" is ONE line in exactly one of these English forms:
    \(forms)
      Pick the form that means exactly what they asked: the same action, the same direction, the same place. Never swap in a \
      different action because it looks close — moving money the wrong way is the worst mistake you can make.
      Resolve references from the chat: «да», «давай», «do it», «ok» after your own suggestion or question is that suggestion; \
      «то же для ETH», «а теперь половину» build on the last request.
      Keep numbers, tickers, prices and percentages as meant; never invent an amount: leave it out and ihatecrypto asks for it.
      A token they name by symbol that is among their favorites is written with that favorite's contract. Never write any \
      other address. «$2», «2 бакса», «два доллара» are 2 USDC; «всё» / «all» means leave the amount out of a withdrawal.
    - "question": about their money, positions, history, prices, or whether something is a good idea now. ihatecrypto answers from live data.
    - "plan": a change to the trade plan the forms can't say, like "take closer", "less risk", "wider stop".
    - "chat": greetings, thanks, what ihatecrypto can do, what a DeFi term means. "reply": the answer, 1–3 short sentences in the reply language. \
      Never invent numbers or prices.
    - "clarify": ambiguous, or no single form does it. "reply" in the reply language, one or two short sentences: say what is missing, or \
      offer the closest way ihatecrypto can do it as a concrete next step the user can accept with «yes» — e.g. «Hyperliquid → Kamino \
      goes through Solana: withdraw 5 USDC to Solana first, then deposit it into Kamino. Withdraw now?»
    """

    public static func route(_ text: String, context: Context, client: any LLMClient, model: String) async throws -> Route {
        var lines: [String] = []
        if !context.recent.isEmpty { lines.append("Recent chat (oldest first):\n" + context.recent.joined(separator: "\n")) }
        lines.append("Plan on the canvas: " + (context.plan ?? "none"))
        lines.append("Open positions: " + (context.positions.isEmpty ? "none" : context.positions.joined(separator: "; ")))
        if !context.favorites.isEmpty { lines.append("Favorite tokens: " + context.favorites.joined(separator: "; ")) }
        if !context.addressBook.isEmpty { lines.append("Address book names: " + context.addressBook.joined(separator: ", ")) }
        if !context.balances.isEmpty { lines.append("Balances: " + context.balances.joined(separator: "; ")) }
        if !context.off.isEmpty {
            lines.append("Switched off in Settings › Modules: \(context.off). Never offer or build a move that uses them; "
                         + "when asked for one, reply (chat) that it is off in Settings › Modules.")
        }
        lines.append("Reply language: " + context.replyLanguage)
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
        let found = command.matches(of: /0x[0-9a-fA-F]{40}|[0-9a-f]{64}|[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.near|[1-9A-HJ-NP-Za-km-z]{32,44}/).map { String($0.0) }
        let knownSet = Set(known.map { $0.lowercased() })
        return found.allSatisfy { userText.contains($0) || knownSet.contains($0.lowercased()) }
    }
}
