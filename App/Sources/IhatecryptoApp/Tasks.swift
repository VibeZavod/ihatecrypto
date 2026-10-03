import AppKit
import IhatecryptoCore
import SignerAPI
import SwiftUI
import TradeExecution
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
        guard !schedulePaused, let i = tasks.firstIndex(where: { $0.next <= Date() && $0.paused != true }), canSwitchCanvas, !thinking, !preparing,
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
    /// `brought`: the networks a move before these steps delivered USDC to (the first step of the chain, gone through).
    func runSteps(_ steps: [String], confirmed: Bool = false, brought: Set<String> = []) async {
        thinking = true
        var rest: [String] = []
        var arrived = brought
        for (k, step) in steps.enumerated() {
            let command = WalletCommand.parse(step)
            defer { if let c = command, let to = Self.arrives(c) { arrived.insert(to) } }
            // The move before this step is done: let it go first, so the canvas keeps it as an earlier move. Cleared only
            // after, the next step's card was saved over it with its «Done» (a Base → Robinhood bridge vanished under
            // «Buy AI», and «Buy MOO» showed Done though it never ran).
            if confirmed {
                finishedAction = nil
                chainAhead = (canvasID, Array(steps[(k + 1)...]))
                showNext(step)
                // Money a move before brought to Solana: this step waits until Solana's balance shows it.
                if arrived.contains("solana"), let c = command, Self.spends(c) == "solana", let need = Self.solanaUSDC(c) {
                    await waitForDeposit(need, then: step)
                }
            }
            // The first step reads the balances as they are now: one that can't be paid is said before any card
            // («Move 0 USDC · Ethereum → Arbitrum» was drawn). Later steps wait for the money the ones before bring.
            if k == 0, !confirmed, TaskRun.automation == nil, let c = WalletCommand.parse(step), let why = refusalBeforeCard(c) {
                reply(why)
                break
            }
            // After a move, a step spends what the move brought, Relay's cents taken off.
            let step = confirmed ? await fittedToArrival(step) : step
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
                              "Все шаги на холсте — один Confirm на всю цепочку, или напиши что-нибудь другое, чтобы отменить.",
                              "Todos los pasos están en el lienzo: un Confirm para toda la cadena, o di otra cosa para cancelar."))
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
        if confirmed {
            // A step that stopped before its move leaves its «Next» board; the outcome board shows from here.
            chainAhead = nil
            runningAction = nil
        }
        snapshotCanvas()
        saveCanvas()
        taskQueue = rest.isEmpty ? nil : (canvasID, rest, Date(), arrived)
    }

    /// A step that spends money on a network, run after a move landed there: when the move's fee left it a little short
    /// of the step's amount (cents from an L2, under a dollar from Ethereum), the step spends what is there. «Move 5 then
    /// spread 5», «move 100 then lend 100» spend what arrived, and nothing has to be held back for the fee (a dollar was:
    /// «переведи 100 и положи в aave» lent 99 and left a dollar on Arbitrum). A bigger gap is left for the step to refuse.
    func fittedToArrival(_ step: String) async -> String {
        guard let c = WalletCommand.parse(step), let net = Self.spends(c), let asked = c.editableAmount, asked > 0 else { return step }
        let there: Decimal?
        if net == "solana" {
            await loadSolana()
            there = solana?.usdc
        } else if let n = EVMNetwork.named(net), let units = try? await n.rpc.tokenBalance(n.usdc, owner: hlAddress) {
            // Tempo's fees come out of the USDC itself: a cent stays.
            there = max(0, Decimal(units) / 1_000_000 - (n.key == "tempo" ? Decimal(string: "0.01")! : 0))
        } else {
            there = nil
        }
        guard let there, there < asked, asked - there <= max(1, asked * Decimal(string: "0.02")!) else { return step }
        let fitted = c.with(amount: there.rounded(2, .down))
        // Run again from its words: only a command that reads back the same.
        return WalletCommand.parse(fitted.summary) == fitted ? fitted.summary : step
    }

    /// When a move finishes: the rest of a scheduled task, if the move was on its canvas, went through, and came
    /// within half an hour (a card waits 15 minutes; a later move on that canvas is something else).
    func continueTask() {
        guard let q = taskQueue else { return }
        taskQueue = nil
        guard q.canvas == canvasID, finishedAction?.outcome.ok == true, Date().timeIntervalSince(q.since) < 1800, let first = q.steps.first else { return }
        // The next step's board in the same breath as the move's goes: no frame where the chain's cards are gone.
        chainAhead = (q.canvas, Array(q.steps.dropFirst()))
        showNext(first)
        Task { await runSteps(q.steps, confirmed: true, brought: q.brought) }
    }

    /// The step a confirmed chain goes to, lit, before its move's own board takes its place.
    private func showNext(_ step: String) {
        runningAction = (say("Next: ", "Дальше: ", "Siguiente: ") + readable(ScheduleCanvas.readable(step)), chainSteps(of: [step]), [], Date())
    }

    /// A step that spends on Solana what a move before it brought: a card of its own («ARRIVES · SOLANA») until
    /// Solana's balance shows the money, two minutes at most; then the step goes on and its own check says what's short.
    private func waitForDeposit(_ need: Decimal, then step: String) async {
        guard let have = solana?.usdc, have < need else { return }
        func card(_ have: Decimal) -> ActivityBubble {
            ActivityBubble(kind: "step", label: "ARRIVES · SOLANA", title: "\(Fmt.num(need)) USDC",
                           lines: [say("on Solana now", "на Solana сейчас", "en Solana ahora") + "\t\(Fmt.num(have)) USDC",
                                   say("then", "потом", "luego") + "\t" + readable(ScheduleCanvas.readable(step))],
                           logo: "sol", fill: .solana)
        }
        runningAction = (say("Waiting for the deposit on Solana", "Жду депозит на Solana", "Esperando el depósito en Solana"),
                         [card(have)] + chainSteps(of: [step]), [], Date())
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(2))
            await loadSolana()
            let now = solana?.usdc ?? 0
            if now >= need { break }
            runningAction?.steps[0] = card(now)
        }
    }

    /// The USDC a step spends on Solana: what it waits for when a move before it brings the money.
    static func solanaUSDC(_ c: WalletCommand) -> Decimal? {
        switch c {
        case .lendDeposit("USDC", let a), .kamino(deposit: true, symbol: "USDC", amount: let a), .hlp(deposit: true, amount: let a), .buy(_, usdc: let a),
             .allocate("USDC", maxShare: _, amount: let a, without: _, from: "solana"): a
        default: nil
        }
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
    static let label = "app.ihatecrypto.mac.keeprunning"
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
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "app.ihatecrypto.mac"],
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
/// What the Schedule says about its items, shared by the frame, an item's canvas and the alerts.
enum ScheduleCanvas {
    /// «Move deposited USDC to the best rates (max 40% per protocol)» for «rebalance USDC max 40% per protocol».
    static func readable(_ step: String) -> String {
        guard let s = WalletCommand.parse(step)?.summary else { return step }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func period(_ days: Int) -> String { days == 1 ? "day" : days == 7 ? "week" : days == 30 ? "month" : "\(days) days" }
}

/// One scheduled task in detail: when, how often, each step as ihatecrypto reads it and as it will be typed.
struct TaskDetail: View {
    @Environment(Workspace.self) private var ws
    let task: ScheduledTask

    /// A step that moves money: without an automation wallet it would wait for Confirm and Touch ID.
    private var movesMoney: Bool {
        task.steps.contains { step in
            switch WalletCommand.parse(step) {
            case nil, .yields?, .receive?, .schedule?, .stopSchedules?: false
            default: true
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
            let automation = task.untrusted == true ? nil : ws.wallets.first(where: \.isAutomation)
            if automation == nil, task.untrusted != true, movesMoney { automationOffer }
            HStack(alignment: .top) {
                Text(automation.map { "Runs on a canvas of its own, from the automation wallet «\($0.label)» — no Touch ID; a trade plan still waits for Execute." }
                     ?? "Runs on a canvas of its own. A money move waits there for your Confirm; the steps after it wait for the move.")
                    .font(.ui(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Cancel") { ws.tasks.removeAll { $0.id == task.id } }.buttonStyle(.borderless).foregroundStyle(Brand.loss).pointerStyle(.link)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.cardBorder))
    }

}
