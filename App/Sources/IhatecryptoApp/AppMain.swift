import AppKit
import GuardJev
import IhatecryptoCore
import LLMCatalog
import LLMCore
import ServiceManagement
import SignerAPI
import SwiftUI

@main
struct AppMain: App {
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
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.ihatecrypto.mac")
            .contains(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
            exit(0)
        }
        if selfTest {
            Task { exit(await SignerSelfTest.run() ? 0 : 1) }
        } else {
            // Balances, exit rules and regular purchases keep running with the window closed; ihatecrypto stays in the
            // menu bar until ⌘Q.
            let ws = workspace
            Task { await ws.watch() }
            Updater.shared.start(ws)
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
                        FileHandle.standardError.write(Data("ihatecrypto browser script: \(r.map { "\($0)" } ?? "nil")\n".utf8))
                        try? await Task.sleep(for: .seconds(resultAfter / 2))
                    } else {
                        try? await Task.sleep(for: .seconds(resultAfter))
                    }
                    let text = (try? await ws.browser.webView.evaluateJavaScript("document.body.innerText")) as? String ?? "no text"
                    FileHandle.standardError.write(Data("ihatecrypto browser page:\n\(text)\n".utf8))
                    for m in ws.messages.dropFirst() { FileHandle.standardError.write(Data("ihatecrypto < \(m.text)\n".utf8)) }
                    NSApp.terminate(nil)
                }
            }
            // `-closeWindowTest YES`: closes the main window and checks the loop still refreshes from the menu bar.
            if UserDefaults.standard.bool(forKey: "closeWindowTest") {
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    NSApp.windows.filter { $0.title == AppMain.mainTitle }.forEach { $0.close() }
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
        Window(AppMain.mainTitle, id: "main") {
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
            // Only in the copy from the site: a local build has no feed.
            CommandGroup(after: .appInfo) {
                if let version = workspace.updateReady { Button("Restart to Update to \(version)") { Updater.shared.restartToUpdate() } }
                if Updater.shared.available { Button("Check for Updates…") { Updater.shared.check() } }
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
    /// The main window's `openWindow`, kept so «Open ihatecrypto» works after the window was closed.
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
            // An app in full screen (a browser) is a Space of its own: the popover opened on ihatecrypto's Space,
            // unseen, until it may join full-screen Spaces and is ordered in again.
            guard let window = popover.contentViewController?.view.window else { return }
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.orderFrontRegardless()
            window.makeKey()
        }
    }

    func openMain() {
        popover.performClose(nil)
        openWindow?(id: "main")
        NSApp.activate()
    }
}

