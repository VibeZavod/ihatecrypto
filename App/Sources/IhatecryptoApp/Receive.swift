import AppKit
import CoreImage.CIFilterBuiltins
import EVMChain
import IhatecryptoCore
import SolanaChain
import SwiftUI
import TradeExecution
import WalletCore

/// Top up (the rail's button): what lands on which network — every network the wallet uses, USDC, the network's coin or
/// any coin, an amount or any — then three ways to send it, each saying what it costs: a browser wallet (recommended:
/// the page comes from this Mac, so the address can't be swapped), a phone wallet's scan, or an exchange to the address.
/// From the moment a way is used the board reads that balance every few seconds, and the money landing shows as a
/// Done card at its top.
struct ReceiveBoard: View {
    @Environment(Workspace.self) private var ws
    @AppStorage("topUpWay") private var way = Way.browser
    @AppStorage("topUpNetwork") private var networkKey = "solana"
    /// Empty: any amount.
    @State private var amount = "20"
    @State private var coin = TopUpOrder.Coin.usdc
    /// A way was used (a page opened, a QR or an address shown): the balance is watched from then on.
    @State private var waiting = false
    @State private var opening = false
    @State private var problem: String?
    /// The chosen coin's balance on the chosen network (USDC and the coin for «any coin»), read from the network itself.
    @State private var held: (network: String, coins: [String: Decimal]) = ("", [:])
    /// What landed, in one line at the board's foot: no card of its own inside the board (the owner, 2026-10-15).
    @State private var arrived: String?

    enum Way: String, CaseIterable { case browser, phone, exchange }

