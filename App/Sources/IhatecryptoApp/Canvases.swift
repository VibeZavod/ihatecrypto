import EVMChain
import Foundation
import IhatecryptoCore
import JupiterSwap
import LLMCatalog
import SwiftUI
import TradeExecution
import WalletCore

/// Owner-only JSON files in Application Support/ihatecrypto.
///
/// A chat reply changes activity.json and canvases.json several times in one go: each file is encoded once, at the
/// end of that turn of the run loop, and written off the main thread. Encoding stays on main: the app's types are
/// main-actor isolated, so their Codable conformances can't run elsewhere.
enum LocalStore {
    /// Writes go one at a time, in order.
    private static let queue = DispatchQueue(label: "app.ihatecrypto.localstore")
    /// Values saved during this turn, by file: only the last one of each is encoded.
    private static var pending: [String: () -> Data?] = [:]
    /// The bytes each file last got: an unchanged value isn't written again.
    private static var written: [String: Data] = [:]

    nonisolated static func url(_ name: String) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "ihatecrypto")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name)
    }

    static func load<T: Decodable>(_ name: String) -> T? {
        // A save still on its way would be read stale (flows.json is read, added to and saved).
        flush()
        let file = url(name)
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(T.self, from: data) } catch {
            // Written by a newer build or damaged: put aside, or the next save writes an empty list over the user's
            // canvases, history or addresses. «canvases.json.unreadable-2026-10-03T104809» can be read back by hand.
            let aside = URL(fileURLWithPath: file.path + ".unreadable-"
                + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted)))
            try? FileManager.default.moveItem(at: file, to: aside)
            FileHandle.standardError.write(Data("ihatecrypto: \(name) couldn't be read (\(error)); kept as \(aside.lastPathComponent)\n".utf8))
            return nil
        }
    }

    /// A file gone for good (a removed wallet's): what still waits to be written goes first, so it can't come back.
    static func remove(_ name: String) {
        flush()
        written[name] = nil
        try? FileManager.default.removeItem(at: url(name))
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
    /// The user's own name for it; wins over the title ihatecrypto keeps updating. Optional, so older files still load.
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
    /// A note written from the chat («запиши в папку ideas: …»): shown as a card on this canvas.
    var note: String?
    /// The notes written to it after the first, oldest first: a card each.
    var moreNotes: [String]?
    var notes: [String] { (note.map { [$0] } ?? []) + (moreNotes ?? []) }

    /// Picked from the icon library (the row's «Change icon…»); nil = the sign of what the canvas holds.
    var icon: AddressIcon?
    /// A scheduled item's own canvas («task:<id>», «buy:SOL», «perp:BTC»): its card shows on it, like a chat's board.
    var schedule: String?
    var displayTitle: String { name ?? (title.isEmpty ? "Canvas" : title) }
}

/// A money move carried out from a canvas.
struct CanvasOutcome: Codable, Equatable {
    var at: Date
    var ok: Bool
    /// Not ok, but not failed either: sent with no outcome back (Execution.swift unsettled); never offered again.
    var unknown: Bool?
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
        var c = old ?? CanvasSession(providerID: providerID, model: model, messages: [], intent: intent, folder: newCanvasFolder)
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

    /// Another canvas may open: nothing is being answered or carried out. A move saves its outcome, title, replies and
    /// «Try again» to the canvas open when it ends, so that canvas can't change under it.
    var canSwitchCanvas: Bool { !busy && !executing && runningAction == nil }

    func openCanvas(_ c: CanvasSession) {
        // The open canvas clicked again: its board back as it was kept, when nothing on it runs or waits for Confirm —
        // its boards closed had left it bare and the click did nothing («при повторном нажатии на этот канвас ничего
        // не происходит»).
        if c.id == canvasID {
            guard canSwitchCanvas, pendingAction == nil, pendingAllocation == nil, awaitingAmount == nil else { return }
            saveCanvas()
            if let kept = canvases.first(where: { $0.id == c.id }) { load(kept) }
            return
        }
        guard canSwitchCanvas else { return }
        saveCanvas()
        load(c)
        Task { await refreshQuote() }
    }

    func newCanvas() {
        guard canSwitchCanvas else { return }
        saveCanvas()
        clearCanvas()
        canvasID = nil
        messages = Array(messages.prefix(1))
        intent = TradeIntent()
        executed = nil
    }

    /// An empty name gives the canvas back its automatic title.
    func setCanvasIcon(_ id: UUID, _ icon: AddressIcon?) {
        guard let i = canvases.firstIndex(where: { $0.id == id }) else { return }
        canvases[i].icon = icon
    }

    func renameCanvas(_ id: UUID, to name: String) {
        guard let i = canvases.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        canvases[i].name = trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    /// A fresh canvas that goes into `folder` as soon as it's kept.
    func newCanvas(in folder: String) {
        guard canSwitchCanvas else { return }
        newCanvas()
        newCanvasFolder = folder
    }

    /// nil takes it out of its folder. Both folders stay in the list, even emptied.
    func moveCanvas(_ id: UUID, to folder: String?) {
        guard let i = canvases.firstIndex(where: { $0.id == id }) else { return }
        let to = folder.flatMap(Self.folderName)
        for f in [canvases[i].folder, to].compactMap({ $0 }) where !folders.contains(f) { folders.append(f) }
        canvases[i].folder = to
    }

    /// «save this canvas to folder X» moves the open canvas there; «write to folder X: …» keeps the text there as a note: a
    /// card on a canvas of its own, titled by it. Written on a new canvas, that canvas becomes the note; otherwise the open
    /// canvas stays open and shows the card with «Open». The next note to the same folder from there is one more card on
    /// that note canvas, not a canvas of its own. A new folder name makes the folder.
    func folderCommand(_ command: FolderCommand, note: String? = nil) {
        switch command {
        case .save(let folder):
            saveCanvas()
            guard let id = canvasID else {
                newCanvasFolder = folder
                createFolder(folder)
                reply(say("This canvas goes to «\(folder)» as soon as it has something on it.", "Холст попадёт в «\(folder)», как только на нём что-то появится."), note: note)
                return
            }
            moveCanvas(id, to: folder)
            reply(say("Saved this canvas to «\(folder)».", "Сохранил этот холст в папку «\(folder)»."), note: note)
        case .note(let folder, let text):
            createFolder(folder)
            let title = text.count > 48 ? String(text.prefix(48)) + "…" : text
            // This canvas is a note in that folder, or shows one: the note joins it as one more card.
            if let i = canvases.firstIndex(where: { c in c.note != nil && c.folder == folder && (c.id == canvasID || c.id == noteCard?.canvas) }) {
                canvases[i].moreNotes = (canvases[i].moreNotes ?? []) + [text]
                canvases[i].updated = Date()
                noteCard = NoteCard(canvas: canvases[i].id, folder: folder, texts: canvases[i].notes)
            } else if canvasID == nil, messages.filter(\.fromUser).count <= 1 {
                // A new canvas with only this message: it becomes the note, keeping the chat that wrote it.
                newCanvasFolder = folder
                saveCanvas()
                if let id = canvasID, let i = canvases.firstIndex(where: { $0.id == id }) {
                    canvases[i].note = text
                    canvases[i].title = title
                    noteCard = NoteCard(canvas: id, folder: folder, texts: [text])
                }
            } else {
                // Only the greeting, as on every canvas: the note is its card, not a message.
                var c = CanvasSession(providerID: providerID, model: model, messages: Array(messages.prefix(1)), intent: TradeIntent(), folder: folder)
                c.title = title
                c.note = text
                canvases.insert(c, at: 0)
                noteCard = NoteCard(canvas: c.id, folder: folder, texts: [text])
            }
            reply(say("Saved the note to «\(folder)» — it's on the canvas.", "Записал заметку в «\(folder)» — она на холсте."), note: note)
        }
    }

    /// An empty name makes nothing.
    func createFolder(_ name: String) {
        if let f = Self.folderName(name), !folders.contains(f) { folders.append(f) }
    }

    /// Its canvases go with it; merging into a folder of that name if one exists.
    func renameFolder(_ old: String, to name: String) {
        guard let new = Self.folderName(name), new != old else { return }
        for i in canvases.indices where canvases[i].folder == old { canvases[i].folder = new }
        folders = folders.filter { $0 != old && $0 != new } + [new]
        if let icon = folderIcons.removeValue(forKey: old), folderIcons[new] == nil { folderIcons[new] = icon }
        if newCanvasFolder == old { newCanvasFolder = new }
    }

    /// The folder goes; its canvases stay, out of any folder.
    func deleteFolder(_ name: String) {
        for i in canvases.indices where canvases[i].folder == name { canvases[i].folder = nil }
        folders.removeAll { $0 == name }
        folderIcons[name] = nil
        if newCanvasFolder == name { newCanvasFolder = nil }
    }

    private static func folderName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(40))
    }

    /// At most this many canvases stay pinned to the top of the list.
    static let maxPinned = 5

    /// Pinning past the limit does nothing; the menu says to unpin one first.
    func pinCanvas(_ id: UUID, _ on: Bool) {
        guard let i = canvases.firstIndex(where: { $0.id == id }),
              !on || canvases.filter({ $0.pinnedAt != nil }).count < Self.maxPinned else { return }
        canvases[i].pinnedAt = on ? Date() : nil
    }

    var canvasFolders: [String] { Array(Set(folders + canvases.compactMap(\.folder))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    func deleteCanvas(_ id: UUID) {
        // The open one only when another can take its place: an answer still being written would save it back.
        if id == canvasID {
            guard canSwitchCanvas else { return }
            newCanvas()
        }
        canvases.removeAll { $0.id == id }
        // A price alert that waited to prepare its plan goes with it.
        alerts.removeAll { $0.plan == id }
    }

    /// The canvas that was open last time (else the one worked on last).
    func restoreLastCanvas() {
        let open = UserDefaults.standard.string(forKey: "openCanvas").flatMap(UUID.init(uuidString:))
        if let last = canvases.first(where: { $0.id == open }) ?? canvases.max(by: { $0.updated < $1.updated }) { load(last) }
    }

    private func load(_ c: CanvasSession) {
        clearCanvas()
        canvasID = c.id
        // A note is a card on the canvas. One written before 2026-10-01 was kept as the only message of a canvas in a folder.
        let oldNote = c.note == nil && c.folder != nil && c.messages.count == 1 && c.messages[0].fromUser ? c.messages[0].text : nil
        messages = oldNote == nil ? c.messages : Array(messages.prefix(1))
        let notes = oldNote.map { [$0] } ?? c.notes
        noteCard = notes.isEmpty ? nil : NoteCard(canvas: c.id, folder: c.folder, texts: notes)
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
        newCanvasFolder = nil
        takeChoices = nil
        nextSteps = nil
        yieldOptions = nil
        allocationPreview = nil
        pendingAllocation = nil
        pendingAction = nil
        pendingText = nil
        // «How much SOL into Kamino?» was asked here: a bare number on the next canvas answers something else.
        awaitingAmount = nil
        finishedAction = nil
        planReview = nil
        savedBoard = nil
        noteCard = nil
        chart = nil
        currentActivity = nil
        draft = ""
        // What the rail opened belongs to the canvas it was opened on; the next one starts clean, scrolled to its start at
        // the zoom the user set (zooming is theirs: the buttons and the pinch, never a canvas switch).
        detail = nil
        showReceive = false
        showMovers = false
        serviceAnswer = nil
        showAlerts = false
        showHistory = false
        showFavorites = false
        showSchedule = false
        UserDefaults.standard.set("plan", forKey: "canvasMode")
        if !keepViewport { NotificationCenter.default.post(name: .canvasFit, object: "home") }
    }
}

// MARK: Views

/// The saved canvases, newest first; a click opens one with its chat, plan and model.
struct CanvasList: View {
    @Environment(Workspace.self) private var ws
    var close: (() -> Void)?
    /// Folded folders, one name per line; kept between launches.
    @AppStorage("foldedCanvasFolders") var foldedRaw = ""
    @State private var newFolder = false
    @State private var folderName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Canvases").font(.ui(12)).foregroundStyle(.secondary).padding(.leading, 4)
                Spacer()
                Button { folderName = ""; newFolder = true } label: {
                    Image(systemName: "folder.badge.plus").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.hoverIcon).help("New folder — drag canvases into it")
                // The whole pill is the button and lights up under the pointer, not only its glyphs.
                Button { withAnimation(StudioView.spring) { ws.newCanvas() }; close?() } label: {
                    Label("New", systemImage: "square.and.pencil").font(.ui(10, .semibold)).padding(.horizontal, 8)
                }
                .buttonStyle(.hoverIcon).help(ws.canSwitchCanvas ? "New canvas" : ws.busy ? "ihatecrypto is still answering" : "A move is running on this canvas").disabled(!ws.canSwitchCanvas)
                .padding(.trailing, -8)   // the word lines up with the rows' right edge; only the hover wash goes past it
            }
            let items = ws.canvases.sorted { $0.updated > $1.updated }
            if items.isEmpty {
                Text("Each conversation gets its own canvas and is kept here.").font(.ui(10)).foregroundStyle(.tertiary)
            }
            // A canvas dropped anywhere but on a folder leaves its folder.
            ScrollView { rows(items) }.scrollIndicators(.never)
                .modifier(CanvasDrop { id in withAnimation(.snappy) { ws.moveCanvas(id, to: nil) } })
        }
        .alert("New folder", isPresented: $newFolder) {
            TextField("Folder name", text: $folderName)
            Button("Create") { withAnimation(.snappy) { ws.createFolder(folderName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Drag canvases into it, or start one there from its menu.")
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
            // The open canvas before it's kept shows at once, on top, instead of appearing only after the first answer.
            if ws.canvasID == nil { NewCanvasRow() }
            ForEach(pinned) { row($0) }
            if !pinned.isEmpty, !items.isEmpty { Divider().padding(.vertical, 4).padding(.horizontal, 8) }
            ForEach(ws.canvasFolders, id: \.self) { folder in
                let inside = items.filter { $0.folder == folder }
                VStack(alignment: .leading, spacing: 2) {
                    FolderRow(name: folder, count: inside.count, folded: folded.contains(folder)) {
                        var set = folded
                        if set.contains(folder) { set.remove(folder) } else { set.insert(folder) }
                        withAnimation(.snappy) { foldedRaw = set.sorted().joined(separator: "\n") }
                    }
                    if !folded.contains(folder) {
                        ForEach(inside) { row($0).padding(.leading, 12) }
                    }
                }
                .modifier(CanvasDrop { id in withAnimation(.snappy) { ws.moveCanvas(id, to: folder) } })
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

/// The notes of a note canvas, shown on the canvas they were written to.
struct NoteCard: Equatable {
    var canvas: UUID
    var folder: String?
    var texts: [String]
}

/// A note from the chat as a card: on its own canvas in the folder, and where it was written (there with «Open»).
struct NoteBoard: View {
    @Environment(Workspace.self) private var ws
    let note: NoteCard

    var body: some View {
        // A card per note, newest at the bottom; «Open» on the first only.
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(note.texts.enumerated()), id: \.offset) { i, text in card(text, first: i == 0) }
        }
        .transition(.opacity)
    }

    private func card(_ text: String, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "note.text").font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.accentInk)
                Text(note.folder.map { "Note · \($0)" } ?? "Note").font(.ui(13, .semibold)).foregroundStyle(.secondary)
                Spacer()
                if first, note.canvas != ws.canvasID, let c = ws.canvases.first(where: { $0.id == note.canvas }) {
                    Button("Open") { withAnimation(StudioView.spring) { ws.openCanvas(c) } }
                        .buttonStyle(.bordered).controlSize(.small).disabled(!ws.canSwitchCanvas)
                        .help("The note's own canvas, in its folder")
                }
            }
            Text(text).font(.ui(16, .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 470, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 26).fill(Brand.card).shadow(color: .black.opacity(0.08), radius: 18, y: 10))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Brand.cardBorder, lineWidth: 1.5))
    }
}

