import SwiftUI

/// The first screen, on a Mac with no wallet and no watched address yet (design: «C01 · First screen · final» on the
/// onboarding canvas). The logo, the slogan, and a demo on the dotted canvas: the coin cursor types a request, its
/// answer lands as a card, then a money move is laid out card by card — the app's own route cards — and confirmed.
/// Three requests to pick from, played in turn. A wallet ends it by itself; «Look around first» ends it by hand.
/// In English, Spanish or Russian: the Mac's language first, the flags on the right switch it. The route cards and
/// Confirm stay English, as in the app; what's typed follows the language, as the chat does.
/// Drawn as one 1280×800 composition, centered, and shrunk to fit a smaller window.
struct WelcomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    let lookAround: () -> Void
    @State private var scenario = 0
    /// Bumped to play again: a chip, or the end of a run.
    @State private var round = 0
    @State private var play = Playback()
    /// The buttons start the onboarding (Onboarding.swift): its first step and which way it goes.
    @AppStorage("onboardingStep") private var onboardingStep = ""
    @AppStorage("onboardingPath") private var onboardingPath = OnboardingPath.fresh.rawValue
    /// A flag's pick; -1 until then, and the Mac's language decides.
    @AppStorage("welcomeLanguage") private var picked = -1
    private var lang: WelcomeLanguage { WelcomeLanguage(rawValue: picked) ?? .system }

    static let size = CGSize(width: 1280, height: 800)

    var body: some View {
        GeometryReader { geo in
            composition
                .frame(width: Self.size.width, height: Self.size.height)
                .scaleEffect(min(1, geo.size.width / Self.size.width, geo.size.height / Self.size.height))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .background { ZStack { Brand.canvas; DotGrid() }.ignoresSafeArea() }
        .task(id: round) { await run(Self.scenarios[scenario]) }
    }

    // MARK: The composition

    private var composition: some View {
        let s = Self.scenarios[scenario]
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 18) {
                LalaLogo(size: 84)
                Text("ihatecrypto").font(.brand(60))
            }
            .position(x: 640, y: 94)
            Text(lang.pick("Even crypto hates crypto.", "Hasta la cripto odia la cripto.", "Даже крипта ненавидит крипту."))
                .font(.ui(22, .bold)).position(x: 640, y: 170)
            Button(lang.pick("Look around first", "Explorar primero", "Сначала осмотреться"), action: lookAround)
                .buttonStyle(.plain).font(.ui(13, .semibold)).foregroundStyle(Brand.accentInk).pointerStyle(.link)
                .position(x: 1190, y: 36)

            input.frame(width: 640, height: 56).opacity(play.inputShown ? 1 : 0).position(x: 640, y: 240)
            chips.position(x: 640, y: 296)
            stage(s).opacity(play.gone ? 0 : 1).allowsHitTesting(false).accessibilityHidden(true)

            languages.position(x: 1236, y: 400)

            HStack(spacing: 12) {
                welcomeButton(lang.pick("Get started", "Empezar", "Начать"), primary: true) { start(.fresh) }
                welcomeButton(lang.pick("I already have a wallet", "Ya tengo una billetera", "У меня уже есть кошелёк"), primary: false) { start(.bring) }
            }
            .position(x: 640, y: 676)
            Label(lang.pick("Keys stay sealed in this Mac's Secure Enclave", "Las claves quedan selladas en el Secure Enclave de este Mac",
                            "Ключи запечатаны в Secure Enclave этого Mac"), systemImage: "lock")
                .font(.ui(12.5, .medium)).foregroundStyle(.secondary)
                .position(x: 640, y: 746)

            CoinCursor(mood: play.mood)
                .offset(x: play.cursor.x - 1, y: play.cursor.y - 1)
                .opacity(play.cursorShown ? 1 : 0)
        }
    }

    /// The field the cursor types into: it only shows the demo, the chat itself is on the canvas.
    private var input: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Text(play.text.isEmpty ? lang.pick("Say what you want", "Di lo que quieres", "Скажи, что нужно") : play.text)
                    .foregroundStyle(play.text.isEmpty ? .secondary : .primary).lineLimit(1)
                Rectangle().fill(Brand.accent).frame(width: 2, height: 20)
            }
            .font(.ui(17, .medium)).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "mic").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
            Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(Brand.onAccent)
                .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 11).fill(Brand.accent))
        }
        .padding(.leading, 20).padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .environment(\.colorScheme, scheme)
        .glassEffect(.regular.tint(Brand.glassTint), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(Self.scenarios.indices, id: \.self) { i in
                Button { scenario = i; round += 1 } label: {
                    Label(Self.scenarios[i].chip[lang.rawValue], systemImage: Self.scenarios[i].icon)
                        .font(.ui(12.5, .semibold)).foregroundStyle(i == scenario ? .primary : .secondary)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Brand.card))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(i == scenario ? Brand.accent : Brand.cardBorder, lineWidth: 1.5))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .modifier(HoverLift(radius: 9))
                .help("«\(Self.scenarios[i].order[lang.rawValue])»")
            }
        }
    }

    /// The screen's language, as round flags down the right side; the chosen one ringed.
    private var languages: some View {
        VStack(spacing: 10) {
            ForEach(WelcomeLanguage.allCases, id: \.self) { l in
                Button { picked = l.rawValue; round += 1 } label: {
                    Flag(language: l).frame(width: 28, height: 28)
                        .padding(3)
                        .overlay(Circle().strokeBorder(Brand.accent, lineWidth: 2).opacity(l == lang ? 1 : 0))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(l.name)
                .accessibilityLabel(l.name)
                .accessibilityAddTraits(l == lang ? .isSelected : [])
            }
        }
        .padding(7)
        .environment(\.colorScheme, scheme)
        .glassEffect(.regular.tint(Brand.glassTint), in: Capsule())
    }

    /// The request's answer on the left, the move's route on the right, Confirm under it; laid out as the 0.8 scale
    /// of the canvas's own sizes (a route card is 236 there).
    private func stage(_ s: Scenario) -> some View {
        ZStack(alignment: .topLeading) {
            bubble(s.ask[lang.rawValue]).opacity(play.asked >= 1 ? 1 : 0).offset(x: 170, y: 330)
            bubble(s.order[lang.rawValue]).opacity(play.asked >= 2 ? 1 : 0).offset(x: 479, y: 330)
            InfoCard(info: s.info, drawn: play.drawn)
                .frame(width: 264, height: 189).opacity(play.info ? 1 : 0).offset(x: 170, y: 370)
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { i in
                    if i > 0 { StepArrow(solid: play.states[i] != .next, width: 32).opacity(play.placed > i ? 1 : 0) }
                    RouteCard(step: s.steps[i], state: play.states[i], width: 189).opacity(play.placed > i ? 1 : 0)
                }
            }
            .offset(x: 479, y: 370)
            confirmFace(s).opacity(play.confirm == .none ? 0 : 1).offset(x: 683, y: 581)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    private func bubble(_ text: String) -> some View {
        // What the person typed: ink on the canvas, so it reads in both modes.
        Text(text).font(.ui(12.5, .medium)).foregroundStyle(Color(light: 0xFFFFFF, dark: 0x111111)).lineLimit(1)
            .padding(.horizontal, 11).frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(light: 0x111111, dark: 0xF2F3F5)))
    }

    /// The route's Confirm as the cursor presses it: orange, then Touch ID, then what was done.
    private func confirmFace(_ s: Scenario) -> some View {
        let (text, icon, fill, ink): (String, String, Color, Color) = switch play.confirm {
        case .touch: ("Touch ID", "touchid", Color(light: 0x111111, dark: 0xF2F3F5), Color(light: 0xFFFFFF, dark: 0x111111))
        case .done: (s.done, "checkmark", Brand.profit.opacity(0.12), Brand.profit)
        default: ("Confirm", "touchid", Brand.accent, Brand.onAccent)
        }
        return Label(text, systemImage: icon).font(.ui(13.5, .bold)).foregroundStyle(ink)
            .frame(width: 224, height: 38).background(RoundedRectangle(cornerRadius: 10).fill(fill))
    }

    private func start(_ path: OnboardingPath) {
        onboardingPath = path.rawValue
        onboardingStep = OnboardingStep.model.rawValue
    }

    private func welcomeButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.ui(15, .semibold)).foregroundStyle(primary ? Brand.onAccent : .primary)
                .padding(.horizontal, primary ? 30 : 22).frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(primary ? Brand.accent : Brand.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(primary ? Brand.accent : Brand.cardBorder))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .modifier(HoverLift(radius: 12))
    }

    // MARK: Playing

    /// Where the cursor's tip goes, in the composition: the field, its send button, the answer card, each route card
    /// (bottom right, as on the canvas) and Confirm.
    private enum Spot {
        static let input = CGPoint(x: 390, y: 244), send = CGPoint(x: 932, y: 240), info = CGPoint(x: 404, y: 533)
        static let confirm = CGPoint(x: 794, y: 606)
        static func card(_ i: Int) -> CGPoint { CGPoint(x: 638 + 221 * CGFloat(i), y: 533) }
    }

    private struct Playback {
        var cursor = CGPoint(x: 1180, y: 760)
        var cursorShown = false
        var mood = LalaLogo.Mood.thinking
        var inputShown = false
        var text = ""
        /// The requests sent so far.
        var asked = 0
        var info = false
        var drawn = false
        var placed = 0
        var states: [StepState] = [.ready, .ready, .ready]
        var confirm = Press.none
        var gone = true

        enum Press { case none, confirm, touch, done }

        /// Without motion: the end of a run, all at once.
        static let finished = Playback(cursorShown: false, mood: .done, inputShown: true, asked: 2, info: true, drawn: true, placed: 3,
                                       states: [.done, .done, .done], confirm: .done, gone: false)
    }

    /// One run of a request, about 20 s; then the next one. A chip's click cancels it and starts its own.
    private func run(_ s: Scenario) async {
        guard !reduceMotion else { play = .finished; return }
        play = Playback()
        func pause(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }
        func fade(_ change: () -> Void) { withAnimation(.easeOut(duration: 0.25), change) }
        func move(_ to: CGPoint, _ seconds: Double = 0.75) {
            withAnimation(.timingCurve(0.45, 0, 0.25, 1, duration: seconds)) { play.cursor = to }
        }
        func type(_ text: String) async throws {
            for i in text.indices {
                play.text = String(text[...i])
                try await pause(34 + text.distance(from: text.startIndex, to: i) * 7 % 30)
            }
        }
        do {
            try await pause(300); fade { play.gone = false }
            try await pause(600); fade { play.cursorShown = true }
            try await pause(300); move(Spot.input)
            try await pause(800); fade { play.inputShown = true }
            try await pause(250); try await type(s.ask[lang.rawValue])
            try await pause(250); move(Spot.send, 0.45)
            try await pause(500); fade { play.text = ""; play.asked = 1 }
            try await pause(100); move(Spot.info)
            try await pause(750); fade { play.info = true }
            try await pause(150); withAnimation(.easeOut(duration: 1.4)) { play.drawn = true }
            try await pause(1700); move(Spot.input)
            try await pause(800); try await type(s.order[lang.rawValue])
            try await pause(250); move(Spot.send, 0.45)
            try await pause(500); fade { play.text = ""; play.asked = 2 }
            // Laid out as the canvas does it: the cursor puts a card down every 420 ms, each fading in where it stands.
            for i in 0..<3 {
                try await pause(i == 0 ? 100 : 0); move(Spot.card(i), i == 0 ? 0.75 : 0.38)
                try await pause(i == 0 ? 800 : 420); fade { play.placed = i + 1 }
            }
            try await pause(550); fade { play.cursorShown = false }
            try await pause(250); fade { play.confirm = .confirm }
            try await pause(500); fade { play.cursorShown = true }; move(Spot.confirm)
            try await pause(850); fade { play.confirm = .touch; play.mood = .tuning; play.states = [.touch, .next, .next] }
            try await pause(1000); fade { play.states = [.done, .now, .next]; play.mood = .thinking }
            try await pause(1100); fade { play.states = [.done, .done, .now] }
            try await pause(1000); fade { play.states = [.done, .done, .done]; play.confirm = .done; play.mood = .done }
            try await pause(2600); fade { play.cursorShown = false }
            try await pause(300); withAnimation(.easeOut(duration: 0.45)) { play.gone = true }
            try await pause(600)
            scenario = (scenario + 1) % Self.scenarios.count
            round += 1
        } catch {}
    }

    // MARK: The requests

    private struct Scenario {
        /// English, Spanish, Russian: WelcomeLanguage's order.
        let chip: [String]
        let icon: String
        /// The first request, answered with a card; the second, a money move.
        let ask: [String]
        let order: [String]
        let info: Info
        let steps: [ActivityBubble]
        let done: String
    }

    fileprivate struct Info {
        let label: String
        let title: String
        /// AssetBadge's coin: a logo, or a drawn sign for oil.
        let asset: String
        /// A price line (up or down), or a balance.
        var up: Bool?
        var amount = ""
        var note = ""
    }

    private static func step(_ label: String, _ title: String, _ line: String, _ fill: RouteFill) -> ActivityBubble {
        ActivityBubble(kind: "route", label: label, title: title, lines: [line], fill: fill)
    }

    private static let scenarios = [
        Scenario(chip: ["Buy Tesla on Robinhood", "Comprar Tesla en Robinhood", "Купить Tesla на Robinhood"], icon: "chart.line.uptrend.xyaxis",
                 ask: ["show me the Tesla chart", "muéstrame el gráfico de Tesla", "покажи график теслы"],
                 order: ["buy $10 of Tesla on Robinhood", "compra $10 de Tesla en Robinhood", "купи теслу на $10 на robinhood"],
                 info: Info(label: "CHART · ROBINHOOD", title: "Tesla · TSLA", asset: "TSLA", up: true),
                 steps: [step("FROM · BASE", "10 USDC", "Your wallet on Base", .base),
                         step("BRIDGE · RELAY", "Base → Robinhood", "10 USDC across", .relay),
                         step("BUY · ROBINHOOD", "$10 → TSLA", "Stock token, in your wallet", .robinhood)],
                 done: "Done · TSLA in your wallet"),
        Scenario(chip: ["Send from Solana", "Enviar desde Solana", "Отправить с Solana"], icon: "paperplane",
                 ask: ["show my Solana wallet", "muéstrame mi billetera de Solana", "покажи мой кошелёк на solana"],
                 order: ["send 20 USDC from Solana to Bybit", "envía 20 USDC de Solana a Bybit", "отправь 20 USDC с solana на bybit"],
                 info: Info(label: "WALLET · SOLANA", title: "Solana", asset: "SOL", amount: "20 USDC", note: "Ready to send"),
                 steps: [step("FROM · SOLANA", "20 USDC", "Your wallet on Solana", .solana),
                         step("CHECK · ADDRESS BOOK", "Bybit", "Saved and approved", .check),
                         step("TO · BYBIT", "20 USDC → Bybit", "Your exchange account", .solana)],
                 done: "Done · 20 USDC sent"),
        Scenario(chip: ["Short oil by the book", "Corto en petróleo con reglas", "Шорт нефти по правилам"], icon: "slider.horizontal.3",
                 ask: ["show me the oil chart", "muéstrame el gráfico del petróleo", "покажи график нефти"],
                 order: ["short oil on a 2% pullback by the book", "corto en petróleo en un retroceso del 2% con reglas",
                         "шорт нефти на откате 2% по правилам"],
                 info: Info(label: "CHART · HYPERLIQUID", title: "Oil · CL", asset: "xyz:CL", up: false),
                 steps: [step("CHECK · RISK RULES", "2% of the account", "Stop, take at 1.5R", .check),
                         step("OPEN SHORT · OIL", "Short CL", "On a 2% pullback", .hyperliquid),
                         step("PROTECT · STOP", "Stop and take", "Placed with the order", .hyperliquid)],
                 done: "Done · short open, stop set"),
    ]
}

