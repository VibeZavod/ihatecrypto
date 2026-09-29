import EVMChain
import Foundation
import LalaCore
import LLMCatalog
import SwiftUI
import TradeExecution
import WalletCore

/// Owner-only JSON files in Application Support/LALA.
///
/// A chat reply changes activity.json and canvases.json several times in one go: each file is encoded once, at the
/// end of that turn of the run loop, and written off the main thread. Encoding stays on main: the app's types are
/// main-actor isolated, so their Codable conformances can't run elsewhere.
enum LocalStore {
    /// Writes go one at a time, in order.
    private static let queue = DispatchQueue(label: "app.lala.localstore")
    /// Values saved during this turn, by file: only the last one of each is encoded.
    private static var pending: [String: () -> Data?] = [:]
    /// The bytes each file last got: an unchanged value isn't written again.
    private static var written: [String: Data] = [:]

    nonisolated static func url(_ name: String) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "LALA")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name)
    }

    static func load<T: Decodable>(_ name: String) -> T? {
        // A save still on its way would be read stale (flows.json is read, added to and saved).
        flush()
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        if pending.isEmpty { Task { encodePending() } }
        pending[name] = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try? encoder.encode(value)
        }
    }

    /// Encodes what was saved and hands the bytes to the queue.
    private static func encodePending() {
        let jobs = pending
        pending = [:]
        for (name, encode) in jobs {
            guard let data = encode(), written[name] != data else { continue }
            written[name] = data
            queue.async {
                let file = url(name)
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                do { try data.write(to: file, options: .atomic) } catch {
                    // Not on disk (a full disk): the same value saved again has to be written, not skipped as unchanged.
                    Task { @MainActor in if written[name] == data { written[name] = nil } }
                }
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
    }

    /// Everything saved so far is on disk when this returns: at quit, and before a read.
    static func flush() {
        encodePending()
        queue.sync {}
    }
}

/// One canvas: its chat, its plan, the model it was talked through and the bubbles last on it.
/// Kept on this Mac (canvases.json, owner-only); the canvas open at quit opens again at launch.
struct CanvasSession: Codable, Identifiable, Equatable {
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
    /// Moves already carried out on this canvas before the one on its board, oldest first: a canvas can hold
    /// several steps in a row («out of Jupiter», then «out of Kamino»). Optional, so older files still load.
    var earlier: [DoneBoard]?
    /// When the board was last live.
    var boardAt: Date?
    /// The chart on it, candles included: reopened, it shows this snapshot until Refresh.
    var chart: ChartState?
    /// When it was pinned to the top of the list; nil = not pinned. Pinned ones keep the order they were pinned in.
    var pinnedAt: Date?

    var displayTitle: String { name ?? (title.isEmpty ? "Canvas" : title) }
}

/// A money move carried out from a canvas.
struct CanvasOutcome: Codable, Equatable {
    var at: Date
    var ok: Bool
}

/// A finished move kept on its canvas once the next one begins.
struct DoneBoard: Codable, Equatable {
    var title: String
    var bubbles: [ActivityBubble]
    var outcome: CanvasOutcome
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
            // A new move after a finished one: the finished one stays on the canvas, above it.
            if let done = old?.outcome, let old, finishedAction?.outcome != done {
                c.earlier = (c.earlier ?? []) + [DoneBoard(title: old.title, bubbles: old.bubbles, outcome: done)]
            }
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
        // Nothing new but the board's time (a reply saves, then the message's end saves again): `canvases` is left
        // alone, so what reads it doesn't redraw and the file isn't written.
        var unchanged = c
        unchanged.boardAt = old?.boardAt
        if unchanged == old { return }
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

    /// At most this many canvases stay pinned to the top of the list.
    static let maxPinned = 5

    /// Pinning past the limit does nothing; the menu says to unpin one first.
    func pinCanvas(_ id: UUID, _ on: Bool) {
        guard let i = canvases.firstIndex(where: { $0.id == id }),
              !on || canvases.filter({ $0.pinnedAt != nil }).count < Self.maxPinned else { return }
        canvases[i].pinnedAt = on ? Date() : nil
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
        // Back on a canvas whose move was waiting for Confirm: it waits again (its numbers are live on the card).
        if let parked = parkedPending.removeValue(forKey: c.id), Date().timeIntervalSince(parked.at) < 15 * 60 {
            pendingAction = parked.action
            pendingText = parked.text
            savedBoard = nil
        }
    }

    /// What belongs to one canvas only: boards, waiting confirmations, the draft.
    private func clearCanvas() {
        if let pendingAction, let canvasID { parkedPending[canvasID] = (pendingAction, pendingText, Date()) }
        takeChoices = nil
        nextSteps = nil
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
        // What the rail opened belongs to the canvas it was opened on; the next one starts clean, at 100 %.
        detail = nil
        showReceive = false
        showMovers = false
        showHistory = false
        showFavorites = false
        showSchedule = false
        UserDefaults.standard.set("plan", forKey: "canvasMode")
        NotificationCenter.default.post(name: .lalaCanvasFit, object: nil)
    }
}

// MARK: Views

/// The saved canvases, newest first; a click opens one with its chat, plan and model.
struct CanvasList: View {
    @Environment(Workspace.self) private var ws
    var close: (() -> Void)?
    /// Folded folders, one name per line; kept between launches.
    @AppStorage("foldedCanvasFolders") var foldedRaw = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Canvases").font(.ui(12)).foregroundStyle(.secondary).padding(.leading, 4)
                Spacer()
                // The whole pill is the button and lights up under the pointer, not only its glyphs.
                Button { withAnimation(StudioView.spring) { ws.newCanvas() }; close?() } label: {
                    Label("New", systemImage: "square.and.pencil").font(.ui(10, .semibold)).padding(.horizontal, 8)
                }
                .buttonStyle(.hoverIcon).help(ws.busy ? "ihatecrypto is still answering" : "New canvas").disabled(ws.busy)
                .padding(.trailing, -8)   // the word lines up with the rows' right edge; only the hover wash goes past it
            }
            let items = ws.canvases.sorted { $0.updated > $1.updated }
            if items.isEmpty {
                Text("Each conversation gets its own canvas and is kept here.").font(.ui(10)).foregroundStyle(.tertiary)
            }
            ScrollView { rows(items) }.scrollIndicators(.never)
        }
    }
}

