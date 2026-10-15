import AppKit
import EVMChain
import IhatecryptoCore
import SignerAPI
import SwiftUI
import TradeExecution

/// The automation wallet's USDC: the Schedule's budget, wherever it lies — Solana, every EVM network ihatecrypto knows
/// (one address for all of them; USDG on Robinhood Chain) and NEAR.
struct AutomationBudget: Equatable {
    var solana: Decimal?
    /// SOL on Solana: what its fees and new accounts are paid with.
    var sol: Decimal?
    /// By EVMNetwork.key; a network that didn't answer is missing.
    var evm: [String: Decimal] = [:]
    var near: Decimal?
    /// Its other tokens on Solana that look real (USDT…): money on it, not the budget, which is USDC.
    var tokens: [Holding] = []
    var evmTotal: Decimal { evm.values.reduce(0, +) }
    var total: Decimal { (solana ?? 0) + evmTotal + (near ?? 0) }
}

/// What the Schedule lists: a scheduled task, a recurring buy or an open perp, by its key (Activity.schedule).
struct ScheduleEntry: Identifiable {
    let id: String
    let title: String
    let when: String
    let next: Date?
    let paused: Bool
    let logo: String?
    let icon: String
    /// «every day», «once»; nil for a perp.
    var every: String?
}

/// Who signs an item's runs, as its mark on the Schedule says.
enum ScheduleSigner {
    case itself, touchID, confirm, ledger, exchange

    var icon: String {
        switch self {
        case .itself: "bolt"
        case .touchID: "touchid"
        case .confirm: "hand.tap"
        case .ledger: "lock.shield"
        case .exchange: "chart.line.uptrend.xyaxis"
        }
    }

    var words: String {
        switch self {
        case .itself: "runs by itself"
        case .touchID: "asks Touch ID"
        case .confirm: "waits for Confirm"
        case .ledger: "asks your Ledger"
        case .exchange: "on the exchange"
        }
    }

    var tint: Color { self == .itself || self == .exchange ? .secondary : Brand.jevInk }
}

extension ScheduledTask {
    /// A step that moves money: without the automation wallet it waits for Confirm and Touch ID.
    var movesMoney: Bool {
        steps.contains { step in
            switch WalletCommand.parse(step) {
            case nil, .yields?, .receive?, .schedule?, .stopSchedules?: false
            default: true
            }
        }
    }
}

/// A run's time as the Schedule says it, in Gregorian dates whatever the Mac's calendar is: «Today 9:00 PM · in 6 h».
enum NextRun {
    static var style: Date.FormatStyle {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return Date.FormatStyle(locale: Locale(identifier: "en_US"), calendar: c)
    }

    static var calendar: Calendar { style.calendar }

    /// «Today 9:00 PM», «Tomorrow 2:39 AM», «Sun 9:00 AM» within the week, «Nov 1, 9:00 AM» after it; «Now» once due.
    static func when(_ d: Date, now: Date = Date()) -> String {
        guard d > now else { return "Now" }
        let cal = calendar, time = d.formatted(style.hour().minute())
        if cal.isDate(d, inSameDayAs: now) { return "Today \(time)" }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "Tomorrow \(time)" }
        if d.timeIntervalSince(now) < 6 * 86_400 { return "\(d.formatted(style.weekday(.abbreviated))) \(time)" }
        return "\(d.formatted(style.month(.abbreviated).day())), \(time)"
    }

    /// «in 12 min», «in 6 h» («in 6 h 12 min» when `exact`), «in 3 d»; nil once due.
    static func until(_ d: Date, now: Date = Date(), exact: Bool = false) -> String? {
        let m = Int((d.timeIntervalSince(now) / 60).rounded(.up))
        guard m > 0 else { return nil }
        if m < 60 { return "in \(m) min" }
        let h = m / 60
        if h < 48 { return exact && m % 60 > 0 ? "in \(h) h \(m % 60) min" : "in \(h) h" }
        return "in \(h / 24) d"
    }
}

extension Workspace {
    var automationWallet: SignerWallet? { wallets.first(where: \.isAutomation) }

    /// Tasks and recurring buys by their next run, then the perps (their stops sit on the exchange).
    var scheduleEntries: [ScheduleEntry] {
        let dated = tasks.map { t in
            ScheduleEntry(id: "task:\(t.id)", title: t.steps.map(ScheduleCanvas.readable).joined(separator: " → "), when: t.when, next: t.next,
                          paused: t.paused == true, logo: nil, icon: t.every == nil ? "calendar.badge.clock" : "repeat",
                          every: t.every.map { "every \($0.words)" } ?? "once")
        } + schedules.map { b in
            ScheduleEntry(id: "buy:\(b.symbol)", title: "Buy \(b.symbol) for \(Fmt.usd(b.usdc))", when: "every \(ScheduleCanvas.period(b.days)) · next \(Fmt.date(b.next))",
                          next: b.next, paused: b.paused == true, logo: b.symbol.lowercased(), icon: "cart", every: "every \(ScheduleCanvas.period(b.days))")
        }
        return dated.sorted { ($0.next ?? .distantFuture) < ($1.next ?? .distantFuture) } + positions.map { p in
            ScheduleEntry(id: "perp:\(p.coin)", title: "\(p.size > 0 ? "Long" : "Short") \(IntentParser.pretty(p.coin))", when: "stop and take on the exchange",
                          next: nil, paused: false, logo: nil, icon: "chart.line.uptrend.xyaxis")
        }
    }

    /// A task runs by itself from the automation wallet (or moves nothing); without it its moves wait for Confirm. A
    /// recurring buy is signed by the wallet that's on: Touch ID, its Ledger, or nothing on a test wallet.
    func signer(_ key: String) -> ScheduleSigner {
        if key.hasPrefix("perp:") { return .exchange }
        if let t = tasks.first(where: { "task:\($0.id)" == key }) {
            if !t.movesMoney || (t.untrusted != true && automationWallet != nil) { return .itself }
            return ledgerActive ? .ledger : activeWallet?.isTest == true ? .confirm : .touchID
        }
        return ledgerActive ? .ledger : activeWallet?.isTest == true ? .itself : .touchID
    }