/// With the window closed, ihatecrypto keeps watching from the menu bar (S13): positions, exit rules, regular purchases.
struct MenuBarContent: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BrandLogo(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ihatecrypto").font(.brand(15))
                    Text(ws.positions.isEmpty && ws.schedules.isEmpty ? "Nothing running" : "Window closed — ihatecrypto keeps working")
                        .font(.ui(10)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ws.total.map(Fmt.usd) ?? "—").font(.ui(14, .heavy)).monospacedDigit()
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
            // A new version downloaded: one click installs it and opens the app again.
            if let version = ws.updateReady {
                Button { Updater.shared.restartToUpdate() } label: {
                    Label("ihatecrypto \(version) is ready · Restart to update", systemImage: "arrow.down.circle.fill")
                        .font(.ui(12, .semibold)).foregroundStyle(Brand.accentInk)
                }
                .buttonStyle(.plain).pointerStyle(.link)
            }
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
    /// «Look around first» on the first screen: it doesn't come back.
    @AppStorage("welcomeDone") private var welcomeDone = false
    /// The onboarding's step while it runs (Onboarding.swift); empty otherwise.
    @AppStorage("onboardingStep") private var onboardingStep = ""

    var body: some View {
        // The chat lives on the canvas only: Settings take the whole window, chat included.
        Group {
            if ws.settingsOpen { SettingsView() }
            else if !onboardingStep.isEmpty { OnboardingView() }
            else if showWelcome { WelcomeView { welcomeDone = true } }
            else { StudioView() }
        }
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
                FileHandle.standardError.write(Data("ihatecrypto sign-in \(ws.providerID): \(ws.llmStatus ?? "")\n".utf8))
            }
            // `-forgetWallet YES` (ihatecrypto.app only): removes the key from the signing process.
            if UserDefaults.standard.bool(forKey: "forgetWallet"), SignerClient.isAvailable {
                log("forget: ok=\((try? await SignerClient().send(.forget))?.ok ?? false)")
            }
            // `-importTestWallet YES` (ihatecrypto.app only): the terminal test wallet goes into the signing process.
            if UserDefaults.standard.bool(forKey: "importTestWallet"), SignerClient.isAvailable,
               let phrase = try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ihatecrypto/test-wallet.txt"), encoding: .utf8) {
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
            // A crash since the last launch: one line in the chat; the report is kept (Crashes.swift).
            if let crash = Crashes.collect().first {
                ws.reply(ws.say("ihatecrypto closed unexpectedly on \(Fmt.date(crash.date)) — \(crash.summary). The report is kept in Application Support/ihatecrypto/Crashes.",
                                "ihatecrypto упал \(Fmt.date(crash.date)) — \(crash.summary). Отчёт сохранён в Application Support/ihatecrypto/Crashes."))
            }
            // `-openPlace kamino`: opens that place's card from the rail, to check the canvas layout in a screenshot;
            // `history` and `favorites` open the boards of the rail's buttons, `settings` Settings (the tab: `-settingsTab modules`). Only shows cards, so it stays in Release builds.
            switch UserDefaults.standard.string(forKey: "openPlace") {
            case "history": ws.showHistory = true
            case "favorites": ws.showFavorites = true
            case "schedule": ws.showSchedule = true
            // `schedule:task:<id>`, `schedule:buy:SOL`, `schedule:perp:BTC`: that item in detail.
            case let item? where item.hasPrefix("schedule:"): ws.openScheduleCanvas(String(item.dropFirst(9))); ws.showSchedule = true
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
    private func log(_ text: String) { FileHandle.standardError.write(Data("ihatecrypto \(text)\n".utf8)) }

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
                        // Names grouped and sorted once per market load (Workspace.loadMarkets); the market itself is
                        // read on the click, so a price moving doesn't redraw the menus.
                        ForEach(ws.marketNames[group] ?? [], id: \.self) { name in
                            Button { Task { if let m = ws.markets[name] { await ws.choose(m) } } } label: {
                                if name == ws.intent.asset { Label(IntentParser.pretty(name), systemImage: "checkmark") } else { Text(IntentParser.pretty(name)) }
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
                    BrandLogo(size: 28, mood: .tuning, animated: true)
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
        case .general: SettingsPage(title: "General", line: "How the assistant trades, talks and runs in the background.") { general }
        case .signIns: SettingsPage(title: "Sign-ins", line: "The model that reads your messages. Optional: typed commands work without one.") { ModelSection() }
        case .wallet: SettingsPage(title: "Wallet", line: "The key that signs, and how long one Touch ID lasts.") { wallet }
        case .debugging: SettingsPage(title: "Debugging", line: "Tools for checking ihatecrypto from Claude Code.") { debugging }
        }
    }

    @ViewBuilder private var general: some View {
        @Bindable var ws = ws
        SettingsColumns {
            risk
            ChatAndNoticeSettings()
        } narrow: {
            SettingsCard(icon: "checkmark.seal", title: "Safe search", line: "Tokens on Solana") {
                Toggle("Safe search", isOn: $ws.safeSearch).toggleStyle(AccentSwitch())
            } content: {
                SettingsHint(ws.safeSearch
                             ? "On: on Solana ihatecrypto buys only verified coins — SOL, BTC, ETH, JUP and JitoSOL. Look-alikes of famous tokens can't slip in."
                             : "Off: any Solana token can be bought by its mint through Jupiter. Before the card, ihatecrypto says what is risky about it — a creator who can freeze or print it, a thin pool, no verification. Confirm and the simulation still apply.")
            }
            keepRunning
            SettingsCard(icon: "checkmark.shield", title: "Second check", line: "Reads each command and plan a second time") {
                Toggle("Second check", isOn: $ws.jevScreening).toggleStyle(AccentSwitch())
            } content: {
                if ws.openRouterKey == nil {
                    SettingsRow("OpenRouter · not connected") { Button("Connect") { Task { await ws.signInJev() } } }
                }
                if let status = ws.jevStatus { SettingsHint(status) }
                SettingsHint(ws.openRouterKey == nil
                             ? "OpenRouter adds a separate model to the check; the chat keeps its own. Without it the chat's model reads each command and plan a second time, and local rules check incoming text. It can only stop something, never approve a signature."
                             : "The chat's model and a separate model on OpenRouter read each command and plan against your words; pasted text with an address or a link is checked for commands aimed at the assistant. It can only stop something, never approve a signature. The texts go to OpenRouter.")
            }
        }
    }

    /// The limits code checks before every trade, as numbers; only the risk per trade is the user's to change.
    private var risk: some View {
        let p = ws.policy
        return SettingsCard(icon: "scalemass", title: "Risk", line: "Checked in code before every trade") {
            HStack(spacing: 8) {
                number("Risk per trade", Fmt.pct(p.maxRiskPct)) {
                    HStack(spacing: 4) {
                        step("minus", "Less risk per trade", enabled: p.maxRiskPct > 0.5) { ws.policy.maxRiskPct -= 0.5 }
                        step("plus", "More risk per trade", enabled: p.maxRiskPct < 10) { ws.policy.maxRiskPct += 0.5 }
                    }
                }
                number("All positions", Fmt.pct(p.maxOpenRiskPct)) { note("at most") }
                number("Reward / risk", Fmt.num(p.minRewardRisk)) { note("at least") }
                number("Leverage", "\(Fmt.num(p.maxLeverage))×") { note("up to") }
            }
            .fixedSize(horizontal: false, vertical: true)
            SettingsHint("By the book: \(Fmt.pct(p.defaultRiskPct)) of capital, a \(Fmt.num(p.defaultRewardRisk))R take-profit and a \(Fmt.num(p.atrStopMultiple)) ATR (4h) stop. A trade that would lose more at its stop is not executed. Crypto only.")
        }
    }

    private func number(_ label: String, _ value: String, @ViewBuilder below: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.ui(22, .bold)).monospacedDigit()
            below().padding(.top, 2)
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func note(_ text: String) -> some View { Text(text).font(.ui(10.5)).foregroundStyle(.tertiary) }

    private func step(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 26, height: 22).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.09)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4).help(help)
    }

    @ViewBuilder private var debugging: some View {
        SettingsColumns {
            SettingsCard(icon: "terminal", title: "Local debug API", line: "For Claude Code, through curl") {
                Toggle("Local debug API", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "debugAPI") },
                    set: { on in
                        UserDefaults.standard.set(on, forKey: "debugAPI")
                        if on { DebugAPI.shared.start(ws) } else { DebugAPI.shared.stop() }
                    }))
                    .toggleStyle(AccentSwitch())
            } content: {
                SettingsHint("127.0.0.1:\(String(DebugAPI.port)) with a token that changes every start (Application Support/ihatecrypto/debug-token). It reads the state, types into the chat and takes a picture of the window. It never signs: money moves still wait for Confirm and Touch ID here.")
            }
        } narrow: {
            EmptyView()
        }
    }

    @ViewBuilder private var wallet: some View {
        VStack(spacing: 14) {
            SettingsColumns {
                signer
                addresses
            } narrow: {
                touchID
                tradingKey
            }
            if ws.signerWallet != nil { forget }
        }
    }

    private var signer: some View {
        SettingsCard(icon: "creditcard", title: "Wallet that signs", line: ws.wallets.count > 1 ? "Switching asks for Touch ID" : "The key on this Mac") {
            // Several wallets: the one that signs (the signer asks for Touch ID to switch); the list is in the key window.
            if ws.wallets.count > 1 {
                Menu("Switch") {
                    ForEach(ws.wallets) { w in
                        Button("\(w.label) — \(Workspace.describe(w))") { Task { await ws.switchWallet(w) } }.disabled(w.id == ws.activeWalletID)
                    }
                }
                .fixedSize()
            }
        } content: {
            if let w = ws.activeWallet {
                HStack(spacing: 12) {
                    Text(w.label.prefix(1).uppercased()).font(.ui(16, .bold)).foregroundStyle(.black.opacity(0.8))
                        .frame(width: 38, height: 38).background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Brand.accent))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(w.label).font(.ui(14, .semibold))
                        Text(Workspace.kindName(w)).font(.ui(10.5)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    ForEach([("Solana", w.solana), ("EVM", w.evm), ("NEAR", w.near)], id: \.0) { pair in
                        if let address = pair.1 {
                            CopyButton(title: "\(pair.0) \(address.prefix(4))…\(address.suffix(4))", text: address, help: "Copy the \(pair.0) address")
                        }
                    }
                }
            }
            Label(ws.signerWallet == nil ? "No key on this Mac yet — import a wallet" : "Key in secure storage; a separate process without network signs",
                  systemImage: ws.signerWallet == nil ? "xmark.circle" : "checkmark.circle.fill")
                .font(.ui(12)).foregroundStyle(ws.signerWallet == nil ? Color.secondary : Brand.profit)
        }
    }

    @ViewBuilder private var addresses: some View {
        @Bindable var ws = ws
        SettingsCard(icon: "eye", title: "Addresses for balances", line: "Read-only. Never a seed phrase or a key here.") {
            HStack(spacing: 8) {
                field("Solana", text: $ws.solanaAddress)
                field("Hyperliquid (0x…)", text: $ws.hlAddress)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.ui(10.5)).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder).font(.system(size: 11.5, design: .monospaced)).labelsHidden()
        }
    }

    private var touchID: some View {
        SettingsCard(icon: "touchid", title: "Touch ID", line: "How long one touch lasts") {
            // Drawn segments: the system's segmented control keeps its blue whatever the tint.
            HStack(spacing: 2) {
                ForEach(SignerSession.choices, id: \.self) { choice in
                    let on = choice == ws.sessionLength
                    Button {
                        Task {
                            // Cancelled Touch ID: the signer keeps the old time and the segment shows it again.
                            _ = try? await SignerClient().send(.setSessionLength(seconds: choice))
                            await ws.loadSigner()
                        }
                    } label: {
                        Text(choice == SignerSession.standard ? "One move" : "\(choice / 60) min").font(.ui(11.5, .semibold))
                            .foregroundStyle(on ? Color.black.opacity(0.85) : Color.primary)
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Brand.accent : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            .disabled(ws.signerWallet == nil)
            SettingsHint("One move: one Touch ID covers that move's signatures (at most a minute) and ends when it's done. With 5–30 min, signatures in that time need no new one. Each still passes the guard and Jev; locking the screen or sleep ends it. A longer time asks for Touch ID.")
        }
    }

    private var tradingKey: some View {
        SettingsCard(icon: "bolt", title: "Trading key", line: "Hyperliquid") {
            SettingsPill(text: ws.agentActive ? "On" : "Off", good: ws.agentActive)
        } content: {
            SettingsHint(ws.agentActive ? "On: it places orders only and can't withdraw."
                         : ws.ledgerActive ? "Off: every order asks for the Ledger's buttons." : "Off: every order asks for Touch ID.")
            // Hyperliquid accepts the key once the account has had a deposit; the onboarding offers it too.
            if !ws.agentActive, ws.activeWallet?.evm != nil {
                Button(ws.ledgerActive ? "Approve a trading key on the Ledger" : "Approve a trading key", systemImage: "key") {
                    Task { await ws.enableAgent() }
                }
                .disabled(ws.executing)
            }
        }
    }

    private var forget: some View {
        SettingsCard(icon: "trash", title: "Forget the key on this Mac",
                     line: "Only if the recovery phrase is written down. Positions, stops and balances stay where they are.", danger: true) {
            Button("Forget the key…", role: .destructive) { confirmForget = true }
                .foregroundStyle(Brand.loss)
                .confirmationDialog("Forget the wallet key on this Mac?", isPresented: $confirmForget) {
                    Button("Forget the key", role: .destructive) {
                        Task {
                            // The signer's own wallet goes (not a Ledger in front of it), and what this Mac kept for it.
                            let id = (try? await SignerClient().send(.status))?.activeWallet
                            if (try? await SignerClient().send(.forget))?.ok == true, let id { ws.walletRemoved(id) }
                            await ws.loadSigner()
                        }
                    }
                } message: {
                    Text("Only if the recovery phrase is written down: without it the money on this wallet can't be reached again. Positions, stops and balances stay where they are.")
                }
        } content: {
            EmptyView()
        }
    }

    /// What keeps running with the window closed.
    private var keepRunning: some View {
        SettingsCard(icon: "moon.stars", title: "Background", line: "Stops, alerts and scheduled buys with the window closed") {
            SettingsRow("Keep always running") {
                Toggle("Keep ihatecrypto always running", isOn: Binding(get: { alwaysRunning }, set: { on in
                    do { try KeepRunning.set(on); alwaysRunningError = nil } catch { alwaysRunningError = error.localizedDescription }
                    alwaysRunning = KeepRunning.isOn
                }))
                .toggleStyle(AccentSwitch())
            }
            SettingsHint("Starts at login and comes back within a minute after Quit or a crash, in the menu bar with the window closed. To quit for good, turn this off first. While the Mac sleeps nothing runs: a task that came due runs when it wakes.")
            if let alwaysRunningError { Text(alwaysRunningError).font(.ui(10)).foregroundStyle(Brand.loss) }
            SettingsRow("Open at login") {
                Toggle("Open ihatecrypto at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }))
                    .toggleStyle(AccentSwitch())
            }
            SettingsHint("After “Quit” its own stops (trailing, breakeven) and scheduled buys stop; the stop and take-profit on the exchange keep working.")
        }
    }
}

// MARK: - Settings cards (S01: the Modules look on every tab)

/// A Settings tab: its title and line, then cards filling the width, as on Modules.
struct SettingsPage<Content: View>: View {
    let title: String
    let line: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.ui(24, .bold))
                    Text(line).font(.ui(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(28)
        }
    }
}

/// Wide cards on the left, narrow ones on the right: about two thirds and one third of the page.
struct SettingsColumns<Wide: View, Narrow: View>: View {
    @ViewBuilder let wide: Wide
    @ViewBuilder let narrow: Narrow

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) { wide }.frame(maxWidth: .infinity)
            VStack(spacing: 14) { narrow }.frame(minWidth: 260, maxWidth: 380)
        }
    }
}

