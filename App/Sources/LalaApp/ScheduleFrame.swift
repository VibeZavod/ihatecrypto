import AppKit
import EVMChain
import LalaCore
import SignerAPI
import SwiftUI
import TradeExecution

/// The automation wallet's USDC: the Schedule's budget, wherever it lies — Solana, every EVM network ihatecrypto knows
/// (one address for all of them; USDG on Robinhood Chain) and NEAR.
struct AutomationBudget: Equatable {
    var solana: Decimal?
    /// By EVMNetwork.key; a network that didn't answer is missing.
    var evm: [String: Decimal] = [:]
    var near: Decimal?
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
}

extension Workspace {
    var automationWallet: SignerWallet? { wallets.first(where: \.isAutomation) }

    /// Tasks and recurring buys by their next run, then the perps (their stops sit on the exchange).
    var scheduleEntries: [ScheduleEntry] {
        let dated = tasks.map { t in
            ScheduleEntry(id: "task:\(t.id)", title: t.steps.map(ScheduleCanvas.readable).joined(separator: " → "), when: t.when, next: t.next,
                          paused: t.paused == true, logo: nil, icon: t.every == nil ? "calendar.badge.clock" : "repeat")
        } + schedules.map { b in
            ScheduleEntry(id: "buy:\(b.symbol)", title: "Buy \(b.symbol) for \(Fmt.usd(b.usdc))", when: "every \(ScheduleCanvas.period(b.days)) · next \(Fmt.date(b.next))",
                          next: b.next, paused: b.paused == true, logo: b.symbol.lowercased(), icon: "cart")
        }
        return dated.sorted { ($0.next ?? .distantFuture) < ($1.next ?? .distantFuture) } + positions.map { p in
            ScheduleEntry(id: "perp:\(p.coin)", title: "\(p.size > 0 ? "Long" : "Short") \(IntentParser.pretty(p.coin))", when: "stop and take on the exchange",
                          next: nil, paused: false, logo: nil, icon: "chart.line.uptrend.xyaxis")
        }
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
        guard !busy else { return }
        // Only the greeting, as on every canvas: the item is its card, not a message.
        var c = CanvasSession(providerID: providerID, model: model, messages: Array(messages.prefix(1)), intent: TradeIntent())
        c.title = scheduleEntries.first { $0.id == key }?.title ?? "Scheduled"
        c.schedule = key
        canvases.insert(c, at: 0)
        openCanvas(c)
    }

    /// Closes an item's canvas: back to the canvas it was opened from (or a new one). Nothing written on it, it was only a
    /// view of the item and leaves the list; the Schedule frame opens it again.
    func closeScheduleCanvas() {
        guard let id = canvasID, let c = canvases.first(where: { $0.id == id }), c.schedule != nil, !busy else { return }
        let frame = showSchedule, place = detail
        keepViewport = true
        defer { showSchedule = frame; detail = place; keepViewport = false }
        if let back = scheduleReturn.flatMap({ r in canvases.first { $0.id == r && $0.schedule == nil } }) { openCanvas(back) } else { newCanvas() }
        if !c.messages.contains(where: \.fromUser) { canvases.removeAll { $0.id == id } }
    }

    /// «Run now»: due at once; the watch loop runs it within half a minute, on a canvas of its own like any run.
    func runScheduledNow(_ key: String) {
        if let i = tasks.firstIndex(where: { "task:\($0.id)" == key }) { tasks[i].next = Date() }
        if let i = schedules.firstIndex(where: { "buy:\($0.symbol)" == key }) { schedules[i].next = Date() }
    }

    func setPaused(_ id: String, _ paused: Bool) {
        if let i = tasks.firstIndex(where: { "task:\($0.id)" == id }) { tasks[i].paused = paused ? true : nil }
        if let i = schedules.firstIndex(where: { "buy:\($0.symbol)" == id }) { schedules[i].paused = paused ? true : nil }
    }

