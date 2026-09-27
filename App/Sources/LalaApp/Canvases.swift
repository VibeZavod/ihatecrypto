import Foundation
import LalaCore
import LLMCatalog
import SwiftUI
import TradeExecution
import WalletCore

/// Owner-only JSON files in Application Support/LALA.
enum LocalStore {
    static func url(_ name: String) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "LALA")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name)
    }

    static func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        let file = url(name)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// One canvas: its chat, its plan, the model it was talked through and the bubbles last on it.
/// Kept on this Mac (canvases.json, owner-only); the canvas open at quit opens again at launch.
struct CanvasSession: Codable, Identifiable {
    var id = UUID()
    var updated = Date()
    var title = ""
    var providerID: String
    var model: String
    var messages: [Message]
    var intent: TradeIntent
    /// The plan was carried out: the canvas shows the position, not a new trade.
    var executed = false
    var bubbles: [ActivityBubble] = []
    /// The user's own name for it; wins over the title LALA keeps updating. Optional, so older files still load.
    var name: String?
    /// The folder it sits in, by name; nil = no folder. A folder exists while a canvas is in it.
    var folder: String?
    /// The money move on its board was carried out: when, and whether it went through.
    var outcome: CanvasOutcome?
    /// When the board was last live.
    var boardAt: Date?
    /// The chart on it, candles included: reopened, it shows this snapshot until Refresh.
    var chart: ChartState?

    var displayTitle: String { name ?? (title.isEmpty ? "Canvas" : title) }
}

/// A money move carried out from a canvas.
struct CanvasOutcome: Codable, Equatable {
    var at: Date
    var ok: Bool
}

extension Workspace {
    /// Keeps the open canvas: after every message and reply, and at quit. An empty canvas (no message, nothing
    /// on the board) is not kept.
    func saveCanvas() {
        guard messages.contains(where: \.fromUser) || canvasBubbles() != nil else { return }
        let old = canvases.first { $0.id == canvasID }
        var c = old ?? CanvasSession(providerID: providerID, model: model, messages: [], intent: intent)
        c.providerID = providerID
        c.model = model
        c.messages = messages
        c.intent = intent
        c.executed = executed != nil && executed == intent
        c.chart = chart
        if let board = canvasBubbles() {
            c.title = board.title
            c.bubbles = board.bubbles
            c.outcome = finishedAction?.outcome
            c.boardAt = Date()
            savedBoard = nil
        } else if c.title.isEmpty, let first = messages.first(where: \.fromUser)?.text {
            c.title = first.count > 48 ? String(first.prefix(48)) + "…" : first
        }
        // The list is ordered by what the user did on a canvas: opening it, or prices moving on its board, doesn't lift it.
        if old.map({ $0.messages != c.messages || $0.intent != c.intent || $0.providerID != c.providerID || $0.model != c.model
                     || $0.title != c.title || $0.outcome != c.outcome }) ?? true {
            c.updated = Date()
        }
        canvasID = c.id
        if let i = canvases.firstIndex(where: { $0.id == c.id }) { canvases[i] = c } else { canvases.append(c) }
    }

    func openCanvas(_ c: CanvasSession) {
        guard c.id != canvasID, !busy else { return }
        saveCanvas()
        load(c)
        Task { await refreshQuote() }
    }

    func newCanvas() {
        guard !busy else { return }
        saveCanvas()
        clearCanvas()
        canvasID = nil
        messages = Array(messages.prefix(1))
        intent = TradeIntent()
        executed = nil
    }

