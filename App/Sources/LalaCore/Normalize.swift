import Foundation
import LLMCore

/// The model reads every message first, for its meaning in any language and in the context of the chat, the plan and
/// the portfolio. Like an agent it may look things up first (the portfolio, a market, any token, the rates), then
/// says what the message is: a command (rewritten as one English line in the forms below), a plan change, an answer
/// with its own view, or something to clarify — with a block to open on the canvas and the ways to go on. It never
/// acts: a command goes through the same parsers, checks, Jev and confirmations as a typed one, and an address may
/// only come from the user's message or their own favorites.
public enum ChatRouter {
    public enum Route: Equatable, Sendable {
        case command(String)
        case question
        case plan
        case chat(String)
        case clarify(String)
    }

    /// One read-only lookup the model asked for: «token B5AN…», «portfolio».
    public struct Lookup: Equatable, Sendable {
        public let tool: String
        public let arg: String
        public init(_ tool: String, _ arg: String = "") { self.tool = tool; self.arg = arg }
    }

    /// A way to go on, offered as a card: what it is, the model's comment on it, and the English form it runs.
    public struct Option: Equatable, Sendable {
        public let title: String
        public let comment: String
        public let command: String
        public let recommended: Bool
        public init(title: String, comment: String, command: String, recommended: Bool = false) {
            self.title = title; self.comment = comment; self.command = command; self.recommended = recommended
        }
    }

    /// The model's last word on a message.
    public struct Reading: Equatable, Sendable {
        public var route: Route
        /// A display command opened with the reply: «chart token B5AN… on solana», «chart ETH week».
        public var show: String?
        public var options: [Option] = []
        /// What was looked up on the way, in order.
        public var lookups: [Lookup] = []
        /// Addresses the lookups returned (a token found by its name, an address repaired): display commands may use them.
        public var found: [String] = []
        public init(route: Route, show: String? = nil, options: [Option] = []) { self.route = route; self.show = show; self.options = options }
    }

    enum Step: Equatable { case lookups([Lookup]), done(Reading) }

