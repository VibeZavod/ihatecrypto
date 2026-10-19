import AppKit
import IhatecryptoCore
import SwiftUI
import TradeExecution

/// The chat's field: the draft as plain text, each «$SOL» in it drawn as the token — its logo and ticker on a chip
/// (TokenMentions). A chip is one character in the field: ← → step over it and ⌫ takes it whole; the draft keeps «$SOL».
/// An NSTextView: SwiftUI's TextField draws only text.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    /// Where the caret is, as a UTF-16 offset in `text`.
    @Binding var caret: Int?
    /// Set to move the caret there (a pick from the «/», «@» or «$» list); cleared once it's there.
    @Binding var moveCaret: Int?
    /// Set to select that part of the text, the field taking the keys (a button's amount to type over); cleared once done.
    var select: Binding<NSRange?> = .constant(nil)
    var maxLines = 8
    /// Return, ↑, ↓, Tab, Esc: true when the composer took the key.
    var onKey: (Key) -> Bool
    /// How many of the contracts in the text are looked up: a change draws their chips again, now with a name.
    var known = 0
    /// What a chip shows for a token: its name (nil: the ticker as written) and its picture on the network, used when the
    /// app has no logo of its own for it (TokenLogo). A contract's comes from its market (TokenLookup).
    var face: (String) -> (label: String?, icon: URL?)

    enum Key { case submit, up, down, tab, escape }

    static var font: NSFont { _ = BrandFonts.ready; return NSFont(name: "Onest", size: 14) ?? .systemFont(ofSize: 14) }
    static let inset = NSSize(width: 0, height: 8)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = FieldView(usingTextLayoutManager: false)
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.isRichText = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = Self.font
        view.textColor = .labelColor
        view.insertionPointColor = Coordinator.accent
        view.textContainerInset = Self.inset
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.typingAttributes = Coordinator.base
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = view
        context.coordinator.view = view
        context.coordinator.show(text, caret: moveCaret ?? text.utf16.count)
        // The field takes the keys when the window opens, as the TextField did.
        DispatchQueue.main.async { if view.window?.firstResponder === view.window { view.window?.makeFirstResponder(view) } }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        let looked = c.parent.known != known
        c.parent = self
        if looked, c.draft() == text { c.redraw() }
        if c.draft() != text {
            c.show(text, caret: moveCaret ?? text.utf16.count)
        } else if let at = moveCaret {
            c.place(at)
        }
        if moveCaret != nil { DispatchQueue.main.async { moveCaret = nil } }
        if let r = select.wrappedValue, c.draft() == text, let view = c.view {
            let start = Coordinator.storageOffset(r.location, in: text), end = Coordinator.storageOffset(r.location + r.length, in: text)
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
            DispatchQueue.main.async { select.wrappedValue = nil }
        }
    }

    /// One line up to `maxLines`, then it scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let view = nsView.documentView as? NSTextView, let storage = view.textStorage else { return nil }
        let width = proposal.width ?? 300
        let padding = view.textContainer?.lineFragmentPadding ?? 5
        let line = ceil(NSLayoutManager().defaultLineHeight(for: Self.font))
        let used = storage.length == 0 ? line : ceil(storage.boundingRect(with: NSSize(width: max(width - 2 * padding, 20), height: .greatestFiniteMagnitude),
                                                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        return CGSize(width: width, height: min(max(used, line), line * CGFloat(maxLines)) + 2 * Self.inset.height)
    }

    // MARK: Chips, for the field and the chat's bubbles

    /// How far a chip sits below the text's baseline.
    static var chipDrop: CGFloat { font.descender - 1.5 }

    /// A token's picture: the app's own logo for a ticker (TokenLogo), else the token's picture from the network once
    /// fetched — `loaded` runs when it arrives. A contract has no logo of the app's: only its market's. Fetched as every
    /// RemoteIcon is: size-capped, and decoded off the main thread at a size for the chip's ~15 pt disc.
    static func picture(_ ticker: String, icon: URL?, loaded: @escaping @MainActor () -> Void = {}) -> NSImage? {
        if let own = TokenLogo.image(ticker.lowercased()) { return own }
        guard let icon else { return nil }
        if let hit = pictures[icon] { return hit }
        if asked.insert(icon).inserted {
            Task { @MainActor in
                guard let image = await RemoteIconLoader.shared.image(icon, pixels: 48) else { return }
                pictures[icon] = NSImage(cgImage: image, size: .zero)
                loaded()
            }
        }
        return nil
    }
    private static var pictures: [URL: NSImage] = [:]
    private static var asked = Set<URL>()

    /// The label on a pill of the accent's tint, the picture on a white disc at its start (its first letter without
    /// one). Drawn once into pixels in `appearance`: an NSImage drawing handler may be called off the main thread, and
    /// this module's code runs on the main actor.
    static func chipImage(_ text: String, picture: NSImage?, appearance: NSAppearance, scale: CGFloat = 2) -> NSImage {
        // Kept: the field and every message with a «$» ask again on each pass. A picture counts by identity (TokenLogo and
        // `pictures` keep each one); the entry holds it, so its identifier can't go to another image meanwhile.
        let key = "\(text)|\(picture.map { "\(ObjectIdentifier($0))" } ?? "-")|\(appearance.name.rawValue)|\(scale)"
        if let hit = chips[key], hit.picture === picture { return hit.image }
        let label = text as NSString
        let bold = NSFont(descriptor: font.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]]),
                          size: font.pointSize - 1) ?? font
        let ink: [NSAttributedString.Key: Any] = [.font: bold, .foregroundColor: NSColor.labelColor]
        let textSize = label.size(withAttributes: ink)
        let h = ceil(font.ascender - font.descender) + 3, disc = h - 6
        let w = ceil(3 + disc + 5 + textSize.width + 8)
        let rect = NSRect(x: 0, y: 0, width: w, height: h)
        let image = NSImage(size: rect.size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return image }
        rep.size = rect.size
        let accent = Coordinator.accent
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: h / 2 - 0.5, yRadius: h / 2 - 0.5)
            accent.withAlphaComponent(0.14).setFill()
            pill.fill()
            accent.withAlphaComponent(0.45).setStroke()
            pill.lineWidth = 1
            pill.stroke()
            let circle = NSRect(x: 3, y: 3, width: disc, height: disc)
            if let picture {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: circle).fill()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(ovalIn: circle).addClip()
                picture.draw(in: circle)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                accent.withAlphaComponent(0.3).setFill()
                NSBezierPath(ovalIn: circle).fill()
                let letter = String(label.substring(to: min(1, label.length))) as NSString
                let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: disc * 0.55, weight: .bold), .foregroundColor: NSColor.labelColor]
                let s = letter.size(withAttributes: small)
                letter.draw(at: NSPoint(x: circle.midX - s.width / 2, y: circle.midY - s.height / 2), withAttributes: small)
            }
            label.draw(at: NSPoint(x: 3 + disc + 5, y: (h - textSize.height) / 2), withAttributes: ink)
        }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        if chips.count >= 200 { chips.removeAll() }
        chips[key] = (picture, image)
        return image
    }
    private static var chips: [String: (picture: NSImage?, image: NSImage)] = [:]

    final class FieldView: NSTextView {
        weak var coordinator: Coordinator?

        /// Only text comes in: a chip is made from «$TICKER», never pasted.
        override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

        /// A copied chip is «$SOL» again.
        override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
            guard let storage = textStorage else { return super.writeSelection(to: pboard, types: types) }
            let text = selectedRanges.map(\.rangeValue).map { Coordinator.plain(storage.attributedSubstring(from: $0)) }.joined()
            pboard.clearContents()
            return pboard.setString(text, forType: .string)
        }

        /// The chips are pictures drawn in the appearance they were made in.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            coordinator?.redraw()
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var view: FieldView?
        /// The field is being set from the draft: its own change and caret callbacks don't echo back.
        private var applying = false

        static let accent = NSColor(srgbRed: 1, green: 0x7A / 255, blue: 0x2F / 255, alpha: 1)
        /// The ticker a chip's character stands for.
        static let token = NSAttributedString.Key("ihatecryptoToken")
        static var base: [NSAttributedString.Key: Any] { [.font: ComposerField.font, .foregroundColor: NSColor.labelColor] }

        init(_ parent: ComposerField) { self.parent = parent }

        /// The field's text as the draft: each chip as «$TICKER», a space after it unless a space or a mark follows —
        /// «$SOL» runs into nothing, or it would read as another ticker (or none).
        static func plain(_ s: NSAttributedString) -> String {
            var out = ""
            let ns = s.string as NSString
            var at = 0
            while at < ns.length {
                let range = NSRange(location: at, length: 1)
                if let ticker = s.attribute(token, at: at, effectiveRange: nil) as? String {
                    out += "$" + ticker
                    let next = at + 1 < ns.length ? ns.substring(with: NSRange(location: at + 1, length: 1)).first : nil
                    if let next, !next.isWhitespace, !",.;:!?)»\"'".contains(next) { out += " " }
                } else {
                    let ch = ns.substring(with: range)
                    if ch != "\u{FFFC}" { out += ch }
                }
                at += 1
            }
            return out
        }

        /// Each chip's place in the field and its ticker.
        static func tickers(_ s: NSAttributedString) -> [(Int, String)] {
            var out: [(Int, String)] = []
            s.enumerateAttribute(token, in: NSRange(location: 0, length: s.length)) { value, range, _ in
                if let ticker = value as? String { for i in range.location..<range.upperBound { out.append((i, ticker)) } }
            }
            return out
        }

        func draft() -> String { view?.textStorage.map(Self.plain) ?? "" }

        /// Draws `text` with its mentions as chips, the caret at `caret` (UTF-16 offset in `text`).
        func show(_ text: String, caret: Int) {
            guard let view, let storage = view.textStorage else { return }
            applying = true
            storage.setAttributedString(render(text))
            view.typingAttributes = Self.base
            applying = false
            place(caret)
        }

        /// The caret at `caret` in the draft.
        func place(_ caret: Int) {
            guard let view else { return }
            let at = min(Self.storageOffset(caret, in: parent.text), view.textStorage?.length ?? 0)
            guard view.selectedRange() != NSRange(location: at, length: 0) else { return }
            applying = true
            view.setSelectedRange(NSRange(location: at, length: 0))
            applying = false
        }

        func redraw() {
            let text = draft(), caret = currentCaret(in: text)
            show(text, caret: caret)
        }

        private func render(_ text: String) -> NSAttributedString {
            let out = NSMutableAttributedString(string: text, attributes: Self.base)
            for m in TokenMentions.find(text).reversed() {
                let chip = NSMutableAttributedString(attachment: chip(m.ticker))
                chip.addAttributes(Self.base, range: NSRange(location: 0, length: chip.length))
                chip.addAttribute(Self.token, value: m.ticker, range: NSRange(location: 0, length: chip.length))
                out.replaceCharacters(in: NSRange(m.range, in: text), with: chip)
            }
            return out
        }

        /// A draft offset in the field: a mention is one character there; inside one, the caret goes after it.
        static func storageOffset(_ d: Int, in text: String) -> Int {
            var shift = 0
            for m in TokenMentions.find(text) {
                let start = m.range.lowerBound.utf16Offset(in: text), end = m.range.upperBound.utf16Offset(in: text)
                if d >= end { shift += end - start - 1 } else if d > start { return start - shift + 1 } else { break }
            }
            return d - shift
        }

        /// The caret as a draft offset: the field's text before it, as the draft.
        private func currentCaret(in text: String) -> Int {
            guard let view, let storage = view.textStorage else { return text.utf16.count }
            let at = min(view.selectedRange().upperBound, storage.length)
            return min(Self.plain(storage.attributedSubstring(from: NSRange(location: 0, length: at))).utf16.count, text.utf16.count)
        }

        func textDidChange(_ notification: Notification) {
            guard !applying, let view, let storage = view.textStorage else { return }
            let text = Self.plain(storage)
            // A mention a space just closed becomes its chip; a chip whose space went back to «$SOL» to edit.
            let chips = Self.tickers(storage).map(\.1)
            let caret = currentCaret(in: text)
            if chips != TokenMentions.find(text).map(\.ticker) {
                parent.text = text
                show(text, caret: caret)
            } else {
                view.typingAttributes = Self.base
                parent.text = text
            }
            parent.caret = caret
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying else { return }
            // The field's own text: on typing the selection moves before textDidChange hands the draft over.
            let caret = currentCaret(in: draft())
            DispatchQueue.main.async { [weak self] in self?.parent.caret = caret }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift-Return breaks the line; Return sends (or puts the list's row in).
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { textView.insertNewlineIgnoringFieldEditor(nil); return true }
                _ = parent.onKey(.submit)
                return true
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.insertTab(_:)):
                if !parent.onKey(.tab) { textView.window?.selectNextKeyView(nil) }
                return true
            case #selector(NSResponder.cancelOperation(_:)): return parent.onKey(.escape)
            default: return false
            }
        }

        // MARK: The chip

        private func chip(_ ticker: String) -> NSTextAttachment {
            let picture = ComposerField.picture(ticker, icon: parent.face(ticker).icon) { [weak self] in self?.redraw() }
            // A ticker in capitals; a contract by its market's symbol as written, or short while it's looked up. Its
            // picture is the market's only: a look-alike calling itself USDC never gets the app's USDC logo.
            let image = ComposerField.chipImage(parent.face(ticker).label ?? ticker.uppercased(), picture: picture,
                                                appearance: view?.effectiveAppearance ?? NSApp.effectiveAppearance,
                                                scale: max(2, view?.window?.backingScaleFactor ?? 2))
            let chip = NSTextAttachment()
            chip.image = image
            chip.bounds = NSRect(x: 0, y: ComposerField.chipDrop, width: image.size.width, height: image.size.height)
            return chip
        }
    }
}

