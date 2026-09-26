import Foundation
import LalaCore
import LLMCatalog
import SwiftUI
import TradeExecution
import WalletCore

/// Owner-only JSON files in Application Support/LALA.
enum LocalStore {
    static func url(_ name: String) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "LALA")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name)
    }

    static func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        let file = url(name)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// One canvas: its chat, its plan, the model it was talked through and the bubbles last on it.
/// Kept on this Mac (canvases.json, owner-only); the canvas open at quit opens again at launch.
struct CanvasSession: Codable, Identifiable {
    var id = UUID()
    var updated = Date()
    var title = ""
    var providerID: String
    var model: String
    var messages: [Message]
    var intent: TradeIntent
    /// The plan was carried out: the canvas shows the position, not a new trade.
    var executed = false
    var bubbles: [ActivityBubble] = []
}

extension Workspace {
    /// Keeps the open canvas. Nothing is kept before the first message.
    func saveCanvas() {
        guard messages.contains(where: \.fromUser) else { return }
        var c = canvases.first { $0.id == canvasID } ?? CanvasSession(providerID: providerID, model: model, messages: [], intent: intent)
        c.updated = Date()
        c.providerID = providerID
        c.model = model
        c.messages = messages
        c.intent = intent
        c.executed = executed != nil && executed == intent
        if let board = canvasBubbles() {
            c.title = board.title
            c.bubbles = board.bubbles
            savedBoard = nil
        } else if c.title.isEmpty, let first = messages.first(where: \.fromUser)?.text {
            c.title = first.count > 48 ? String(first.prefix(48)) + "…" : first
        }
        canvasID = c.id
        if let i = canvases.firstIndex(where: { $0.id == c.id }) { canvases[i] = c } else { canvases.append(c) }
    }

    func openCanvas(_ c: CanvasSession) {
        guard c.id != canvasID, !busy else { return }
        saveCanvas()
        load(c)
        Task { await refreshQuote() }
    }

    func newCanvas() {
        guard !busy else { return }
        saveCanvas()
        clearCanvas()
        canvasID = nil
        messages = Array(messages.prefix(1))
        intent = TradeIntent()
        executed = nil
    }

    func deleteCanvas(_ id: UUID) {
        if id == canvasID { newCanvas() }
        canvases.removeAll { $0.id == id }
    }

    /// The canvas that was open last time.
    func restoreLastCanvas() {
        if let last = canvases.max(by: { $0.updated < $1.updated }) { load(last) }
    }

    private func load(_ c: CanvasSession) {
        clearCanvas()
        canvasID = c.id
        messages = c.messages
        intent = c.intent
        executed = c.executed ? c.intent : nil
        if LLMCatalog.provider(id: c.providerID) != nil {
            providerID = c.providerID
            modelChoices[c.providerID] = c.model
        }
        savedBoard = c.bubbles.isEmpty ? nil : c
    }

    /// What belongs to one canvas only: boards, waiting confirmations, the draft.
    private func clearCanvas() {
        takeChoices = nil
        yieldOptions = nil
        allocationPreview = nil
        pendingAllocation = nil
        pendingAction = nil
        pendingText = nil
        planReview = nil
        savedBoard = nil
        currentActivity = nil
        draft = ""
    }
}

// MARK: Views

