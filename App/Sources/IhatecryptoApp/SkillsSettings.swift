import AppKit
import IhatecryptoCore
import SwiftUI
import UniformTypeIdentifiers

/// The skills: the ones ihatecrypto comes with (Skill.builtIn) and those added from a file, each with a switch
/// (Settings › Skills). Which are loaded on a canvas is the canvas's own (Workspace.activeSkills).
@MainActor @Observable final class SkillStore {
    static let shared = SkillStore()
    /// Added from files, kept whole.
    var added: [Skill] = LocalStore.load("skills.json") ?? [] {
        didSet { LocalStore.save(added, "skills.json") }
    }
    /// Switched off, by id: a skill is on until switched off.
    var off: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "skillsOff") ?? []) {
        didSet { UserDefaults.standard.set(off.sorted(), forKey: "skillsOff") }
    }
    var all: [Skill] { Skill.builtIn + added }
    var on: [Skill] { all.filter { !off.contains($0.id) } }

    /// A file added again replaces the skill it made before; one named like a built-in skill gets a number.
    @discardableResult func add(_ url: URL) throws -> Skill {
        var s = Skill.parse(try String(contentsOf: url, encoding: .utf8), fileName: url.lastPathComponent)
        if let i = added.firstIndex(where: { $0.id == s.id }) { added[i] = s; return s }
        let base = s.id
        var n = 2
        while Skill.builtIn.contains(where: { $0.id == s.id }) { s.id = "\(base)-\(n)"; n += 1 }
        added.append(s)
        return s
    }

    func remove(_ id: String) {
        added.removeAll { $0.id == id }
        off.remove(id)
    }
}

struct SkillsSettings: View {
    @Environment(Workspace.self) private var ws
    private var store: SkillStore { SkillStore.shared }
    /// The skill whose whole text is open.
    @State private var reading: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(store.all) { card($0) }
            HStack(spacing: 10) {
                Button(action: add) { Label("Add skill…", systemImage: "plus").font(.ui(13, .semibold)) }
                    .buttonStyle(.bordered).controlSize(.large)
                    .help("A .md or .txt file: a SKILL.md with name and description at the top, or any prompt")
                if let problem { Text(problem).font(.ui(11)).foregroundStyle(Brand.loss).fixedSize(horizontal: false, vertical: true) }
            }
            Text("The assistant sees each switched-on skill's name and what it's for, and reads the whole text when your message is that work; it then follows it for the rest of that canvas. A skill changes how it works with you, never the risk rules, the checks or your Confirm.")
                .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(_ s: Skill) -> some View {
        let on = !store.off.contains(s.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                SettingsIcon(icon: s.builtIn ? "chart.line.text.clipboard" : "doc.text", size: 34, active: on)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(s.name).font(.ui(15, .semibold))
                        if s.builtIn {
                            Text("Built in").font(.ui(10, .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                    }
                    Text(s.about).font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle(s.name, isOn: Binding(get: { on }, set: { v in if v { store.off.remove(s.id) } else { store.off.insert(s.id) } }))
                    .toggleStyle(AccentSwitch())
            }
            HStack(spacing: 14) {
                Button(reading == s.id ? "Hide the text" : "Read the text") { reading = reading == s.id ? nil : s.id }
                if s.id == Skill.tradingStudy.id {
                    Button("Study notes") { NSWorkspace.shared.open(Workspace.studyFolder) }
                        .help("The study's files — profile, playbook, hypotheses… — in Finder")
                    Button("Journal") { NSWorkspace.shared.open(LocalStore.url("journal.json")) }
                        .help("Your journal entries with the market at the time of each")
                        .disabled(!FileManager.default.fileExists(atPath: LocalStore.url("journal.json").path))
                }
                if !s.builtIn { Button("Remove", role: .destructive) { store.remove(s.id) } }
            }
            .buttonStyle(.plain).foregroundStyle(Brand.accentInk).font(.ui(11.5, .semibold)).padding(.leading, 44)
            if reading == s.id {
                ScrollView {
                    Text(s.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 280).padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Brand.glassFill))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Brand.glassRim))
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText] + [UTType(filenameExtension: "md")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.message = "A skill: a .md or .txt file with the instructions"
        guard panel.runModal() == .OK else { return }
        problem = nil
        for url in panel.urls {
            do { try store.add(url) } catch { problem = "«\(url.lastPathComponent)» couldn't be read as text." }
        }
    }
}

// MARK: The trading study's tools in the chat

