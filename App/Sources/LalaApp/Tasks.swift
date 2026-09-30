import AppKit
import LalaCore
import SignerAPI
import SwiftUI
import WalletCore

/// The automation wallet a scheduled task is running on, for the moves inside that run only (`executor` picks it up):
/// a Confirm pressed meanwhile in the window is another task and still signs with the active wallet.
nonisolated enum TaskRun {
    @TaskLocal static var automation: SignerWallet?
}

// Scheduled tasks («in 1 week: rebalance USDC», «every day at 09:00: sell SOL then lend USDC» — ScheduledTask) and
// Settings › General › Keep running, which keeps the app up so they run.

extension Workspace {
    /// Keeps a task if every step is something ihatecrypto does, and opens the Schedule board (the rail's button) on the canvas.
    func schedule(_ task: ScheduledTask, note: String? = nil) {
        if let unknown = task.steps.first(where: { !knows($0) }) {
            reply(say("I can schedule that, but ihatecrypto can’t do “\(unknown)” yet — nothing was scheduled.",
                      "Запланировать могу, но «\(unknown)» ihatecrypto пока не умеет — ничего не запланировано."), note: note)
            return
        }
        var task = task
        if SignerClient.untrusted { task.untrusted = true }
        tasks.append(task)
        // The Schedule canvas shows it in detail: the chat keeps one line.
        scheduleItem = "task:\(task.id)"
        showSchedule = true
        let what = task.steps.joined(separator: say(", then ", ", потом "))
        let how = wallets.contains(where: \.isAutomation) && task.untrusted != true
            ? say(" Its moves run by themselves from the automation wallet, no Touch ID.", " Движения пойдут сами с кошелька автоматизации, без Touch ID.")
            : say(" Its moves will wait for your Confirm; to run them by themselves, say «create an automation wallet».",
                  " Движения будут ждать твоего Confirm; чтобы шли сами, скажи «создай кошелёк автоматизации».")
        reply(say("Scheduled: \(what) — \(task.when). It’s on the canvas.", "Запланировано: \(what) — \(task.when). Это на канвасе.") + how, note: note)
    }

    func cancelTasks(note: String? = nil) {
        let n = tasks.count
        tasks = []
        taskQueue = nil
        if n > 0 { showSchedule = true }
        reply(n == 0 ? say("Nothing was scheduled.", "Ничего не было запланировано.")
                     : say("Cancelled \(n) scheduled task\(n == 1 ? "" : "s").", "Отменено запланированных задач: \(n)."), note: note)
    }