/// A card like a Modules kind: an icon tile, a title and its line, a control on the right, what it holds below.
struct SettingsCard<Trailing: View, Content: View>: View {
    let icon: String
    let title: String
    let line: String
    var danger = false
    let trailing: Trailing
    let content: Content

    init(icon: String, title: String, line: String, danger: Bool = false,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        (self.icon, self.title, self.line, self.danger) = (icon, title, line, danger)
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        let tint = danger ? Brand.loss : Brand.accent
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(danger ? Brand.loss : Brand.accentInk)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.16)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.ui(15, .semibold))
                    Text(line).font(.ui(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                trailing
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Brand.glassFill))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(danger ? Brand.loss.opacity(0.4) : Brand.glassRim))
    }
}

extension SettingsCard where Trailing == EmptyView {
    init(icon: String, title: String, line: String, danger: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(icon: icon, title: title, line: line, danger: danger, trailing: { EmptyView() }, content: content)
    }
}

/// A row inside a card: a hairline above, the label on the left, its control on the right.
struct SettingsRow<Control: View>: View {
    let label: String
    let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text(label).font(.ui(12.5)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                control
            }
            .padding(.top, 8)
        }
    }
}

struct SettingsHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.ui(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// «● Connected» / «Off» beside a card's title.
struct SettingsPill: View {
    let text: String
    let good: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(good ? Brand.profit : Color.secondary).frame(width: 6, height: 6)
            Text(text).font(.ui(11, .semibold))
        }
        .foregroundStyle(good ? Brand.profit : Color.secondary)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill((good ? Brand.profit : Color.primary).opacity(0.1)))
    }
}