/// The open canvas before it's kept: its edge pulses while it waits for the first message and while the first answer is
/// being written; with that answer it becomes a row of its own.
private struct NewCanvasRow: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 8).fill(Brand.glassFill).frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Brand.glassRim))
                .overlay(Image(systemName: "bubble.left").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(ws.messages.first(where: \.fromUser)?.text ?? "New canvas").font(.ui(13, .semibold)).lineLimit(1)
                Text(ws.thinking ? "answering…" : ws.newCanvasFolder.map { "goes to «\($0)» · write below" } ?? "write below to keep it")
                    .font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.glassSelected))
        .modifier(PulsingEdge(active: true))
        .help("A new canvas: it's kept here once you write something")
    }
}

/// A row's edge breathing in the accent while `active` (a canvas being written). Only the border changes, the row stays put.
struct PulsingEdge: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            // The repeating animation is scoped to this border: started with withAnimation as the row lit up, it took
            // along whatever else changed in that update — the canvas's old board, leaving on Confirm, stayed on
            // screen under the running one for as long as the row breathed («опять видно два канваса»).
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.accent.opacity(active ? (lit ? 0.8 : 0.2) : 0), lineWidth: 1.5)
                .animation(active && !reduceMotion ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: lit))
            .onChange(of: active, initial: true) { lit = active }
    }
}

/// A folder of canvases: a click folds or unfolds it; canvases are dragged onto it.
struct FolderRow: View {
    @Environment(Workspace.self) private var ws
    let name: String
    let count: Int
    let folded: Bool
    let toggle: () -> Void
    @State private var hover = false
    @State private var renaming = false
    @State private var draft = ""
    @State private var picking = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(folded ? 0 : 90))
                    if let icon = ws.folderIcons[name] {
                        PickedIcon(icon: icon, size: 18, letter: name)
                    } else {
                        Image(systemName: folded ? "folder" : "folder.fill").font(.system(size: 12)).foregroundStyle(Brand.accentInk)
                    }
                    Text(name).font(.ui(12.5, .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(count)").font(.ui(10)).foregroundStyle(.tertiary).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(folded ? "Show the canvases in \(name)" : "Fold \(name)")
            Menu { actions } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .pointerStyle(.link)
            .opacity(hover ? 1 : 0)
            .allowsHitTesting(hover)
            .help("New canvas here, rename, change icon, delete")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .onHover { hover = $0 }
        .contextMenu { actions }
        .popover(isPresented: $picking, arrowEdge: .trailing) {
            IconPicker(icon: Binding(get: { ws.folderIcons[name] }, set: { ws.folderIcons[name] = $0 }), name: name)
        }
        .alert("Rename folder", isPresented: $renaming) {
            TextField("Folder name", text: $draft)
            Button("Rename") { withAnimation(.snappy) { ws.renameFolder(name, to: draft) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var actions: some View {
        Group {
            Button { withAnimation(StudioView.spring) { ws.newCanvas(in: name) } } label: {
                Label("New canvas here", systemImage: "square.and.pencil")
            }
            .disabled(!ws.canSwitchCanvas)
            Button { draft = name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
            Button { picking = true } label: { Label("Change icon…", systemImage: "face.smiling") }
            Divider()
            Button(role: .destructive) { withAnimation(.snappy) { ws.deleteFolder(name) } } label: { Label("Delete folder (canvases stay)", systemImage: "trash") }
        }
        .labelStyle(.titleAndIcon)
    }
}

/// Takes a canvas dragged from the list; its edge lights while one is over it.
private struct CanvasDrop: ViewModifier {
    let drop: (UUID) -> Void
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.accent, lineWidth: 1.5).opacity(over ? 1 : 0))
            .dropDestination(for: String.self) { items, _ in
                let ids = items.compactMap(UUID.init(uuidString:))
                ids.forEach(drop)
                return !ids.isEmpty
            } isTargeted: { over = $0 }
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
    @State private var picking = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if renaming {
                content
            } else {
                Button(action: open) { content }.buttonStyle(.plain)
                    .draggable(canvas.id.uuidString)
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
        // The open canvas pulses while its answer is being written.
        .modifier(PulsingEdge(active: current && ws.thinking))
        .onHover { hover = $0 }
        .help("\(canvas.displayTitle) · \(LLMCatalog.provider(id: canvas.providerID)?.info.name ?? canvas.providerID) · \(canvas.model)")
        .contextMenu { actions }
        .popover(isPresented: $picking, arrowEdge: .trailing) {
            IconPicker(icon: Binding(get: { canvas.icon }, set: { ws.setCanvasIcon(canvas.id, $0) }), name: canvas.displayTitle)
        }
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
            if let icon = canvas.icon {
                PickedIcon(icon: icon, size: 26, letter: canvas.displayTitle)
            } else if canvas.intent != TradeIntent() {
                AssetBadge(coin: canvas.intent.asset, size: 26, dark: true)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Brand.glassFill).frame(width: 26, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Brand.glassRim))
                    .overlay(Image(systemName: canvas.note != nil ? "note.text" : canvas.bubbles.isEmpty ? "bubble.left" : "square.grid.2x2").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary))
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

    // Each action with its icon, as in Finder's menus.
    private var actions: some View {
        Group { actionItems }.labelStyle(.titleAndIcon)
    }

    @ViewBuilder private var actionItems: some View {
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
        Button {
            draft = canvas.displayTitle
            renaming = true
            DispatchQueue.main.async { nameFocused = true }
        } label: { Label("Rename", systemImage: "pencil") }
        Button { picking = true } label: { Label("Change icon…", systemImage: "face.smiling") }
        Menu {
            let others = ws.canvasFolders.filter { $0 != canvas.folder }
            ForEach(others, id: \.self) { f in
                Button { withAnimation(.snappy) { ws.moveCanvas(canvas.id, to: f) } } label: { Label(f, systemImage: "folder") }
            }
            if !others.isEmpty { Divider() }
            Button { folderName = ""; newFolder = true } label: { Label("New folder…", systemImage: "folder.badge.plus") }
            if let current = canvas.folder {
                Button { withAnimation(.snappy) { ws.moveCanvas(canvas.id, to: nil) } } label: { Label("Remove from “\(current)”", systemImage: "folder.badge.minus") }
            }
        } label: { Label("Move to folder", systemImage: "folder") }
        Divider()
        Button(role: .destructive) { withAnimation { ws.deleteCanvas(canvas.id) } } label: { Label("Delete canvas", systemImage: "trash") }
            .disabled(current && !ws.canSwitchCanvas)
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
                    if let answer = done.bubbles.last?.answer { ServiceAnswerBoard(answer: answer, closable: false) }
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
                HStack(spacing: 12) {
                    Label("\(o.ok ? "Executed" : o.unknown == true ? "Sent, status unknown" : "Failed") · \(Fmt.date(o.at))", systemImage: o.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.ui(13, .semibold)).foregroundStyle(o.ok ? Brand.profit : Brand.loss)
                    // The same move again: a fresh card with new quotes, waiting for Confirm like the first time. What the
                    // failed run already did stays done (USDC it bridged waits on that network; the chat said so).
                    if !o.ok, let retry = ws.retryCommand, retry.canvas == canvas.id {
                        Button { Task { await ws.handleWallet(retry.command) } } label: {
                            Label("Try again", systemImage: "arrow.clockwise").font(.ui(12, .semibold))
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Lays the same move out again with fresh quotes; nothing moves until you Confirm. What the failed run already did stays done.")
                    }
                }
            } else {
                // Its Refresh is at the header's top right, where a live board has Cancel and Confirm.
                Label("As it was · \(Fmt.date(canvas.boardAt ?? canvas.updated))", systemImage: "clock.arrow.circlepath")
                    .font(.ui(10)).foregroundStyle(.secondary)
            }
            if !canvas.bubbles.isEmpty, canvas.bubbles.allSatisfy({ $0.kind == "step" }) {
                RouteCards(steps: canvas.bubbles, outcome: canvas.outcome?.ok, asItWas: canvas.outcome == nil)
                if let answer = canvas.bubbles.last?.answer { ServiceAnswerBoard(answer: answer, closable: false) }
            } else {
                LazyVGrid(columns: [GridItem(.fixed(220), alignment: .top), GridItem(.fixed(220), alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(canvas.bubbles, id: \.self) { HistoryBubble(bubble: $0) }
                }
            }
        }
        // It leaves at once: the board taking its place (the running one) is already drawn, and a removal caught in
        // someone's repeating animation would keep both on screen.
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)), removal: .identity))
    }
}

/// A row in ihatecrypto's own menus: a title, an optional detail, a hover highlight.
struct MenuRow: View {
    let title: String
    var detail: String?
    var icon: String?
    /// The icon's own color, when it tells something (a subscription in the model menu).
    var iconTint: Color?
    var shortcut: String?
    var checked = false
    var tint: Color = .primary
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).frame(width: 18).foregroundStyle(iconTint ?? (tint == .primary ? .secondary : tint)) }
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
            RouteCards(steps: [
                ActivityBubble(kind: "step", label: "EVERY \(period.uppercased()) · BUY", title: "\(Fmt.usd(schedule.usdc)) → \(schedule.symbol)",
                               lines: ["next\t\(schedule.next <= Date() ? "now" : Fmt.date(schedule.next))",
                                       "a month\t≈ \(Fmt.usd(schedule.usdc * 30 / Decimal(max(schedule.days, 1))))"], logo: "jup", fill: .jupiter),
                ActivityBubble(kind: "step", label: "FROM · SOLANA", title: "\(Fmt.num(schedule.usdc)) USDC",
                               lines: [balance.map { "free\t\(Fmt.num($0)) USDC" } ?? "USDC on Solana"], logo: "sol", fill: .solana),
                ActivityBubble(kind: "step", label: "BUY · JUPITER", title: schedule.symbol,
                               lines: ["Jupiter quote, address check, simulation and signature — like a manual one"],
                               logo: TokenLogo.name(forAsset: schedule.symbol) ?? "jup", fill: .jupiter),
            ])
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
        .frame(width: RouteCards.width(3) + 32)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card).shadow(color: .black.opacity(0.06), radius: 14, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.cardBorder))
    }

    private var period: String { schedule.days == 1 ? "day" : schedule.days == 7 ? "week" : schedule.days == 30 ? "month" : "\(schedule.days) days" }
}

/// The running Jupiter DCA orders: how much each has spent and bought, the swap size and interval, and Cancel. The
/// orders live on-chain; this reads them from Jupiter when asked and after a DCA is placed or cancelled.
struct JupiterDCABoard: View {
    @Environment(Workspace.self) private var ws
    let orders: [JupiterRecurring.Order]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TokenLogo(name: "jup", size: 26)
                Text("Jupiter DCA").font(.ui(15, .bold))
                Spacer()
                StatusChip(text: orders.count == 1 ? "1 running" : "\(orders.count) running", tint: Brand.profit)
            }
            ForEach(orders, id: \.key) { order in row(order) }
            Text("On-chain: Jupiter's keepers buy even with ihatecrypto closed. Cancel returns what wasn't spent and the rent.")
                .font(.ui(10)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: RouteCards.width(3) + 32)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card).shadow(color: .black.opacity(0.06), radius: 14, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.cardBorder))
    }

    private func row(_ o: JupiterRecurring.Order) -> some View {
        let coin = SpotAsset.all.first { $0.mint == o.outputMint }?.symbol ?? "\(o.outputMint.prefix(4))…"
        let done = o.deposited > 0 ? NSDecimalNumber(decimal: o.used / o.deposited).doubleValue : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TokenLogo(name: "usdc", size: 22)
                Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                AssetBadge(coin: coin, size: 22)
                Text("\(Fmt.num(o.perCycle)) USDC → \(coin) every \(WalletCommand.everyText(o.every))").font(.ui(13, .semibold))
                Spacer()
                Button("Cancel") { Task { await ws.send("cancel Jupiter DCA \(coin)") } }.buttonStyle(.borderless).foregroundStyle(Brand.loss)
            }
            ProgressView(value: min(max(done, 0), 1)).tint(Brand.accent)
            HStack {
                Text("spent \(Fmt.num(o.used)) of \(Fmt.num(o.deposited)) USDC · \(o.fills) \(o.fills == 1 ? "swap" : "swaps")").monospacedDigit()
                Spacer()
                Text("bought \(Fmt.num(o.received, maxFraction: 6)) \(coin)").monospacedDigit()
            }
            .font(.ui(11.5)).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
    }
}