extension CanvasList {
    /// Pinned canvases first (in the order they were pinned), then folders (open or folded), then the canvases in no
    /// folder; newest first inside each. A pinned canvas shows only at the top, not again in its folder.
    private func rows(_ all: [CanvasSession]) -> some View {
        let folded = Set(foldedRaw.split(separator: "\n").map(String.init))
        let pinned = all.filter { $0.pinnedAt != nil }.sorted { $0.pinnedAt! < $1.pinnedAt! }
        let items = all.filter { $0.pinnedAt == nil }
        return LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(pinned) { row($0) }
            if !pinned.isEmpty, !items.isEmpty { Divider().padding(.vertical, 4).padding(.horizontal, 8) }
            ForEach(ws.canvasFolders.filter { f in items.contains { $0.folder == f } }, id: \.self) { folder in
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
                Image(systemName: folded ? "folder" : "folder.fill").font(.system(size: 12)).foregroundStyle(Brand.accentInk)
                Text(name).font(.ui(12.5, .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count)").font(.ui(10)).foregroundStyle(.tertiary).monospacedDigit()
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
            .help("Pin, rename, move to a folder, delete")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        // The open canvas is a lit glass row, like a selected item in a macOS 26 sidebar.
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(current ? Brand.glassSelected : hover ? Brand.glassFill.opacity(0.6) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(current ? Brand.glassRim : .clear))
        .shadow(color: .black.opacity(current ? 0.06 : 0), radius: 2, y: 1)
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
                RoundedRectangle(cornerRadius: 8).fill(Brand.glassFill).frame(width: 26, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Brand.glassRim))
                    .overlay(Image(systemName: canvas.bubbles.isEmpty ? "bubble.left" : "square.grid.2x2").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain).font(.ui(12.5, .semibold))
                        .focused($nameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { renaming = false }
                        .onChange(of: nameFocused) { if !nameFocused, renaming { commitRename() } }
                } else {
                    HStack(spacing: 4) {
                        Text(canvas.displayTitle).font(.ui(13, current ? .semibold : .medium)).lineLimit(1)
                        if canvas.pinnedAt != nil {
                            Image(systemName: "pin.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).help("Pinned")
                        }
                    }
                }
                Text("\(canvas.model) · \(Fmt.date(canvas.updated))").font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var actions: some View {
        if canvas.pinnedAt != nil {
            Button { withAnimation(.snappy) { ws.pinCanvas(canvas.id, false) } } label: { Label("Unpin", systemImage: "pin.slash") }
        } else {
            let full = ws.canvases.filter { $0.pinnedAt != nil }.count >= Workspace.maxPinned
            Button { withAnimation(.snappy) { ws.pinCanvas(canvas.id, true) } } label: {
                Label(full ? "Pin — \(Workspace.maxPinned) already pinned, unpin one first" : "Pin to the top", systemImage: "pin")
            }
            .disabled(full)
        }
        Divider()
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

/// The moves already carried out on the open canvas, oldest first, above what is on it now.
struct EarlierBoards: View {
    @Environment(Workspace.self) private var ws
    /// Finished moves are one line each, so the current one stays in view; a click shows a move's route again.
    @State private var open: Set<Int> = []

    var body: some View {
        let earlier = ws.canvases.first { $0.id == ws.canvasID }?.earlier ?? []
        ForEach(Array(earlier.enumerated()), id: \.offset) { i, done in
            VStack(alignment: .leading, spacing: 10) {
                Button { withAnimation(.snappy) { if open.contains(i) { open.remove(i) } else { open.insert(i) } } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: done.outcome.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(done.outcome.ok ? Brand.profit : Brand.loss)
                        Text(ws.readable(done.title)).font(.ui(13, .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(Fmt.date(done.outcome.at)).font(.ui(10)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open.contains(i) ? 90 : 0))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Capsule().fill(Brand.card))
                    .overlay(Capsule().strokeBorder(Brand.cardBorder))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(HoverLift(radius: 20))
                .help(open.contains(i) ? "Hide its route" : "Show its route")
                if !open.contains(i) {
                    EmptyView()
                } else if done.bubbles.allSatisfy({ $0.kind == "step" }) {
                    RouteCards(steps: done.bubbles, outcome: done.outcome.ok)
                } else {
                    LazyVGrid(columns: [GridItem(.fixed(220), alignment: .top), GridItem(.fixed(220), alignment: .top)], alignment: .leading, spacing: 14) {
                        ForEach(done.bubbles, id: \.self) { HistoryBubble(bubble: $0) }
                    }
                }
            }
            .padding(.bottom, 6)
        }
    }
}

/// A canvas opened again whose board isn't a live plan: its bubbles as they were.
struct SavedBoard: View {
    @Environment(Workspace.self) private var ws
    let canvas: CanvasSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let o = canvas.outcome {
                Label("\(o.ok ? "Executed" : "Failed") · \(Fmt.date(o.at))", systemImage: o.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.ui(13, .semibold)).foregroundStyle(o.ok ? Brand.profit : Brand.loss)
            } else {
                HStack(spacing: 10) {
                    Label("As it was · \(Fmt.date(canvas.boardAt ?? canvas.updated))", systemImage: "clock.arrow.circlepath")
                        .font(.ui(10)).foregroundStyle(.secondary)
                    // The same request again, through the chat: live numbers, and a money move still waits for Confirm.
                    if let request = canvas.messages.last(where: \.fromUser)?.text {
                        Button { Task { await ws.send(request) } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise").font(.ui(10, .semibold))
                        }
                        .buttonStyle(.bordered).controlSize(.small).disabled(ws.busy)
                        .help("Asks “\(request)” again for fresh numbers")
                    }
                }
            }
            if !canvas.bubbles.isEmpty, canvas.bubbles.allSatisfy({ $0.kind == "step" }) {
                RouteCards(steps: canvas.bubbles, outcome: canvas.outcome?.ok)
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
                    Text(title).font(.ui(13, .semibold)).foregroundStyle(tint)
                    if let detail { Text(detail).font(.ui(10)).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 8)
                if let shortcut { Text(shortcut).font(.ui(10)).foregroundStyle(.secondary) }
                if checked { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.accentInk) }
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
                Text("\(Fmt.usd(schedule.usdc)) → \(schedule.symbol) every \(period)").font(.ui(15, .bold))
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
                    .font(.ui(12.5))
                    .padding(.vertical, 7)
                    if i < runs.count - 1 { Divider() }
                }
            }
            if let short {
                Label("On \(Fmt.date(short.date)) there won’t be enough USDC on Solana. Top up Solana or lower the amount.", systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(10)).foregroundStyle(Brand.jevInk)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Brand.jevInk.opacity(0.1)))
            }
            HStack {
                Text("Runs while ihatecrypto is open or in the menu bar.").font(.ui(10)).foregroundStyle(.secondary)
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
            Text(label).font(.ui(9.5, .heavy)).tracking(0.5).foregroundStyle(.secondary)
            Text(text).font(.ui(12.5, .semibold)).fixedSize(horizontal: false, vertical: true)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CHOOSE AN OPTION").font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                if let fit = ws.fittingRisk {
                    card(badge: "Recommended", title: "Risk \(Fmt.usd(fit.risk))",
                         detail: "notional \(Fmt.usd(fit.sizing.notional)) · margin \(Fmt.usd(fit.sizing.margin)) — everything fits", recommended: true) {
                        Task { await ws.send("risk $\(fit.risk)") }
                    }
                }
                card(badge: "at your own risk", title: "Raise the limit",
                     detail: "now at most \(Fmt.pct(ws.policy.maxRiskPct)) per trade · in Settings", recommended: false) { ws.openSettings(.general) }
            }
        }
        .frame(width: 470, alignment: .leading)
        .transition(.opacity)
    }

    private func card(badge: String, title: String, detail: String, recommended: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(badge.uppercased()).font(.ui(9.5, .heavy)).tracking(0.5)
                    .foregroundStyle(recommended ? Brand.onAccent : .secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(recommended ? Brand.accent : Color.primary.opacity(0.07)))
                Text(title).font(.ui(17, .heavy))
                Text(detail).font(.ui(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 20).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(recommended ? Brand.accent : Brand.cardBorder,
                                                                       style: StrokeStyle(lineWidth: recommended ? 2 : 1, dash: recommended ? [] : [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverLift(radius: 20))
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
                Label(confirm, systemImage: "touchid").font(.ui(13, .semibold)).padding(.horizontal, 6)
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
    case solana, relay, hyperliquid, hlp, jupiter, kamino, jito, aave, morpho, base, arbitrum, robinhood, near

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
        case .morpho: Color(hex: 0x1D4FC4)
        case .base: Color(hex: 0x0052FF)
        case .arbitrum: Color(hex: 0x213147)
        case .robinhood: Color(hex: 0x3A4A00)
        case .near: Color(hex: 0x10231C)
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
        case .aave(deposit: true, amount: let amount?, network: let net): aaveRoute(amount, network: net)
        case .aave(deposit: false, amount: let amount, network: let net): backRoute(from: "aave", amount: amount, network: net)
        case .morpho(deposit: true, amount: let amount?, network: let net): aaveRoute(amount, morpho: true, network: net)
        case .morpho(deposit: false, amount: let amount, network: let net): backRoute(from: "morpho", amount: amount, network: net)
        case .evmToSolana(let net, let amount): backRoute(from: net, amount: amount, network: net)
        case .baseToSolana(let amount): backRoute(from: "base", amount: amount)
        case .arbitrumToSolana(let amount): backRoute(from: "arbitrum", amount: amount)
        case .robinhoodToSolana(let amount): backRoute(from: "robinhood", amount: amount)
        case .solanaTo(let place, let amount?): outRoute(to: place, amount: amount)
        case .buyStock(let symbol, let usdc?): stockRoute(symbol, usdc)
        case .buyOn(let place, let token, let usdc?): swapRoute(place, token, usdc: usdc, sell: nil)
        case .sellOn(let place, let token, let amount): swapRoute(place, token, usdc: nil, sell: amount)
        case .sellNear(let asked): sellNearRoute(asked)
        case .sendNear(let name, let asked): nearOutRoute(to: name, amount: asked, close: false)
        case .closeNear(let name): nearOutRoute(to: name, amount: nil, close: true)
        case .sendSol(let name, let amount): solOutRoute(to: name, amount: amount)
        default: ends(command).map { from, to in
            let footer = if case .sellStock = command {
                "Two Robinhood Chain transactions: an exact approve and the Uniswap swap, which may only pay this wallet. Say “do it” or press Confirm; anything else cancels."
            } else {
                "One Solana signature, checked and simulated before it’s signed. Say “do it” or press Confirm; anything else cancels."
            }
            return MoveRoute(title: readable(command.summary.prefix(1).uppercased() + command.summary.dropFirst()), footer: footer, steps: [from, to])
        }
        }
    }

    private func step(_ logo: String, _ label: String, _ title: String, _ line: String, _ fill: RouteFill) -> ActivityBubble {
        ActivityBubble(kind: "step", label: label, title: title, lines: [line], logo: logo, fill: fill)
    }

    /// Any wallet command without a drawn route still gets its card with Confirm: a pending move is never invisible.
    func fallbackRoute(_ command: WalletCommand) -> MoveRoute {
        MoveRoute(title: readable(Self.canvasTitle(command)),
                  footer: "Checked and simulated before it’s signed. Say “do it” or press Confirm; anything else cancels.", steps: [])
    }

    /// Native NEAR → USDC on Solana through NEAR Intents (1Click); «all» keeps ≈ 0.09 NEAR: storage, and prepaid gas
    /// at NEAR's pessimistic price (NearTransaction.intentDepositOverhead), most of which comes back after the sale.
    private func sellNearRoute(_ asked: Decimal?) -> MoveRoute {
        let amount = asked ?? max(0, near - Decimal(string: "0.09")!)
        let usd = markets["NEAR"].map { amount * $0.markPx }
        return MoveRoute(title: "Sell \(Fmt.num(amount, maxFraction: 4)) NEAR for USDC on Solana",
                         footer: "One NEAR transaction: exactly this NEAR, wrapped and sent to the 1Click deposit address the quote names, checked before signing. USDC arrives on your own Solana address in ≈ 30–40 s. Say “do it” or press Confirm.",
                         steps: [
            step("near", "FROM · NEAR", "\(Fmt.num(amount, maxFraction: 4)) NEAR", usd.map { "≈ \(Fmt.usd($0)) · ≈ 0.09 NEAR stays for storage and gas, most of it back after" } ?? "", .near),
            step("near", "SWAP · NEAR INTENTS", "1Click", "≈ 30–40 s · the quote is checked", .relay),
            step("sol", "TO · SOLANA", usd.map { "≈ \(Fmt.num($0.rounded(2, .plain))) USDC" } ?? "USDC",
                 "your own address ✓", .solana),
        ])
    }

    /// NEAR to a saved NEAR account, or the whole NEAR account closed into it.
    private func nearOutRoute(to name: String, amount asked: Decimal?, close: Bool) -> MoveRoute? {
        guard let entry = savedAddress(name, on: .near) else { return nil }
        let amount = close ? near : asked ?? max(0, near - Decimal(string: "0.012")!)
        let usd = markets["NEAR"].map { amount * $0.markPx }
        let ends = AddressCheck.ends(entry.address)
        return MoveRoute(title: close ? "Close the NEAR account into \(entry.name)" : "Send \(Fmt.num(amount, maxFraction: 4)) NEAR to \(entry.name)",
                         footer: (close
                            ? "One NEAR transaction: your NEAR account is deleted and NEAR sends everything on it to \(entry.name). Touch ID asks in plain words first; buying NEAR later opens the account again. "
                            : "One NEAR transfer, built and signed by the signer; only this saved address may receive it. ")
                            + "Say “do it” or press Confirm.",
                         steps: [
            step("near", "FROM · NEAR", "\(Fmt.num(amount, maxFraction: 4)) NEAR",
                 usd.map { "≈ \(Fmt.usd($0))" + (close ? " · everything" : asked == nil ? " · ≈ 0.012 NEAR stays" : "") } ?? "", .near),
            step(entry.network.logo, "TO · \(entry.label?.uppercased() ?? "SAVED ADDRESS")", entry.name, "\(ends.start) … \(ends.end)", .near),
        ], warning: entry.lastSent == nil ? "First transfer to this address. Sending a small test amount first is the safe habit." : nil)
    }

    /// SOL to a saved Solana address.
    private func solOutRoute(to name: String, amount: Decimal) -> MoveRoute? {
        guard let entry = savedAddress(name, on: .solana) else { return nil }
        let ends = AddressCheck.ends(entry.address)
        return MoveRoute(title: "Send \(Fmt.num(amount, maxFraction: 9)) SOL to \(entry.name)",
                         footer: "One Solana transfer: only this saved address may receive it, and the simulation must show exactly this SOL leaving plus the fee. Say “do it” or press Confirm.",
                         steps: [
            step("sol", "FROM · SOLANA", "\(Fmt.num(amount, maxFraction: 9)) SOL", solana.map { "free: \(Fmt.num($0.sol, maxFraction: 6)) SOL" } ?? "", .solana),
            step("sol", "TO · \(entry.label?.uppercased() ?? "SAVED ADDRESS")", entry.name, "\(ends.start) … \(ends.end)", .solana),
        ], warning: entry.lastSent == nil ? "First transfer to this address. Sending a small test amount first is the safe habit." : nil)
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

    /// Aave, or Morpho's vault: the same way in on Base.
    private func aaveRoute(_ amount: Decimal, morpho: Bool = false, network: String = "base") -> MoveRoute {
        guard network == "base" else { return lendingRoute(amount, morpho: morpho, network: network) }
        let onBase = base?.usdc ?? 0
        let short = max(0, amount - onBase)
        let needGas = (base?.eth ?? 0) < Decimal(string: "0.000005")!
        let bridging = short > 0 || needGas
        let apy = (morpho ? morphoAPY : aaveAPY).map { "≈ \(Fmt.num($0.rounded(2, .plain)))% a year" } ?? "rate from the pool"
        var steps: [ActivityBubble] = []
        if bridging {
            steps.append(step("sol", "FROM · SOLANA", solana.map { "\(Fmt.num($0.usdc)) USDC" } ?? "—",
                              "sends ≈ \(Fmt.num(max(short, needGas ? Decimal(string: "0.5")! : 0) + (needGas ? Decimal(string: "0.14")! : Decimal(string: "0.03")!))) USDC", .solana))
            steps.append(step("relay", "BRIDGE · RELAY", "\(Fmt.num(max(short, needGas ? Decimal(string: "0.5")! : 0))) USDC → Base",
                              needGas ? "+ $0.03 of ETH for gas · ≈ 2 s" : "≈ 2 s", .relay))
        } else {
            steps.append(step("base", "ON BASE", "\(Fmt.num(onBase)) USDC", "already there, gas too", .base))
        }
        steps.append(morpho ? step("morpho", "MORPHO · \(MorphoVault.name.uppercased())", "\(Fmt.num(amount)) USDC", apy, .morpho)
                            : step("aave", "AAVE V3 · BASE", "\(Fmt.num(amount)) USDC", apy, .aave))
        return MoveRoute(title: morpho ? "Morpho · deposit \(Fmt.num(amount)) USDC on Base" : "Aave · lend \(Fmt.num(amount)) USDC on Base",
                         footer: (bridging ? "One Solana signature for the bridge, then " : "")
                            + "two on Base: approve exactly \(Fmt.num(amount)) USDC, then \(morpho ? "deposit; the shares come to this wallet only" : "supply"). "
                            + "\(morpho ? "The vault’s asset is" : "Pool and rate are") re-read from Base first. Say “do it” or press Confirm.",
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
            let x = x ?? (s == "USDC" && lendTotal > 0 ? lendTotal : nil)
            return (step("jup", "FROM · JUPITER LEND", "\(n(x)) \(s)", lendTotal > 0 ? "in the vault: \(Fmt.num(lendTotal)) USDC" : "", .jupiter),
                    step(s == "SOL" ? "sol" : "usdc", "TO · SOLANA", "\(n(x)) \(s)", "your wallet", .solana))
        case .kamino(true, let s, let x):
            return (step(s == "SOL" ? "sol" : "usdc", "FROM · SOLANA", "\(n(x)) \(s)", s == "SOL" ? solSOL : solUSDC, .solana),
                    step("kamino", "INTO · KAMINO LEND", "\(n(x)) \(s)", "first deposit pays ≈ 0.03 SOL rent", .kamino))
        case .kamino(false, let s, let x):
            let x = x ?? (s == "USDC" && kamino > 0 ? kamino : nil)
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
            // In dollars: what is held (or asked) at the last price, and about as much USDG back.
            let stock = robinhood?.stocks.first { $0.symbol.uppercased() == s.uppercased() || $0.address.lowercased() == s.lowercased() }
            let token = favoriteToken(s)
            let held = stock?.amount ?? token.flatMap { tokenBalances[$0.id] }
            let price = stock?.price ?? token.flatMap { tokenInfo[$0.id]?.priceUSD }
            let amount = x ?? held
            let usd = amount.flatMap { a in price.map { a * $0 } }
            let name = s.hasPrefix("0x") ? (token?.symbol ?? tokenLabel(s)) : s.uppercased()
            return (step(stock != nil || !s.hasPrefix("0x") ? "stock:\(name)" : "robinhood", "SELL · UNISWAP",
                         usd.map { "≈ \(Fmt.usd($0)) of \(name)" } ?? "\(n(x)) \(tokenLabel(s))",
                         amount.map { "\(Fmt.num($0, maxFraction: 6)) \(name) · Robinhood Chain" } ?? "Robinhood Chain", .robinhood),
                    step("usdg", "TO · USDG", usd.map { "≈ \(Fmt.num($0.rounded(2, .plain))) USDG" } ?? "USDG",
                         "on Robinhood Chain · then “move USDG from Robinhood to Solana”", .solana))
        case .sell(let a, let x):
            return (step(TokenLogo.name(forAsset: a.symbol) ?? "usdc", "SELL · JUPITER", "\(n(x)) \(a.symbol)", "", .jupiter),
                    step("usdc", "TO · SOLANA", "USDC", "your wallet", .solana))
        default:
            return nil
        }
    }

    /// A Robinhood Stock Token bought with USDC from Solana: bridge, then Uniswap on Robinhood Chain.
    /// A token's name for people: the favorite's symbol for its contract, else the contract shortened.
    func tokenLabel(_ symbolOrContract: String) -> String {
        guard symbolOrContract.hasPrefix("0x") else { return symbolOrContract }
        let short = "\(symbolOrContract.prefix(6))…\(symbolOrContract.suffix(4))"
        return favoriteToken(symbolOrContract).map { "\($0.symbol) (\(short))" } ?? short
    }

    func favoriteToken(_ contract: String) -> FavoriteToken? {
        favoriteTokens.first { $0.address.lowercased() == contract.lowercased() }
    }

    /// Text for the canvas and the chat with every contract in it replaced by its token's name.
    func readable(_ text: String) -> String {
        text.replacing(/0x[0-9a-fA-F]{40}/) { tokenLabel(String($0.0)) }
    }

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

    /// A token on Base or Arbitrum, bought with USDC from Solana or sold back to it. The way (Relay's swap, or Relay's
    /// bridge and Uniswap) is chosen when it runs, by what leaves more after gas.
    private func swapRoute(_ place: String, _ token: String, usdc: Decimal?, sell: Decimal?) -> MoveRoute {
        let name = ["base": "Base", "arbitrum": "Arbitrum"][place] ?? place
        let fill: RouteFill = place == "base" ? .base : .arbitrum
        let label = token.hasPrefix("0x") ? "\(token.prefix(6))…\(token.suffix(4))" : token.uppercased()
        let logo = place == "arbitrum" ? "arb" : place
        // The way picked in the step's details, else the better of the two when it runs.
        let way = switch routeWays[Self.wayKey(place, token)] {
        case "relay": step("relay", "RELAY SWAP", "one step", usdc != nil ? "Relay swaps on the way · one Solana signature" : "Relay swaps it back to USDC on Solana", .relay)
        case "uniswap": step("relay", "RELAY + UNISWAP", usdc != nil ? "bridge, then Uniswap" : "Uniswap, then bridge",
                             usdc != nil ? "USDC to \(name), then Uniswap with an exact approve" : "Uniswap on \(name), then Relay's bridge to Solana", .relay)
        default: step("relay", "RELAY OR RELAY + UNISWAP", "whichever leaves more", "both quoted right before signing, gas counted", .relay)
        }
        let footer = "Relay’s swap is one Solana signature; the other way bridges USDC over Relay and swaps on Uniswap with an exact approve, the swap paying only this wallet. "
            + (token.hasPrefix("0x") ? "A token by its contract must trade on \(name) with $50k+ of liquidity. " : "The ticker is taken from Uniswap’s token list, its contract checked on-chain. ")
            + "Say “do it” or press Confirm."
        if let usdc {
            return MoveRoute(title: "Buy \(label) · \(Fmt.num(usdc)) USDC on \(name)", footer: footer, steps: [
                step("sol", "FROM · SOLANA", "\(Fmt.num(usdc)) USDC", solana.map { "free: \(Fmt.num($0.usdc)) USDC" } ?? "", .solana),
                way,
                step(logo, "BUY · ON \(name.uppercased())", label, "at the best price found", fill),
            ], warning: token.hasPrefix("0x") ? "A token by its contract is anyone’s coin: its price can halve in a day and nobody vouches for it. Put in only what you can lose." : nil)
        }
        return MoveRoute(title: "Sell \(sell.map { Fmt.num($0) } ?? "all") \(label) on \(name) → Solana", footer: footer, steps: [
            step(logo, "FROM · \(name.uppercased())", "\(sell.map { Fmt.num($0) } ?? "all") \(label)", "ETH for gas comes along when there’s none", fill),
            way,
            step("sol", "TO · SOLANA", "USDC", "your wallet", .solana),
        ])
    }

    /// Solana → Relay → our own address on Base, Arbitrum or Robinhood Chain.
    private func outRoute(to place: String, amount: Decimal) -> MoveRoute {
        let name = ["base": "Base", "arbitrum": "Arbitrum", "robinhood": "Robinhood Chain"][place] ?? place
        let stable = place == "robinhood" ? "USDG" : "USDC"
        let there = place == "base" ? base?.usdc : place == "arbitrum" ? arbitrumUSDC : robinhood?.usdg
        let fill: RouteFill = place == "base" ? .base : place == "arbitrum" ? .arbitrum : .robinhood
        return MoveRoute(title: "Move \(Fmt.num(amount)) USDC · Solana → \(name)",
                         footer: "One Solana signature for the Relay bridge, checked and simulated before it’s signed; it pays only your own address on \(name). Say “do it” or press Confirm.",
                         steps: [
            step("sol", "FROM · SOLANA", solana.map { "\(Fmt.num($0.usdc)) → \(Fmt.num(max(0, $0.usdc - amount)))" } ?? "\(Fmt.num(amount)) USDC", "USDC on Solana", .solana),
            step("relay", "BRIDGE · RELAY", "\(Fmt.num(amount)) USDC", "a few seconds · + ETH for gas when there's none", .relay),
            step(place == "arbitrum" ? "arb" : place, "TO · \(name.uppercased())", there.map { "\(Fmt.num($0)) → \(Fmt.num($0 + amount)) \(stable)" } ?? "\(Fmt.num(amount)) \(stable)",
                 "your own address ✓", fill),
        ])
    }

    /// Aave or idle USDC on Base, Arbitrum or Robinhood Chain → Relay → Solana.
    /// Aave or Morpho on a network other than Base. The app doesn't read balances there yet, so the route shows the way,
    /// not live amounts; the executor checks everything before signing.
    private func lendingRoute(_ amount: Decimal, morpho: Bool, network: String) -> MoveRoute {
        let name = WalletCommand.placeName(network), coin = network == "polygon" ? "POL" : "ETH"
        let protocolName = morpho ? "Morpho" : "Aave"
        return MoveRoute(title: "\(protocolName) · \(morpho ? "deposit" : "lend") \(Fmt.num(amount)) USDC on \(name)",
                         footer: "USDC missing on \(name) comes from Solana over Relay, with \(coin) for gas when there's none; then two \(name) transactions: "
                            + "approve exactly \(Fmt.num(amount)) USDC, then \(morpho ? "deposit; the shares come to this wallet only" : "supply"). "
                            + "\(morpho ? "The vault's asset is" : "Pool and aToken are") re-read from \(name) first"
                            + (network == "ethereum" ? "; Ethereum's gas costs dollars" : "") + ". Say “do it” or press Confirm.",
                         steps: [
            step("sol", "FROM · SOLANA", solana.map { "\(Fmt.num($0.usdc)) USDC" } ?? "—", "sends what's missing there", .solana),
            step("relay", "BRIDGE · RELAY", "USDC → \(name)", "+ \(coin) for gas when there's none · ≈ 2 s", .relay),
            morpho ? step("morpho", "MORPHO · \(name.uppercased())", "\(Fmt.num(amount)) USDC", "rate from the vault", .morpho)
                   : step("aave", "AAVE V3 · \(name.uppercased())", "\(Fmt.num(amount)) USDC", "rate from the pool", .aave),
        ])
    }

    private func backRoute(from place: String, amount: Decimal?, network: String = "base") -> MoveRoute {
        if network != "base" {
            let name = WalletCommand.placeName(network), lending = place == "aave" || place == "morpho"
            let what = place == "aave" ? "Aave" : "Morpho", moving = amount.map { Fmt.num($0) } ?? "all"
            let from = lending
                ? step(place, "FROM · \(what.uppercased()) ON \(name.uppercased())", "\(moving) USDC", "with the interest", place == "aave" ? .aave : .morpho)
                : step(network == "polygon" ? "pol" : network == "arbitrum" ? "arb" : "eth", "FROM · \(name.uppercased())", "\(moving) USDC", "idle USDC", .relay)
            return MoveRoute(title: lending ? "\(what) · withdraw \(moving) USDC on \(name) to Solana" : "\(name) · \(moving) USDC to Solana",
                             footer: (lending ? "Three \(name) transactions: withdraw from \(what), an exact approve and Relay’s deposit"
                                              : "Two \(name) transactions: an exact approve and Relay’s deposit")
                                + " — checked field by field before signing. Say “do it” or press Confirm.", steps: [
                from,
                step("relay", "BRIDGE · RELAY", "\(moving) USDC", "a few seconds", .relay),
                step("sol", "TO · SOLANA", solana.map { Fmt.num($0.usdc) } ?? "—", "your own address ✓", .solana),
            ])
        }
        let available = place == "aave" ? base?.aave : place == "morpho" ? base?.morpho : place == "arbitrum" ? arbitrumUSDC : place == "robinhood" ? robinhood?.usdg : base?.usdc
        let moving = amount.map { min($0, available ?? $0) } ?? available
        let chainName = place == "arbitrum" ? "Arbitrum" : place == "robinhood" ? "Robinhood Chain" : "Base"
        let from = place == "morpho"
            ? step("morpho", "FROM · MORPHO ON BASE", available.map { "\(Fmt.num($0)) USDC" } ?? "—",
                   morphoAPY.map { "earning ≈ \(Fmt.num($0))% until now" } ?? "with the interest", .morpho)
            : place == "aave"
            ? step("aave", "FROM · AAVE ON BASE", available.map { "\(Fmt.num($0)) USDC" } ?? "—",
                   aaveAPY.map { "earning ≈ \(Fmt.num($0.rounded(2, .plain)))% until now" } ?? "with the interest", .aave)
            : step(place == "arbitrum" ? "arb" : place == "robinhood" ? "robinhood" : "base", "FROM · \(chainName.uppercased())",
                   available.map { "\(Fmt.num($0)) \(place == "robinhood" ? "USDG" : "USDC")" } ?? "—",
                   "idle \(place == "robinhood" ? "USDG" : "USDC")", place == "arbitrum" ? .arbitrum : place == "robinhood" ? .robinhood : .base)
        return MoveRoute(title: place == "aave" || place == "morpho" ? "\(place == "aave" ? "Aave" : "Morpho") · withdraw \(moving.map { Fmt.num($0) } ?? "all") USDC to Solana" : "\(chainName) · \(moving.map { Fmt.num($0) } ?? "all") USDC to Solana",
                         footer: (place == "aave" || place == "morpho" ? "Three Base transactions: withdraw from \(place == "aave" ? "Aave" : "Morpho"), an exact approve and Relay’s deposit" : "Two Base transactions: an exact approve and Relay’s deposit")
                            + " — checked field by field before signing. Say “do it” or press Confirm.", steps: [
            from,
            step("relay", "BRIDGE · RELAY", moving.map { "\(Fmt.num($0)) USDC" } ?? "—", "≈ $0.02 · a few seconds", .relay),
            step("sol", "TO · SOLANA", solana.map { s in moving.map { "\(Fmt.num(s.usdc)) → \(Fmt.num(s.usdc + $0))" } ?? Fmt.num(s.usdc) } ?? "—",
                 "your own address ✓", .solana),
        ])
    }
}

/// A confirmed move while it runs: the route as it was confirmed, pulsing, and the step LALA is on. It turns into
/// the executed (or failed) board when the move ends, so the canvas never goes blank in between.
struct RunningBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if let run = ws.runningAction {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(run.title).font(.ui(14, .semibold))
                    StatusChip(text: "in progress", tint: Brand.accentInk)
                    ProgressView().controlSize(.small)
                }
                if !run.steps.isEmpty {
                    RouteCards(steps: run.steps, current: Self.currentStep(run.steps, run.lines))
                }
                if SignerActivity.shared.waiting > 0 {
                    Label("Touch ID — confirm on the sensor, or with your Mac password, if it asks", systemImage: "touchid")
                        .font(.ui(13, .semibold)).foregroundStyle(Brand.onAccent)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(Brand.accent))
                        .transition(.opacity)
                }
                TimelineView(.periodic(from: run.started, by: 1)) { t in
                    Label("\(run.lines.last ?? "Signing") · \(Int(t.date.timeIntervalSince(run.started))) s", systemImage: "bolt.fill")
                        .font(.ui(10)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(width: max(470, RouteCards.width(run.steps.count)), alignment: .leading)
            .transition(.opacity)
            .animation(.snappy, value: SignerActivity.shared.waiting > 0)
        }
    }

    /// The step the move is on: the furthest one whose place («Morpho», «Relay», «Solana») a report has named.
    // ponytail: matches place names in the executor's lines; a line quoting the destination early lights it up early.
    static func currentStep(_ steps: [ActivityBubble], _ lines: [String]) -> Int {
        let said = lines.joined(separator: " ").lowercased()
        var current = 0
        for (i, step) in steps.enumerated() {
            let place = step.label.components(separatedBy: "·").last?.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map { $0.lowercased() } ?? ""
            if !place.isEmpty, said.contains(place) { current = i }
        }
        return current
    }
}