extension Workspace {
    /// What a «$» mention shows: a contract's or mint's market symbol and picture (TokenLookup), short until it's
    /// found; a ticker's picture from the wallet's tokens or the favorites (nil label: the ticker itself).
    func tokenFace(_ token: String) -> (label: String?, icon: URL?) {
        if TokenMentions.isAddress(token) {
            let found = contractLookups[token]?.first
            return (found?.symbol ?? "\(token.prefix(5))…\(token.suffix(4))", found?.imageURL)
        }
        return (nil, holdings.first { $0.symbol.caseInsensitiveCompare(token) == .orderedSame }?.icon
            ?? favoriteTokens.first { $0.symbol.caseInsensitiveCompare(token) == .orderedSame }?.image)
    }
}

/// The typing of a suggested prompt under way; the next one replaces it.
// ponytail: one for the app (one chat field); per window if there are ever two.
private var suggesting: Task<Void, Never>?

extension Workspace {
    /// A button's prompt put into the chat's field typed out, a few letters at a time for about half a second whatever
    /// its length (the user: «анимация печатания в чате, чтобы человек понимал куда обращать внимание»). The field
    /// follows the draft and keeps the caret at its end.
    /// `select`: a part of it to select once it's typed, to type over (the amount of «send 20 USDC to Automation»).
    func suggest(_ text: String, select: String? = nil) {
        suggesting?.cancel()
        let letters = Array(text), step = max(1, letters.count / 24)
        draft = ""
        suggesting = Task {
            for end in stride(from: step, to: letters.count, by: step) {
                draft = String(letters[..<end])
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { return }
            }
            draft = text
            if let select, let r = text.range(of: select) { draftSelection = NSRange(r, in: text) }
        }
    }
}

