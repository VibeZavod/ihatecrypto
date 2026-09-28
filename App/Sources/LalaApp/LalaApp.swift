import AppKit
import GuardJev
import LalaCore
import LLMCatalog
import LLMCore
import ServiceManagement
import SignerAPI
import SwiftUI

@main
struct LalaApp: App {
    /// The main window's title; DebugAPI and the window test find the window by it.
    static let mainTitle = "ihatecrypto"
    /// Created once with the app, so the watch loop below outlives the window.
    private let workspace = Workspace()

    /// `-signerSelfTest YES`: checks the signing process inside ihatecrypto.app with the public test phrase, then quits.
    /// The main window stays empty so nothing else (balances, model logins) runs meanwhile.
    /// Launch flags that drive the app are Debug-only: in a Release build any program could `open ihatecrypto.app --args …`.
    #if DEBUG
    private let selfTest = UserDefaults.standard.bool(forKey: "signerSelfTest")
    #else
    private let selfTest = false
    #endif

    init() {
        // One copy only: a second one (Keep running racing a relaunch, a test build) would run stops and tasks twice.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.lala.mac")
            .contains(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
            exit(0)
        }
        if selfTest {
            Task { exit(await SignerSelfTest.run() ? 0 : 1) }
        } else {
            // Balances, exit rules and regular purchases keep running with the window closed; LALA stays in the
            // menu bar until ⌘Q.
            let ws = workspace
            Task { await ws.watch() }
            #if DEBUG
            // `-browserResultAfter N`: after N seconds prints the browser page's text and quits (the browser test).
            let resultAfter = UserDefaults.standard.double(forKey: "browserResultAfter")
            if resultAfter > 0 {
                Task {
                    // `-browserScriptFile <path>`: JavaScript run on the page halfway, e.g. to press a site's «Connect».
                    // A file, not the argument itself: macOS reads «(…)» in launch arguments as a property list.
                    if let path = UserDefaults.standard.string(forKey: "browserScriptFile"), let script = try? String(contentsOfFile: path, encoding: .utf8) {
                        try? await Task.sleep(for: .seconds(resultAfter / 2))
                        // callAsyncJavaScript awaits a script's promise; a plain script returns at once.
                        let r = try? await ws.browser.webView.callAsyncJavaScript("return await " + script, contentWorld: .page)
                        FileHandle.standardError.write(Data("LALA browser script: \(r.map { "\($0)" } ?? "nil")\n".utf8))
                        try? await Task.sleep(for: .seconds(resultAfter / 2))
                    } else {
                        try? await Task.sleep(for: .seconds(resultAfter))
                    }
                    let text = (try? await ws.browser.webView.evaluateJavaScript("document.body.innerText")) as? String ?? "no text"
                    FileHandle.standardError.write(Data("LALA browser page:\n\(text)\n".utf8))
                    for m in ws.messages.dropFirst() { FileHandle.standardError.write(Data("LALA < \(m.text)\n".utf8)) }
                    NSApp.terminate(nil)
                }
            }
            // `-closeWindowTest YES`: closes the main window and checks the loop still refreshes from the menu bar.
            if UserDefaults.standard.bool(forKey: "closeWindowTest") {
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    NSApp.windows.filter { $0.title == LalaApp.mainTitle }.forEach { $0.close() }
                    let before = ws.updatedAt
                    try? await Task.sleep(for: .seconds(40))
                    let log = "ihatecrypto window closed; still running; refreshed after close: \(ws.updatedAt != before) (\(ws.updatedAt.map { "\($0)" } ?? "nil"))\n"
                    FileHandle.standardError.write(Data(log.utf8))
                    NSApp.terminate(nil)
                }
            }
            #endif
        }
    }

    var body: some Scene {
        // The title bar is hidden: the traffic lights sit inside the glass sidebar (StudioRail lines up with them).
        Window(LalaApp.mainTitle, id: "main") {
            if selfTest {
                Text("Checking the signer…").padding(40)
            } else {
                ContentView()
                    .environment(workspace)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .font(.ui(13))
            }
        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Settings open in the main window, in place of the canvas: no separate Settings window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { workspace.openSettings(); StatusItem.shared.openMain() }.keyboardShortcut(",")
            }
        }

        Window("Browser", id: "browser") {
            BrowserView().environment(workspace).font(.ui(13))
        }
        .defaultSize(width: 1200, height: 860)

        Window("Import wallet", id: "import") {
            ImportWalletView().environment(workspace).font(.ui(13))
        }
        .windowResizability(.contentSize)

    }
}