    var body: some View {
        let order = self.order
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.accentInk).font(.system(size: 18))
                Text("Top up ihatecrypto").font(.ui(16, .bold))
                Spacer()
                Button { withAnimation(StudioView.spring) { ws.showReceive = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.hoverIcon).help("Close")
            }
            amountRow(order)
            networkRow(order)
            VStack(spacing: 8) {
                tile(.browser, order)
                HStack(spacing: 8) { tile(.phone, order); tile(.exchange, order) }
            }
            wayBody(order)
            if let sent = TopUpPage.shared.sent, sent.order.network == order.network, arrived == nil {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill").foregroundStyle(Brand.profit)
                    Text("Sent from your wallet — it shows here the moment it lands.").font(.ui(11, .semibold))
                    if let url = sent.order.explorer(sent.id) { Button("See it") { ws.openWeb(url) }.buttonStyle(.link).font(.ui(11)) }
                }
            } else if let arrived {
                Label(arrived, systemImage: "checkmark.circle.fill").font(.ui(11, .semibold)).foregroundStyle(Brand.profit)
            } else if waiting {
                Label("Waiting for \(order.units != nil ? "\(order.amount ?? 0) \(order.symbol)" : order.coin == .any ? "money" : order.symbol) on \(order.network.title)…",
                      systemImage: "hourglass")
                    .font(.ui(11)).foregroundStyle(.secondary)
            }
            if let problem { Text(problem).font(.ui(11, .semibold)).foregroundStyle(Brand.loss).fixedSize(horizontal: false, vertical: true) }
            BalanceFreshness()
        }
        .padding(18)
        .frame(width: 470, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 26).fill(Brand.card).shadow(color: .black.opacity(0.08), radius: 18, y: 10))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Brand.accent.opacity(0.5), lineWidth: 1.5))
        .transition(.opacity)
        .onAppear { waiting = way != .browser }
        .onChange(of: way) { problem = nil; if way != .browser { waiting = true } }
        .task(id: "\(order.network.key) \(order.coin) \(waiting)") { await watch(order) }
        .onDisappear { TopUpPage.shared.stop() }
    }

    // MARK: The order

    /// Solana, then the EVM networks as a search for money takes them (Ethereum last); a network off in Settings › Modules isn't offered.
    private var networks: [TopUpOrder.Network] {
        (isSolanaAddress(ws.solanaAddress) && Modules.current.isOn(.solana) ? [.solana] : [])
            + (isEVMAddress(ws.hlAddress) ? EVMNetwork.searched.map(TopUpOrder.Network.init) : [])
    }

    private var order: TopUpOrder {
        let net = networks.first { $0.key == networkKey } ?? networks.first ?? .solana
        let typed = amount.replacing(",", with: ".").trimmingCharacters(in: .whitespaces)
        return TopUpOrder(network: net, coin: coin, amount: typed.isEmpty ? nil : Decimal(string: typed) ?? 0,
                          recipient: net.chainId == nil ? ws.solanaAddress : ws.hlAddress)
    }

    /// Quick amounts in a coin (nil: the network's dollar): a few dollars' worth of gas, more of the cheaper coins.
    private static func presets(_ coin: String?) -> [String] {
        switch coin ?? "USDC" {
        case "USDC": ["20", "50", "100", "500"]
        case "SOL", "HYPE": ["0.02", "0.1", "0.5"]
        case "ETH": ["0.002", "0.01", "0.05"]
        case "BNB": ["0.005", "0.02", "0.1"]
        case "POL": ["5", "20", "100"]
        default: []
        }
    }

    private func amountRow(_ o: TopUpOrder) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if o.coin == .any {
                    Text("Any coin").font(.ui(30, .bold))
                } else {
                    TextField("Any", text: $amount).textFieldStyle(.plain).font(.ui(30, .bold)).monospacedDigit()
                        .fixedSize().frame(minWidth: 40, alignment: .leading)
                        .accessibilityLabel("Amount")
                    Text(o.symbol).font(.ui(18, .bold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                chip(o.network.usdcSymbol, on: o.coin == .usdc) { coin = .usdc; amount = "20" }
                if let gas = o.network.coin {
                    chip(gas, on: o.coin == .native) { coin = .native; amount = Self.presets(gas).first ?? "" }
                }
                chip("Any", on: o.coin == .any) { coin = .any }.accessibilityLabel("Any coin")
            }
            HStack(spacing: 6) {
                if o.coin == .any {
                    Text("Any token on \(o.network.title) lands at this wallet's address: \(o.network.usdcSymbol), \(o.network.coin ?? "stablecoins"), memecoins…")
                        .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Self.presets(o.coin == .usdc ? nil : o.network.coin), id: \.self) { p in chip(p, on: amount == p) { amount = p } }
                    chip("Any", on: amount.isEmpty) { amount = "" }.accessibilityLabel("Any amount")
                    Spacer(minLength: 6)
                    if held.network == o.network.key, let now = held.coins[o.symbol] {
                        let digits = o.coin == .usdc ? 2 : 6
                        Text(o.units != nil ? "\(Fmt.num(now, maxFraction: digits)) → \(Fmt.num(now + (o.amount ?? 0), maxFraction: digits)) \(o.symbol)"
                                            : "\(Fmt.num(now, maxFraction: digits)) \(o.symbol) now")
                            .font(.ui(11, .semibold)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                            .help("What this wallet holds on \(o.network.title) now → after the top-up")
                    }
                }
            }
            if o.coin != .any, o.amount != nil, o.units == nil {
                Text("Type an amount above zero, with at most \(o.decimals) digits after the point.").font(.ui(10.5)).foregroundStyle(Brand.loss)
            }
        }
    }

    /// Every network, in one row that scrolls sideways; the chosen one is scrolled into view.
    private func networkRow(_ o: TopUpOrder) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(networks, id: \.key) { n in
                        Button { pick(n) } label: {
                            HStack(spacing: 6) {
                                TokenLogo(name: Self.logo(n), size: 16)
                                Text(n.title).font(.ui(12, .semibold))
                                if n.chainId == nil { Self.best }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                            .overlay(Capsule().strokeBorder(o.network == n ? Brand.accent : .clear, lineWidth: 1.5))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).modifier(HoverLift(radius: 20)).id(n.key)
                        .accessibilityLabel(n.chainId == nil ? "\(n.title), recommended" : n.title)
                        .help(n.chainId == nil ? "Recommended: the cheapest and fastest to top up, and where ihatecrypto trades from" : "")
                    }
                }
                .padding(.vertical, 3).padding(.trailing, 24)
            }
            // It moves sideways only: a trackpad swipe is never quite level, and the row sprang up and down with it.
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            // The last chips fade out: there's more to the right.
            .mask(HStack(spacing: 0) { Color.black; LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28) })
            .padding(.vertical, -3)
            .onAppear { proxy.scrollTo(o.network.key, anchor: .center) }
        }
    }

    /// Another network: its own coin's quick amount if the coin was chosen (Tempo has none: its dollar then).
    private func pick(_ n: TopUpOrder.Network) {
        networkKey = n.key
        guard coin == .native else { return }
        if let gas = n.coin { amount = Self.presets(gas).first ?? "" } else { (coin, amount) = (.usdc, "20") }
    }

    /// The recommended network and way.
    static var best: some View {
        Text("BEST").font(.ui(8.5, .heavy)).foregroundStyle(Brand.onAccent)
            .padding(.horizontal, 5).padding(.vertical, 2).background(Capsule().fill(Brand.accent))
    }

    static func logo(_ n: TopUpOrder.Network) -> String { n.chainId == nil ? "sol" : HoldingRow.chainLogos[n.key] ?? n.key }

    /// What's chosen has an orange border and nothing more: an orange tint under the text read worse (the owner, 2026-10-15).
    private func chip(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.ui(11.5, .semibold)).monospacedDigit()
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                .overlay(Capsule().strokeBorder(on ? Brand.accent : .clear, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).modifier(HoverLift(radius: 20))
    }

    // MARK: The ways

    /// A browser wallet is asked for one transfer: it needs the coin and the amount.
    private func browserNeeds(_ o: TopUpOrder) -> String? {
        o.coin == .any ? "pick \(o.network.usdcSymbol)\(o.network.coin.map { " or \($0)" } ?? "") above" : o.amount == nil ? "pick an amount above" : nil
    }

    private func tile(_ w: Way, _ o: TopUpOrder) -> some View {
        let solana = o.network.chainId == nil
        let (icon, title, detail, cost): (String, String, String, String) = switch w {
        case .browser: ("macwindow", "Browser wallet", browserNeeds(o).map { "Needs a coin and an amount: \($0)" }
                            ?? (solana ? "Phantom, Solflare, Backpack" : "MetaMask, Rabby, Phantom"), o.network.cost)
        case .phone: ("qrcode.viewfinder", "Phone wallet", o.units != nil ? "scan, the amount is filled in" : "scan, the wallet asks how much", o.network.cost)
        case .exchange: ("building.columns", "Exchange", "Binance, OKX, Bybit… by address", "the exchange's withdrawal fee")
        }
        let on = way == w
        return Button { way = w } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.accentInk).frame(width: 18)
                    Text(title).font(.ui(13, .bold))
                    Spacer(minLength: 4)
                    if w == .browser { Self.best }
                }
                Text(detail).font(.ui(10.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                Text(cost).font(.ui(10.5, .semibold)).foregroundStyle(w == .exchange ? AnyShapeStyle(.secondary) : AnyShapeStyle(Brand.profit))
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? Brand.accent : Brand.cardBorder, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).modifier(HoverLift(radius: 14))
        .accessibilityLabel(title)
    }

    @ViewBuilder private func wayBody(_ o: TopUpOrder) -> some View {
        let net = o.network, solana = net.chainId == nil
        switch way {
        case .browser:
            VStack(alignment: .leading, spacing: 10) {
                if let needs = browserNeeds(o) {
                    Text("A browser wallet is asked for one transfer: \(needs). For any coin or amount, scan with your phone or send from an exchange.")
                        .font(.ui(11)).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Your browser opens a page served by this Mac. Pick your wallet there and approve \(o.amount ?? 0) \(o.symbol) on \(net.title): the address is put in by ihatecrypto, so no website can swap it.")
                        .font(.ui(11)).fixedSize(horizontal: false, vertical: true)
                }
                Button { Task { await openPage(o) } } label: {
                    Label(opening ? "Opening…" : browserNeeds(o) == nil ? "Top up \(o.amount ?? 0) \(o.symbol) from a browser wallet" : "Top up from a browser wallet",
                          systemImage: "arrow.up.forward.app")
                        .font(.ui(13, .semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(o.units == nil || opening)
            }
        case .phone:
            HStack(alignment: .top, spacing: 14) {
                if let link = o.payLink, let qr = QR.image(link) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 132, height: 132)
                        .padding(6).background(RoundedRectangle(cornerRadius: 12).fill(.white))
                        .overlay(alignment: .center) { TokenLogo(name: Self.logo(net), size: 28, round: true) }
                        .accessibilityLabel(o.units != nil ? "QR code to top up \(o.amount ?? 0) \(o.symbol)" : "QR code of this wallet on \(net.title)")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scan with your phone's wallet").font(.ui(13, .bold))
                    Text((solana ? "Phantom, Solflare or Backpack: " : "MetaMask, Rainbow or Coinbase Wallet: ")
                         + (o.coin == .any ? "this wallet on \(net.title) is filled in, you pick the coin and the amount."
                            : o.units != nil ? "\(o.amount ?? 0) \(o.symbol) to this wallet on \(net.title) is filled in, you only approve."
                            : "\(o.symbol) to this wallet on \(net.title) is filled in, the wallet asks how much."))
                        .font(.ui(11)).fixedSize(horizontal: false, vertical: true)
                    AddressLines(address: o.recipient)
                    Text("An exchange's app wants the plain address: use Exchange.").font(.ui(10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .exchange:
            VStack(alignment: .leading, spacing: 8) {
                ReceiveCard(logo: Self.logo(net), network: net.title, badge: solana ? "recommended" : nil, address: o.recipient,
                            what: solana ? "Withdraw USDC, SOL or any Solana token (SPL). USDC is what ihatecrypto trades with; keep ≈ 0.02 SOL for fees."
                                : "Withdraw \(net.usdcSymbol)\(net.coin.map { ", \($0)" } ?? "") or any token on \(net.title). The same 0x address is this wallet on every EVM network ihatecrypto uses.",
                            tint: solana ? Brand.solanaTint : Color(light: 0xEAF0FF, dark: 0x14213F))
                Label("Pick the network exactly: \(solana ? "Solana (SPL)" : net.title). Sent on another network, money can get stuck. Many exchanges withdraw USDC on Solana or Base for well under a dollar.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.jevInk).font(.ui(10))
                    .fixedSize(horizontal: false, vertical: true)
                if !solana {
                    Label("Hyperliquid uses the same 0x address, but money gets there through ihatecrypto. Never send to Hyperliquid’s old bridge contract.",
                          systemImage: "info.circle").foregroundStyle(.secondary).font(.ui(10)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func openPage(_ o: TopUpOrder) async {
        opening = true
        defer { opening = false }
        do {
            NSWorkspace.shared.open(try await TopUpPage.shared.open(o))
            problem = nil
            waiting = true
        } catch {
            problem = "The page didn't open: \((error as? WalletError)?.message ?? error.localizedDescription)"
        }
    }

    // MARK: Watching for it

    /// Reads the order's balance (shown as now → after); once a way is used, again every 4 s for up to 20 min. When it
    /// rises, a line says what landed and the whole portfolio is read again (which says in the chat what came in).
    private func watch(_ o: TopUpOrder) async {
        let before = await Self.balances(o)
        if Task.isCancelled { return }
        held = (o.network.key, before)
        guard waiting, !before.isEmpty else { return }
        for _ in 0..<300 {
            try? await Task.sleep(for: .seconds(4))
            if Task.isCancelled { return }
            let now = await Self.balances(o)
            let up = now.compactMap { symbol, value in
                before[symbol].flatMap { value > $0 ? MoneyMove(place: o.network.title, symbol: symbol, was: $0, after: value) : nil }
            }
            guard !up.isEmpty else { continue }
            held = (o.network.key, now)
            let digits = { (m: MoneyMove) in m.symbol == o.network.usdcSymbol ? 2 : 6 }
            arrived = "Landed on \(o.network.title): " + up.map {
                "+\(Fmt.num($0.after - $0.was, maxFraction: digits($0))) \($0.symbol), \(Fmt.num($0.was, maxFraction: digits($0))) → \(Fmt.num($0.after, maxFraction: digits($0)))"
            }.joined(separator: "; ")
            await ws.refresh()
            return
        }
    }

    /// The order's coin at the wallet, by symbol, straight from the network: USDC and the network's coin for «any coin»
    /// (another token landing shows with the next portfolio read). Empty when the network didn't answer.
    private nonisolated static func balances(_ o: TopUpOrder) async -> [String: Decimal] {
        let net = o.network, coins: [TopUpOrder.Coin] = o.coin == .any ? [.usdc, .native] : [o.coin]
        var out: [String: Decimal] = [:]
        for coin in coins where coin == .usdc || net.coin != nil {
            let one = TopUpOrder(network: net, coin: coin, amount: nil, recipient: o.recipient)
            var raw: Decimal?
            if net.chainId == nil {
                raw = coin == .usdc ? (try? await SolanaRPC().tokenBalance(owner: o.recipient, mint: net.usdc)).map { Decimal($0) }
                                    : (try? await SolanaRPC().balance(o.recipient)).map { Decimal($0) }
            } else if let rpc = EVMNetwork.named(net.key)?.rpc {
                raw = coin == .usdc ? (try? await rpc.read(net.usdc, ERC20.balanceOf(o.recipient))).flatMap { ABI.decimal(in: $0, word: 0) }
                    : (try? await rpc.call("eth_getBalance", [o.recipient, "latest"]) as? String)
                        .map { $0.dropFirst(2).reduce(Decimal(0)) { $0 * 16 + Decimal(Int(String($1), radix: 16) ?? 0) } }
            }
            if let raw { out[one.symbol] = raw / pow(10, one.decimals) }
        }
        return out
    }
}

extension TopUpOrder.Network {
    init(_ n: EVMNetwork) {
        self.init(key: n.key, title: n.name, chainId: n.rpc.chainId, usdc: n.usdc, usdcSymbol: EVMRPC.dollars[n.usdc] ?? "USDC",
                  usdcDecimals: n.usdcDecimals, coin: n.feeToken == nil ? n.gasCoin : nil, explorer: n.explorer, rpc: n.rpc.url.absoluteString,
                  // A USDC transfer on Ethereum: ≈ 1¢ at 0.07 gwei (2026-10-15), ≈ 15¢ at 0.74 (2026-09-29); the rest stay under a cent.
                  cost: n.key == "ethereum" ? "fee 1–20¢ · lands in ~15 s" : "fee under 1¢ · lands in seconds")
    }
}

struct ReceiveCard: View {
    let logo: String
    let network: String
    let badge: String?
    let address: String
    let what: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let qr = QR.image(address) {
                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 104, height: 104)
                    .padding(6).background(RoundedRectangle(cornerRadius: 12).fill(.white))
                    .overlay(alignment: .center) { TokenLogo(name: logo, size: 26, round: true) }
                    .help("Scan with the exchange or wallet app")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TokenLogo(name: logo, size: 20)
                    Text(network).font(.ui(14, .bold))
                    if let badge {
                        Text(badge.uppercased()).font(.ui(9, .heavy)).foregroundStyle(Brand.onAccent)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Brand.accent))
                    }
                }
                AddressLines(address: address)
                Text(what).font(.ui(10)).fixedSize(horizontal: false, vertical: true)
                CopyButton(title: "Copy address", text: address, help: "Copy the address")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(tint))
    }
}

/// An address as it's checked by eye: its ends in bold, then the whole of it, selectable.
struct AddressLines: View {
    let address: String

    var body: some View {
        let ends = AddressCheck.ends(address)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text(ends.start).fontWeight(.bold)
                Text("  …  ").foregroundStyle(.tertiary)
                Text(ends.end).fontWeight(.bold)
            }
            .font(.system(size: 13, design: .monospaced))
            Text(address).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A refresh icon; on hover it lights up and «Updated 12 s ago» fades in. A click refreshes now.
struct BalanceFreshness: View {
    @Environment(Workspace.self) private var ws
    /// The hover of the block around it (the balance), so the line shows without aiming at the small icon.
    var hovering = false
    @State private var selfHover = false
    @State private var refreshing = false

    private var shown: Bool { hovering || selfHover || refreshing }

    var body: some View {
        HStack(spacing: 5) {
            Button {
                refreshing = true
                Task { await ws.refresh(); refreshing = false }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .symbolEffect(.rotate, isActive: refreshing)
            }
            .buttonStyle(HoverIconStyle(size: 18)).disabled(refreshing)
            .accessibilityLabel("Refresh balances")
            if shown {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(refreshing ? "Updating…" : freshness(now: context.date))
                        .font(.ui(10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                .transition(.opacity)
            }
        }
        .font(.ui(10))
        .animation(.easeOut(duration: 0.2), value: shown)
        .onHover { selfHover = $0 }
        .help("ihatecrypto reads balances straight from Solana, Hyperliquid and Base: every 30 s, every 10 s while it guards a position or watches an alert, and right after each action. Click to refresh now.")
    }

    private func freshness(now: Date) -> String {
        guard let at = ws.updatedAt else { return "Loading…" }
        let seconds = max(0, Int(now.timeIntervalSince(at)))
        return "Updated \(seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min") ago"
    }
}

enum QR {
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    static func image(_ text: String) -> NSImage? {
        if let hit = cache[text] { return hit }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"   // room for the logo in the middle
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        cache[text] = image
        return image
    }
}

extension Workspace {
    /// Money that came in from outside since the last refresh — not during or right after ihatecrypto's own moves.
    func announceIncoming(before: (usdc: Decimal?, sol: Decimal?, base: Decimal?)) {
        guard !executing, !preparing, Date().timeIntervalSince(lastOwnMove) > 120 else { return }
        recordIncomingFlows(before: before)
        var lines: [String] = []
        let on = say("on", "на"), now = say("now", "сейчас")
        if let old = before.usdc, let new = solana?.usdc, new - old >= Decimal(string: "0.01")! { lines.append("+\(Fmt.num(new - old)) USDC \(on) Solana (\(now) \(Fmt.num(new)))") }
        if let old = before.sol, let new = solana?.sol, new - old >= Decimal(string: "0.0005")! { lines.append("+\(Fmt.num(new - old, maxFraction: 4)) SOL \(on) Solana") }
        if let old = before.base, let new = base?.usdc, new - old >= Decimal(string: "0.01")! { lines.append("+\(Fmt.num(new - old)) USDC \(on) Base") }
        guard !lines.isEmpty else { return }
        let text = say("💸 Received ", "💸 Пришло ") + lines.joined(separator: ", ") + "."
        notify(.incoming, say("Money arrived", "Пришли деньги"), text)
        reply(text, note: "incoming")
    }
}
