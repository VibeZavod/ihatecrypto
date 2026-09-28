import AppKit
import LalaCore
import SwiftUI
import WalletCore

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
        tasks.append(task)
        showSchedule = true   // the canvas shows it: the chat keeps one line
        let what = task.steps.joined(separator: say(", then ", ", потом "))
        reply(say("Scheduled: \(what) — \(task.when). It’s on the canvas.", "Запланировано: \(what) — \(task.when). Это на канвасе."), note: note)
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
            || AddressBookCommand.parse(step) != nil || WalletCommand.parse(step) != nil || PositionCommand.parse(step) != nil
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
        let request = say("Scheduled: ", "По расписанию: ") + task.steps.joined(separator: say(", then ", ", потом "))
        messages.append(Message(fromUser: true, text: request))
        beginActivity(.request, request: request)
        await runSteps(task.steps)
        let waits = pendingAction != nil || pendingAllocation != nil
        notify(waits ? .confirm : .moves, request, waits ? say("Ready on its canvas — press Confirm.", "Готово на своём канвасе — нажми Confirm.")
                                                         : messages.last.map(\.text) ?? "")
    }

    /// Steps one after another. One that waits for Confirm holds the rest until its move has gone through
    /// (`continueTask`): they may need the money it moves.
    func runSteps(_ steps: [String]) async {
        thinking = true
        var rest: [String] = []
        for (k, step) in steps.enumerated() {
            guard await runCanonical(step, userText: step, before: intent) else {
                reply(say("ihatecrypto can’t do “\(step)” — the scheduled task stops here.", "ihatecrypto не умеет «\(step)» — задача по расписанию на этом останавливается."))
                break
            }
            if pendingAction != nil || pendingAllocation != nil || awaitingAmount != nil { rest = Array(steps[(k + 1)...]); break }
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
        Task { await runSteps(q.steps) }
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

/// The rail's Schedule button: everything that runs on its own, next first — scheduled tasks and recurring buys, each
/// with ✕ — and, while there is nothing, examples that go into the chat with a click.
struct ScheduleOverview: View {
    @Environment(Workspace.self) private var ws

    private struct Run: Identifiable {
        let id: String, date: Date, title: String, detail: String, icon: String
        let cancel: () -> Void
    }

    /// «Move deposited USDC to the best rates (max 40% per protocol)» for «rebalance USDC max 40% per protocol».
    static func readable(_ step: String) -> String {
        guard let s = WalletCommand.parse(step)?.summary else { return step }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static let examples = ["every week: rebalance USDC", "every day at 09:00: what's moving",
                           "every monday at 10:00: profit and loss week", "buy SOL for 5 USDC every week"]

    var body: some View {
        let runs = (ws.tasks.map { t in
            Run(id: t.id.uuidString, date: t.next, title: t.steps.map(Self.readable).joined(separator: " → "), detail: t.when,
                icon: t.every == nil ? "calendar.badge.clock" : "repeat") { ws.tasks.removeAll { $0.id == t.id } }
        } + ws.schedules.map { b in
            Run(id: "buy-" + b.symbol, date: b.next, title: "Buy \(b.symbol) for \(Fmt.usd(b.usdc))",
                detail: "every \(b.days == 1 ? "day" : b.days == 7 ? "week" : "\(b.days) days") · next \(Fmt.date(b.next))",
                icon: "cart") { ws.schedules.removeAll { $0.symbol == b.symbol } }
        }).sorted { $0.date < $1.date }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "calendar").foregroundStyle(Brand.accentInk).font(.system(size: 16, weight: .semibold))
                Text("Schedule").font(.ui(16, .bold))
                Spacer()
                StatusChip(text: KeepRunning.isOn ? "always running" : "while open", tint: KeepRunning.isOn ? Brand.profit : Brand.jevInk)
                Button { withAnimation(StudioView.spring) { ws.showSchedule = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.hoverIcon).help("Close")
            }
            if runs.isEmpty {
                Text("Nothing scheduled. Tell the chat when and what, in any words — or start from one of these:")
                    .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Flow(spacing: 6) {
                    ForEach(Self.examples, id: \.self) { e in
                        Button { ws.draft = e } label: {
                            Text(e).font(.ui(12, .medium)).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Brand.glassFill)).overlay(Capsule().strokeBorder(Brand.cardBorder))
                        }
                        .buttonStyle(.plain).pointerStyle(.link).help("Put it in the chat")
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(runs) { r in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: r.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).font(.ui(13, .semibold)).fixedSize(horizontal: false, vertical: true)
                                Text(r.detail).font(.ui(11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button(action: r.cancel) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                                .buttonStyle(.hoverIcon).help("Cancel")
                        }
                        .padding(.vertical, 9)
                        if r.id != runs.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 18).fill(Brand.card))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Brand.cardBorder))
            }
            HStack(spacing: 6) {
                Text(KeepRunning.isOn ? "Money moves wait for your Confirm and Touch ID; a notification says when."
                                      : "Runs only while ihatecrypto is open.")
                    .font(.ui(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !KeepRunning.isOn {
                    Button("Keep it running…") { ws.openSettings(.general) }.buttonStyle(.borderless).font(.ui(10, .semibold))
                }
            }
        }
        .frame(width: 470, alignment: .leading)
    }
}