    func loadAutomationBudget() async {
        guard let w = automationWallet else { automationBudget = nil; return }
        async let sol = Self.solanaUSDC(w.solana)
        async let evm = Self.evmUSDC(w.evm)
        async let near = Self.nearUSDC(w.near)
        let budget = AutomationBudget(solana: await sol, evm: await evm, near: await near)
        if budget != automationBudget { automationBudget = budget }
    }

    private static func solanaUSDC(_ address: String?) async -> Decimal? {
        guard let address else { return nil }
        return try? await Solana.balance(owner: address).usdc
    }

    /// USDC (USDG on Robinhood Chain) at the one EVM address, on every network at once.
    private static func evmUSDC(_ address: String?) async -> [String: Decimal] {
        guard let address, isEVMAddress(address) else { return [:] }
        return await withTaskGroup(of: (String, Decimal?).self) { group in
            for n in EVMNetwork.all {
                group.addTask { (n.key, (try? await n.rpc.tokenBalance(n.usdc, owner: address)).map { Decimal($0) / 1_000_000 }) }
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

    /// Top up through the chat, the way typing it would: from Solana when it holds the amount, else moved over first
    /// from the network that has it. The card waits for Confirm and Touch ID like any move from the main wallet.
    func topUpAutomation(_ amount: Decimal = 20) async {
        guard let w = automationWallet else { return }
        let a = Fmt.num(amount)
        let send = "send \(a) USDC to \(w.label)"
        let command = (solana?.usdc ?? 0) >= amount ? send
            : EVMNetwork.funding(amount, held: { self.usdc(on: $0) }).map { "move \(a) USDC from \($0.name) to Solana then \(send)" } ?? send
        await self.send(command)
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
            let weeks = total.flatMap { t in spend > 0 ? NSDecimalNumber(decimal: t / spend).intValue : nil }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(total.map { "\(Fmt.num($0)) USDC" } ?? "…").font(.ui(24, .heavy)).monospacedDigit()
                    Text("budget").font(.ui(11)).foregroundStyle(.secondary)
                }
                if let weeks {
                    Text(weeks >= 4 ? "covers the next 4 weeks" : weeks == 0 ? "not enough for the next run" : "covers \(weeks) week\(weeks == 1 ? "" : "s")")
                        .font(.ui(11, .semibold)).foregroundStyle(weeks == 0 ? Brand.loss : Brand.profit)
                    HStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { i in Capsule().fill(i < weeks ? Brand.profit : Color.primary.opacity(0.1)).frame(height: 5) }
                    }
                }
                // Nothing on it: the way to put the budget there, right here and in the chat.
                if total == 0 {
                    Button { Task { await ws.topUpAutomation() } } label: {
                        Label("Top up 20 USDC", systemImage: "plus").font(.ui(13, .bold)).frame(maxWidth: .infinity).frame(height: 34)
                    }
                    .buttonStyle(LitBlock(radius: 12)).foregroundStyle(Brand.onAccent)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Brand.accent))
                    Text("or say in the chat: «пополни автоматизацию на 20»").font(.ui(10.5)).foregroundStyle(.secondary)
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
                    Button { ws.draft = e } label: {
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
            Group {
                if let logo = e.logo { TokenLogo(name: logo, size: 26) } else { Image(systemName: e.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
            }
            .frame(width: 30, height: 30).background(Circle().fill(Brand.card)).overlay(Circle().strokeBorder(Brand.cardBorder))
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.ui(12.5, .semibold)).lineLimit(1)
                Text(e.paused ? "paused" : e.when).font(.ui(10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
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
            Text(title).font(.ui(12, .medium)).lineLimit(1)
            Spacer(minLength: 2)
            if let id = a.canvas, let c = ws.canvases.first(where: { $0.id == id }) {
                Button { ws.openCanvas(c) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.hoverIcon).help("Open the canvas it ran on")
            }
        }
        .padding(.vertical, 3)
        .help(a.lines.last ?? title)
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
                Button { Task { await ws.topUpAutomation() } } label: { Label("Top up 20 USDC", systemImage: "plus").font(.ui(12.5, .bold)).frame(maxWidth: .infinity).frame(height: 32) }
                    .buttonStyle(LitBlock(radius: 12)).background(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.cardBorder))
                    .help("From your main wallet: the card waits for Confirm and Touch ID")
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

/// On the portfolio: the next three things that run on their own; a click opens the Schedule beside it.
struct ScheduleTop3: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        let next = Array(ws.scheduleEntries.prefix(3))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SCHEDULE").font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary)
                if ws.schedulePaused { Text("paused").font(.ui(10)).foregroundStyle(Brand.loss) }
                Spacer()
                Button { withAnimation(StudioView.spring) { ws.showSchedule = true } } label: {
                    HStack(spacing: 2) { Text("All"); Image(systemName: "chevron.right") }.font(.ui(10.5, .semibold))
                }
                .buttonStyle(.hoverIcon)
            }
            if next.isEmpty {
                Text("Nothing scheduled yet").font(.ui(11)).foregroundStyle(.secondary)
            }
            ForEach(next) { e in
                HStack(spacing: 8) {
                    Image(systemName: e.icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 14)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(e.title).font(.ui(11.5, .semibold)).lineLimit(1)
                        Text(e.paused ? "paused" : e.when).font(.ui(10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .opacity(e.paused || ws.schedulePaused ? 0.55 : 1)
                // Room inside the row, so its hover edge sits off the text; all of it clicks.
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .modifier(HoverLift(radius: 10)).onTapGesture { ws.openScheduleCanvas(e.id) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.cardBorder))
    }
}

/// A scheduled item on its own canvas: the task, the buy or the perp in detail, its switch, Run now, and every time it ran.
struct ScheduleItemBoard: View {
    @Environment(Workspace.self) private var ws
    let key: String

    var body: some View {
        let entry = ws.scheduleEntries.first { $0.id == key }
        let runs = Array(ws.activities.reversed().lazy.filter { $0.schedule == key }.prefix(50))
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("SCHEDULED · ITS OWN CANVAS").font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                Button { ws.closeScheduleCanvas() } label: { Label("Close", systemImage: "xmark").font(.ui(11.5, .semibold)).padding(.horizontal, 9) }
                    .buttonStyle(.hoverIcon).help("Back to the canvas you came from")
            }
            if let t = ws.tasks.first(where: { "task:\($0.id)" == key }) {
                TaskDetail(task: t)
            } else if let b = ws.schedules.first(where: { "buy:\($0.symbol)" == key }) {
                ScheduleBoard(schedule: b)
            } else if let p = ws.positions.first(where: { "perp:\($0.coin)" == key }) {
                PositionBoard(position: p)
            } else {
                // Done or cancelled: what it did is all that's left.
                Text("No longer scheduled — what it did is below.").font(.ui(13, .semibold)).foregroundStyle(.secondary)
            }
            if let entry, !key.hasPrefix("perp:") {
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { !entry.paused }, set: { ws.setPaused(key, !$0) })) {
                        Text(entry.paused ? "Paused" : "On").font(.ui(12.5, .semibold))
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    Button { ws.runScheduledNow(key) } label: { Label("Run now", systemImage: "play.fill").font(.ui(12, .semibold)) }
                        .buttonStyle(.bordered).controlSize(.small).pointerStyle(.link).disabled(ws.schedulePaused)
                        .help("Runs within half a minute, on a canvas of its own")
                    Text("Change it in the chat, in any words.").font(.ui(10.5)).foregroundStyle(.secondary)
                }
            }
            Text(runs.isEmpty ? "HASN’T RUN YET" : "PREVIOUS RUNS · \(runs.count)").font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(runs) { a in
                VStack(alignment: .trailing, spacing: 4) {
                    ActivityCard(activity: Self.done(a))
                    if let id = a.canvas, let c = ws.canvases.first(where: { $0.id == id }) {
                        Button { ws.openCanvas(c) } label: { Label("Open its canvas", systemImage: "rectangle.on.rectangle") }
                            .buttonStyle(.borderless).font(.ui(10, .semibold)).pointerStyle(.link)
                    }
                }
            }
        }
        .frame(width: 470, alignment: .leading)
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