    /// Lookups per message before the model must answer.
    static let rounds = 3

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
        /// The cards on the canvas from the last answer, «title → command», so «да» or «второй» picks one.
        public var offered: [String] = []
        /// «2026-09-29 10:30, Tuesday»: the local time, so «в пятницу в 9» becomes a date. Gregorian whatever the Mac's calendar.
        public var now: String = {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm, EEEE"
            return f.string(from: Date())
        }()
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
      watch token <CONTRACT or MINT> [on robinhood|base|arbitrum|ethereum|solana] | remove token <SYMBOL> from favorites
    MARKET: chart <ASSET> [week|month] | what's moving | alert me when <ASSET> is above|below <PRICE> | cancel alerts
      chart token <CONTRACT or MINT> on <solana|robinhood|base|arbitrum|ethereum>   (any token's card: price chart, market cap, liquidity, volume, links)
    P/L: profit and loss [today|week|month|all] [for <ASSET>]   (how much they made or lost, on trading and on the whole portfolio)
    APP: new canvas | clear the plan | lock
    LATER OR ON REPEAT (COMMAND is one form above, or several joined by " then "; the time is the user's local time):
      in N <minutes|hours|days|weeks|months>: COMMAND | at HH:MM: COMMAND | tomorrow [at HH:MM]: COMMAND | on YYYY-MM-DD [at HH:MM]: COMMAND
      every <hour|day|week|month|N hours|N days|N weeks|N months> [at HH:MM]: COMMAND | every <monday…sunday> [at HH:MM]: COMMAND | cancel scheduled tasks
      («через неделю переложи депозиты в лучшие ставки» = in 1 week: rebalance USDC; «каждый день в 9 продавай SOL и клади USDC в vault» = every day at 09:00: sell SOL then lend USDC. Recurring BUYS keep their own form above. A step no form can do makes the whole request "clarify": say which step ihatecrypto can't do yet.)
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
    Buying and selling a token by its contract works on Robinhood Chain only; on Solana ihatecrypto buys SOL, BTC, ETH, JUP \
    and JitoSOL and nothing else yet. Any other token can be watched (it becomes a favorite with its price) and charted.

    Work like an agent, not a menu of canned answers: figure out what they are after, look up what you don't know, then \
    answer with the facts, your own view and the ways to go on. Your hands are the lookups and the forms below and nothing \
    else: you can't change the app, write code, open websites or move money yourself. When they want something ihatecrypto \
    can't do, say so plainly and offer the closest thing it can.

    Every reply of yours is ONE JSON object and nothing else.

    To look something up first: {"route": "lookup", "lookups": [{"tool": "...", "arg": "..."}]}, up to 3 at once. The \
    results come back to you (the user doesn't see them) and you reply again. Tools, all read-only:
      portfolio               every balance and place, open positions and orders, the plan, profit and loss, closed trades, \
    alerts, recurring buys, favorites, recent activity
      market <ASSET>          a Hyperliquid market (crypto, oil, gold, stocks): price, 24h move, funding, volatility, and a \
    long and a short by the book with ihatecrypto's risk-rule checks
      token <ADDRESS or NAME> any token by its contract or mint on any chain, or by its name or ticker: price, market cap, \
    liquidity, volume, buyers and sellers, age, holders, safety flags, links. It repairs an address pasted with extra characters. \
    By name it lists the matches and gives the deepest one in full, so look up another only when they mean a different one.
      rates <USDC|SOL>        where the money can earn now: each vault ihatecrypto can use and its yearly rate
      movers                  the Hyperliquid markets that moved most today
    Look things up whenever the answer depends on data you don't have below: a pasted address or a token's name → token; \
    how they're doing, what they hold or did → portfolio; a price or «should I long X» → market, plus portfolio for the size; \
    where to earn → rates. Never say you have no data about something before looking it up.

    When you know enough, the final answer: {"route": "command" | "plan" | "chat" | "clarify", "command": "...", \
    "reply": "...", "show": "...", "options": [...]}
    - "command": they want ihatecrypto to do something it can do. "command" is ONE line in exactly one of these English forms:
    \(forms)
      Pick the form that means exactly what they asked: the same action, the same direction, the same place. Never swap in a \
      different action because it looks close — moving money the wrong way is the worst mistake you can make.
      Resolve references from the chat: «да», «давай», «do it», «ok» after your own suggestion or question is that suggestion \
      (after cards you offered, the recommended one; «второй», «the first one» by their order); «то же для ETH», \
      «а теперь половину», «покажи его чарт» build on the last request.
      Keep numbers, tickers, prices and percentages as meant; never invent an amount: leave it out and ihatecrypto asks for it.
      A token they name by symbol that is among their favorites is written with that favorite's contract. Any other address \
      must be one they wrote (repaired by the token lookup is fine) — never one you remember or made up. «$2», «2 бакса», \
      «два доллара» are 2 USDC; «всё» / «all» means leave the amount out of a withdrawal.
    - "plan": a change to the trade plan the forms can't say, like "take closer", "less risk", "wider stop".
    - "chat": answers, views and explanations — about their money, a token, a market, whether something is a good idea, \
      what ihatecrypto can do, a DeFi term. "reply": 1–4 short sentences in the reply language with the numbers that matter \
      and your own take: what stands out, the risk, what you'd do — like a sharp friend who trades. The details go on the \
      canvas ("show"), so don't recite every number. Every number comes from the lookups or the context; never invent one. \
      The decision is theirs; never promise an outcome.
    - "clarify": ambiguous, or no single form does it. "reply" in the reply language, one or two short sentences: say what is missing, or \
      offer the closest way ihatecrypto can do it as a concrete next step the user can accept with «yes» — e.g. «Hyperliquid → Kamino \
      goes through Solana: withdraw 5 USDC to Solana first, then deposit it into Kamino. Withdraw now?»
    - "show": one command that opens a block on the canvas beside the reply. An answer about one token, one market or \
      the rates always shows its block: chart <ASSET> [week|month] | \
      chart token <ADDRESS> on <chain> (use the address and chain the token lookup returned) | what's moving | where to keep <USDC|SOL>
    - "options" (with "chat" and "clarify"; leave them out for greetings and thanks): 2–4 ways to go on, shown as cards the user \
      can pick: [{"title": "a short label in the reply language", "comment": "one sentence in the reply language: what it gives \
      and the catch, with a number where it helps", "command": "one line in the English forms above", "recommended": true}]. \
      Mark exactly one "recommended": the one you'd pick for them. Only forms ihatecrypto has; amounts that fit their balances; \
      a money move among them still waits for their Confirm. Don't offer what "show" already opens: go one step further \
      (another range, an alert at a level that matters, watching it, a safer alternative, a way to earn instead).
    """

    /// Reads the message, looking things up with `lookup` as the model asks (at most `rounds` times), until its answer.
    public static func route(
        _ text: String, context: Context, client: any LLMClient, model: String,
        lookup: @escaping @Sendable (Lookup) async -> String = { _ in "Lookups aren't available here." }
    ) async throws -> Reading {
        var messages = [LLMMessage(.system, system), LLMMessage(.user, brief(text, context))]
        var asked: [Lookup] = [], found: [String] = []
        for round in 0...rounds {
            let full = try await client.complete(LLMRequest(model: model, messages: messages, wantsJSON: true))
            // A model sometimes writes its lookup and then guesses the answer after it: only the first object counts.
            let reply = firstObject(in: full) ?? full
            guard let json = JSONText.object(in: reply) else { throw LLMError("The model did not reply with JSON: \(reply.prefix(120))") }
            let next: Step
            do { next = try step(json) } catch { throw LLMError("The model's reply doesn't fit (\(error)): \(reply.prefix(300))") }
            switch next {
            case .done(var reading):
                reading.lookups = asked
                reading.found = found
                return reading
            case .lookups(let wanted):
                guard round < rounds else { break }
                // At once, results in the order asked.
                let results = await withTaskGroup(of: (Int, String).self) { group in
                    for (i, l) in wanted.enumerated() { group.addTask { (i, await lookup(l)) } }
                    var out = Array(repeating: "", count: wanted.count)
                    for await (i, r) in group { out[i] = String(r.prefix(4000)) }
                    return out
                }
                asked += wanted
                found += results.flatMap(addresses)
                messages.append(LLMMessage(.assistant, reply))
                messages.append(LLMMessage(.user, zip(wanted, results).map { "Result of \($0.tool) \($0.arg):\n\($1)" }.joined(separator: "\n\n")
                                           + (round == rounds - 1 ? "\n\nNo more lookups: give your final answer now." : "")))
            }
        }
        throw LLMError("The model kept looking things up without answering.")
    }

    static func brief(_ text: String, _ context: Context) -> String {
        var lines: [String] = []
        if !context.recent.isEmpty { lines.append("Recent chat (oldest first):\n" + context.recent.joined(separator: "\n")) }
        if !context.offered.isEmpty { lines.append("Cards you offered after your last reply, in order: " + context.offered.joined(separator: "; ")) }
        lines.append("Plan on the canvas: " + (context.plan ?? "none"))
        lines.append("Open positions: " + (context.positions.isEmpty ? "none" : context.positions.joined(separator: "; ")))
        if !context.favorites.isEmpty { lines.append("Favorite tokens: " + context.favorites.joined(separator: "; ")) }
        if !context.addressBook.isEmpty { lines.append("Address book names: " + context.addressBook.joined(separator: ", ")) }
        if !context.balances.isEmpty { lines.append("Balances: " + context.balances.joined(separator: "; ")) }
        if !context.off.isEmpty {
            lines.append("Switched off in Settings › Modules: \(context.off). Never offer or build a move that uses them; "
                         + "when asked for one, reply (chat) that it is off in Settings › Modules.")
        }
        lines.append("Now (local time): " + context.now)
        lines.append("Reply language: " + context.replyLanguage)
        lines.append("Message: " + text)
        return lines.joined(separator: "\n")
    }

    /// One reply of the model: lookups to make, or its answer with the block to show and the cards to offer.
    static func step(_ json: Data) throws -> Step {
        // Read leniently: a model writes «"recommended": "true"» or a number for an argument as often as not.
        guard let a = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw LLMError("The model's reply is not an object.") }
        func text(_ v: Any?) -> String? { v.map { "\($0)" }.flatMap { $0 == "<null>" ? nil : $0 } }
        let clean = CharacterSet(charactersIn: "`\"'«» \n")
        if a["route"] as? String == "lookup" {
            let wanted = (a["lookups"] as? [[String: Any]] ?? []).prefix(3).compactMap { l in
                text(l["tool"]).map { Lookup($0.lowercased(), text(l["arg"])?.trimmingCharacters(in: .whitespaces) ?? "") }
            }
            guard !wanted.isEmpty else { throw LLMError("The model asked to look something up but named nothing.") }
            return .lookups(wanted)
        }
        let options = (a["options"] as? [[String: Any]] ?? []).prefix(4).compactMap { c -> Option? in
            guard let title = text(c["title"])?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let command = text(c["command"])?.trimmingCharacters(in: clean), !command.isEmpty, command.count <= 200 else { return nil }
            return Option(title: title, comment: text(c["comment"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", command: command,
                          recommended: c["recommended"] as? Bool ?? (text(c["recommended"]) == "true"))
        }
        var show = text(a["show"])?.trimmingCharacters(in: clean)
        // The details belong on the canvas: a chart the model offered as a card opens with the answer instead.
        if show?.isEmpty != false { show = options.first { $0.command.lowercased().hasPrefix("chart") }?.command }
        return .done(Reading(route: try decode(json), show: show, options: options.filter { $0.command != show }))
    }

    /// The first complete {…} in a text, braces inside strings skipped.
    static func firstObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        for i in text[start...].indices {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true } else if c == "{" { depth += 1 } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...i]) }
            }
        }
        return nil
    }

    /// Contracts, mints and NEAR accounts in a text.
    static func addresses(_ text: String) -> [String] {
        text.matches(of: /0x[0-9a-fA-F]{40}|[0-9a-f]{64}|[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.near|[1-9A-HJ-NP-Za-km-z]{32,44}/).map { String($0.0) }
    }

    /// Whether ihatecrypto has a parser for this English line: the check every command and card of the model passes.
    public static func parses(_ c: String, markets: Set<String>) -> Bool {
        ["new canvas", "clear the plan", "lock"].contains(c.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".! ")))
            || WalletCommand.parse(c) != nil || TokenCommand.parse(c) != nil || PositionCommand.parse(c) != nil
            || ChartCommand.parse(c, markets: markets) != nil || AlertCommand.parse(c, markets: markets) != nil || AddressBookCommand.parse(c) != nil
            || PnLCommand.parse(c, markets: markets) != nil || ScheduledTask.parse(c) != nil || ScheduledTask.cancelsAll(c)
            || TakeStyle.asksForChoice(c) || IntentParser.apply(c, to: TradeIntent(), markets: markets) != nil
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
        let found = addresses(command)
        let knownSet = Set(known.map { $0.lowercased() })
        return found.allSatisfy { userText.contains($0) || knownSet.contains($0.lowercased()) }
    }
}