/// «send 0.01 SOL to …», «buy SOL for 1 USDC»: an amount of a token typed in the draft, for the slider over the field.
struct DraftAmount: Equatable {
    /// Where the number is in the draft, as UTF-16 (the field's caret is one too).
    let range: NSRange
    let value: Decimal
    let ticker: String

    /// Every «<number> <ticker>» in the text, «$SOL» chips too; the composer takes the first the wallet holds.
    static func all(_ text: String) -> [DraftAmount] {
        text.matches(of: /(\d+(?:\.\d+)?)\s*\$?([A-Za-z][A-Za-z0-9₮]{1,9})\b/).compactMap { m in
            Decimal(string: String(m.1)).map { DraftAmount(range: NSRange(m.1.startIndex..<m.1.endIndex, in: text), value: $0, ticker: String(m.2).uppercased()) }
        }
    }

    /// The place the draft names («on Base», «from Solana»), as a key; nil when it names none.
    static func place(_ text: String) -> String? {
        let t = text.lowercased()
        return (["solana", "hyperliquid"] + EVMNetwork.all.map(\.key)).first { k in
            let name = WalletCommand.placeName(k).lowercased()
            return t.contains(" on \(name)") || t.contains(" from \(name)") || t.contains(" on \(k)") || t.contains(" from \(k)")
        }
    }

