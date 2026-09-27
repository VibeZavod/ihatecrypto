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
    /// Created once with the app, so the watch loop below outlives the window.
    private let workspace = Workspace()

    /// `-signerSelfTest YES`: checks the signing process inside LALA.app with the public test phrase, then quits.
    /// The main window stays empty so nothing else (balances, model logins) runs meanwhile.
    private let selfTest = UserDefaults.standard.bool(forKey: "signerSelfTest")

    init() {
        if selfTest {
            Task { exit(await SignerSelfTest.run() ? 0 : 1) }
        } else {
            // Balances, exit rules and regular purchases keep running with the window closed; LALA stays in the
            // menu bar until ⌘Q.
            let ws = workspace
            Task { await ws.watch() }
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
                    NSApp.windows.filter { $0.title == "LALA" }.forEach { $0.close() }
                    let before = ws.updatedAt
                    try? await Task.sleep(for: .seconds(40))
                    let log = "LALA window closed; still running; refreshed after close: \(ws.updatedAt != before) (\(ws.updatedAt.map { "\($0)" } ?? "nil"))\n"
                    FileHandle.standardError.write(Data(log.utf8))
                    NSApp.terminate(nil)
                }
            }
        }
    }

    var body: some Scene {
        Window("LALA", id: "main") {
            if selfTest {
                Text("Checking the signer…").padding(40)
            } else {
                ContentView()
                    .environment(workspace)
                    .environment(\.locale, Locale(identifier: "en_US"))
            }
        }
        .defaultSize(width: 1320, height: 860)

        Window("Browser", id: "browser") {
            BrowserView().environment(workspace)
        }
        .defaultSize(width: 1200, height: 860)

        Window("Import wallet", id: "import") {
            ImportWalletView().environment(workspace)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView().environment(workspace)
        }
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
        item.button?.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "LALA")
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        let hosting = NSHostingController(rootView: MenuBarContent().environment(ws))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        self.item = item
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
                    Text("LALA").font(.system(size: 14, weight: .bold))
                    Text(ws.positions.isEmpty && ws.schedules.isEmpty ? "Nothing running" : "Window closed — LALA keeps working")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ws.equity.map(Fmt.usd) ?? "—").font(.system(size: 14, weight: .heavy)).monospacedDigit()
                    if !ws.positions.isEmpty {
                        Text("\(signed(ws.positionsPnl)) in positions").font(.caption.weight(.semibold))
                            .foregroundStyle(ws.positionsPnl < 0 ? Brand.loss : Brand.profit)
                    }
                }
            }
            ForEach(ws.positions, id: \.coin) { PositionChip(position: $0) }
            ForEach(ws.exitRules.keys.sorted(), id: \.self) { coin in
                Label("LALA manages the stop: \(IntentParser.pretty(coin))", systemImage: "shield.lefthalf.filled").font(.caption)
            }
            ForEach(ws.schedules, id: \.symbol) { s in
                Label("Buy \(s.symbol) for \(Fmt.usd(s.usdc)) · \(Fmt.date(s.next))", systemImage: "arrow.triangle.2.circlepath").font(.caption)
            }
            ForEach(ws.alerts) { a in
                Label("\(IntentParser.pretty(a.coin)) \(a.above ? "above" : "below") \(Fmt.price(a.price))", systemImage: "bell").font(.caption)
            }
            Divider()
            HStack {
                Button("Open LALA") { StatusItem.shared.openMain() }.buttonStyle(.borderedProminent)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            Text("Quit stops the guardian and scheduled buys; the stop and take-profit on the exchange stay.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct ContentView: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var routeExpanded = false
    /// «studio» — wallet rail, canvas and floating chat (R4); «classic» — chat beside the route.
    @AppStorage("layout") private var layout = "studio"

    var body: some View {
        Group {
            if layout == "studio" {
                StudioView()
            } else {
                HStack(spacing: 0) {
                    if !routeExpanded {
                        ChatView()
                            .frame(minWidth: 390, maxWidth: .infinity)
                        Divider()
                    }
                    RouteWorkspace(expanded: $routeExpanded)
                        .frame(minWidth: routeExpanded ? 800 : 500, maxWidth: .infinity)
                }
            }
        }
            .frame(minWidth: 960, minHeight: 650)
            .toolbar {
                if layout != "studio" {
                    ToolbarItem(placement: .navigation) { ModelMenu() }
                    ToolbarSpacer(.flexible)
                    ToolbarItem {
                        Button { openWindow(id: "browser") } label: { Image(systemName: "globe") }
                            .help("dApp browser: LALA connects as a Solana wallet")
                    }
                    ToolbarItem { BalanceButton() }
                    ToolbarItem { SettingsLink { Image(systemName: "gearshape") } }
                    ToolbarItem {
                        Button("Studio") { layout = "studio" }.help("New layout: wallet, canvas and floating chat")
                    }
                }
            }
            .toolbar(removing: .title)
            .task {
            StatusItem.shared.openWindow = openWindow
            StatusItem.shared.install(ws)
            // Launched from `swift run`, the process is not a regular app until told so.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            // Launch flags for checking the app end to end. Written as `-key YES` pairs: a lone argument would be
            // taken by macOS as a file to open, and the main window would not appear.
            if UserDefaults.standard.bool(forKey: "connectExisting") { ws.useExistingLogin() }
            if UserDefaults.standard.bool(forKey: "openSettings") { openSettings() }
            if UserDefaults.standard.bool(forKey: "demoImport") { openWindow(id: "import") }
            if UserDefaults.standard.bool(forKey: "signIn") {
                openSettings()
                await ws.signIn()
                FileHandle.standardError.write(Data("LALA sign-in \(ws.providerID): \(ws.llmStatus ?? "")\n".utf8))
            }
            // `-forgetWallet YES` (LALA.app only): removes the key from the signing process.
            if UserDefaults.standard.bool(forKey: "forgetWallet"), SignerClient.isAvailable {
                log("forget: ok=\((try? await SignerClient().send(.forget))?.ok ?? false)")
            }
            // `-importTestWallet YES` (LALA.app only): the terminal test wallet goes into the signing process.
            if UserDefaults.standard.bool(forKey: "importTestWallet"), SignerClient.isAvailable,
               let phrase = try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".lala/test-wallet.txt"), encoding: .utf8) {
                let r = try? await SignerClient().send(.importMnemonic(phrase: phrase, passphrase: "", requirePresence: UserDefaults.standard.bool(forKey: "presence")))
                log("import: ok=\(r?.ok ?? false) \(r?.solanaAddress ?? "") \(r?.evmAddress ?? "") \(r?.error ?? "")")
            }
            await ws.loadSigner()
            // `-openBrowser <url>`: opens the dApp browser on that page, once the wallet is known.
            if UserDefaults.standard.string(forKey: "openBrowser") != nil { openWindow(id: "browser") }
            if UserDefaults.standard.bool(forKey: "enableAgent"), !ws.agentActive {
                await ws.enableAgent()
                log("agent: active=\(ws.agentActive) \(ws.agentAddress ?? "")")
            }
            await ws.refresh()
            // `-openPlace kamino`: opens that place's card from the rail, to check the canvas layout in a screenshot.
            if let place = UserDefaults.standard.string(forKey: "openPlace") { ws.detail = place }
            // `--say "…"` replays messages on launch; used to check the app end to end.
            for text in sayArguments() { await ws.send(text) }
            await runTestHooks()

            }
    }

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
}