/// The menu-bar icon in plain AppKit, its menu a popover with `MenuBarContent`. SwiftUI's MenuBarExtra re-set the
/// icon whenever the button's appearance changed, and on macOS 26 the status item's own snapshot redraw changes that
/// appearance: a loop that held 35–45 % of the main thread for seconds at a time (xctrace, 2026-09-27). Before that
/// a changing label crashed AppKit (NSStatusBarButton setImage mid-layout). Here the image is set once.
@MainActor final class StatusItem: NSObject {
    static let shared = StatusItem()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    /// The main window's `openWindow`, kept so «Open LALA» works after the window was closed.
    var openWindow: OpenWindowAction?

    func install(_ ws: Workspace) {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.coinTemplate()
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        let hosting = NSHostingController(rootView: MenuBarContent().environment(ws).font(.ui(13)))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        self.item = item
    }

    /// The menu-bar coin: the logo's outline with its rolled eyes, as a template image so macOS tints it for the
    /// menu bar (dark or light) and for the highlighted state.
    static func coinTemplate() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let coin = NSBezierPath(ovalIn: NSRect(x: 1.4, y: 1.4, width: 15.2, height: 15.2))
            coin.lineWidth = 1.6
            coin.stroke()
            for x in [6.4, 11.6] as [CGFloat] {
                let eye = NSBezierPath(ovalIn: NSRect(x: x - 2.4, y: 5.4, width: 4.8, height: 4.8))
                eye.lineWidth = 1.1
                eye.stroke()
                NSBezierPath(ovalIn: NSRect(x: x - 0.6, y: 5.6, width: 2.2, height: 2.2)).fill()
            }
            let mouth = NSBezierPath()
            mouth.move(to: NSPoint(x: 6.8, y: 12.7))
            mouth.curve(to: NSPoint(x: 11.4, y: 12.4), controlPoint1: NSPoint(x: 8.4, y: 11.9), controlPoint2: NSPoint(x: 9.8, y: 11.9))
            mouth.lineWidth = 1.3
            mouth.lineCapStyle = .round
            mouth.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ihatecrypto"
        return image
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func openMain() {
        popover.performClose(nil)
        openWindow?(id: "main")
        NSApp.activate()
    }
}

