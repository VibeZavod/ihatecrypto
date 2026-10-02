import AppKit
import IhatecryptoCore
import LLMCatalog
import LLMCore
import LocalAuthentication
import SignerAPI
import SwiftUI
import UserNotifications
import WalletCore

/// After the first screen: what the app needs before the first move, one card at a time on the dotted canvas (design:
/// D00–D16 on the onboarding canvas). «Get started» makes a wallet, «I already have a wallet» brings one; both connect
/// a model first, then pick the networks, and only with Hyperliquid on approve the trading key and see the trade rules,
/// then top up and choose notifications. The step is kept in UserDefaults, so a quit comes back to it; the recovery
/// words are not: after a relaunch the words steps are passed.
enum OnboardingStep: String {
    case model, modelReady, newWallet, words, check, secure, bring, found, ledger, networks, tradingKey, rules, money, stayInTouch

    /// Which of the rail's stops it belongs to.
    var stage: OnboardingStage {
        switch self {
        case .model, .modelReady: .model
        case .newWallet, .words, .check, .bring, .found, .ledger: .wallet
        case .secure: .secure
        case .networks: .networks
        case .tradingKey, .rules: .trading
        case .money, .stayInTouch: .money
        }
    }
}

enum OnboardingStage: Int, CaseIterable {
    case model, wallet, secure, networks, trading, money

    var title: String {
        switch self {
        case .model: "Model"
        case .wallet: "Wallet"
        case .secure: "Secure"
        case .networks: "Networks"
        case .trading: "Trading"
        case .money: "Money"
        }
    }
}

/// Which button on the first screen started it.
enum OnboardingPath: String { case fresh, bring }

struct OnboardingView: View {
    @Environment(Workspace.self) private var ws
    @AppStorage("onboardingStep") private var stepRaw = ""
    @AppStorage("onboardingPath") private var pathRaw = OnboardingPath.fresh.rawValue
    @AppStorage("welcomeDone") private var welcomeDone = false
    @AppStorage(Modules.key) private var modules = ""
    @State private var history: [OnboardingStep] = []
    /// The new wallet's words: only in memory, and only until they are checked.
    @State private var words: [String]?
    /// What the signer answered for the wallet just made or imported.
    @State private var found: SignerReply?

    private var step: OnboardingStep { OnboardingStep(rawValue: stepRaw) ?? .model }
    private var path: OnboardingPath { OnboardingPath(rawValue: pathRaw) ?? .fresh }

    /// Hyperliquid on, and a wallet that can sign there: then the trading key and the rules come before the money.
    private var trades: Bool {
        Modules(stored: modules).isOn(ModuleNetwork.hyperliquid) && ws.activeWallet?.evm != nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                page
                    .id(step)
                    .transition(.opacity)
                    .frame(maxWidth: 660)
                    .padding(.top, 104).padding(.bottom, 40).padding(.horizontal, 24)
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 0) {
                HStack(spacing: 9) {
                    BrandLogo(size: 28)
                    Text("ihatecrypto").font(.brand(21))
                }
                .frame(width: 190, alignment: .leading)
                Spacer(minLength: 12)
                rail
                Spacer(minLength: 12)
                Color.clear.frame(width: 190, height: 1)
            }
            .padding(.horizontal, 28).padding(.top, 40)
        }
        .background { ZStack { Brand.canvas; DotGrid() }.ignoresSafeArea() }
        .animation(.easeOut(duration: 0.2), value: stepRaw)
        #if DEBUG
        // `-demoWords YES` with `-onboardingStep words`: the public BIP-39 test phrase, for screenshots of the words steps.
        .onAppear {
            if words == nil, UserDefaults.standard.bool(forKey: "demoWords") {
                words = "abandon ability able about above absent absorb abstract absurd abuse access accident".split(separator: " ").map(String.init)
            }
        }
        #endif
    }

    // MARK: Moving

    private func go(_ next: OnboardingStep) {
        history.append(step)
        stepRaw = next.rawValue
    }

    /// Back one card; from the first, back to the first screen.
    private func back() {
        stepRaw = history.popLast()?.rawValue ?? ""
    }

    private func finish() {
        words = nil
        stepRaw = ""
        welcomeDone = true
    }

    private func afterModel() { go(path == .fresh ? .newWallet : .bring) }
    private func afterNetworks() { go(trades ? .tradingKey : .money) }

    // MARK: The rail

    private var rail: some View {
        let stages = OnboardingStage.allCases.filter { $0 != .trading || trades }
        let current = step.stage
        return HStack(spacing: 6) {
            ForEach(stages, id: \.self) { s in
                if s != stages.first { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary) }
                let done = s.rawValue < current.rawValue, now = s == current
                HStack(spacing: 7) {
                    ZStack {
                        Circle().fill(now ? Brand.accent : done ? Brand.profit.opacity(0.14) : Color.primary.opacity(0.06))
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.profit)
                        } else {
                            Text("\((stages.firstIndex(of: s) ?? 0) + 1)").font(.ui(10.5, .bold)).foregroundStyle(now ? Brand.onAccent : .secondary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(s.title).font(.ui(12.5, .semibold)).foregroundStyle(now || done ? .primary : .secondary)
                }
                .padding(.leading, 5).padding(.trailing, 11).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 10).fill(Brand.card))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(now ? Brand.accent : Brand.cardBorder, lineWidth: now ? 1.5 : 1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.title)")
    }

    // MARK: The cards

    @ViewBuilder private var page: some View {
        switch step {
        case .model: ModelStep(next: { go(.modelReady) }, skip: afterModel, back: back)
        case .modelReady: ModelReadyStep(next: afterModel, back: back)
        case .newWallet:
            NewWalletStep(back: back) { reply in
                found = reply
                words = reply.phrase?.split(separator: " ").map(String.init)
                go(.words)
            }
        case .words:
            if let words {
                WordsStep(words: words, next: { go(.check) }, back: back)
            } else {
                WordsGoneStep { go(.secure) }
            }
        case .check:
            if let words {
                CheckStep(words: words, next: { self.words = nil; go(.secure) }, back: back)
            } else {
                WordsGoneStep { go(.secure) }
            }
        case .secure: SecureStep(next: { go(.networks) }, back: back)
        case .bring:
            BringStep(back: back, ledger: { go(.ledger) }, watched: { go(.networks) }) { reply in
                found = reply
                go(.found)
            }
        case .found: FoundStep(reply: found, next: { go(.secure) }, back: back)
        case .ledger: LedgerStep(next: { go(.networks) }, back: back)
        case .networks: NetworksStep(trades: trades, next: afterNetworks, back: back)
        case .tradingKey: TradingKeyStep(next: { go(.rules) }, back: back)
        case .rules: RulesStep(next: { go(.money) }, back: back)
        case .money: MoneyStep(next: { go(.stayInTouch) }, back: back)
        case .stayInTouch: StayInTouchStep(finish: finish, back: back)
        }
    }
}