    /// What the recurring buys take from the budget in a week.
    // ponytail: buys only; a task's own money moves aren't priced, add them when tasks carry amounts.
    var weeklyBudgetSpend: Decimal {
        schedules.filter { $0.paused != true }.reduce(0) { $0 + $1.usdc * 7 / Decimal(max(1, $1.days)) }
    }

    /// The scheduled item the open canvas shows, when it's one's own canvas.
    var currentScheduleKey: String? { canvasID.flatMap { id in canvases.first { $0.id == id }?.schedule } }

    /// A scheduled item opens on a canvas of its own, like a chat: made the first time, then the same one, in the list
    /// with the others. Its card is there, and the chat on it can change it.
    func openScheduleCanvas(_ key: String) {
        scheduleItem = key
        if currentScheduleKey == nil { scheduleReturn = canvasID }
        // Switching canvases closes the boards; the Schedule frame stays open, so the next item is one click away.
        // Nothing moves on its own: the view stays where the user left it («при закрывании ничего не двигалось»), and what
        // the rail or a click opened beside it — the Schedule frame, a token's or a place's board — stays open
        // («нажимаю на клоуз где скедуал, то оно закрывает и токен»).
        let frame = showSchedule, place = detail
        keepViewport = true
        defer { showSchedule = frame; detail = place; keepViewport = false }
        if let c = canvases.first(where: { $0.schedule == key }) {
            if c.id != canvasID { openCanvas(c) }
            return
        }
        guard canSwitchCanvas else { return }
        // Only the greeting, as on every canvas: the item is its card, not a message.
        var c = CanvasSession(providerID: providerID, model: model, messages: Array(messages.prefix(1)), intent: TradeIntent())
        c.title = scheduleEntries.first { $0.id == key }?.title ?? "Scheduled"
        c.schedule = key
        canvases.insert(c, at: 0)
        openCanvas(c)
    }

    /// A run's canvas from the Schedule's history: as an item's, the frame and the view stay where they were. A plain
    /// switch closed the frame and refitted the view («нажимаю на кнопку и перекидывает канвас куда-то», 2026-10-15).
    func openRunCanvas(_ c: CanvasSession) {
        let frame = showSchedule, place = detail
        keepViewport = true
        defer { showSchedule = frame; detail = place; keepViewport = false }
        openCanvas(c)
    }

    /// Closes an item's canvas: back to the canvas it was opened from (or a new one). Nothing written on it, it was only a
    /// view of the item and leaves the list; the Schedule frame opens it again.
    func closeScheduleCanvas() {
        guard let id = canvasID, let c = canvases.first(where: { $0.id == id }), c.schedule != nil, canSwitchCanvas else { return }
        let frame = showSchedule, place = detail
        keepViewport = true
        defer { showSchedule = frame; detail = place; keepViewport = false }
        if let back = scheduleReturn.flatMap({ r in canvases.first { $0.id == r && $0.schedule == nil } }) { openCanvas(back) } else { newCanvas() }
        if !c.messages.contains(where: \.fromUser) { canvases.removeAll { $0.id == id } }
    }

    /// «Run now»: due at once; the watch loop runs it within half a minute, on a canvas of its own like any run, without
    /// waiting for the user to step away. A repeating one keeps its next run after it (TaskRun.kept).
    func runScheduledNow(_ key: String) {
        if let i = tasks.firstIndex(where: { "task:\($0.id)" == key }) {
            if tasks[i].every != nil, tasks[i].next > Date() { TaskRun.kept[key] = tasks[i].next }
            tasks[i].next = Date()
            TaskRun.now.insert(key)
        }
        if let i = schedules.firstIndex(where: { "buy:\($0.symbol)" == key }) {
            if schedules[i].next > Date() { TaskRun.kept[key] = schedules[i].next }
            schedules[i].next = Date()
        }
    }

    func setPaused(_ id: String, _ paused: Bool) {
        if let i = tasks.firstIndex(where: { "task:\($0.id)" == id }) { tasks[i].paused = paused ? true : nil }
        if let i = schedules.firstIndex(where: { "buy:\($0.symbol)" == id }) { schedules[i].paused = paused ? true : nil }
    }

    /// Off the schedule for good; what it ran stays in the history.
    func removeScheduled(_ id: String) {
        tasks.removeAll { "task:\($0.id)" == id }
        schedules.removeAll { "buy:\($0.symbol)" == id }
    }

    func loadAutomationBudget() async {
        guard let w = automationWallet else { automationBudget = nil; return }
        async let sol = Self.solanaBalance(w.solana)
        async let evm = Self.evmUSDC(w.evm)
        async let near = Self.nearUSDC(w.near)
        let solana = await sol
        let budget = AutomationBudget(solana: solana?.usdc, sol: solana?.sol, evm: await evm, near: await near,
                                      tokens: solana?.tokens.filter(\.looksReal) ?? [])
        if budget != automationBudget { automationBudget = budget }
    }

    private static func solanaBalance(_ address: String?) async -> Solana.Balance? {
        guard let address else { return nil }
        return try? await Solana.balance(owner: address)
    }

    /// USDC (USDG on Robinhood Chain) at the one EVM address, on every network at once.
    private static func evmUSDC(_ address: String?) async -> [String: Decimal] {
        guard let address, isEVMAddress(address) else { return [:] }
        return await withTaskGroup(of: (String, Decimal?).self) { group in
            for n in EVMNetwork.all {
                group.addTask { (n.key, (try? await n.usdcBalance(address)).map { Decimal($0) / 1_000_000 }) }
            }
            var out: [String: Decimal] = [:]
            for await (key, usdc) in group { if let usdc { out[key] = usdc } }
            return out
        }
    }

