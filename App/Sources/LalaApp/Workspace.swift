import AppKit
import SwiftUI
import DeFiJupiterLend
import DeFiKamino
import DeFiYields
import EVMChain
import ExecutionCore
import Foundation
import GuardJev
import LalaCore
import LLMCatalog
import LLMCore
import Observation
import Security
import SignerAPI
import TradeExecution
import TxGuard

struct Message: Identifiable, Codable, Equatable {
    var id = UUID()
    let fromUser: Bool
    let text: String
    var note: String?
}

@Observable
final class Workspace {
    var intent = TradeIntent()
    var messages = [Message(fromUser: false, text: "Tell me what to do, e.g. “long ETH risk $10 stop 3% take 6% leverage 2x”. Blocks with live numbers appear on the right. Nothing is executed without your signature.")]
    var busy = false
    /// From a sent message until its first reply: the chat shows LALA reading it.
    var thinking = false

    var markets: [String: Market] = [:]
    /// The market picker's lists, names by group, most traded first. Set only when they change, so the picker
    /// doesn't rebuild its menus with every price.
    var marketNames: [Market.Group: [String]] = [:]
    var marketsError: String?
    var solana: Solana.Balance?
    var solanaError: String?
    /// The user's say on a token, by Holding.id: true shows it, false hides it; no entry follows Holding.looksReal.
    /// Not per wallet: a scam token hidden once stays hidden on every wallet.
    var tokenChoices: [String: Bool] = UserDefaults.standard.dictionary(forKey: "tokenChoices") as? [String: Bool] ?? [:] {
        didSet { UserDefaults.standard.set(tokenChoices, forKey: "tokenChoices") }
    }
    func tokenShown(_ t: Holding) -> Bool { tokenChoices[t.id] ?? t.looksReal }
    /// Tokens on the other networks (Holdings.swift): ERC-20s on Base, Arbitrum, Ethereum and Robinhood Chain, ETH on
    /// Arbitrum and Ethereum, Hyperliquid's spot side and NEAR tokens.
    var otherTokens: [Holding] = []
    /// Aave and Morpho off Base, with money in them (Lending.swift).
    var lendingElsewhere: [LendingPosition] = []
    /// A read of the other networks' tokens is under way (refresh starts one and doesn't wait for it).
    @ObservationIgnored var holdingsLoading = false
    /// Every token beyond the balances read one by one, Solana's first. Stock tokens the Robinhood card already shows
    /// are left out here.
    var holdings: [Holding] {
        let stocks = Set((robinhood?.stocks ?? []).map { $0.address.lowercased() })
        return (solana?.tokens ?? []) + otherTokens.filter { !($0.chain == "robinhood" && stocks.contains($0.contract)) }
    }
    /// The tokens on show, and the ones tucked away (hidden by the user or looking like scam airdrops).
    var shownTokens: [Holding] { holdings.filter(tokenShown) }
    var tuckedTokens: [Holding] { holdings.filter { !tokenShown($0) } }
    /// What the tokens on show are worth, the networks' own coins apart: those are gas, like SOL.
    var shownTokensUSD: Decimal { shownTokens.filter { !$0.native }.reduce(0) { $0 + ($1.usd ?? 0) } }
    var shownNativeUSD: Decimal { shownTokens.filter(\.native).reduce(0) { $0 + ($1.usd ?? 0) } }
    var hl: Hyperliquid.Balance?
    var hlError: String?
    var quote: BridgeQuote?
    var quoteError: String?
    var updatedAt: Date?
    /// Whether the signing process holds a key; nil outside ihatecrypto.app, where there is no signer.
    var signerHasWallet: Bool?
    /// The wallet whose key the signing process holds; only then can a plan be executed.
    var signerWallet: TradeWallet?
    /// Every wallet in the signer (public parts) and the one that signs; state kept on this Mac per wallet (exit rules,
    /// recurring buys, the portfolio curve) sits under its id (Wallets.swift).
    var wallets: [SignerWallet] = []
    var activeWalletID: String? = UserDefaults.standard.string(forKey: "activeWalletID") {
        didSet { UserDefaults.standard.set(activeWalletID, forKey: "activeWalletID") }
    }
    /// The in-app dApp browser; its wallet is the signer's.
    @ObservationIgnored let browser = Browser()
    /// The signer's Hyperliquid agent: orders without Touch ID, no withdrawals.
    var agentAddress: String?
    var agentActive = false
    /// Seconds one Touch ID confirmation keeps signing open (the signer's setting).
    var sessionLength = SignerSession.standard

    // Execution
    var prepared: Executor.Prepared? {
        didSet { if prepared != nil, oldValue == nil { remindToConfirm(say("The trade is ready to sign.", "Сделка готова к подписи.")) } }
    }
    var preparing = false
    var executing = false {
        didSet { if oldValue, !executing { lastOwnMove = Date(); endSigningSession(); continueTask() } }
    }

    /// One Touch ID covers one move: once it's done the next signature asks again, unless the user chose 5–30 minutes.
    func endSigningSession() {
        guard sessionLength == SignerSession.standard, !executing, SignerClient.isAvailable else { return }
        Task { _ = try? await SignerClient().send(.endSession) }
    }
    var executionError: String?
    /// A confirmed money move while it runs: its route stays on the canvas with the latest step, until the outcome.
    var runningAction: (title: String, steps: [ActivityBubble], lines: [String], started: Date)?
    var planReview: JevReview?
    var txReview: JevReview?
    var jevNote: String?
    var positions: [HyperliquidAccount.Position] = []
    /// Positions closed in the last 7 days, newest first, from the exchange: a close shows up even if it happened
    /// while LALA was shut or another run closed it. nil until loaded.
    var recentlyClosed: [TradeHistory.Story]?
    /// Margin balances on HIP-3 exchanges («xyz»), separate from the main one.
    var dexBalances: [String: (accountValue: Decimal, withdrawable: Decimal)] = [:]
    /// The plan last carried out; while the intent equals it, the card shows the position, not a new trade.
    var executed: TradeIntent?
    /// Regular purchases, carried out while the app is open.
    /// An allocation plan shown and waiting for «делай».
    var pendingAllocation: WalletCommand? {
        didSet { if pendingAllocation != nil, oldValue == nil { remindToConfirm() } }
    }
    /// A command the model read from another language: it waits for «do it», so a wrong reading moves nothing.
    var pendingAction: PendingAction? {
        didSet {
            if pendingAction != nil, oldValue == nil { remindToConfirm() }
            // A way picked on a route's step belongs to that trade: another move waiting for Confirm drops it.
            if case .wallet(let command)? = pendingAction { routeWays = routeWays.filter { $0.key == command.wayKey } }
        }
    }