    /// Whether a step reads as a command ihatecrypto carries out: the parsers `runCanonical` tries, in its order.
    func knows(_ step: String) -> Bool {
        let m = Set(markets.keys), s = step.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".! "))
        return s == "lock" || s == "clear the plan" || TokenCommand.parse(step) != nil || ChartCommand.parse(step, markets: m) != nil
            || PnLCommand.parse(step, markets: m) != nil || AlertCommand.parse(step, markets: m) != nil
            || AddressBookCommand.parse(step) != nil || FolderCommand.parse(step) != nil || WalletCommand.parse(step) != nil || PositionCommand.parse(step) != nil
            || (IntentParser.startsPlan(step, markets: m) && IntentParser.apply(step, to: TradeIntent(), markets: m) != nil)
    }

    /// The first task whose time has come, on a canvas of its own, once nothing else is going on: the user's card
    /// waiting for Confirm, a reply being written, a move running or half-typed text come first.
    func runDueTask() async {
        guard let i = tasks.firstIndex(where: { $0.next <= Date() }), !busy, !thinking, !executing, !preparing,
              pendingAction == nil, pendingAllocation == nil, prepared == nil, awaitingAmount == nil, draft.isEmpty else { return }
        var task = tasks[i]
        if task.advance() { tasks[i] = task } else { tasks.remove(at: i) }
        newCanvas()
        let request = (task.because.map { $0 + ": " } ?? say("Scheduled: ", "По расписанию: ")) + task.steps.joined(separator: say(", then ", ", потом "))
        messages.append(Message(fromUser: true, text: request))
        beginActivity(.request, request: request, schedule: "task:\(task.id)")
        let run = currentActivity
        // With an automation wallet the task's moves go through at once from it, without Touch ID — never one typed
        // through the debug API. Without one, each move waits on its canvas for Confirm.
        let automation = task.untrusted == true ? nil : wallets.first(where: \.isAutomation)
        if let automation { reply(say("From the automation wallet «\(automation.label)», no Touch ID.", "С кошелька автоматизации «\(automation.label)», без Touch ID.")) }
        await TaskRun.$automation.withValue(automation) { await runSteps(task.steps, confirmed: automation != nil) }
        // The Schedule canvas opens the canvas it ran on (saved by now).
        if let i = activities.lastIndex(where: { $0.id == run }) { activities[i].canvas = canvasID }
        // A trade plan waits for Execute the way a move waits for Confirm; one a rule stops needs the user just as much.
        let plan = intent != TradeIntent() && !managesPosition
        let waits = pendingAction != nil || pendingAllocation != nil || plan
        // The run is already in the history as its request.
        notify(waits ? .confirm : .moves, request,
               plan ? (planIsReady ? say("The plan is ready on its canvas — press Execute.", "План готов на своём канвасе — нажми Execute.")
                                   : say("The plan is on its canvas, but a rule stops it — open it to fix.", "План на своём канвасе, но его стопорит правило — открой и поправь."))
                    : waits ? say("Ready on its canvas — press Confirm.", "Готово на своём канвасе — нажми Confirm.")
                            : messages.last.map(\.text) ?? "", record: false)
    }

    /// Steps one after another. The first that waits for Confirm holds the rest until its move has gone through
    /// (`continueTask`): they may need the money it moves. That one Confirm covers the chain: once `confirmed`, a step's
    /// move is carried out at once, and one that doesn't go through stops the rest.
    func runSteps(_ steps: [String], confirmed: Bool = false) async {
        thinking = true
        var rest: [String] = []
        for (k, step) in steps.enumerated() {
            // The move before this step is done: let it go first, so the canvas keeps it as an earlier move. Cleared only
            // after, the next step's card was saved over it with its «Done» (a Base → Robinhood bridge vanished under
            // «Buy AI», and «Buy MOO» showed Done though it never ran).
            if confirmed { finishedAction = nil }
            guard await runCanonical(step, userText: step, before: intent, inChain: true) else {
                reply(say("ihatecrypto can’t do “\(step)” — the steps stop here.", "ihatecrypto не умеет «\(step)» — на этом шаги останавливаются."))
                break
            }
            if confirmed, pendingAction != nil || pendingAllocation != nil {
                finishedAction = nil
                if let p = pendingAction {
                    pendingAction = nil
                    pendingText = nil
                    await carryOut(p)
                } else if let p = pendingAllocation {
                    pendingAllocation = nil
                    await move(p, confirmed: true)
                }
                if finishedAction?.outcome.ok == false {
                    if k + 1 < steps.count { reply(say("“\(step)” didn’t go through, so the steps after it don’t run.", "«\(step)» не прошёл, поэтому следующие шаги не запускаю.")) }
                    break
                }
                continue
            }
            if pendingAction != nil || pendingAllocation != nil || awaitingAmount != nil {
                rest = Array(steps[(k + 1)...])
                // The Confirm covers the chain, so it names what follows.
                if let p = pendingText, !rest.isEmpty { pendingText = ([p] + rest).joined(separator: " → ") }
                // The step's card said nothing of its own (runCanonical inChain): one line for the chain.
                if pendingAction != nil {
                    reply(say("It’s on the canvas, every step in a row — one Confirm covers them all, or say anything else to cancel.",
                              "Все шаги на холсте — один Confirm на всю цепочку, или напиши что-нибудь другое, чтобы отменить."))
                }
                break
            }
            // A move that didn't get to its Confirm (short of money, a rule, switched off) stops the rest: they may need its money.
            switch WalletCommand.parse(step) {
            case nil, .yields?, .schedule?, .stopSchedules?, .receive?: continue
            default:
                if k + 1 < steps.count {
                    reply(say("“\(step)” didn’t get to its Confirm, so the steps after it don’t run.", "«\(step)» не дошёл до подтверждения, поэтому следующие шаги не запускаю."))
                }
            }
            break
        }
        thinking = false
        snapshotCanvas()
        saveCanvas()
        taskQueue = rest.isEmpty ? nil : (canvasID, rest, Date())
    }

    /// When a move finishes: the rest of a scheduled task, if the move was on its canvas, went through, and came
    /// within half an hour (a card waits 15 minutes; a later move on that canvas is something else).
    func continueTask() {
        guard let q = taskQueue else { return }
        taskQueue = nil
        guard q.canvas == canvasID, finishedAction?.outcome.ok == true, Date().timeIntervalSince(q.since) < 1800 else { return }
        Task { await runSteps(q.steps, confirmed: true) }
    }
}