extension Workspace {
    /// Why a plan can't go, in a few words for its status and a sentence for the chat. nil when nothing stops it (or a
    /// detail is still missing: that has its own «By the book»).
    var planBlocker: (short: String, sentence: String)? {
        guard intent != TradeIntent(), !managesPosition, missingDetails == nil else { return nil }
        let b = blocks, e = evaluation
        if let s = e.sizing, s.notional < 10, e.problem != nil {
            return (say("order under the $10 minimum", "ордер меньше $10"),
                    say("The order is \(Fmt.usd(s.notional)), under Hyperliquid’s $10 minimum.", "Ордер \(Fmt.usd(s.notional)) — меньше минимума Hyperliquid $10."))
        }
        if let p = e.problem { return (say("the position can’t be placed", "позицию не выставить"), p) }
        if let source = b.first(where: { $0.id == "source" }), source.status == .blocked, let short = source.lines.last?.dropLast() {
            let place = fundingNet?.name ?? "Solana"
            return (say("not enough USDC", "не хватает USDC"), say("\(short) on \(place).", "\(short.replacingOccurrences(of: "Short by", with: "Не хватает")) на \(place)."))
        }
        if let s = e.sizing, let equity, equity > 0, s.lossAtStopUSD / equity * 100 > policy.maxRiskPct {
            return (say("risk over the \(Fmt.pct(policy.maxRiskPct)) limit", "риск выше лимита \(Fmt.pct(policy.maxRiskPct))"),
                    say("At the stop \(Fmt.usd(s.lossAtStopUSD)) is lost, over the limit of \(Fmt.pct(policy.maxRiskPct)) of capital (\(Fmt.usd(equity * policy.maxRiskPct / 100))).",
                        "На стопе теряется \(Fmt.usd(s.lossAtStopUSD)) — больше лимита \(Fmt.pct(policy.maxRiskPct)) капитала (\(Fmt.usd(equity * policy.maxRiskPct / 100)))."))
        }
        guard let stopped = b.first(where: { $0.status == .blocked }) else { return nil }
        let line = stopped.lines.first { $0.hasPrefix("✗") }.map { String($0.dropFirst(2)) } ?? stopped.lines.first ?? stopped.title
        return (say("a rule stops it", "его стопорит правило"), line)
    }

    /// For a plan the rules stop: the one change that passes every rule, the $10 minimum and the money (Plan.fix), as a
    /// card or button says it.
    var planFix: (title: String, detail: String, command: String)? {
        guard planBlocker != nil, let m = market else { return nil }
        // ponytail: the richest source (Solana or an EVM network the plan can bridge from) less a bridge-fee cushion, plus
        // what is free on Hyperliquid; the confirm step re-quotes exactly.
        let richest = ([solana?.usdc] + EVMNetwork.searched.map { usdc(on: $0.key) }).compactMap { $0 }.max() ?? 0
        let available = max(0, richest - Decimal(string: "0.1")!) + (hl.map { $0.withdrawable + (m.dex.flatMap { dexBalances[$0]?.withdrawable } ?? 0) } ?? 0)
        guard let f = Plan.fix(intent, market: m, equity: equity, policy: policy,
                               openRisk: HyperliquidAccount.riskAtStops(positions: positions, orders: orders), available: available) else { return nil }
        // Said as what changes in the trade, not as a sum: «Risk $0.33» read like something to pay.
        let s = f.sizing, now = evaluation.sizing
        let title = f.command.hasSuffix("USDC")
            ? say("Put \(f.command) in the trade", "Вложить \(f.command) в сделку")
            : (now.map { s.notional > $0.notional } ?? true)
                ? say("Raise the order to \(Fmt.usd(s.notional))", "Поднять ордер до \(Fmt.usd(s.notional))")
                : say("Cut the order to \(Fmt.usd(s.notional))", "Уменьшить ордер до \(Fmt.usd(s.notional))")
        let was = now.map { " " + say("instead of", "вместо") + " −\(Fmt.usd($0.lossAtStopUSD))" } ?? ""
        return (title, say("At the stop −\(Fmt.usd(s.lossAtStopUSD))\(was), margin \(Fmt.usd(s.margin)) — passes every rule.",
                           "На стопе −\(Fmt.usd(s.lossAtStopUSD))\(was), маржа \(Fmt.usd(s.margin)) — проходит все правила."), f.command)
    }
}

/// Confirm and Cancel under a board waiting for «do it»: the same path as typing «do it» or «cancel» in the chat,
/// so the signer, the guard and Jev see exactly what they would.
struct PendingButtons: View {
    @Environment(Workspace.self) private var ws
    var confirm = "Confirm"

    var body: some View {
        // Cancel first, Confirm last: the macOS order, and at a board's top right Confirm sits at the corner.
        HStack(spacing: 8) {
            Button("Cancel") { Task { await ws.send("cancel") } }
                .buttonStyle(.bordered).controlSize(.large)
            Button { Task { await ws.pressConfirm() } } label: {
                Label(confirm, systemImage: "touchid").font(.ui(13, .semibold)).padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
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

    /// A footer counts an approve and what spends it as two transactions; with Settings › Wallet › «One transaction for
    /// approve and swap» on, Touch ID signs them as one (EIP-7702), and the card says so.
    init(title: String, footer: String, steps: [ActivityBubble], warning: String? = nil) {
        self.title = title
        self.footer = Executor.batchesOn && footer.contains("approve")
            ? footer + " With «One transaction for approve and swap» on, Touch ID signs the approve and what spends it as one transaction."
            : footer
        self.steps = steps
        self.warning = warning
    }
}

/// A route step's color, by place; kept by name, so a saved route draws the same.
enum RouteFill: String, Codable, Hashable, Sendable {
    case solana, relay, hyperliquid, hlp, jupiter, kamino, jito, aave, morpho, base, arbitrum, robinhood, near, tempo
    /// A plan's checks and its result: no place of their own, a grey card.
    case check

    /// A place a newer build added reads as a grey card: one unknown card would leave the whole file unreadable.
    init(from decoder: Decoder) throws {
        self = RouteFill(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .check
    }

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
        case .tempo: Color(hex: 0x111111)
        case .check: Color(light: 0xF7F7F8, dark: 0x26262B)
        }
    }
    var dark: Bool { self != .solana && self != .check }
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
        case .buyOn(let place, let token, let usdc?, let from): swapRoute(place, token, usdc: usdc, sell: nil, from: from)
        case .sellOn(let place, let token, let amount, let keep): swapRoute(place, token, usdc: nil, sell: amount, keep: keep)
        case .swapOn(let place, let from, let to, let amount): pairRoute(place, from, to, amount)
        case .crossSwap(let a, let from, let b, let to, let amount): crossRoute(a, from, b, to, amount)
        case .sweepDust(let under): dustRoute(under)
        case .revokeApproval(let place, let token, let spender, let permit2): revokeRoute(place, token, spender, permit2)
        case .hlSpotBuy(let symbol, let usdc?): hlSpotRoute(symbol, usdc: usdc, sell: nil)
        case .hlSpotSell(let symbol, let amount): hlSpotRoute(symbol, usdc: nil, sell: amount)
        case .sellNear(let asked, let to): sellNearRoute(asked, to: to)
        case .buyNear(let usdc?): buyNearRoute(usdc)
        case .sendNear(let name, let asked): nearOutRoute(to: name, amount: asked, close: false)
        case .closeNear(let name): nearOutRoute(to: name, amount: nil, close: true)
        case .sendSol(let name, let amount): solOutRoute(to: name, amount: amount)
        case .sendToken(let name, let token, let amount, let network):
            if let r = try? acrossRecipient(name, token: token, network: network) { acrossRoute(command, r, amount) }
            else { tokenOutRoute(to: name, token: token, amount: amount, network: network) }
        case .pay: payRoute(command)
        case .bridge(let from, let to, let amount): bridgeRoute(from, to, amount)
        case .gas(let place, let usd): gasRoute(place, usd ?? 1)
        case .claimRewards, .sweepRewards: claimRoute()
        default: ends(command).map { from, to in
            let footer = if case .sellStock = command {
                "Two Robinhood Chain transactions: an exact approve and the Uniswap swap, which may only pay this wallet. Press Confirm; Cancel or “cancel” drops it."
            } else {
                "One Solana signature, checked and simulated before it’s signed. Press Confirm; Cancel or “cancel” drops it."
            }
            return MoveRoute(title: readable(command.summary.prefix(1).uppercased() + command.summary.dropFirst()), footer: footer, steps: around(command, [from, to]))
        }
        }
    }

    private func step(_ logo: String, _ label: String, _ title: String, _ line: String, _ fill: RouteFill) -> ActivityBubble {
        ActivityBubble(kind: "step", label: label, title: title, lines: [line], logo: logo, fill: fill)
    }

    /// An exact approve on an EVM chain as a step of its own: this much, for this contract, nothing more.
    private func approve(_ amount: String, for spender: String, logo: String, _ fill: RouteFill, line: String? = nil) -> ActivityBubble {
        step(logo, "APPROVE · EXACT", amount, line ?? "exactly this · only \(spender) may take it", fill)
    }

    /// What a move between two places has besides its ends: a stock token sold on Robinhood Chain is approved exactly
    /// first, and HLP keeps a deposit for 4 days.
    private func around(_ command: WalletCommand, _ ends: [ActivityBubble]) -> [ActivityBubble] {
        switch command {
        case .sellStock(let s, let x):
            let name = s.hasPrefix("0x") ? (favoriteToken(s)?.symbol ?? tokenLabel(s)) : s.uppercased()
            return [approve(x.map { "\(Fmt.num($0, maxFraction: 6)) \(name)" } ?? "all \(name)", for: "Uniswap", logo: "uni", .robinhood)] + ends
        case .hlp(true, _):
            let out = Calendar.current.date(byAdding: .day, value: 4, to: Date()) ?? Date()
            return ends + [step("hype", "LOCKED · 4 DAYS", ends.last?.title ?? "USDC", "HLP lets it out from \(Fmt.date(out))", .hlp)]
        default:
            return ends
        }
    }

    /// Any wallet command without a drawn route still gets its card with Confirm: a pending move is never invisible.
    func fallbackRoute(_ command: WalletCommand) -> MoveRoute {
        MoveRoute(title: readable(Self.canvasTitle(command)),
                  footer: "Checked and simulated before it’s signed. Press Confirm; Cancel or “cancel” drops it.", steps: [])
    }

    /// USDC → native NEAR through NEAR Intents (1Click): from Solana, or from the EVM network holding it when Solana is
    /// short — the executor's own rule (Executor.nearSource), so the card names where the USDC really comes from.
    private func buyNearRoute(_ usdc: Decimal) -> MoveRoute {
        let onSolana = self.usdc(on: "solana") ?? 0
        let src = Executor.nearSource(usdc: usdc, onSolana: onSolana, held: { self.usdc(on: $0) })
        let near = markets["NEAR"].map { usdc / $0.markPx }
        let from = src?.name ?? "Solana"
        return MoveRoute(title: "Buy NEAR for \(Fmt.num(usdc)) USDC",
                         footer: "One transfer on \(from): exactly this USDC to the 1Click deposit address the quote names, checked before signing\(src == nil ? "" : "; a refund comes back to your own address there"). Native NEAR arrives on your NEAR account in ≈ 30–50 s. Press Confirm.",
                         steps: [
            step(src?.key ?? "sol", "FROM · \(from.uppercased())", "\(Fmt.num(usdc)) USDC",
                 src == nil ? "" : "Solana has only \(Fmt.num(onSolana)) · straight from \(from), no bridge", src == nil ? .solana : .relay),
            step("near", "SWAP · NEAR INTENTS", "1Click", "the quote is checked before signing", .relay),
            step("near", "TO · NEAR", near.map { "≈ \(Fmt.num($0, maxFraction: 4)) NEAR" } ?? "NEAR", "your own NEAR account ✓", .near),
        ])
    }