// MARK: - The card every step sits in

/// One step: the coin with the step's face, a title and a line, what the step asks, then a quiet way back or past it on
/// the left and the step's one button on the right.
private struct OnboardingCard<Content: View, Quiet: View>: View {
    var mood: BrandLogo.Mood = .idle
    let title: String
    let subtitle: String
    let primary: String
    var icon: String?
    var busy = false
    var enabled = true
    let action: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let quiet: Quiet

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                BrandLogo(size: 56, mood: mood, animated: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.ui(25, .heavy)).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(.ui(13.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            HStack(spacing: 18) {
                quiet
                Spacer(minLength: 8)
                if busy { ProgressView().controlSize(.small) }
                OnboardingButton(title: primary, icon: icon, enabled: enabled && !busy, action: action)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Brand.card).shadow(color: .black.opacity(0.07), radius: 24, y: 12))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Brand.cardBorder))
    }
}

/// The step's orange button.
private struct OnboardingButton: View {
    let title: String
    var icon: String?
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)) }
                Text(title).font(.ui(15, .semibold))
            }
            .foregroundStyle(Brand.onAccent)
            .padding(.horizontal, 24).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.accent))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .modifier(HoverLift(radius: 12, enabled: enabled))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .keyboardShortcut(.defaultAction)
    }
}

/// A quiet text button: Back, Skip, Later.
private struct QuietButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action).buttonStyle(.plain).font(.ui(14, .semibold)).foregroundStyle(.secondary).pointerStyle(.link)
    }
}

/// A row with an icon square, a title and a line: the facts a step states.
private struct FactRow: View {
    let icon: String
    let title: String
    let line: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.accentInk)
                .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 10).fill(Brand.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(14.5, .bold))
                Text(line).font(.ui(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A tinted row a step lists things in (ways to connect, addresses, networks).
private struct Tile<Content: View>: View {
    var selected = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Brand.accent : .clear, lineWidth: 1.5))
    }
}