/// Conversation stays on the left; the live route and its explanation stay visible on the right.
struct ChatView: View {
    @Environment(Workspace.self) private var ws
    @State private var draft = ""

    static let examples = ["short oil risk $1 by the book", "long ETH risk $10 stop 3%", "spread USDC across the best rates"]

    var body: some View {
        VStack(spacing: 0) {
            if ws.messages.contains(where: \.fromUser) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            // The first message is the old greeting; the empty screen replaces it.
                            ChatHistory(messages: Array(ws.messages.dropFirst()), running: ws.executing, thinking: ws.thinking)
                        }
                        .frame(maxWidth: 720)
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: ws.messages.count) {
                        withAnimation { proxy.scrollTo(ChatHistory.end, anchor: .bottom) }
                    }
                }
                Composer(draft: $draft, busy: ws.busy, send: send)
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 24)
                Text(ws.signerWallet == nil ? "Preview only: signing happens in LALA.app with the key in secure storage." : "A trade runs only after “Sign and execute”; a separate process signs it.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                Spacer()
                Text("What should we do?").font(.system(size: 28, weight: .semibold))
                Composer(draft: $draft, busy: ws.busy, send: send)
                    .frame(maxWidth: 680)
                    .padding(24)
                // One row when it fits, a column in a narrow window: a chip never breaks into two lines.
                ViewThatFits {
                    HStack(spacing: 8) { chips }
                    VStack(spacing: 8) { chips }
                }
                .padding(.horizontal, 24)
                Spacer()
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var chips: some View {
        ForEach(Self.examples, id: \.self) { example in
            Button(example) { draft = example; send() }
                .buttonStyle(.plain)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 7)
                .overlay(Capsule().strokeBorder(.separator))
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !ws.busy else { return }
        draft = ""
        Task { await ws.send(text) }
    }
}