extension Workspace {
    /// «create an automation wallet»: a wallet the signer makes (Touch ID first) that signs scheduled tasks' moves
    /// without Touch ID. The active wallet stays; «Automation» goes into Addresses (Solana and Base) so «send 20 USDC
    /// to Automation» tops it up — the signer asks Touch ID for that new address once, with the address on the prompt.
    func createAutomationWallet(note: String? = nil) async {
        do {
            let r = try await SignerClient().send(.createAutomationWallet)
            guard r.ok, let w = r.wallets?.first(where: \.isAutomation) else { throw WalletError(r.error ?? "The signer refused.") }
            await loadSigner()
            for (address, network) in [(w.solana, AddressCheck.Network.solana), (w.evm, .base)] {
                guard let address, !addressBook.contains(where: { $0.address == address && $0.network == network }) else { continue }
                addressBook.append(SavedAddress(name: w.label, address: address, network: network, category: "Your wallet",
                                                icon: .symbol("clock.arrow.circlepath"), source: "signer"))
            }
            reply(say("The automation wallet is made: scheduled tasks now spend only from it, without Touch ID. Put their budget on it — "
                      + "keep only that there; if this Mac's keychain is lost, so is what's on it.",
                      "Кошелёк автоматизации создан: задачи по расписанию тратят только с него, без Touch ID. Положи туда их бюджет — "
                      + "и только его: если связка ключей этого Мака пропадёт, пропадёт и то, что на нём."), note: note)
            nextSteps = NextSteps(options: [
                ChatRouter.Option(title: say("Top up 20 USDC", "Пополнить на 20 USDC"),
                                  comment: say("From your wallet on Solana: Touch ID once for the new address.", "С твоего кошелька на Solana: Touch ID один раз на новый адрес."),
                                  command: "send 20 USDC to \(w.label)", recommended: true),
            ], userText: "", found: [], canvas: canvasID)
        } catch {
            reply(say("No automation wallet: ", "Кошелёк автоматизации не создан: ") + error.localizedDescription, note: note)
        }
    }
}

/// Settings › General › Keep running: a launch agent that starts ihatecrypto at login and again within a minute after
/// it quits or crashes, so scheduled tasks, stops and alerts keep going. It starts the app only when no copy runs, and
/// hidden (`open -g -j`): the window stays closed, the coin is in the menu bar.
enum KeepRunning {
    static let label = "app.lala.mac.keeprunning"
    static var plist: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist") }
    static var isOn: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static func set(_ on: Bool) throws {
        let domain = "gui/\(getuid())"
        launchctl("bootout", "\(domain)/\(label)")
        guard on else { try? FileManager.default.removeItem(at: plist); return }
        let job: [String: Any] = [
            "Label": label,
            // The app as it is now; a moved or rebuilt copy elsewhere re-registers when the switch is set again.
            "ProgramArguments": ["/bin/sh", "-c", "/usr/bin/pgrep -qx ihatecrypto || /usr/bin/open -g -j '\(Bundle.main.bundlePath)'"],
            "RunAtLoad": true,
            "StartInterval": 60,
            "ProcessType": "Background",
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "app.lala.mac"],
        ]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist)
        guard launchctl("bootstrap", domain, plist.path) == 0 else {
            try? FileManager.default.removeItem(at: plist)
            throw WalletError("macOS didn’t accept the background item. Check System Settings › General › Login Items.")
        }
    }

    /// Sparkle is about to swap the app: the agent rests, or it could open the old copy mid-swap (Updater.swift).
    static func pause() { launchctl("bootout", "gui/\(getuid())/\(label)") }
    /// At launch of a copy that updates itself: the agent runs again if the switch is on (already running is fine).
    static func resume() { if isOn { launchctl("bootstrap", "gui/\(getuid())", plist.path) } }

    @discardableResult private static func launchctl(_ args: String...) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// The rail's Schedule button: a canvas of its own in place of the plan. On the left what runs on its own, next first
