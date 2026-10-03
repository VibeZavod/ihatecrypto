import AppKit
import IhatecryptoCore
import LLMCatalog
import LLMCore
import ServiceManagement
import SignerAPI
import SwiftUI

/// Settings occupy the window; the coin and Esc return to the canvas.
struct SettingsView: View {
    @Environment(Workspace.self) private var ws
    @State private var confirmForget = false
    @State private var alwaysRunning = KeepRunning.isOn
    @State private var alwaysRunningError: String?
    static let tabKey = "settingsTab"
    @AppStorage(SettingsView.tabKey) private var tab = Tab.general

    /// Raw values also serve links from the chat and the networks menu.
    enum Tab: String, CaseIterable {
        case general, signIns = "signins", wallet, modules, debugging

        var title: String {
            switch self {
            case .general: "General"
            case .signIns: "Sign-ins"
            case .wallet: "Wallet"
            case .modules: "Modules"
            case .debugging: "Debugging"
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .signIns: "key"
            case .wallet: "creditcard"
            case .modules: "square.grid.2x2"
            case .debugging: "terminal"
            }
        }
    }

    static let lights = CGPoint(x: 20, y: 21)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                WindowDragArea()
                Text("Settings").font(.ui(13, .semibold)).allowsHitTesting(false)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.hoverIcon).help("Close Settings (Esc)")
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 10)
            }
            .frame(height: 2 * Self.lights.y).background(Brand.card)
            Brand.cardBorder.frame(height: 1)
            HStack(spacing: 0) {
                sidebar
                Brand.cardBorder.frame(width: 1)
                page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Brand.canvas)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(TrafficLights(center: Self.lights))
        .background(Button("Back to the canvas", action: close).keyboardShortcut(.cancelAction).opacity(0))
        .onAppear { ws.tuning = "In Settings" }
        .onDisappear { ws.tuning = nil }
    }

    private func close() { ws.settingsOpen = false }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: close) {
                HStack(spacing: 10) {
                    BrandLogo(size: 28, mood: .tuning, animated: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Assistant").font(.ui(13, .semibold))
                        Text(ws.tuning ?? "In Settings").font(.ui(11)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Back to the canvas (Esc)")
            .padding(.horizontal, 6).padding(.bottom, 18)
            ForEach(Tab.allCases.filter { $0 != .debugging }, id: \.self) { tabButton($0) }
            Spacer()
            Divider().padding(.vertical, 8)
            Text("DEVELOPER").font(.ui(10, .semibold)).tracking(1).foregroundStyle(.tertiary).padding(.leading, 10)
            tabButton(.debugging)
        }
        .padding(.horizontal, 10).padding(.vertical, 20).frame(width: 190).background(Brand.card)
    }

    private func tabButton(_ t: Tab) -> some View {
        Button { tab = t } label: {
            HStack(spacing: 10) {
                SettingsIcon(icon: t.icon, size: 24, active: tab == t)
                Text(t.title).font(.ui(13, tab == t ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 8).fill(tab == t ? Brand.glassSelected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(tab == t ? [.isSelected] : [])
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case .modules: ModulesSettings()
        case .general: SettingsPage(title: "General", line: "How the assistant trades, talks and stays running.") { general }
        case .signIns: SettingsPage(title: "Sign-ins", line: "Choose what reads your chat. A model is optional.") { ModelSection() }
        case .wallet: SettingsPage(title: "Wallet", line: "Your signing key, addresses and Touch ID.") { wallet }
        case .debugging: SettingsPage(title: "Debugging", line: "Developer tools on this Mac.") { debugging }
        }
    }

    @ViewBuilder private var general: some View {
        @Bindable var ws = ws
        risk
        SettingsSection(icon: "checkmark.seal", title: "Tokens", line: "What can be bought on Solana.") {
            SettingsGroup {
                SettingsRow("Safe search", icon: "checkmark.seal", info: ws.safeSearch
                            ? "Only verified coins on Solana: SOL, BTC, ETH, JUP and JitoSOL. Look-alikes of famous tokens cannot slip in."
                            : "Any Solana token can be bought by its mint through Jupiter. Before you confirm, the assistant explains risks such as a creator who can freeze or print tokens, a thin pool, or no verification. Confirm and simulation still apply.") {
                    Toggle("Safe search", isOn: $ws.safeSearch).toggleStyle(AccentSwitch())
                }
            }
        }
        ChatAndNoticeSettings()
        keepRunning
        SettingsSection(icon: "checkmark.shield", title: "Second check", line: "A second reader. It can only stop, never approve.") {
            SettingsGroup {
                SettingsRow("Check commands and plans twice", icon: "checkmark.shield", info: ws.openRouterKey == nil
                            ? "OpenRouter adds a separate model; the chat keeps its own. Without OpenRouter, the chat's model reads each command and plan a second time. Local rules also check incoming text. This check can stop a move, never approve a signature."
                            : "The chat's model and a separate model on OpenRouter check your commands and plans against your words. Pasted text is checked for instructions aimed at the assistant. The texts go to OpenRouter. This check can stop a move, never approve a signature.") {
                    Toggle("Second check", isOn: $ws.jevScreening).toggleStyle(AccentSwitch())
                }
                SettingsRow("OpenRouter", icon: "network", logo: "llm-openrouter") {
                    SettingsPill(text: ws.openRouterKey == nil ? "Not connected" : "Connected", good: ws.openRouterKey != nil)
                    if ws.openRouterKey == nil { Button("Connect") { Task { await ws.signInJev() } } }
                }
                if let status = ws.jevStatus { SettingsRow(status, icon: "info.circle") { EmptyView() } }
            }
        }
    }

    /// Only risk per trade is editable; the other numbers are limits enforced by code.
    private var risk: some View {
        let p = ws.policy
        return SettingsSection(icon: "scalemass", title: "Risk", line: "Limits checked before every trade. Crypto only.") {
            SettingsGroup {
                SettingsRow("Risk per trade", icon: "chart.bar", info: "The most a trade may lose at its stop, as a share of your capital. The usual starting point is \(Fmt.pct(p.defaultRiskPct)), with a \(Fmt.num(p.defaultRewardRisk))R take-profit and a stop at \(Fmt.num(p.atrStopMultiple)) times recent price movement (4-hour ATR). Trades above the limit are blocked.") {
                    HStack(spacing: 10) {
                        GeometryReader { g in
                            Capsule().fill(Color.primary.opacity(0.1))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Brand.accent).frame(width: g.size.width * min(max(CGFloat(NSDecimalNumber(decimal: p.maxRiskPct).doubleValue / 10), 0), 1))
                                }
                        }
                        .frame(width: 70, height: 6).accessibilityHidden(true)
                        step("minus", "Less risk per trade", enabled: p.maxRiskPct > 0.5) { ws.policy.maxRiskPct -= 0.5 }
                        Text(Fmt.pct(p.maxRiskPct)).font(.ui(16, .bold)).monospacedDigit().frame(minWidth: 46)
                        step("plus", "More risk per trade", enabled: p.maxRiskPct < 10) { ws.policy.maxRiskPct += 0.5 }
                    }
                }
                SettingsRow("All open positions together", icon: "square.stack.3d.up", info: "Their combined loss at the stops cannot exceed this share of capital. This limit is fixed.") {
                    Text("at most \(Fmt.pct(p.maxOpenRiskPct))").monospacedDigit()
                }
                SettingsRow("Reward / risk", icon: "arrow.up.right", info: "The planned profit must be at least this many times the planned loss. This limit is fixed.") {
                    Text("at least \(Fmt.num(p.minRewardRisk))").monospacedDigit()
                }
                SettingsRow("Leverage", icon: "multiply", info: "Borrowed exposure makes gains and losses larger. The assistant cannot trade above this fixed limit.") {
                    Text("up to \(Fmt.num(p.maxLeverage))×").monospacedDigit()
                }
            }
        }
    }

    private func step(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4).help(help).accessibilityLabel(help)
    }

    private var debugging: some View {
        SettingsSection(icon: "terminal", title: "Local debug API", line: "For Claude Code and local developer tools.") {
            SettingsGroup {
                SettingsRow("Allow local debug access", icon: "terminal", info: "Reads state, types into the chat and captures the window. It never signs: money moves still need Confirm and Touch ID in the app. Access requires a token that changes each time the API starts.") {
                    Toggle("Local debug API", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "debugAPI") },
                        set: { on in
                            UserDefaults.standard.set(on, forKey: "debugAPI")
                            if on { DebugAPI.shared.start(ws) } else { DebugAPI.shared.stop() }
                        }))
                    .toggleStyle(AccentSwitch())
                }
                SettingsRow("Local address", icon: "network") { Text("127.0.0.1:\(String(DebugAPI.port))").textSelection(.enabled) }
                SettingsRow("Access token", icon: "key", info: "Stored at Application Support/ihatecrypto/debug-token. Use it as a Bearer token with curl.") {
                    Text("Changes each start").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var wallet: some View {
        signer
        touchID
        tradingKey
        addresses
        if ws.signerWallet != nil { forget }
    }

    private var signer: some View {
        SettingsSection(icon: "creditcard", title: "Wallet that signs", line: "The active wallet. Switching asks for Touch ID.") {
            SettingsGroup {
                if let w = ws.activeWallet {
                    HStack(spacing: 12) {
                        Text(w.label.prefix(1).uppercased()).font(.ui(18, .bold)).foregroundStyle(Brand.accentInk)
                            .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 12).fill(Brand.canvas))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(w.label).font(.ui(15, .semibold))
                            Text(Workspace.kindName(w)).font(.ui(12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if ws.wallets.count > 1 {
                            Menu("Switch") {
                                ForEach(ws.wallets) { wallet in
                                    Button("\(wallet.label) — \(Workspace.describe(wallet))") { Task { await ws.switchWallet(wallet) } }
                                        .disabled(wallet.id == ws.activeWalletID)
                                }
                            }
                            .fixedSize()
                        }
                    }
                    .padding(14)
                    Divider().padding(.leading, 54)
                    ForEach([("Solana", "sol", w.solana), ("EVM", "eth", w.evm), ("NEAR", "near", w.near)], id: \.0) { pair in
                        if let address = pair.2 {
                            SettingsRow(pair.0, icon: "link", logo: pair.1) {
                                CopyButton(title: "\(address.prefix(6))…\(address.suffix(6))", text: address, help: "Copy the \(pair.0) address")
                            }
                        }
                    }
                }
                SettingsRow("Signing key", icon: "lock.shield", info: "The key stays in secure storage. A separate process without network access signs approved moves.") {
                    SettingsPill(text: ws.signerWallet == nil ? "No key on this Mac" : "Secure storage", good: ws.signerWallet != nil)
                }
                if ws.signerWallet == nil {
                    SettingsRow("Import a wallet to add a signing key", icon: "square.and.arrow.down") { EmptyView() }
                }
            }
        }
    }

    @ViewBuilder private var addresses: some View {
        @Bindable var ws = ws
        SettingsSection(icon: "eye", title: "Addresses for balances", line: "Read-only wallets. Never paste a recovery phrase or key.") {
            SettingsGroup {
                SettingsRow("Solana", icon: "link", logo: "sol") {
                    addressField("Solana address", text: $ws.solanaAddress)
                }
                SettingsRow("Hyperliquid", icon: "link", logo: "hype") {
                    addressField("Hyperliquid address (0x…)", text: $ws.hlAddress)
                }
            }
        }
    }

    private func addressField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            TextField(label, text: text).textFieldStyle(.roundedBorder).font(.system(size: 11.5, design: .monospaced))
                .labelsHidden().frame(maxWidth: 340)
            CopyButton(text: text.wrappedValue, help: "Copy the \(label)").disabled(text.wrappedValue.isEmpty)
        }
    }

    private var touchID: some View {
        SettingsSection(icon: "touchid", title: "Touch ID", line: "One touch covers one move, or a few minutes.") {
            SettingsGroup {
                SettingsRow("Stays valid for", icon: "timer", info: "One move covers that move's signatures for at most a minute and ends when it is done. With 5–30 minutes, signatures need no new touch during that time. Each still passes the guard and second check. Locking the screen or sleep ends the session. A longer duration asks for Touch ID.") {
                    // Drawn segments keep the brand accent instead of macOS's system blue.
                    HStack(spacing: 2) {
                        ForEach(SignerSession.choices, id: \.self) { choice in
                            let on = choice == ws.sessionLength
                            Button {
                                Task {
                                    _ = try? await SignerClient().send(.setSessionLength(seconds: choice))
                                    await ws.loadSigner()
                                }
                            } label: {
                                Text(choice == SignerSession.standard ? "One move" : "\(choice / 60) min").font(.ui(11.5, .semibold))
                                    .foregroundStyle(on ? Brand.onAccent : Color.primary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? Brand.accent : .clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityAddTraits(on ? [.isSelected] : [])
                        }
                    }
                    .padding(2).frame(width: 290)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    .disabled(ws.signerWallet == nil)
                }
            }
        }
    }

    private var tradingKey: some View {
        SettingsSection(icon: "bolt", title: "Hyperliquid", line: "A trading key places orders. It cannot withdraw money.") {
            SettingsGroup {
                SettingsRow("Trading key", icon: "key", logo: "hype", info: ws.agentActive
                            ? "Approved once for Hyperliquid orders. The key cannot withdraw money."
                            : ws.ledgerActive ? "Without a trading key, every order asks for the Ledger's buttons. Hyperliquid accepts the key after the account has had a deposit."
                            : "Without a trading key, every order asks for Touch ID. Hyperliquid accepts the key after the account has had a deposit.") {
                    SettingsPill(text: ws.agentActive ? "On" : "Off", good: ws.agentActive)
                    if !ws.agentActive, ws.activeWallet?.evm != nil {
                        Button(ws.ledgerActive ? "Approve on Ledger…" : "Approve…") { Task { await ws.enableAgent() } }.disabled(ws.executing)
                    }
                }
            }
        }
    }

    private var forget: some View {
        VStack(alignment: .center, spacing: 6) {
            Button("Forget the key on this Mac…", systemImage: "trash", role: .destructive) { confirmForget = true }
                .buttonStyle(.plain).foregroundStyle(Brand.loss)
                .confirmationDialog("Forget the wallet key on this Mac?", isPresented: $confirmForget) {
                    Button("Forget the key", role: .destructive) {
                        Task {
                            let id = (try? await SignerClient().send(.status))?.activeWallet
                            if (try? await SignerClient().send(.forget))?.ok == true, let id { ws.walletRemoved(id) }
                            await ws.loadSigner()
                        }
                    }
                } message: {
                    Text("Only if the recovery phrase is written down: without it the money on this wallet can't be reached again. Positions, stops and balances stay where they are.")
                }
            Text("Only if the recovery phrase is written down.").font(.ui(12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 12).padding(.bottom, 8)
    }

    private var keepRunning: some View {
        SettingsSection(icon: "moon.stars", title: "Background", line: "Stops, alerts and scheduled buys with the window closed.") {
            SettingsGroup {
                SettingsRow("Keep always running", icon: "moon.stars", info: "Starts at login and returns within a minute after Quit or a crash, in the menu bar with its window closed. Turn this off to quit for good. Nothing runs while the Mac sleeps; due tasks run when it wakes.") {
                    Toggle("Keep ihatecrypto always running", isOn: Binding(get: { alwaysRunning }, set: { on in
                        do { try KeepRunning.set(on); alwaysRunningError = nil } catch { alwaysRunningError = error.localizedDescription }
                        alwaysRunning = KeepRunning.isOn
                    })).toggleStyle(AccentSwitch())
                }
                if let alwaysRunningError {
                    SettingsRow(alwaysRunningError, icon: "exclamationmark.triangle") { EmptyView() }.foregroundStyle(Brand.loss)
                }
                SettingsRow("Open at login", icon: "power", info: "Opens the app when you log in. If you quit with Keep always running off, app-managed stops and scheduled buys stop. Stop and take-profit orders already on the exchange keep working.") {
                    Toggle("Open ihatecrypto at login", isOn: Binding(
                        get: { SMAppService.mainApp.status == .enabled },
                        set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }))
                        .toggleStyle(AccentSwitch())
                }
            }
        }
    }
}

/// The column stays centred and readable on a wide window.
struct SettingsPage<Content: View>: View {
    let title: String
    let line: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.ui(24, .bold))
                    Text(line).font(.ui(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .frame(maxWidth: 660, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        }
    }
}

/// Neutral tiles keep coloured glyphs legible in both themes, including disabled Modules.
struct SettingsIcon: View {
    let icon: String
    var size: CGFloat = 26
    var active = true

    var body: some View {
        Image(systemName: icon).font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(active ? Brand.accentInk : Color.secondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(Color.primary.opacity(0.06)))
            .accessibilityHidden(true)
    }
}

struct SettingsSection<Content: View>: View {
    let icon: String
    let title: String
    let line: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SettingsIcon(icon: icon, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(17, .bold)).accessibilityAddTraits(.isHeader)
                    Text(line).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
    }
}

struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.cardBorder))
    }
}