/// A move of money waiting for «do it», drawn as its route.
struct WithdrawBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if case .wallet(let command)? = ws.pendingAction {
            let route = ws.route(command) ?? ws.fallbackRoute(command)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text(route.title).font(.ui(14, .semibold)).lineLimit(2).truncationMode(.middle)
                        StatusChip(text: "waiting for the signature", tint: Brand.profit).fixedSize()
                    }
                    RouteCards(steps: route.steps, footer: route.footer, pending: command, build: true)
                    Label(route.footer, systemImage: "signature").font(.ui(10)).foregroundStyle(.secondary)
                        .frame(maxWidth: 470, alignment: .leading)
                    PendingButtons()
                }
                if let warning = route.warning {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.ui(10)).foregroundStyle(Brand.jevInk)
                }
            }
            .frame(width: max(470, RouteCards.width(route.steps.count)), alignment: .leading)
            .transition(.opacity)
        }
    }
}

extension Workspace {
    static let help = "I didn’t catch what to do. For example: “deposit 1 USDC into Jupiter”, “long ETH risk $5 by the book”, “send 5 USDC to Bybit”, “where to keep USDC”, “alert me when ETH is below 2,500”."

    /// One path for every wallet command, typed or read by the model: a missing amount is asked for and remembered;
    /// money moves only after «do it» on the drawn route.
    func handleWallet(_ command: WalletCommand, note: String? = nil) async {
        // A Solana token named by its mint: looked up first, and only with Safe search off (TokensUI.swift).
        var command = command
        switch command {
        case .buy(let a, let u) where !a.resolved:
            guard let token = await spotToken(a, note: note) else { return }
            command = .buy(token, usdc: u)
        case .sell(let a, let x) where !a.resolved:
            guard let token = await spotToken(a, note: note) else { return }
            command = .sell(token, amount: x)
        default: break
        }
        updateActivity { $0.understood = command.summary }
        if let missing = missingKey(for: command) { reply(missing, note: note); return }   // a key wallet without this chain (Wallets.swift)
        if let off = moduleRefusal(command) { reply(off, note: note); return }   // switched off in Settings › Modules
        if case .sendTo(let name, let amount) = command { prepareTransfer(amount, to: name, note: note); return }
        if case .receive = command {
            withAnimation(StudioView.spring) { showReceive = true }
            let sol = isSolanaAddress(solanaAddress) ? "Solana \(AddressCheck.ends(solanaAddress).start) … \(AddressCheck.ends(solanaAddress).end)" : nil
            reply(say("Your addresses are on the canvas\(sol.map { " — \($0) for USDC and SOL (recommended)" } ?? ""), plus Base for USDC and ETH. ihatecrypto can’t pull money in; send it there from an exchange or another wallet, on that network. It shows up within about 30 s and I’ll tell you when it arrives. To put money you already have into a vault, say “deposit 1 USDC into Jupiter”.",
                      "Твои адреса на холсте\(sol.map { " — \($0) для USDC и SOL (рекомендую)" } ?? ""), и Base для USDC и ETH. ihatecrypto не может сам забрать деньги: отправь их туда с биржи или другого кошелька, именно в этой сети. Они появятся примерно через 30 с, и я скажу, когда придут. Чтобы положить уже имеющиеся деньги в хранилище, скажи «положи 1 USDC в Jupiter»."), note: note)
            return
        }
        let recipient: (name: String, network: AddressCheck.Network)? = switch command {
        case .sendNear(let name, _), .closeNear(let name): (name, .near)
        case .sendSol(let name, _): (name, .solana)
        default: nil
        }
        if let recipient {
            guard let entry = savedAddress(recipient.name, on: recipient.network) else {
                reply("There’s no \(recipient.network.title) address “\(recipient.name)” in Addresses. Save it first, e.g. “save <address> as \(recipient.name) on \(recipient.network.rawValue)”.", note: note)
                return
            }
            guard entry.memo.isEmpty else {
                reply("“\(entry.name)” needs a memo / tag, and ihatecrypto can’t add one to this transfer — send it from the exchange’s app instead.", note: note)
                return
            }
        }
        if let question = command.amountQuestion {
            awaitingAmount = command
            reply(say(question, "Сколько? Напиши число.") + amountHint(command), note: note)
            return
        }
        if let why = refusalBeforeCard(command) { reply(why, note: note); return }
        switch command {
        case .yields, .allocate, .rebalance, .schedule, .stopSchedules:
            // Read-only, or with a board and a step of their own.
            await move(command)
        default:
            pendingAction = .wallet(command)
            pendingText = readable(command.summary)
            reply(say("Understood: \(readable(command.summary)). It’s on the canvas — Sign it, or say anything else to cancel.",
                      "Понял: \(readable(command.summary)). Карточка на холсте — нажми Confirm или напиши что-нибудь другое, чтобы отменить."), note: note)
        }
    }