/// — scheduled tasks, recurring buys, the stops and takes of open perps — and every time one of them ran; on the
/// right the one picked, in detail, with its runs. While nothing is scheduled, examples go into the chat with a click.
struct ScheduleCanvas: View {
    @Environment(Workspace.self) private var ws

    private struct Item: Identifiable {
        /// The key its runs carry (Activity.schedule).
        let id: String
        let icon: String, title: String, detail: String
        var cancel: (() -> Void)?
    }

    /// «Move deposited USDC to the best rates (max 40% per protocol)» for «rebalance USDC max 40% per protocol».
    static func readable(_ step: String) -> String {
        guard let s = WalletCommand.parse(step)?.summary else { return step }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static let examples = ["every week: rebalance USDC", "every day at 09:00: what's moving",
                           "every monday at 10:00: profit and loss week", "buy SOL for 5 USDC every week"]

    static func period(_ days: Int) -> String { days == 1 ? "day" : days == 7 ? "week" : days == 30 ? "month" : "\(days) days" }

    var body: some View {
        let items = upcoming
        let runs = Array(ws.activities.reversed().lazy.compactMap(ran).prefix(200))
        // A cancelled task that never ran is gone: then the first one.
        let known = Set(items.map(\.id) + runs.compactMap(\.schedule))
        let picked = ws.scheduleItem.flatMap { known.contains($0) ? $0 : nil } ?? items.first?.id ?? runs.first?.schedule
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Schedule", close: { withAnimation(StudioView.spring) { ws.showSchedule = false } }) {
                StatusChip(text: KeepRunning.isOn ? "always running" : "while open", tint: KeepRunning.isOn ? Brand.profit : Brand.jevInk)
                if !KeepRunning.isOn {
                    Button("Keep it running…") { ws.openSettings(.general) }.buttonStyle(.borderless).font(.ui(11, .semibold))
                }
            }
            ScrollView {
                // Side by side while both fit left of the docked chat; else the picked one on top.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        list(items, runs, picked).frame(width: 420)
                        detail(picked, runs).frame(width: 470)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        detail(picked, runs)
                        list(items, runs, picked)
                    }
                    .frame(width: 470)
                }
                .padding(.leading, 28).padding(.trailing, StudioView.chatColumn).padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Tasks and recurring buys by their next run, then every open perp: its stop and take run on their own too.
    private var upcoming: [Item] {
        let dated = ws.tasks.map { t in
            (t.next, Item(id: "task:\(t.id)", icon: t.every == nil ? "calendar.badge.clock" : "repeat",
                          title: t.steps.map(Self.readable).joined(separator: " → "), detail: t.when) { ws.tasks.removeAll { $0.id == t.id } })
        } + ws.schedules.map { b in
            (b.next, Item(id: "buy:\(b.symbol)", icon: "cart", title: "Buy \(b.symbol) for \(Fmt.usd(b.usdc))",
                          detail: "every \(Self.period(b.days)) · next \(Fmt.date(b.next))") { ws.schedules.removeAll { $0.symbol == b.symbol } })
        }
        return dated.sorted { $0.0 < $1.0 }.map(\.1) + ws.positions.map { p in
            Item(id: "perp:\(p.coin)", icon: "chart.line.uptrend.xyaxis", title: "\(p.size > 0 ? "Long" : "Short") \(IntentParser.pretty(p.coin))",
                 detail: rules(p.coin).joined(separator: " · "))
        }
    }