/// The saved canvases, newest first; a click opens one with its chat, plan and model.
struct CanvasList: View {
    @Environment(Workspace.self) private var ws
    var close: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Canvases").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { withAnimation(StudioView.spring) { ws.newCanvas() }; close?() } label: {
                    Label("New", systemImage: "square.and.pencil").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless).help("New canvas").disabled(ws.busy)
            }
            let items = ws.canvases.sorted { $0.updated > $1.updated }
            if items.isEmpty {
                Text("Each conversation gets its own canvas and is kept here.").font(.caption).foregroundStyle(.tertiary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { c in
                        CanvasRow(canvas: c, current: c.id == ws.canvasID) {
                            withAnimation(StudioView.spring) { ws.openCanvas(c) }
                            close?()
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

struct CanvasRow: View {
    @Environment(Workspace.self) private var ws
    let canvas: CanvasSession
    let current: Bool
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                if canvas.intent != TradeIntent() {
                    AssetBadge(coin: canvas.intent.asset, size: 26, dark: true)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Brand.accent.opacity(0.12)).frame(width: 26, height: 26)
                        .overlay(Image(systemName: canvas.bubbles.isEmpty ? "bubble.left" : "square.grid.2x2").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.accent))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(canvas.title.isEmpty ? "Canvas" : canvas.title).font(.system(size: 12.5, weight: current ? .semibold : .regular)).lineLimit(1)
                    Text("\(canvas.model) · \(Fmt.date(canvas.updated))").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(current ? Brand.accent.opacity(0.1) : hover ? Color.primary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(canvas.title) · \(LLMCatalog.provider(id: canvas.providerID)?.info.name ?? canvas.providerID) · \(canvas.model)")
        .contextMenu {
            Button("Delete canvas", role: .destructive) { withAnimation { ws.deleteCanvas(canvas.id) } }
        }
    }
}

/// A canvas opened again whose board isn't a live plan: its bubbles as they were.
struct SavedBoard: View {
    let canvas: CanvasSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("As it was · \(Fmt.date(canvas.updated)). Ask again for fresh numbers.", systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.fixed(220), alignment: .top), GridItem(.fixed(220), alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(canvas.bubbles, id: \.self) { HistoryBubble(bubble: $0) }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
    }
}

/// A row in LALA's own menus: a title, an optional detail, a hover highlight.
struct MenuRow: View {
    let title: String
    var detail: String?
    var icon: String?
    var shortcut: String?
    var checked = false
    var tint: Color = .primary
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).frame(width: 18).foregroundStyle(tint == .primary ? .secondary : tint) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 8)
                if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.secondary) }
                if checked { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.accent) }
            }
            .padding(.horizontal, 10).padding(.vertical, detail == nil ? 8 : 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(checked ? Brand.accent.opacity(0.09) : hover ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Recurring buys on the canvas (S09): the next runs, what each leaves on Solana, and where the money runs out.
struct ScheduleBoard: View {
    @Environment(Workspace.self) private var ws
    let schedule: Schedule

    var body: some View {
        let balance = ws.solana?.usdc
        let runs = (0..<4).map { k in
            (date: Calendar.current.date(byAdding: .day, value: k * schedule.days, to: schedule.next) ?? schedule.next,
             left: balance.map { $0 - Decimal(k + 1) * schedule.usdc })
        }
        let short = runs.first { ($0.left ?? 0) < 0 }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TokenLogo(name: "usdc", size: 26)
                Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                AssetBadge(coin: schedule.symbol, size: 26)
                Text("\(Fmt.usd(schedule.usdc)) → \(schedule.symbol) every \(period)").font(.system(size: 15, weight: .bold))
                Spacer()
                StatusChip(text: short == nil ? "running" : "runs short", tint: short == nil ? Brand.profit : Brand.jevInk)
            }
            HStack(alignment: .top, spacing: 10) {
                fact("EACH PURCHASE", "Jupiter quote, address check, simulation and signature — like a manual one")
                fact("A MONTH", "≈ \(Fmt.usd(schedule.usdc * 30 / Decimal(max(schedule.days, 1))))")
            }
            VStack(spacing: 0) {
                ForEach(runs.indices, id: \.self) { i in
                    let run = runs[i], enough = (run.left ?? 0) >= 0
                    HStack {
                        Text(i == 0 && schedule.next <= Date() ? "now" : Fmt.date(run.date)).monospacedDigit().frame(width: 130, alignment: .leading)
                        Text(Fmt.usd(schedule.usdc)).monospacedDigit()
                        Spacer()
                        Text(run.left.map { enough ? "Solana left \(Fmt.num($0)) USDC" : "not enough" } ?? "—")
                            .foregroundStyle(enough ? AnyShapeStyle(.secondary) : AnyShapeStyle(Brand.loss))
                    }
                    .font(.system(size: 12.5))
                    .padding(.vertical, 7)
                    if i < runs.count - 1 { Divider() }
                }
            }
            if let short {
                Label("On \(Fmt.date(short.date)) there won’t be enough USDC on Solana. Top up Solana or lower the amount.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Brand.jevInk)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Brand.jevInk.opacity(0.1)))
            }
            HStack {
                Text("Runs while LALA is open or in the menu bar.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { Task { await ws.send("stop recurring buys") } }.buttonStyle(.borderless).foregroundStyle(Brand.loss)
            }
        }
        .padding(16)
        .frame(width: 470)
        .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card).shadow(color: .black.opacity(0.06), radius: 14, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.cardBorder))
    }

    private var period: String { schedule.days == 1 ? "day" : schedule.days == 7 ? "week" : schedule.days == 30 ? "month" : "\(schedule.days) days" }

    private func fact(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 9.5, weight: .heavy)).tracking(0.5).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.solanaTint))
    }
}