extension Workspace {
    /// The study's notes, a Markdown file each (StudyNote.files), in Application Support.
    static var studyFolder: URL {
        let folder = LocalStore.url("study")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The `skill`, `trades`, `journal` and `study` lookups.
    func skillLookup(_ l: ChatRouter.Lookup) async -> String {
        switch l.tool {
        case "skill":
            let on = SkillStore.shared.on
            guard let s = on.first(where: { $0.id == Skill.slug(l.arg) || $0.name.lowercased() == l.arg.lowercased() }) else {
                return "No switched-on skill «\(l.arg)». Switched on: " + (on.isEmpty ? "none" : on.map(\.id).joined(separator: ", ")) + "."
            }
            agentStep = say("Reading the skill «\(s.name)»", "Читаю скилл «\(s.name)»")
            if !activeSkills.contains(s.id) { activeSkills.append(s.id) }
            return "Skill «\(s.name)», loaded on this canvas from now on — follow it:\n" + s.text
        case "trades":
            let asked = l.arg.trimmingCharacters(in: .whitespaces)
            let me = asked.isEmpty || asked.lowercased() == "me"
            let address = me ? hlAddress : asked
            guard isEVMAddress(address) else { return "trades takes a Hyperliquid account's 0x address, or me: «\(asked)» isn't one." }
            agentStep = say("Rebuilding the trades on Hyperliquid", "Восстанавливаю сделки на Hyperliquid")
            async let fills = TradeHistory.allFills(user: address)
            async let funding = TradeHistory.allFunding(user: address)
            guard let all = try? await fills else { return "Hyperliquid didn't answer for \(me ? "this wallet" : address); try again in a minute." }
            let stories = TradeHistory.stories(all)
            let trades = TradeStudy.trades(stories, funding: (try? await funding) ?? [])
            return (me ? "The wallet in ihatecrypto" : "Account \(address)") + ": \(all.count) fills"
                + (all.count >= 10_000 ? " (Hyperliquid serves only the last 10,000: older trades aren't in it)" : "") + ".\n"
                + TradeStudy.report(trades, open: stories.filter(\.isOpen).count, cut: TradeStudy.cut(stories))
        case "journal":
            let entries: [JournalEntry] = LocalStore.load("journal.json") ?? []
            guard !entries.isEmpty else { return "The journal is empty: nothing was written with the journal command yet." }
            return "The journal, oldest first\(entries.count > 40 ? " (the last 40 of \(entries.count))" : ""):\n"
                + entries.suffix(40).map { $0.review(now: markets[$0.asset]?.markPx) }.joined(separator: "\n")
        default:   // study
            let one = StudyNote.parse("study \(l.arg): x")?.file
            let notes = StudyNote.files.map(\.value).filter { one == nil || $0 == one }.compactMap { file -> String? in
                guard let text = try? String(contentsOf: Self.studyFolder.appending(path: "\(file).md"), encoding: .utf8) else { return nil }
                // One file whole up to 6,000 characters; all of them, the newest 1,200 of each.
                let keep = one == nil ? 1200 : 6000
                return "\(file):\n" + (text.count > keep ? "…" + text.suffix(keep) : text)
            }
            return notes.isEmpty ? "No study notes\(one.map { " in \($0)" } ?? "") yet." : notes.joined(separator: "\n\n")
        }
    }

    /// «journal HYPE: …»: their words with the market as it is now — price, funding, open interest, BTC and ETH, their
    /// position there.
    func journalCommand(_ j: JournalCommand, note: String) async {
        guard MemoryCommand.inTheirWords(j.words, messages.last(where: \.fromUser)?.text ?? "") else {
            reply(say("The journal keeps only your own words: write the entry yourself and I'll save exactly that.",
                      "В журнал записываю только твои слова: напиши запись сам — сохраню ровно её."), note: note)
            return
        }
        let coin = IntentParser.namedAsset(j.asset, markets: Set(markets.keys)) ?? j.asset
        var e = JournalEntry(at: Date(), asset: coin, words: String(j.words.prefix(2000)))
        if let m = markets[coin] {
            e.price = m.markPx; e.funding = m.funding; e.change24h = m.change24h
            e.volume24h = m.volume24h > 0 ? m.volume24h : nil
        }
        e.openInterestUSD = await JournalEntry.openInterestUSD(coin: coin)
        e.market = ["BTC", "ETH"].filter { $0 != coin }.compactMap { c in
            markets[c].map { "\(c) \(Fmt.price($0.markPx))" + ($0.change24h.map { " (24h \(signedPct($0)))" } ?? "") }
        }
        if let p = positions.first(where: { $0.coin == coin }) {
            e.position = "\(p.size > 0 ? "long" : "short") \(positionSummary(p)), unrealized \(signed(p.unrealizedPnl))"
        }
        let entries: [JournalEntry] = LocalStore.load("journal.json") ?? []
        LocalStore.save(entries + [e], "journal.json")
        reply(say("Saved to your journal — \(IntentParser.pretty(coin)): \(e.snapshot).",
                  "Записал в журнал — \(IntentParser.pretty(coin)): \(e.snapshot)."), note: note)
    }

    /// «study hypotheses: …»: a dated entry at the end of that file.
    func studyNote(_ n: StudyNote, note: String) {
        let url = Self.studyFolder.appending(path: "\(n.file).md")
        let entry = "\n## \(Fmt.date(Date()))\n\(n.text)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(entry.utf8))
            try? h.close()
        } else {
            try? Data(("# \(n.file)\n" + entry).utf8).write(to: url)
        }
        reply(say("Noted in the study's \(n.file).", "Записал в \(n.file) исследования."), note: note)
    }
}