    /// What a perp does on its own: the stop and takes on the exchange, the app's trailing and breakeven.
    private func rules(_ coin: String) -> [String] {
        let triggers = ws.orders.filter { $0.coin == coin && $0.isTrigger }
        var out = triggers.filter { ($0.orderType ?? "").contains("Stop") }.compactMap(\.triggerPx).map { "stop \(Fmt.price($0))" }
        if out.isEmpty { out = ["no stop on the exchange"] }
        out += triggers.filter { ($0.orderType ?? "").contains("Take") }.compactMap(\.triggerPx).map { "take \(Fmt.price($0))" }
        if let r = ws.exitRules[coin] {
            if let pct = r.trailingPct { out.append("trailing \(Fmt.pct(pct))") }
            if r.breakevenAfterPartial { out.append(r.movedToBreakeven ? "stop at breakeven" : "breakeven after the first take") }
        }
        return out
    }

    private static func icon(_ key: String?) -> String {
        key?.hasPrefix("buy:") == true ? "cart" : key?.hasPrefix("perp:") == true ? "chart.line.uptrend.xyaxis" : "calendar.badge.clock"
    }

    // MARK: Left: next and ran

    private func list(_ items: [Item], _ runs: [Activity], _ picked: String?) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                heading("Next", "clock")
                if items.isEmpty {
                    Text("Nothing scheduled. Tell the chat when and what, in any words — or start from one of these:")
                        .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Flow(spacing: 6) {
                        ForEach(Self.examples, id: \.self) { e in
                            Button { ws.draft = e } label: {
                                Text(e).font(.ui(12, .medium)).padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(Brand.glassFill)).overlay(Capsule().strokeBorder(Brand.cardBorder))
                            }
                            .buttonStyle(.plain).modifier(HoverLift(radius: 14)).help("Put it in the chat")
                        }
                    }
                }
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        row(item.id, picked: picked, icon: item.icon, title: item.title, detail: item.detail, time: nil)
                        if let cancel = item.cancel {
                            Button(action: cancel) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                                .buttonStyle(.hoverIcon).help("Cancel")
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                heading("Ran", "checkmark.circle")
                if runs.isEmpty {
                    Text("Nothing ran yet. Each run shows here with its time.").font(.ui(12)).foregroundStyle(.secondary)
                }
                ForEach(runs) { a in
                    row(a.schedule ?? "", picked: picked, icon: Self.icon(a.schedule), title: Self.title(a), detail: a.lines.last ?? "", time: a.at)
                }
            }
            Text(KeepRunning.isOn ? "Money moves wait for your Confirm and Touch ID; a notification says when. Stops and takes sit on the exchange; trailing and breakeven run while ihatecrypto does."
                                  : "Runs only while ihatecrypto is open. Stops and takes sit on the exchange either way.")
                .font(.ui(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// «Scheduled: …» is how a task's run reads in the chat; here the icon says it.
    private static func title(_ a: Activity) -> String {
        let t = a.request ?? a.title ?? "ihatecrypto"
        return steps(t) ?? t
    }

    private static func steps(_ request: String) -> String? {
        ["Scheduled: ", "По расписанию: "].first(where: request.hasPrefix).map { String(request.dropFirst($0.count)) }
    }

    /// A run of something scheduled. Runs from before they carried their key (2026-09-29) are found by their
    /// «Scheduled: …» request: under the task that still has those steps, else under the steps themselves.
    private func ran(_ a: Activity) -> Activity? {
        if a.schedule != nil { return a }
        guard a.kind == .request, let steps = a.request.flatMap(Self.steps) else { return nil }
        var run = a
        run.schedule = ws.tasks.first { t in [", then ", ", потом "].contains { t.steps.joined(separator: $0) == steps } }
            .map { "task:\($0.id)" } ?? "ran:" + steps
        return run
    }

    private func heading(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon).font(.ui(11, .heavy)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    private func row(_ key: String, picked: String?, icon: String, title: String, detail: String, time: Date?) -> some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { ws.scheduleItem = key } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(13, .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if !detail.isEmpty { Text(detail).font(.ui(11)).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 8)
                if let time { Text(Fmt.date(time)).font(.ui(10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize() }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(key == picked ? Brand.accent : Brand.cardBorder, lineWidth: key == picked ? 1.5 : 1))
        }
        .buttonStyle(LitBlock(radius: 14))
    }

    // MARK: Right: the picked one

    @ViewBuilder private func detail(_ key: String?, _ runs: [Activity]) -> some View {
        let mine = runs.filter { $0.schedule == key }
        VStack(alignment: .leading, spacing: 14) {
            if let key, let t = ws.tasks.first(where: { "task:\($0.id)" == key }) {
                TaskDetail(task: t)
            } else if let key, let b = ws.schedules.first(where: { "buy:\($0.symbol)" == key }) {
                ScheduleBoard(schedule: b)
            } else if let key, let p = ws.positions.first(where: { "perp:\($0.coin)" == key }) {
                PositionBoard(position: p)
                facts(rules(p.coin), title: "Runs on its own")
            } else if let first = mine.first {
                // Done or cancelled: what it did is all that's left.
                facts(["No longer scheduled."], title: Self.title(first))
            } else {
                Text("Pick something on the left to see it in detail.").font(.ui(12)).foregroundStyle(.secondary)
            }
            if key != nil {
                heading(mine.isEmpty ? "Hasn’t run yet" : "Runs · \(mine.count)", "clock.arrow.circlepath").padding(.top, 6)
                ForEach(mine) { a in
                    VStack(alignment: .trailing, spacing: 4) {
                        ActivityCard(activity: a)
                        if let id = a.canvas, let c = ws.canvases.first(where: { $0.id == id }) {
                            Button { ws.showSchedule = false; ws.openCanvas(c) } label: { Label("Open its canvas", systemImage: "rectangle.on.rectangle") }
                                .buttonStyle(.borderless).font(.ui(10, .semibold))
                        }
                    }
                }
            }
        }
    }

    private func facts(_ lines: [String], title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.ui(14, .semibold)).fixedSize(horizontal: false, vertical: true)
            ForEach(lines, id: \.self) { Label($0, systemImage: "checkmark.shield").font(.ui(12)).foregroundStyle(.secondary) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Brand.cardBorder))
    }
}