/// Each row has one control and optional detail behind an information button.
struct SettingsRow<Control: View>: View {
    let label: String
    let icon: String
    let logo: String?
    let info: String?
    let control: Control

    init(_ label: String, icon: String, logo: String? = nil, info: String? = nil, @ViewBuilder control: () -> Control) {
        (self.label, self.icon, self.logo, self.info) = (label, icon, logo, info)
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let logo { TokenLogo(name: logo, size: 26).clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true) }
            else { SettingsIcon(icon: icon) }
            Text(label).font(.ui(13)).fixedSize(horizontal: false, vertical: true)
            if let info { SettingsInfo(text: info, label: label) }
            Spacer(minLength: 8)
            control.font(.ui(12.5))
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 48)
        .overlay(alignment: .bottom) { Brand.cardBorder.opacity(0.65).frame(height: 0.5).padding(.leading, 50) }
    }
}

struct SettingsInfo: View {
    let text: String
    let label: String
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("About \(label)").accessibilityLabel("About \(label)")
        .popover(isPresented: $showing) {
            Text(text).font(.ui(13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .padding(16).frame(width: 330, alignment: .leading)
        }
    }
}

/// Status uses the same neutral surface; the dot carries the accent.
struct SettingsPill: View {
    let text: String
    let good: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(good ? Brand.accent : Color.secondary).frame(width: 6, height: 6)
            Text(text).font(.ui(11, .semibold))
        }
        .foregroundStyle(good ? Color.primary : Color.secondary)
        .padding(.horizontal, 9).padding(.vertical, 4).background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}