private func statusLine(_ text: String, ok: Bool? = nil) -> some View {
    Label(text, systemImage: ok == true ? "checkmark.circle.fill" : ok == false ? "exclamationmark.triangle.fill" : "info.circle")
        .font(.ui(12.5)).foregroundStyle(ok == true ? Brand.profit : ok == false ? Brand.loss : .secondary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - Model

private struct ModelStep: View {
    @Environment(Workspace.self) private var ws
    let next: () -> Void
    let skip: () -> Void
    let back: () -> Void
    @State private var keyProvider = "openai"
    @State private var key = ""

    /// Ways in by an API key, or a model run on this Mac; Apple's on-device model is too small for the chat.
    private var keyed: [any LLMProvider] {
        LLMCatalog.all.filter { p in
            p.info.unavailable == nil && p.info.id != "openrouter" && p.info.id != "apple" && (p.info.takesKey || p.info.kind == .local)
        }
    }

    var body: some View {
        OnboardingCard(mood: .tuning, title: "What does the chat think with?",
                       subtitle: "A model you already pay for, or one you run. It reads your words and the plan, never your keys.",
                       primary: "Continue", busy: ws.llmBusy, enabled: ws.llmClient() != nil, action: next) {
            VStack(spacing: 10) {
                way("chatgpt", "ChatGPT subscription", "Plus or Pro: sign in once in the browser", logo: "llm-openai")
                way("claude-code", "Claude subscription", "Uses the Claude Code already on this Mac", logo: "llm-claude")
                way("openrouter", "OpenRouter", "One key for many models: sign in in the browser", logo: "llm-openrouter")
                keyRow
            }
            if let status = ws.llmStatus { statusLine(status, ok: ws.llmClient() != nil) }
            Text("Apple's on-device model is too small for the chat. More ways and the model itself: Settings › Sign-ins.")
                .font(.ui(11.5)).foregroundStyle(.secondary)
        } quiet: {
            QuietButton("Back", action: back)
            QuietButton("Skip for now", action: skip)
        }
    }

    private func connected(_ id: String) -> Bool { ws.providerID == id && ws.llmClient() != nil }

    private func way(_ id: String, _ title: String, _ line: String, logo: String) -> some View {
        let p = LLMCatalog.provider(id: id)
        return Tile(selected: connected(id)) {
            TokenLogo(name: logo, size: 30).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(14.5, .bold))
                Text(line).font(.ui(12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if connected(id) {
                Label("Connected", systemImage: "checkmark.circle.fill").font(.ui(12.5, .semibold)).foregroundStyle(Brand.profit)
            } else if let p {
                if let existing = p.info.existingLoginLabel, p.info.signInLabel != nil {
                    Button(existing) { ws.providerID = id; ws.useExistingLogin() }
                        .buttonStyle(.plain).font(.ui(12, .semibold)).foregroundStyle(Brand.accentInk).pointerStyle(.link)
                }
                Button(p.info.signInLabel ?? p.info.existingLoginLabel ?? "Connect") {
                    ws.providerID = id
                    if p.info.signInLabel != nil { Task { await ws.signIn() } } else { ws.useExistingLogin() }
                }
                .disabled(ws.llmBusy)
            }
        }
    }

    private var keyRow: some View {
        Tile(selected: keyed.contains { connected($0.info.id) }) {
            Image(systemName: "key.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 6) {
                Text("An API key, or a model on this Mac").font(.ui(14.5, .bold))
                HStack(spacing: 8) {
                    Picker("Provider", selection: $keyProvider) {
                        ForEach(keyed, id: \.info.id) { Text($0.info.name).tag($0.info.id) }
                    }
                    .labelsHidden().frame(width: 170)
                    if LLMCatalog.provider(id: keyProvider)?.info.takesKey ?? false {
                        SecureField("Key", text: $key).textFieldStyle(.roundedBorder)
                        Button("Save") {
                            ws.providerID = keyProvider
                            ws.setCredential(.apiKey(key.trimmingCharacters(in: .whitespacesAndNewlines)))
                            key = ""
                        }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Button("Use it") { ws.providerID = keyProvider }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

private struct ModelReadyStep: View {
    @Environment(Workspace.self) private var ws
    let next: () -> Void
    let back: () -> Void

    private var answered: Bool { ws.llmStatus?.contains(" answered in ") ?? false }

    var body: some View {
        OnboardingCard(mood: ws.llmBusy ? .thinking : answered ? .done : .waiting,
                       title: "\(ws.provider.info.name) is connected",
                       subtitle: "A quick test, so you know it answers. \(LLMCatalog.displayName(model: ws.model)) does the talking; change it any time in the chat's menu.",
                       primary: "Continue", busy: ws.llmBusy, action: next) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    Text("Reply with one word: works").font(.ui(13)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x111111)))
                }
                HStack(alignment: .top, spacing: 9) {
                    BrandLogo(size: 24, mood: answered ? .done : .thinking)
                    Text(ws.llmBusy ? "…" : ws.llmStatus ?? "…").font(.ui(13))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 40)
                }
            }
        } quiet: {
            QuietButton("Use another", action: back)
            QuietButton("Test again") { Task { await ws.testModel() } }
        }
        .task { await ws.testModel() }
    }
}

// MARK: - A new wallet

private struct NewWalletStep: View {
    @Environment(Workspace.self) private var ws
    let back: () -> Void
    let made: (SignerReply) -> Void
    /// Off unless picked here: the wallet menu's «New test wallet…» keeps its own switch.
    @State private var test = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        OnboardingCard(mood: .idle, title: "A new wallet",
                       subtitle: "Made inside the separate signer on this Mac, which has no network access.",
                       primary: test ? "Create a test wallet" : "Create a new wallet", busy: busy, enabled: SignerClient.isAvailable, action: create) {
            VStack(alignment: .leading, spacing: 14) {
                FactRow(icon: "list.number", title: "12 recovery words",
                        line: "Made from this Mac's random number generator. They are the only way back if the Mac is lost; you see them once, next.")
                FactRow(icon: "cpu", title: "Sealed by the Secure Enclave", line: "The key never leaves the signer; nothing can read it back, ihatecrypto included.")
                FactRow(icon: "touchid", title: test ? "Signs without asking" : "Touch ID or your Mac password",
                        line: test ? "A test wallet: keep only a few dollars on it." : "Every signature asks first; one touch covers one move.")
            }
            Tile {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Test wallet: signs without asking").font(.ui(13.5, .semibold))
                    Text("For trying things out with a few dollars.").font(.ui(11.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Test wallet", isOn: $test).labelsHidden().toggleStyle(AccentSwitch())
            }
            if !SignerClient.isAvailable { statusLine("This copy has no signer (a swift run build): wallets are made in ihatecrypto.app.", ok: false) }
            if let error { statusLine(error, ok: false) }
        } quiet: {
            QuietButton("Back", action: back)
        }
    }

    private func create() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let reply = try await SignerClient().send(.createWallet(requirePresence: !test))
                guard reply.ok, reply.phrase != nil else { throw WalletError(reply.error ?? "The signer refused.") }
                await ws.loadSigner()
                made(reply)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct WordsStep: View {
    let words: [String]
    let next: () -> Void
    let back: () -> Void
    @State private var copied: Int?

    var body: some View {
        OnboardingCard(mood: .waiting, title: "Your 12 recovery words",
                       subtitle: "Write them on paper, in order. They are the only way back to this wallet if the Mac is lost or wiped; ihatecrypto won't show them again.",
                       primary: "I wrote them down", action: { wipe(); next() }) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(words.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(.ui(11.5, .semibold)).foregroundStyle(.secondary).monospacedDigit().frame(width: 18, alignment: .trailing)
                        Text(words[i]).font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                }
            }
            .textSelection(.disabled)
            statusLine("Never type them into a website, a chat or a photo. Anyone with these words owns the money.", ok: false)
            HStack(spacing: 12) {
                Button(copied == nil ? "Copy all 12 words" : "Copied", systemImage: copied == nil ? "doc.on.doc" : "checkmark", action: copy)
                Text("For a password manager: wiped from the clipboard in 60 s, kept off your other devices.")
                    .font(.ui(11.5)).foregroundStyle(.secondary)
            }
        } quiet: {
            QuietButton("Back", action: back)
        }
        // While the words are on screen, screenshots, recordings and screen sharing get a blank window: the main
        // window by its title, key or not.
        .onAppear { mainWindows.forEach { $0.sharingType = .none } }
        .onDisappear { mainWindows.forEach { $0.sharingType = .readOnly }; wipe() }
    }

    private var mainWindows: [NSWindow] { NSApp.windows.filter { $0.title == AppMain.mainTitle } }

    private func copy() {
        let change = SecretPasteboard.copy(words.joined(separator: " "))
        copied = change
        Task {
            try? await Task.sleep(for: .seconds(60))
            if copied == change { wipe() }
        }
    }

    private func wipe() {
        SecretPasteboard.wipe(copied)
        copied = nil
    }
}

/// Three of the words, by number, picked from a few shuffled ones: the paper is right before anything goes on it.
private struct CheckStep: View {
    let words: [String]
    let next: () -> Void
    let back: () -> Void
    @State private var asked: [Int] = []
    @State private var choices: [String] = []
    @State private var filled = 0
    @State private var miss: String?

    var body: some View {
        OnboardingCard(mood: filled == asked.count && !asked.isEmpty ? .done : .tuning, title: "Check three of them",
                       subtitle: "Pick the words by their numbers, from your paper.",
                       primary: "Continue", enabled: !asked.isEmpty && filled == asked.count, action: next) {
            HStack(spacing: 10) {
                ForEach(asked.indices, id: \.self) { k in
                    let i = asked[k]
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WORD \(i + 1)").font(.ui(10, .heavy)).tracking(0.6).foregroundStyle(.secondary)
                        Text(k < filled ? words[i] : " ").font(.system(size: 15, weight: .semibold, design: .monospaced))
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 62)
                    .background(RoundedRectangle(cornerRadius: 12).fill(k < filled ? Brand.profit.opacity(0.1) : Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(k == filled ? Brand.accent : .clear, lineWidth: 1.5))
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(choices, id: \.self) { w in
                    let used = asked.prefix(filled).contains { words[$0] == w }
                    Button { pick(w) } label: {
                        Text(w).font(.system(size: 13.5, weight: .semibold, design: .monospaced)).frame(maxWidth: .infinity).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Brand.card))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.cardBorder))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain).modifier(HoverLift(radius: 10, enabled: !used)).disabled(used || filled == asked.count).opacity(used ? 0.35 : 1)
                }
            }
            if let miss { statusLine(miss, ok: false) }
        } quiet: {
            QuietButton("Show the words again", action: back)
        }
        .onAppear(perform: deal)
    }

    private func deal() {
        guard asked.isEmpty else { return }
        asked = Array(words.indices.shuffled().prefix(3)).sorted()
        let others = words.indices.filter { !asked.contains($0) }.shuffled().prefix(5)
        choices = Array(Set((asked + others).map { words[$0] })).shuffled()
    }

    private func pick(_ word: String) {
        guard filled < asked.count else { return }
        if words[asked[filled]] == word {
            filled += 1
            miss = nil
        } else {
            miss = "That isn't word \(asked[filled] + 1). Look at your paper again."
        }
    }
}