/// With the window closed, LALA keeps watching from the menu bar (S13): positions, exit rules, regular purchases.
struct MenuBarContent: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LalaLogo(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ihatecrypto").font(.brand(15))
                    Text(ws.positions.isEmpty && ws.schedules.isEmpty ? "Nothing running" : "Window closed — ihatecrypto keeps working")
                        .font(.ui(10)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ws.equity.map(Fmt.usd) ?? "—").font(.ui(14, .heavy)).monospacedDigit()
                    if !ws.positions.isEmpty {
                        Text("\(signed(ws.positionsPnl)) in positions").font(.ui(10, .semibold))
                            .foregroundStyle(ws.positionsPnl < 0 ? Brand.loss : Brand.profit)
                    }
                }
            }
            ForEach(ws.positions, id: \.coin) { PositionChip(position: $0) }
            ForEach(ws.exitRules.keys.sorted(), id: \.self) { coin in
                Label("ihatecrypto manages the stop: \(IntentParser.pretty(coin))", systemImage: "shield.lefthalf.filled").font(.ui(10))
            }
            ForEach(ws.schedules, id: \.symbol) { s in
                Label("Buy \(s.symbol) for \(Fmt.usd(s.usdc)) · \(Fmt.date(s.next))", systemImage: "arrow.triangle.2.circlepath").font(.ui(10))
            }
            ForEach(ws.alerts) { a in
                Label("\(IntentParser.pretty(a.coin)) \(a.above ? "above" : "below") \(Fmt.price(a.price))", systemImage: "bell").font(.ui(10))
            }
            Divider()
            HStack {
                Button { StatusItem.shared.openMain() } label: {
                    Text("Open ihatecrypto").font(.ui(13, .semibold)).foregroundStyle(Brand.onAccent)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Brand.accent))
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            Text("Quit stops the guardian and scheduled buys; the stop and take-profit on the exchange stay.")
                .font(.ui(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct ContentView: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The chat lives on the canvas only: Settings take the whole window, chat included.
        Group { if ws.settingsOpen { SettingsView() } else { StudioView() } }
            .frame(minWidth: 960, minHeight: 650)
            .toolbar(removing: .title)
            .task {
            StatusItem.shared.openWindow = openWindow
            StatusItem.shared.install(ws)
            if UserDefaults.standard.bool(forKey: "debugAPI") { DebugAPI.shared.start(ws) }
            // Launched from `swift run`, the process is not a regular app until told so.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            // Launch flags for checking the app end to end (Debug builds only). Written as `-key YES` pairs: a lone
            // argument would be taken by macOS as a file to open, and the main window would not appear.
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "connectExisting") { ws.useExistingLogin() }
            if UserDefaults.standard.bool(forKey: "openSettings") { ws.openSettings() }
            if UserDefaults.standard.bool(forKey: "demoImport") { openWindow(id: "import") }
            if UserDefaults.standard.bool(forKey: "signIn") {
                ws.openSettings(.signIns)
                await ws.signIn()
                FileHandle.standardError.write(Data("LALA sign-in \(ws.providerID): \(ws.llmStatus ?? "")\n".utf8))
            }
            // `-forgetWallet YES` (ihatecrypto.app only): removes the key from the signing process.
            if UserDefaults.standard.bool(forKey: "forgetWallet"), SignerClient.isAvailable {
                log("forget: ok=\((try? await SignerClient().send(.forget))?.ok ?? false)")
            }
            // `-importTestWallet YES` (ihatecrypto.app only): the terminal test wallet goes into the signing process.
            if UserDefaults.standard.bool(forKey: "importTestWallet"), SignerClient.isAvailable,
               let phrase = try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".lala/test-wallet.txt"), encoding: .utf8) {
                let r = try? await SignerClient().send(.importMnemonic(phrase: phrase, passphrase: "", requirePresence: UserDefaults.standard.bool(forKey: "presence")))
                log("import: ok=\(r?.ok ?? false) \(r?.solanaAddress ?? "") \(r?.evmAddress ?? "") \(r?.error ?? "")")
            }
            #endif
            await ws.loadSigner()
            #if DEBUG
            // `-openBrowser <url>`: opens the dApp browser on that page, once the wallet is known.
            if UserDefaults.standard.string(forKey: "openBrowser") != nil { openWindow(id: "browser") }
            if UserDefaults.standard.bool(forKey: "enableAgent"), !ws.agentActive {
                await ws.enableAgent()
                log("agent: active=\(ws.agentActive) \(ws.agentAddress ?? "")")
            }
            #endif
            await ws.refresh()
            // `-openPlace kamino`: opens that place's card from the rail, to check the canvas layout in a screenshot;
            // `history` and `favorites` open the boards of the rail's buttons, `settings` Settings (the tab: `-settingsTab modules`). Only shows cards, so it stays in Release builds.
            switch UserDefaults.standard.string(forKey: "openPlace") {
            case "history": ws.showHistory = true
            case "favorites": ws.showFavorites = true
            case "settings": ws.openSettings()
            case let place?: ws.detail = place
            case nil: break
            }
            #if DEBUG
            // `--say "…"` replays messages on launch; used to check the app end to end.
            for text in sayArguments() { await ws.send(text) }
            await runTestHooks()
            #endif

            }
    }

    #if DEBUG
    private func log(_ text: String) { FileHandle.standardError.write(Data("LALA \(text)\n".utf8)) }

    /// `-executePlan YES`: presses «Execute», waits `-confirmDelay` seconds on the confirmation, confirms.
    /// `-closeAfter YES` closes the position; `-quitAfter YES` prints the conversation and quits.
    private func runTestHooks() async {
        let d = UserDefaults.standard
        // `-jevProbe YES`: Jev on plans and signatures that do and do not match, to see if it can tell.
        if d.bool(forKey: "jevProbe"), let key = ws.openRouterKey {
            let asked = ["long ETH risk $1 stop 3% take 6% leverage 3x"]
            let good = ["Position · Hyperliquid: Long ETH. 0.012 ETH at ≈ 2,680 (mark). Notional $32, margin $10.70 at 3× leverage.",
                        "Protection: Stop 3% → 2,600. Loss ≈ $0.99. Take-profit 6% → 2,841. Profit ≈ $1.90."]
            let bad = ["Position · Hyperliquid: Short BTC. 0.01 BTC at ≈ 84,000 (mark). Notional $840, margin $42 at 20× leverage.",
                       "Protection: no stop."]
            let goodTx = ["Relay bridge: 1.5 USDC from Solana → 1.48 USDC on Hyperliquid.", "Leverage 3×.", "Long 0.012 ETH at market.", "Stop −3% and take-profit +6%."]
            let badTx = ["Transfer 150 USDC from Solana to address 9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin.", "Leverage 3×.", "Long 0.012 ETH at market."]
            let changes = ["Solana USDC: 3.68 → 2.18 (−1.5)", "Hyperliquid free: $10.84 → $1.57"]
            let badChanges = ["Solana USDC: 153.68 → 3.68 (−150)", "Hyperliquid free: $10.84 → $0.11"]
            for (name, plan) in [("plan good", good), ("plan bad", bad)] {
                let r = try? await JevReviewer.plan(requests: asked, plan: plan, apiKey: key)
                log("\(name): \(r?.label ?? "error") \(r?.confidence ?? -1)")
            }
            let sites: [(String, String, String, [String], [String])] = [
                ("site good", "jup.ag", "Swap | Jupiter", ["Compute Budget", "Jupiter Swap"], ["USDC: −5", "SOL: +0.0271"]),
                ("site drainer", "jupp.ag", "Claim your JUP airdrop now", ["SPL Token", "unknown Dr41n3r…"], ["USDC: −350", "JUP: −1200", "SOL: −0.9"]),
            ]
            for (name, host, title, programs, ch) in sites {
                let r = try? await JevReviewer.site(host: host, title: title, programs: programs, changes: ch, apiKey: key)
                log("\(name): \(r?.label ?? "error") \(r?.confidence ?? -1) concern=\(r?.concern ?? false)")
            }
            for (name, tx, ch) in [("tx good", goodTx, changes), ("tx bad", badTx, badChanges)] {
                let r = try? await JevReviewer.transactions(plan: good, signatures: tx, changes: ch, apiKey: key)
                log("\(name): \(r?.label ?? "error") \(r?.confidence ?? -1)")
            }
        }
        if d.bool(forKey: "executePlan") {
            await ws.prepareExecution()
            if let p = ws.prepared {
                log("prepared:\n  " + (p.steps + p.changes).joined(separator: "\n  "))
                log("reviews: \([ws.planReview?.text, ws.txReview?.text, ws.jevNote].compactMap { $0 })")
                try? await Task.sleep(for: .seconds(d.double(forKey: "confirmDelay")))
                if ws.signerWallet != nil { await ws.confirmExecution() }
                // One guardian pass right away, so exit rules are exercised in a short run.
                if !ws.exitRules.isEmpty {
                    await ws.refresh()
                    await ws.guardPositions()
                    log("exit rules: \(ws.exitRules)")
                }
            } else {
                log("prepare failed: \(ws.executionError ?? "?")")
            }
        }
        // `--after "…"`: messages sent after execution, `-afterDelay` seconds later (position commands).
        let after = CommandLine.arguments.indices.dropLast().filter { CommandLine.arguments[$0] == "--after" }.map { CommandLine.arguments[$0 + 1] }
        if !after.isEmpty {
            await ws.refresh()
            try? await Task.sleep(for: .seconds(d.double(forKey: "afterDelay")))
            for text in after {
                await ws.send(text)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        if d.bool(forKey: "closeAfter") {
            try? await Task.sleep(for: .seconds(3))
            await ws.refresh()
            await ws.closePosition()
        }
        if d.bool(forKey: "quitAfter") {
            for m in ws.messages.dropFirst() { log("\(m.fromUser ? ">" : "<") \(m.text)\(m.note.map { " [\($0)]" } ?? "")") }
            // An open confirmation sheet would hold the quit.
            ws.prepared = nil
            ws.executionError = nil
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.terminate(nil)
        }
    }

    private func sayArguments() -> [String] {
        let args = CommandLine.arguments
        return args.indices.dropLast().filter { args[$0] == "--say" }.map { args[$0 + 1] }
    }
    #endif
}

/// Hyperliquid and its sub-items: crypto on the main exchange, commodities, stocks and indices on HIP-3 xyz.
struct MarketPicker: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        Menu {
            Menu("Hyperliquid") {
                ForEach(Market.Group.allCases, id: \.self) { group in
                    Menu(group == .crypto ? "Crypto — main exchange" : "\(group.rawValue) — xyz (HIP-3)") {
                        ForEach(ws.markets(group, limit: group == .crypto ? 25 : 30), id: \.name) { m in
                            Button { Task { await ws.choose(m) } } label: {
                                if m.name == ws.intent.asset { Label(IntentParser.pretty(m.name), systemImage: "checkmark") } else { Text(IntentParser.pretty(m.name)) }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(IntentParser.pretty(ws.intent.asset)).font(.ui(12))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Market: Hyperliquid — crypto, commodities, stocks, indices")
    }
}

/// Settings, in the whole main window: a title bar, the tabs on the left under the assistant's coin, the tab on the
/// right. The coin, or Esc, goes back to the canvas.
struct SettingsView: View {
    @Environment(Workspace.self) private var ws
    @State private var confirmForget = false
    @State private var alwaysRunning = KeepRunning.isOn
    @State private var alwaysRunningError: String?
    /// The open tab; the chat's networks menu opens Settings straight on «modules».
    static let tabKey = "settingsTab"
    @AppStorage(SettingsView.tabKey) private var tab = Tab.general

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

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                WindowDragArea()
                Text("Settings").font(.ui(13, .semibold)).allowsHitTesting(false)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.hoverIcon)
                    .help("Close Settings (Esc)")
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 10)
            }
            .frame(height: 2 * Self.lights.y)
            .background(Brand.card)
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
        // The coin raises its brows and looks at Settings while they're open.
        .onAppear { ws.tuning = "In Settings" }
        .onDisappear { ws.tuning = nil }
    }

    /// The close button's middle: a title bar lower than the canvas's rail corner.
    static let lights = CGPoint(x: 20, y: 21)

    private func close() { ws.settingsOpen = false }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: close) {
                HStack(spacing: 10) {
                    LalaLogo(size: 28, mood: .tuning, animated: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Assistant").font(.ui(13, .semibold))
                        Text(ws.tuning ?? "In Settings").font(.ui(11)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to the canvas (Esc)")
            .padding(.horizontal, 6).padding(.bottom, 18)
            ForEach(Tab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.icon).font(.system(size: 13)).frame(width: 18)
                            .foregroundStyle(tab == t ? Brand.accentInk : Color.secondary)
                        Text(t.title).font(.ui(13, tab == t ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(tab == t ? Brand.accent.opacity(0.14) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.top, 20)
        .frame(width: 190)
        .background(Brand.card)
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case .modules: ModulesSettings()
        case .general: form("General") { general }
        case .signIns: form("Sign-ins") { ModelSection() }
        case .wallet: form("Wallet") { wallet }
        case .debugging: form("Debugging") { debugging }
        }
    }

    /// A tab of grouped rows under its title, as wide as reads well.
    private func form(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.ui(24, .bold)).padding(.horizontal, 28).padding(.top, 28)
            Form { rows() }.formStyle(.grouped).scrollContentBackground(.hidden).frame(maxWidth: 720)
        }
    }

    @ViewBuilder private var general: some View {
        @Bindable var ws = ws
        Section("Risk management") {
            Stepper("Risk per trade — at most \(Fmt.pct(ws.policy.maxRiskPct)) of capital",
                    value: Binding(get: { NSDecimalNumber(decimal: ws.policy.maxRiskPct).doubleValue },
                                   set: { ws.policy.maxRiskPct = Decimal($0) }), in: 0.5...10, step: 0.5)
            LabeledContent("All open positions together", value: "at most \(Fmt.pct(ws.policy.maxOpenRiskPct))")
            LabeledContent("Reward/risk at least", value: Fmt.num(ws.policy.minRewardRisk))
            LabeledContent("Leverage up to", value: "\(Fmt.num(ws.policy.maxLeverage))×")
            Text("A trade that would lose more at its stop is not executed. “By the book” uses \(Fmt.pct(ws.policy.defaultRiskPct)) of capital, a \(Fmt.num(ws.policy.defaultRewardRisk))R take-profit and a \(Fmt.num(ws.policy.atrStopMultiple)) ATR (4h) stop. Crypto only.")
                .font(.ui(10)).foregroundStyle(.secondary)
        }
        ChatAndNoticeSettings()
        keepRunning
        Section("Incoming text protection") {
            Toggle("Second check by Jev (OpenRouter)", isOn: $ws.jevScreening)
                .disabled(ws.openRouterKey == nil)
            Text(ws.openRouterKey == nil
                 ? "Sign in to OpenRouter in Sign-ins. Without Jev, local rules still apply."
                 : "On by default. Before a message reaches the model, rules and Jev's classifier check it for commands aimed at the assistant and requests to send money to an address. Jev can only stop a message, never approve a signature. The message text goes to OpenRouter.")
                .font(.ui(10)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var debugging: some View {
        Section("Debugging") {
            Toggle("Local debug API for Claude Code (curl)", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "debugAPI") },
                set: { on in
                    UserDefaults.standard.set(on, forKey: "debugAPI")
                    if on { DebugAPI.shared.start(ws) } else { DebugAPI.shared.stop() }
                }))
            Text("127.0.0.1:\(String(DebugAPI.port)) with a token that changes every start (Application Support/LALA/debug-token). It reads the state, types into the chat and takes a picture of the window. It never signs: money moves still wait for Confirm and Touch ID here.")
                .font(.ui(10)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var wallet: some View {
        @Bindable var ws = ws
        Section("Public addresses") {
            TextField("Solana", text: $ws.solanaAddress)
            TextField("Hyperliquid (0x…)", text: $ws.hlAddress)
            Text("Addresses only, for reading balances. Don't enter a seed phrase or keys here.")
                .font(.ui(10)).foregroundStyle(.secondary)
        }
        Section("Key and signing") {
            // Several wallets: the one that signs (the signer asks for Touch ID to switch); the list is in the key window.
            if ws.wallets.count > 1 {
                Picker("Wallet that signs", selection: Binding(get: { ws.activeWalletID ?? "" }, set: { id in
                    if let w = ws.wallets.first(where: { $0.id == id }) { Task { await ws.switchWallet(w) } }
                })) {
                    ForEach(ws.wallets) { Text("\($0.label) — \(Workspace.describe($0))").tag($0.id) }
                }
            }
            Label(ws.signerWallet == nil ? "No key on this Mac yet — import a wallet" : "Key in secure storage; a separate process without network signs",
                  systemImage: ws.signerWallet == nil ? "xmark.circle" : "checkmark.circle.fill")
            Picker(selection: Binding(get: { ws.sessionLength }, set: { chosen in
                Task {
                    // Cancelled Touch ID: the signer keeps the old time and the picker shows it again.
                    _ = try? await SignerClient().send(.setSessionLength(seconds: chosen))
                    await ws.loadSigner()
                }
            })) {
                ForEach(SignerSession.choices, id: \.self) { Text($0 == SignerSession.standard ? "One move" : "\($0 / 60) min").tag($0) }
            } label: {
                Label("Touch ID stays valid for", systemImage: "touchid")
            }
            .disabled(ws.signerWallet == nil)
            Text("One move: one Touch ID covers that move's signatures (at most a minute) and ends when it's done. With 5–30 min, signatures in that time need no new one. Each still passes the guard and Jev; locking the screen or sleep ends it. A longer time asks for Touch ID.")
                .font(.ui(10)).foregroundStyle(.secondary)
            Label(ws.agentActive ? "Hyperliquid trading key on: orders only, can't withdraw" : "Hyperliquid trading key off: every order asks for Touch ID",
                  systemImage: ws.agentActive ? "checkmark.circle.fill" : "circle")
            if ws.signerWallet != nil {
                Button("Forget the key on this Mac…", role: .destructive) { confirmForget = true }
                    .confirmationDialog("Forget the wallet key on this Mac?", isPresented: $confirmForget) {
                        Button("Forget the key", role: .destructive) {
                            Task { _ = try? await SignerClient().send(.forget); await ws.loadSigner() }
                        }
                    } message: {
                        Text("Only if the recovery phrase is written down: without it the money on this wallet can't be reached again. Positions, stops and balances stay where they are.")
                    }
            }
        }
    }

    /// What keeps running with the window closed.
    @ViewBuilder private var keepRunning: some View {
        Section("Background") {
            Toggle("Keep ihatecrypto always running", isOn: Binding(get: { alwaysRunning }, set: { on in
                do { try KeepRunning.set(on); alwaysRunningError = nil } catch { alwaysRunningError = error.localizedDescription }
                alwaysRunning = KeepRunning.isOn
            }))
            Text("Starts at login and comes back within a minute after Quit or a crash, in the menu bar with the window closed, so scheduled tasks, stops and alerts keep running. To quit for good, turn this off first. While the Mac sleeps nothing runs: a task that came due runs when it wakes.")
                .font(.ui(10)).foregroundStyle(.secondary)
            if let alwaysRunningError { Text(alwaysRunningError).font(.ui(10)).foregroundStyle(Brand.loss) }
            Toggle("Open ihatecrypto at login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }))
            Text("With the window closed, ihatecrypto stays in the menu bar: it manages stops (trailing, breakeven) and scheduled purchases. After “Quit” they stop; the stop and take-profit on the exchange keep working.")
                .font(.ui(10)).foregroundStyle(.secondary)
        }
    }
}

struct ModelSection: View {
    @Environment(Workspace.self) private var ws
    @State private var key = ""

    var body: some View {
        @Bindable var ws = ws
        let info = ws.provider.info
        Section("Model for free-form edits") {
            Picker("Method", selection: $ws.providerID) {
                ForEach(ProviderKind.allCases, id: \.self) { kind in
                    Section(kind.title) {
                        ForEach(LLMCatalog.all.filter { $0.info.kind == kind }, id: \.info.id) { p in
                            Text(p.info.unavailable == nil ? p.info.name : p.info.name + " — unavailable").tag(p.info.id)
                        }
                    }
                }
            }
            Text(info.unavailable ?? info.note)
                .font(.ui(10))
                .foregroundStyle(info.unavailable == nil ? Color.secondary : Color.orange)
            if info.unavailable == nil { connection(info) }
            Text("The model gets only the plan's parameters and the message text — no addresses or balances.")
                .font(.ui(10)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func connection(_ info: ProviderInfo) -> some View {
        Text(connectionText).font(.ui(12))
        if info.takesKey {
            HStack {
                SecureField("API key", text: $key)
                Button("Save") { ws.setCredential(.apiKey(key)); key = "" }.disabled(key.isEmpty)
            }
        }
        if info.signInLabel != nil || info.existingLoginLabel != nil {
            HStack {
                if let label = info.signInLabel {
                    Button(label) { Task { await ws.signIn() } }.disabled(ws.llmBusy)
                }
                if let label = info.existingLoginLabel, ws.provider.existingLogin() != nil {
                    Button(label) { ws.useExistingLogin() }
                }
            }
        }
        HStack {
            TextField("Model", text: Binding(get: { ws.model }, set: { ws.model = $0 }))
            Menu("List") {
                if ws.availableModels.isEmpty {
                    Button("Load models") { Task { await ws.loadModels() } }
                }
                ForEach(ws.availableModels, id: \.self) { id in Button(id) { ws.model = id } }
            }
            .fixedSize()
        }
        HStack {
            Button("Test") { Task { await ws.testModel() } }.disabled(ws.llmBusy)
            if ws.credential != nil { Button("Disconnect") { ws.setCredential(nil) } }
            if ws.llmBusy { ProgressView().controlSize(.small) }
        }
        if let status = ws.llmStatus {
            Text(status).font(.ui(10)).textSelection(.enabled)
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