/// The first request's answer: a price line drawing itself in, or a wallet's balance. No numbers that would need a
/// live price: the demo shows how it looks, not a quote.
private struct InfoCard: View {
    let info: WelcomeView.Info
    let drawn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(info.label).font(.ui(9.5, .heavy)).tracking(0.6).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if info.up != nil {
                    HStack(spacing: 2) {
                        ForEach(["1D", "1W", "1M", "1Y"], id: \.self) { t in
                            Text(t).font(.ui(10, t == "1M" ? .bold : .medium)).foregroundStyle(t == "1M" ? .primary : .secondary)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(t == "1M" ? 0.06 : 0)))
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                AssetBadge(coin: info.asset, size: 24)
                Text(info.title).font(.ui(16, .bold))
            }
            .padding(.top, 9)
            Spacer(minLength: 0)
            if let up = info.up {
                let tint = up ? Brand.profit : Brand.loss
                ZStack {
                    PriceLine(up: up, closed: true).fill(tint.opacity(0.12)).opacity(drawn ? 1 : 0)
                    PriceLine(up: up, closed: false).trim(from: 0, to: drawn ? 1 : 0)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }
                .frame(height: 96)
            } else {
                Text(info.amount).font(.ui(30, .heavy)).monospacedDigit()
                Text(info.note).font(.ui(11.5)).foregroundStyle(.secondary).padding(.top, 2).padding(.bottom, 6)
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.cardBorder))
    }
}