/// One scheduled task in detail: when, how often, each step as ihatecrypto reads it and as it will be typed.
private struct TaskDetail: View {
    @Environment(Workspace.self) private var ws
    let task: ScheduledTask

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: task.every == nil ? "calendar.badge.clock" : "repeat").foregroundStyle(Brand.accentInk).font(.system(size: 16, weight: .semibold))
                Text(task.steps.map(ScheduleCanvas.readable).joined(separator: " → ")).font(.ui(15, .bold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                StatusChip(text: task.every.map { "every \($0.words)" } ?? "once", tint: Brand.accentInk)
            }
            RouteCards(steps: [ActivityBubble(kind: "step", label: task.every.map { "EVERY \($0.words.uppercased()) · RUN" } ?? "LATER · SCHEDULE",
                                              title: Fmt.date(task.next),
                                              lines: ["then\t\(task.every.map { "again every \($0.words)" } ?? "done, it’s removed")"] + task.steps.map(ScheduleCanvas.readable),
                                              fill: .check)])
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(task.steps.enumerated()), id: \.offset) { i, step in
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
                    if i < task.steps.count - 1 { Divider() }
                }
            }
            HStack(alignment: .top) {
                Text("Runs on a canvas of its own. A money move waits there for your Confirm; the steps after it wait for the move.")
                    .font(.ui(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Cancel") { ws.tasks.removeAll { $0.id == task.id } }.buttonStyle(.borderless).foregroundStyle(Brand.loss)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.cardBorder))
    }

}