    /// A card waits for Confirm while the window isn't in front (the model took a few seconds and the user looked
    /// away): a notification says so. Read on the next turn of the run loop, when the card's text is set.
    func remindToConfirm(_ what: String? = nil) {
        Task { @MainActor in
            guard !NSApp.isActive else { return }
            notify(.confirm, say("Waiting for your Confirm", "Ждёт твоего Confirm"),
                   what ?? pendingText ?? say("A move is on the canvas.", "Действие на холсте."), record: false)
        }
    }
    /// The last money move carried out on this canvas: whether and when it went through, and its route as confirmed.
    /// The canvas keeps them in place of the «waiting for the signature» they replace.
    var finishedAction: (title: String, outcome: CanvasOutcome, route: [ActivityBubble])?
    enum PendingAction { case wallet(WalletCommand), position(PositionCommand, coin: String), address(SavedAddress), transfer(SavedAddress, Decimal) }
    /// The English command the pending action was understood as, for the confirm button.
    var pendingText: String?
    /// A move left waiting on a canvas the user switched away from: it waits there, for a quarter of an hour.
    var parkedPending: [UUID: (action: PendingAction, text: String?, at: Date)] = [:]
    /// A deposit or buy that came without an amount: the next reply that is just a number fills it.
    var awaitingAmount: WalletCommand?
    /// The «Top up LALA» board on the canvas: our addresses and how balances update.
    var showReceive = false
    /// A market's price chart on the canvas (Modules.swift).
    var chart: ChartState?
    /// The day's biggest movers on the canvas.
    var showMovers = false
    /// The price alerts as a board on the canvas, opened when one is set.
    var showAlerts = false
    /// The latest of the history and the favorites on the canvas, opened by the rail's buttons.
    var showHistory = false
    var showFavorites = false
    /// The Schedule canvas in place of the plan (Tasks.swift), and the item it shows in detail: «task:<id>», «buy:SOL», «perp:BTC».
    var showSchedule = false
    var scheduleItem: String?
    /// Where the chat is in the window, so scrolling over it isn't taken by the canvas.
    @ObservationIgnored var chatFrame: CGRect = .zero
    /// The same for the rail, which floats over the canvas too.
    @ObservationIgnored var railFrame: CGRect = .zero
    /// The plan being assembled on the canvas, block by block (S02: the chat shows the count).
    var assembly: (shown: Int, total: Int)?
    /// A place opened from the rail or the portfolio: «solana», «hyperliquid», «jupiter», «aave».
    var detail: String?
    /// When LALA last finished moving money itself; incoming money right after it is its own, not a top-up.
    var lastOwnMove = Date.distantPast
    /// Everything LALA did, with the canvas bubbles of each moment; saved on every change.
    var activities: [Activity] = LocalStore.load("activity.json") ?? [] {
        didSet { LocalStore.save(Array(activities.suffix(1000)), "activity.json") }
    }
    /// Every canvas with its chat, plan and model (see Canvases.swift); saved on every change.
    var canvases: [CanvasSession] = LocalStore.load("canvases.json") ?? [] {
        didSet { LocalStore.save(canvases, "canvases.json") }
    }
    /// The portfolio's value every ten minutes for 30 days (Alerts.swift).
    var equityHistory: [EquityPoint] = LocalStore.load(Workspace.scoped("equity") + ".json") ?? [] {
        didSet { LocalStore.save(equityHistory, Workspace.scoped("equity", activeWalletID) + ".json") }
    }
    /// Tokens the user watches (TokensUI.swift), their DexScreener data and what the wallet holds of them.
    var favoriteTokens: [FavoriteToken] = LocalStore.load("tokens.json") ?? [] {
        didSet { LocalStore.save(favoriteTokens, "tokens.json") }
    }
    /// Behind setters that skip an unchanged value: a `merge` in place (TokensUI, StocksUI) otherwise redraws the
    /// window on every refresh, even with nothing new.
    var tokenInfo: [String: TokenLookup.Info] {
        get { tokenInfoRead }
        set { if newValue != tokenInfoRead { tokenInfoRead = newValue } }
    }
    private var tokenInfoRead: [String: TokenLookup.Info] = [:]
    var tokenBalances: [String: Decimal] {
        get { tokenBalancesRead }
        set { if newValue != tokenBalancesRead { tokenBalancesRead = newValue } }
    }
    private var tokenBalancesRead: [String: Decimal] = [:]
    var tokensCheckedAt = Date.distantPast
    /// Price alerts, one notification each; checked with every refresh (Alerts.swift).
    var alerts: [PriceAlert] = LocalStore.load("alerts.json") ?? [] {
        didSet { LocalStore.save(alerts, "alerts.json") }
    }
    /// Saved addresses — exchanges, other wallets — entered by hand in the address book only (AddressBook.swift).
    var addressBook: [SavedAddress] = LocalStore.load("addressbook.json") ?? [] {
        didSet { LocalStore.save(addressBook, "addressbook.json") }
    }
    /// The canvas on screen; nil for a fresh one nobody has written in yet. Remembered, so it opens again at launch.
    var canvasID: UUID? {
        didSet { UserDefaults.standard.set(canvasID?.uuidString, forKey: "openCanvas") }
    }
    /// A reopened canvas whose board isn't a live plan: drawn as it was.
    var savedBoard: CanvasSession?
    /// The open canvas once its money move is carried out: its route stays on screen, marked Done or Failed with the
    /// time, until a new board replaces it.
    var finishedCanvas: CanvasSession? { canvases.first { $0.id == canvasID && $0.outcome != nil } }
    /// The activity replies are added to.
    var currentActivity: UUID?
    /// What the user is typing in the studio chat; templates on the canvas fill it.
    var draft = ""
    /// A route step handed to the chat from its card («Send to chat»): the next message is about it.
    var stepContext: StepContext?
    /// The way a Base or Arbitrum trade takes, picked in its route step's details (Workspace.wayKey → "relay" or
    /// "uniswap"); none = whichever leaves more. Used once, by the move it was picked for.
    var routeWays: [String: String] = [:]
    /// Both ways of the Base or Arbitrum trade waiting for Confirm, quoted now, the better first (Workspace.quoteSwap):
    /// its card shows the one that leaves more. Empty = neither quotes.
    var swapQuote: (command: WalletCommand, ways: [(way: String, gets: String, worth: Decimal)])?
    /// Speaking into the chat's field.
    let voice = VoiceInput()
    /// A menu or Settings the person has open ("Picking a model", "Choosing networks", "In Settings"): the coin raises
    /// its brows and looks at it, and the chat's header says so.
    var tuning: String?
    /// Settings fill the main window in place of the canvas and the chat.
    var settingsOpen = false