    /// One step of ↑↓ and the slider: a tenth of the held amount's order — 0.01 of 0.17 SOL, 1 of 45 USDC.
    static func scale(_ held: Decimal) -> Int {
        let digits = held > 0 ? Int(floor(log10(NSDecimalNumber(decimal: held).doubleValue))) : 0
        return max(0, 1 - digits)
    }

    /// An amount as the draft takes it: `scale` places, no thousands commas.
    static func written(_ value: Decimal, scale: Int) -> String { Fmt.num(value, maxFraction: scale).replacingOccurrences(of: ",", with: "") }

    /// The draft with this number swapped for `value`.
    func replacing(in text: String, with value: Decimal, scale: Int) -> String {
        guard let r = Range(range, in: text) else { return text }
        return text.replacingCharacters(in: r, with: Self.written(value, scale: scale))
    }
}

/// Over the chat's field while the draft says an amount of a token the wallet holds: how much of it that is, in dollars
/// too, and a slider and 25 % / 50 % / Max to set it; ↑↓ with the caret on the number step it. Nothing is sent: Return does.
struct AmountSlider: View {
    @Environment(Workspace.self) private var ws
    let amount: DraftAmount
    let held: Decimal
    let place: String

    var body: some View {
        let scale = DraftAmount.scale(held)
        let price = Stablecoins.isDollar(amount.ticker) ? 1 : ws.markets[amount.ticker]?.markPx
            ?? (ws.holdings + (ws.solana?.tokens ?? [])).first { $0.symbol.uppercased() == amount.ticker && $0.chain == place }?.price
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TokenLogo(name: amount.ticker.lowercased(), size: 18, round: true)
                Text("\(Fmt.num(amount.value, maxFraction: 8)) \(amount.ticker)").font(.ui(13, .bold)).monospacedDigit()
                    .foregroundStyle(amount.value > held ? AnyShapeStyle(Brand.loss) : AnyShapeStyle(.primary))
                Text(ws.say("of \(Fmt.num(held, maxFraction: 6)) on \(WalletCommand.placeName(place))",
                            "из \(Fmt.num(held, maxFraction: 6)) на \(WalletCommand.placeName(place))",
                            "de \(Fmt.num(held, maxFraction: 6)) en \(WalletCommand.placeName(place))"))
                    .font(.ui(11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let price { Text("≈ \(Fmt.usd(amount.value * price))").font(.ui(12, .semibold)).monospacedDigit().foregroundStyle(.secondary) }
            }
            HStack(spacing: 6) {
                Slider(value: Binding(get: { held > 0 ? min(1, NSDecimalNumber(decimal: amount.value / held).doubleValue) : 0 },
                                      set: { set((held * Decimal($0)).rounded(scale, .down), scale: scale) }))
                    .controlSize(.small).tint(Brand.accent)
                    .accessibilityLabel(ws.say("Amount", "Сумма", "Cantidad"))
                ForEach([25, 50, 100], id: \.self) { pct in
                    Button { set(pct == 100 ? held : (held * Decimal(pct) / 100).rounded(scale, .down), scale: pct == 100 ? 18 : scale) } label: {
                        Text(pct == 100 ? "Max" : "\(pct)%").font(.ui(11, .semibold)).padding(.horizontal, 8).frame(height: 22)
                            .background(Capsule().strokeBorder(Brand.cardBorder))
                    }
                    .buttonStyle(.plain).pointerStyle(.link)
                }
            }
            Text(ws.say("Cursor on the number: ↑ ↓ change it · Return sends", "Курсор на числе: ↑ ↓ меняют сумму · Return — отправить",
                        "Cursor en el número: ↑ ↓ lo cambian · Return envía"))
                .font(.ui(10)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.glassFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.glassRim))
        .transition(.opacity)
    }