extension Workspace {
    /// For a plan the rules stop: the risk LALA suggests instead and what the trade looks like with it.
    var fittingRisk: (risk: Decimal, sizing: Sizing)? {
        let i = resolved.intent
        guard let m = market else { return nil }
        // ponytail: Solana USDC less a bridge-fee cushion plus what is free on Hyperliquid; the confirm step re-quotes exactly.
        let available = max(0, (solana?.usdc ?? 0) - Decimal(string: "0.1")!) + (hl.map { $0.withdrawable + (m.dex.flatMap { dexBalances[$0]?.withdrawable } ?? 0) } ?? 0)
        guard let r = Plan.fittingRisk(i, market: m, equity: equity, policy: policy,
                                       openRisk: HyperliquidAccount.riskAtStops(positions: positions, orders: orders), available: available) else { return nil }
        var j = i
        j.riskUSD = r
        return Plan.evaluate(j, market: m).sizing.map { (r, $0) }
    }
}

/// A plan the rules stop (S04): what fits instead, one click away.
struct FixChoices: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CHOOSE AN OPTION").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                if let fit = ws.fittingRisk {
                    card(badge: "LALA recommends", title: "Risk \(Fmt.usd(fit.risk))",
                         detail: "notional \(Fmt.usd(fit.sizing.notional)) · margin \(Fmt.usd(fit.sizing.margin)) — everything fits", recommended: true) {
                        Task { await ws.send("risk $\(fit.risk)") }
                    }
                }
                card(badge: "at your own risk", title: "Raise the limit",
                     detail: "now at most \(Fmt.pct(ws.policy.maxRiskPct)) per trade · in Settings", recommended: false) { openSettings() }
            }
        }
        .frame(width: 470, alignment: .leading)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func card(badge: String, title: String, detail: String, recommended: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(badge.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(0.5)
                    .foregroundStyle(recommended ? .white : .secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(recommended ? Brand.accent : Color.primary.opacity(0.07)))
                Text(title).font(.system(size: 17, weight: .heavy))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 20).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(recommended ? Brand.accent : Brand.cardBorder,
                                                                       style: StrokeStyle(lineWidth: recommended ? 2 : 1, dash: recommended ? [] : [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A move of money waiting for «do it», drawn as a route (S10): a withdrawal to Solana, or USDC into Aave on Base.
struct WithdrawBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if case .wallet(let command)? = ws.pendingAction {
            switch command {
            case .withdrawToSolana(let asked): withdraw(asked)
            case .aave(deposit: true, amount: let amount?): aave(amount)
            case .aave(deposit: false, amount: let amount): back(from: "aave", amount: amount)
            case .baseToSolana(let amount): back(from: "base", amount: amount)
            case .arbitrumToSolana(let amount): back(from: "arbitrum", amount: amount)
            default: generic(command)
            }
        }
    }

    private func withdraw(_ asked: Decimal?) -> some View {
        let free = ws.hl?.withdrawable
        let amount = asked ?? free
        return board(title: "Withdraw · \(amount.map { Fmt.num($0) } ?? "all") USDC to Solana",
                     footer: "Signed with the main key — the trading key can’t withdraw. Say “do it” or press Confirm; anything else cancels.") {
            step(logo: "hype", label: "FROM · HYPERLIQUID", title: free.map { f in amount.map { "\(Fmt.usd(f)) → \(Fmt.usd(max(0, f - $0)))" } ?? Fmt.usd(f) } ?? "—",
                 line: "position margin isn’t touched", fill: Brand.hl, dark: true)
            step(logo: "relay", label: "BRIDGE · RELAY", title: amount.map { "\(Fmt.num($0)) USDC" } ?? "—", line: "≈ 4 s · small Relay fee", fill: Brand.relay, dark: true)
            step(logo: "sol", label: "TO · SOLANA", title: ws.solana.map { s in amount.map { "\(Fmt.num(s.usdc)) → \(Fmt.num(s.usdc + $0))" } ?? Fmt.num(s.usdc) } ?? "—",
                 line: "your own address ✓", fill: Brand.solanaTint, dark: false)
        }
    }

    private func aave(_ amount: Decimal) -> some View {
        let onBase = ws.base?.usdc ?? 0
        let short = max(0, amount - onBase)
        let needGas = (ws.base?.eth ?? 0) < Decimal(string: "0.000005")!
        let bridging = short > 0 || needGas
        let apy = ws.aaveAPY.map { "≈ \(Fmt.num($0.rounded(2, .plain)))% a year" } ?? "rate from the pool"
        return board(title: "Aave · lend \(Fmt.num(amount)) USDC on Base",
                     footer: (bridging ? "One Solana signature for the bridge, then " : "")
                        + "two on Base: approve exactly \(Fmt.num(amount)) USDC, then supply. Pool and rate are re-read from Base first. Say “do it” or press Confirm.") {
            if bridging {
                step(logo: "sol", label: "FROM · SOLANA", title: ws.solana.map { "\(Fmt.num($0.usdc)) USDC" } ?? "—",
                     line: "sends ≈ \(Fmt.num(max(short, needGas ? Decimal(string: "0.5")! : 0) + (needGas ? Decimal(string: "0.14")! : Decimal(string: "0.03")!))) USDC", fill: Brand.solanaTint, dark: false)
                step(logo: "relay", label: "BRIDGE · RELAY", title: "\(Fmt.num(max(short, needGas ? Decimal(string: "0.5")! : 0))) USDC → Base",
                     line: needGas ? "+ $0.03 of ETH for gas · ≈ 2 s" : "≈ 2 s", fill: Brand.relay, dark: true)
            } else {
                step(logo: "base", label: "ON BASE", title: "\(Fmt.num(onBase)) USDC", line: "already there, gas too", fill: Color(hex: 0x0052FF), dark: true)
            }
            step(logo: "aave", label: "AAVE V3 · BASE", title: "\(Fmt.num(amount)) USDC", line: apy, fill: Color(hex: 0x2B2D3C), dark: true)
        }
    }

    /// Any other move between the user's own places: where from, where to, in the places' colors.
    @ViewBuilder private func generic(_ c: WalletCommand) -> some View {
        if let (from, to) = ends(c) {
            board(title: c.summary.prefix(1).uppercased() + c.summary.dropFirst(),
                  footer: "One Solana signature, checked and simulated before it’s signed. Say “do it” or press Confirm; anything else cancels.") {
                step(logo: from.0, label: from.1, title: from.2, line: from.3, fill: from.4, dark: from.5)
                step(logo: to.0, label: to.1, title: to.2, line: to.3, fill: to.4, dark: to.5)
            }
        }
    }

    private typealias End = (String, String, String, String, Color, Bool)

    private func ends(_ c: WalletCommand) -> (End, End)? {
        func n(_ d: Decimal?) -> String { d.map { Fmt.num($0, maxFraction: 6) } ?? "all" }
        let solUSDC = ws.solana.map { "free: \(Fmt.num($0.usdc)) USDC" } ?? ""
        let solSOL = ws.solana.map { "free: \(Fmt.num($0.sol, maxFraction: 4)) SOL" } ?? ""
        let jup = Color(hex: 0x131D27), kamino = Color(hex: 0x082A56), jito = Color(hex: 0x1F9D6A)
        switch c {
        case .lendDeposit(let s, let x):
            return ((s == "SOL" ? "sol" : "usdc", "FROM · SOLANA", "\(n(x)) \(s)", s == "SOL" ? solSOL : solUSDC, Brand.solanaTint, false),
                    ("jup", "INTO · JUPITER LEND", "\(n(x)) \(s)", "earns the vault rate · withdraw any time", jup, true))
        case .lendWithdraw(let s, let x):
            return (("jup", "FROM · JUPITER LEND", "\(n(x)) \(s)", ws.lendTotal > 0 ? "in the vault: \(Fmt.num(ws.lendTotal)) USDC" : "", jup, true),
                    (s == "SOL" ? "sol" : "usdc", "TO · SOLANA", "\(n(x)) \(s)", "your wallet", Brand.solanaTint, false))
        case .kamino(true, let s, let x):
            return ((s == "SOL" ? "sol" : "usdc", "FROM · SOLANA", "\(n(x)) \(s)", s == "SOL" ? solSOL : solUSDC, Brand.solanaTint, false),
                    ("kamino", "INTO · KAMINO LEND", "\(n(x)) \(s)", "first deposit pays ≈ 0.03 SOL rent", kamino, true))
        case .kamino(false, let s, let x):
            return (("kamino", "FROM · KAMINO LEND", "\(n(x)) \(s)", "", kamino, true),
                    (s == "SOL" ? "sol" : "usdc", "TO · SOLANA", "\(n(x)) \(s)", "your wallet", Brand.solanaTint, false))
        case .stake(let x):
            return (("sol", "FROM · SOLANA", "\(n(x)) SOL", solSOL, Brand.solanaTint, false),
                    ("jitosol", "INTO · JITOSOL", "liquid staking", "earns the staking yield · swap back any time", jito, true))
        case .unstake(let x):
            return (("jitosol", "FROM · JITOSOL", "\(n(x)) JitoSOL", "", jito, true), ("sol", "TO · SOLANA", "SOL", "your wallet", Brand.solanaTint, false))
        case .hlp(true, let x):
            return (("hype", "FROM · HYPERLIQUID", "\(n(x)) USDC", ws.hl.map { "free: \(Fmt.usd($0.withdrawable))" } ?? "", Brand.hl, true),
                    ("hype", "INTO · HLP VAULT", "\(n(x)) USDC", "min $5 · 4-day lockup", Brand.hlChip, true))
        case .hlp(false, let x):
            return (("hype", "FROM · HLP VAULT", "\(n(x)) USDC", "", Brand.hlChip, true), ("hype", "TO · HYPERLIQUID", "USDC", "trading balance", Brand.hl, true))
        case .buy(let a, let u):
            return (("usdc", "FROM · SOLANA", "\(n(u)) USDC", solUSDC, Brand.solanaTint, false),
                    (TokenLogo.name(forAsset: a.symbol) ?? "usdc", "BUY · JUPITER", a.symbol, "best route, simulated first", jup, true))
        case .sell(let a, let x):
            return ((TokenLogo.name(forAsset: a.symbol) ?? "usdc", "SELL · JUPITER", "\(n(x)) \(a.symbol)", "", jup, true),
                    ("usdc", "TO · SOLANA", "USDC", "your wallet", Brand.solanaTint, false))
        default:
            return nil
        }
    }

    /// Aave or idle USDC on Base → Relay → Solana.
    private func back(from place: String, amount: Decimal?) -> some View {
        let b = ws.base
        let available = place == "aave" ? b?.aave : place == "arbitrum" ? ws.arbitrumUSDC : b?.usdc
        let moving = amount.map { min($0, available ?? $0) } ?? available
        let chainName = place == "arbitrum" ? "Arbitrum" : "Base"
        return board(title: place == "aave" ? "Aave · withdraw \(moving.map { Fmt.num($0) } ?? "all") USDC to Solana" : "\(chainName) · \(moving.map { Fmt.num($0) } ?? "all") USDC to Solana",
                     footer: (place == "aave" ? "Three Base transactions: withdraw from Aave, an exact approve and Relay’s deposit" : "Two Base transactions: an exact approve and Relay’s deposit")
                        + " — checked field by field before signing. Say “do it” or press Confirm.") {
            if place == "aave" {
                step(logo: "aave", label: "FROM · AAVE ON BASE", title: available.map { "\(Fmt.num($0)) USDC" } ?? "—",
                     line: ws.aaveAPY.map { "earning ≈ \(Fmt.num($0.rounded(2, .plain)))% until now" } ?? "with the interest", fill: Color(hex: 0x2B2D3C), dark: true)
            } else {
                step(logo: place == "arbitrum" ? "arb" : "base", label: "FROM · \(chainName.uppercased())", title: available.map { "\(Fmt.num($0)) USDC" } ?? "—",
                     line: "idle USDC", fill: place == "arbitrum" ? Color(hex: 0x213147) : Color(hex: 0x0052FF), dark: true)
            }
            step(logo: "relay", label: "BRIDGE · RELAY", title: moving.map { "\(Fmt.num($0)) USDC" } ?? "—", line: "≈ $0.02 · a few seconds", fill: Brand.relay, dark: true)
            step(logo: "sol", label: "TO · SOLANA", title: ws.solana.map { s in moving.map { "\(Fmt.num(s.usdc)) → \(Fmt.num(s.usdc + $0))" } ?? Fmt.num(s.usdc) } ?? "—",
                 line: "your own address ✓", fill: Brand.solanaTint, dark: false)
        }
    }

    private func board<Steps: View>(title: String, footer: String, @ViewBuilder steps: () -> Steps) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold))
                StatusChip(text: "waiting for the signature", tint: Brand.profit)
            }
            HStack(alignment: .top, spacing: 12) { steps() }
            Label(footer, systemImage: "signature").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 470, alignment: .leading)
        .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
    }

    private func step(logo: String, label: String, title: String, line: String, fill: Color, dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TokenLogo(name: logo, size: 24)
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(0.4).opacity(0.75)
            Text(title).font(.system(size: 13, weight: .bold)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            Text(line).font(.caption2).opacity(0.8).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(dark ? Color.white : Color.primary)
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(ArrowCard(radius: 16, tip: 10).fill(fill))
    }
}

