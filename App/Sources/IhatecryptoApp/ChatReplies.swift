import Foundation
import LLMCatalog
import IhatecryptoCore
import SwiftUI

/// The chat as the eye reads it: execution steps gathered into one card, every other message on its own.
struct ChatHistory: View, Equatable {
    let messages: [Message]
    /// The last steps card shows a spinner on its last step while a plan is executing.
    var running = false

    var body: some View {
        let items = ChatItem.group(messages)
        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
            switch item {
            // The line right after the steps is their outcome.
            case .message(let m) where i > 0 && items[i - 1].isSteps && !m.fromUser: Reply(message: m, outcome: true)
            case .message(let m): MessageRow(message: m)
            case .steps(let steps): StepsCard(steps: steps, running: running && steps.last?.id == messages.last?.id)
            }
        }
    }

    /// Scroll here for the newest line: a step inside a card has no view of its own.
    static let end = "chat-end"
}

/// ihatecrypto working on the last message: dots under it until the first words, then the answer as far as the model
/// has written it. A view of its own: the draft changes several times a second, and only this redraws with it, not the
/// whole chat above.
struct DraftReply: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if ws.thinking, ws.messages.last?.fromUser == true {
            if let draft = ws.draftReply { Reply(message: Message(fromUser: false, text: draft), draft: true).opacity(0.85).transition(.opacity) }
            else { ThinkingDots(label: ws.agentStep).transition(.opacity) }
        }
    }
}

/// Three dots breathing in turn where ihatecrypto's reply will appear.
struct ThinkingDots: View {
    var label: String?

    var body: some View {
        HStack(spacing: 8) {
            dots
            if let label { Text(label + "…").font(.ui(12)).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private var dots: some View {
        // Core Animation's: a 30 fps TimelineView here redrew the whole window for as long as a model took to answer.
        BreathingDots().frame(width: BreathingDots.size.width, height: BreathingDots.size.height)
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.glassFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.cardBorder))
        .accessibilityElement().accessibilityLabel("The assistant is thinking")
    }
}

enum ChatItem: Identifiable {
    case message(Message)
    case steps([Message])

    var id: UUID {
        switch self {
        case .message(let m): m.id
        case .steps(let s): s[0].id
        }
    }

    var isSteps: Bool { if case .steps = self { true } else { false } }

    static func group(_ messages: [Message]) -> [ChatItem] {
        var items: [ChatItem] = []
        for m in messages {
            guard !m.fromUser, m.note == "execution" else { items.append(.message(m)); continue }
            if case .steps(let s)? = items.last { items[items.count - 1] = .steps(s + [m]) } else { items.append(.steps([m])) }
        }
        return items
    }
}

struct MessageRow: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.colorScheme) private var scheme
    let message: Message

    var body: some View {
        if message.fromUser {
            // Yours: an orange outline, no fill (V02 «Cards»); the answers are the filled cards.
            VStack(alignment: .trailing, spacing: 6) {
                // What went to the model with it, over it: one chip per block, step, token or address.
                if let context = message.context, !context.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { contextLabel; ForEach(context, id: \.title) { SentContextChip(context: $0) } }
                        VStack(alignment: .trailing, spacing: 4) { contextLabel; ForEach(context, id: \.title) { SentContextChip(context: $0) } }
                    }
                    .padding(.leading, 80)
                }
                // Its time beside it, at the bubble's foot: under the pointer only, nobody found it.
                HStack(alignment: .bottom, spacing: 8) {
                    Spacer(minLength: 80)
                    if let at = message.at {
                        Text(ChatText.when(at)).font(.ui(10.5)).monospacedDigit().foregroundStyle(.tertiary).padding(.bottom, 5)
                    }
                    (message.shown.map(chipped) ?? Text(message.text))
                        .textSelection(.enabled)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.accent, lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .font(.ui(14))
        } else {
            Reply(message: message)
        }
    }

    private var contextLabel: some View {
        Label(ws.say("Context", "Контекст", "Contexto"), systemImage: "paperclip").font(.ui(10.5, .semibold)).foregroundStyle(.tertiary)
    }

    /// The message as typed, each «$SOL» or «$<mint>» drawn as in the field: the token's chip, not a raw address.
    private func chipped(_ typed: String) -> Text {
        // Padded: a mention at the very end is closed too.
        let padded = typed + " "
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance
        var out = Text(""), at = padded.startIndex
        for m in TokenMentions.find(padded) {
            let face = ws.tokenFace(m.ticker)
            let chip = ComposerField.chipImage(face.label ?? m.ticker.uppercased(), picture: ComposerField.picture(m.ticker, icon: face.icon),
                                               appearance: appearance)
            out = out + Text(padded[at..<m.range.lowerBound]) + Text(Image(nsImage: chip)).baselineOffset(ComposerField.chipDrop)
            at = m.range.upperBound
        }
        return out + Text(padded[at...].dropLast())
    }
}