    /// An empty name gives the canvas back its automatic title.
    func renameCanvas(_ id: UUID, to name: String) {
        guard let i = canvases.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        canvases[i].name = trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    /// nil takes it out of its folder.
    func moveCanvas(_ id: UUID, to folder: String?) {
        guard let i = canvases.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        canvases[i].folder = trimmed?.isEmpty == false ? String(trimmed!.prefix(40)) : nil
    }

    var canvasFolders: [String] { Array(Set(canvases.compactMap(\.folder))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    func deleteCanvas(_ id: UUID) {
        if id == canvasID { newCanvas() }
        canvases.removeAll { $0.id == id }
    }

    /// The canvas that was open last time (else the one worked on last).
    func restoreLastCanvas() {
        let open = UserDefaults.standard.string(forKey: "openCanvas").flatMap(UUID.init(uuidString:))
        if let last = canvases.first(where: { $0.id == open }) ?? canvases.max(by: { $0.updated < $1.updated }) { load(last) }
    }

    private func load(_ c: CanvasSession) {
        clearCanvas()
        canvasID = c.id
        messages = c.messages
        intent = c.intent
        executed = c.executed ? c.intent : nil
        if LLMCatalog.provider(id: c.providerID) != nil {
            providerID = c.providerID
            modelChoices[c.providerID] = c.model
        }
        // A chart comes back as the chart itself, from its snapshot; one saved before snapshots is loaded fresh.
        chart = c.chart ?? c.bubbles.first { $0.label.hasPrefix("Chart ·") && !$0.asset.isEmpty }.map { b in
            ChartState(coin: b.asset, range: ChartCommand.Range.allCases.first { b.label.hasSuffix($0.title) } ?? .day)
        }
        savedBoard = c.bubbles.isEmpty || chart != nil ? nil : c
        if let ch = chart, ch.candles.isEmpty { Task { await openChart(ch.coin, range: ch.range) } }
    }

    /// What belongs to one canvas only: boards, waiting confirmations, the draft.
    private func clearCanvas() {
        takeChoices = nil
        yieldOptions = nil
        allocationPreview = nil
        pendingAllocation = nil
        pendingAction = nil
        pendingText = nil
        finishedAction = nil
        planReview = nil
        savedBoard = nil
        chart = nil
        currentActivity = nil
        draft = ""
    }
}

// MARK: Views

/// The saved canvases, newest first; a click opens one with its chat, plan and model.
struct CanvasList: View {
    @Environment(Workspace.self) private var ws
    /// Its own scroll view in the popover; the rail scrolls the list together with everything above it.
    var scrolls = true
    var close: (() -> Void)?
    /// Folded folders, one name per line; kept between launches.
    @AppStorage("foldedCanvasFolders") var foldedRaw = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Canvases").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { withAnimation(StudioView.spring) { ws.newCanvas() }; close?() } label: {
                    Label("New", systemImage: "square.and.pencil").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless).help("New canvas").disabled(ws.busy)
            }
            let items = ws.canvases.sorted { $0.updated > $1.updated }
            if items.isEmpty {
                Text("Each conversation gets its own canvas and is kept here.").font(.caption).foregroundStyle(.tertiary)
            }
            if scrolls {
                ScrollView { rows(items) }.scrollIndicators(.never)
            } else {
                rows(items)
            }
        }
    }
}

extension CanvasList {
    /// Folders first (open or folded), then the canvases in no folder; newest first inside each.
    private func rows(_ items: [CanvasSession]) -> some View {
        let folded = Set(foldedRaw.split(separator: "\n").map(String.init))
        return LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(ws.canvasFolders, id: \.self) { folder in
                FolderRow(name: folder, count: items.filter { $0.folder == folder }.count, folded: folded.contains(folder)) {
                    var set = folded
                    if set.contains(folder) { set.remove(folder) } else { set.insert(folder) }
                    withAnimation(.snappy) { foldedRaw = set.sorted().joined(separator: "\n") }
                }
                if !folded.contains(folder) {
                    ForEach(items.filter { $0.folder == folder }) { row($0).padding(.leading, 12) }
                }
            }
            ForEach(items.filter { $0.folder == nil }) { row($0) }
        }
    }

    private func row(_ c: CanvasSession) -> some View {
        CanvasRow(canvas: c, current: c.id == ws.canvasID) {
            withAnimation(StudioView.spring) { ws.openCanvas(c) }
            close?()
        }
    }
}

/// A folder of canvases: a click folds or unfolds it.
struct FolderRow: View {
    let name: String
    let count: Int
    let folded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                Image(systemName: folded ? "folder" : "folder.fill").font(.system(size: 12)).foregroundStyle(Brand.accent)
                Text(name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(folded ? "Show the canvases in \(name)" : "Fold \(name)")
    }
}