struct Composer: View {
    @Binding var draft: String
    let busy: Bool
    let send: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Describe a trade or adjust the plan", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .padding(.vertical, 7)
                .onSubmit(send)
            ZStack {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(draft.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary)))
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .frame(width: 30, height: 30)
        }
        .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 24).fill(.fill.tertiary))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.separator.opacity(0.6)))
    }
}

/// The plan the conversation has built so far: one row per block, edited by the next message.
struct PlanCard: View {
    @Environment(Workspace.self) private var ws
    @Binding var selectedBlockID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(ws.managesPosition ? "Position" : "Plan").font(.system(size: 13, weight: .semibold))
                MarketPicker()
                Spacer()
                if let t = ws.updatedAt { Text(t, style: .time).font(.caption).foregroundStyle(.tertiary) }
                Button { Task { await ws.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.hoverIcon)
                    .help("Refresh prices and quote")
            }
            .padding(.bottom, 10)
            if ws.managesPosition {
                // The plan is on the exchange now: what remains is the position itself.
                Text("Executed. Now you can manage the position: “stop to breakeven”, “stop at …”, “close half”, “close”. For a new trade, just describe it.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                if let block = ws.blocks.first(where: { $0.id == selectedBlockID }) ?? ws.blocks.first {
                    Text("Selected step · \(block.label)")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                    BlockRow(block: block)
                    Text("This step's data and checks. To change the route, send a message in the chat.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
                if let error = ws.quoteError ?? ws.marketsError {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.top, 10)
                }
                Divider().padding(.vertical, 12)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let r = ws.planReview {
                            Label(r.text, systemImage: r.concern ? "exclamationmark.triangle.fill" : "checkmark.seal")
                                .foregroundStyle(r.concern ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        } else if let note = ws.jevNote {
                            Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
                        }
                        if ws.previewWallet == nil {
                            Text("Preview needs Solana and Hyperliquid addresses: balance → “Addresses from phrase…”.").foregroundStyle(.tertiary)
                        } else if ws.signerWallet == nil {
                            Text(ws.signerHasWallet == nil ? "Execution happens in LALA.app; this is a preview." : "To execute, save the key: balance → “Addresses from phrase…”.")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                    Spacer()
                    if ws.executing { ProgressView().controlSize(.small) }
                    Button { Task { await ws.prepareExecution() } } label: {
                        Text(ws.signerWallet == nil ? "Preview" : "Execute")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .background(Capsule().fill(ws.planIsReady ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!ws.planIsReady || ws.previewWallet == nil || ws.executing || ws.preparing)
                }
            }
            if ws.position == nil, let o = ws.pendingEntry {
                HStack {
                    Text("Limit waiting: \(o.side == "B" ? "long" : "short") \(o.size.map { Fmt.num($0, maxFraction: 6) } ?? "") \(o.coin) at \(o.limitPx.map(Fmt.price) ?? "?"); stop and take-profit turn on after entry.")
                        .font(.caption).monospacedDigit()
                    Spacer()
                    if ws.signerWallet != nil {
                        Button("Cancel") { Task { await ws.closePosition() } }.disabled(ws.executing)
                    }
                }
                .padding(.top, 10)
            }
            if let p = ws.position {
                HStack {
                    Text("Open position: \(p.size > 0 ? "long" : "short") \(IntentParser.pretty(p.coin)), PnL \(Fmt.usd(p.unrealizedPnl)). \(ws.positionSummary(p))")
                        .font(.caption).monospacedDigit()
                    Spacer()
                    if ws.signerWallet != nil {
                        Button("Close position") { Task { await ws.closePosition() } }.disabled(ws.executing)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .sheet(isPresented: Binding(get: { ws.preparing || ws.prepared != nil || (ws.executionError != nil && !ws.executing) },
                                    set: { if !$0 { ws.prepared = nil; ws.executionError = nil } })) {
            ConfirmSheet().environment(ws)
        }
    }
}

struct ModelMenu: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        Menu {
            ForEach(LLMCatalog.all.filter { $0.info.unavailable == nil }, id: \.info.id) { p in
                Button { ws.providerID = p.info.id } label: {
                    if p.info.id == ws.providerID { Label(p.info.name, systemImage: "checkmark") } else { Text(p.info.name) }
                }
            }
            Divider()
            SettingsLink { Text("Model settings…") }
        } label: {
            HStack(spacing: 4) {
                Text(ws.provider.info.name).font(.system(size: 14, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

struct BalanceButton: View {
    @Environment(Workspace.self) private var ws
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label(summary, systemImage: "wallet.bifold").labelStyle(.titleAndIcon).monospacedDigit()
        }
        .help("Balance and key")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            BalanceSection().padding(18).frame(width: 470)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let hl = ws.hl { parts.append(Fmt.usd(hl.accountValue + ws.dexBalances.values.reduce(0) { $0 + $1.accountValue })) }
        if let sol = ws.solana { parts.append("\(Fmt.num(sol.usdc)) USDC") }
        return parts.isEmpty ? "Wallet" : parts.joined(separator: " · ")
    }
}

struct BalanceSection: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Balance").font(.headline)
                Spacer()
                Button("Addresses from phrase…") { openWindow(id: "import") }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Solana").foregroundStyle(.secondary)
                    if ws.solanaAddress.isEmpty {
                        Text("no address set").foregroundStyle(.secondary)
                    } else if let b = ws.solana {
                        Text("\(Fmt.num(b.usdc)) USDC · \(Fmt.num(b.sol, maxFraction: 4)) SOL").monospacedDigit()
                    } else {
                        Text("— no data").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Hyperliquid").foregroundStyle(.secondary)
                    if ws.hlAddress.isEmpty {
                        Text("no address set").foregroundStyle(.secondary)
                    } else if ws.hl == nil {
                        Text("— no data").foregroundStyle(.secondary)
                    } else {
                        Text("")
                    }
                }
                if let b = ws.hl {
                    GridRow {
                        Text("  · perps, crypto").foregroundStyle(.secondary)
                        Text("\(Fmt.usd(b.accountValue)), available \(Fmt.usd(b.withdrawable))").monospacedDigit()
                    }
                    ForEach(Hyperliquid.hip3Dexes, id: \.self) { dex in
                        if let d = ws.dexBalances[dex] {
                            GridRow {
                                Text("  · \(dex): commodities, stocks").foregroundStyle(.secondary)
                                Text("\(Fmt.usd(d.accountValue)), available \(Fmt.usd(d.withdrawable))").monospacedDigit()
                            }
                        }
                    }
                    GridRow {
                        Text("  · spot").foregroundStyle(.secondary)
                        Text("\(Fmt.num(b.spotUSDC)) USDC").monospacedDigit()
                    }
                }
            }
            ForEach(ws.schedules, id: \.symbol) { s in
                Text("Scheduled: \(s.symbol) for \(Fmt.usd(s.usdc)) every \(s.days) days, next \(Fmt.date(s.next))")
                    .font(.callout).monospacedDigit()
            }
            ForEach(ws.lend, id: \.vault) { v in
                Text("Jupiter Lend vault \(v.vault): \(Fmt.num(v.usdc, maxFraction: 6)) USDC").font(.callout).monospacedDigit()
            }
            if let stored = ws.signerHasWallet {
                Label(stored ? "Key in secure storage; a separate process signs" : "No key: balance view only",
                      systemImage: stored ? "lock.fill" : "eye")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if ws.signerWallet != nil {
                if ws.agentActive {
                    Label("Trading key on: trades without Touch ID; it can't withdraw", systemImage: "key.horizontal")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Turn on trading key") { Task { await ws.enableAgent() } }
                        .disabled(ws.executing)
                        .help("A separate Hyperliquid key inside the signer: it can trade but can't withdraw. Approved once with the main key.")
                }
            }
            if let error = ws.solanaError ?? ws.hlError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
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
                Text(IntentParser.pretty(ws.intent.asset)).font(.system(size: 12))
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

struct BlockRow: View {
    let block: Block

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(statusColor).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(block.title).font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text("\(block.label) · \(statusText)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(block.lines.indices, id: \.self) {
                    Text(block.lines[$0]).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private var statusText: String {
        switch block.status {
        case .ready: "ready"
        case .warning: "has warnings"
        case .needsInput: "needs input"
        case .blocked: "stopped"
        case .noData: "no data"
        case .info: "not needed"
        }
    }

    private var statusColor: Color {
        switch block.status {
        case .ready: .green
        case .warning: .yellow
        case .needsInput: .orange
        case .blocked: .red
        case .noData, .info: .secondary
        }
    }
}

struct SettingsView: View {
    @Environment(Workspace.self) private var ws
    @AppStorage("layout") private var layout = "studio"
    @State private var confirmForget = false

    var body: some View {
        @Bindable var ws = ws
        Form {
            Section("Public addresses") {
                TextField("Solana", text: $ws.solanaAddress)
                TextField("Hyperliquid (0x…)", text: $ws.hlAddress)
                Text("Addresses only, for reading balances. Don't enter a seed phrase or keys here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ModelSection()
            Section("Risk management") {
                Stepper("Risk per trade — at most \(Fmt.pct(ws.policy.maxRiskPct)) of capital",
                        value: Binding(get: { NSDecimalNumber(decimal: ws.policy.maxRiskPct).doubleValue },
                                       set: { ws.policy.maxRiskPct = Decimal($0) }), in: 0.5...10, step: 0.5)
                LabeledContent("All open positions together", value: "at most \(Fmt.pct(ws.policy.maxOpenRiskPct))")
                LabeledContent("Reward/risk at least", value: Fmt.num(ws.policy.minRewardRisk))
                LabeledContent("Leverage up to", value: "\(Fmt.num(ws.policy.maxLeverage))×")
                Text("A trade that would lose more at its stop is not executed. “By the book” uses \(Fmt.pct(ws.policy.defaultRiskPct)) of capital, a \(Fmt.num(ws.policy.defaultRewardRisk))R take-profit and a \(Fmt.num(ws.policy.atrStopMultiple)) ATR (4h) stop. Crypto only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Key and signing") {
                Label(ws.signerWallet == nil ? "No key on this Mac yet — import a wallet" : "Key in secure storage; a separate process without network signs",
                      systemImage: ws.signerWallet == nil ? "xmark.circle" : "checkmark.circle.fill")
                Label("Touch ID: one confirmation covers 60 s", systemImage: "touchid")
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
            Section("Layout") {
                Picker("Main window", selection: $layout) {
                    Text("Studio — wallet, canvas, floating chat").tag("studio")
                    Text("Classic — chat beside the route").tag("classic")
                }
            }
            Section("Background") {
                Toggle("Open LALA at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }))
                Text("With the window closed, LALA stays in the menu bar: it manages stops (trailing, breakeven) and scheduled purchases. After “Quit” they stop; the stop and take-profit on the exchange keep working.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Incoming text protection") {
                Toggle("Second check by Jev (OpenRouter)", isOn: $ws.jevScreening)
                    .disabled(ws.openRouterKey == nil)
                Text(ws.openRouterKey == nil
                     ? "Sign in to OpenRouter above. Without Jev, local rules still apply."
                     : "On by default. Before a message reaches the model, rules and Jev's classifier check it for commands aimed at the assistant and requests to send money to an address. Jev can only stop a message, never approve a signature. The message text goes to OpenRouter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 720)
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
                .font(.caption)
                .foregroundStyle(info.unavailable == nil ? Color.secondary : Color.orange)
            if info.unavailable == nil { connection(info) }
            Text("The model gets only the plan's parameters and the message text — no addresses or balances.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func connection(_ info: ProviderInfo) -> some View {
        Text(connectionText).font(.callout)
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
            Text(status).font(.caption).textSelection(.enabled)
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