/// What went to the model with a message — a canvas block, a route step, a token, an address — as a chip over it; a click
/// shows the words it went as (the owner, 2026-10-19: «чтобы отображалось в чате как контекст, мы его передаем же?»).
/// A block whose numbers aren't in what the model reads says so in orange: only its name went.
struct SentContextChip: View {
    @Environment(Workspace.self) private var ws
    let context: StepContext
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                if let logo = context.logo { TokenLogo(name: logo, size: 14) }
                else { Image(systemName: "square.on.square").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                Text(context.title).font(.ui(11.5, .semibold)).lineLimit(1).truncationMode(.middle)
                Image(systemName: context.bare ? "exclamationmark.circle" : "chevron.down").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(context.bare ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.glassFill))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.glassRim))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .help(ws.say("What the model got with this message", "Что модель получила с этим сообщением", "Lo que recibió el modelo con este mensaje"))
        .accessibilityLabel(context.title)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(ws.say("SENT TO THE MODEL", "УШЛО МОДЕЛИ", "ENVIADO AL MODELO")).font(.ui(10, .semibold)).tracking(0.8).foregroundStyle(.secondary)
                Text(context.about ?? context.title).font(.ui(12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if context.bare {
                    Text(ws.say("Only the block's name went: its numbers don't reach the model yet.",
                                "Ушло только название блока: его цифры модели пока не передаются.",
                                "Solo fue el nombre del bloque: sus cifras aún no llegan al modelo."))
                        .font(.ui(11, .semibold)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14).frame(width: 360, alignment: .leading)
        }
    }
}

/// One answer: a header line (the coin, who answered or where it ran, the time — «understood as …» and what the model
/// looked at under the pointer), then its words as paragraphs and lists, amounts standing out, gains and losses colored,
/// links and long hex short. A result (a move done, money in, an emoji line) keeps a card of its own; the model's plain
/// answer is words on the chat, no frame (2026-10-19, «меньше рамок»). A failure keeps its red card, a checklist its own.
struct Reply: View {
    let message: Message
    /// What an execution came to: a green check instead of the emoji.
    var outcome = false
    /// A reply still being written: each version of it is drawn once, so it isn't kept in ChatText's cache.
    var draft = false