struct CanvasRow: View {
    @Environment(Workspace.self) private var ws
    let canvas: CanvasSession
    let current: Bool
    let open: () -> Void
    @State private var hover = false
    @State private var renaming = false
    @State private var draft = ""
    @State private var newFolder = false
    @State private var folderName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if renaming {
                content
            } else {
                Button(action: open) { content }.buttonStyle(.plain)
            }
            // The three dots show under the pointer, like ChatGPT's sidebar; they stay in the layout so an open menu
            // keeps its anchor when the pointer moves onto it.
            Menu { actions } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .pointerStyle(.link)
            .opacity(hover && !renaming ? 1 : 0)
            .allowsHitTesting(hover && !renaming)
            .help("Rename, move to a folder, delete")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(current ? Brand.accent.opacity(0.1) : hover ? Color.primary.opacity(0.05) : .clear))
        .onHover { hover = $0 }
        .help("\(canvas.displayTitle) · \(LLMCatalog.provider(id: canvas.providerID)?.info.name ?? canvas.providerID) · \(canvas.model)")
        .contextMenu { actions }
        .alert("New folder", isPresented: $newFolder) {
            TextField("Folder name", text: $folderName)
            Button("Create") { withAnimation(.snappy) { ws.moveCanvas(canvas.id, to: folderName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(canvas.displayTitle)” goes into it.")
        }
    }

    private var content: some View {
        HStack(spacing: 9) {
            if canvas.intent != TradeIntent() {
                AssetBadge(coin: canvas.intent.asset, size: 26, dark: true)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Brand.accent.opacity(0.12)).frame(width: 26, height: 26)
                    .overlay(Image(systemName: canvas.bubbles.isEmpty ? "bubble.left" : "square.grid.2x2").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.accent))
            }
            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain).font(.system(size: 12.5, weight: .semibold))
                        .focused($nameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { renaming = false }
                        .onChange(of: nameFocused) { if !nameFocused, renaming { commitRename() } }
                } else {
                    Text(canvas.displayTitle).font(.system(size: 12.5, weight: current ? .semibold : .regular)).lineLimit(1)
                }
                Text("\(canvas.model) · \(Fmt.date(canvas.updated))").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var actions: some View {
        Button("Rename") {
            draft = canvas.displayTitle
            renaming = true
            DispatchQueue.main.async { nameFocused = true }
        }
        Menu("Move to folder") {
            let others = ws.canvasFolders.filter { $0 != canvas.folder }
            ForEach(others, id: \.self) { f in
                Button(f) { withAnimation(.snappy) { ws.moveCanvas(canvas.id, to: f) } }
            }
            if !others.isEmpty { Divider() }
            Button("New folder…") { folderName = ""; newFolder = true }
            if let current = canvas.folder {
                Button("Remove from “\(current)”") { withAnimation(.snappy) { ws.moveCanvas(canvas.id, to: nil) } }
            }
        }
        Divider()
        Button("Delete canvas", role: .destructive) { withAnimation { ws.deleteCanvas(canvas.id) } }
    }

    private func commitRename() {
        renaming = false
        ws.renameCanvas(canvas.id, to: draft)
    }
}

/// A canvas opened again whose board isn't a live plan: its bubbles as they were.
struct SavedBoard: View {
    let canvas: CanvasSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let o = canvas.outcome {
                Label("\(o.ok ? "Executed" : "Failed") · \(Fmt.date(o.at))", systemImage: o.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(o.ok ? Brand.profit : Brand.loss)
            } else {
                Label("As it was · \(Fmt.date(canvas.boardAt ?? canvas.updated)). Ask again for fresh numbers.", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !canvas.bubbles.isEmpty, canvas.bubbles.allSatisfy({ $0.kind == "step" }) {
                RouteSteps(steps: canvas.bubbles).frame(width: 470, alignment: .leading)
            } else {
                LazyVGrid(columns: [GridItem(.fixed(220), alignment: .top), GridItem(.fixed(220), alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(canvas.bubbles, id: \.self) { HistoryBubble(bubble: $0) }
                }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
    }
}

/// A row in LALA's own menus: a title, an optional detail, a hover highlight.
struct MenuRow: View {
    let title: String
    var detail: String?
    var icon: String?
    var shortcut: String?
    var checked = false
    var tint: Color = .primary
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).frame(width: 18).foregroundStyle(tint == .primary ? .secondary : tint) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 8)
                if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.secondary) }
                if checked { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.accent) }
            }
            .padding(.horizontal, 10).padding(.vertical, detail == nil ? 8 : 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(checked ? Brand.accent.opacity(0.09) : hover ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Recurring buys on the canvas (S09): the next runs, what each leaves on Solana, and where the money runs out.
struct ScheduleBoard: View {
    @Environment(Workspace.self) private var ws
    let schedule: Schedule

    var body: some View {
        let balance = ws.solana?.usdc
        let runs = (0..<4).map { k in
            (date: Calendar.current.date(byAdding: .day, value: k * schedule.days, to: schedule.next) ?? schedule.next,
             left: balance.map { $0 - Decimal(k + 1) * schedule.usdc })
        }
        let short = runs.first { ($0.left ?? 0) < 0 }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TokenLogo(name: "usdc", size: 26)
                Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                AssetBadge(coin: schedule.symbol, size: 26)
                Text("\(Fmt.usd(schedule.usdc)) → \(schedule.symbol) every \(period)").font(.system(size: 15, weight: .bold))
                Spacer()
                StatusChip(text: short == nil ? "running" : "runs short", tint: short == nil ? Brand.profit : Brand.jevInk)
            }
            HStack(alignment: .top, spacing: 10) {
                fact("EACH PURCHASE", "Jupiter quote, address check, simulation and signature — like a manual one")
                fact("A MONTH", "≈ \(Fmt.usd(schedule.usdc * 30 / Decimal(max(schedule.days, 1))))")
            }
            VStack(spacing: 0) {
                ForEach(runs.indices, id: \.self) { i in
                    let run = runs[i], enough = (run.left ?? 0) >= 0
                    HStack {
                        Text(i == 0 && schedule.next <= Date() ? "now" : Fmt.date(run.date)).monospacedDigit().frame(width: 130, alignment: .leading)
                        Text(Fmt.usd(schedule.usdc)).monospacedDigit()
                        Spacer()
                        Text(run.left.map { enough ? "Solana left \(Fmt.num($0)) USDC" : "not enough" } ?? "—")
                            .foregroundStyle(enough ? AnyShapeStyle(.secondary) : AnyShapeStyle(Brand.loss))
                    }
                    .font(.system(size: 12.5))
                    .padding(.vertical, 7)
                    if i < runs.count - 1 { Divider() }
                }
            }
            if let short {
                Label("On \(Fmt.date(short.date)) there won’t be enough USDC on Solana. Top up Solana or lower the amount.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Brand.jevInk)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Brand.jevInk.opacity(0.1)))
            }
            HStack {
                Text("Runs while LALA is open or in the menu bar.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { Task { await ws.send("stop recurring buys") } }.buttonStyle(.borderless).foregroundStyle(Brand.loss)
            }
        }
        .padding(16)
        .frame(width: 470)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card).shadow(color: .black.opacity(0.06), radius: 14, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.cardBorder))
    }

    private var period: String { schedule.days == 1 ? "day" : schedule.days == 7 ? "week" : schedule.days == 30 ? "month" : "\(schedule.days) days" }

    private func fact(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 9.5, weight: .heavy)).tracking(0.5).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.solanaTint))
    }
}