struct ModelSection: View {
    @Environment(Workspace.self) private var ws
    @State private var key = ""
    /// The three ways most people come in by; any other provider is under «API key or a model on this Mac».
    private static let ways = ["claude-code", "chatgpt", "openrouter"]
    /// Commands the local parsers read without any model.
    private static let commands = ["long ETH risk $5", "send 5 USDC to Bybit", "stop 3%"]

    var body: some View {
        VStack(spacing: 14) {
            SettingsColumns {
                model
            } narrow: {
                SettingsCard(icon: "text.bubble", title: "Without a model", line: "Typed commands still work") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Self.commands, id: \.self) { c in
                            Button { ws.draft = c; ws.settingsOpen = false } label: {
                                Text(c).font(.system(size: 11.5, design: .monospaced))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Brand.glassRim))
                            }
                            .buttonStyle(.plain).pointerStyle(.link).help("Put it in the chat")
                        }
                    }
                    SettingsHint("Commands like these work with no subscription, in English or Russian. A model adds free wording in any language: «закрой половину, если упадёт ниже 3000».")
                }
            }
            SettingsCard(icon: "lock", title: "Nothing moves without you", line: "Confirm and Touch ID, every time") {
                SettingsHint("Whatever you type and whichever model reads it, money moves only after Confirm and Touch ID. The model gets only the plan's parameters and the message text — never keys, addresses or balances.")
            }
        }
    }

    private var model: some View {
        let info = ws.provider.info
        return SettingsCard(icon: "sparkles", title: "Model", line: "Reads your words and the plan. Never sees keys, addresses or balances.") {
            SettingsPill(text: ws.hasModel ? "Connected" : "Not connected", good: ws.hasModel)
        } content: {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 8) {
                way("claude-code", "Claude subscription", "Uses the Claude Code on this Mac", logo: "llm-claude")
                way("chatgpt", "ChatGPT subscription", "Plus or Pro · sign in once in the browser", logo: "llm-openai")
                way("openrouter", "OpenRouter", "One key for many models", logo: "llm-openrouter")
                other
            }
            Text(info.unavailable ?? info.note)
                .font(.ui(10))
                .foregroundStyle(info.unavailable == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            if info.unavailable == nil { connection(info) }
        }
    }

    private func tile(selected: Bool, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) { content() }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? Brand.accent.opacity(0.08) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(selected ? Brand.accent : Brand.glassRim))
            .contentShape(Rectangle())
    }

    private func way(_ id: String, _ title: String, _ line: String, logo: String) -> some View {
        let on = ws.providerID == id
        return Button { ws.providerID = id } label: {
            tile(selected: on) {
                TokenLogo(name: logo, size: 26).clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.ui(12.5, .semibold))
                    Text(line).font(.ui(10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.accentInk) }
            }
        }
        .buttonStyle(.plain)
    }

    /// Every other provider: API keys and credits, models on this Mac, and the subscriptions that can't sign in yet.
    private var other: some View {
        let on = !Self.ways.contains(ws.providerID)
        return tile(selected: on) {
            Image(systemName: "key.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 4) {
                Text("API key or a model on this Mac").font(.ui(12.5, .semibold))
                Menu(on ? ws.provider.info.name : "Choose…") {
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
            Spacer(minLength: 4)
            if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.accentInk) }
        }
    }

    @ViewBuilder
    private func connection(_ info: ProviderInfo) -> some View {
        SettingsRow(connectionText) {
            if let label = info.existingLoginLabel, ws.provider.existingLogin() != nil {
                Button(label) { ws.useExistingLogin() }
            }
            if let label = info.signInLabel {
                Button(label) { Task { await ws.signIn() } }.disabled(ws.llmBusy)
            }
        }
        if info.takesKey {
            HStack {
                SecureField("API key", text: $key).textFieldStyle(.roundedBorder)
                Button("Save") { ws.setCredential(.apiKey(key)); key = "" }.disabled(key.isEmpty)
            }
        }
        SettingsRow("Model") {
            TextField("Model", text: Binding(get: { ws.model }, set: { ws.model = $0 }))
                .textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 220)
            Menu("List") {
                if ws.availableModels.isEmpty {
                    Button("Load models") { Task { await ws.loadModels() } }
                }
                ForEach(ws.availableModels, id: \.self) { id in Button(id) { ws.model = id } }
            }
            .fixedSize()
            Button("Test") { Task { await ws.testModel() } }.disabled(ws.llmBusy)
            if ws.credential != nil { Button("Disconnect") { ws.setCredential(nil) } }
            if ws.llmBusy { ProgressView().controlSize(.small) }
        }
        if let status = ws.llmStatus {
            Text(status).font(.ui(10)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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

extension ContentView {
    /// The first screen, until the signer has a wallet or an address is watched, unless put aside. A wallet made from
    /// it ends it by itself. `-showWelcome YES` (Debug) shows it anyway.
    var showWelcome: Bool {
        guard !welcomeDone else { return false }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "showWelcome") { return true }
        #endif
        return ws.signerHasWallet == false && ws.solanaAddress.isEmpty && ws.hlAddress.isEmpty
    }
}