    var body: some View {
        let (emoji, full) = ChatText.leadingEmoji(message.text)
        // A service's raw JSON under the words (older paid answers had it): folded into a card, not a wall of braces.
        let (text, data) = MPP.splitData(full)
        let failed = text.hasPrefix("Failed: "), list = Checklist(text)
        let head = message.note.map(ChatText.header)
        let boxed = !failed && list == nil && (outcome || emoji != nil || head?.result == true)
        VStack(alignment: .leading, spacing: 8) {
            if head != nil || message.at != nil { header(head) }
            if failed {
                Label { styled(String(text.dropFirst(8))).foregroundStyle(Brand.blockedInk) } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Brand.loss)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.blockedTint))
            } else if outcome {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(Brand.profit)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.profit.opacity(0.16)))
                    words(emoji.map { "\($0) \(text)" } ?? text).padding(.top, 5)
                }
            } else if let list {
                ChecklistCard(list: list)
            } else if let emoji {
                HStack(alignment: .top, spacing: 10) {
                    Text(emoji).font(.ui(15))
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.7)))
                    words(text).padding(.top, 5)
                }
            } else {
                words(text)
            }
            if let data { DataCard(json: data).padding(.leading, outcome || emoji != nil ? 40 : 0) }
            if message.options?.isEmpty == false { Answers(message: message) }
        }
        .font(.ui(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        // Unframed words line up with a card's.
        .padding(.horizontal, failed || list != nil ? 0 : 12).padding(.vertical, boxed ? 12 : 2)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(boxed ? AnyShapeStyle(Brand.glassFill) : AnyShapeStyle(.clear)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(boxed ? Brand.cardBorder : .clear))
    }

    private func styled(_ text: String) -> some View {
        Text(ChatText.styled(text, cached: !draft)).textSelection(.enabled).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    /// The words as the model laid them out: paragraphs apart, «- » and «1. » lines as a list.
    private func words(_ text: String) -> some View {
        let blocks = ChatText.blocks(text)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                Group {
                    if let mark = b.mark {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(mark).foregroundStyle(.secondary).monospacedDigit()
                            styled(b.text)
                        }
                        .padding(.leading, 2)
                    } else {
                        styled(b.text)
                    }
                }
                .padding(.top, i == 0 ? 0 : b.mark != nil && blocks[i - 1].mark != nil ? 4 : 10)
            }
        }
    }

    /// The coin, «Claude Opus 5.5» or where it ran («Relay · Solana → Base»), then its time right after the name (the
    /// owner, 2026-10-19: «после клауд было время»).
    private func header(_ head: ChatText.Header?) -> some View {
        HStack(spacing: 6) {
            BrandLogo(size: 14)
            if message.note == "incoming" { Image(systemName: "arrow.down.circle.fill") }
            if let head { Text(head.label).lineLimit(1) }
            if let at = message.at { Text((head == nil ? "" : "· ") + ChatText.when(at)).monospacedDigit().layoutPriority(1) }
            Spacer(minLength: 0)
        }
        .font(.ui(11, .medium))
        .foregroundStyle(message.note == "incoming" ? AnyShapeStyle(Brand.profit) : AnyShapeStyle(.tertiary))
        .help(head?.detail ?? "")
    }
}

/// The cards a reply offered, under its words (the user's reference, 2026-10-15: a chat answer with its cards inside):
/// a tap carries one out while they're the live ones (`ws.liveSteps`: the last reply's, for 30 minutes). Old ones — passed
/// over, answered or past their time — fold to one line, the pick staying in view with its check (the owner,
/// 2026-10-19: «блеклые… может их убирать или скрывать», «чтобы их можно было сворачивать»); any can be folded or
/// opened by hand.
struct Answers: View {
    @Environment(Workspace.self) private var ws
    let message: Message

    /// The chat scrolls to the card the keys are on.
    static func cardID(_ message: UUID, _ index: Int) -> String { "\(message)#\(index)" }

    var body: some View {
        // The live ones look again each minute: at 30 minutes they fold by themselves, the chat untouched.
        if ws.nextSteps?.message == message.id { TimelineView(.everyMinute) { _ in cards } } else { cards }
    }