    private func set(_ value: Decimal, scale: Int) {
        // The number where it is now: the slider's binding can outlive the text it was drawn for, and a stale range cut
        // into the words around it.
        guard let now = DraftAmount.all(ws.draft).first(where: { $0.ticker == amount.ticker }) else { return }
        ws.draft = now.replacing(in: ws.draft, with: value, scale: scale)
    }
}

extension Workspace {
    /// What the wallet holds of a draft's token, and where: at the place the draft names, else SOL on Solana, USDC where
    /// there's most, another token where most of it is. nil when none is held.
    func draftHeld(_ ticker: String, place: String?) -> (amount: Decimal, place: String)? {
        if let place, let x = held(ticker, on: place) { return x > 0 ? (x, place) : nil }
        let found: [(Decimal, String)] = switch ticker {
        case "SOL": [(solana?.sol ?? 0, "solana")]
        case "USDC": (["solana", "hyperliquid"] + EVMNetwork.all.map(\.key)).compactMap { k in usdc(on: k).map { ($0, k) } }
        default: (holdings + (solana?.tokens ?? [])).filter { $0.symbol.uppercased() == ticker }.map { ($0.amount, $0.chain) }
        }
        return found.max { $0.0 < $1.0 }.flatMap { $0.0 > 0 ? (amount: $0.0, place: $0.1) : nil }
    }
}