    /// Native NEAR → USDC on Solana through NEAR Intents (1Click); «all» keeps ≈ 0.09 NEAR: storage, and prepaid gas
    /// at NEAR's pessimistic price (NearTransaction.intentDepositOverhead), most of which comes back after the sale.
    /// NEAR for USDC through 1Click, on Solana or (`to`) at our address on Base, Arbitrum or Ethereum.
    private func sellNearRoute(_ asked: Decimal?, to: String? = nil) -> MoveRoute {
        let amount = asked ?? max(0, near - Decimal(string: "0.09")!)
        let usd = markets["NEAR"].map { amount * $0.markPx }
        let name = to.map(WalletCommand.placeName) ?? "Solana", logo = to.flatMap { ModuleNetwork(place: $0)?.logo } ?? "sol"
        let fill = to.flatMap { RouteFill(rawValue: $0) } ?? .solana
        return MoveRoute(title: "Sell \(Fmt.num(amount, maxFraction: 4)) NEAR for USDC on \(name)",
                         footer: "One NEAR transaction: exactly this NEAR, wrapped and sent to the 1Click deposit address the quote names, checked before signing. USDC arrives at your own address on \(name) in ≈ 30–40 s; the card says each step of 1Click's as it goes. Press Confirm.",
                         steps: [
            step("near", "FROM · NEAR", "\(Fmt.num(amount, maxFraction: 4)) NEAR", usd.map { "≈ \(Fmt.usd($0)) · ≈ 0.09 NEAR stays for storage and gas, most of it back after" } ?? "", .near),
            step("near", "SWAP · NEAR INTENTS", "1Click", "the quote is checked before signing", .relay),
            step(logo, "ARRIVES · ≈ 30–40 S", "→ \(name)", "1Click sends the USDC over", .near),
            step(logo, "TO · \(name.uppercased())", usd.map { "≈ \(Fmt.num($0.rounded(2, .plain))) USDC" } ?? "USDC",
                 "your own address ✓", fill),
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
                            + "Press Confirm.",
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
                         footer: "One Solana transfer: only this saved address may receive it, and the simulation must show exactly this SOL leaving plus the fee. Press Confirm.",
                         steps: [
            step("sol", "FROM · SOLANA", "\(Fmt.num(amount, maxFraction: 9)) SOL", solana.map { "free: \(Fmt.num($0.sol, maxFraction: 6)) SOL" } ?? "", .solana),
            step("sol", "TO · \(entry.label?.uppercased() ?? "SAVED ADDRESS")", entry.name, "\(ends.start) … \(ends.end)", .solana),
        ], warning: entry.lastSent == nil ? "First transfer to this address. Sending a small test amount first is the safe habit." : nil)
    }

    /// A token as it is to a saved address, on one network: what the portfolio last read of it there, when it has.
    private func tokenOutRoute(to name: String, token: String, amount: Decimal?, network: String?) -> MoveRoute? {
        guard let (entry, net) = try? tokenRecipient(name, network: network) else { return nil }
        let ends = AddressCheck.ends(entry.address), place = AddressCheck.Network(rawValue: net)
        let fill = RouteFill(rawValue: net) ?? .check, logo = place?.logo ?? "sol"
        let held = holdings.first { $0.chain == net && ($0.symbol.lowercased() == token.lowercased() || $0.contract.lowercased() == token.lowercased()) }
        let what = "\(amount.map { Fmt.num($0, maxFraction: 9) } ?? "all") \(held?.symbol ?? token)"
        return MoveRoute(title: "Send \(what) to \(entry.name)",
                         footer: "One transfer on \(place?.title ?? net), the token as it is: only this saved address may receive it. Press Confirm.",
                         steps: [
            step(logo, "FROM · \((place?.title ?? net).uppercased())", what, held.map { "held: \(Fmt.num($0.amount, maxFraction: 6)) \($0.symbol)" } ?? "", fill),
            step(logo, "TO · \(entry.label?.uppercased() ?? "SAVED ADDRESS")", entry.name, "\(ends.start) … \(ends.end)", fill),
        ], warning: entry.lastSent == nil ? "First transfer to this address. Sending a small test amount first is the safe habit." : nil)
    }

    private func withdrawRoute(_ asked: Decimal?) -> MoveRoute {
        let free = hl?.withdrawable
        let amount = asked ?? free
        return MoveRoute(title: "Withdraw · \(amount.map { Fmt.num($0) } ?? "all") USDC to Solana",
                         footer: "Signed with the main key — the trading key can’t withdraw. Press Confirm; Cancel or “cancel” drops it.", steps: [
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
            if needGas { steps.append(step("base", "GAS · COMES ALONG", "≈ $0.03 of ETH", "there’s no ETH on Base yet · it comes with the bridge", .base)) }
        } else {
            steps.append(step("base", "ON BASE", "\(Fmt.num(onBase)) USDC", "already there, gas too", .base))
        }
        steps.append(approve("\(Fmt.num(amount)) USDC", for: morpho ? "Morpho" : "Aave", logo: morpho ? "morpho" : "aave", morpho ? .morpho : .aave))
        steps.append(morpho ? step("morpho", "MORPHO · \(MorphoVault.name.uppercased())", "\(Fmt.num(amount)) USDC", apy, .morpho)
                            : step("aave", "AAVE V3 · BASE", "\(Fmt.num(amount)) USDC", apy, .aave))
        return MoveRoute(title: morpho ? "Morpho · deposit \(Fmt.num(amount)) USDC on Base" : "Aave · lend \(Fmt.num(amount)) USDC on Base",
                         footer: (bridging ? "One Solana signature for the bridge, then " : "")
                            + "two on Base: approve exactly \(Fmt.num(amount)) USDC, then \(morpho ? "deposit; the shares come to this wallet only" : "supply"). "
                            + "\(morpho ? "The vault’s asset is" : "Pool and rate are") re-read from Base first. Press Confirm.",
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
            let vault = kaminoVault(s)
            let x = x ?? vault?.tokens ?? (s == "USDC" && kamino > 0 ? kamino : nil)
            return (step("kamino", vault == nil ? "FROM · KAMINO LEND" : "FROM · KAMINO EARN", "\(n(x)) \(s)", vault.map { "\($0.name): \($0.amount ?? "")" } ?? "", .kamino),
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
        case .jupiterDCA(let a, let u, let o, let e):
            let orders = o ?? u.map(WalletCommand.jupiterDCAOrders) ?? 2
            return (step("usdc", "FROM · SOLANA", "\(n(u)) USDC", solUSDC + (solUSDC.isEmpty ? "" : " · ") + "all goes in now", .solana),
                    step(TokenLogo.name(forAsset: a.symbol) ?? "jup", "EVERY \(WalletCommand.everyText(e).uppercased()) · JUPITER DCA",
                         "\(orders) × \(u.map { Fmt.num($0 / Decimal(orders)) } ?? "?") USDC → \(a.symbol)",
                         "Jupiter's keepers buy on-chain, the first now · 0.1% fee · cancel any time", .jupiter))
        case .jupiterDCACancel(let a):
            return (step("jup", "FROM · JUPITER DCA", a.map { "\($0.symbol) orders" } ?? "all orders", "what they haven't spent", .jupiter),
                    step("usdc", "TO · SOLANA", "USDC", "your wallet · the ≈ 0.005 SOL rent too", .solana))
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
                         "on Robinhood Chain · then “move USDG from Robinhood to Solana”", .robinhood))
        case .sell(let a, let x):
            // What is held, so «sell all JUP» shows how much «all» is (the line was empty).
            let held = a.symbol == "SOL" ? solana?.sol
                : solana?.tokens.first { $0.contract == a.mint || (a.mint.isEmpty && $0.symbol.uppercased() == a.symbol.uppercased()) }?.amount
            return (step(TokenLogo.name(forAsset: a.symbol) ?? "usdc", "SELL · JUPITER", "\(n(x)) \(a.symbol)",
                         held.map { "held: \(Fmt.num($0, maxFraction: 6)) \(a.symbol)" } ?? "best route, simulated first", .jupiter),
                    step("usdc", "TO · SOLANA", "USDC", "your wallet", .solana))
        default:
            return nil
        }
    }

    /// A Robinhood Stock Token bought with USDC from Solana: bridge, then Uniswap on Robinhood Chain.
    /// A token's name for people: «AI (0x2E8c…1e18)», with ⚠ before a symbol that imitates another; the contract
    /// shortened until its symbol is known.
    func tokenLabel(_ symbolOrContract: String) -> String {
        guard symbolOrContract.hasPrefix("0x") else { return symbolOrContract }
        let short = "\(symbolOrContract.prefix(6))…\(symbolOrContract.suffix(4))"
        guard let symbol = tokenSymbol(symbolOrContract) else { return short }
        return "\(TokenLookup.suspicious(symbol, contract: symbolOrContract, genuine: Self.genuineContracts) ? "⚠ " : "")\(symbol) (\(short))"
    }

    /// A contract's symbol: the favorite's, else one learned before. An unknown one is looked up once (DexScreener)
    /// and shows as soon as it's found.
    func tokenSymbol(_ contract: String) -> String? {
        let key = contract.lowercased()
        if let s = favoriteToken(contract)?.symbol ?? tokenNames[key] { return s }
        if tokenNamesAsked.insert(key).inserted { Task { await learnTokenName(contract) } }
        return nil
    }

    /// A contract or mint typed after «@» in the chat's field: what DexScreener knows of it, asked once. The user typed it
    /// there to look it up, so it goes out; its ticker is learned for the cards and the chat.
    func lookUpContract(_ address: String) async {
        guard contractLookups[address] == nil else { return }
        try? await Task.sleep(for: .milliseconds(300))   // the field still being typed or pasted into
        guard !Task.isCancelled else { return }
        let found = (try? await TokenLookup.lookup(address)) ?? []
        contractLookups[address] = found
        if let symbol = found.first?.symbol, favoriteToken(address) == nil { tokenNames[address.lowercased()] = symbol }
    }

    func learnTokenName(_ contract: String) async {
        let key = contract.lowercased()
        guard favoriteToken(contract) == nil, tokenNames[key] == nil,
              let symbol = try? await TokenLookup.lookup(contract).first?.symbol else { return }
        tokenNames[key] = symbol
    }

    /// Names every contract in a line before it's written down for good (a chat reply). Waits 3 s at most: a name
    /// found later still shows on the card.
    func learnTokenNames(in text: String) async {
        let contracts = text.matches(of: /0x[0-9a-fA-F]{40}/).map { String($0.0) }
        guard contracts.contains(where: { favoriteToken($0) == nil && tokenNames[$0.lowercased()] == nil }) else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for c in contracts { await self.learnTokenName(c) } }
            group.addTask { try? await Task.sleep(for: .seconds(3)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// The real dollars and wrapped ether where the app moves money: their tickers on any other contract are a fake.
    static let genuineContracts = Set(EVMNetwork.all.map { $0.usdc.lowercased() } + [
        "0x4200000000000000000000000000000000000006",   // WETH · Base
        "0x82af49447d8a07e3bd95bd0d56f35241523fbab1",   // WETH · Arbitrum
        "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",   // WETH · Ethereum
        "0xdac17f958d2ee523a2206206994597c13d831ec7",   // USDT · Ethereum
        "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9",   // USDT · Arbitrum
    ])

    func favoriteToken(_ contract: String) -> FavoriteToken? {
        favoriteTokens.first { $0.address.lowercased() == contract.lowercased() }
    }

    /// Text for the canvas and the chat with every contract in it replaced by its token's name.
    func readable(_ text: String) -> String {
        text.replacing(/0x[0-9a-fA-F]{40}/) { tokenLabel(String($0.0)) }
    }

    /// What the chain waiting behind this card does next («… then buy AI then buy MOO»): each step's own cards but where
    /// its money starts and its approves, marked to come after this move.
    /// `of`: these steps instead of the queue (the step a confirmed chain is about to run).
    func chainSteps(of given: [String]? = nil) -> [ActivityBubble] {
        let queued = [taskQueue.map { ($0.canvas, $0.steps) }, chainAhead.map { ($0.canvas, $0.steps) }].compactMap { $0 }
            .first { $0.0 == canvasID }?.1 ?? []
        let steps = given ?? queued
        guard !steps.isEmpty else { return [] }
        // Where the steps before bring money: a deposit there spends it, so its card draws no bridge from Solana
        // («Ethereum → Arbitrum, then Aave» drew a second bridge, Solana → Arbitrum, that never runs).
        var arrived = Set<String>()
        if case .wallet(let first)? = pendingAction, let to = Self.arrives(first) { arrived.insert(to) }
        return steps.compactMap(WalletCommand.parse).flatMap { c -> [ActivityBubble] in
            defer { if let to = Self.arrives(c) { arrived.insert(to) } }
            let brought = Self.spends(c).map(arrived.contains) ?? false
            switch c {
            // Spread and rebalance have no route of their own: their split is planned when the money before them has landed.
            case .allocate(let asset, let share, let amount, _, _):
                return [ActivityBubble(kind: "step", label: "INTO · BEST RATES", title: amount.map { "\(Fmt.num($0)) \(asset)" } ?? "all free \(asset)",
                                       lines: ["split\twhen the money lands", "max per place\t\(Fmt.pct(share ?? 50))"], status: "then", logo: "usdc", fill: .jupiter)]
            case .rebalance(let share):
                return [ActivityBubble(kind: "step", label: "REBALANCE · BEST RATES", title: "deposits",
                                       lines: ["moves\twhen the money lands", "max per place\t\(Fmt.pct(share ?? 50))"], status: "then", logo: "usdc", fill: .jupiter)]
            // A transfer to a saved address has no route of its own (its board is TransferBoard): one card, so a chain
            // ending in it («move 20 from Base to Solana, then send 20 to Automation») doesn't look like a bare bridge.
            case .sendTo(let name, let amount, let net):
                // The same entry and network prepareTransfer will use when the step runs.
                let entry = savedEntry(name, network: net)
                let network = net.flatMap(AddressCheck.Network.init(rawValue:)) ?? entry?.network ?? .solana
                let ends = entry.map { AddressCheck.ends($0.address) }
                return [ActivityBubble(kind: "step", label: "SEND · \(network.title.uppercased())",
                                       title: "\(Fmt.num(amount)) USDC", lines: ["to \(entry?.name ?? name)"] + (ends.map { ["\($0.start) … \($0.end)"] } ?? []),
                                       status: "then", logo: network.logo, fill: RouteFill(rawValue: network.rawValue) ?? .check)]
            default:
                // Any other step without a route still shows, as its words: a chain never loses a step on the canvas.
                return route(c)?.steps.filter { !$0.label.hasPrefix("FROM") && !$0.label.hasPrefix("APPROVE")
                    && !(brought && ($0.label.hasPrefix("BRIDGE") || $0.label.hasPrefix("GAS"))) }.map { var s = $0; s.status = "then"; return s }
                    ?? [ActivityBubble(kind: "step", label: "THEN", title: readable(c.summary), status: "then", logo: "usdc", fill: .check)]
            }
        }
    }

    /// The network a move delivers USDC to («solana» for Solana); nil for anything else.
    static func arrives(_ c: WalletCommand) -> String? {
        switch c {
        case .bridge(_, let to, _): to == "hyperliquid" ? nil : to
        case .evmToSolana, .baseToSolana, .arbitrumToSolana, .robinhoodToSolana, .withdrawToSolana, .sellNear: "solana"
        case .solanaTo(let to, _): to
        default: nil
        }
    }

    /// The network a step spends USDC on; nil when it spends none.
    static func spends(_ c: WalletCommand) -> String? {
        switch c {
        case .aave(true, _, let n), .morpho(true, _, let n), .buyOn(let n, _, _, _): n
        case .lendDeposit, .kamino(true, _, _), .buy, .hlp(true, _), .allocate(_, _, _, _, from: "solana"), .solanaTo, .jupiterDCA: "solana"
        case .buyStock: "robinhood"
        default: nil
        }
    }

    private func stockRoute(_ symbolOrContract: String, _ asked: Decimal) -> MoveRoute {
        // The three ways as quoted while the card waits (quoteStock): the best names the BUY step, the others are its line.
        let ways = swapQuote.flatMap { q in q.command == .buyStock(symbol: symbolOrContract, usdc: asked) ? q.ways : nil }
        // A contract («купи 0x…»): its name and price from the favorites when it's there.
        let contract = symbolOrContract.hasPrefix("0x")
        let favorite = favoriteTokens.first { $0.address.lowercased() == symbolOrContract.lowercased() }
        let symbol = contract ? tokenSymbol(symbolOrContract) ?? "\(symbolOrContract.prefix(6))…\(symbolOrContract.suffix(4))" : symbolOrContract
        let price = contract ? favorite.flatMap { tokenInfo[$0.id]?.priceUSD } : markets["xyz:\(symbolOrContract)"]?.markPx
        // USDG already on Robinhood Chain pays first (a bridge from Base leaves it there): Solana only brings what's missing,
        // and a few cents short ($1 or 2% at most) isn't worth a bridge: the buy spends what's there (Executor.buyStock).
        let usdg = robinhood?.usdg ?? 0
        let fits = usdg > 0 && usdg < asked && asked - usdg <= max(1, asked / 50)
        let usdc = fits ? usdg : asked, bring = max(0, usdc - usdg)
        // Solana short: the USDC comes straight from the EVM network holding it, as Executor.ensureEVM does.
        let elsewhere = bring > 0 ? solana.flatMap { s in EVMNetwork.source(arrive: bring, onSolana: s.usdc, target: "robinhood", held: { self.usdc(on: $0) }) } : nil
        let from = bring == 0
            ? step("robinhood", "FROM · ROBINHOOD CHAIN", "\(Fmt.num(usdg)) → \(Fmt.num(usdg - usdc)) USDG", fits ? "what's there · the cents short aren't worth a bridge" : "already there · no bridge", .robinhood)
            : elsewhere.map { e in
                step(ModuleNetwork(place: e.net.key)?.logo ?? e.net.key, "FROM · \(e.net.name.uppercased())", "≈ \(Fmt.num(e.send)) USDC",
                     "Solana has only \(Fmt.num(solana?.usdc ?? 0)) · free there: \(Fmt.num(self.usdc(on: e.net.key) ?? 0)) USDC", RouteFill(rawValue: e.net.key) ?? .relay)
            }
            ?? step("sol", "FROM · SOLANA", "\(Fmt.num(bring)) USDC", (usdg > 0 ? "the rest of \(Fmt.num(usdc)) is on Robinhood · " : "")
                   + (solana.map { "free: \(Fmt.num($0.usdc)) USDC" } ?? ""), .solana)
        return MoveRoute(title: "Buy \(symbol) · \(Fmt.num(usdc)) USDC on Robinhood Chain",
                         footer: (bring == 0 ? "Two signatures on Robinhood Chain with the USDG already there: "
                                  : elsewhere.map { "An exact approve and Relay's deposit on \($0.net.name), then two on Robinhood Chain: " } ?? "One Solana signature for the bridge, then two on Robinhood Chain: ")
                            + "an exact USDG approve and the swap the best way takes (Uniswap v4, v3 or Relay’s swap, compared in the step), which may only pay this wallet. "
                            + (contract ? "The token is taken by its contract: it must trade on Robinhood Chain with $50k+ of liquidity, and the price must sit within 5% of DexScreener's."
                                        : "The token is Robinhood's registered contract, checked on-chain, and the price must sit within Robinhood's own quote.")
                            + " Press Confirm.", steps: [
            from,
        ] + (bring == 0 ? [] : [step("relay", "BRIDGE · RELAY", elsewhere.map { "\($0.net.name) → Robinhood" } ?? "USDG → Robinhood",
                                     (elsewhere == nil ? "" : "straight, no stop on Solana · ") + "+ ETH for gas when there's none", .relay)]) + [
            approve("≈ \(Fmt.num(usdc)) USDG", for: ways?.first?.way == "relay" ? "Relay" : ways?.first?.way == "v4" ? "Permit2, then Uniswap v4" : "Uniswap", logo: ways?.first?.way == "relay" ? "relay" : "uni",
                    .robinhood, line: ways?.first?.way == "v4" ? "exactly this · Permit2 lets Uniswap v4 take it for 30 min" : nil),
            stockBuyStep(symbol, ways, fallback: price.map { "≈ \(Fmt.num(usdc / $0, maxFraction: 2)) \(symbol) worth ≈ \(Fmt.usd(usdc)) · 1 \(symbol) = \(tokenPrice($0))" } ?? "at the pool price"),
        ], warning: contract ? "A token by its contract is anyone's coin: its price can halve in a day and nobody vouches for it. Put in only what you can lose."
                             : "Robinhood Stock Tokens give economic exposure, not the shares, and aren’t offered to US persons or in Canada, the UK and Switzerland.")
    }

    /// A token on an EVM network: bought with the USDC already there (or brought from the network `from` names), else
    /// with USDC from Solana; sold back to Solana, or for USDC that stays there (`keep`). Solana's way (Relay's swap, or
    /// Relay's bridge and Uniswap) is chosen when it runs, by what leaves more after gas.
    private func swapRoute(_ place: String, _ token: String, usdc: Decimal?, sell: Decimal?, from: String? = nil, keep: Bool = false) -> MoveRoute {
        let name = WalletCommand.placeName(place)
        let fill = RouteFill(rawValue: place) ?? .check
        let label = token.hasPrefix("0x") ? tokenSymbol(token) ?? "\(token.prefix(6))…\(token.suffix(4))" : token.uppercased()
        let logo = ModuleNetwork(place: place)?.logo ?? place
        let command: WalletCommand = usdc != nil ? .buyOn(place, token: token, usdc: usdc, from: from) : .sellOn(place, token: token, amount: sell, keep: keep)
        // On the network itself, as the executor decides (Executor.buyHere): its quote says so; before it lands, the balances.
        let quoted = swapQuote.flatMap { q in q.command == command ? q.ways : nil }
        // Solana short and the network without the USDC: it comes straight from the EVM network holding it, as Executor.buyOn
        // decides (EVMNetwork.source) — the card said «from Solana» while Base paid.
        let auto = usdc.flatMap { u in
            from == nil && routeWays[Self.wayKey(place, token)] == nil && (self.usdc(on: place) ?? 0) < u
                ? solana.flatMap { s in EVMNetwork.source(arrive: u, onSolana: s.usdc, target: place, held: { self.usdc(on: $0) })?.net.key } : nil
        }
        let src = (from ?? auto).flatMap { $0 == "solana" || $0 == place ? nil : $0 }
        // A source the user named is the card's, never Solana's ways: if it can't pay, the move is refused, not swapped.
        let here = keep || ((from ?? auto) != nil && (from ?? auto) != "solana") || (usdc.map { u in quoted?.first.map { $0.way == "here" }
            ?? (from != "solana" && (self.usdc(on: place) ?? 0) >= u) } ?? false)
        if here {
            let gets = quoted?.first { $0.way == "here" }?.gets
            let moving = usdc.map { "\(Fmt.num($0)) USDC" } ?? "\(sell.map { Fmt.num($0, maxFraction: 8) } ?? "all") \(label)"
            let start: [ActivityBubble] = if let src {
                [step(ModuleNetwork(place: src)?.logo ?? src, "FROM · \(WalletCommand.placeName(src).uppercased())", moving,
                      self.usdc(on: src).map { "free there: \(Fmt.num($0)) USDC" } ?? "USDC there", RouteFill(rawValue: src) ?? .relay),
                 step("relay", "BRIDGE · RELAY", "USDC → \(name)", "a few seconds · no stop on Solana", .relay)]
            } else if let u = usdc, let have = self.usdc(on: place) {
                [step(logo, "FROM · \(name.uppercased())", "\(Fmt.num(have)) → \(Fmt.num(max(0, have - u))) USDC", "already there · no bridge", fill)]
            } else {
                [step(logo, "FROM · \(name.uppercased())", moving, usdc == nil ? "on \(name)" : "already there · no bridge", fill)]
            }
            let footer = (src.map { "First Relay moves the USDC from \(WalletCommand.placeName($0)) to \(name): an exact approve and its deposit. Then two" } ?? "Two")
                + " \(name) transactions: an exact approve and the Uniswap swap, which may only pay this wallet"
                + (usdc == nil ? "; the USDC stays on \(name)." : ".") + " Press Confirm."
            if let usdc {
                return MoveRoute(title: "Buy \(label) · \(Fmt.num(usdc)) USDC on \(name)", footer: footer, steps: start + [
                    approve("\(Fmt.num(usdc)) USDC", for: "Uniswap", logo: "uni", fill, line: src == nil ? nil : "what arrives · only Uniswap may take it"),
                    step(logo, "BUY · UNISWAP ON \(name.uppercased())", label, gets.map { "≈ \($0)" } ?? "at the pool price", fill),
                ], warning: token.hasPrefix("0x") ? "A token by its contract is anyone’s coin: its price can halve in a day and nobody vouches for it. Put in only what you can lose." : nil)
            }
            return MoveRoute(title: "Sell \(sell.map { Fmt.num($0, maxFraction: 8) } ?? "all") \(label) on \(name) → USDC on \(name)", footer: footer, steps: start + [
                approve(moving, for: "Uniswap", logo: "uni", fill),
                step("usdc", "TO · USDC ON \(name.uppercased())", gets.map { "≈ \($0)" } ?? "USDC", "stays on \(name) · your own address ✓", fill),
            ])
        }
        // The way picked in the step's details, else the one that leaves more now (quoted while the card waits).
        let way = switch routeWays[Self.wayKey(place, token)] {
        case "relay": step("relay", "RELAY SWAP", "one step", usdc != nil ? "Relay swaps on the way · one Solana signature" : "Relay swaps it back to USDC on Solana", .relay)
        case "uniswap": step("relay", "RELAY + UNISWAP", usdc != nil ? "bridge, then Uniswap" : "Uniswap, then bridge",
                             usdc != nil ? "USDC to \(name), then Uniswap with an exact approve" : "Uniswap on \(name), then Relay's bridge to Solana", .relay)
        default: bestWay(swapQuote.flatMap { q in q.command == command ? q.ways : nil })
        }
        // Relay + Uniswap approves exactly what it swaps: shown once that's the way (picked, or leaving more now).
        let viaUniswap = (routeWays[Self.wayKey(place, token)] ?? swapQuote.flatMap { q in q.command == command ? q.ways.first?.way : nil }) == "uniswap"
        let footer = "Relay’s swap is one Solana signature; the other way bridges USDC over Relay and swaps on Uniswap with an exact approve, the swap paying only this wallet. "
            + (token.hasPrefix("0x") ? "A token by its contract must trade on \(name) with $50k+ of liquidity. " : "The ticker is taken from Uniswap’s token list, its contract checked on-chain. ")
            + "Press Confirm."
        if let usdc {
            return MoveRoute(title: "Buy \(label) · \(Fmt.num(usdc)) USDC on \(name)", footer: footer, steps: [
                step("sol", "FROM · SOLANA", "\(Fmt.num(usdc)) USDC", solana.map { "free: \(Fmt.num($0.usdc)) USDC" } ?? "", .solana),
                way,
            ] + (viaUniswap ? [approve("≈ \(Fmt.num(usdc)) USDC", for: "Uniswap", logo: "uni", fill, line: "exactly what arrives · only Uniswap may take it")] : []) + [
                step(logo, "BUY · ON \(name.uppercased())", label, "at the best price found", fill),
            ], warning: token.hasPrefix("0x") ? "A token by its contract is anyone’s coin: its price can halve in a day and nobody vouches for it. Put in only what you can lose." : nil)
        }
        return MoveRoute(title: "Sell \(sell.map { Fmt.num($0, maxFraction: 8) } ?? "all") \(label) on \(name) → Solana", footer: footer, steps: [
            step(logo, "FROM · \(name.uppercased())", "\(sell.map { Fmt.num($0, maxFraction: 8) } ?? "all") \(label)", "\(EVMNetwork.named(place)?.gasCoin ?? "ETH") for gas comes along when there’s none", fill),
        ] + (viaUniswap ? [approve("\(sell.map { Fmt.num($0, maxFraction: 8) } ?? "all") \(label)", for: "Uniswap", logo: "uni", fill)] : []) + [
            way,
            step("sol", "TO · SOLANA", "USDC", "your wallet", .solana),
        ])
    }

    /// A spot order on Hyperliquid: the spot USDC (topped up from perp when short), the IOC order within 1% of the mid, what lands.
    private func hlSpotRoute(_ symbol: String, usdc: Decimal?, sell: Decimal?) -> MoveRoute {
        let logo = TokenLogo.name(forAsset: symbol) ?? "hyperliquid"
        if let usdc {
            return MoveRoute(title: "Buy \(symbol) · \(Fmt.num(usdc)) USDC on Hyperliquid spot",
                             footer: "One spot order on Hyperliquid's book, IOC within 1% of the mid; the spot USDC comes from your perp balance first when short (one more signature of yours). The exchange takes orders from 10 USDC. Press Confirm.",
                             steps: [step("hyperliquid", "FROM · HYPERLIQUID", "\(Fmt.num(usdc)) USDC", "spot balance · perp tops it up when short", .hyperliquid),
                                     step(logo, "BUY · SPOT ORDER", symbol, "IOC · at most 1% over the mid", .hyperliquid),
                                     step(logo, "TO · SPOT BALANCE", symbol, "on Hyperliquid, yours ✓", .hyperliquid)])
        }
        return MoveRoute(title: "Sell \(sell.map { Fmt.num($0, maxFraction: 8) } ?? "all") \(symbol) on Hyperliquid spot",
                         footer: "One spot order on Hyperliquid's book, IOC within 1% of the mid; the USDC lands on your spot balance. The exchange takes orders from 10 USDC. Press Confirm.",
                         steps: [step(logo, "FROM · SPOT BALANCE", "\(sell.map { Fmt.num($0, maxFraction: 8) } ?? "all") \(symbol)", "on Hyperliquid", .hyperliquid),
                                 step(logo, "SELL · SPOT ORDER", "→ USDC", "IOC · at most 1% under the mid", .hyperliquid),
                                 step("usdc", "TO · SPOT USDC", "USDC", "on Hyperliquid, yours ✓", .hyperliquid)])
    }

    /// One approval set to zero: the token, who may spend it now, and that nothing is spent.
    private func revokeRoute(_ place: String, _ token: String, _ spender: String, _ permit2: Bool) -> MoveRoute {
        let name = WalletCommand.placeName(place), fill = RouteFill(rawValue: place) ?? .check
        let symbol = tokenSymbol(token) ?? "\(token.prefix(6))…\(token.suffix(4))"
        let who = EVMNetwork.named(place).flatMap { Executor.spenderName(spender, chainId: $0.rpc.chainId) } ?? "\(spender.prefix(6))…\(spender.suffix(4))"
        return MoveRoute(title: "Revoke \(who)'s approval of \(symbol) on \(name)",
                         footer: "One \(name) transaction: \(permit2 ? "Permit2's own approve" : "the token's approve") set to zero for \(spender). Nothing is spent and nobody gains a right; only the gas is paid. Press Confirm.",
                         steps: [step(ModuleNetwork(place: place)?.logo ?? place, "TOKEN · \(name.uppercased())", symbol, permit2 ? "through Permit2" : "its own approve", fill),
                                 step("shield", "REVOKE · TO ZERO", who, "\(spender.prefix(6))…\(spender.suffix(4)) can't spend it after", .check)])
    }

    /// «Sweep dust»: the tokens that go, a step each (eight at most, then how many more), each sold for USDC on its own network.
    private func dustRoute(_ under: Decimal?) -> MoveRoute {
        let dust = dustTokens(under: under)
        let total = dust.reduce(Decimal(0)) { $0 + $1.usd }
        var steps = dust.prefix(8).map { d in
            step(ModuleNetwork(place: d.chain)?.logo ?? d.chain, "SELL · \(WalletCommand.placeName(d.chain).uppercased())", d.symbol,
                 "≈ \(Fmt.usd(d.usd)) → USDC there", RouteFill(rawValue: d.chain) ?? .check)
        }
        if dust.count > 8 { steps.append(step("usdc", "AND \(dust.count - 8) MORE", "\(dust.count - 8) tokens", "the same way", .check)) }
        return MoveRoute(title: "Sweep \(dust.count) token\(dust.count == 1 ? "" : "s") ≈ \(Fmt.usd(total)) into USDC",
                         footer: "Each verified token worth $0.20 to \(Fmt.usd(under ?? 5)) on Base, Arbitrum and Polygon: quoted on Uniswap first and sold for USDC on its own network with an exact approve, only when the gas takes less than half of it — the rest stays, said by name. Press Confirm.",
                         steps: steps)
    }

    /// One token for another on an EVM network, straight on Uniswap: what goes in (approved exactly, or the network's coin
    /// itself), the swap with the version and what comes out once quoted (Executor.pairQuote), paying only this wallet.
    private func pairRoute(_ place: String, _ from: String, _ to: String, _ amount: Decimal?) -> MoveRoute {
        let name = WalletCommand.placeName(place)
        let fill = RouteFill(rawValue: place) ?? .check
        let logo = ModuleNetwork(place: place)?.logo ?? place
        func label(_ t: String) -> String { t.hasPrefix("0x") ? tokenSymbol(t) ?? "\(t.prefix(6))…\(t.suffix(4))" : t.uppercased() }
        let coin = EVMNetwork.named(place)?.gasCoin ?? "ETH"
        let coinIn = from.uppercased() == coin, coinOut = to.uppercased() == coin
        let quoted = swapQuote.flatMap { q in q.command == .swapOn(place, from: from, to: to, amount: amount) ? q.ways.first : nil }
        // A token amount as written: 0.0001 ETH read «0 ETH» at two places.
        let moving = "\(amount.map { Fmt.num($0, maxFraction: 8) } ?? "all") \(label(from))"
        var steps = [step(logo, "FROM · \(name.uppercased())", moving, coinIn ? "your \(coin) · its fees stay" : "on \(name)", fill)]
        if !coinIn { steps.append(approve(moving, for: "Uniswap", logo: "uni", fill)) }
        steps.append(step("uni", "SWAP · \((quoted?.way ?? "Uniswap").uppercased()) ON \(name.uppercased())", label(to),
                          quoted.map { "≈ \($0.gets)" } ?? "the best of v2, v3 and v4", fill))
        let footer = "One swap on \(name), no USDC in the middle: the best of Uniswap v2, v3 and v4, at most 0.5–3% under its quote by the price impact, paying only this wallet."
            + (coinIn ? " \(coin) goes in as itself into a v4 pool of it, else wrapped into W\(coin) first (one more transaction)." : " An exact approve first.")
            + (coinOut ? " \(coin) comes out as itself, or is unwrapped after." : "") + " Press Confirm."
        return MoveRoute(title: "Swap \(moving) → \(label(to)) on \(name)", footer: footer, steps: steps,
                         warning: to.hasPrefix("0x") ? "A token by its contract is anyone’s coin: its price can halve in a day and nobody vouches for it. Put in only what you can lose." : nil)
    }

    /// A token on one network for one on another through Relay: what goes out, an exact approve for a token on an EVM
    /// network, Relay's swap across with what arrives once quoted (Executor.crossQuoteText), and the wallet's own address
    /// where it lands.
    private func crossRoute(_ a: String, _ from: String, _ b: String, _ to: String, _ amount: Decimal?) -> MoveRoute {
        let fromName = WalletCommand.placeName(from), toName = WalletCommand.placeName(to)
        func fill(_ p: String) -> RouteFill { RouteFill(rawValue: p) ?? .check }
        func logo(_ p: String) -> String { ModuleNetwork(place: p)?.logo ?? p }
        func label(_ t: String) -> String { t.hasPrefix("0x") ? tokenSymbol(t) ?? "\(t.prefix(6))…\(t.suffix(4))" : t.uppercased() }
        let coinIn = a.uppercased() == (from == "solana" ? "SOL" : EVMNetwork.named(from)?.gasCoin ?? "ETH")
        let quote = swapQuote.flatMap { $0.command == .crossSwap(from: a, on: from, to: b, at: to, amount: amount) ? $0.ways : nil }
        let moving = "\(amount.map { Fmt.num($0, maxFraction: 8) } ?? "all") \(label(a))"
        var steps = [step(logo(from), "FROM · \(fromName.uppercased())", moving, coinIn ? "your \(label(a)) · its fees stay" : "on \(fromName)", fill(from))]
        if from != "solana", !coinIn { steps.append(approve(moving, for: "Relay", logo: "relay", fill(from))) }
        steps.append(step("relay", "SWAP ACROSS · RELAY", label(b),
                          quote.map { $0.first.map { "≈ \($0.gets) · \($0.way)" } ?? "no quote now · asked again every 30 s" } ?? "quoting…", .relay))
        steps.append(step(logo(to), "TO · \(toName.uppercased())", label(b), "your own address there", fill(to)))
        let footer = "One signature on \(fromName): Relay's solver swaps on the way and pays \(label(b)) to your own address on \(toName), usually within seconds. "
            + "If more than 3% (or 15 cents) of the value would be lost, nothing is signed."
            + (from != "solana" && coinIn ? " The \(label(a)) goes to Relay's depository: Touch ID allows that address the first time." : "")
            + (from != "solana" && !coinIn ? " An exact approve to Relay comes first, in the same transaction where the network allows." : "")
            + " Press Confirm."
        return MoveRoute(title: "Swap \(moving) on \(fromName) → \(label(b)) on \(toName)", footer: footer, steps: steps)
    }

    /// A coin to a saved address on a network only NEAR Intents reaches: the USDC it costs and where from (once quoted),
    /// 1Click's swap for exactly that much, and the saved address.
    private func acrossRoute(_ command: WalletCommand, _ r: (entry: SavedAddress, symbol: String, address: String), _ amount: Decimal?) -> MoveRoute {
        let ends = AddressCheck.ends(r.entry.address), title = r.entry.network.title
        let quote = swapQuote.flatMap { $0.command == command ? $0.ways : nil }
        let what = "\(amount.map { Fmt.num($0, maxFraction: 9) } ?? "?") \(r.symbol)"
        let from = quote?.first?.way ?? "Solana"
        let steps = [
            step(from == "Solana" ? "sol" : ModuleNetwork(place: from.lowercased())?.logo ?? "usdc", "FROM · \(from.uppercased())", "USDC",
                 quote.map { $0.first.map { "\($0.gets) · the rest comes back" } ?? "no quote now · asked again every 30 s" } ?? "quoting…", RouteFill(rawValue: from.lowercased()) ?? .solana),
            step("near", "SWAP · NEAR INTENTS", what, "exactly this much arrives", .check),
            step(r.entry.network.logo, "TO · \(r.entry.label?.uppercased() ?? "SAVED ADDRESS")", r.entry.name, "\(ends.start) … \(ends.end) · \(title)", .check),
        ]
        let warning = r.entry.network == .xrp && r.entry.memo.isEmpty
            ? "An exchange's XRP address needs its destination tag: without it the exchange can't credit you. Save the tag as this address's memo first."
            : r.entry.lastSent == nil ? "First transfer to this address. Sending a small test amount first is the safe habit." : nil
        return MoveRoute(title: "Send \(what) to \(r.entry.name)",
                         footer: "NEAR Intents' 1Click turns USDC into \(r.symbol) on \(title) and pays this saved address exactly \(what); what's left of the USDC comes back. "
                            + "Its deposit address is fresh: Touch ID allows it before anything is sent. Press Confirm.",
                         steps: steps, warning: warning)
    }

    static func wayName(_ way: String) -> String { way == "relay" ? "Relay swap" : "Relay + Uniswap" }
    static func stockWayName(_ way: String) -> String { way == "v4" ? "Uniswap v4" : way == "v3" ? "Uniswap v3" : "Relay swap" }

    /// The BUY step of a Robinhood Chain buy: the way that gives the most now, marked best, and what the others give.
    private func stockBuyStep(_ symbol: String, _ ways: [(way: String, gets: String, worth: Decimal)]?, fallback: String) -> ActivityBubble {
        guard let ways else { return step("robinhood", "BUY · COMPARING", symbol, "Uniswap v4, v3 and Relay’s swap…", .robinhood) }
        guard let best = ways.first else { return step("robinhood", "BUY · UNISWAP", symbol, fallback, .robinhood) }
        let others = ways.dropFirst().map { "\(Self.stockWayName($0.way)) ≈ \($0.gets)" }
        return step(best.way == "relay" ? "relay" : "uni", "BUY · \(Self.stockWayName(best.way).uppercased()) · BEST", symbol,
                    "≈ \(best.gets)" + (others.isEmpty ? " · the only way that quotes it" : " · " + others.joined(separator: " · ")), .robinhood)
    }

    /// The way that leaves more right now, what it gives and by how much it beats the other; `ways` is nil while both
    /// are being quoted.
    private func bestWay(_ ways: [(way: String, gets: String, worth: Decimal)]?) -> ActivityBubble {
        guard let ways else { return step("relay", "RELAY OR UNISWAP · COMPARING", "comparing…", "Relay swap vs Relay + Uniswap", .relay) }
        guard let best = ways.first else { return step("relay", "RELAY OR UNISWAP · COMPARING", "no quote now", "asking again every 30 s", .relay) }
        let other = Self.wayName(best.way == "relay" ? "uniswap" : "relay")
        let margin = ways.dropFirst().first.map { best.worth - $0.worth }
        let line = switch margin {
        case nil: "\(other) doesn't quote it now"
        case let m? where m < Decimal(string: "0.01")!: "about the same as \(other)"
        case let m?: "\(Fmt.usd(m)) more than \(other)"
        }
        return step("relay", "\(Self.wayName(best.way).uppercased()) · BEST NOW", "≈ \(best.gets)", line, .relay)
    }

    /// Quotes both ways of a Base or Arbitrum trade while its card waits for Confirm, again every 30 s, so the card
    /// shows the one that leaves more now. Nothing is signed; the executor quotes once more right before signing.
    func quoteSwap(_ command: WalletCommand) async {
        let (place, token, usdc, sell): (String, String, Decimal?, Decimal?)
        switch command {
        case .buyOn(let p, let t, let u?, _): (place, token, usdc, sell) = (p, t, u, nil)
        case .sellOn(let p, let t, let a, _): (place, token, usdc, sell) = (p, t, nil, a)
        case .buyStock(let s, let u?): await quoteStock(command, s, usdc: u, sell: nil); return
        case .sellStock(let s, let a): await quoteStock(command, s, usdc: nil, sell: a); return
        case .swapOn(let p, let a, let b, let x): await quotePair(command, p, a, b, x); return
        case .crossSwap(let a, let from, let b, let to, let x): await quoteCross(command, a, from, b, to, x); return
        case .sendToken(let name, let token, let x?, let network):
            if let r = try? acrossRecipient(name, token: token, network: network) { await quoteAcross(command, r.symbol, x, r.entry.network.rawValue, r.address) }
            return
        default: return
        }
        var from: String?, keep = false
        if case .buyOn(_, _, _, let f) = command { from = f }
        if case .sellOn(_, _, _, let k) = command { keep = k }
        guard let wallet = previewWallet, let net = EVMNetwork.named(place) else { return }
        while !Task.isCancelled {
            let ways = try? await executor(wallet).swapQuotes(net, token, usdc: usdc, sell: sell, from: from, keep: keep)
            guard !Task.isCancelled else { return }
            // A failed quote keeps the last good one.
            if let ways, !ways.isEmpty { swapQuote = (command, ways) }
            else if swapQuote?.command != command { swapQuote = (command, []) }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    /// A token-for-token swap: Uniswap's best route quoted while the card waits, again every 30 s; nothing is signed.
    private func quotePair(_ command: WalletCommand, _ place: String, _ from: String, _ to: String, _ amount: Decimal?) async {
        guard let wallet = previewWallet, let net = EVMNetwork.named(place) else { return }
        while !Task.isCancelled {
            let q = try? await executor(wallet).pairQuote(net, from: from, to: to, amount: amount)
            guard !Task.isCancelled else { return }
            if let q { swapQuote = (command, [(q.way, q.gets, 0)]) }
            else if swapQuote?.command != command { swapQuote = (command, []) }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    /// A coin to an address on a network only NEAR Intents reaches: what it costs in USDC and where that comes from, again
    /// every 30 s.
    private func quoteAcross(_ command: WalletCommand, _ symbol: String, _ amount: Decimal, _ network: String, _ address: String) async {
        guard let wallet = previewWallet else { return }
        while !Task.isCancelled {
            let q = try? await executor(wallet).acrossQuote(symbol, amount: amount, network: network, to: address)
            guard !Task.isCancelled else { return }
            if let q {
                // What it's worth there, and what 1Click and the network keep: a small BTC send loses a fifth to fees.
                let cost = Decimal(string: q.quote.amountInFormatted) ?? 0, worth = q.quote.amountOutUSD
                let fees = worth.map { cost - $0 }.map { $0 > 0 ? " · fees ≈ \(Fmt.usd($0)) (\(Fmt.num($0 / cost * 100, maxFraction: 0))%)" : "" } ?? ""
                let time = q.quote.timeEstimate.map { $0 >= 120 ? " · ≈ \($0 / 60) min" : " · ≈ \($0) s" } ?? ""
                swapQuote = (command, [(q.source?.name ?? "Solana", "≈ \(Fmt.num(cost)) USDC for \(worth.map(Fmt.usd) ?? "?") of it\(fees)\(time)", 0)])
            }
            else if swapQuote?.command != command { swapQuote = (command, []) }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    /// A swap between networks: Relay's quote, again every 30 s.
    private func quoteCross(_ command: WalletCommand, _ a: String, _ from: String, _ b: String, _ to: String, _ amount: Decimal?) async {
        guard let wallet = previewWallet else { return }
        while !Task.isCancelled {
            let q = try? await executor(wallet).crossQuoteText(a, on: from, for: b, on: to, amount: amount)
            guard !Task.isCancelled else { return }
            if let q { swapQuote = (command, [(q.way, q.gets, 0)]) }
            else if swapQuote?.command != command { swapQuote = (command, []) }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    /// A Robinhood Chain buy or sale: Uniswap v4, v3 and Relay's swap quoted, again every 30 s, the best first.
    private func quoteStock(_ command: WalletCommand, _ symbol: String, usdc: Decimal?, sell: Decimal?) async {
        guard let wallet = previewWallet else { return }
        while !Task.isCancelled {
            let ways = try? await executor(wallet).stockQuotes(symbol, usdc: usdc, sell: sell)
            guard !Task.isCancelled else { return }
            if let ways, !ways.isEmpty { swapQuote = (command, ways) }
            else if swapQuote?.command != command { swapQuote = (command, []) }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    /// What a deposit or a buy spends and where, and how much of it that place lacks; nil when it has it, or the move
    /// brings its own money (a source the user named).
    private func fundingNeed(_ c: WalletCommand) -> (short: Decimal, net: String)? {
        let amount: Decimal, net: String
        switch c {
        case .aave(true, let a?, let n), .morpho(true, let a?, let n), .buyOn(let n, _, let a?, nil): (amount, net) = (a, n)
        case .buyStock(_, let a?): (amount, net) = (a, "robinhood")
        case .lendDeposit("USDC", let a?), .kamino(true, "USDC", let a?), .buy(_, let a?), .jupiterDCA(_, let a?, _, _): (amount, net) = (a, "solana")
        default: return nil
        }
        let short = amount - (usdc(on: net) ?? 0)
        return short > 0 ? (short, net) : nil
    }

    /// One place pays all of it inside the move itself, one card: Solana for a move elsewhere, or one EVM network sending
    /// straight (EVMNetwork.source, as Executor.ensureEVM and buyOn sign it).
    private func oneSource(_ short: Decimal, _ net: String) -> Bool {
        net != "solana" && ((solana?.usdc ?? 0) >= short + Decimal(string: "0.1")!
            || EVMNetwork.source(arrive: short, onSolana: solana?.usdc ?? 0, target: net, held: { self.usdc(on: $0) }) != nil)
    }

    private func fundingLegs(_ short: Decimal, _ net: String) -> [String]? {
        let evm = EVMNetwork.searched.map { FundingPlan.Place(key: $0.key, name: $0.name, usdc: usdc(on: $0.key) ?? 0) }
        return FundingPlan.legs(short: short, target: net, targetName: WalletCommand.placeName(net), solana: solana?.usdc ?? 0, evm: evm,
                                hyperliquid: hl?.withdrawable ?? 0, near: near, nearPrice: markets["NEAR"]?.markPx)
    }

    /// A deposit or a buy whose network hasn't the USDC, the source left unsaid, as steps: the portfolio's free money brought
    /// there first — Solana, the EVM networks (Ethereum last), Hyperliquid's withdrawable, NEAR sold — one leg a place
    /// (FundingPlan), then the move. nil when the network has it, one place pays all of it inside the move (one card), or
    /// all of it together isn't enough (fundingShortfall says so).
    func fundedFromElsewhere(_ c: WalletCommand) -> [String]? {
        // The move is run again from its words: only a command that reads back the same (not a token by its mint).
        guard let (short, net) = fundingNeed(c), WalletCommand.parse(c.summary) == c, !oneSource(short, net),
              let legs = fundingLegs(short, net), !legs.isEmpty else { return nil }
        return legs + [c.summary]
    }

    /// All the wallet's free money together can't pay the move: said before a card that would fail.
    func fundingShortfall(_ c: WalletCommand) -> String? {
        guard let (short, net) = fundingNeed(c), !oneSource(short, net), fundingLegs(short, net) == nil else { return nil }
        var free: [(String, Decimal)] = [("Solana", solana?.usdc ?? 0)]
        free += EVMNetwork.searched.compactMap { n in usdc(on: n.key).flatMap { $0 > 0 ? (n.name, $0) : nil } }
        free.append(("Hyperliquid", hl?.withdrawable ?? 0))
        if let price = markets["NEAR"]?.markPx, near > 0 { free.append(("NEAR", near * price)) }
        let listed = free.filter { $0.1 >= Decimal(string: "0.01")! }.map { "\($0.0) \(Fmt.usd($0.1))" }.joined(separator: ", ")
        return say("This needs \(Fmt.num(short)) USDC more on \(WalletCommand.placeName(net)), and all the free money together isn't enough: \(listed). Top up, or say a smaller amount.",
                   "Нужно ещё \(Fmt.num(short)) USDC на \(WalletCommand.placeName(net)), а всех свободных денег не хватает: \(listed). Пополни или назови сумму меньше.")
    }

    /// USDC free at a place: Solana, Hyperliquid's withdrawable, each EVM network (Ethereum and Polygon from the tokens read).
    func usdc(on place: String) -> Decimal? {
        switch place {
        case "solana": solana?.usdc
        case "base": base?.usdc
        case "ethereum": heldUSDC("ethereum", EVMRPC.ethereumUSDC)
        case "polygon": heldUSDC("polygon", EVMRPC.polygonUSDC)
        case "arbitrum": arbitrumUSDC
        case "robinhood": robinhood?.usdg
        case "tempo": tempoUSDC
        case "hyperliquid": hl?.withdrawable
        default: nil
        }
    }

    /// USDC read with the other networks' tokens; nil until they've been read.
    func heldUSDC(_ chain: String, _ contract: String) -> Decimal? {
        otherTokens.first { $0.chain == chain && $0.contract == contract }?.amount ?? (otherTokens.isEmpty ? nil : 0)
    }

    /// Gas for a network: Solana's USDC → Relay → the network's own coin at our address (half a dollar of USDC comes along).
    private func gasRoute(_ place: String, _ usd: Decimal) -> MoveRoute {
        let name = WalletCommand.placeName(place), coin = place == "polygon" ? "POL" : "ETH"
        let fill: RouteFill = ["base": .base, "arbitrum": .arbitrum, "robinhood": .robinhood][place] ?? .relay
        return MoveRoute(title: "Gas · \(Fmt.usd(usd)) of \(coin) on \(name)",
                         footer: "One Solana signature for the Relay bridge: \(Fmt.usd(usd)) of \(coin) and half a dollar of USDC arrive at your own address on \(name). "
                            + "When Solana is short, Relay swaps \(name)'s own USDC for it there. Press Confirm.",
                         steps: [
            step("sol", "FROM · SOLANA", "\(Fmt.num(usd + Decimal(string: "0.58")!)) USDC", solana.map { "free: \(Fmt.num($0.usdc)) USDC" } ?? "", .solana),
            step("relay", "BRIDGE · RELAY", "\(Fmt.usd(usd)) of \(coin)", "+ 0.5 USDC along · a few seconds", .relay),
            step(ModuleNetwork(place: place)?.logo ?? "eth", "GAS · \(name.uppercased())", "≈ \(Fmt.usd(usd)) of \(coin)", "for the fees of the next moves there", fill),
        ])
    }

    /// One EVM network → Relay → another, both our own address: no stop on Solana.
    private func bridgeRoute(_ from: String, _ to: String, _ amount: Decimal?) -> MoveRoute {
        let a = WalletCommand.placeName(from), b = WalletCommand.placeName(to), stable = to == "robinhood" ? "USDG" : "USDC"
        let have = usdc(on: from), moving = amount.map { min($0, have ?? $0) } ?? have
        func fill(_ place: String) -> RouteFill { ["base": .base, "arbitrum": .arbitrum, "robinhood": .robinhood, "tempo": .tempo, "hyperliquid": .hyperliquid][place] ?? .relay }
        let shown = moving.map { Fmt.num($0) } ?? "all"
        return MoveRoute(title: "Move \(shown) USDC · \(a) → \(b)",
                         footer: "Two \(a) transactions: an exact approve and Relay's deposit, checked field by field before signing; "
                            + "it pays only your own address on \(b). Press Confirm.",
                         steps: [
            step(ModuleNetwork(place: from)?.logo ?? "eth", "FROM · \(a.uppercased())",
                 have.map { h in "\(Fmt.num(h)) → \(Fmt.num(max(0, h - (moving ?? h))))" } ?? "\(shown) USDC", "USDC on \(a)", fill(from)),
            step("relay", "BRIDGE · RELAY", "\(shown) USDC", "≈ $0.03 · a few seconds · no stop on Solana", .relay),
            step(ModuleNetwork(place: to)?.logo ?? "eth", "TO · \(b.uppercased())",
                 usdc(on: to).map { "\(Fmt.num($0)) → \(Fmt.num($0 + (moving ?? 0))) \(stable)" } ?? "\(shown) \(stable)", "your own address ✓", fill(to)),
        ])
    }

    /// Solana → Relay → our own address on Base, Arbitrum or Robinhood Chain.
    private func outRoute(to place: String, amount: Decimal) -> MoveRoute {
        let name = WalletCommand.placeName(place)
        let stable = place == "robinhood" ? "USDG" : "USDC"
        let there = place == "base" ? base?.usdc : place == "arbitrum" ? arbitrumUSDC : place == "tempo" ? tempoUSDC : robinhood?.usdg
        let fill: RouteFill = place == "base" ? .base : place == "arbitrum" ? .arbitrum : place == "tempo" ? .tempo : .robinhood
        return MoveRoute(title: "Move \(Fmt.num(amount)) USDC · Solana → \(name)",
                         footer: "One Solana signature for the Relay bridge, checked and simulated before it’s signed; it pays only your own address on \(name). Press Confirm.",
                         steps: [
            step("sol", "FROM · SOLANA", solana.map { "\(Fmt.num($0.usdc)) → \(Fmt.num(max(0, $0.usdc - amount)))" } ?? "\(Fmt.num(amount)) USDC", "USDC on Solana", .solana),
            step("relay", "BRIDGE · RELAY", "\(Fmt.num(amount)) USDC", place == "tempo" ? "a few seconds · fees there come out of the USDC" : "a few seconds · + ETH for gas when there's none", .relay),
            step(ModuleNetwork(place: place)?.logo ?? place, "TO · \(name.uppercased())", there.map { "\(Fmt.num($0)) → \(Fmt.num($0 + amount)) \(stable)" } ?? "\(Fmt.num(amount)) \(stable)",
                 "your own address ✓", fill),
        ])
    }

    /// Aave or Morpho on a network other than Base: USDC and gas already there are used, Solana brings only what's
    /// missing (ensureEVM); the executor checks everything before signing.
    private func lendingRoute(_ amount: Decimal, morpho: Bool, network: String) -> MoveRoute {
        let name = WalletCommand.placeName(network), coin = network == "polygon" ? "POL" : "ETH"
        let protocolName = morpho ? "Morpho" : "Aave"
        let have = usdc(on: network) ?? 0, short = max(0, amount - have)
        let gas = otherTokens.first { $0.chain == network && $0.native }?.amount ?? 0
        let needGas = gas < EVMNetwork.named(network).map { Decimal($0.gasFloor) / 1_000_000_000_000_000_000 } ?? 0
        let from = short > 0 || needGas
            ? [step("sol", "FROM · SOLANA", "\(Fmt.num(max(short, Decimal(string: "0.5")!))) USDC",
                    (have > 0 ? "\(Fmt.num(have)) already on \(name) · " : "") + (solana.map { "free: \(Fmt.num($0.usdc)) USDC" } ?? ""), .solana),
               step("relay", "BRIDGE · RELAY", "USDC → \(name)", needGas ? "+ \(coin) for gas · ≈ 2 s" : "≈ 2 s", .relay)]
            : [step(ModuleNetwork(place: network)?.logo ?? "eth", "ON \(name.uppercased())", "\(Fmt.num(have)) USDC", "already there, gas too", RouteFill(rawValue: network) ?? .relay)]
        return MoveRoute(title: "\(protocolName) · \(morpho ? "deposit" : "lend") \(Fmt.num(amount)) USDC on \(name)",
                         footer: (from.count > 1 ? "What's missing on \(name) comes from Solana over Relay, with \(coin) for gas when there's none; then two" : "Two")
                            + " \(name) transactions: approve exactly \(Fmt.num(amount)) USDC, then \(morpho ? "deposit; the shares come to this wallet only" : "supply"). "
                            + "\(morpho ? "The vault's asset is" : "Pool and aToken are") re-read from \(name) first"
                            + (network == "ethereum" ? "; Ethereum's gas changes by the hour (cents to dollars): ask the chat «сколько газа?» for today's" : "") + ". Press Confirm.",
                         steps: from + [
            approve("\(Fmt.num(amount)) USDC", for: protocolName, logo: morpho ? "morpho" : "aave", morpho ? .morpho : .aave),
            morpho ? step("morpho", "MORPHO · \(name.uppercased())", "\(Fmt.num(amount)) USDC", "rate from the vault", .morpho)
                   : step("aave", "AAVE V3 · \(name.uppercased())", "\(Fmt.num(amount)) USDC", "rate from the pool", .aave),
        ])
    }

    private func backRoute(from place: String, amount: Decimal?, network: String = "base") -> MoveRoute {
        if network != "base" {
            let name = WalletCommand.placeName(network), lending = place == "aave" || place == "morpho"
            let what = place == "aave" ? "Aave" : "Morpho", held = lending ? nil : usdc(on: network)
            let moving = (amount.map { min($0, held ?? $0) } ?? held).map { Fmt.num($0) } ?? "all"
            let from = lending
                ? step(place, "FROM · \(what.uppercased()) ON \(name.uppercased())", "\(moving) USDC", "with the interest", place == "aave" ? .aave : .morpho)
                : step(ModuleNetwork(place: network)?.logo ?? "eth", "FROM · \(name.uppercased())", "\(moving) USDC",
                       held.map { "free there: \(Fmt.num($0)) USDC" } ?? "free USDC", RouteFill(rawValue: network) ?? .relay)
            return MoveRoute(title: lending ? "\(what) · withdraw \(moving) USDC on \(name) to Solana" : "\(name) · \(moving) USDC to Solana",
                             footer: (lending ? "Three \(name) transactions: withdraw from \(what), an exact approve and Relay’s deposit"
                                              : "Two \(name) transactions: an exact approve and Relay’s deposit")
                                + " — checked field by field before signing. Press Confirm.", steps: [
                from,
                approve("\(moving) USDC", for: "Relay", logo: "relay", .relay),
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
                         footer: (place == "aave" || place == "morpho" ? "Three Base transactions: withdraw from \(place == "aave" ? "Aave" : "Morpho"), an exact approve and Relay’s deposit" : "Two \(chainName) transactions: an exact approve and Relay’s deposit")
                            + " — checked field by field before signing. Press Confirm.", steps: [
            from,
            approve(moving.map { "\(Fmt.num($0)) \(place == "robinhood" ? "USDG" : "USDC")" } ?? "all of it", for: "Relay", logo: "relay", .relay),
            step("relay", "BRIDGE · RELAY", moving.map { "\(Fmt.num($0)) \(place == "robinhood" ? "USDG" : "USDC")" } ?? "—", "≈ $0.02 · a few seconds", .relay),
            step("sol", "TO · SOLANA", solana.map { s in moving.map { "\(Fmt.num(s.usdc)) → \(Fmt.num(s.usdc + $0))" } ?? Fmt.num(s.usdc) } ?? "—",
                 "your own address ✓", .solana),
        ])
    }
}

/// A confirmed move while it runs: the route as it was confirmed, pulsing, and the step ihatecrypto is on. It turns into
/// the executed (or failed) board when the move ends, so the canvas never goes blank in between.
struct RunningBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if let run = ws.runningAction {
            // The chain's steps still to come stay after this move's cards, as they were drawn under Confirm: the
            // route doesn't lose its tail and re-lay its cards smaller or bigger while the move runs.
            let ahead = ws.chainSteps()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(run.title).font(.ui(14, .semibold))
                    StatusChip(text: "in progress", tint: Brand.accentInk)
                    ProgressView().controlSize(.small)
                }
                if !run.steps.isEmpty {
                    RouteCards(steps: run.steps + ahead, current: Self.currentStep(run.steps, run.lines))
                }
                if let prompt = SignerActivity.shared.ledger {
                    // The Ledger's turn: what to do on the device, in the words of the step it is on.
                    HStack(spacing: 12) {
                        LedgerGlyph(size: 34).colorInvert()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ws.say("Confirm on your Ledger: \(run.title)", "Подтверди на Ledger: \(run.title)")).font(.ui(13, .semibold)).lineLimit(1)
                            Text(prompt).font(.ui(10.5)).opacity(0.85).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "hand.point.up.left.fill").font(.system(size: 20, weight: .medium))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: 560, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black))
                    .transition(.opacity)
                } else if SignerActivity.shared.waiting > 0 {
                    // What is being signed, with the coin: the system's own window says it in the signer's words.
                    HStack(spacing: 10) {
                        BrandLogo(size: 30, mood: .waiting)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ws.say("Sign with Touch ID: \(run.title)", "Подпиши Touch ID: \(run.title)")).font(.ui(13, .semibold)).lineLimit(1)
                            Text(ws.say("Touch the sensor, or type your Mac password if it asks. It covers this move only.",
                                        "Приложи палец к датчику или введи пароль Mac, если спросит. Подпись — только на это действие."))
                                .font(.ui(10.5)).opacity(0.85).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "touchid").font(.system(size: 22, weight: .medium))
                    }
                    .foregroundStyle(Brand.onAccent)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: 560, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.accent))
                    .transition(.opacity)
                }
                TimelineView(.periodic(from: run.started, by: 1)) { t in
                    Label("\(run.lines.last ?? "Signing") · \(Int(t.date.timeIntervalSince(run.started))) s", systemImage: "bolt.fill")
                        .font(.ui(10)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(width: max(470, RouteCards.width(run.steps.count + ahead.count)), alignment: .leading)
            .transition(.opacity)
            .animation(.snappy, value: SignerActivity.shared.atDevice)
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
            // A place, not a number: «LOCKED · 4 DAYS» or «ARRIVES · ≈ 30–40 S» mustn't light up at any «4» in a report.
            if place.first?.isLetter == true, said.contains(place) { current = i }
        }
        return current
    }
}

/// Closing an open position, waiting for «do it»: the price line runs to its flag with what it comes to, and the USDC
/// goes back to the trading balance.
struct PositionMoveBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if case .position(.close(let share), let coin)? = ws.pendingAction, let route = ws.closeRoute(share, coin: coin) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(route.title).font(.ui(14, .semibold))
                    StatusChip(text: "waiting for the signature", tint: Brand.profit).fixedSize()
                    Spacer(minLength: 12)
                    PendingButtons()
                }
                RouteCards(steps: route.steps, build: true)
            }
            .transition(.opacity)
        }
    }
}

extension Workspace {
    /// A close as the canvas draws it: waiting for Confirm, while it goes through, and as Done or Failed after.
    func closeRoute(_ share: Decimal, coin: String) -> (title: String, steps: [ActivityBubble])? {
        guard let p = positions.first(where: { $0.coin == coin }) else { return nil }
        let name = coin.hasPrefix("xyz:") ? String(coin.dropFirst(4)) : coin
        let side = p.size > 0 ? "long" : "short"
        let pnl = p.unrealizedPnl * share
        return ("Close \(share == 1 ? "" : Fmt.pct(share * 100) + " of ")\(name) \(side)", [
            ActivityBubble(kind: "step", label: "CLOSE · \(name.uppercased()) \(side.uppercased())", title: "\(pnl < 0 ? "−" : "+")\(Fmt.usd(abs(pnl)))",
                           lines: ["share\t\(Fmt.pct(share * 100))", "size\t\(Fmt.num(abs(p.size) * share, maxFraction: 6)) \(name)", "entry\t\(Fmt.price(p.entry))"]
                               + (markets[coin].map { ["now\t≈ \(Fmt.price($0.markPx))"] } ?? []),
                           logo: TokenLogo.name(forAsset: coin) ?? "hype", fill: .hyperliquid),
            ActivityBubble(kind: "step", label: "TO · HYPERLIQUID", title: "USDC", lines: ["back to the trading balance"], logo: "hype", fill: .hyperliquid),
        ])
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
                        Spacer(minLength: 12)
                        PendingButtons()
                    }
                    RouteCards(steps: route.steps + ws.chainSteps(), footer: route.footer, pending: command, build: true)
                    Label(route.footer, systemImage: "signature").font(.ui(10)).foregroundStyle(.secondary)
                        .frame(maxWidth: 470, alignment: .leading)
                }
                if let warning = route.warning {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.ui(10)).foregroundStyle(Brand.jevInk)
                }
            }
            .frame(width: max(470, RouteCards.width(route.steps.count)), alignment: .leading)
            .transition(.opacity)
            .task(id: command) { await ws.quoteSwap(command) }
        }
    }
}