extension Workspace {
    /// For a plan the rules stop: the risk LALA suggests instead and what the trade looks like with it.
    var fittingRisk: (risk: Decimal, sizing: Sizing)? {
        let i = resolved.intent
        guard let m = market else { return nil }
        // ponytail: Solana USDC less a bridge-fee cushion plus what is free on Hyperliquid; the confirm step re-quotes exactly.
        let available = max(0, (solana?.usdc ?? 0) - Decimal(string: "0.1")!) + (hl.map { $0.withdrawable + (m.dex.flatMap { dexBalances[$0]?.withdrawable } ?? 0) } ?? 0)
        guard let r = Plan.fittingRisk(i, market: m, equity: equity, policy: policy,
                                       openRisk: HyperliquidAccount.riskAtStops(positions: positions, orders: orders), available: available) else { return nil }
        var j = i
        j.riskUSD = r
        return Plan.evaluate(j, market: m).sizing.map { (r, $0) }
    }
}

/// A plan the rules stop (S04): what fits instead, one click away.
struct FixChoices: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CHOOSE AN OPTION").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                if let fit = ws.fittingRisk {
                    card(badge: "LALA recommends", title: "Risk \(Fmt.usd(fit.risk))",
                         detail: "notional \(Fmt.usd(fit.sizing.notional)) · margin \(Fmt.usd(fit.sizing.margin)) — everything fits", recommended: true) {
                        Task { await ws.send("risk $\(fit.risk)") }
                    }
                }
                card(badge: "at your own risk", title: "Raise the limit",
                     detail: "now at most \(Fmt.pct(ws.policy.maxRiskPct)) per trade · in Settings", recommended: false) { openSettings() }
            }
        }
        .frame(width: 470, alignment: .leading)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func card(badge: String, title: String, detail: String, recommended: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(badge.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(0.5)
                    .foregroundStyle(recommended ? .white : .secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(recommended ? Brand.accent : Color.primary.opacity(0.07)))
                Text(title).font(.system(size: 17, weight: .heavy))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 20).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(recommended ? Brand.accent : Brand.cardBorder,
                                                                       style: StrokeStyle(lineWidth: recommended ? 2 : 1, dash: recommended ? [] : [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Confirm and Cancel under a board waiting for «do it»: the same path as typing «do it» or «cancel» in the chat,
/// so the signer, the guard and Jev see exactly what they would.
struct PendingButtons: View {
    @Environment(Workspace.self) private var ws
    var confirm = "Confirm"

    var body: some View {
        HStack(spacing: 8) {
            Button { Task { await ws.send("do it") } } label: {
                Label(confirm, systemImage: "signature").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            Button("Cancel") { Task { await ws.send("cancel") } }
                .buttonStyle(.bordered).controlSize(.large)
        }
        .disabled(ws.busy)
    }
}

/// A money move's route as the canvas draws it (S10). The steps are data, so the canvas keeps the route after the move
/// and shows it as it was, with Done or Failed and the time.
struct MoveRoute {
    let title: String
    let footer: String
    let steps: [ActivityBubble]
    var warning: String?
}

/// A route step's color, by place; kept by name, so a saved route draws the same.
enum RouteFill: String, Codable, Hashable, Sendable {
    case solana, relay, hyperliquid, hlp, jupiter, kamino, jito, aave, base, arbitrum, robinhood

    var color: Color {
        switch self {
        case .solana: Brand.solanaTint
        case .relay: Brand.relay
        case .hyperliquid: Brand.hl
        case .hlp: Brand.hlChip
        case .jupiter: Color(hex: 0x131D27)
        case .kamino: Color(hex: 0x082A56)
        case .jito: Color(hex: 0x1F9D6A)
        case .aave: Color(hex: 0x2B2D3C)
        case .base: Color(hex: 0x0052FF)
        case .arbitrum: Color(hex: 0x213147)
        case .robinhood: Color(hex: 0x3A4A00)
        }
    }
    var dark: Bool { self != .solana }
}

extension Workspace {
    /// The route of a money move waiting for «do it»: a withdrawal to Solana, USDC into Aave on Base, a stock token,
    /// a way back to Solana, or any move between the user's own places. nil for commands that aren't drawn as one.
    func route(_ command: WalletCommand) -> MoveRoute? {
        switch command {
        case .withdrawToSolana(let asked): withdrawRoute(asked)
        case .aave(deposit: true, amount: let amount?): aaveRoute(amount)
        case .aave(deposit: false, amount: let amount): backRoute(from: "aave", amount: amount)
        case .baseToSolana(let amount): backRoute(from: "base", amount: amount)
        case .arbitrumToSolana(let amount): backRoute(from: "arbitrum", amount: amount)
        case .robinhoodToSolana(let amount): backRoute(from: "robinhood", amount: amount)
        case .buyStock(let symbol, let usdc?): stockRoute(symbol, usdc)
        default: ends(command).map { from, to in
            MoveRoute(title: command.summary.prefix(1).uppercased() + command.summary.dropFirst(),
                      footer: "One Solana signature, checked and simulated before it’s signed. Say “do it” or press Confirm; anything else cancels.",
                      steps: [from, to])
        }
        }
    }

    private func step(_ logo: String, _ label: String, _ title: String, _ line: String, _ fill: RouteFill) -> ActivityBubble {
        ActivityBubble(kind: "step", label: label, title: title, lines: [line], logo: logo, fill: fill)
    }

    private func withdrawRoute(_ asked: Decimal?) -> MoveRoute {
        let free = hl?.withdrawable
        let amount = asked ?? free
        return MoveRoute(title: "Withdraw · \(amount.map { Fmt.num($0) } ?? "all") USDC to Solana",
                         footer: "Signed with the main key — the trading key can’t withdraw. Say “do it” or press Confirm; anything else cancels.", steps: [
            step("hype", "FROM · HYPERLIQUID", free.map { f in amount.map { "\(Fmt.usd(f)) → \(Fmt.usd(max(0, f - $0)))" } ?? Fmt.usd(f) } ?? "—",
                 "position margin isn’t touched", .hyperliquid),
            step("relay", "BRIDGE · RELAY", amount.map { "\(Fmt.num($0)) USDC" } ?? "—", "≈ 4 s · small Relay fee", .relay),
            step("sol", "TO · SOLANA", solana.map { s in amount.map { "\(Fmt.num(s.usdc)) → \(Fmt.num(s.usdc + $0))" } ?? Fmt.num(s.usdc) } ?? "—",
                 "your own address ✓", .solana),
        ])
    }

    private func aaveRoute(_ amount: Decimal) -> MoveRoute {
        let onBase = base?.usdc ?? 0
        let short = max(0, amount - onBase)
        let needGas = (base?.eth ?? 0) < Decimal(string: "0.000005")!
        let bridging = short > 0 || needGas
        let apy = aaveAPY.map { "≈ \(Fmt.num($0.rounded(2, .plain)))% a year" } ?? "rate from the pool"
        var steps: [ActivityBubble] = []
        if bridging {
            steps.append(step("sol", "FROM · SOLANA", solana.map { "\(Fmt.num($0.usdc)) USDC" } ?? "—",
                              "sends ≈ \(Fmt.num(max(short, needGas ? Decimal(string: "0.5")! : 0) + (needGas ? Decimal(string: "0.14")! : Decimal(string: "0.03")!))) USDC", .solana))
            steps.append(step("relay", "BRIDGE · RELAY", "\(Fmt.num(max(short, needGas ? Decimal(string: "0.5")! : 0))) USDC → Base",
                              needGas ? "+ $0.03 of ETH for gas · ≈ 2 s" : "≈ 2 s", .relay))
        } else {
            steps.append(step("base", "ON BASE", "\(Fmt.num(onBase)) USDC", "already there, gas too", .base))
        }
        steps.append(step("aave", "AAVE V3 · BASE", "\(Fmt.num(amount)) USDC", apy, .aave))
        return MoveRoute(title: "Aave · lend \(Fmt.num(amount)) USDC on Base",
                         footer: (bridging ? "One Solana signature for the bridge, then " : "")
                            + "two on Base: approve exactly \(Fmt.num(amount)) USDC, then supply. Pool and rate are re-read from Base first. Say “do it” or press Confirm.",
                         steps: steps)
    }

    /// Any other move between the user's own places: where from, where to, in the places' colors.
    private func ends(_ c: WalletCommand) -> (ActivityBubble, ActivityBubble)? {
        func n(_ d: Decimal?) -> String { d.map { Fmt.num($0, maxFraction: 6) } ?? "all" }
        let solUSDC = solana.map { "free: \(Fmt.num($0.usdc)) USDC" } ?? ""
        let solSOL = solana.map { "free: \(Fmt.num($0.sol, maxFraction: 4)) SOL" } ?? ""
        switch c {
        case .lendDeposit(let s, let x):
            return (step(s == "SOL" ? "sol" : "usdc", "FROM · SOLANA", "\(n(x)) \(s)", s == "SOL" ? solSOL : solUSDC, .solana),
                    step("jup", "INTO · JUPITER LEND", "\(n(x)) \(s)", "earns the vault rate · withdraw any time", .jupiter))
        case .lendWithdraw(let s, let x):
            return (step("jup", "FROM · JUPITER LEND", "\(n(x)) \(s)", lendTotal > 0 ? "in the vault: \(Fmt.num(lendTotal)) USDC" : "", .jupiter),
                    step(s == "SOL" ? "sol" : "usdc", "TO · SOLANA", "\(n(x)) \(s)", "your wallet", .solana))
        case .kamino(true, let s, let x):
            return (step(s == "SOL" ? "sol" : "usdc", "FROM · SOLANA", "\(n(x)) \(s)", s == "SOL" ? solSOL : solUSDC, .solana),
                    step("kamino", "INTO · KAMINO LEND", "\(n(x)) \(s)", "first deposit pays ≈ 0.03 SOL rent", .kamino))
        case .kamino(false, let s, let x):
            return (step("kamino", "FROM · KAMINO LEND", "\(n(x)) \(s)", "", .kamino),
                    step(s == "SOL" ? "sol" : "usdc", "TO · SOLANA", "\(n(x)) \(s)", "your wallet", .solana))
        case .stake(let x):
            return (step("sol", "FROM · SOLANA", "\(n(x)) SOL", solSOL, .solana),
                    step("jitosol", "INTO · JITOSOL", "liquid staking", "earns the staking yield · swap back any time", .jito))
        case .unstake(let x):
            return (step("jitosol", "FROM · JITOSOL", "\(n(x)) JitoSOL", "", .jito), step("sol", "TO · SOLANA", "SOL", "your wallet", .solana))
        case .hlp(true, let x):
            return (step("hype", "FROM · HYPERLIQUID", "\(n(x)) USDC", hl.map { "free: \(Fmt.usd($0.withdrawable))" } ?? "", .hyperliquid),
                    step("hype", "INTO · HLP VAULT", "\(n(x)) USDC", "min $5 · 4-day lockup", .hlp))
        case .hlp(false, let x):
            return (step("hype", "FROM · HLP VAULT", "\(n(x)) USDC", "", .hlp), step("hype", "TO · HYPERLIQUID", "USDC", "trading balance", .hyperliquid))
        case .buy(let a, let u):
            return (step("usdc", "FROM · SOLANA", "\(n(u)) USDC", solUSDC, .solana),
                    step(TokenLogo.name(forAsset: a.symbol) ?? "usdc", "BUY · JUPITER", a.symbol, "best route, simulated first", .jupiter))
        case .sellStock(let s, let x):
            return (step("robinhood", "SELL · UNISWAP", "\(n(x)) \(s)", "Robinhood Chain", .robinhood),
                    step("usdc", "TO · USDG", "on Robinhood Chain", "then “move USDG from Robinhood to Solana”", .solana))
        case .sell(let a, let x):
            return (step(TokenLogo.name(forAsset: a.symbol) ?? "usdc", "SELL · JUPITER", "\(n(x)) \(a.symbol)", "", .jupiter),
                    step("usdc", "TO · SOLANA", "USDC", "your wallet", .solana))
        default:
            return nil
        }
    }

    /// A Robinhood Stock Token bought with USDC from Solana: bridge, then Uniswap on Robinhood Chain.
    private func stockRoute(_ symbolOrContract: String, _ usdc: Decimal) -> MoveRoute {
        // A contract («купи 0x…»): its name and price from the favorites when it's there.
        let contract = symbolOrContract.hasPrefix("0x")
        let favorite = favoriteTokens.first { $0.address.lowercased() == symbolOrContract.lowercased() }
        let symbol = favorite?.symbol ?? (contract ? "\(symbolOrContract.prefix(6))…\(symbolOrContract.suffix(4))" : symbolOrContract)
        let price = contract ? favorite.flatMap { tokenInfo[$0.id]?.priceUSD } : markets["xyz:\(symbolOrContract)"]?.markPx
        return MoveRoute(title: "Buy \(symbol) · \(Fmt.num(usdc)) USDC on Robinhood Chain",
                         footer: "One Solana signature for the bridge, then two on Robinhood Chain: an exact USDG approve and the Uniswap swap, which may only pay this wallet. "
                            + (contract ? "The token is taken by its contract: it must trade on Robinhood Chain with $50k+ of liquidity, and the price must sit within 5% of DexScreener's."
                                        : "The token is Robinhood's registered contract, checked on-chain, and the price must sit within Robinhood's own quote.")
                            + " Say “do it” or press Confirm.", steps: [
            step("sol", "FROM · SOLANA", "\(Fmt.num(usdc)) USDC", solana.map { "free: \(Fmt.num($0.usdc)) USDC" } ?? "", .solana),
            step("relay", "BRIDGE · RELAY", "USDG → Robinhood", "+ ETH for gas when there's none", .relay),
            step("robinhood", "BUY · UNISWAP", symbol,
                 price.map { "≈ \(Fmt.num(usdc / $0, maxFraction: 2)) \(symbol) worth ≈ \(Fmt.usd(usdc)) · 1 \(symbol) = \(tokenPrice($0))" } ?? "at the pool price", .robinhood),
        ], warning: contract ? "A token by its contract is anyone's coin: its price can halve in a day and nobody vouches for it. Put in only what you can lose."
                             : "Robinhood Stock Tokens give economic exposure, not the shares, and aren’t offered to US persons or in Canada, the UK and Switzerland.")
    }

    /// Aave or idle USDC on Base, Arbitrum or Robinhood Chain → Relay → Solana.
    private func backRoute(from place: String, amount: Decimal?) -> MoveRoute {
        let available = place == "aave" ? base?.aave : place == "arbitrum" ? arbitrumUSDC : place == "robinhood" ? robinhood?.usdg : base?.usdc
        let moving = amount.map { min($0, available ?? $0) } ?? available
        let chainName = place == "arbitrum" ? "Arbitrum" : place == "robinhood" ? "Robinhood Chain" : "Base"
        let from = place == "aave"
            ? step("aave", "FROM · AAVE ON BASE", available.map { "\(Fmt.num($0)) USDC" } ?? "—",
                   aaveAPY.map { "earning ≈ \(Fmt.num($0.rounded(2, .plain)))% until now" } ?? "with the interest", .aave)
            : step(place == "arbitrum" ? "arb" : place == "robinhood" ? "robinhood" : "base", "FROM · \(chainName.uppercased())",
                   available.map { "\(Fmt.num($0)) \(place == "robinhood" ? "USDG" : "USDC")" } ?? "—",
                   "idle \(place == "robinhood" ? "USDG" : "USDC")", place == "arbitrum" ? .arbitrum : place == "robinhood" ? .robinhood : .base)
        return MoveRoute(title: place == "aave" ? "Aave · withdraw \(moving.map { Fmt.num($0) } ?? "all") USDC to Solana" : "\(chainName) · \(moving.map { Fmt.num($0) } ?? "all") USDC to Solana",
                         footer: (place == "aave" ? "Three Base transactions: withdraw from Aave, an exact approve and Relay’s deposit" : "Two Base transactions: an exact approve and Relay’s deposit")
                            + " — checked field by field before signing. Say “do it” or press Confirm.", steps: [
            from,
            step("relay", "BRIDGE · RELAY", moving.map { "\(Fmt.num($0)) USDC" } ?? "—", "≈ $0.02 · a few seconds", .relay),
            step("sol", "TO · SOLANA", solana.map { s in moving.map { "\(Fmt.num(s.usdc)) → \(Fmt.num(s.usdc + $0))" } ?? Fmt.num(s.usdc) } ?? "—",
                 "your own address ✓", .solana),
        ])
    }
}

/// A move of money waiting for «do it», drawn as its route.
struct WithdrawBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if case .wallet(let command)? = ws.pendingAction, let route = ws.route(command) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text(route.title).font(.system(size: 14, weight: .semibold))
                        StatusChip(text: "waiting for the signature", tint: Brand.profit)
                    }
                    RouteSteps(steps: route.steps)
                    Label(route.footer, systemImage: "signature").font(.caption).foregroundStyle(.secondary)
                    PendingButtons()
                }
                if let warning = route.warning {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Brand.jevInk)
                }
            }
            .frame(width: 470, alignment: .leading)
            .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
        }
    }
}

