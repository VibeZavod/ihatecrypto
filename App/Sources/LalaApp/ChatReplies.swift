import Foundation
import LLMCatalog
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
        // Scroll here for the newest line: a step inside a card has no view of its own.
        Color.clear.frame(height: 0).id(Self.end)
    }

    static let end = "chat-end"
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
    let message: Message

    var body: some View {
        if message.fromUser {
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.quaternary.opacity(0.8)))
            }
            .font(.system(size: 14))
        } else {
            Reply(message: message)
        }
    }
}

/// One answer: a small kicker from its note, a badge for its leading emoji, a red card for a failure,
/// and text where amounts stand out, gains and losses are colored, links and long hex are short.
struct Reply: View {
    let message: Message
    /// What an execution came to: a green check instead of the emoji.
    var outcome = false

    var body: some View {
        let (emoji, text) = ChatText.leadingEmoji(message.text)
        VStack(alignment: .leading, spacing: 5) {
            if let note = message.note { kicker(note) }
            if text.hasPrefix("Failed: ") {
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
                    styled(emoji.map { "\($0) \(text)" } ?? text).padding(.top, 5)
                }
            } else if let list = Checklist(text) {
                ChecklistCard(list: list)
            } else if let emoji {
                HStack(alignment: .top, spacing: 10) {
                    Text(emoji).font(.system(size: 15))
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.7)))
                    styled(text).padding(.top, 5)
                }
            } else {
                styled(text)
            }
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func styled(_ text: String) -> some View {
        Text(ChatText.styled(text)).textSelection(.enabled).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    /// «gpt-6-sol · from your portfolio and history» → ✦ GPT 6 SOL · FROM YOUR PORTFOLIO AND HISTORY; «incoming» in green.
    @ViewBuilder private func kicker(_ note: String) -> some View {
        let fromModel = note.hasSuffix("from your portfolio and history")
        let parts = note.components(separatedBy: " · ")
        let label = fromModel && parts.count > 1 ? ([LLMCatalog.displayName(model: parts[0])] + parts.dropFirst()).joined(separator: " · ") : note
        HStack(spacing: 4) {
            if fromModel { Image(systemName: "sparkles") }
            if note == "incoming" { Image(systemName: "arrow.down.circle.fill") }
            Text(label.uppercased()).tracking(0.6)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(note == "incoming" ? AnyShapeStyle(Brand.profit) : AnyShapeStyle(.tertiary))
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
                        icon(item.mark).font(.system(size: 12, weight: .semibold)).frame(width: 14)
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
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
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
                Text(ChatText.styled(head)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if let rest, !rest.isEmpty {
                    Text(ChatText.styled(rest, emphasis: false)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(rest)
                }
            }
            .textSelection(.enabled)
            .padding(.bottom, last ? 0 : 12)
        }
    }
}

enum ChatText {
    /// «💸 Received…» → («💸», «Received…»); nil when the text starts with a letter.
    static func leadingEmoji(_ text: String) -> (String?, String) {
        guard let first = text.first, first.unicodeScalars.first?.properties.isEmojiPresentation == true
                || first.unicodeScalars.count > 1 && first.unicodeScalars.first?.properties.isEmoji == true else { return (nil, text) }
        return (String(first), String(text.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    /// Markdown as the model writes it, then: links → «Arbiscan ↗», 0x… → «0x2E8c…1e18», signed numbers in
    /// profit or loss colors, amounts («2 USDC», «$0.24») bold unless `emphasis` is off.
    static func styled(_ text: String, emphasis: Bool = true) -> AttributedString {
        let key = "\(emphasis)\u{0}\(text)"
        if let hit = cache[key] { return hit }
        let s = parse(text, emphasis: emphasis)
        cache[key] = s
        return s
    }

    /// The chat redraws on every keystroke in the field; each message is parsed once.
    // ponytail: grows with the messages seen this run (hundreds of short strings); evict if chats get huge.
    private static var cache: [String: AttributedString] = [:]

    private static func parse(_ text: String, emphasis: Bool) -> AttributedString {
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
            return short
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
