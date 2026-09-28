import AppKit
import LalaCore
import SwiftUI
import WalletCore

// Scheduled tasks («in 1 week: rebalance USDC», «every day at 09:00: sell SOL then lend USDC» — ScheduledTask) and
// Settings › General › Keep running, which keeps the app up so they run.

extension Workspace {
    /// Keeps a task if every step is something ihatecrypto does; the schedule board on an empty canvas lists it.
    func schedule(_ task: ScheduledTask, note: String? = nil) {
        if let unknown = task.steps.first(where: { !knows($0) }) {
            reply(say("I can schedule that, but ihatecrypto can’t do “\(unknown)” yet — nothing was scheduled.",
                      "Запланировать могу, но «\(unknown)» ihatecrypto пока не умеет — ничего не запланировано."), note: note)
            return
        }
        tasks.append(task)
        let what = task.steps.joined(separator: say(", then ", ", потом "))
        let moves = task.steps.contains { WalletCommand.parse($0) != nil || PositionCommand.parse($0) != nil }
        reply(say("Scheduled: \(what) — \(task.when).", "Запланировано: \(what) — \(task.when).")
              + (moves ? say(" Money moves wait for your Confirm on their canvas; a notification says when.",
                             " Переводы ждут твоего Confirm на своём канвасе — придёт уведомление.") : "")
              + (KeepRunning.isOn ? "" : say(" ihatecrypto has to be running then: turn on Settings › General › Keep running.",
                                             " В это время ihatecrypto должен быть запущен: включи Settings › General › Keep running.")), note: note)
    }

    func cancelTasks(note: String? = nil) {
        let n = tasks.count
        tasks = []
        taskQueue = nil
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

/// On an empty canvas, under the recurring buys: what is scheduled, when it runs next, and ✕ to drop it.
struct TasksBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Scheduled", systemImage: "calendar.badge.clock").font(.ui(15, .bold))
                Spacer()
                StatusChip(text: KeepRunning.isOn ? "always running" : "while open", tint: KeepRunning.isOn ? Brand.profit : Brand.jevInk)
            }
            VStack(spacing: 0) {
                ForEach(ws.tasks) { task in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.steps.joined(separator: " → ")).font(.ui(13, .semibold)).fixedSize(horizontal: false, vertical: true)
                            Text(task.when).font(.ui(11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button { ws.tasks.removeAll { $0.id == task.id } } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                            .buttonStyle(HoverIconStyle()).help("Cancel this task")
                    }
                    .padding(.vertical, 8)
                    if task.id != ws.tasks.last?.id { Divider() }
                }
            }
            Text(KeepRunning.isOn ? "Money moves wait for your Confirm and Touch ID; a notification says when."
                                  : "Runs only while ihatecrypto is open. Settings › General › Keep running keeps it up.")
                .font(.ui(10)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 470)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card).shadow(color: .black.opacity(0.06), radius: 14, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.cardBorder))
    }
}