extension Workspace {
    static let help = "I didn’t catch what to do. For example: “deposit 1 USDC into Jupiter”, “long ETH risk $5 by the book”, “send 5 USDC to Bybit”, “where to keep USDC”, “alert me when ETH is below 2,500”."

    /// One path for every wallet command, typed or read by the model: a missing amount is asked for and remembered;
    /// in the studio (or whenever the model read it) money moves only after «do it» on the drawn route.
    func handleWallet(_ command: WalletCommand, note: String? = nil, confirmAlways: Bool = false) async {
        updateActivity { $0.understood = command.summary }
        if case .sendTo(let name, let amount) = command { prepareTransfer(amount, to: name, note: note); return }
        if case .receive = command {
            withAnimation(StudioView.spring) { showReceive = true }
            let sol = isSolanaAddress(solanaAddress) ? "Solana \(AddressCheck.ends(solanaAddress).start) … \(AddressCheck.ends(solanaAddress).end)" : nil
            reply("Your addresses are on the canvas\(sol.map { " — \($0) for USDC and SOL (recommended)" } ?? ""), plus Base for USDC and ETH. LALA can’t pull money in; send it there from an exchange or another wallet, on that network. It shows up within about 30 s and I’ll tell you when it arrives. To put money you already have into a vault, say “deposit 1 USDC into Jupiter”.", note: note)
            return
        }
        if let question = command.amountQuestion {
            awaitingAmount = command
            reply(question + amountHint(command), note: note)
            return
        }
        switch command {
        case .yields, .allocate, .schedule, .stopSchedules:
            // Read-only, or with a board and a step of their own.
            await move(command)
        default:
            guard isStudio || confirmAlways else { await move(command); return }
            pendingAction = .wallet(command)
            pendingText = command.summary
            reply("Understood: \(command.summary). It’s on the canvas — Sign it, or say anything else to cancel.", note: note)
        }
    }

    /// What there is to use, so the answer to «How much?» is easy.
    private func amountHint(_ command: WalletCommand) -> String {
        switch command {
        case .lendDeposit("SOL", _), .kamino(_, "SOL", _), .stake:
            return solana.map { " You have \(Fmt.num($0.sol, maxFraction: 4)) SOL on Solana — answer with a number, e.g. “0.01”." } ?? ""
        case .hlp: return hl.map { " \(Fmt.usd($0.withdrawable)) is free on Hyperliquid — answer with a number, e.g. “5”." } ?? ""
        default: return solana.map { " You have \(Fmt.num($0.usdc)) USDC on Solana — answer with a number, e.g. “1”." } ?? ""
        }
    }

    /// The last few lines of this canvas's chat, for a model reading a follow-up like «1» or «yes».
    func recentChat() -> [String] {
        messages.dropFirst().suffix(6).map { ($0.fromUser ? "user: " : "LALA: ") + $0.text.prefix(300) }
    }
}