/// A made-up price line, the same every time: up or down with some wobble; closed, the area under it.
private nonisolated struct PriceLine: Shape {
    let up: Bool
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        // A fixed walk: 25 points, each a step toward the end plus a wobble from a small deterministic sequence.
        var y = up ? 0.85 : 0.2, seed: UInt32 = up ? 11 : 5
        var points: [CGPoint] = []
        for i in 0..<25 {
            seed = seed &* 1_103_515_245 &+ 12345
            let wobble = Double(seed >> 16 & 0x7FFF) / 32767 - 0.5
            y = min(0.92, max(0.08, y + (up ? -0.028 : 0.028) + wobble * 0.14))
            points.append(CGPoint(x: rect.minX + rect.width * Double(i) / 24, y: rect.minY + rect.height * y))
        }
        var path = Path()
        path.addLines(points)
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// The first screen's languages, in the scenarios' order.
enum WelcomeLanguage: Int, CaseIterable {
    case en, es, ru

    /// The first of the Mac's preferred languages that is one of these; English otherwise.
    static var system: WelcomeLanguage {
        Locale.preferredLanguages.lazy.compactMap { code in
            switch code.prefix(2) { case "en": .en; case "es": .es; case "ru": .ru; default: nil }
        }.first ?? .en
    }

    var name: String { pick("English", "Español", "Русский") }

    func pick(_ english: String, _ spanish: String, _ russian: String) -> String {
        switch self { case .en: english; case .es: spanish; case .ru: russian }
    }
}

/// A language's flag in a circle, drawn: the US stripes and canton (no stars) for English, Spain's red-yellow-red
/// without the arms, Russia's white-blue-red.
private struct Flag: View {
    let language: WelcomeLanguage

    var body: some View {
        // (top, height) as fractions of the flag, and the color; the canvas draws them in order.
        let bands: [(CGFloat, CGFloat, Color)] = switch language {
        case .ru: [(0, 1 / 3, .white), (1 / 3, 1 / 3, Color(hex: 0x0039A6)), (2 / 3, 1 / 3, Color(hex: 0xD52B1E))]
        case .es: [(0, 1, Color(hex: 0xAA151B)), (0.25, 0.5, Color(hex: 0xF1BF00))]
        case .en: (0..<13).map { (CGFloat($0) / 13, 1.05 / 13, $0 % 2 == 0 ? Color(hex: 0xB22234) : .white) }
        }
        let canton = language == .en ? Color(hex: 0x3C3B6E) : nil
        return Canvas { context, size in
            for (y, h, color) in bands {
                context.fill(Path(CGRect(x: 0, y: y * size.height, width: size.width, height: h * size.height)), with: .color(color))
            }
            if let canton {
                context.fill(Path(CGRect(x: 0, y: 0, width: size.width * 0.5, height: size.height * 7 / 13)), with: .color(canton))
            }
        }
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
        .accessibilityHidden(true)
    }
}
