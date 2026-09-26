import AppKit
import DeFiJupiterLend
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

struct Message: Identifiable, Codable {
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

    var markets: [String: Market] = [:]
    var marketsError: String?
    var solana: Solana.Balance?
    var solanaError: String?
    var hl: Hyperliquid.Balance?
    var hlError: String?
    var quote: BridgeQuote?
    var quoteError: String?
    var updatedAt: Date?
    /// Whether the signing process holds a key; nil outside LALA.app, where there is no signer.
    var signerHasWallet: Bool?
    /// The wallet whose key the signing process holds; only then can a plan be executed.
    var signerWallet: TradeWallet?
    /// The in-app dApp browser; its wallet is the signer's.
    @ObservationIgnored let browser = Browser()
    /// The signer's Hyperliquid agent: orders without Touch ID, no withdrawals.
    var agentAddress: String?
    var agentActive = false

    // Execution
    var prepared: Executor.Prepared?
    var preparing = false
    var executing = false {
        didSet { if oldValue, !executing { lastOwnMove = Date() } }
    }
    var executionError: String?
    var planReview: JevReview?
    var txReview: JevReview?
    var jevNote: String?
    var positions: [HyperliquidAccount.Position] = []
    /// Margin balances on HIP-3 exchanges («xyz»), separate from the main one.
    var dexBalances: [String: (accountValue: Decimal, withdrawable: Decimal)] = [:]
    /// The plan last carried out; while the intent equals it, the card shows the position, not a new trade.
    var executed: TradeIntent?
    /// Regular purchases, carried out while the app is open.
    /// An allocation plan shown and waiting for «делай».
    var pendingAllocation: WalletCommand?
    /// A command the model read from another language: it waits for «do it», so a wrong reading moves nothing.
    var pendingAction: PendingAction?
    enum PendingAction { case wallet(WalletCommand), position(PositionCommand, coin: String), address(SavedAddress), transfer(SavedAddress, Decimal) }
    /// The English command the pending action was understood as, for the confirm button.
    var pendingText: String?
    /// A deposit or buy that came without an amount: the next reply that is just a number fills it.
    var awaitingAmount: WalletCommand?
    /// The «Top up LALA» board on the canvas: our addresses and how balances update.
    var showReceive = false
    /// A market's price chart on the canvas (Modules.swift).
    var chart: ChartState?
    /// The day's biggest movers on the canvas.
    var showMovers = false
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
    var equityHistory: [EquityPoint] = LocalStore.load("equity.json") ?? [] {
        didSet { LocalStore.save(equityHistory, "equity.json") }
    }
    /// Price alerts, one notification each; checked with every refresh (Alerts.swift).
    var alerts: [PriceAlert] = LocalStore.load("alerts.json") ?? [] {
        didSet { LocalStore.save(alerts, "alerts.json") }
    }
    /// Saved addresses — exchanges, other wallets — entered by hand in the address book only (AddressBook.swift).
    var addressBook: [SavedAddress] = LocalStore.load("addressbook.json") ?? [] {
        didSet { LocalStore.save(addressBook, "addressbook.json") }
    }
    /// The canvas on screen; nil for a fresh one nobody has written in yet.
    var canvasID: UUID?
    /// A reopened canvas whose board isn't a live plan: drawn as it was.
    var savedBoard: CanvasSession?
    /// The activity replies are added to.
    var currentActivity: UUID?
    /// What the user is typing in the studio chat; templates on the canvas fill it.
    var draft = ""
    /// «Spread … across the best rates» waiting for a signature, drawn on the studio canvas.
    var allocationPreview: AllocationPreview?
    /// Yields shown as bubbles on the studio canvas; nil when none.
    var yieldOptions: [Yields.Option]?
    /// The R4 layout is on (see ContentView).
    var isStudio: Bool { (UserDefaults.standard.string(forKey: "layout") ?? "studio") == "studio" }
    /// Take-profit styles offered on the canvas after «take profit like the best investors»; nil when none.
    var takeChoices: [TakeStyle]?
    var schedules: [Schedule] = (UserDefaults.standard.data(forKey: "schedules").flatMap { try? JSONDecoder().decode([Schedule].self, from: $0) }) ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(schedules), forKey: "schedules") }
    }
    /// Exit rules the app keeps for open positions (breakeven after the partial take, trailing), by coin.
    var exitRules: [String: ExitRules] = (UserDefaults.standard.data(forKey: "exitRules").flatMap { try? JSONDecoder().decode([String: ExitRules].self, from: $0) }) ?? [:] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(exitRules), forKey: "exitRules") }
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
    /// On Base, at the Hyperliquid (EVM) address: idle USDC, USDC supplied to Aave, ETH for gas.
    var base: (usdc: Decimal, aave: Decimal, eth: Decimal)?
    /// Aave v3 USDC supply APY on Base, %, read from the pool itself.
    var aaveAPY: Decimal?
    private var aaveCheckedAt: Date?
    var reviewedIntent: TradeIntent?

    init() { restoreLastCanvas() }
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
        if let v = UserDefaults.standard.string(forKey: "maxRiskPct").flatMap({ Decimal(string: $0) }) { p.maxRiskPct = v }
        return p
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(policy), forKey: "riskPolicy") }
    }
    /// 4-hour ATR per asset, % of price.
    var atr: [String: Decimal] = [:]
    var jevScreening = UserDefaults.standard.object(forKey: "jevScreening") as? Bool ?? true {
        didSet { UserDefaults.standard.set(jevScreening, forKey: "jevScreening") }
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

    func setCredential(_ credential: Credential?) {
        Keychain.save(credential, for: providerID)
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
    /// Capital the risk rules measure against: USDC on Solana, the Hyperliquid account and vaults.
    var equity: Decimal? {
        guard solana != nil || hl != nil else { return nil }
        return (solana?.usdc ?? 0) + (hl?.accountValue ?? 0) + lend.reduce(0) { $0 + $1.usdc } + dexBalances.values.reduce(0) { $0 + $1.accountValue }
            + (base.map { $0.usdc + $0.aave } ?? 0)
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
            reply("That looks like a recovery phrase. I don’t show it, store it or send it anywhere. Import a phrase in its own window.")
            return
        }
        messages.append(Message(fromUser: true, text: text))
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
            reply("This looks like an attempt to steer the assistant or swap an address. " + screen.problems.joined(separator: " ")
                  + " The message was not passed to the model and changed nothing."
                  + (pastedAddress ? " To keep an address, save it in Addresses — the book button in the rail." : ""),
                  note: classifier == nil ? "guard: local rules" : "guard: rules and Jev")
            return
        }
        let before = intent

        // «делай» / «do it» right after a plan that waits for it carries it out; anything else drops it.
        let confirms = text.lowercased().contains(/^(?:делай|да|давай|подтверждаю|раскладывай|го|do\s+it|go|yes|confirm|sign)\b/)
        if let pending = pendingAllocation {
            pendingAllocation = nil
            if confirms { await move(pending, confirmed: true); return }
        }
        let declines = text.lowercased().wholeMatch(of: /\s*(?:no|nope|cancel|stop|нет|не\s+надо|отмена|отмени\w*|стоп|nein|abbrechen|non|annuler|cancelar|não|nao|nie|anuluj)[.!\s]*/) != nil
        if let pending = pendingAction {
            pendingAction = nil
            pendingText = nil
            if declines {
                reply("Cancelled — nothing moved.")
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
                reply("OK, not doing that.")
                return
            }
            if let value = WalletCommand.amountAnswer(text) {
                awaitingAmount = nil
                await handleWallet(waiting.with(amount: value))
                return
            }
            if text.lowercased().wholeMatch(of: /\s*(?:да|yes|yep|ok|okay|давай|угу|sure|go)[.!\s]*/) != nil {
                reply("How much? Just the number, for example “1”.")
                return
            }
            awaitingAmount = nil
        }
        if text.lowercased().wholeMatch(of: /\s*(?:делай|да|давай|подтверждаю|го|do\s+it|go|yes|yep|ok|okay|confirm|sign)[.!\s]*/) != nil {
            reply("Nothing is waiting for a confirmation right now. Tell me what to do — for example “deposit 1 USDC into Jupiter”.")
            return
        }
        takeChoices = nil
        yieldOptions = nil
        if pendingAllocation == nil { allocationPreview = nil }
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
            reply("The plan is cleared. Tell me what to do next.")
            return
        }
        if text.lowercased().wholeMatch(of: /\s*(?:lock|lock\s+(?:it|the\s+wallet|signing)|заблокируй\w*|блокир\w*)\s*[.!]?\s*/) != nil {
            await lockSigner()
            return
        }
        if text.lowercased().contains(/(?:resume|unpause|turn\s+on|включи|верни)\s+(?:the\s+)?(?:trading\s+key|торгов\w*\s+ключ)/) {
            await resumeTradingKey()
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
        let client = llmClient()
        let confident = parsed != nil && (client == nil || (!IntentParser.needsModel(text) && IntentParser.hasTradeWords(text)))
        if let next = parsed, confident {
            if await editExecuted(from: before, to: next) { return }
            intent = next
            let changes = next.changes(from: before)
            await refreshQuote()
            reply((changes.isEmpty ? "That’s already in the plan." : "Plan updated: " + changes.joined(separator: ", ") + ".") + outcomeLine)
        } else if let client {
            // Another language or wording the parsers don't know: the model rewrites it as one English command,
            // which then goes through the same parsers. The reply says how it was understood.
            if !IntentParser.hasTradeWords(text) || parsed == nil, await runNormalized(text, client: client, before: before) { return }
            // No plan and nothing about trading: the plan editor would only invent one.
            guard startsPlan || IntentParser.hasTradeWords(text) else {
                reply(Self.help)
                return
            }
            busy = true
            defer { busy = false }
            let note = "\(model) · \(provider.info.name)"
            do {
                let (next, answer) = try await ChatModel.edit(intent, message: text, client: client, model: model, history: recentChat())
                if let next, await editExecuted(from: before, to: next) { return }
                if let next { intent = next }
                let changes = next?.changes(from: before) ?? []
                let fallback = changes.isEmpty ? "The model changed nothing." : "Plan updated: " + changes.joined(separator: ", ") + "."
                await refreshQuote()
                reply((answer.isEmpty ? fallback : answer) + outcomeLine, note: note)
            } catch {
                reply("The model is unavailable: \(error.localizedDescription)", note: note)
            }
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

    /// Runs the model's English rewrite of `text` through the parsers. False when it is not a command they know.
    private func runNormalized(_ text: String, client: any LLMClient, before: TradeIntent) async -> Bool {
        busy = true
        let canonical = try? await CommandNormalizer.normalize(text, client: client, model: model,
                                                              context: messages.last(where: { !$0.fromUser })?.text)
        busy = false
        guard let canonical, canonical.lowercased() != text.lowercased() else { return false }
        updateActivity { $0.understood = canonical }
        let note = "understood as “\(canonical)” · \(model)"
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
            await handleWallet(command, note: note, confirmAlways: true)
            return true
        }
        if let coin = targetCoin(for: canonical), let command = PositionCommand.parse(canonical) {
            pendingAction = .position(command, coin: coin)
            pendingText = canonical
            reply("Understood as “\(canonical)” for \(IntentParser.pretty(coin)). Say “do it” or press Confirm to go ahead.", note: note)
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

    /// «На стопе −$0,99 (−6,8% капитала), на тейке +$1,90 (+13%), 1:1,9» after every plan change.
    var outcomeLine: String {
        // In the studio the Result block on the canvas says this; the chat doesn't repeat it.
        if isStudio { return "" }
        guard let s = evaluation.sizing else { return "" }
        func share(_ v: Decimal) -> String { equity.map { $0 > 0 ? " (\(Fmt.pct((v / $0 * 100).rounded(1, .plain))) of capital)" : "" } ?? "" }
        var line = "\nAt the stop −\(Fmt.usd(s.lossAtStopUSD))\(share(s.lossAtStopUSD))"
        if let p = s.profitAtTakeUSD, s.lossAtStopUSD > 0 {
            line += ", at the take +\(Fmt.usd(p))\(share(p)), reward/risk 1:\(Fmt.num((p / s.lossAtStopUSD).rounded(1, .plain)))"
        }
        return line + "."
    }

    func reply(_ text: String, note: String? = nil) {
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
        _ = await (m, s, h, b)
        await refreshQuote()
        updatedAt = Date()
        recordEquity()
    }

    /// Base balances at our EVM address and Aave's rate; quiet on errors (the rest of the portfolio still shows).
    func loadBase() async {
        guard isEVMAddress(hlAddress) else { return }
        let rpc = EVMRPC.base, me = hlAddress
        async let usdc = rpc.tokenBalance(EVMRPC.baseUSDC, owner: me)
        async let supplied = rpc.tokenBalance(AaveV3.baseAUSDC, owner: me)
        async let eth = rpc.balance(me)
        if let u = try? await usdc, let a = try? await supplied, let e = try? await eth {
            base = (Decimal(u) / 1_000_000, Decimal(a) / 1_000_000, Decimal(e) / Decimal(sign: .plus, exponent: 18, significand: 1))
        }
        // The rate moves slowly: re-read it every ten minutes, not on every refresh.
        if aaveCheckedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true, let apy = try? await AaveV3.verifyBase(rpc) {
            aaveAPY = apy
            aaveCheckedAt = Date()
        }
    }

    func loadMarkets() async {
        do {
            markets = try await Hyperliquid.markets()
            marketsError = nil
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
        do {
            solana = try await Solana.balance(owner: solanaAddress)
            solanaError = nil
            lend = ((try? await JupiterLend.positions(user: solanaAddress)) ?? []).filter { $0.assets > 0 }
                .map { ($0.vault, Decimal($0.assets) / 1_000_000) }
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
        do {
            hl = try await Hyperliquid.balance(user: hlAddress)
            hlError = nil
            let before = Set(positions.map(\.coin))
            positions = ((try? await HyperliquidAccount.positions(hlAddress)) ?? []).filter { $0.size != 0 }
            for dex in Hyperliquid.hip3Dexes { dexBalances[dex] = try? await Hyperliquid.dexBalance(user: hlAddress, dex: dex) }
            // A position that vanished while we were not closing it was closed by its stop or take.
            if !executing {
                for coin in before.subtracting(positions.map(\.coin)) { await closedByExchange(coin) }
            }
            orders = (try? await HyperliquidAccount.openOrders(hlAddress)) ?? []
        } catch {
            hl = nil
            hlError = error.localizedDescription
        }
    }

    /// Re-quotes only when the amount to bridge changed.
    func refreshQuote() async {
        if atr[intent.asset] == nil, let v = try? await Hyperliquid.atrPct(coin: intent.asset) { atr[intent.asset] = v }
        let amount: Bridge.Amount? = if let a = intent.amountUSDC { .send(a) }
            else if let need = Plan.bridgeNeed(resolved.intent, evaluation, hlWithdrawable: hl.map { $0.withdrawable + (market?.dex.flatMap { dexBalances[$0]?.withdrawable } ?? 0) }) { .arrive(need) }
            else { nil }
        let key = amount.map { "\($0)" }
        guard key != quotedKey else { return }
        quotedKey = key
        quote = nil
        quoteError = nil
        guard let amount else { return }
        do {
            let q = try await Bridge.dryQuote(amount)
            if quotedKey == key { quote = q }
        } catch {
            if quotedKey == key { quoteError = error.localizedDescription; quotedKey = nil }
        }
    }

    func loadSigner() async {
        guard SignerClient.isAvailable, let status = try? await SignerClient().send(.status) else { return }
        signerHasWallet = status.hasWallet
        agentAddress = status.agentAddress
        agentActive = status.agentActive ?? false
        if status.hasWallet == true, let solana = status.solanaAddress, let evm = status.evmAddress {
            signerWallet = TradeWallet(solana: solana, evm: evm)
            // The key holder defines the wallet: balances and plans follow it.
            if solanaAddress != solana { solanaAddress = solana }
            if hlAddress.lowercased() != evm.lowercased() { hlAddress = evm }
        } else {
            signerWallet = nil
        }
    }
}

func isSolanaAddress(_ s: String) -> Bool { s.wholeMatch(of: /[1-9A-HJ-NP-Za-km-z]{32,44}/) != nil }
func isEVMAddress(_ s: String) -> Bool { s.wholeMatch(of: /0x[0-9a-fA-F]{40}/) != nil }

/// Credentials per provider, as JSON, in the login Keychain of this Mac only.
nonisolated enum Keychain {
    /// LALA.app keeps its own model logins: an item made by the development build would make the
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