struct ModelSection: View {
    @Environment(Workspace.self) private var ws
    @State private var key = ""
    private static let ways = ["claude-code", "chatgpt", "openrouter"]
    private static let commands = ["long ETH risk $5", "send 5 USDC to Bybit", "stop 3%"]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            model
            SettingsSection(icon: "text.bubble", title: "Without a model", line: "Typed commands still work, with no subscription.") {
                SettingsGroup {
                    HStack(alignment: .top, spacing: 10) {
                        SettingsIcon(icon: "terminal")
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) { commandChips }
                            VStack(alignment: .leading, spacing: 6) { commandChips }
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    SettingsRow("English or Russian commands", icon: "textformat", info: "Click an example to put it in the chat. Free wording in any language, such as «закрой половину, если упадёт ниже 3000», needs a model.") { EmptyView() }
                }
            }
            SettingsSection(icon: "lock.shield", title: "Safety", line: "A model reads your words. It cannot approve a move.") {
                SettingsGroup {
                    SettingsRow("Money moves only after Confirm + Touch ID", icon: "touchid", info: "You approve money moves in the app. Touch ID can cover one move or a session, as set in Wallet. A separately approved Hyperliquid trading key can place orders without a new touch; it cannot withdraw money.") { EmptyView() }
                    SettingsRow("Keys, addresses and balances stay private", icon: "eye.slash", info: "The chat model receives your message text and the plan's parameters. The app does not attach wallet keys, addresses or balances to the model's request.") { EmptyView() }
                }
            }
        }
        .onChange(of: ws.providerID) { key = "" }
    }

    private var commandChips: some View {
        ForEach(Self.commands, id: \.self) { command in
            Button { ws.draft = command; ws.settingsOpen = false } label: {
                Text(command).font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Brand.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Brand.cardBorder))
            }
            .buttonStyle(.plain).pointerStyle(.link).help("Put it in the chat")
        }
    }

    private var model: some View {
        let info = ws.provider.info
        return SettingsSection(icon: "sparkles", title: "Chat model", line: "Write freely, in any language. Choose a way to connect.") {
            SettingsGroup {
                way("claude-code", "Claude subscription", "Uses Claude Code on this Mac", logo: "llm-claude")
                way("chatgpt", "ChatGPT subscription", "Plus or Pro · sign in in the browser", logo: "llm-openai")
                way("openrouter", "OpenRouter", "One key for many models", logo: "llm-openrouter")
                other
            }
            SettingsGroup {
                SettingsRow("\(info.name)", icon: "info.circle", info: info.note.isEmpty ? nil : info.note) {
                    if let unavailable = info.unavailable { Text(unavailable).foregroundStyle(Brand.accentInk).fixedSize(horizontal: false, vertical: true) }
                    else { SettingsPill(text: ws.hasModel ? "Connected" : "Not connected", good: ws.hasModel) }
                }
                if info.unavailable == nil { connection(info) }
            }
        }
    }

    private func radio(_ selected: Bool) -> some View {
        Circle().strokeBorder(selected ? Brand.accent : Color.secondary.opacity(0.5), lineWidth: selected ? 4 : 1.5)
            .frame(width: 16, height: 16).accessibilityHidden(true)
    }

    private func way(_ id: String, _ title: String, _ line: String, logo: String) -> some View {
        let selected = ws.providerID == id
        return Button { ws.providerID = id } label: {
            HStack(spacing: 10) {
                radio(selected)
                TokenLogo(name: logo, size: 28).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(13, .semibold))
                    Text(line).font(.ui(11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if selected, ws.hasModel { SettingsPill(text: "Connected", good: true) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Brand.cardBorder.opacity(0.65).frame(height: 0.5).padding(.leading, 78) }
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Less common providers stay reachable from a single row.
    private var other: some View {
        let selected = !Self.ways.contains(ws.providerID)
        return HStack(spacing: 10) {
            radio(selected)
            SettingsIcon(icon: "key.fill", size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("API key or a model on this Mac").font(.ui(13, .semibold))
                Text(selected ? ws.provider.info.name : "Choose a provider or local model").font(.ui(11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if selected, ws.hasModel { SettingsPill(text: "Connected", good: true) }
            Menu("Choose…") {
                ForEach(ProviderKind.allCases, id: \.self) { kind in
                    Section(kind.title) {
                        ForEach(LLMCatalog.all.filter { $0.info.kind == kind && !Self.ways.contains($0.info.id) }, id: \.info.id) { p in
                            Button(p.info.unavailable == nil ? p.info.name : p.info.name + " — unavailable") { ws.providerID = p.info.id }
                        }
                    }
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 12).accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder private func connection(_ info: ProviderInfo) -> some View {
        SettingsRow("Sign-in", icon: "person.crop.circle", info: connectionText) {
            if let label = info.existingLoginLabel, ws.provider.existingLogin() != nil {
                Button(label) { ws.useExistingLogin() }
            }
            if let label = info.signInLabel {
                Button(label) { Task { await ws.signIn() } }.disabled(ws.llmBusy)
            }
            if info.signInLabel == nil, info.existingLoginLabel == nil {
                Text(info.kind == .local ? "No key needed" : "Use an API key below").foregroundStyle(.secondary)
            }
        }
        if info.takesKey {
            SettingsRow("API key", icon: "key") {
                SecureField("API key", text: $key).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Button("Save") { ws.setCredential(.apiKey(key)); key = "" }.disabled(key.isEmpty)
            }
        }
        SettingsRow("Model", icon: "sparkles") {
            TextField("Model", text: Binding(get: { ws.model }, set: { ws.model = $0 }))
                .textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 300)
            Menu("List") {
                if ws.availableModels.isEmpty { Button("Load models") { Task { await ws.loadModels() } } }
                ForEach(ws.availableModels, id: \.self) { id in Button(id) { ws.model = id } }
            }
            .fixedSize()
        }
        SettingsRow("Connection", icon: "antenna.radiowaves.left.and.right") {
            if ws.llmBusy { ProgressView().controlSize(.small) }
            Button("Test") { Task { await ws.testModel() } }.disabled(ws.llmBusy)
            if ws.credential != nil { Button("Disconnect") { ws.setCredential(nil) } }
        }
        if let status = ws.llmStatus {
            SettingsRow(status, icon: "info.circle") { EmptyView() }.textSelection(.enabled)
        }
    }

    private var connectionText: String {
        switch ws.credential {
        case .apiKey: "Connected: key in Keychain."
        case .oauth: "Connected: signed in via browser."
        case .external(let path): "Connected: \(path)."
        case nil: ws.provider.info.kind == .local ? "No key needed; the local server must be running." : "Not connected."
        }
    }
}

extension ProviderKind {
    var title: String {
        switch self {
        case .subscription: "Subscription"
        case .apiKey: "API key or credits"
        case .local: "On this Mac"
        }
    }
}