/// After a relaunch the words are gone from memory, as they should be.
private struct WordsGoneStep: View {
    let next: () -> Void

    var body: some View {
        OnboardingCard(mood: .idle, title: "The words were shown once",
                       subtitle: "ihatecrypto doesn't keep them, so they aren't here after a restart. If they aren't on paper, make a new wallet from the wallet menu before putting money on this one.",
                       primary: "Continue", action: next) {
            EmptyView()
        } quiet: {
            EmptyView()
        }
    }
}

// MARK: - Secure

/// How the signer asks before a move: Touch ID where the Mac has it, the Mac's password otherwise (macOS offers it
/// with the lid closed too). One try now with the same macOS prompt. A PIN of its own is planned, not built.
private struct SecureStep: View {
    @Environment(Workspace.self) private var ws
    let next: () -> Void
    let back: () -> Void
    @State private var tried: Bool?
    @State private var error: String?
    private let touchID: Bool = {
        var e: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e)
    }()

    var body: some View {
        let test = ws.activeWallet?.test ?? false
        OnboardingCard(mood: tried == true ? .done : .tuning, title: test ? "A test wallet signs by itself" : "One touch now",
                       subtitle: test ? "It doesn't ask before a move: keep only a few dollars on it."
                       : "So the first real move is no surprise: each move asks once, and so does switching wallets.",
                       primary: test || tried == true ? "Continue" : touchID ? "Try Touch ID" : "Try the password", icon: test || tried == true ? nil : touchID ? "touchid" : "lock.fill", action: { test || tried == true ? next() : tryIt() }) {
            HStack(spacing: 10) {
                way("touchid", "Touch ID", touchID ? "On this Mac" : "No sensor here", on: touchID)
                way("lock.fill", "Mac password", touchID ? "With the lid closed" : "On this Mac", on: !touchID)
                way("circle.grid.3x3.fill", "PIN code", "Soon", on: false, soon: true)
            }
            if !test {
                HStack(spacing: 14) {
                    Image(systemName: touchID ? "touchid" : "lock.fill").font(.system(size: 34, weight: .light)).foregroundStyle(Brand.accentInk)
                        .frame(width: 72, height: 72).overlay(Circle().strokeBorder(Brand.accent, lineWidth: 2))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(touchID ? "Touch the sensor when macOS asks" : "Type your Mac's password when macOS asks").font(.ui(14.5, .bold))
                        Text("Nothing is signed now: this only shows the prompt each move will bring. The password isn't saved anywhere; macOS checks it each time.")
                            .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if tried == true { statusLine("That's how it will ask.", ok: true) }
                if let error { statusLine(error, ok: false) }
            }
        } quiet: {
            QuietButton("Back", action: back)
            if !test && tried != true { QuietButton("Skip", action: next) }
        }
    }

    private func way(_ icon: String, _ title: String, _ line: String, on: Bool, soon: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(on ? Brand.accentInk : .secondary)
            Text(title).font(.ui(13.5, .bold))
            Text(line).font(.ui(11.5)).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Brand.accent : .clear, lineWidth: 1.5))
        .opacity(soon ? 0.55 : 1)
    }

    private func tryIt() {
        error = nil
        Task {
            do {
                tried = try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show how ihatecrypto asks before each move")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Bring a wallet

private struct BringStep: View {
    @Environment(Workspace.self) private var ws
    let back: () -> Void
    let ledger: () -> Void
    let watched: () -> Void
    let imported: (SignerReply) -> Void

    enum Way: String, CaseIterable { case phrase = "Recovery phrase", key = "Private key", ledger = "Ledger", address = "Address only" }
    @State private var way = Way.phrase
    @State private var phrase = ""
    @State private var passphrase = ""
    @State private var key = ""
    @State private var solana = ""
    @State private var evm = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        OnboardingCard(mood: .tuning, title: "Bring your wallet",
                       subtitle: "From Phantom, MetaMask or any wallet. It goes only to the separate signer, which seals it with this Mac's Secure Enclave.",
                       primary: title, busy: busy, enabled: ready, action: go) {
            Picker("Way", selection: $way) { ForEach(Way.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            switch way {
            case .phrase:
                SecureField("12 or 24 words separated by spaces", text: $phrase).textFieldStyle(.roundedBorder)
                SecureField("Extra passphrase, if your wallet has one", text: $passphrase).textFieldStyle(.roundedBorder)
                Text("The same words open the same addresses here as in Phantom and MetaMask: Solana, every EVM network and NEAR.")
                    .font(.ui(12)).foregroundStyle(.secondary)
            case .key:
                SecureField("Solana key from Phantom, or EVM key from MetaMask", text: $key).textFieldStyle(.roundedBorder)
                switch key.isEmpty ? nil : Result(catching: { try ImportedKey.parse(key) }) {
                case .success(let k)?:
                    statusLine("\(k.chain): \((try? k.address()).map { AddressCheck.ends($0) }.map { "\($0.start)…\($0.end)" } ?? "?")", ok: true)
                    Text("A key opens one network only: \(k.chain). For every network, use the recovery phrase instead.")
                        .font(.ui(12)).foregroundStyle(.secondary)
                case .failure(let e)?: statusLine(e.localizedDescription, ok: false)
                case nil: Text("Phantom: Settings › Manage accounts › Show private key. MetaMask: Account details › Show private key.")
                        .font(.ui(12)).foregroundStyle(.secondary)
                }
            case .ledger:
                FactRow(icon: "cable.connector", title: "USB or Bluetooth", line: "Nano X, Stax and Flex work over Bluetooth; any Ledger over USB.")
                FactRow(icon: "lock.shield", title: "The keys stay on the device", line: "Every move shows on its screen and waits for its buttons.")
            case .address:
                TextField("Solana address", text: $solana).textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
                TextField("EVM address (0x…): Base, Arbitrum, Hyperliquid and the rest", text: $evm).textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                Text("Balances only: nothing can be signed with an address. Add a key or a phrase later from the wallet menu.")
                    .font(.ui(12)).foregroundStyle(.secondary)
            }
            if let error { statusLine(error, ok: false) }
        } quiet: {
            QuietButton("Back", action: back)
        }
    }

    private var title: String {
        switch way {
        case .phrase, .key: "Find my wallet"
        case .ledger: "Connect a Ledger"
        case .address: "Watch these"
        }
    }

    private var ready: Bool {
        switch way {
        case .phrase: SignerClient.isAvailable && phrase.split(separator: " ").count >= 12
        case .key: SignerClient.isAvailable && (try? ImportedKey.parse(key)) != nil
        case .ledger: true
        case .address:
            (solana.isEmpty || isSolanaAddress(solana)) && (evm.isEmpty || isEVMAddress(evm)) && !(solana.isEmpty && evm.isEmpty)
        }
    }

    private func go() {
        error = nil
        switch way {
        case .ledger: ledger()
        case .address:
            if !solana.isEmpty { ws.solanaAddress = solana }
            if !evm.isEmpty { ws.hlAddress = evm }
            watched()
        case .phrase, .key:
            let request: SignerRequest = way == .phrase
                ? .importMnemonic(phrase: phrase.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " "), passphrase: passphrase, requirePresence: true)
                : .importPrivateKey(key: key.trimmingCharacters(in: .whitespacesAndNewlines))
            busy = true
            Task {
                defer { busy = false }
                do {
                    let reply = try await SignerClient().send(request)
                    guard reply.ok else { throw WalletError(reply.error ?? "The signer refused.") }
                    phrase = ""; passphrase = ""; key = ""
                    await ws.loadSigner()
                    imported(reply)
                    await ws.refresh()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

/// What the phrase or key opened, to compare with the wallet it came from. A key opens one chain: the rest is offered.
private struct FoundStep: View {
    @Environment(Workspace.self) private var ws
    let reply: SignerReply?
    let next: () -> Void
    let back: () -> Void
    @AppStorage(Modules.key) private var modules = ""
    @State private var others = Others.only

    enum Others { case only, phrase }

    private var solana: String? { reply?.solanaAddress ?? ws.activeWallet?.solana }
    private var evm: String? { reply?.evmAddress ?? ws.activeWallet?.evm }
    private var near: String? { reply?.nearAddress ?? ws.activeWallet?.near }
    /// The chain a single key opened; nil for a phrase.
    private var keyChain: String? {
        guard ws.activeWallet?.kind == "solana" || ws.activeWallet?.kind == "evm" else { return nil }
        return ws.activeWallet?.kind == "solana" ? "Solana" : "EVM"
    }

    var body: some View {
        OnboardingCard(mood: .done, title: keyChain.map { "This key opens \($0)" } ?? "Found your wallet",
                       subtitle: "The addresses it opens. Check them against the wallet you came from.",
                       primary: keyChain != nil && others == .phrase ? "Enter a phrase" : "That's my wallet", action: done) {
            VStack(spacing: 8) {
                row("sol", "Solana", "Jupiter, Kamino, JitoSOL", solana)
                row("base", "EVM", "Base, Arbitrum, Hyperliquid, Robinhood Chain, Polygon, Ethereum, Tempo", evm)
                row("near", "NEAR", "NEAR Intents, 1Click", near)
            }
            if let keyChain {
                Text("What about the other networks?").font(.ui(14.5, .bold)).padding(.top, 4)
                choice(.only, "Only \(keyChain) for now", "The other networks stay off; add a wallet for them any time from the wallet menu.")
                choice(.phrase, "Use a recovery phrase instead", "A phrase opens every network at once. This key stays as a wallet you can remove.")
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Make them for me · soon").font(.ui(13.5, .bold)).foregroundStyle(.secondary)
                        Text("New addresses for the missing networks, in the same wallet.").font(.ui(11.5)).foregroundStyle(.secondary)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.cardBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            } else {
                statusLine("Compare with MetaMask and Phantom: the same phrase shows the same addresses there.")
            }
        } quiet: {
            QuietButton(keyChain == nil ? "Try another phrase" : "Try another key", action: back)
        }
    }

    private func row(_ logo: String, _ name: String, _ line: String, _ address: String?) -> some View {
        Tile {
            TokenLogo(name: logo, size: 28).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.ui(14, .bold))
                Text(line).font(.ui(11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let address, !address.isEmpty {
                let ends = AddressCheck.ends(address)
                Text("\(ends.start)…\(ends.end)").font(.system(size: 13, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.profit)
            } else {
                Text("No address yet").font(.ui(12.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func choice(_ value: Others, _ title: String, _ line: String) -> some View {
        Button { others = value } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: others == value ? "largecircle.fill.circle" : "circle").foregroundStyle(others == value ? Brand.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(13.5, .bold))
                    Text(line).font(.ui(11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(others == value ? Brand.accent : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func done() {
        if keyChain != nil, others == .phrase { back(); return }
        // A single key: the networks it can't sign on go off, so the assistant never plans a move through them.
        if keyChain != nil {
            var m = Modules(stored: modules)
            for n in ModuleNetwork.allCases {
                let has = n == .solana ? !(solana ?? "").isEmpty : n == .near ? !(near ?? "").isEmpty : !(evm ?? "").isEmpty
                if !has { m.set(n, false) }
            }
            modules = m.stored
        }
        next()
    }
}

private struct LedgerStep: View {
    @Environment(Workspace.self) private var ws
    let next: () -> Void
    let back: () -> Void

    private var state: LedgerConnect? { ws.ledgerConnect }
    private var connected: Bool { state?.busy == false && state?.problem == nil && LedgerAccount.saved?.evm != nil }

    var body: some View {
        OnboardingCard(mood: connected ? .done : state?.busy == true ? .thinking : .waiting, title: "Connect a Ledger",
                       subtitle: "The keys stay on the device: every move shows on its screen and waits for its buttons.",
                       primary: connected ? "Use this Ledger" : state == nil ? "Look for it" : "Try again", busy: state?.busy == true, action: act) {
            VStack(alignment: .leading, spacing: 12) {
                FactRow(icon: "1.circle", title: "Plug it in, or turn its Bluetooth on", line: "USB for any Ledger; Bluetooth for Nano X, Stax and Flex.")
                FactRow(icon: "2.circle", title: "Unlock it with its PIN", line: "On the device itself: the PIN never touches this Mac.")
                FactRow(icon: "3.circle", title: "Allow the Ethereum and Solana apps", line: "The Ledger asks for each; ihatecrypto reads the addresses from them.")
            }
            if let state {
                if let model = state.model { statusLine(model, ok: true) }
                statusLine(state.problem ?? state.status, ok: state.problem != nil ? false : connected ? true : nil)
                ForEach(state.notes, id: \.self) { Text($0).font(.ui(11.5)).foregroundStyle(Brand.jevInk).fixedSize(horizontal: false, vertical: true) }
            }
        } quiet: {
            QuietButton("Back") { ws.ledgerConnect = nil; back() }
        }
    }

    private func act() {
        if connected, let account = LedgerAccount.saved {
            Task {
                await ws.switchWallet(account.wallet)
                ws.ledgerConnect = nil
                next()
            }
        } else {
            Task { await ws.connectLedger() }
        }
    }
}

// MARK: - Networks

private struct NetworksStep: View {
    @Environment(Workspace.self) private var ws
    let trades: Bool
    let next: () -> Void
    let back: () -> Void
    @AppStorage(Modules.key) private var stored = ""

    var body: some View {
        let m = Modules(stored: stored)
        OnboardingCard(mood: .tuning, title: "Which networks do you use?",
                       subtitle: "The assistant plans moves only on the ones that are on. Money already on the others still shows.",
                       primary: "Continue", action: next) {
            VStack(spacing: 6) {
                ForEach(ModuleNetwork.allCases, id: \.self) { n in
                    let has = hasAddress(n)
                    Tile(selected: n == .hyperliquid && trades) {
                        TokenLogo(name: n.logo, size: 26).clipShape(Circle()).saturation(has ? 1 : 0)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(n.name).font(.ui(13.5, .bold))
                            Text(has ? (n == .hyperliquid && m.isOn(n) ? "\(n.uses) · adds two steps: trading key, rules" : n.uses) : "No address for it in this wallet")
                                .font(.ui(11.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Toggle(n.name, isOn: Binding(get: { has && m.isOn(n) }, set: { on in
                            var c = Modules(stored: stored)
                            c.set(n, on)
                            stored = c.stored
                        }))
                        .labelsHidden().toggleStyle(AccentSwitch()).disabled(!has)
                    }
                    .opacity(has ? 1 : 0.55)
                }
            }
            Text("Change any time in Settings › Modules, or from the networks above the chat.").font(.ui(11.5)).foregroundStyle(.secondary)
        } quiet: {
            QuietButton("Back", action: back)
        }
    }

    /// Whether the wallet (or a watched address) has an address there.
    private func hasAddress(_ n: ModuleNetwork) -> Bool {
        switch n {
        case .solana: isSolanaAddress(ws.solanaAddress)
        case .near: ws.nearAddress != nil
        default: isEVMAddress(ws.hlAddress)
        }
    }
}

// MARK: - Trading (only with Hyperliquid on)

private struct TradingKeyStep: View {
    @Environment(Workspace.self) private var ws
    let next: () -> Void
    let back: () -> Void
    @State private var tried = false
    /// The account has never had a deposit: Hyperliquid would refuse the key, so the step doesn't ask for Touch ID.
    @State private var noDeposit = false

    var body: some View {
        let ready = ws.agentActive || noDeposit
        OnboardingCard(mood: ws.agentActive ? .done : ws.executing ? .thinking : .idle, title: "A trading key for Hyperliquid",
                       subtitle: noDeposit && !ws.agentActive
                           ? "Hyperliquid takes it once the account has had a deposit, so it waits until then. Until then every order asks for \(ws.ledgerActive ? "the Ledger's buttons" : "Touch ID")."
                           : "Because Hyperliquid is on. Without it every order asks for \(ws.ledgerActive ? "the Ledger's buttons" : "Touch ID"); with it, orders go straight through the rules.",
                       primary: ready ? "Continue" : ws.ledgerActive ? "Approve on the Ledger" : "Approve with Touch ID", icon: ready ? nil : "touchid", busy: ws.executing, action: { ready ? next() : approve() }) {
            VStack(alignment: .leading, spacing: 14) {
                FactRow(icon: "arrow.left.arrow.right", title: "It opens and closes positions", line: "Orders, stops and takes, within the trade rules.")
                FactRow(icon: "nosign", title: "It can't withdraw", line: "Hyperliquid itself refuses a withdrawal signed by it.")
                FactRow(icon: "pause.circle", title: "Pause it any time", line: "Say «lock» in the chat, or in Settings › Wallet › Key and signing.")
            }
            if ws.agentActive {
                statusLine("The trading key is on.", ok: true)
            } else if noDeposit {
                statusLine("After the first deposit to Hyperliquid: Settings › Wallet › Key and signing has the button.")
            } else if tried, let said = ws.messages.last(where: { !$0.fromUser })?.text {
                statusLine(said, ok: false)
            }
        } quiet: {
            QuietButton("Back", action: back)
            if !ready { QuietButton("Later", action: next) }
        }
        .task {
            if let evm = ws.signerWallet?.evm { noDeposit = (try? await Hyperliquid.isNewAccount(evm)) == true }
        }
    }

    private func approve() {
        tried = false
        Task {
            await ws.enableAgent()
            tried = true
        }
    }
}

private struct RulesStep: View {
    @Environment(Workspace.self) private var ws
    let next: () -> Void
    let back: () -> Void

    var body: some View {
        @Bindable var ws = ws
        let p = ws.policy
        OnboardingCard(mood: .idle, title: "Rules every trade passes",
                       subtitle: "Because Hyperliquid is on. Checked in code before a trade is signed, not by the model.",
                       primary: "Continue", action: next) {
            VStack(spacing: 8) {
                Tile {
                    rule("At most \(Fmt.num(p.maxRiskPct))% of the account at risk", "What one trade may lose at its stop")
                    Stepper("", value: Binding(get: { (p.maxRiskPct as NSDecimalNumber).doubleValue },
                                               set: { ws.policy.maxRiskPct = Decimal($0) }), in: 0.5...10, step: 0.5).labelsHidden()
                }
                Tile { rule("By the book: \(Fmt.num(p.defaultRiskPct))% risk, take at \(Fmt.num(p.defaultRewardRisk))R", "When you say «by the book» and name no amount") }
                Tile { rule("Reward at least \(Fmt.num(p.minRewardRisk))× the risk", "A plan that pays less is stopped") }
                Tile { rule("Stop by volatility: \(Fmt.num(p.atrStopMultiple))× the 4-hour ATR", "Leverage up to \(Fmt.num(p.maxLeverage))×; all open positions together at most \(Fmt.num(p.maxOpenRiskPct))%") }
                Tile {
                    rule("Second check", "Another model reads every plan before you confirm it")
                    Toggle("Second check", isOn: $ws.jevScreening).labelsHidden().toggleStyle(AccentSwitch())
                }
            }
        } quiet: {
            QuietButton("Back", action: back)
        }
    }

    private func rule(_ title: String, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.ui(13.5, .bold))
            Text(line).font(.ui(11.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Money and staying in touch

private struct MoneyStep: View {
    @Environment(Workspace.self) private var ws
    let next: () -> Void
    let back: () -> Void
    /// Solana's USDC and SOL when the card opened: what lands after shows here.
    @State private var start: (usdc: Decimal, sol: Decimal)?

    private var landed: String? {
        guard let start, let now = ws.solana else { return nil }
        let parts = [now.usdc > start.usdc ? "\(Fmt.num(now.usdc - start.usdc)) USDC" : nil,
                     now.sol > start.sol ? "\(Fmt.num(now.sol - start.sol, maxFraction: 6)) SOL" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    var body: some View {
        OnboardingCard(mood: landed != nil ? .done : .waiting, title: "Add money",
                       subtitle: "Send USDC from an exchange or another wallet. It shows up here as it lands.",
                       primary: landed != nil ? "Continue" : "I'll do it later", action: next) {
            VStack(spacing: 10) {
                if isSolanaAddress(ws.solanaAddress) {
                    ReceiveCard(logo: "sol", network: "Solana", badge: "recommended", address: ws.solanaAddress,
                                what: "USDC or SOL on the Solana network. USDC is what ihatecrypto trades with; keep ≈ 0.02 SOL for fees.",
                                tint: Brand.solanaTint)
                }
                if isEVMAddress(ws.hlAddress) {
                    ReceiveCard(logo: "base", network: "Base", badge: nil, address: ws.hlAddress,
                                what: "USDC or ETH on Base. Hyperliquid uses the same address, but money gets there through ihatecrypto.",
                                tint: Color(light: 0xEAF0FF, dark: 0x14213F))
                }
            }
            statusLine("On an exchange, pick the network exactly: Solana (SPL) or Base. Sent on another network, money can get stuck.", ok: false)
            if let landed {
                statusLine("\(landed) arrived on Solana", ok: true)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for a deposit… balances refresh every 30 s.").font(.ui(12)).foregroundStyle(.secondary)
                }
            }
        } quiet: {
            QuietButton("Back", action: back)
        }
        // Taken once the balance is known: money already there when the card opened isn't «arrived».
        .onAppear { start = ws.solana.map { ($0.usdc, $0.sol) } }
        .onChange(of: ws.solana == nil) { if start == nil { start = ws.solana.map { ($0.usdc, $0.sol) } } }
    }
}

private struct StayInTouchStep: View {
    let finish: () -> Void
    let back: () -> Void
    @State private var notices: Bool?
    @State private var keepRunning = KeepRunning.isOn
    @State private var error: String?

    var body: some View {
        OnboardingCard(mood: .idle, title: "Stay in touch",
                       subtitle: "So a price alert or a finished move reaches you, and schedules run with the window closed.",
                       primary: "Finish", action: finish) {
            VStack(spacing: 8) {
                Tile {
                    item("bell.badge", "Notifications", notices == false ? "Off in System Settings › Notifications › ihatecrypto" : "Money arrived, an alert fired, a move finished or needs your Confirm")
                    Toggle("Notifications", isOn: Binding(get: { notices == true }, set: { if $0 { ask() } }))
                        .labelsHidden().toggleStyle(AccentSwitch()).disabled(notices == true)
                }
                Tile {
                    item("menubar.rectangle", "Keep running in the menu bar", "Stops, alerts and scheduled buys keep working after the window is closed")
                    Toggle("Keep running", isOn: Binding(get: { keepRunning }, set: { on in
                        do { try KeepRunning.set(on); keepRunning = on } catch { self.error = error.localizedDescription }
                    }))
                    .labelsHidden().toggleStyle(AccentSwitch())
                }
            }
            if let error { statusLine(error, ok: false) }
            Text("Both are in Settings › General too.").font(.ui(11.5)).foregroundStyle(.secondary)
        } quiet: {
            QuietButton("Back", action: back)
        }
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notices = settings.authorizationStatus == .authorized ? true : settings.authorizationStatus == .denied ? false : nil
        }
    }

    private func item(_ icon: String, _ title: String, _ line: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.accentInk).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(13.5, .bold))
                Text(line).font(.ui(11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ask() {
        NSApp.activate()
        Task { notices = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false }
    }
}