    /// Shows Settings, on `tab` (a `SettingsView.Tab`) when given.
    func openSettings(_ tab: SettingsView.Tab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsView.tabKey) }
        settingsOpen = true
    }
    /// «Spread … across the best rates» waiting for a signature, drawn on the studio canvas.
    var allocationPreview: AllocationPreview?
    /// «Переложи в лучшие ставки» waiting for its signature: the plan, drawn on the canvas it was made on (RebalanceBoard).
    var rebalancePlan: (canvas: UUID?, plan: Rebalance.Plan, maxShare: Decimal)?
    /// Yields shown as bubbles on the studio canvas; nil when none.
    var yieldOptions: [Yields.Option]?
    /// Take-profit styles offered on the canvas after «take profit like the best investors»; nil when none.
    var takeChoices: [TakeStyle]?
    /// The ways to go on the model offered with its last answer, as cards on the canvas (Agent.swift).
    var nextSteps: NextSteps?
    /// What the model is looking up right now («Looking at the token»), under the chat's thinking dots.
    var agentStep: String?
    var schedules: [Schedule] = (UserDefaults.standard.data(forKey: Workspace.scoped("schedules")).flatMap { try? JSONDecoder().decode([Schedule].self, from: $0) }) ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(schedules), forKey: Workspace.scoped("schedules", activeWalletID)) }
    }
    /// Commands scheduled for later or on repeat («in 1 week: rebalance USDC»), per wallet; `watch` runs them (Tasks.swift).
    var tasks: [ScheduledTask] = (UserDefaults.standard.data(forKey: Workspace.scoped("tasks")).flatMap { try? JSONDecoder().decode([ScheduledTask].self, from: $0) }) ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(tasks), forKey: Workspace.scoped("tasks", activeWalletID)) }
    }
    /// A running task's steps after one that waits for Confirm, and the canvas it runs on: they go when that move is done.
    var taskQueue: (canvas: UUID?, steps: [String], since: Date)?
    /// Exit rules the app keeps for open positions (breakeven after the partial take, trailing), by coin.
    var exitRules: [String: ExitRules] = (UserDefaults.standard.data(forKey: Workspace.scoped("exitRules")).flatMap { try? JSONDecoder().decode([String: ExitRules].self, from: $0) }) ?? [:] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(exitRules), forKey: Workspace.scoped("exitRules", activeWalletID)) }
    }
    /// The position the plan card shows: the plan's asset if open, otherwise the first one.
    var position: HyperliquidAccount.Position? { positions.first { $0.coin == intent.asset } ?? positions.first }

    /// For the «Расписание» tab: regular purchases and positions the guardian watches.
    var scheduledCount: Int { schedules.count + exitRules.count }

    /// «0,369 по 93,417 · стоп 96,033 · тейк 90,801 и 88,186»: size, entry and the exchange's trigger orders.
    func positionSummary(_ p: HyperliquidAccount.Position) -> String {
        let triggers = orders.filter { $0.coin == p.coin && $0.isTrigger }
        let stop = triggers.first { ($0.orderType ?? "").contains("Stop") }?.triggerPx
        // Nearest take first: a partial one fills before the full one.
        let takes = triggers.filter { ($0.orderType ?? "").contains("Take") }.compactMap(\.triggerPx)
            .sorted { p.size > 0 ? $0 < $1 : $0 > $1 }
        return "\(Fmt.num(abs(p.size), maxFraction: 6)) at \(Fmt.price(p.entry)) · stop \(stop.map(Fmt.price) ?? "none")"
            + (takes.isEmpty ? "" : " · take " + takes.map(Fmt.price).joined(separator: " and "))
    }
    var orders: [HyperliquidAccount.Order] = []
    /// A limit entry waiting on the book (its stop and take are the trigger orders next to it).
    var pendingEntry: HyperliquidAccount.Order? { orders.first { !$0.isTrigger } }
    var lend: [(vault: String, usdc: Decimal)] = []
    /// Kamino Lend deposits, in dollars.
    var kamino: Decimal = 0
    /// The NEAR implicit account the signer derived from the same phrase; nil until it has been asked once.
    var nearAddress: String?
    /// NEAR on that account: native and wNEAR, in NEAR.
    var near: Decimal = 0
    /// Its value in dollars, at Hyperliquid's NEAR price.
    var nearUSD: Decimal { near * (markets["NEAR"]?.markPx ?? 0) }
    /// Gas money: SOL on Solana, ETH on Base and Robinhood Chain, at Hyperliquid's prices. It is the user's money, so
    /// the balance shows it (`total`); the risk rules leave it out (`equity`), since no trade may spend it.
    var solUSD: Decimal { (solana?.sol ?? 0) * (markets["SOL"]?.markPx ?? 0) }
    var gasETH: Decimal { (base?.eth ?? 0) + (robinhood?.eth ?? 0) }
    var gasETHUSD: Decimal { gasETH * (markets["ETH"]?.markPx ?? 0) }
    /// Everything the wallet holds, gas included: the balance on screen.
    var total: Decimal? { equity.map { $0 + solUSD + gasETHUSD + shownNativeUSD } }
    /// Hyperliquid's HLP vault: what is in it and, while a deposit is locked, until when.
    var hlp: (equity: Decimal, lockedUntil: Date?) = (0, nil)
    /// On Base, at the Hyperliquid (EVM) address: idle USDC, USDC supplied to Aave, ETH for gas.
    var base: (usdc: Decimal, aave: Decimal, morpho: Decimal, eth: Decimal)?
    /// USDC on Arbitrum at our EVM address (money in transit or left from a transfer).
    var arbitrumUSDC: Decimal?
    /// Robinhood Chain at our EVM address: USDG, ETH for gas, the Stock Tokens bought through LALA (StocksUI.swift).
    /// A tuple isn't Equatable, so @Observable would redraw on every refresh's assignment: the setter skips an unchanged one.
    var robinhood: (usdg: Decimal, eth: Decimal, stocks: [StockHolding])? {
        get { robinhoodRead }
        set {
            if let n = newValue, let o = robinhoodRead, n == o { return }
            if newValue == nil, robinhoodRead == nil { return }
            robinhoodRead = newValue
        }
    }
    private var robinhoodRead: (usdg: Decimal, eth: Decimal, stocks: [StockHolding])?
    /// Aave v3 USDC supply APY on Base, %, read from the pool itself.
    var aaveAPY: Decimal?
    /// Morpho's Gauntlet USDC Prime vault on Base, net of its fee.
    var morphoAPY: Decimal?
    private var aaveCheckedAt: Date?
    var reviewedIntent: TradeIntent?

    init() {
        restoreLastCanvas()
        // What is on the open canvas at quit (a chart opened by a click, a board that finished building) is kept too.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // Then every file saved so far is written before the app goes (LocalStore writes off the main thread).
            MainActor.assumeIsolated { self?.saveCanvas(); LocalStore.flush() }
        }
        // A locked screen or sleep ends the Touch ID session, however long the user let it be.
        let endSession: @Sendable (Notification) -> Void = { _ in
            Task { if SignerClient.isAvailable { _ = try? await SignerClient().send(.endSession) } }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: endSession)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: endSession)
    }
    private var quotedKey: String?

    var solanaAddress = UserDefaults.standard.string(forKey: "solanaAddress") ?? "" {
        didSet { UserDefaults.standard.set(solanaAddress, forKey: "solanaAddress"); Task { await loadSolana() } }
    }
    var hlAddress = UserDefaults.standard.string(forKey: "hlAddress") ?? "" {
        didSet { UserDefaults.standard.set(hlAddress, forKey: "hlAddress"); Task { await loadHL(); await refreshQuote() } }
    }

    // MARK: Model connection. Which provider and model live in UserDefaults; keys and tokens only in Keychain.

    var providerID = UserDefaults.standard.string(forKey: "llmProvider") ?? "chatgpt" {
        didSet { UserDefaults.standard.set(providerID, forKey: "llmProvider"); llmStatus = nil; availableModels = [] }
    }
    var modelChoices = UserDefaults.standard.dictionary(forKey: "llmModels") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(modelChoices, forKey: "llmModels") }
    }
    /// Second opinion on incoming text from Jev via OpenRouter. On by default (product decision, 2026-09-25);
    /// it needs an OpenRouter login and sends the message text there. Local rules run regardless.
    var policy: RiskPolicy = (UserDefaults.standard.data(forKey: "riskPolicy").flatMap { try? JSONDecoder().decode(RiskPolicy.self, from: $0) }) ?? {
        var p = RiskPolicy()
        // `-maxRiskPct 10`: a looser limit for tests on a tiny wallet.
        #if DEBUG
        if let v = UserDefaults.standard.string(forKey: "maxRiskPct").flatMap({ Decimal(string: $0) }) { p.maxRiskPct = v }
        #endif
        return p
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(policy), forKey: "riskPolicy") }
    }
    /// 4-hour ATR per asset, % of price.
    var atr: [String: Decimal] = [:]
    var jevScreening = UserDefaults.standard.object(forKey: "jevScreening") as? Bool ?? true {
        didSet { UserDefaults.standard.set(jevScreening, forKey: "jevScreening") }
    }
    /// On: Solana buys only the fixed verified coins. Off: any token by its mint, with its risks said first (TokensUI.swift).
    var safeSearch = UserDefaults.standard.object(forKey: "safeSearch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(safeSearch, forKey: "safeSearch") }
    }
    var openRouterKey: String? {
        _ = credentialVersion
        if case .apiKey(let key)? = Keychain.load("openrouter") { return key }
        return nil
    }
    private var credentialVersion = 0
    var llmBusy = false
    var llmStatus: String?
    var availableModels: [String] = []

    var provider: any LLMProvider { LLMCatalog.provider(id: providerID) ?? LLMCatalog.all[0] }
    var model: String {
        get { modelChoices[providerID] ?? provider.info.defaultModel }
        set { modelChoices[providerID] = newValue }
    }
    var credential: Credential? {
        _ = credentialVersion
        return Keychain.load(providerID)
    }
    /// Whether the chosen provider has a login, for views: a Keychain read is a round trip to securityd (≈ 4 ms) and
    /// the rail redraws with every balance refresh. A login found is remembered (a token refresh never removes one);
    /// «none» is read again, since a read can fail once (a fresh build's Keychain prompt) and must not stick.
    var signedIn: Bool {
        _ = credentialVersion
        if signedInCache.contains(providerID) { return true }
        guard Keychain.load(providerID) != nil else { return false }
        signedInCache.insert(providerID)
        return true
    }
    @ObservationIgnored private var signedInCache: Set<String> = []

    func setCredential(_ credential: Credential?) {
        Keychain.save(credential, for: providerID)
        signedInCache.remove(providerID)
        credentialVersion += 1
    }

    /// nil until the chosen provider is connected.
    func llmClient() -> (any LLMClient)? {
        let p = provider, id = p.info.id
        guard p.info.unavailable == nil, credential != nil || p.info.kind == .local else { return nil }
        return try? p.client(credential, save: { Keychain.save($0, for: id) })
    }

    func signIn() async {
        llmBusy = true
        defer { llmBusy = false }
        llmStatus = "Waiting for the sign-in in the browser…"
        do {
            setCredential(try await provider.signIn(open: { url in Task { @MainActor in NSWorkspace.shared.open(url) } }))
            llmStatus = "Signed in."
        } catch {
            llmStatus = error.localizedDescription
        }
    }

    func useExistingLogin() {
        guard let login = provider.existingLogin() else { llmStatus = "No sign-in found on this Mac."; return }
        setCredential(login)
        llmStatus = "Connected."
    }

    func testModel() async {
        guard let client = llmClient() else { llmStatus = "Connect \(provider.info.name) first."; return }
        llmBusy = true
        defer { llmBusy = false }
        do {
            let started = Date()
            let reply = try await client.complete(LLMRequest(model: model, messages: [LLMMessage(.user, "Reply with one word: works")]))
            llmStatus = "\(model) answered in \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(reply.prefix(80))"
        } catch {
            llmStatus = error.localizedDescription
        }
    }

    func loadModels() async {
        do {
            availableModels = try await provider.models(credential)
            if availableModels.isEmpty { llmStatus = "This provider does not list its models; type the name." }
        } catch {
            llmStatus = error.localizedDescription
        }
    }

    var market: Market? {
        var m = markets[intent.asset]
        m?.atrPct = atr[intent.asset]
        return m
    }
    /// Capital the risk rules measure against: USDC on Solana and the tokens on show there, the Hyperliquid account and vaults.
    var equity: Decimal? {
        guard solana != nil || hl != nil else { return nil }
        return (solana?.usdc ?? 0) + shownTokensUSD + (hl?.accountValue ?? 0) + lend.reduce(0) { $0 + $1.usdc } + dexBalances.values.reduce(0) { $0 + $1.accountValue }
            + (base.map { $0.usdc + $0.aave + $0.morpho } ?? 0) + lendingElsewhereUSD + (arbitrumUSDC ?? 0) + robinhoodTotal + kamino + hlp.equity + nearUSD
    }
    /// The plan with what the user left to the rules filled in.
    var resolved: (intent: TradeIntent, notes: [String]) { Plan.resolve(intent, market: market, equity: equity, policy: policy) }
    var evaluation: Evaluation { Plan.evaluate(resolved.intent, market: market) }
    var blocks: [Block] {
        let (intent, notes) = resolved
        var live = Live()
        live.equity = equity
        live.policy = policy
        live.openRisk = HyperliquidAccount.riskAtStops(positions: positions, orders: orders)
        live.notes = notes
        live.solanaAddressSet = isSolanaAddress(solanaAddress)
        live.solanaUSDC = solana?.usdc
        live.hlAddressSet = isEVMAddress(hlAddress)
        // A HIP-3 market can use what is free on its own exchange as well as the main balance.
        live.hlWithdrawable = hl.map { $0.withdrawable + (market?.dex.flatMap { dexBalances[$0]?.withdrawable } ?? 0) }
        live.marketsLoaded = !markets.isEmpty
        live.market = market
        live.quote = quote
        return Plan.blocks(intent, evaluation, live)
    }

    // MARK: Chat

    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        if SeedGuard.containsMnemonic(text) {
            reply(say("That looks like a recovery phrase. I don’t show it, store it or send it anywhere. Import a phrase in its own window.",
                      "Похоже на фразу восстановления. Я её не показываю, не храню и никуда не отправляю. Импортируй фразу в отдельном окне."))
            return
        }
        // A step handed over from its card: the message is about it, and a move waiting for Confirm keeps waiting.
        let step = stepContext
        stepContext = nil
        messages.append(Message(fromUser: true, text: step.map { "«\($0.title)»\n" + text } ?? text))
        thinking = true
        defer { thinking = false }
        finishedAction = nil
        // The answer goes on the plan canvas; scheduling opens the Schedule canvas again.
        showSchedule = false
        // The cards of the last answer go with any new message; the model still knows them («да», «второй»).
        let offered = nextSteps?.options ?? []
        nextSteps = nil
        // Every message starts an activity; whatever is on the canvas when it's handled is frozen into it.
        beginActivity(.request, request: text)
        defer { snapshotCanvas(); saveCanvas() }

        // Before the parser or any model sees it: local rules, plus Jev if the user turned it on.
        let classifier: (any TextClassifier)? = jevScreening ? openRouterKey.map { JevClassifier(apiKey: $0) } : nil
        busy = true
        let screen = await InjectionGuard.screen(text, source: "chat message", classifier: classifier)
        busy = false
        FileHandle.standardError.write(Data("LALA screen: ok=\(screen.ok) \(screen.checks + screen.problems)\n".utf8))
        guard screen.ok else {
            let pastedAddress = text.contains(/0x[0-9a-fA-F]{40}|[1-9A-HJ-NP-Za-km-z]{32,44}/)
            reply(say("This looks like an attempt to steer the assistant or swap an address. ", "Похоже на попытку управлять ассистентом или подменить адрес. ")
                  + screen.problems.joined(separator: " ")
                  + say(" The message was not passed to the model and changed nothing.", " Сообщение не ушло модели и ничего не изменило.")
                  + (pastedAddress ? say(" To keep an address, save it in Addresses — the book button in the rail.", " Чтобы сохранить адрес, добавь его в адресную книгу — кнопка с книгой слева.") : ""),
                  note: classifier == nil ? "guard: local rules" : "guard: rules and Jev")
            return
        }
        let before = intent

        // A confirmation from the debug API would only fail at the signer and lose the card: keep it for the window.
        if SignerClient.untrusted, activeWallet?.isTest != true, pendingAction != nil || pendingAllocation != nil,
           text.lowercased().contains(/^(?:делай|да|давай|подтверждаю|го|do\s+it|go|yes|confirm|sign)\b/) {
            reply(say("That «do it» came from the debug API, which can’t confirm money moves. In the window, press Confirm on the card or type «do it» yourself.",
                      "Это «do it» пришло из отладочного API, а он не подтверждает переводы. В окне нажми Confirm на карточке или напиши «делай» сам."), note: "debug API")
            return
        }

        // «делай» / «do it» right after a plan that waits for it carries it out; anything else drops it.
        let confirms = text.lowercased().contains(/^(?:делай|да|давай|подтверждаю|раскладывай|го|do\s+it|go|yes|confirm|sign)\b/)
        // Anything but a confirmation takes over from a scheduled task that waited for one.
        if !confirms { taskQueue = nil }
        let declines = text.lowercased().wholeMatch(of: /\s*(?:no|nope|cancel|stop|нет|не\s+надо|отмена|отмени\w*|стоп|nein|abbrechen|non|annuler|cancelar|não|nao|nie|anuluj)[.!\s]*/) != nil
        if let pending = pendingAllocation {
            pendingAllocation = nil
            if confirms { await move(pending, confirmed: true); return }
            if declines {
                allocationPreview = nil
                rebalancePlan = nil
                reply(say("Cancelled — nothing moved.", "Отменено — ничего не ушло."))
                return
            }
        }
        if let pending = pendingAction, step == nil || confirms || declines {
            pendingAction = nil
            pendingText = nil
            if declines {
                reply(say("Cancelled — nothing moved.", "Отменено — ничего не ушло."))
                return
            }
            if confirms {
                switch pending {
                case .wallet(let command): await move(command)
                case .position(let command, let coin): await manage(command, coin: coin)
                case .transfer(let entry, let amount): await transfer(amount, to: entry)
                case .address(let entry):
                    addressBook.append(entry)
                    reply("Saved “\(entry.name)” in Addresses (\(entry.network.title)). Star it there or say “add \(entry.name) to favorites”.")
                }
                return
            }
        }
        // The answer to «How much …?»: a bare number fills the waiting command.
        if let waiting = awaitingAmount {
            if declines {
                awaitingAmount = nil
                reply(say("OK, not doing that.", "Хорошо, не делаю."))
                return
            }
            if let value = WalletCommand.amountAnswer(text) {
                awaitingAmount = nil
                await handleWallet(waiting.with(amount: value))
                return
            }
            if text.lowercased().wholeMatch(of: /\s*(?:да|yes|yep|ok|okay|давай|угу|sure|go)[.!\s]*/) != nil {
                reply(say("How much? Just the number, for example “1”.", "Сколько? Просто число, например «1»."))
                return
            }
            awaitingAmount = nil
        }
        if declines {
            withAnimation(StudioView.spring) { allocationPreview = nil; rebalancePlan = nil; yieldOptions = nil; takeChoices = nil }
            reply(say("OK — nothing was waiting, nothing moved.", "Хорошо — ничего не ждало подтверждения, ничего не ушло."))
            return
        }
        // Read once per message: each read is a Keychain round trip and a JSON decode.
        let client = llmClient()
        // «да» with nothing waiting answers LALA's last question: the model reads it with the chat. Without a model
        // there is nothing to answer.
        if client == nil, text.lowercased().wholeMatch(of: /\s*(?:делай|да|давай|подтверждаю|го|do\s+it|go|yes|yep|ok|okay|confirm|sign)[.!\s]*/) != nil {
            reply(say("Nothing is waiting for a confirmation right now. Tell me what to do — for example “deposit 1 USDC into Jupiter”.",
                      "Сейчас нечего подтверждать. Скажи, что сделать — например «положи 1 USDC в Jupiter»."))
            return
        }
        takeChoices = nil
        yieldOptions = nil
        if pendingAllocation == nil { allocationPreview = nil; rebalancePlan = nil }
        if TakeStyle.asksForChoice(text) {
            if intent == TradeIntent() {
                reply("Describe the trade first — then I’ll show the ways to take profit on it.")
            } else {
                takeChoices = TakeStyle.allCases
                reply("Three ways to take profit are on the canvas. The stop stays the same; pick one or say your own, e.g. “take 3R”.")
            }
            return
        }
        let lower = text.lowercased()
        if lower.wholeMatch(of: /\s*(?:new\s+canvas|новый\s+(?:канвас|холст)|start\s+over|начн[иём]\s+заново)\s*[.!]?\s*/) != nil {
            messages.removeLast()   // the command itself doesn't belong to the canvas being closed
            newCanvas()
            return
        }
        if lower.wholeMatch(of: /\s*(?:clear|reset|remove|drop)\s+(?:the\s+)?plan|(?:очисти|сбрось|убери|удали)\s+план\w*\s*[.!]?\s*/) != nil {
            intent = TradeIntent()
            executed = nil
            takeChoices = nil
            reply(say("The plan is cleared. Tell me what to do next.", "План очищен. Скажи, что дальше."))
            return
        }
        if text.lowercased().wholeMatch(of: /\s*(?:lock|lock\s+(?:it|the\s+wallet|signing)|заблокируй\w*|блокир\w*)\s*[.!]?\s*/) != nil {
            await lockSigner()
            return
        }
        // «переключись на кошелёк Main»: the wallet by its name; the signer asks for Touch ID.
        if let target = walletSwitch(text) {
            if let target { await switchWallet(target) } else {
                reply("No wallet has that name. Yours: \(wallets.map { "«\($0.label)»" }.joined(separator: ", ")).")
            }
            return
        }
        if text.lowercased().contains(/(?:resume|unpause|turn\s+on|включи|верни)\s+(?:the\s+)?(?:trading\s+key|торгов\w*\s+ключ)/) {
            await resumeTradingKey()
            return
        }
        // A connected model reads every message first: its meaning, not keywords. What it understood goes through
        // the same parsers, checks, Jev and confirmations as a typed command. The local parsers below read the message
        // as typed when no model is connected or it can't be reached.
        if let client {
            await routeWithModel(step.map { "About the step «\($0.title)» of the route on the canvas: \(text)" } ?? text,
                                 client: client, before: before, offered: offered)
            return
        }
        // No model connected: the local parsers read the message as typed.
        if ScheduledTask.cancelsAll(text) { cancelTasks(); return }
        if let task = ScheduledTask.parse(text) { schedule(task); return }
        if let command = TokenCommand.parse(text) {
            await tokenCommand(command)
            return
        }
        if let command = AddressBookCommand.parse(text) {
            addressBookCommand(command)
            return
        }
        if let command = AlertCommand.parse(text, markets: Set(markets.keys)) {
            alertCommand(command)
            return
        }
        if let command = ChartCommand.parse(text, markets: Set(markets.keys)) {
            await chartCommand(command)
            return
        }
        if let command = PnLCommand.parse(text, markets: Set(markets.keys)) { await showPnL(command); return }
        if case .sendTo(let name, let amount)? = WalletCommand.parse(text) {
            prepareTransfer(amount, to: name)
            return
        }
        if let command = WalletCommand.parse(text) {
            await handleWallet(command)
            return
        }
        // With a position or a waiting limit, «стоп в безубыток», «закрой половину» act on it, not on the plan.
        if !positions.isEmpty || pendingEntry != nil, let command = PositionCommand.parse(text) {
            if let coin = targetCoin(for: text) {
                await manage(command, coin: coin)
            } else {
                let open = positions.map { "\($0.size > 0 ? "long" : "short") \(IntentParser.pretty($0.coin))" }.joined(separator: ", ")
                reply("Which position? Open: \(open). Name it, e.g. “\(text) \(positions.first.map { IntentParser.pretty($0.coin).components(separatedBy: " (").first ?? $0.coin } ?? "")”.")
            }
            return
        }

        // A question gets an answer from the portfolio and the history; it never becomes a plan.
        if IntentParser.isQuestion(text) {
            await answer(text)
            return
        }

        // With no plan on the canvas, only a market or a direction starts one: «1 USDC» alone is not «long ETH».
        let startsPlan = intent != TradeIntent() || IntentParser.startsPlan(text, markets: Set(markets.keys))
        let parsed = startsPlan ? IntentParser.apply(text, to: intent, markets: Set(markets.keys)) : nil
        let confident = parsed != nil && (client == nil || (!IntentParser.needsModel(text) && IntentParser.hasTradeWords(text)))
        if let next = parsed, confident {
            if await editExecuted(from: before, to: next) { return }
            intent = next
            let changes = next.changes(from: before)
            await refreshQuote()
            reply((changes.isEmpty ? "That’s already in the plan." : "Plan updated: " + changes.joined(separator: ", ") + ".") + outcomeLine)
        } else if let client {
            // No plan and nothing about trading: the plan editor would only invent one.
            guard startsPlan || IntentParser.hasTradeWords(text) else {
                reply(Self.help)
                return
            }
            await editPlanWithModel(text, client: client, before: before)
            return
        } else {
            reply("I didn’t get that. Without a model I understand: long/short, a ticker ($ETH), “risk $10”, “stop 3%”, “take 6%”, “leverage 2x”, “100 USDC” — in English or Russian. For other languages and free wording like “take closer”, connect a model in Settings (⌘,): a ChatGPT subscription, Claude Code, OpenRouter or an API key.")
        }
        await refreshQuote()
        await reviewPlan()
    }

    /// Which position a position command is about. Never a guess: the asset the message names, else the plan's asset
    /// if it has a position, else the only position when no plan is on screen. nil means ask.
    func targetCoin(for text: String) -> String? {
        let open = Set(positions.map(\.coin) + (pendingEntry.map { [$0.coin] } ?? []))
        if let named = IntentParser.namedAsset(text, markets: Set(markets.keys)) { return open.contains(named) ? named : nil }
        if intent != TradeIntent(), open.contains(intent.asset) { return intent.asset }
        if intent == TradeIntent(), open.count == 1 { return open.first }
        return nil
    }

    /// A take-profit style picked on the canvas.
    func chooseTake(_ style: TakeStyle) async {
        let before = intent
        intent = style.apply(to: intent)
        takeChoices = nil
        let changes = intent.changes(from: before)
        await refreshQuote()
        reply("Take: \(style.title.lowercased())" + (changes.isEmpty ? "." : " — " + changes.joined(separator: ", ") + ".") + outcomeLine)
        await reviewPlan()
    }

    /// The model's reading of the message (ChatRouter) — the only reading while a model is connected: keywords guess,
    /// and a wrong guess about money is worse than a question. The model is asked twice; if it still can't be reached,
    /// nothing is done and the chat says so.
    private func routeWithModel(_ text: String, client: any LLMClient, before: TradeIntent, offered: [ChatRouter.Option] = []) async {
        busy = true
        var reading: ChatRouter.Reading?
        var failure = ""
        let context = routerContext(offered: offered)
        // The model's lookups run here, on this canvas's data; the chat shows which one is under way.
        let lookup: @Sendable (ChatRouter.Lookup) async -> String = { [weak self] l in await self?.agentLookup(l) ?? "" }
        for _ in 0..<2 where reading == nil {
            do {
                reading = try await ChatRouter.route(text, context: context, client: client, model: model, lookup: lookup)
            } catch {
                failure = error.localizedDescription
                FileHandle.standardError.write(Data("LALA router: \(error)\n".utf8))
            }
        }
        busy = false
        agentStep = nil
        if let reading, !reading.lookups.isEmpty {
            updateActivity { $0.understood = "looked up " + reading.lookups.map { "\($0.tool) \($0.arg)" }.joined(separator: ", ") }
        }
        // The block the answer points to opens with it; the cards follow the reply.
        if let reading { await show(reading, userText: text) }
        defer { if let reading { offer(reading, userText: text) } }
        let note = reading.map { $0.lookups.isEmpty ? model : "\(model) · looked at \(Set($0.lookups.map(\.tool)).sorted().joined(separator: ", "))" } ?? model
        switch reading?.route {
        case nil:
            reply(say("I couldn’t reach \(model) (\(failure.prefix(140))), so I didn’t act on this — nothing moved. Send it again, or pick another model above.",
                      "Не достучался до \(model) (\(failure.prefix(140))), поэтому ничего не сделал — ничего не ушло. Отправь ещё раз или выбери другую модель сверху."), note: model)
        case .question?: await answer(text)
        case .plan?:
            // With both perps and xyz markets off there's no trade to build; otherwise Execute checks the market.
            if let off = Modules.current.refusal(trade: false, bridges: false, ru: modulesRussian),
               Modules.current.refusal(trade: true, bridges: false) != nil {
                reply(off, note: model)
            } else {
                await editPlanWithModel(text, client: client, before: before)
                if let off = tradeRefusal { reply(off, note: model) }
            }
        case .chat(let r)?, .clarify(let r)?: reply(r, note: note)
        case .command(let canonical)?:
            guard ChatRouter.addressesAllowed(canonical, userText: text, known: favoriteTokens.map(\.address) + (Self.displays(canonical) ? reading?.found ?? [] : [])) else {
                reply(say("I read that as “\(canonical)”, but its address is neither in your message nor among your favorites, so I won’t use it. Paste the address itself.",
                          "Я понял это как «\(canonical)», но этого адреса нет ни в твоём сообщении, ни в избранном, поэтому я его не использую. Вставь сам адрес."), note: model)
                return
            }
            if await !runCanonical(canonical, userText: text, before: before) {
                reply(say("I read that as “\(canonical)”, but ihatecrypto can’t do that yet — nothing moved. Tell me another way, or ask what ihatecrypto can do.",
                          "Я понял это как «\(canonical)», но ihatecrypto пока так не умеет — ничего не ушло. Скажи иначе или спроси, что ihatecrypto умеет."), note: model)
            }
        }
    }

    /// What the model may know besides the message: the chat, the plan, positions, favorites, address book names and
    /// the main balances. Never keys or the user's own addresses.
    private func routerContext(offered: [ChatRouter.Option] = []) -> ChatRouter.Context {
        var c = ChatRouter.Context()
        c.recent = Array(recentChat().dropLast())   // the last line is the message itself
        c.offered = offered.map { "\($0.title) → \($0.command)\($0.recommended ? " (recommended)" : "")" }
        if intent != TradeIntent(), let json = try? JSONEncoder().encode(intent) { c.plan = String(decoding: json, as: UTF8.self) }
        if let ch = chart { c.canvas.append("chart \(ch.coin) (\(ch.range.title))") }
        if let p = pendingText { c.canvas.append("waiting for Confirm: \(p)") }
        c.canvas += alerts.map { a in
            "price alert: \(a.coin) \(a.above ? "above" : "below") \(Fmt.price(a.price))" + (a.steps.map { ", then " + $0.joined(separator: " then ") } ?? "")
        }
        c.positions = positions.map { "\($0.size > 0 ? "long" : "short") \(IntentParser.pretty($0.coin))" }
        c.favorites = favoriteTokens.map { "\($0.symbol) (\($0.name)) = \($0.address) on \($0.chainTitle)" }
        c.addressBook = addressBook.map(\.name)
        c.replyLanguage = replyLanguage
        c.off = Modules.current.offSummary
        c.safeSearch = safeSearch
        if let s = solana { c.balances.append("Solana \(Fmt.num(s.usdc)) USDC, \(Fmt.num(s.sol, maxFraction: 4)) SOL") }
        // Every place with money, so «выведи всё из Jupiter» needs no question about which asset is there.
        if let h = hl { c.balances.append("Hyperliquid trading balance \(Fmt.usd(h.accountValue)), withdrawable \(Fmt.usd(h.withdrawable))") }
        for (dex, b) in dexBalances where b.accountValue > 0 { c.balances.append("Hyperliquid \(dex) exchange \(Fmt.usd(b.accountValue))") }
        if hlp.equity > 0 { c.balances.append("HLP vault \(Fmt.usd(hlp.equity))" + (hlp.lockedUntil.map { ", locked until \(Fmt.date($0))" } ?? "")) }
        for l in lend where l.usdc > 0 { c.balances.append("Jupiter Lend \(l.vault.replacingOccurrences(of: "jl", with: "")) \(Fmt.num(l.usdc))") }
        if kamino > 0 { c.balances.append("Kamino \(Fmt.usd(kamino))") }
        if let b = base {
            if b.aave > 0 { c.balances.append("Aave on Base \(Fmt.num(b.aave)) USDC") }
            if b.morpho > 0 { c.balances.append("Morpho on Base \(Fmt.num(b.morpho)) USDC") }
            if b.usdc > 0 { c.balances.append("Base \(Fmt.num(b.usdc)) USDC idle") }
        }
        if near > 0 { c.balances.append("NEAR \(Fmt.num(near, maxFraction: 4)) NEAR") }
        if let r = robinhood {
            c.balances.append("Robinhood Chain \(Fmt.num(r.usdg)) USDG" + r.stocks.map { ", \(Fmt.num($0.amount, maxFraction: 6)) \($0.symbol) stock" }.joined())
        }
        for t in favoriteTokens { if let held = tokenBalances[t.id], held > 0 { c.balances.append("\(t.symbol) token on \(t.chainTitle) \(Fmt.num(held, maxFraction: 4))") } }
        return c
    }

    /// Free-form plan edits («take closer», «less risk») by the model.
    private func editPlanWithModel(_ text: String, client: any LLMClient, before: TradeIntent) async {
        busy = true
        let note = "\(model) · \(provider.info.name)"
        do {
            let (next, answer) = try await ChatModel.edit(intent, message: text, client: client, model: model, history: recentChat(), replyLanguage: replyLanguage)
            busy = false
            if let next, await editExecuted(from: before, to: next) { return }
            if let next { intent = next }
            let changes = next?.changes(from: before) ?? []
            let fallback = changes.isEmpty ? "The model changed nothing." : "Plan updated: " + changes.joined(separator: ", ") + "."
            await refreshQuote()
            reply((answer.isEmpty ? fallback : answer) + outcomeLine, note: note)
        } catch {
            busy = false
            reply("The model is unavailable: \(error.localizedDescription)", note: note)
        }
        await refreshQuote()
        await reviewPlan()
    }

    /// Runs the model's English command through the parsers. False when it is not a command they know.
    func runCanonical(_ canonical: String, userText text: String, before: TradeIntent) async -> Bool {
        updateActivity { $0.understood = canonical }
        let note = "understood as “\(canonical)” · \(model)"
        if ScheduledTask.cancelsAll(canonical) { cancelTasks(note: note); return true }
        if let task = ScheduledTask.parse(canonical) { schedule(task, note: note); return true }
        switch canonical.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".! ")) {
        case "new canvas":
            messages.removeLast()
            newCanvas()
            return true
        case "clear the plan":
            intent = TradeIntent()
            executed = nil
            takeChoices = nil
            reply(say("The plan is cleared. Tell me what to do next.", "План очищен. Скажи, что дальше."), note: note)
            return true
        case "lock":
            await lockSigner()
            return true
        default: break
        }
        if let command = TokenCommand.parse(canonical) {
            await tokenCommand(command, note: note)
            return true
        }
        if let command = ChartCommand.parse(canonical, markets: Set(markets.keys)) {
            await chartCommand(command, note: note)
            return true
        }
        if let command = PnLCommand.parse(canonical, markets: Set(markets.keys)) { await showPnL(command, note: note); return true }
        if TakeStyle.asksForChoice(canonical), intent != TradeIntent() {
            takeChoices = TakeStyle.allCases
            reply("Three ways to take profit are on the canvas. The stop stays the same; pick one.", note: note)
            return true
        }
        if let command = AlertCommand.parse(canonical, markets: Set(markets.keys)) {
            alertCommand(command, note: note)
            return true
        }
        if let command = AddressBookCommand.parse(canonical) {
            // The model only rewords: an address it wrote must be in the user's own message, character for character.
            if case .save(let address, _, _) = command, !text.contains(address) { return false }
            addressBookCommand(command, note: note)
            return true
        }
        if case .sendTo(let name, let amount)? = WalletCommand.parse(canonical) {
            prepareTransfer(amount, to: name, note: note)
            return true
        }
        if let command = WalletCommand.parse(canonical) {
            await handleWallet(command, note: note)
            return true
        }
        if let coin = targetCoin(for: canonical), let command = PositionCommand.parse(canonical) {
            pendingAction = .position(command, coin: coin)
            pendingText = canonical
            reply(say("Understood as “\(canonical)” for \(IntentParser.pretty(coin)). Say “do it” or press Confirm to go ahead.",
                      "Понял как «\(canonical)» для \(IntentParser.pretty(coin)). Напиши «делай» или нажми Confirm."), note: note)
            return true
        }
        guard let next = IntentParser.apply(canonical, to: intent, markets: Set(markets.keys)) else { return false }
        if await editExecuted(from: before, to: next) { return true }
        intent = next
        let changes = next.changes(from: before)
        await refreshQuote()
        reply((changes.isEmpty ? "That’s already in the plan." : "Plan updated: " + changes.joined(separator: ", ") + ".") + outcomeLine, note: note)
        await reviewPlan()
        return true
    }

    /// After every message about the plan: the plan checked item by item and the next step (TradeAdvice.swift).
    var outcomeLine: String {
        let list = planChecklist
        return list.isEmpty ? "" : "\n" + list
    }

    func reply(_ text: String, note: String? = nil) {
        // The executor reports its last line and the move returns it too: say it once.
        if let last = messages.last, !last.fromUser, last.text == text { return }
        messages.append(Message(fromUser: false, text: text, note: note))
        updateActivity { $0.lines.append(text) }
        saveCanvas()
    }

    // MARK: Live data

    func refresh() async {
        let before = (solana?.usdc, solana?.sol, base?.usdc)
        defer { if updatedAt != nil { announceIncoming(before: (before.0, before.1, before.2)) } }
        async let m: Void = loadMarkets()
        async let s: Void = loadSolana()
        async let h: Void = loadHL()
        async let b: Void = loadBase()
        async let r: Void = loadRobinhood()
        async let t: Void = refreshTokens()
        _ = await (m, s, h, b, r, t)
        // Not waited for: a spammed address takes many pages, and the balances above shouldn't sit behind it.
        if !holdingsLoading { Task { await loadHoldings() } }
        await refreshQuote()
        updatedAt = Date()
        recordEquity()
    }

    /// Every token on the other networks, read at once and assigned together (each assignment after an await is a
    /// redraw). What the app counts elsewhere is skipped: USDC, Aave's aUSDC and the Morpho vault on Base, USDC on
    /// Arbitrum, USDG on Robinhood Chain, and ETH on Base and Robinhood (gas, counted with gasETH).
    func loadHoldings() async {
        holdingsLoading = true
        defer { holdingsLoading = false }
        let me = hlAddress, nearAccount = nearAddress, evm = isEVMAddress(hlAddress)
        // Aave's aUSDC and Morpho's vault shares off Base are read as lending positions, not as tokens.
        async let lending: Void = loadLending()
        async let base = evm ? await Holdings.evm("base", address: me, native: false, skip: [EVMRPC.baseUSDC, AaveV3.baseAUSDC, MorphoVault.gauntletUSDCPrime]) : []
        async let arbitrum = evm ? await Holdings.evm("arbitrum", address: me, native: true,
                                                      skip: [EVMRPC.arbitrumUSDC, AaveV3.arbitrum.aUSDC, MorphoVault.arbitrum.address]) : []
        async let ethereum = evm ? await Holdings.evm("ethereum", address: me, native: true, skip: [AaveV3.ethereum.aUSDC, MorphoVault.ethereum.address]) : []
        async let polygon = evm ? await Holdings.evm("polygon", address: me, native: true, skip: [AaveV3.polygon.aUSDC]) : []
        async let robinhood = evm ? await Holdings.evm("robinhood", address: me, native: false, skip: [EVMRPC.robinhoodUSDG]) : []
        async let spot = evm ? await Holdings.hyperliquidSpot(user: me) : []
        async let near = nearAccount != nil ? await Holdings.near(account: nearAccount ?? "") : []
        // A network that didn't answer keeps its tokens from the last read instead of dropping out of the total.
        let read: [(chain: String, tokens: [Holding]?)] = [("base", await base), ("arbitrum", await arbitrum), ("ethereum", await ethereum),
                                                           ("polygon", await polygon), ("robinhood", await robinhood), ("hyperliquid", await spot),
                                                           ("near", await near)]
        _ = await lending
        let found = read.flatMap { r in r.tokens ?? otherTokens.filter { $0.chain == r.chain } }
        if found != otherTokens { otherTokens = found }
    }

    /// Base balances at our EVM address and Aave's rate; quiet on errors (the rest of the portfolio still shows).
    func loadBase() async {
        guard isEVMAddress(hlAddress) else { return }
        let rpc = EVMRPC.base, me = hlAddress
        async let usdc = rpc.tokenBalance(EVMRPC.baseUSDC, owner: me)
        async let supplied = rpc.tokenBalance(AaveV3.baseAUSDC, owner: me)
        async let vault = MorphoVault.value(me, MorphoVault.base)
        async let eth = rpc.balance(me)
        async let arb = EVMRPC.arbitrum.tokenBalance(EVMRPC.arbitrumUSDC, owner: me)
        // The rates move slowly: re-read them every ten minutes, not on every refresh.
        let stale = aaveCheckedAt.map { Date().timeIntervalSince($0) > 600 } ?? true
        async let rates: (aave: Decimal?, morpho: Decimal?) = stale ? (try? await AaveV3.verify(AaveV3.base), await MorphoRates.netAPY(MorphoVault.base)) : (nil, nil)
        // Awaited first, assigned together: every assignment after an await is one more redraw of the window.
        let u = try? await usdc, a = try? await supplied, m = try? await vault, e = try? await eth, arbitrum = try? await arb, r = await rates
        if let u, let a, let e {
            let b = (usdc: Decimal(u) / 1_000_000, aave: Decimal(a) / 1_000_000, morpho: Decimal(m ?? 0) / 1_000_000,
                     eth: Decimal(e) / Decimal(sign: .plus, exponent: 18, significand: 1))
            // A tuple isn't Equatable: without this check @Observable redraws on every refresh.
            if base.map({ $0 != b }) ?? true { base = b }
        }
        if let arbitrum { arbitrumUSDC = Decimal(arbitrum) / 1_000_000 }
        if let apy = r.aave {
            aaveAPY = apy
            morphoAPY = r.morpho
            aaveCheckedAt = Date()
        }
    }

    func loadMarkets() async {
        do {
            markets = try await Hyperliquid.markets()
            marketsError = nil
            let names = Dictionary(uniqueKeysWithValues: Market.Group.allCases.map { g in (g, markets(g, limit: g == .crypto ? 25 : 30).map(\.name)) })
            if names != marketNames { marketNames = names }
        } catch {
            marketsError = error.localizedDescription
        }
    }

    func loadSolana() async {
        guard isSolanaAddress(solanaAddress) else {
            solana = nil
            solanaError = solanaAddress.isEmpty ? nil : "Check the Solana address format."
            return
        }
        // All at once, assigned together: every assignment after an await is one more redraw of the window.
        let owner = solanaAddress, nearAccount = nearAddress
        async let balance = Solana.balance(owner: owner)
        async let lendPositions = try? JupiterLend.positions(user: owner)
        async let kaminoPositions = try? Kamino.positions(wallet: owner)
        async let nearBalance = { () async -> (near: Decimal, wrapped: Decimal)? in
            guard let nearAccount else { return nil }
            return try? await Near.balance(account: nearAccount)
        }()
        do {
            let s = try await balance
            let l: [(vault: String, usdc: Decimal)] = ((await lendPositions) ?? []).filter { $0.assets > 0 }
                .map { ($0.vault, Decimal($0.assets) / 1_000_000) }
            let k = await kaminoPositions, n = await nearBalance
            solana = s
            solanaError = nil
            // Tuples aren't Equatable: without this check @Observable redraws on every refresh.
            if !l.elementsEqual(lend, by: ==) { lend = l }
            if let k { kamino = k.reduce(0) { $0 + $1.valueUSD } }
            if let n { near = n.near + n.wrapped }
        } catch {
            solana = nil
            solanaError = error.localizedDescription
        }
    }

    func loadHL() async {
        guard isEVMAddress(hlAddress) else {
            hl = nil
            hlError = hlAddress.isEmpty ? nil : "Check the address format: 0x and 40 hex characters."
            return
        }
        // All at once, assigned together: every assignment after an await is one more redraw of the window.
        let user = hlAddress
        async let balance = Hyperliquid.balance(user: user)
        async let openPositions = try? HyperliquidAccount.positions(user)
        async let openOrders = try? HyperliquidAccount.openOrders(user)
        async let vault = try? HyperliquidAccount.vaultEquity(user: user, vault: HLGuard.hlpVault)
        async let dexes = { () async -> [String: (accountValue: Decimal, withdrawable: Decimal)] in
            var out: [String: (accountValue: Decimal, withdrawable: Decimal)] = [:]
            for dex in Hyperliquid.hip3Dexes { out[dex] = try? await Hyperliquid.dexBalance(user: user, dex: dex) }
            return out
        }()
        do {
            let b = try await balance
            let p = ((await openPositions) ?? []).filter { $0.size != 0 }
            let o = (await openOrders) ?? [], v = await vault, d = await dexes
            // The week's closes are read again when the open positions changed: after the positions and their
            // notices, so a stop-out never waits on the fills request (one more redraw, only then).
            let readFills = recentlyClosed == nil || Set(positions.map(\.coin)) != Set(p.map(\.coin))
            let before = Set(positions.map(\.coin))
            let waitingEntries = Set(orders.filter { !$0.isTrigger }.map(\.coin))
            hl = b
            hlError = nil
            positions = p
            // Tuples aren't Equatable: without these checks @Observable redraws on every refresh.
            if d.count != dexBalances.count || d.contains(where: { dex, new in dexBalances[dex].map { $0 != new } ?? true }) { dexBalances = d }
            orders = o
            if let v, hlp != (v.equity, v.lockedUntil) { hlp = (v.equity, v.lockedUntil) }
            // A position that vanished while we were not closing it was closed by its stop or take.
            if !executing {
                for coin in before.subtracting(positions.map(\.coin)) { await closedByExchange(coin) }
                // A limit entry that became a position while nobody watched: it filled.
                for p in positions where !before.contains(p.coin) && waitingEntries.contains(p.coin) {
                    notify(.orders, say("Limit filled: \(IntentParser.pretty(p.coin))", "Лимитка исполнилась: \(IntentParser.pretty(p.coin))"),
                           say("\(p.size > 0 ? "Long" : "Short") \(Fmt.num(abs(p.size), maxFraction: 6)) at \(Fmt.price(p.entry)); its stop and take are on the exchange.",
                               "\(p.size > 0 ? "Лонг" : "Шорт") \(Fmt.num(abs(p.size), maxFraction: 6)) по \(Fmt.price(p.entry)); стоп и тейк стоят на бирже."),
                           schedule: "perp:\(p.coin)")
                }
            }
            // The HLP deposit's 4-day lock ended: say so once per lock.
            if let until = hlp.lockedUntil, until <= Date(), hlp.equity > 0,
               UserDefaults.standard.double(forKey: "hlpUnlockNoticed") != until.timeIntervalSince1970 {
                UserDefaults.standard.set(until.timeIntervalSince1970, forKey: "hlpUnlockNoticed")
                notify(.hlp, say("HLP unlocked", "HLP разблокирован"),
                       say("\(Fmt.usd(hlp.equity)) in the HLP vault can be withdrawn now.", "\(Fmt.usd(hlp.equity)) в хранилище HLP теперь можно вывести."))
            }
            if readFills, let fills = try? await TradeHistory.fills(user: user) {
                let week = Date().addingTimeInterval(-7 * 86400)
                recentlyClosed = TradeHistory.stories(fills).filter { ($0.closed ?? .distantPast) > week }
            }
        } catch {
            hl = nil
            hlError = error.localizedDescription
        }
    }

    /// Re-quotes only when the amount to bridge changed, or whether the Hyperliquid account exists yet.
    func refreshQuote() async {
        if atr[intent.asset] == nil, let v = try? await Hyperliquid.atrPct(coin: intent.asset) { atr[intent.asset] = v }
        let amount: Bridge.Amount? = if let a = intent.amountUSDC { .send(a) }
            else if let need = Plan.bridgeNeed(resolved.intent, evaluation, hlWithdrawable: hl.map { $0.withdrawable + (market?.dex.flatMap { dexBalances[$0]?.withdrawable } ?? 0) }) { .arrive(need) }
            else { nil }
        // A new Hyperliquid account pays a one-time opening fee on its first deposit; the plan shows it up front.
        let newAccount = if amount != nil, let evm = previewWallet?.evm { (try? await Hyperliquid.isNewAccount(evm)) ?? false } else { false }
        let key = amount.map { "\($0) \(newAccount)" }
        guard key != quotedKey else { return }
        quotedKey = key
        quote = nil
        quoteError = nil
        guard let amount else { return }
        do {
            let q = try await Bridge.dryQuote(amount, newAccount: newAccount)
            if quotedKey == key { quote = q }
        } catch {
            if quotedKey == key { quoteError = error.localizedDescription; quotedKey = nil }
        }
    }

    /// The plan again from now: balances, prices and a new bridge quote, then a fresh preparation. For a canvas that has
    /// gone stale or a preparation that failed on old numbers.
    func rerunPlan() async {
        prepared = nil
        executionError = nil
        quotedKey = nil
        await refresh()
        await prepareExecution()
    }

    func loadSigner() async {
        guard SignerClient.isAvailable, let status = try? await SignerClient().send(.status) else { return }
        // The switch first, before anything can wait: the old wallet's card, rules and positions go at once.
        signerHasWallet = status.hasWallet
        wallets = status.wallets ?? []
        if status.activeWallet != activeWalletID { walletChanged(to: status.activeWallet) }
        // A phrase wallet imported before NEAR: the signer derives the address once (one unlock), then keeps it.
        // A key wallet has no NEAR account at all. The rest is assigned together after it: every assignment after an
        // await is one more redraw of the window.
        let phrase = activeWallet?.kind ?? "phrase" == "phrase"
        let near = status.hasWallet == true && status.nearAddress == nil && phrase ? try? await SignerClient().send(.nearAddress).nearAddress : status.nearAddress
        let nearChanged = nearAddress != near
        nearAddress = near
        agentAddress = status.agentAddress
        agentActive = status.agentActive ?? false
        sessionLength = status.sessionLength ?? SignerSession.standard
        if status.hasWallet == true, status.solanaAddress != nil || status.evmAddress != nil {
            // A key wallet leaves the other chain's address empty: its balances show nothing, its commands say why.
            let solana = status.solanaAddress ?? "", evm = status.evmAddress ?? ""
            signerWallet = TradeWallet(solana: solana, evm: evm)
            // The key holder defines the wallet: balances and plans follow it.
            if solanaAddress != solana { solanaAddress = solana }
            if hlAddress.lowercased() != evm.lowercased() { hlAddress = evm }
        } else {
            signerWallet = nil
        }
        // NEAR's balance is read with Solana's.
        if nearChanged { await loadSolana() }
    }
}

func isSolanaAddress(_ s: String) -> Bool { s.wholeMatch(of: /[1-9A-HJ-NP-Za-km-z]{32,44}/) != nil }
func isEVMAddress(_ s: String) -> Bool { s.wholeMatch(of: /0x[0-9a-fA-F]{40}/) != nil }

/// Credentials per provider, as JSON, in the login Keychain of this Mac only.
nonisolated enum Keychain {
    /// ihatecrypto.app keeps its own model logins: an item made by the development build would make the
    /// signed app ask for the login password.
    static let service = Bundle.main.bundleIdentifier.map { $0 + ".llm" } ?? "app.lala.llm"

    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load(_ account: String) -> Credential? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Credential.self, from: data)
    }

    static func save(_ credential: Credential?, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let credential, let data = try? JSONEncoder().encode(credential) else { return }
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

}