    /// Circle's USDC on NEAR, at the wallet's implicit account.
    static let nearUSDCContract = "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1"
    private static func nearUSDC(_ account: String?) async -> Decimal? {
        guard let account, let tokens = await Holdings.near(account: account) else { return nil }
        return tokens.first { $0.contract == nearUSDCContract }?.amount ?? 0
    }

    /// «Top up»: the transfer typed into the chat with its amount selected to type over — nothing is sent until the user
    /// sends the line; meanwhile TopUpBalances shows what it comes from. The card then waits for Confirm and Touch ID.
    func suggestTopUp(_ amount: Decimal = 20) {
        guard let w = automationWallet else { return }
        // «on Solana»: the wallet is saved on Solana and Base too, and without it the chat asked which one. No SOL on it
        // yet: its fees go along in the same chain, or its first task fails on them.
        let gas = (automationBudget?.sol ?? 0) < TaskRun.solFloor ? ", then send 0.01 SOL to \(w.label) on Solana" : ""
        suggest("send \(Fmt.num(amount)) USDC to \(w.label) on Solana" + gas, select: Fmt.num(amount))
    }

    /// The draft is a top-up of the automation wallet: its amount.
    var topUpDraft: Decimal? {
        guard let w = automationWallet, let m = draft.wholeMatch(of: /send\s+(\d+(?:\.\d+)?)\s+USDC\s+to\s+(.+?)(?:\s+on\s+solana)?(?:,\s*then\s+send\s+[\d.]+\s+SOL\s+to\s+.+)?/.ignoresCase()),
              String(m.2).lowercased() == w.label.lowercased() else { return nil }
        return Decimal(string: String(m.1))
    }
}

/// The Schedule on the canvas, beside the portfolio: the automation wallet's budget, then three tabs — the tasks with a
/// switch each and one to pause them all, what ran, and the wallet with its addresses.
struct ScheduleFrame: View {
    @Environment(Workspace.self) private var ws
    @State private var tab = Tab.tasks
    static let width: CGFloat = 320