/// A route's steps side by side, each an arrow in its place's color.
struct RouteSteps: View {
    let steps: [ActivityBubble]

    var body: some View {
        HStack(alignment: .top, spacing: 12) { ForEach(steps, id: \.self) { RouteStepView(step: $0) } }
    }
}

struct RouteStepView: View {
    let step: ActivityBubble

    var body: some View {
        let fill = step.fill ?? .solana
        VStack(alignment: .leading, spacing: 6) {
            if let logo = step.logo { TokenLogo(name: logo, size: 24) }
            Text(step.label).font(.system(size: 9, weight: .heavy)).tracking(0.4).opacity(0.75)
            Text(step.title).font(.system(size: 13, weight: .bold)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            ForEach(step.lines, id: \.self) { Text($0).font(.caption2).opacity(0.8).fixedSize(horizontal: false, vertical: true) }
        }
        .foregroundStyle(fill.dark ? Color.white : Color.primary)
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(ArrowCard(radius: 16, tip: 10).fill(fill.color))
    }
}

extension Workspace {
    static let help = "I didn’t catch what to do. For example: “deposit 1 USDC into Jupiter”, “long ETH risk $5 by the book”, “send 5 USDC to Bybit”, “where to keep USDC”, “alert me when ETH is below 2,500”."