extension Workspace {
    static let help = "I didn’t catch what to do. For example: “deposit 1 USDC into Jupiter”, “long ETH risk $5 by the book”, “send 5 USDC to Bybit”, “where to keep USDC”, “alert me when ETH is below 2,500”."

    /// One path for every wallet command, typed or read by the model: a missing amount is asked for and remembered;
    /// money moves only after «do it» on the drawn route.
    /// `quiet`: a step of a chain; its card shows, the chain's own line already said what it is.
    func handleWallet(_ command: WalletCommand, note: String? = nil, quiet: Bool = false) async {
        // A Solana token named by its mint: looked up first, and only with Safe search off (TokensUI.swift).
        var command = command
        switch command {
        case .buy(let a, let u) where !a.resolved:
            guard let token = await spotToken(a, note: note) else { return }
            command = .buy(token, usdc: u)
        case .sell(let a, let x) where !a.resolved:
            guard let token = await spotToken(a, note: note) else { return }
            command = .sell(token, amount: x)
        case .jupiterDCA(let a, let u, let o, let e) where !a.resolved:
            guard let token = await spotToken(a, note: note) else { return }
            command = .jupiterDCA(token, usdc: u, orders: o, every: e)
        case .jupiterDCACancel(let a?) where !a.resolved:
            guard let token = await spotToken(a, note: note) else { return }
            command = .jupiterDCACancel(token)
        default: break
        }
        updateActivity { $0.understood = command.summary }
        if let missing = missingKey(for: command) { reply(missing, note: note); return }   // a key wallet without this chain (Wallets.swift)
        if let off = moduleRefusal(command) { reply(off, note: note); return }   // switched off in Settings › Modules
        if case .sendTo(let name, let amount, let net) = command { prepareTransfer(amount, to: name, network: net, note: note, quiet: quiet); return }
        if case .pay = command { await preparePayment(command, note: note); return }
        if case .claimRewards = command { await prepareClaim(command, note: note); return }
        if case .sweepRewards = command { await prepareClaim(command, note: note); return }
        if case .showApprovals = command {
            withAnimation(StudioView.spring) { detail = "approvals" }
            reply(say("Your token approvals are on the canvas: who may still spend what, on each network. Revoke sets one to zero.",
                      "Разрешения на холсте: кто ещё может тратить твои токены, по сетям. Revoke обнуляет одно."), note: note)
            return
        }
        if case .receive = command {
            withAnimation(StudioView.spring) { showReceive = true }
            let sol = isSolanaAddress(solanaAddress) ? "Solana \(AddressCheck.ends(solanaAddress).start) … \(AddressCheck.ends(solanaAddress).end)" : nil
            reply(say("Your addresses are on the canvas\(sol.map { " — \($0) for USDC and SOL (recommended)" } ?? ""), plus Base for USDC and ETH. ihatecrypto can’t pull money in; send it there from an exchange or another wallet, on that network. It shows up within about 30 s and I’ll tell you when it arrives. To put money you already have into a vault, say “deposit 1 USDC into Jupiter”.",
                      "Твои адреса на холсте\(sol.map { " — \($0) для USDC и SOL (рекомендую)" } ?? ""), и Base для USDC и ETH. ihatecrypto не может сам забрать деньги: отправь их туда с биржи или другого кошелька, именно в этой сети. Они появятся примерно через 30 с, и я скажу, когда придут. Чтобы положить уже имеющиеся деньги в хранилище, скажи «положи 1 USDC в Jupiter»."), note: note)
            return
        }
        if case .sendToken(let name, let token, let amount, let network) = command {
            do {
                if try acrossRecipient(name, token: token, network: network) != nil {
                    guard amount != nil else { throw ExecutionError("Say how much \(token.uppercased()): there's none in this wallet to send all of — it's bought with USDC on the way.") }
                } else {
                    _ = try tokenRecipient(name, network: network)
                }
            } catch { reply(error.localizedDescription, note: note); return }
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
            do { try requireConfirmed(entry) } catch { reply(error.localizedDescription, note: note); return }
        }
        if let question = command.amountQuestion {
            awaitingAmount = command
            reply(say(question, "Сколько? Напиши число.") + amountHint(command), note: note)
            return
        }
        // Jupiter's DCA: the swaps when none were named, and Jupiter's own minimums before a card that would fail.
        if case .jupiterDCA(let a, let u?, let o, let e) = command {
            let orders = o ?? WalletCommand.jupiterDCAOrders(for: u)
            if let problem = WalletCommand.jupiterDCAProblem(usdc: u, orders: orders) { reply(problem, note: note); return }
            command = .jupiterDCA(a, usdc: u, orders: orders, every: e)
        }
        // A deposit into Aave or Morpho takes the USDC on its own network first, then Solana's. When neither has enough
        // but another EVM network does, that money comes straight from there, the way a trade's does: the move, then the
        // deposit, one Confirm. «положи 300 в aave на арбитруме» with the USDC on Ethereum made a card that could only fail.
        if !quiet, TaskRun.automation == nil, let steps = fundedFromElsewhere(command) {
            reply(say("In steps: ", "По шагам: ", "Por pasos: ") + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " → "), note: note)
            await runSteps(steps)
            return
        }
        // A recurring buy can run two ways: both are offered, in a line each, before either starts. Jupiter's DCA named
        // outright, a step of a chain or a task, and the way already picked go straight.
        if case .schedule(let asset, let usdc, let days) = command, !quiet, TaskRun.automation == nil, dcaChoice != command,
           Modules.current.allows(.jupiterDCA) {
            offerDCAChoice(asset, usdc: usdc, days: days, note: note)
            return
        }
        if case .schedule = command { dcaChoice = nil }
        // It reads the active wallet's balances: a task on the automation wallet leaves the check to the move itself.
        if TaskRun.automation == nil, let why = refusalBeforeCard(command, inChain: quiet) { reply(why, note: note); return }
        switch command {
        case .yields, .allocate, .rebalance, .schedule, .stopSchedules, .jupiterDCAOrders:
            // Read-only, or with a board and a step of their own.
            await move(command)
        default:
            await learnTokenNames(in: command.summary)
            pendingAction = .wallet(command)
            pendingText = readable(command.summary)
            if quiet { return }
            reply(say("Understood: \(readable(command.summary)). It’s on the canvas — Sign it",
                      "Понял: \(readable(command.summary)). Карточка на холсте — нажми Confirm",
                      "Entendido: \(readable(command.summary)). Está en el lienzo: confírmalo")
                  + orCancel(say(", or say anything else to cancel.", " или напиши что-нибудь другое, чтобы отменить.", ", o di otra cosa para cancelar.")), note: note)
        }
    }

    /// Buying over time, the two ways as cards: Jupiter's DCA on-chain (a budget in rounds of at least 50, runs with the
    /// app closed) or the app's own recurring buys (the money stays in the wallet, no minimum, the app must run).
    private func offerDCAChoice(_ asset: SpotAsset, usdc: Decimal, days: Int, note: String?) {
        let period = days == 1 ? "day" : days == 7 ? "week" : days == 30 ? "month" : "\(days) days"
        let periodRU = days == 1 ? "день" : days == 7 ? "неделю" : days == 30 ? "месяц" : "\(days) дн."
        // Jupiter takes a budget: four rounds of this amount, or its least (2 × 50) when the amount is under a round.
        let (total, rounds) = usdc >= WalletCommand.jupiterDCAMinimum / 2 ? (usdc * 4, 4) : (WalletCommand.jupiterDCAMinimum, 2)
        let jupiter = WalletCommand.jupiterDCA(asset, usdc: total, orders: rounds, every: days * 86400)
        let app = WalletCommand.schedule(asset, usdc: usdc, days: days)
        dcaChoice = app
        let each = Fmt.num(total / Decimal(rounds))
        withAnimation(StudioView.spring) {
            nextSteps = NextSteps(options: [
                ChatRouter.Option(title: say("Jupiter DCA: \(rounds) × \(each) USDC → \(asset.symbol)", "Jupiter DCA: \(rounds) × \(each) USDC → \(asset.symbol)"),
                                  comment: say("On-chain: \(Fmt.num(total)) USDC goes in now and Jupiter buys every \(period), even with the app closed. From 100 USDC, 50 a round; 0.1% fee; cancel returns the rest.",
                                               "На блокчейне: \(Fmt.num(total)) USDC вносятся сразу, Jupiter покупает раз в \(periodRU), даже при закрытом приложении. От 100 USDC, по 50 за раз; комиссия 0.1%; отмена вернёт остаток."),
                                  command: jupiter.summary, recommended: usdc >= WalletCommand.jupiterDCAMinimum / 2),
                ChatRouter.Option(title: say("In the app: \(Fmt.num(usdc)) USDC → \(asset.symbol) every \(period)", "В приложении: \(Fmt.num(usdc)) USDC → \(asset.symbol) раз в \(periodRU)"),
                                  comment: say("The money stays in your wallet until each buy; no minimum. Buys while ihatecrypto runs (Keep running), each signed with Touch ID or the automation wallet.",
                                               "Деньги лежат у тебя до каждой покупки; минимума нет. Покупает, пока ihatecrypto работает (Keep running), каждую покупку подписывает Touch ID или кошелёк автоматизации."),
                                  command: app.summary, recommended: usdc < WalletCommand.jupiterDCAMinimum / 2),
            ], userText: "", found: [], canvas: canvasID)
        }
        reply(say("\(asset.symbol) over time can be bought two ways — pick one on the canvas.", "Покупать \(asset.symbol) регулярно можно двумя способами — выбери на холсте."), note: note)
    }

    /// How a card waiting for Confirm is dropped, after the line that lays it out. With a model a question about the
    /// card keeps it (send()): only Cancel or «cancel» drops it. Without one, `withoutModel`: anything else said does.
    func orCancel(_ withoutModel: String) -> String {
        llmClient() == nil ? withoutModel
            : say(". To cancel, press Cancel or say “cancel”.", ". Чтобы отменить, нажми Cancel или скажи «отмена».", ". Para cancelar, pulsa Cancel o di «cancelar».")
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
        let chat = Array(messages.dropFirst())
        // A message the guard stopped never reaches a model, not even as history behind a «pass it»: only the guard's reply stays.
        let stopped = Set(chat.indices.dropLast().filter { chat[$0].fromUser && Message.stopsSteering(chat[$0 + 1].note) })
        // A long message the person wrote is read whole (up to 3000 characters); our own replies only need their gist.
        return chat.indices.filter { !stopped.contains($0) }.suffix(12).map { i in
            chat[i].fromUser ? "user: " + chat[i].text.prefix(3000) : "ihatecrypto: " + chat[i].text.prefix(600)
        }
    }
}