    /// What there is to use, so the answer to «How much?» is easy.
    private func amountHint(_ command: WalletCommand) -> String {
        switch command {
        case .lendDeposit("SOL", _), .kamino(_, "SOL", _), .stake:
            return solana.map { say(" You have \(Fmt.num($0.sol, maxFraction: 4)) SOL on Solana — answer with a number, e.g. “0.01”.", " На Solana \(Fmt.num($0.sol, maxFraction: 4)) SOL — ответь числом, например «0.01».") } ?? ""
        case .hlp: return hl.map { say(" \(Fmt.usd($0.withdrawable)) is free on Hyperliquid — answer with a number, e.g. “5”.", " На Hyperliquid свободно \(Fmt.usd($0.withdrawable)) — ответь числом, например «5».") } ?? ""
        default: return solana.map { say(" You have \(Fmt.num($0.usdc)) USDC on Solana — answer with a number, e.g. “1”.", " На Solana \(Fmt.num($0.usdc)) USDC — ответь числом, например «1».") } ?? ""
        }
    }

    /// The last few lines of this canvas's chat, for a model reading a follow-up like «1» or «yes».
    func recentChat() -> [String] {
        messages.dropFirst().suffix(6).map { ($0.fromUser ? "user: " : "ihatecrypto: ") + $0.text.prefix(300) }
    }
}