    /// One path for every wallet command, typed or read by the model: a missing amount is asked for and remembered;
    /// in the studio (or whenever the model read it) money moves only after «do it» on the drawn route.
    func handleWallet(_ command: WalletCommand, note: String? = nil, confirmAlways: Bool = false) async {
        updateActivity { $0.understood = command.summary }
        if case .sendTo(let name, let amount) = command { prepareTransfer(amount, to: name, note: note); return }
        if case .receive = command {
            withAnimation(StudioView.spring) { showReceive = true }
            let sol = isSolanaAddress(solanaAddress) ? "Solana \(AddressCheck.ends(solanaAddress).start) … \(AddressCheck.ends(solanaAddress).end)" : nil
            reply("Your addresses are on the canvas\(sol.map { " — \($0) for USDC and SOL (recommended)" } ?? ""), plus Base for USDC and ETH. LALA can’t pull money in; send it there from an exchange or another wallet, on that network. It shows up within about 30 s and I’ll tell you when it arrives. To put money you already have into a vault, say “deposit 1 USDC into Jupiter”.", note: note)
            return
        }
        if let question = command.amountQuestion {
            awaitingAmount = command
            reply(question + amountHint(command), note: note)
            return
        }
        switch command {
        case .yields, .allocate, .schedule, .stopSchedules:
            // Read-only, or with a board and a step of their own.
            await move(command)
        default:
            guard isStudio || confirmAlways else { await move(command); return }
            pendingAction = .wallet(command)
            pendingText = command.summary
            reply("Understood: \(command.summary). It’s on the canvas — Sign it, or say anything else to cancel.", note: note)
        }
    }

    /// What there is to use, so the answer to «How much?» is easy.
    private func amountHint(_ command: WalletCommand) -> String {
        switch command {
        case .lendDeposit("SOL", _), .kamino(_, "SOL", _), .stake:
            return solana.map { " You have \(Fmt.num($0.sol, maxFraction: 4)) SOL on Solana — answer with a number, e.g. “0.01”." } ?? ""
        case .hlp: return hl.map { " \(Fmt.usd($0.withdrawable)) is free on Hyperliquid — answer with a number, e.g. “5”." } ?? ""
        default: return solana.map { " You have \(Fmt.num($0.usdc)) USDC on Solana — answer with a number, e.g. “1”." } ?? ""
        }
    }

    /// The last few lines of this canvas's chat, for a model reading a follow-up like «1» or «yes».
    func recentChat() -> [String] {
        messages.dropFirst().suffix(6).map { ($0.fromUser ? "user: " : "LALA: ") + $0.text.prefix(300) }
    }
}
