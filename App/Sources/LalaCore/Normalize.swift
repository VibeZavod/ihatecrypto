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
        /// A second reader still disagrees with the command after the model tried again: why. The app asks the user.
        public var doubt: String?
        /// What the second reader said about the first command, when it disagreed and the model tried again.
        public var corrected: String?
        public init(route: Route, show: String? = nil, options: [Option] = []) { self.route = route; self.show = show; self.options = options }
    }

    enum Step: Equatable { case lookups([Lookup]), done(Reading) }

    /// Lookups per message before the model must answer.
    static let rounds = 3

    /// What the model may know besides the message: never keys, never full balances history.
    public struct Context: Sendable {
        public var recent: [String] = []
        public var plan: String?
        /// The other blocks on the canvas in the router's forms: «chart ETH», «waiting for Confirm: …», «price alert: …».
        public var canvas: [String] = []
        public var positions: [String] = []
        /// «AI (Artificial Inu) = 0x… on Robinhood Chain»
        public var favorites: [String] = []
        public var addressBook: [String] = []
        public var balances: [String] = []
        /// «$29.85»: the capital the risk rules measure, so «риск 2% от депо» becomes dollars.
        public var capital: String?
        /// «Russian» or «English»: the language chat and clarify replies are written in (ChatLanguage).
        public var replyLanguage = "English"
        /// Networks, kinds and protocols switched off in Settings › Modules (`Modules.offSummary`); empty when none.
        public var off = ""
        /// Safe search on: Solana buys only the fixed verified coins. Off: any token by its mint.
        public var safeSearch = true
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
      long|short <ASSET> [N USDC] [risk $N] [stop N%] [take N% | take NR] [leverage Nx] [by the book] [on a N% pullback] [limit <PRICE>] [take in parts] [trailing N%]
      with a plan already on the canvas, a change alone: N USDC | risk $N | stop N% | take N% | take NR | leverage Nx | limit <PRICE> | at market | by the book
        | take in parts («фиксируй частями») | trailing N% | on a N% pullback
      N USDC is the money put into the trade (its margin; the size follows from it and the stop): «на 5 баксов», «увеличь до 5 USDC»,
      «сумма 10», «зайди на 20$». risk $N is only what is lost at the stop: «риск 1$», «рискну долларом», «потерять не больше 2».
      «by the book» fills whatever they didn't give — risk, stop, take and leverage (the rules' cap) — so «max leverage by the
      rules» is just by the book. Several changes to the plan go in ONE line («6 USDC leverage 4x»), never as steps. One trade
      plan at a time: two trades in one message («лонг эфира и шорт битка») is "clarify", offering the first.
      Risk as a share of capital: 1% is by the book; another share is risk $N of the capital in the context («риск 2% от депо»
      with $30 = risk $0.6). A limit N% away from the price is «on a N% pullback» (below it for a long, above for a short).
      take profit options   (how pros take profit)
    OPEN POSITION (add the asset when there are several, e.g. "close ETH"):
      move stop to breakeven | stop at <PRICE> | take at <PRICE> | trail N% | close | close half | close N% | cancel orders
    SPOT ON SOLANA (Jupiter): buy <SOL|BTC|ETH|JUP|JitoSOL> for N USDC | sell [N] <SOL|BTC|ETH|JUP>
      any other Jupiter-verified token by its ticker: buy <TICKER> on solana for N USDC | sell [N] <TICKER> on solana   (BONK, WIF, USDT, JTO, PYTH, POPCAT, RENDER…)
      buy <SOL|BTC|ETH|JUP> for N USDC every <day|week|N days> | stop recurring buys
      buy NEAR for N USDC | sell [N] NEAR   (native NEAR on the NEAR account → USDC on Solana; no N = all of it)
    STOCK TOKENS ON ROBINHOOD CHAIN: buy <COMPANY or TICKER> stock for N USDC | sell <TICKER> stock | move USDG from Robinhood to Solana
    ANY TOKEN BY ITS CONTRACT (Robinhood Chain): buy token <0xCONTRACT> for N USDC | sell [N] tokens <0xCONTRACT>
    TOKENS ON BASE AND ARBITRUM (Relay's swap or Relay's bridge + Uniswap, whichever leaves more; a sale comes back as USDC on Solana):
      buy <TICKER> on <base|arbitrum|polygon|ethereum> for N USDC | sell [N] <TICKER> on <base|arbitrum|polygon|ethereum>   (tickers from Uniswap's list: AERO, DEGEN, VIRTUAL, cbBTC, WETH on Base; ARB, GMX, PENDLE, LINK, UNI on Arbitrum; AAVE, LINK, WPOL on Polygon; UNI, PEPE, LDO on Ethereum, where gas costs dollars)
      buy token <0xCONTRACT> on <base|arbitrum|polygon|ethereum> for N USDC | sell [N] tokens <0xCONTRACT> on <base|arbitrum|polygon|ethereum>
    ANY SOLANA TOKEN BY ITS MINT (Jupiter; only while Safe search is off): buy token <MINT> for N USDC | sell [N] tokens <MINT>
    EARNING: lend [N] <USDC|SOL|USDT> (Jupiter Lend, "the vault") | withdraw [N] <USDC|SOL> from the vault
      deposit N <USDC|SOL> to kamino | withdraw <USDC|SOL> from kamino | stake N SOL | unstake N JitoSOL
      deposit N USDC to HLP | withdraw from HLP | lend N USDC on Aave [on <Base|Arbitrum|Polygon|Ethereum>] | withdraw USDC from Aave [on <network>]
      deposit N USDC into Morpho [on <Base|Arbitrum|Ethereum>] | withdraw USDC from Morpho [on <network>]   (no network = Base; name it only when the user does)
      where to keep <USDC|SOL> | spread [N] <USDC|SOL> across the best rates [max N% per protocol]   (N = at most that much; none = all that is free:
        USDC idle on Solana AND on Base, Arbitrum, Polygon, Ethereum, Robinhood and Tempo — each slice takes the money where it is, so never put a
        move before a spread: «разложи 1000 USDC с Base» = spread 1000 USDC across the best rates)
      claim rewards   (what Merkl owes the wallet: Morpho's, Aave's and other protocols' rewards on Base, Arbitrum, Ethereum and Polygon)
      sweep rewards [over $N] [into <USDC|TICKER>]   (claim AND sell them for USDC on Solana, only once worth $N (≥ $5); «every hour: sweep rewards over $10 into USDC» = «продавай награды раз в час, когда наберётся $10»)
      rebalance USDC [max N% per protocol]   (moves money ALREADY in vaults to better rates: «переложи», «перекинь депозиты», «перебалансируй», «rebalance». «spread» / «разложи» / «распредели» is only for FREE USDC, on any network)
    MOVING MONEY: withdraw N USDC to Solana (from Hyperliquid) | move N USDC from <Base|Arbitrum|Polygon|Ethereum|Tempo> to Solana
      move N USDC from Solana to <Base|Arbitrum|Polygon|Ethereum|Robinhood|Tempo>   (arrives as USDG on Robinhood Chain)
      move N USDC from <Base|Arbitrum|Polygon|Ethereum|Robinhood|Tempo> to <another of them|Hyperliquid>   (straight over Relay, no Solana in between; no N = all of it)
      add gas on <Base|Arbitrum|Polygon|Ethereum|Robinhood> [for N USDC]   (that network's own coin for fees, over Relay; no N = $1. Gas is never a dead end:
      a move short of it tops it up by itself, so «not enough ETH» is fixed with this form, never refused)
      send N USDC to <NAME from the address book> [on <network the user names — any, Ethereum mainnet too; they decide about the fee>] | top up (where to send money into ihatecrypto)
      send N NEAR to <NAME from the address book> | send all NEAR to <NAME> | close the NEAR account into <NAME>
      send N SOL to <NAME from the address book>
    PAYING FOR A SERVICE (MPP on Tempo, the x402 way: an API that charges per request — search, data, email, phone calls, mailed letters,
      flights, token research…): pay <GET|POST> <URL> [<JSON body>]   (the URL and body exactly as the services lookup and the service's docs give them;
      the price comes from the service and shows on a card; paid in USDC on Tempo, bridged from Solana when short, only after Confirm)
      Don't pick a service silently when more than one fits, or when they ask what it costs or what the options are: answer "chat" with the
      prices and offer each fitting service as a card — its pay command, the comment saying its price and what it gives and misses — the best
      one "recommended". Go straight to the pay command only when they named the service or one clearly fits. Posts on X (Twitter): Grok's
      x-search reads X itself (priced by use, up to ≈ $0.18); a web search with site:x.com sees only the pages a search engine indexed.
    ADDRESSES AND WATCHLIST: save <ADDRESS> as <NAME> [on solana|base|arbitrum|ethereum|tempo|hyperliquid|near] | add <NAME> to favorites | remove <NAME> from favorites   (NAME from the address book, not a ticker)
      watch token <CONTRACT or MINT> [on robinhood|base|arbitrum|ethereum|solana] | remove token <SYMBOL> from favorites
    MARKET: chart <ASSET> [week|month] | what's moving | alert me when <ASSET> is above|below|at <PRICE> | cancel alerts
      (at: no side said, «алерт на 2600» — ihatecrypto picks it from the price)
      chart token <CONTRACT or MINT> on <solana|robinhood|base|arbitrum|ethereum>   (any token's card: price chart, market cap, liquidity, volume, links)
    P/L: profit and loss [today|week|month|all] [for <ASSET>]   (how much they made or lost, on trading and on the whole portfolio)
    APP: new canvas | clear the plan | lock | create an automation wallet   (a wallet without Touch ID that scheduled tasks spend from by
      themselves: «создай кошелёк автоматизации», «чтобы расписание работало без пальца»)
    FOLDERS: save this canvas to folder <NAME> | write to folder <NAME>: <TEXT>   (a folder in the sidebar; a new name makes it;
      «сохрани в папку Ресерч», «запиши в папку Идеи: …» — the text kept whole as a note there)
    NOW, IN STEPS (what no single form does, built from the forms above, up to 5): COMMAND then COMMAND [then COMMAND…]
      («выведи 5 с хайпера и положи в камино» = withdraw 5 USDC to Solana then deposit 5 USDC to kamino). The user confirms the chain once, at its first
      money move, and each step after it runs by itself once the one before went through. Moving money between places costs a
      bridge fee (often about $1), so a step that spends what an earlier one brought uses a little less (withdraw 5 → deposit 4); a step no form can do makes the whole request "clarify".
    LATER OR ON REPEAT (COMMAND is one form above, or several joined by " then "; the time is the user's local time):
      in N <minutes|hours|days|weeks|months>: COMMAND | at HH:MM: COMMAND | tomorrow [at HH:MM]: COMMAND | on YYYY-MM-DD [at HH:MM]: COMMAND
      every <hour|day|week|month|N hours|N days|N weeks|N months> [at HH:MM]: COMMAND | every <monday…sunday> [at HH:MM]: COMMAND | cancel scheduled tasks
      every month on the <1st…28th> [at HH:MM]: COMMAND   («каждое 1-е число переводи маме 20 USDC» = every month on the 1st: send 20 USDC to Mom)
      when <ASSET> is above|below|at <PRICE>: COMMAND   (once, when the price gets there: a price alert that then prepares COMMAND; a trade plan or a money move waits for their Confirm, with a notification. «поставь алерт на 2680 и пришли лонг ×3 на аппрув» = when ETH is below 2680: long ETH leverage 3x. Build it from the blocks on the canvas when they point at them («на этот план», «вот это»): the plan written in the long|short form from its fields, or the move waiting for Confirm)
      («через неделю переложи депозиты в лучшие ставки» = in 1 week: rebalance USDC; «каждый день в 9 продавай SOL и клади USDC в vault» = every day at 09:00: sell SOL then lend USDC. Recurring BUYS keep their own form above. A step no form can do makes the whole request "clarify": say which step ihatecrypto can't do yet.)
    """

    /// Where money lives and how it moves: the chat's brief and the second reading's, so neither takes «deposit into
    /// Morpho on Base» for a deposit that skips the bridge.
    static let places = """
    Where their money lives, all at their own addresses: the Solana wallet (USDC and SOL, the hub); Hyperliquid (perp margin \
    and the HLP vault); Jupiter Lend and Kamino on Solana; Aave on Base, Arbitrum, Polygon and Ethereum; Morpho on Base, \
    Arbitrum and Ethereum; idle USDC on those networks; Robinhood Chain (USDG, stock tokens, tokens by contract); NEAR; \
    Tempo (USDC for transfers and for paying services per request, MPP; fees come out of the USDC, no gas coin). \
    Ethereum's gas costs dollars: only large amounts are worth it there, and «spread»/«rebalance» weigh that by themselves.
    How money moves: Solana ⇄ Base, Arbitrum, Polygon, Ethereum, Robinhood Chain and Tempo over Relay, and between any two of those EVM \
    networks straight over Relay too (Base → Robinhood Chain: one move, no stop on Solana), and from any of them straight to \
    Hyperliquid; Hyperliquid → Solana; a trade plan brings its USDC to Hyperliquid by itself — from Solana, or straight from an \
    EVM network that has it when Solana is short, gas there included — so never put a move before a trade; NEAR ⇄ Solana USDC through NEAR Intents (buy NEAR / sell NEAR); every vault is entered and left \
    in ONE command. Aave and Morpho take the USDC already idle on their own network first, then Solana's, and when both are short \
    ihatecrypto brings it straight from the EVM network that holds it, in the same Confirm — so «положи 300 в aave на арбитруме» is \
    just lend 300 USDC on Aave on Arbitrum wherever the money is (its card then shows two steps: the move, then the deposit; that \
    is this one command, not something to offer again). That is for a deposit on its own; inside steps (« then ») a deposit \
    finds only what the steps before it brought, so write its straight move before it when its network and Solana lack the money: \
    «1000 в морфо на эфире, 500 в aave на базе» with the USDC on Ethereum = deposit 1000 USDC into Morpho on Ethereum then move 501 \
    USDC from Ethereum to Base then lend 500 USDC on Aave on Base. When the user names the move themselves, it is a straight move \
    first: «переведи 200 с эфира на базу и положи в морфо там» = move 200 USDC from Ethereum to Base then deposit 199 USDC into \
    Morpho on Base — never through Solana. Leaving goes back to \
    Solana by itself: «withdraw USDC from Aave on Arbitrum» withdraws there and bridges to Solana, so never split it into two steps. Selling stock tokens or tokens by contract leaves USDG on Robinhood Chain; «move USDG from Robinhood \
    to Solana» brings it back. \
    Hyperliquid → the EVM networks, and NEAR ⇄ them, go through Solana: build that as steps (NOW, IN STEPS).
    Buying and selling a token by its contract works on Robinhood Chain, Base and Arbitrum. On Solana ihatecrypto buys \
    SOL, BTC, ETH, JUP and JitoSOL, and any Jupiter-verified token by its ticker (BONK, WIF, USDT…) — Safe search on or off; \
    any other Solana token by its mint only while Safe search is off (the context says which). On Base and Arbitrum it \
    buys the tokens on Uniswap's list by ticker and any other by contract, comparing Relay's swap with Relay + Uniswap. \
    Any token can be watched (it becomes a favorite with its price) and charted.
    """

    static let system = """
    You are ihatecrypto's mind: the user's own crypto wallet and trading agent. Understand what they want the way a sharp human \
    assistant would — from the whole conversation, not from keywords. They write in any language, casually, with typos \
    («робингуд»/«робинхуд» = Robinhood Chain, «хайпер» = Hyperliquid, «солана»/«сол» = the Solana wallet, «бакс» = a dollar).

    \(places)

    Work like an agent, not a menu of canned answers: figure out what they are after, look up what you don't know, then \
    answer with the facts, your own view and the ways to go on. Your hands are the lookups and the forms below and nothing \
    else: you can't change the app, write code, open websites or move money yourself. When they want something ihatecrypto \
    can't do, say so plainly and offer the closest thing it can.
    A clear instruction that a form does is that "command" at once: no lookups, no second-guessing the balance — ihatecrypto \
    checks the money, the rules and the route itself and shows any shortfall with its fix on the canvas. A question one form \
    answers with its own board is that command too: profit and loss («какой у меня P/L», «сколько я заработал на нефти»), \
    a chart, what's moving, where to keep USDC. Everything else — questions, advice, a token, whether it's a good idea — \
    you look up and answer yourself.

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
      services <WORDS>        paid APIs that take MPP payments on Tempo (mpp.dev's directory): what each does, its endpoints and prices
      service <ID> [<PATH>]   one of them in full: every endpoint, its price, and the docs of that endpoint with the request's fields
    Look things up whenever the answer depends on data you don't have below: a pasted address or a token's name → token; \
    how they're doing, what they hold or did → portfolio; a price or «should I long X» → market, plus portfolio for the size; \
    where to earn → rates; paying for something, a service or an API («оплати», «купи звонок», «отправь письмо почтой», «сколько \
    стоит найти…») → services, then service for the fields and the price. \
    Token research goes deeper through paid services on Tempo when the free token lookup isn't enough or they ask for more (price \
    history, onchain trades and holders, wallet balances and PnL, the news, what people say on X): Codex (onchain token data by \
    GraphQL, $0.001 a query), Allium (prices, history, balances, PnL, $0.02), CoinGecko (market data, $0.06), Perplexity or Brave \
    (web and news, $0.006 / $0.035), Grok x-search (posts on X). Look them up with services, then offer them as cards with their \
    prices; nothing is paid without their Confirm. Never say you have no data about something before looking it up.

    When you know enough, the final answer: {"route": "command" | "plan" | "chat" | "clarify", "command": "...", \
    "reply": "...", "show": "...", "options": [...]}
    - "command": they want ihatecrypto to do something it can do. "command" is ONE line in exactly one of these English forms:
    \(forms)
      Pick the form that means exactly what they asked: the same action, the same direction, the same place. Never swap in a \
      different action because it looks close — moving money the wrong way is the worst mistake you can make.
      Resolve references from the chat: «да», «давай», «do it», «ok» after your own suggestion or question is that suggestion \
      (after cards you offered, the recommended one; «второй», «the first one» by their order); «то же для ETH», \
      «а теперь половину», «покажи его чарт» build on the last request.
      A card «waiting for Confirm» on the canvas is what «это», «маршрут», «план» mean. A question about it — is it the best \
      route, what it costs, why this vault and not another — is "chat" answered from its numbers (look up what it lacks, e.g. \
      rates), and the card keeps waiting; don't send its command again. A change to it is its command again with the change \
      applied to the WHOLE of it: «добавь ещё 300» to a waiting «spread 500 USDC» = spread 800 USDC across the best rates; \
      «не больше 40% в один» = the same spread with max 40% per protocol; «лучше 150» to «move 100 USDC …» = move 150 USDC ….
      Keep numbers, tickers, prices and percentages as meant; never invent an amount: leave it out and ihatecrypto asks for it.
      A token they name by symbol that is among their favorites is written with that favorite's contract. Any other address \
      must be one they wrote (repaired by the token lookup is fine) — never one you remember or made up. «$2», «2 бакса», \
      «два доллара» are 2 USDC; «всё» / «all» means leave the amount out of a withdrawal, and from a place holding \
      several assets (Kamino, Jupiter Lend: USDC and SOL) it is each of them, as steps — ask only when a lookup shows nothing there.
    - "plan": a change to the trade plan the forms can't say, like "take closer", "less risk", "wider stop".
    - "chat": answers, views and explanations — about their money, a token, a market, whether something is a good idea, \
      what ihatecrypto can do, a DeFi term. "reply": 1–4 short sentences in the reply language with the numbers that matter \
      and your own take: what stands out, the risk, what you'd do — like a sharp friend who trades. The details go on the \
      canvas ("show"), so don't recite every number. Every number comes from the lookups or the context; never invent one. \
      The decision is theirs; never promise an outcome.
    - "clarify": ambiguous, or no single form does it. "reply" in the reply language, one or two short sentences: say what is missing, or \
      offer the closest way ihatecrypto can do it as a concrete next step the user can accept with «yes» — e.g. «ihatecrypto can't \
      stake ETH; it can lend USDC or stake SOL. Stake 0.1 SOL?»
    - "show": one command that opens a block on the canvas beside the reply. An answer about one token, one market or \
      the rates always shows its block: chart <ASSET> [week|month] | \
      chart token <ADDRESS> on <chain> (use the address and chain the token lookup returned) | what's moving | where to keep <USDC|SOL>. \
      A general question (a term, how something works) shows nothing.
    - "options" (with "chat" and "clarify"; leave them out for greetings and thanks): 2–4 ways to go on, shown as cards the user \
      can pick: [{"title": "a short label in the reply language", "comment": "one sentence in the reply language: what it gives \
      and the catch, with a number where it helps", "command": "one line in the English forms above", "recommended": true}]. \
      Mark exactly one "recommended": the one you'd pick for them. Only forms ihatecrypto has; amounts that fit their balances; \
      a money move among them still waits for their Confirm. Every card does something: «leave it as it is» is not a card, nor one that repeats what the plan already has, \
      and the app's own commands (new canvas, clear the plan, lock) never are. Don't offer what "show" already opens: go one step further \
      (another range, an alert at a level that matters, watching it, a safer alternative, a way to earn instead).
    """

    /// Reads the message, looking things up with `lookup` as the model asks (at most `rounds` times), until its answer.
    /// With `markets`, a command no parser reads goes back to the model with what's wrong, so it answers with forms that
    /// do it or says plainly what ihatecrypto can't do: it never ends at «can't do that yet».
    /// `check` is a second reader (Jev, or a model asked to verify): given the command, nil when it does what the message
    /// asks, else why not. A disagreement goes back to the model once; a second one is left to the user (`doubt`).
    public static func route(
        _ text: String, context: Context, client: any LLMClient, model: String, markets: Set<String>? = nil,
        lookup: @escaping @Sendable (Lookup) async -> String = { _ in "Lookups aren't available here." },
        check: (@Sendable (String) async -> String?)? = nil,
        draft: (@Sendable (String) -> Void)? = nil
    ) async throws -> Reading {
        var asked: [Lookup] = [], found: [String] = [], corrected: String?
        var brief = brief(text, context)
        // A pasted contract or mint is looked up before the model reads the message: one round less.
        if let address = pastedAddress(text) {
            let first = Lookup("token", address)
            let result = String(await lookup(first).prefix(4000))
            asked.append(first)
            found += addresses(result)
            brief += "\n\nAlready looked up for you — token \(address):\n\(result)"
        }
        var messages = [LLMMessage(.system, system), LLMMessage(.user, brief)]
        for round in 0...rounds {
            // An answer's words show while the model still writes them (a chat or clarify reply; never a command's).
            let full = try await client.stream(LLMRequest(model: model, messages: messages, wantsJSON: true)) { text in
                if let draft, let words = partialReply(text) { draft(words) }
            }
            // A model sometimes writes its lookup and then guesses the answer after it: only the first object counts.
            let reply = firstObject(in: full) ?? full
            // A reply that isn't the JSON asked for goes back once more, saying what's wrong, before the chat gives up on it.
            let next: Step
            do {
                guard let json = JSONText.object(in: reply) else { throw LLMError("it isn't a JSON object") }
                next = try step(json)
            } catch {
                guard round < rounds else { throw Unreadable(reply: String(reply.prefix(300))) }
                messages.append(LLMMessage(.assistant, reply))
                messages.append(LLMMessage(.user, "That reply doesn't fit the format (\(error.localizedDescription)). Answer again with ONE "
                                           + "JSON object exactly as described; several steps go in one «command» joined by « then »."))
                continue
            }
            switch next {
            case .done(var reading):
                if let markets, round < rounds, case .command(let c) = reading.route, let bad = unparsed(c, markets: markets) {
                    messages.append(LLMMessage(.assistant, reply))
                    messages.append(LLMMessage(.user, "«\(bad)» can't run: no form reads it, or it names a market Hyperliquid doesn't have. Answer again, as one JSON object: "
                                               + "the forms that do it (steps joined by « then »), or \"clarify\" saying plainly which part ihatecrypto "
                                               + "can't do, with the closest ways it can as options."))
                    continue
                }
                if let check, case .command(let c) = reading.route, let why = await check(c) {
                    if corrected == nil, round < rounds {
                        corrected = why
                        messages.append(LLMMessage(.assistant, reply))
                        messages.append(LLMMessage(.user, "A second reader checked «\(c)» against the message and disagrees: \(why) "
                                                   + "Read the message again and answer, as one JSON object: the command that does exactly what they "
                                                   + "asked, or \"clarify\" if it really can be read two ways."))
                        continue
                    }
                    reading.doubt = why
                }
                reading.corrected = corrected
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

    /// After a command built or changed the trade plan: the model reads ihatecrypto's own check of it and answers like an
    /// agent — what it built, what matters most, and the changes worth making as cards. Every number is the check's.
    public static func comment(on check: String, command: String, _ text: String, context: Context, client: any LLMClient, model: String) async throws -> Reading {
        let ask = brief(text, context) + """


        You read the message as «\(command)», and ihatecrypto built it. Its own check of the plan now on the canvas \
        (every number in it is ihatecrypto's; lines start with ✓ met, ✗ missing or blocked, ⚠ warning, · note):
        \(check)

        Answer now, as {"route": "chat", "reply": "...", "options": [...]}. "reply": 1–3 short sentences in the reply \
        language, like a sharp friend who trades: what you built in plain words (the market, the side, what the rules \
        filled in), then the one thing in the check that matters most — a ✗ or ⚠ line first, else the loss at the stop \
        against the profit at the take — and what you'd do about it. Quote numbers only from the check, and don't repeat it \
        line by line: it is shown under your reply. "options": 2–3 changes to this plan in the TRADE PLAN forms (risk $N, \
        stop N%, take NR, leverage Nx, on a N% pullback, take in parts…) that answer what you pointed out, one \
        recommended; when the money is short, a smaller N USDC that fits. The plan's own Execute button signs it, so never offer that.
        """
        let full = try await client.complete(LLMRequest(model: model, messages: [LLMMessage(.system, system), LLMMessage(.user, ask)], wantsJSON: true))
        let reply = firstObject(in: full) ?? full
        guard let json = JSONText.object(in: reply), case .done(let reading) = try step(json), case .chat = reading.route else {
            throw LLMError("The model didn't comment on the plan: \(reply.prefix(120))")
        }
        return reading
    }

    /// A second reading by a model: does the command do what the message asks? nil when it does, else why not (in the
    /// reply language). For when Jev isn't connected; the same model reading again, with the forms spelled out, still
    /// catches a number put in the wrong role («увеличь до 5 USDC» written as risk $5).
    public static func verify(_ text: String, command: String, context: Context, client: any LLMClient, model: String) async throws -> String? {
        let ask = brief(text, context) + """


        Another assistant read the message and wrote this command, in the app's English forms: «\(command)»
        What ihatecrypto does and how money moves:
        \(places)
        The forms and what they mean:
        \(forms)
        Check it like a careful second reader: the same action, direction, place and asset as asked; each number the user \
        gave kept, in the same role (money put into a trade «N USDC» vs the loss at the stop «risk $N»; percent vs dollars; \
        a price vs a percent); nothing they didn't ask for. Read a typo as the word it most likely is in a wallet \
        («подай 0,01 сол» is «продай», «выеди» is «выведи») and flag only a real difference in meaning. A follow-up («да», «второй», «то же для ETH») is read against the \
        recent chat. Numbers they didn't give may be missing: the app fills them by its rules or asks. A bridge fee taken off \
        a later step's amount is fine.
        Reply with ONE JSON object: {"matches": true} or {"matches": false, "why": "one short sentence in the reply language: \
        what the user asked and what the command does instead"}.
        """
        let full = try await client.complete(LLMRequest(model: model, messages: [LLMMessage(.user, ask)], wantsJSON: true))
        guard let json = JSONText.object(in: firstObject(in: full) ?? full),
              let a = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw LLMError("The checker did not reply with JSON.") }
        let matches = a["matches"] as? Bool ?? (a["matches"].map { "\($0)" } == "true")
        return matches ? nil : ((a["why"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "it does something else")
    }

    /// The plan against the user's own words, by a model: nil when it matches, else what differs (in `language`).
    public static func verifyPlan(requests: [String], plan: [String], language: String, client: any LLMClient, model: String) async throws -> String? {
        let ask = """
        A trader typed these messages to a crypto app, oldest first; later ones edit earlier ones:
        \(requests.suffix(8).map { "- " + $0.prefix(400) }.joined(separator: "\n"))
        The app built this trade plan from them, with live prices («by the book» values come from its risk rules):
        \(plan.joined(separator: "\n"))
        Does the plan do what the latest intent of the messages asks: the same market, side, and each number the trader gave \
        in the same role (money put into the trade vs the loss at the stop, percent vs dollars, leverage)? Values the trader \
        left to the rules are fine. Reply with ONE JSON object: {"matches": true} or {"matches": false, "why": "one short \
        sentence in \(language): what they asked and what the plan does instead"}.
        """
        let full = try await client.complete(LLMRequest(model: model, messages: [LLMMessage(.user, ask)], wantsJSON: true))
        guard let json = JSONText.object(in: firstObject(in: full) ?? full),
              let a = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw LLMError("The checker did not reply with JSON.") }
        let matches = a["matches"] as? Bool ?? (a["matches"].map { "\($0)" } == "true")
        return matches ? nil : ((a["why"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "the plan differs from the request")
    }

    static func brief(_ text: String, _ context: Context) -> String {
        var lines: [String] = []
        if !context.recent.isEmpty { lines.append("Recent chat (oldest first):\n" + context.recent.joined(separator: "\n")) }
        if !context.offered.isEmpty { lines.append("Cards you offered after your last reply, in order: " + context.offered.joined(separator: "; ")) }
        lines.append("Plan on the canvas: " + (context.plan ?? "none"))
        if !context.canvas.isEmpty { lines.append("Other blocks on the canvas: " + context.canvas.joined(separator: "; ")) }
        lines.append("Open positions: " + (context.positions.isEmpty ? "none" : context.positions.joined(separator: "; ")))
        if !context.favorites.isEmpty { lines.append("Favorite tokens: " + context.favorites.joined(separator: "; ")) }
        if !context.addressBook.isEmpty {
            lines.append("Address book, each name with the network it's saved on (a send goes there unless the user names another network: then \"send N USDC to NAME on <network>\" at once, any EVM network, Ethereum mainnet too — the fee is the user's call, the card warns; write only the name): "
                         + context.addressBook.joined(separator: ", "))
        }
        if !context.balances.isEmpty { lines.append("Balances: " + context.balances.joined(separator: "; ")) }
        if let capital = context.capital { lines.append("Capital the risk rules measure: " + capital) }
        if !context.off.isEmpty {
            lines.append("Switched off in Settings › Modules: \(context.off). Never offer or build a move that uses them; "
                         + "when asked for one, reply (chat) that it is off in Settings › Modules.")
        }
        lines.append(context.safeSearch
            ? "Safe search: ON — on Solana only Jupiter-verified tokens can be bought (by ticker: buy <TICKER> on solana). An unverified token by its mint needs Safe search off in Settings › General; offer to watch it instead."
            : "Safe search: OFF — any Solana token can be bought by its mint. Before offering it, look it up and say plainly what is risky about it.")
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
        let options = (a["options"] as? [[String: Any]] ?? []).compactMap { c -> Option? in
            guard let title = text(c["title"])?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let command = text(c["command"])?.trimmingCharacters(in: clean), !command.isEmpty, command.count <= maxCommand(command),
                  // A card that opens a new canvas or clears the plan stands in for «do nothing».
                  !["new canvas", "clear the plan", "lock"].contains(command.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".! "))) else { return nil }
            return Option(title: title, comment: text(c["comment"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", command: command,
                          recommended: c["recommended"] as? Bool ?? (text(c["recommended"]) == "true"))
        }.prefix(4)
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

    /// A contract or mint the user pasted, as pasted (a broken one too: the lookup repairs it).
    static func pastedAddress(_ text: String) -> String? {
        if let evm = text.firstMatch(of: /0x[0-9a-fA-F]{40}/) { return String(evm.0) }
        // Whole runs of base58, so a 46-character paste isn't cut to 44.
        return text.matches(of: /[1-9A-HJ-NP-Za-km-z]+/).map { String($0.0) }.first { a in
            (32...60).contains(a.count) && a.contains(where: \.isNumber) && a.contains(where: \.isUppercase) && a.contains(where: \.isLowercase)
        }
    }

    /// Contracts, mints and NEAR accounts in a text.
    static func addresses(_ text: String) -> [String] {
        text.matches(of: /0x[0-9a-fA-F]{40}|[0-9a-f]{64}|[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.near|[1-9A-HJ-NP-Za-km-z]{32,44}/).map { String($0.0) }
    }

    /// The model's answer, twice not in the format asked for: nothing is run.
    public struct Unreadable: LocalizedError {
        public let reply: String
        public var errorDescription: String? { "The model's answer didn't fit the format: \(reply)" }
    }

    /// «withdraw 5 USDC to Solana then deposit 5 USDC to kamino»: the steps of a command run now, in order. nil for one
    /// command, and for a scheduled task's or a price alert's steps (they follow their «…:»).
    public static func steps(_ command: String) -> [String]? {
        guard !command.contains(":") else { return nil }
        let steps = command.split(separator: /(?i)\s+then\s+/).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return steps.count > 1 ? steps : nil
    }

    /// A chain whose steps only change the trade plan is one change: «6 USDC then leverage 4x» → «6 USDC leverage 4x».
    public static func planChange(_ c: String, markets: Set<String>) -> String? {
        guard let steps = steps(c), steps.allSatisfy({ onlyPlan($0, markets: markets) }),
              steps.filter({ IntentParser.startsPlan($0, markets: markets) }).count <= 1 else { return nil }
        return steps.joined(separator: " ")
    }

    /// A line only the trade plan's parser reads.
    static func onlyPlan(_ s: String, markets: Set<String>) -> Bool {
        WalletCommand.parse(s) == nil && TokenCommand.parse(s) == nil && ChartCommand.parse(s, markets: markets) == nil
            && AlertCommand.parse(s, markets: markets) == nil && PnLCommand.parse(s, markets: markets) == nil && ScheduledTask.parse(s) == nil
            && AddressBookCommand.parse(s) == nil && IntentParser.apply(s, to: TradeIntent(), markets: markets) != nil
    }

    /// The command, or its first step, that no parser reads. nil when every one does.
    static func unparsed(_ c: String, markets: Set<String>) -> String? {
        (steps(c) ?? [c]).first { !parses($0, markets: markets) }
    }

    /// Whether ihatecrypto has a parser for this English line (each step of a chain): the check every command and card
    /// of the model passes.
    public static func parses(_ c: String, markets: Set<String>) -> Bool {
        // The canvas holds one trade plan: a chain that starts two would replace the first with the second.
        if let steps = steps(c) {
            return steps.filter { onlyPlan($0, markets: markets) && IntentParser.startsPlan($0, markets: markets) }.count <= 1
                && steps.allSatisfy { parses($0, markets: markets) }
        }
        // «long PEPE» where Hyperliquid has no such market would keep the plan's old one: it doesn't parse.
        if !markets.isEmpty, let m = c.firstMatch(of: /^(?i)(?:long|short)\s+(\S+)/),
           !["risk", "stop", "take", "leverage", "by", "on", "limit", "trailing"].contains(m.1.lowercased()),
           !m.1.hasSuffix("USDC"), Double(m.1) == nil, IntentParser.namedAsset(String(m.1), markets: markets) == nil { return false }
        return ["new canvas", "clear the plan", "lock"].contains(c.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".! ")))
            || WalletCommand.parse(c) != nil || TokenCommand.parse(c) != nil || PositionCommand.parse(c) != nil || FolderCommand.parse(c) != nil
            || ChartCommand.parse(c, markets: markets) != nil || AlertCommand.parse(c, markets: markets) != nil || AddressBookCommand.parse(c) != nil
            || PnLCommand.parse(c, markets: markets) != nil || ScheduledTask.parse(c) != nil || ScheduledTask.cancelsAll(c)
            || TakeStyle.asksForChoice(c) || IntentParser.apply(c, to: TradeIntent(), markets: markets) != nil
    }

    /// A command is one short line; a paid request carries its JSON body (a question for Grok's X search runs past 200).
    /// A chain of steps has room for each («chart token 0x… on base» three times ran past 200 and the answer was dropped).
    static func maxCommand(_ c: String) -> Int { c.hasPrefix("pay ") ? 2000 : steps(c) != nil ? 1200 : 200 }

    /// The words of a chat or clarify answer while its JSON is still being written: `{"route": "chat", "reply": "Bitc…`
    /// → «Bitc…». nil before the reply starts, or for a lookup or a command.
    public static func partialReply(_ json: String) -> String? {
        guard json.firstMatch(of: /"route"\s*:\s*"(?:chat|clarify)"/) != nil,
              let start = json.firstMatch(of: /"reply"\s*:\s*"/)?.range.upperBound else { return nil }
        var out = "", chars = json[start...].makeIterator()
        while let c = chars.next() {
            if c == "\"" { break }
            guard c == "\\" else { out.append(c); continue }
            guard let e = chars.next() else { break }
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "u":
                var hex = ""
                while hex.count < 4, let h = chars.next() { hex.append(h) }
                if hex.count == 4, let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) { out.append(Character(scalar)) }
            default: out.append(e)
            }
        }
        return out.isEmpty ? nil : out
    }

    static func decode(_ json: Data) throws -> Route {
        struct Answer: Decodable { let route: String; let command: String?; let reply: String? }
        let a = try JSONDecoder().decode(Answer.self, from: json)
        let command = a.command?.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'«» \n")) ?? ""
        let reply = a.reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch a.route {
        case "command" where !command.isEmpty && command.count <= maxCommand(command): return .command(command)
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