    enum Tab: String, CaseIterable { case tasks = "Tasks", history = "History", wallet = "Wallet" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("SCHEDULE").font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Text(ws.schedulePaused ? "paused" : KeepRunning.isOn ? "always running" : "while the app is open")
                    .font(.ui(10)).foregroundStyle(ws.schedulePaused ? Brand.loss : .secondary)
                Spacer()
                Button { withAnimation(StudioView.spring) { ws.showSchedule = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.hoverIcon).help("Close").accessibilityLabel("Close the Schedule")
            }
            budget
            HStack(spacing: 3) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue).font(.ui(12, .semibold)).foregroundStyle(tab == t ? Color.primary : .secondary)
                            .frame(maxWidth: .infinity).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 9).fill(tab == t ? Brand.card : .clear).shadow(color: .black.opacity(tab == t ? 0.08 : 0), radius: 2, y: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(LitBlock(radius: 9))
                }
            }
            .padding(3).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
            switch tab {
            case .tasks: tasks
            case .history: history
            case .wallet: wallet
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 26).fill(Brand.card).shadow(color: .black.opacity(0.08), radius: 18, y: 10))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Brand.cardBorder))
        .task(id: ws.automationWallet?.id) {
            while !Task.isCancelled {
                await ws.loadAutomationBudget()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: The budget

    @ViewBuilder private var budget: some View {
        if ws.automationWallet == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Run tasks by themselves, without Touch ID?").font(.ui(13, .bold))
                Text("An automation wallet holds the Schedule’s budget and signs its tasks. Your main wallet keeps Touch ID.")
                    .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { Task { await ws.createAutomationWallet() } } label: { Label("Create an automation wallet", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(Brand.accent).controlSize(.small).pointerStyle(.link)
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 16).fill(Brand.accent.opacity(0.1)))
        } else {
            let total = ws.automationBudget?.total
            let spend = ws.weeklyBudgetSpend
            // Whole weeks: 20 / 3 unrounded read as 0 («not enough for the next run»).
            let weeks = total.flatMap { t in spend > 0 ? NSDecimalNumber(decimal: (t / spend).rounded(0, .down)).intValue : nil }
            VStack(alignment: .leading, spacing: 6) {
                // All the money on it, in dollars: «0 USDC» read as empty while 25 USDT lay there (the owner, 2026-10-15).
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ws.automationUSD.map(Fmt.usd) ?? total.map { "\(Fmt.num($0)) USDC" } ?? "…").font(.ui(24, .heavy)).monospacedDigit()
                    Text("budget").font(.ui(11)).foregroundStyle(.secondary)
                }
                if let b = ws.automationBudget, !b.tokens.isEmpty {
                    Text(b.tokens.map { "\(Fmt.num($0.amount)) \($0.symbol)" }.joined(separator: ", ") + " on Solana · \(Fmt.num(b.total)) USDC")
                        .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let weeks {
                    Text(weeks >= 4 ? "covers the next 4 weeks" : weeks == 0 ? "not enough for the next run" : "covers \(weeks) week\(weeks == 1 ? "" : "s")")
                        .font(.ui(11, .semibold)).foregroundStyle(weeks == 0 ? Brand.loss : Brand.profit)
                    HStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { i in Capsule().fill(i < weeks ? Brand.profit : Color.primary.opacity(0.1)).frame(height: 5) }
                    }
                }
                // USDC on Solana but next to no SOL: every move there fails on the fee or a new account's rent.
                if let w = ws.automationWallet, let b = ws.automationBudget, let sol = b.sol, sol < TaskRun.solFloor, (b.solana ?? 0) > 0 || !b.tokens.isEmpty {
                    HStack(spacing: 8) {
                        Text("\(Fmt.num(sol, maxFraction: 6)) SOL for Solana’s fees: too little, its tasks there fail.")
                            .font(.ui(11, .semibold)).foregroundStyle(Brand.loss).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button { Task { await ws.send("send 0.01 SOL to \(w.label) on Solana") } } label: { Label("Send 0.01 SOL", systemImage: "plus").font(.ui(11.5, .bold)) }
                            .buttonStyle(.bordered).controlSize(.small).pointerStyle(.link)
                            .help("From your main wallet: the card waits for Confirm and Touch ID")
                    }
                }
                // Nothing on it: the way to put the budget there — the button puts it in the chat.
                if total == 0 {
                    Button { ws.suggestTopUp() } label: {
                        Label("Top up 20 USDC", systemImage: "plus").font(.ui(13, .bold)).frame(maxWidth: .infinity).frame(height: 34)
                    }
                    .buttonStyle(LitBlock(radius: 12)).foregroundStyle(Brand.onAccent)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Brand.accent))
                    .help("Puts it in the chat with the amount to change; nothing goes until you send it")
                }
            }
        }
    }

    // MARK: Tasks

    @ViewBuilder private var tasks: some View {
        let entries = ws.scheduleEntries
        VStack(alignment: .leading, spacing: 6) {
            if !entries.isEmpty {
                Button { ws.schedulePaused.toggle() } label: {
                    Label(ws.schedulePaused ? "Resume schedule" : "Pause schedule", systemImage: ws.schedulePaused ? "play.fill" : "pause.fill")
                        .font(.ui(12.5, .bold)).frame(maxWidth: .infinity).frame(height: 34)
                }
                .buttonStyle(LitBlock(radius: 12))
                .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ws.schedulePaused ? Brand.accent : Brand.cardBorder))
                .help(ws.schedulePaused ? "Everything scheduled runs again" : "Nothing scheduled runs until you resume; stops and takes stay on the exchange")
            }
            ForEach(entries) { e in row(e) }
            if entries.isEmpty {
                Text("Nothing scheduled. Say it in the chat, in any words:").font(.ui(11)).foregroundStyle(.secondary)
            }
            Flow(spacing: 6) {
                ForEach(["every week: rebalance USDC", "every day at 09:00: what's moving"], id: \.self) { e in
                    Button { ws.suggest(e) } label: {
                        Label(e, systemImage: "text.bubble").font(.ui(11, .medium)).padding(.horizontal, 9).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(Brand.cardBorder))
                    }
                    .buttonStyle(LitBlock(radius: 14)).help("Put it in the chat")
                }
            }
        }
    }

    private func row(_ e: ScheduleEntry) -> some View {
        HStack(spacing: 10) {
            DateTile(date: e.next, icon: e.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.ui(12.5, .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                NextLine(entry: e)
            }
            Spacer(minLength: 4)
            SignerMark(signer: ws.signer(e.id))
            if !e.id.hasPrefix("perp:") {
                Toggle("", isOn: Binding(get: { !e.paused }, set: { on in ws.setPaused(e.id, !on) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help(e.paused ? "Paused: switch on to run it again" : "Switch off to pause it")
                    .accessibilityLabel("\(e.paused ? "Resume" : "Pause") \(e.title)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.03)))
        // Lit while its canvas is the open one: closed, or another canvas opened, the row goes back to plain.
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ws.currentScheduleKey == e.id ? Brand.accent : Brand.cardBorder))
        .opacity(e.paused || ws.schedulePaused ? 0.55 : 1)
        .contentShape(Rectangle())
        // Its own canvas: steps, runs, Pause and Delete, and the chat to change it.
        .modifier(HoverLift(radius: 14)).onTapGesture { ws.openScheduleCanvas(e.id) }
        .contextMenu {
            if !e.id.hasPrefix("perp:") { Button("Delete", role: .destructive) { ws.removeScheduled(e.id) } }
        }
    }

    // MARK: History

    @ViewBuilder private var history: some View {
        let runs = Array(ws.activities.reversed().lazy.filter { $0.schedule != nil }.prefix(30))
        let days = Dictionary(grouping: runs) { Calendar.current.startOfDay(for: $0.at) }.sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: 4) {
            if runs.isEmpty {
                Text("Nothing ran yet. Each run shows here with its time.").font(.ui(11)).foregroundStyle(.secondary)
            }
            ForEach(days, id: \.key) { day, items in
                Text(Calendar.current.isDateInToday(day) ? "TODAY" : Calendar.current.isDateInYesterday(day) ? "YESTERDAY" : Fmt.date(day).uppercased())
                    .font(.ui(10, .semibold)).tracking(1).foregroundStyle(.secondary).padding(.top, 6)
                ForEach(items) { a in historyRow(a) }
            }
        }
    }

    private func historyRow(_ a: Activity) -> some View {
        let failed = a.failed == true || a.bubbles.contains { $0.status == "failed" }
        let title = (a.title ?? a.request ?? "ihatecrypto").replacingOccurrences(of: "Scheduled: ", with: "").replacingOccurrences(of: "По расписанию: ", with: "")
        return HStack(spacing: 8) {
            Text(a.at.formatted(date: .omitted, time: .shortened)).font(.ui(10.5)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(failed ? Brand.loss : Brand.profit).font(.system(size: 13))
            // What it said, on the title only: on the row it covered the button's own tooltip.
            Text(title).font(.ui(12, .medium)).lineLimit(1).help(a.lines.last ?? title)
            Spacer(minLength: 2)
            if let id = a.canvas, let c = ws.canvases.first(where: { $0.id == id }) {
                Button { ws.openRunCanvas(c) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.hoverIcon).help("Open the canvas it ran on").accessibilityLabel("Open its canvas")
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Wallet

    @ViewBuilder private var wallet: some View {
        if let w = ws.automationWallet {
            let b = ws.automationBudget
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    if let sol = w.solana, let qr = QR.image(sol) {
                        VStack(spacing: 3) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 104, height: 104)
                                .padding(6).background(RoundedRectangle(cornerRadius: 12).fill(.white))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.cardBorder))
                                .accessibilityLabel("QR code of the automation wallet’s Solana address")
                            Text("Solana").font(.ui(10)).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Send USDC here on Solana, any EVM network below or NEAR").font(.ui(11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let sol = w.solana { CopyButton(title: "Copy Solana", text: sol, help: "Copy the Solana address") }
                        if let evm = w.evm { CopyButton(title: "Copy EVM", text: evm, help: "Copy the EVM address: the same on \(Self.evmNames)") }
                        if let near = w.near { CopyButton(title: "Copy NEAR", text: near, help: "Copy the NEAR account") }
                    }
                }
                if let sol = w.solana { addressRow(["sol"], sol, b?.solana) }
                if let evm = w.evm {
                    // The same address on every one of them; where money is, how much.
                    let held = EVMNetwork.all.compactMap { n in b?.evm[n.key].flatMap { $0 >= Decimal(string: "0.01")! ? "\(n.name) \(Fmt.num($0)) \(n.key == "robinhood" ? "USDG" : "USDC")" : nil } }
                    addressRow(EVMNetwork.all.compactMap { ModuleNetwork(rawValue: $0.key)?.logo }, evm, b?.evmTotal,
                               ["Same address on \(Self.evmNames)"] + (held.isEmpty ? [] : [held.joined(separator: " · ")]))
                }
                if let near = w.near { addressRow(["near"], near, b?.near) }
                Button { ws.suggestTopUp() } label: { Label("Top up 20 USDC", systemImage: "plus").font(.ui(12.5, .bold)).frame(maxWidth: .infinity).frame(height: 32) }
                    .buttonStyle(LitBlock(radius: 12)).background(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.cardBorder))
                    .help("Puts it in the chat with the amount to change; nothing goes until you send it")
                Text("Sent it on another network? The assistant can move it to any other network for you: just ask in the chat.")
                    .font(.ui(10.5, .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("Signs scheduled tasks only, under the same checks. Its key lives in this Mac’s keychain.")
                    .font(.ui(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("No automation wallet yet: create it above, then its addresses show here.").font(.ui(11)).foregroundStyle(.secondary)
        }
    }

    /// «Base, Arbitrum, Robinhood Chain, Polygon, Ethereum and Tempo».
    static var evmNames: String {
        let names = EVMNetwork.all.map(\.name)
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    /// One address: its network's logo (every EVM network's for the EVM one), its ends, the USDC on it, a line or two.
    private func addressRow(_ logos: [String], _ address: String, _ usdc: Decimal?, _ lines: [String] = []) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: logos.count > 1 ? -4 : 0) { ForEach(logos, id: \.self) { TokenLogo(name: $0, size: logos.count > 1 ? 15 : 18) } }
                Text(Self.short(address)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(usdc.map { "\(Fmt.num($0)) USDC" } ?? "…").font(.ui(12, .semibold)).monospacedDigit().fixedSize()
            }
            ForEach(lines, id: \.self) { Text($0).font(.ui(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
        .help(address)
    }

    static func short(_ address: String) -> String { address.count > 14 ? "\(address.prefix(6))…\(address.suffix(6))" : address }
}

/// A run's day as a calendar leaf: the month on a strip (orange when it's today), the day under it, on a big one the
/// weekday too. Without a date (a perp), its icon.
struct DateTile: View {
    let date: Date?
    var icon = "calendar"
    var big = false
    var now = Date()

    var body: some View {
        let r: CGFloat = big ? 14 : 8
        VStack(spacing: 0) {
            if let date {
                let today = date <= now || NextRun.calendar.isDate(date, inSameDayAs: now)
                Text(date.formatted(NextRun.style.month(.abbreviated)).uppercased()).font(.ui(big ? 11 : 9, .bold)).tracking(0.8)
                    .foregroundStyle(today ? Brand.onAccent : .white)
                    .frame(maxWidth: .infinity).frame(height: big ? 20 : 14)
                    .background(today ? Brand.accent : Self.strip)
                Text(date.formatted(NextRun.style.day())).font(.ui(big ? 30 : 17, .bold)).monospacedDigit().frame(maxHeight: .infinity)
                if big {
                    Text(date.formatted(NextRun.style.weekday(.abbreviated)).uppercased()).font(.ui(10, .semibold)).foregroundStyle(.secondary).padding(.bottom, 7)
                }
            } else {
                Image(systemName: icon).font(.system(size: big ? 22 : 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: big ? 68 : 36, height: big ? 78 : 40)
        .background(Self.leaf)
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Self.edge))
        .accessibilityHidden(true)
    }

    static let strip = Color(hex: 0x3A3E47)
    static let leaf = Color(light: 0xFFFFFF, dark: 0x23262D)
    static let edge = Color(light: 0xD3D7DE, dark: 0x2C3038)
}

/// The panels inside a schedule item's card (the mock's #15171C on #1B1E24).
private let schedulePanel = Color(light: 0xF4F5F7, dark: 0x15171C)

/// An item's second line: when it runs next, then how long until it (within a day) or how often.
struct NextLine: View {
    let entry: ScheduleEntry
    var now = Date()

    var body: some View {
        Group {
            if entry.paused {
                Text("paused")
            } else if let next = entry.next {
                let time = Text(NextRun.when(next, now: now)).fontWeight(.semibold).foregroundStyle(.primary)
                // A clock task that's due waits for the user to step away (Workspace.runDueTask).
                let tail = next <= now ? (entry.id.hasPrefix("task:") ? "when you step away" : "any moment")
                    : next.timeIntervalSince(now) < 86_400 ? NextRun.until(next, now: now) ?? "" : entry.every ?? ""
                // The time always; what follows it only when it fits whole.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) { time; Text(" · " + tail) }.fixedSize()
                    time
                }
            } else {
                Text(entry.when)
            }
        }
        .font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// Bolt: runs by itself; finger: asks Touch ID. Nothing for a perp.
struct SignerMark: View {
    let signer: ScheduleSigner

    var body: some View {
        if signer != .exchange {
            Image(systemName: signer.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(signer.tint)
                .help(signer.words.prefix(1).uppercased() + signer.words.dropFirst()).accessibilityLabel(signer.words)
        }
    }
}

/// On the portfolio: the next three things that run on their own; a click opens the Schedule beside it.
struct ScheduleTop3: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        let next = Array(ws.scheduleEntries.prefix(3))
        // What the marks mean, for the ones shown.
        let marks = next.map { ws.signer($0.id) }.filter { $0 != .exchange }.reduce(into: [ScheduleSigner]()) { if !$0.contains($1) { $0.append($1) } }
        TimelineView(.everyMinute) { clock in
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SCHEDULE").font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary)
                if ws.schedulePaused { Text("paused").font(.ui(10)).foregroundStyle(Brand.loss) }
                Spacer()
                if !next.isEmpty {
                    Button { ws.schedulePaused.toggle() } label: { Image(systemName: ws.schedulePaused ? "play.fill" : "pause.fill").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.hoverIcon)
                        .help(ws.schedulePaused ? "Resume the schedule" : "Pause the whole schedule: nothing runs until you resume")
                        .accessibilityLabel(ws.schedulePaused ? "Resume the schedule" : "Pause the schedule")
                }
                Button { withAnimation(StudioView.spring) { ws.showSchedule = true } } label: {
                    HStack(spacing: 2) { Text("All"); Image(systemName: "chevron.right") }.font(.ui(10.5, .semibold))
                }
                .buttonStyle(.hoverIcon)
            }
            if next.isEmpty {
                Text("Nothing scheduled yet").font(.ui(11)).foregroundStyle(.secondary)
            }
            ForEach(next) { e in
                HStack(spacing: 10) {
                    DateTile(date: e.next, icon: e.icon, now: clock.date)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.ui(12.5, .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        NextLine(entry: e, now: clock.date)
                    }
                    Spacer(minLength: 4)
                    SignerMark(signer: ws.signer(e.id))
                }
                .opacity(e.paused || ws.schedulePaused ? 0.55 : 1)
                // Room inside the row, so its hover edge sits off the text; all of it clicks.
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .modifier(HoverLift(radius: 10)).onTapGesture { ws.openScheduleCanvas(e.id) }
                .contextMenu {
                    if !e.id.hasPrefix("perp:") {
                        Button(e.paused ? "Resume" : "Pause") { ws.setPaused(e.id, !e.paused) }
                        Button("Delete", role: .destructive) { ws.removeScheduled(e.id) }
                    }
                }
            }
            if !marks.isEmpty {
                let legend = ForEach(marks, id: \.self) { s in Label(s.words, systemImage: s.icon).foregroundStyle(s.tint).fixedSize() }
                // Side by side when they fit, else one under the other: a mark's words never break.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { legend }
                    VStack(alignment: .leading, spacing: 3) { legend }
                }
                .font(.ui(10.5)).labelStyle(.titleAndIcon).padding(.horizontal, 8).padding(.top, 4)
            }
        }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.cardBorder))
    }
}

/// Over the chat's field while it holds a top-up of the automation wallet: where the money comes from and the budget,
/// each now → after, so the amount is picked seeing them. Nothing moves until the line is sent.
struct TopUpBalances: View {
    @Environment(Workspace.self) private var ws
    let amount: Decimal

    var body: some View {
        let solana = ws.solana?.usdc, budget = ws.automationBudget?.total
        // Where else USDC is: it can be moved to Solana first.
        let elsewhere = EVMNetwork.all.compactMap { n in ws.usdc(on: n.key).flatMap { $0 >= 0.01 ? "\(n.name) \(Fmt.num($0))" : nil } }
        VStack(alignment: .leading, spacing: 8) {
            Text("TOP UP THE AUTOMATION WALLET").font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary)
            row(Image(nsImage: TokenLogo.image("sol") ?? NSImage()), "Your wallet · Solana", solana, solana.map { $0 - amount })
            row(Image(systemName: "clock.arrow.circlepath"), "Automation budget", budget, budget.map { $0 + amount })
            if let solana, solana < amount {
                Text("Solana has \(Fmt.num(solana)) USDC, \(Fmt.num(amount - solana)) short." + (elsewhere.isEmpty ? "" : " There’s USDC on \(elsewhere.joined(separator: ", ")): move it to Solana first."))
                    .font(.ui(11, .semibold)).foregroundStyle(Brand.jevInk).fixedSize(horizontal: false, vertical: true)
            }
            Text("Type another amount if you like, then Return. Confirm and Touch ID come after.").font(.ui(10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.glassFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.glassRim))
        .transition(.opacity)
    }

    /// A balance as now → after.
    private func row(_ icon: Image, _ name: String, _ now: Decimal?, _ after: Decimal?) -> some View {
        HStack(spacing: 8) {
            icon.resizable().scaledToFit().frame(width: 16, height: 16).foregroundStyle(.secondary)
            Text(name).font(.ui(12.5, .semibold))
            Spacer(minLength: 8)
            Text(now.map { n in "\(Fmt.num(n)) → \(after.map { Fmt.num(max(0, $0)) } ?? "…") USDC" } ?? "…")
                .font(.ui(12.5, .bold)).monospacedDigit()
                .foregroundStyle(after.map { $0 < 0 } == true ? AnyShapeStyle(Brand.loss) : AnyShapeStyle(.primary))
        }
    }
}

/// A scheduled item on its own canvas (variant 01 of the design canvas): the task or the
/// buy with its switch and Run now, its next run as a date, where it pays from, where what it gets ends up and who
/// signs, then its runs one line each, a click opening one in full. A perp keeps its own board.
struct ScheduleItemBoard: View {
    @Environment(Workspace.self) private var ws
    let key: String
    /// Runs opened to their whole card.
    @State private var opened: Set<UUID> = []

    private var task: ScheduledTask? { ws.tasks.first { "task:\($0.id)" == key } }

    var body: some View {
        let entry = ws.scheduleEntries.first { $0.id == key }
        let runs = Array(ws.activities.reversed().lazy.filter { $0.schedule == key }.prefix(50))
        let perp = key.hasPrefix("perp:")
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text((["SCHEDULED"] + [entry?.every?.uppercased()].compactMap { $0 }).joined(separator: " · "))
                    .font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                Button { ws.closeScheduleCanvas() } label: { Label("Close", systemImage: "xmark").font(.ui(11.5, .semibold)).padding(.horizontal, 9) }
                    .buttonStyle(.hoverIcon).help("Back to the canvas you came from")
            }
            if let p = ws.positions.first(where: { "perp:\($0.coin)" == key }) {
                PositionBoard(position: p)
            } else if let entry {
                header(entry)
                if let next = entry.next { TimelineView(.everyMinute) { clock in nextRun(entry, next, now: clock.date) } }
                facts(entry)
                if let t = task, t.steps.count > 1 { steps(t) }
                if let t = task, t.untrusted != true, ws.automationWallet == nil, t.movesMoney { automationOffer }
            } else {
                // Done or cancelled: what it did is all that's left.
                Text("No longer scheduled — what it did is below.").font(.ui(13, .semibold)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(runs.isEmpty ? "HASN’T RUN YET" : "LAST RUNS · \(runs.count)").font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                ForEach(runs) { a in
                    Divider()
                    run(a)
                }
            }
            if entry != nil, !perp {
                HStack {
                    Text("Change it in the chat, in any words.").font(.ui(11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { ws.removeScheduled(key) } label: { Label("Delete", systemImage: "trash").font(.ui(12, .semibold)) }
                        .buttonStyle(.borderless).foregroundStyle(Brand.loss).pointerStyle(.link)
                }
            }
        }
        .padding(perp ? 0 : 20)
        .frame(width: perp ? 470 : 500, alignment: .leading)
        .background { if !perp { RoundedRectangle(cornerRadius: 24).fill(Brand.card) } }
        .overlay { if !perp { RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.cardBorder) } }
        .task(id: ws.automationWallet?.id) { if ws.automationWallet != nil { await ws.loadAutomationBudget() } }
    }

    private func header(_ e: ScheduleEntry) -> some View {
        HStack(spacing: 12) {
            if let logo = e.logo {
                TokenLogo(name: logo, size: 36)
            } else {
                Image(systemName: e.icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.accentInk)
                    .frame(width: 36, height: 36).background(Circle().fill(Brand.accent.opacity(0.14)))
            }
            Text(e.title).font(.ui(21, .bold)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Toggle(isOn: Binding(get: { !e.paused }, set: { ws.setPaused(key, !$0) })) {
                Text(e.paused ? "Paused" : "On").font(.ui(12.5, .semibold))
            }
            .toggleStyle(.switch).controlSize(.small)
            Button { ws.runScheduledNow(key) } label: { Label("Run now", systemImage: "play.fill").font(.ui(12, .semibold)) }
                .buttonStyle(.bordered).controlSize(.small).pointerStyle(.link).disabled(ws.schedulePaused)
                .help("Runs within half a minute, on a canvas of its own")
        }
    }

    private func nextRun(_ e: ScheduleEntry, _ next: Date, now: Date) -> some View {
        let again = e.every.map { $0 == "once" ? "once, then it’s off the schedule" : "then again \($0)" }
        let line = e.paused ? "paused — switch it on to run"
            : ws.schedulePaused ? "the whole schedule is paused"
            : next <= now ? (task != nil ? "waits until you step away from the Mac, half an hour at most" : "runs within a minute")
            : [NextRun.until(next, now: now, exact: true), again].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 18) {
            DateTile(date: next, big: true, now: now)
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT RUN").font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Text(NextRun.when(next, now: now)).font(.ui(30, .bold)).lineLimit(1).minimumScaleFactor(0.7)
                Text(line).font(.ui(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(schedulePanel))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.cardBorder))
        .opacity(e.paused || ws.schedulePaused ? 0.55 : 1)
    }

    private struct Fact: Identifiable {
        let label, value, detail: String
        var icon: String?
        var id: String { label }
    }

    /// Where it pays from, where what it gets ends up, who signs — as the run will do it now.
    private func facts(_ e: ScheduleEntry) -> some View {
        let signer = ws.signer(key)
        let wallet = ws.activeWallet?.label ?? "Your wallet"
        let money = task?.movesMoney ?? true
        let signs = switch signer {
        case .itself: Fact(label: "SIGNS", value: "By itself", detail: money ? "no Touch ID" : "nothing to sign", icon: signer.icon)
        case .touchID: Fact(label: "SIGNS", value: "Touch ID", detail: task == nil ? "each buy asks your finger" : "each move waits for Confirm and your finger", icon: signer.icon)
        case .confirm: Fact(label: "SIGNS", value: "Your Confirm", detail: "each move waits on its canvas", icon: signer.icon)
        case .ledger: Fact(label: "SIGNS", value: "Your Ledger", detail: "approve each run on the device", icon: signer.icon)
        case .exchange: Fact(label: "SIGNS", value: "The exchange", detail: "", icon: signer.icon)
        }
        var facts: [Fact] = []
        if let b = ws.schedules.first(where: { "buy:\($0.symbol)" == key }) {
            let free = ws.solana?.usdc
            let buys = free.map { b.usdc > 0 ? NSDecimalNumber(decimal: ($0 / b.usdc).rounded(0, .down)).intValue : 0 }
            facts = [Fact(label: "PAYS FROM", value: "\(wallet) · Solana",
                          detail: free.map { "\(Fmt.num($0)) USDC free · \(buys ?? 0) more buy\(buys == 1 ? "" : "s")" } ?? "USDC on Solana"),
                     Fact(label: "BOUGHT \(b.symbol) GOES TO", value: wallet, detail: "the wallet it pays from")]
        } else if !money {
            facts = [Fact(label: "MONEY", value: "None", detail: "it reads and tells you, moves nothing")]
        } else if signer == .itself, let a = ws.automationWallet {
            facts = [Fact(label: "PAYS FROM", value: "Automation budget",
                          detail: ws.automationBudget.map { "\(Fmt.num($0.total)) USDC on «\(a.label)»" } ?? "the wallet «\(a.label)»"),
                     Fact(label: "ENDS UP IN", value: "«\(a.label)»", detail: "the automation wallet; move it over in the chat")]
        } else {
            facts = [Fact(label: "PAYS FROM", value: wallet, detail: "the wallet that’s on"),
                     Fact(label: "ENDS UP IN", value: wallet, detail: "the wallet it pays from")]
        }
        return HStack(alignment: .top, spacing: 10) {
            ForEach(facts + [signs]) { f in
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.label).font(.ui(9.5, .semibold)).tracking(1.1).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    HStack(spacing: 5) {
                        if let icon = f.icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                        Text(f.value).font(.ui(15, .bold)).lineLimit(2)
                    }
                    if !f.detail.isEmpty { Text(f.detail).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 14).fill(schedulePanel))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Brand.cardBorder))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Each step as ihatecrypto reads it and as it will be typed, when there are several.
    private func steps(_ t: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(t.steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(i + 1)").font(.ui(11, .heavy)).foregroundStyle(.secondary).monospacedDigit().frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ScheduleCanvas.readable(step)).font(.ui(12.5, .semibold)).fixedSize(horizontal: false, vertical: true)
                        if ScheduleCanvas.readable(step).lowercased() != step.lowercased() {
                            Text(step).font(.ui(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 7)
                if i < t.steps.count - 1 { Divider() }
            }
        }
    }

    /// Automation asked for, and nothing yet that runs it without a finger: the way offered right here, as a card.
    private var automationOffer: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.accentInk)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Run it by itself, without Touch ID?").font(.ui(13.5, .bold))
                Text("Right now its moves wait for your Confirm and finger. An automation wallet holds the budget for scheduled tasks and signs them on its own; your main wallet keeps Touch ID.")
                    .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await ws.createAutomationWallet() }
                } label: {
                    Label("Create an automation wallet", systemImage: "plus.circle.fill").font(.ui(12, .semibold))
                }
                .buttonStyle(.borderedProminent).tint(Brand.accent).controlSize(.small).pointerStyle(.link).padding(.top, 4)
                .help("Touch ID once; then put the tasks' budget on it")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.accent.opacity(0.5)))
    }

    /// One run in a line — when, what it said, its canvas while it's kept, done or failed; a click shows it whole.
    private func run(_ a: Activity) -> some View {
        let failed = a.failed == true || a.bubbles.contains { $0.status == "failed" }
        let open = opened.contains(a.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(Self.stamp(a.at)).font(.ui(13)).foregroundStyle(.secondary).monospacedDigit().frame(width: 128, alignment: .leading)
                Text(Self.said(a)).font(.ui(13, .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                if let id = a.canvas, let c = ws.canvases.first(where: { $0.id == id }) {
                    Button { ws.openRunCanvas(c) } label: { Label("Its canvas", systemImage: "arrow.up.right").font(.ui(11, .semibold)) }
                        .buttonStyle(.borderless).pointerStyle(.link).help("Open the canvas it ran on")
                }
                Image(systemName: failed ? "xmark" : "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(failed ? Brand.loss : Brand.profit)
                    .accessibilityLabel(failed ? "Failed" : "Done")
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .contentShape(Rectangle())
            .modifier(HoverLift(radius: 10))
            .onTapGesture { if open { opened.remove(a.id) } else { opened.insert(a.id) } }
            .help(open ? "Hide what it did" : "Show what it did")
            if open { ActivityCard(activity: Self.done(a)).padding(.bottom, 8).transition(.opacity) }
        }
    }

    /// «Today · 9:00 PM», «Yesterday · 2:39 AM», «Oct 12 · 9:00 PM».
    static func stamp(_ d: Date, now: Date = Date()) -> String {
        let cal = NextRun.calendar
        let day = cal.isDate(d, inSameDayAs: now) ? "Today"
            : cal.date(byAdding: .day, value: -1, to: now).map { cal.isDate(d, inSameDayAs: $0) } == true ? "Yesterday"
            : d.formatted(NextRun.style.month(.abbreviated).day())
        return "\(day) · \(d.formatted(NextRun.style.hour().minute()))"
    }

    /// A run in one line: the last thing it said — not the line naming the wallet it ran from, nor «see the canvas».
    static func said(_ a: Activity) -> String {
        let line = done(a).lines.last { !$0.hasPrefix("From the automation wallet") && !$0.hasPrefix("С кошелька автоматизации") }
        let text = (line ?? a.title ?? a.request ?? "Ran").components(separatedBy: "\n").first ?? ""
        return text.replacing(/\s*(?:—|:)\s*(?:see the canvas|смотри холст|mira el lienzo)\.?$/, with: "")
    }

    /// A run as it went: what it did and its result. Not the options a spread passed over («SKIPPED»), nor the line that
    /// asked to sign a plan back then.
    static func done(_ a: Activity) -> Activity {
        var a = a
        a.bubbles.removeAll { $0.kind == "skipped" }
        a.lines.removeAll { $0.contains("Sign it") || $0.contains("Подпиши") || $0.contains("Confirm") }
        return a
    }
}