    @ViewBuilder private var cards: some View {
        let live = ws.liveSteps?.message == message.id
        let options = message.options ?? []
        let folded = ws.cardFold[message.id] ?? !live
        let shown: [Int] = !folded ? Array(options.indices) : message.picked.flatMap { options.indices.contains($0) ? [$0] : nil } ?? []
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown, id: \.self) { i in
                let o = options[i]
                // Not `.disabled`: it would dim the pick too.
                Button { if live { Task { await ws.pick(o) } } } label: {
                    // ↑↓ from the field (ChatComposer) move between them; Return picks the one they're on.
                    OptionCard(option: o, compact: true, answered: message.picked != nil, picked: message.picked == i,
                               keyed: live ? ws.cardKey.map { $0 == i } : nil)
                }
                .buttonStyle(.plain)
                .modifier(HoverLift(radius: 12, enabled: live && !ws.busy))
                .allowsHitTesting(live && !ws.busy)
                .opacity(live || message.picked == i ? 1 : 0.45)
                .help(o.command.isEmpty ? ws.say("Answer with this", "Ответить этим") : o.command)
                .accessibilityLabel(o.title)
                .id(Self.cardID(message.id, i))
            }
            HStack(spacing: 10) {
                if shown.count < options.count || !folded {
                    Button { ws.cardFold[message.id] = !folded } label: {
                        Label(!folded ? ws.say("Fold", "Свернуть", "Plegar")
                              : message.picked == nil ? ws.say("Options: \(options.count)", "Варианты: \(options.count)", "Opciones: \(options.count)")
                              : ws.say("Other options: \(options.count - 1)", "Другие варианты: \(options.count - 1)", "Otras opciones: \(options.count - 1)"),
                              systemImage: folded ? "chevron.down" : "chevron.up")
                            .font(.ui(11, .semibold)).labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).pointerStyle(.link)
                    .help(live ? ws.say("Fold the cards; they stay pickable when opened", "Свернуть варианты; раскрытые снова можно выбрать",
                                        "Plegar las opciones; abiertas se pueden elegir")
                          : ws.say("Offered earlier: a newer message or 30 minutes have passed, so their numbers may be old",
                                   "Предлагались раньше: был новый вопрос или прошло 30 минут, цифры в них могли устареть",
                                   "Ofrecidas antes: llegó un mensaje nuevo o pasaron 30 minutos, sus cifras pueden ser viejas"))
                }
                if live, !folded {
                    Text(ws.say("Or write your own. ↑ ↓ to choose, ⏎ to answer.", "Или напиши свой вариант. ↑ ↓ — выбрать, ⏎ — ответить."))
                        .font(.ui(10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// «✓ Market: …», «✗ Stop: not set — …»: a plan checked item by item (Workspace.planChecklist), with the text
/// before the marked lines above the card and the next step under it.
struct Checklist {
    let intro: String
    let items: [(mark: Character, text: String)]
    let next: String

    init?(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        func mark(_ line: String) -> Character? {
            guard let first = line.first, "✓✗⚠·".contains(first), line.dropFirst().first == " " else { return nil }
            return first
        }
        guard let first = lines.firstIndex(where: { mark($0) != nil }), let last = lines.lastIndex(where: { mark($0) != nil }),
              lines[first...last].filter({ mark($0) != nil }).count >= 3 else { return nil }
        intro = lines[..<first].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        items = lines[first...last].compactMap { line in mark(line).map { (mark: $0, text: String(line.dropFirst(2))) } }
        next = lines[(last + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ChecklistCard: View {
    let list: Checklist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !list.intro.isEmpty { text(list.intro) }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        icon(item.mark).font(.ui(12, .semibold)).frame(width: 14)
                        text(item.text)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
            if !list.next.isEmpty { text(list.next).fontWeight(.semibold) }
        }
    }

    private func text(_ s: String) -> some View {
        Text(ChatText.styled(s)).textSelection(.enabled).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func icon(_ mark: Character) -> some View {
        switch mark {
        case "✓": Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.profit).accessibilityLabel("OK")
        case "✗": Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.loss).accessibilityLabel("Missing or blocked")
        case "⚠": Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Warning")
        default: Image(systemName: "circle.dotted").foregroundStyle(.secondary).accessibilityLabel("Optional")
        }
    }
}

/// «Bridge…», «Approve…: done.», «Buy…: done.» — the steps of one execution as a checklist with a rail.
struct StepsCard: View {
    let steps: [Message]
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                Text(running ? "EXECUTING" : "EXECUTED · \(steps.count) \(steps.count == 1 ? "STEP" : "STEPS")").tracking(0.6)
            }
            .font(.ui(10, .semibold)).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(steps.indices, id: \.self) { i in
                    step(steps[i].text, last: i == steps.count - 1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.cardBorder))
    }

    private func step(_ raw: String, last: Bool) -> some View {
        let text = raw.replacingOccurrences(of: ": done.", with: "")
        // The first sentence says what happened; the rest (balances before and after) is small print.
        let cut = text.range(of: ". ")
        let head = cut.map { String(text[..<$0.lowerBound]) } ?? text
        let rest = cut.map { String(text[$0.upperBound...]) }
        let failed = raw.localizedCaseInsensitiveContains("failed") || raw.localizedCaseInsensitiveContains("refused")
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 3) {
                Group {
                    if running && last {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: failed ? "xmark" : "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                            .frame(width: 16, height: 16).background(Circle().fill(failed ? Brand.loss : Brand.profit.opacity(0.9)))
                    }
                }
                .frame(width: 16, height: 16)
                if !last { Capsule().fill(.quaternary).frame(width: 2).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ChatText.styled(head)).font(.ui(13)).fixedSize(horizontal: false, vertical: true)
                if let rest, !rest.isEmpty {
                    Text(ChatText.styled(rest, emphasis: false)).font(.ui(11)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(rest)
                }
            }
            .textSelection(.enabled)
            .padding(.bottom, last ? 0 : 12)
        }
    }
}

/// A service's JSON in the chat, folded: what it found (titles with their sites, or its first values), and the JSON itself
/// behind «Show JSON». Works on JSON cut short too: the rows are read line by line.
struct DataCard: View {
    let json: String
    @State private var open = false

    var body: some View {
        let rows = MPP.rows(json)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces").font(.ui(10, .bold))
                Text("SERVICE ANSWER").font(.ui(10, .semibold)).tracking(0.6)
                Spacer(minLength: 8)
                Button { open.toggle() } label: {
                    Label(open ? "Hide JSON" : "Show JSON", systemImage: open ? "chevron.up" : "chevron.down").font(.ui(10.5, .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("The service's answer as it came")
            }
            .foregroundStyle(.tertiary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 1) {
                    if let url = row.url.flatMap(URL.init(string:)) {
                        Link(destination: url) { Text(row.title).font(.ui(12.5, .semibold)).lineLimit(2).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                        Text(url.host() ?? url.absoluteString).font(.ui(10)).foregroundStyle(RouteFill.relay.accent).lineLimit(1)
                    } else {
                        Text(row.title).font(.ui(12)).lineLimit(2)
                    }
                }
            }
            if open {
                ScrollView {
                    Text(json).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}

enum ChatText {

    /// «14:57» today, «Oct 16, 22:38» before.
    static func when(_ d: Date) -> String { Calendar.current.isDateInToday(d) ? Fmt.time(d) : Fmt.date(d) }

    struct Header: Equatable {
        let label: String
        /// Under the pointer: what the message was understood as, what the model looked at.
        let detail: String?
        /// Where a move ran («Relay · Solana → Base», «Solana»): its reply is a result's card.
        let result: Bool
    }

    /// A reply's note as its header says it: the model by name, «understood as “…”» and «looked at …» under the pointer.
    static func header(_ note: String) -> Header {
        let parts = note.components(separatedBy: " · ")
        func first(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
        // «understood as “send 0.01 SOL to Automation” · claude-opus-5-5»: the command may hold « · » itself.
        if note.hasPrefix("understood as "), let cut = note.range(of: " · ", options: .backwards) {
            return Header(label: LLMCatalog.displayName(model: String(note[cut.upperBound...])), detail: first(String(note[..<cut.lowerBound])), result: false)
        }
        if note == "from your portfolio and history" { return Header(label: first(note), detail: nil, result: false) }
        if parts.count > 1, parts[1].hasPrefix("looked at ") || parts[1] == "from your portfolio and history" {
            return Header(label: LLMCatalog.displayName(model: parts[0]), detail: first(parts.dropFirst().joined(separator: " · ")), result: false)
        }
        // A bare model id («claude-opus-5-5», «qwen3:8b»): no spaces and a digit; places and protocols have neither.
        if !note.contains(" "), note.contains(where: \.isNumber) {
            return Header(label: LLMCatalog.displayName(model: note), detail: nil, result: false)
        }
        return Header(label: first(note), detail: nil, result: true)
    }

    struct Block: Equatable {
        /// «•» or «2.» for a list line; nil for a paragraph.
        let mark: String?
        let text: String
    }

    /// Paragraphs (a blank line between), «- »/«• »/«1. » lines as list items, «## Title» as a bold line.
    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = [], para: [String] = []
        func flush() { if !para.isEmpty { out.append(Block(mark: nil, text: para.joined(separator: "\n"))); para = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let m = line.wholeMatch(of: /(?:[-•*]|(\d{1,2})[.)])\s+(.+)/) {
                flush()
                out.append(Block(mark: m.1.map { "\($0)." } ?? "•", text: String(m.2)))
            } else if let m = line.wholeMatch(of: /#{1,4}\s+(.+)/) {
                flush()
                out.append(Block(mark: nil, text: "**\(m.1)**"))
            } else {
                para.append(raw)
            }
        }
        flush()
        return out
    }

    /// «💸 Received…» → («💸», «Received…»); nil when the text starts with a letter.
    static func leadingEmoji(_ text: String) -> (String?, String) {
        guard let first = text.first, first.unicodeScalars.first?.properties.isEmojiPresentation == true
                || first.unicodeScalars.count > 1 && first.unicodeScalars.first?.properties.isEmoji == true else { return (nil, text) }
        return (String(first), String(text.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    /// Markdown as the model writes it, then: links → «Arbiscan ↗», 0x… → «0x2E8c…1e18», signed numbers in
    /// profit or loss colors, amounts («2 USDC», «$0.24») bold unless `emphasis` is off.
    static func styled(_ text: String, emphasis: Bool = true, cached: Bool = true) -> AttributedString {
        guard cached else { return parse(text, emphasis: emphasis) }
        let key = "\(emphasis)\u{0}\(text)"
        if let hit = cache[key] { return hit }
        let s = parse(text, emphasis: emphasis)
        // ponytail: dropped whole past 500 texts, then filled again by what's on screen; LRU if that ever shows.
        if cache.count >= 500 { cache.removeAll(keepingCapacity: true) }
        cache[key] = s
        return s
    }

    /// The chat redraws on every keystroke in the field; each message is parsed once.
    private static var cache: [String: AttributedString] = [:]
    /// A contract's ticker when the app knows it (Workspace sets it).
    static var tokenName: (String) -> String? = { _ in nil }

    private static func parse(_ text: String, emphasis: Bool) -> AttributedString {
        // «~87% … ~$8.1» is the model's «about», not a strikethrough between the two.
        let text = text.replacingOccurrences(of: "~", with: "\\~")
        var s = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        replace(in: &s, #/https?://[^\s]+[^\s.,;:)]/#) { url in
            let host = URL(string: url)?.host() ?? url
            let labels = host.split(separator: ".")
            let name = labels.count >= 2 ? labels[labels.count - 2] : Substring(host)
            var link = AttributedString(name.prefix(1).uppercased() + String(name.dropFirst()) + " ↗")
            link.link = URL(string: url)
            return link
        }
        replace(in: &s, #/0x[0-9a-fA-F]{40,64}/#) { hex in
            var short = AttributedString("\(hex.prefix(6))…\(hex.suffix(4))")
            short.inlinePresentationIntent = .code
            // A token's contract goes by its ticker, the contract after it: «AI 0x2E8c…1e18».
            guard hex.count == 42, let symbol = tokenName(hex) else { return short }
            return AttributedString("\(symbol) ") + short
        }
        if emphasis {
            style(in: &s, #/\$\d[\d,]*(?:\.\d+)?|\d[\d,]*(?:\.\d+)? [A-Z]{2,6}\b/#) { $0.inlinePresentationIntent = .stronglyEmphasized }
        }
        // Signed numbers start the text or follow a space or «(»: «+25», «(−2.061193)», not «gpt-6»;
        // an alert's «−15.5% away» is a distance, not a loss.
        style(in: &s, #/[+−-]\$?\d[\d,]*(?:\.\d+)?%?/#, when: { plain, range in
            (range.lowerBound == plain.startIndex || " (".contains(plain[plain.index(before: range.lowerBound)]))
                && !plain[range.upperBound...].hasPrefix(" away")
        }) { run in
            let loss = run.characters.first != "+"
            run.foregroundColor = loss ? Brand.loss : Brand.profit
        }
        return s
    }

    private static func replace(in s: inout AttributedString, _ regex: some RegexComponent, with make: (String) -> AttributedString) {
        let plain = String(s.characters)
        for match in plain.matches(of: regex).reversed() {
            let lower = s.index(s.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: match.range.lowerBound))
            let upper = s.index(s.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: match.range.upperBound))
            s.replaceSubrange(lower..<upper, with: make(String(plain[match.range])))
        }
    }

    private static func style(in s: inout AttributedString, _ regex: some RegexComponent,
                              when: (String, Range<String.Index>) -> Bool = { _, _ in true }, _ apply: (inout AttributedSubstring) -> Void) {
        let plain = String(s.characters)
        for match in plain.matches(of: regex) where when(plain, match.range) {
            let lower = s.index(s.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: match.range.lowerBound))
            let upper = s.index(s.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: match.range.upperBound))
            apply(&s[lower..<upper])
        }
    }
}
