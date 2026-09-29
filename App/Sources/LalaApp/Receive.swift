import AppKit
import CoreImage.CIFilterBuiltins
import LalaCore
import SwiftUI
import WalletCore

/// Where to send money into LALA: the wallet's own addresses, which network each takes, and how balances update.
struct ReceiveBoard: View {
    @Environment(Workspace.self) private var ws
    /// Solana's USDC and SOL when the board opened: a deposit that lands after turns the card Done.
    @State private var start: (usdc: Decimal, sol: Decimal)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.accentInk).font(.system(size: 18))
                Text("Top up ihatecrypto").font(.ui(16, .bold))
                Spacer()
                Button { withAnimation(StudioView.spring) { ws.showReceive = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.hoverIcon).help("Close")
            }
            RouteCards(steps: [topUp])
            if isSolanaAddress(ws.solanaAddress) {
                ReceiveCard(logo: "sol", network: "Solana", badge: "recommended", address: ws.solanaAddress,
                            what: "USDC or SOL on the Solana network. USDC is what ihatecrypto trades with; keep ≈ 0.02 SOL for fees.",
                            tint: Brand.solanaTint)
            }
            if isEVMAddress(ws.hlAddress) {
                ReceiveCard(logo: "base", network: "Base", badge: nil, address: ws.hlAddress,
                            what: "USDC or ETH on Base. Then say “move USDC from Base to Solana”, or “lend 2 USDC on Aave”.",
                            tint: Color(light: 0xEAF0FF, dark: 0x14213F))
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("On an exchange, pick the network exactly: Solana (SPL) or Base. Sent on another network, money can get stuck.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.jevInk)
                Label("Hyperliquid uses the same 0x address, but money gets there through ihatecrypto (it bridges from Solana). Never send to Hyperliquid’s old bridge contract.",
                      systemImage: "info.circle").foregroundStyle(.secondary)
            }
            .font(.ui(10))
            BalanceFreshness()
        }
        .padding(18)
        .frame(width: 470, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 26).fill(Brand.card).shadow(color: .black.opacity(0.08), radius: 18, y: 10))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Brand.accent.opacity(0.5), lineWidth: 1.5))
        .transition(.opacity)
        .onAppear { start = ws.solana.map { ($0.usdc, $0.sol) } }
    }

    /// The deposit being waited for: Watching until Solana's USDC or SOL goes up, then what landed.
    private var topUp: ActivityBubble {
        let now = ws.solana
        let usdc = start.flatMap { s in now.map { $0.usdc - s.usdc } }.flatMap { $0 > 0 ? $0 : nil }
        let sol = start.flatMap { s in now.map { $0.sol - s.sol } }.flatMap { $0 > 0 ? $0 : nil }
        let landed = [usdc.map { "+\(Fmt.num($0)) USDC" }, sol.map { "+\(Fmt.num($0, maxFraction: 6)) SOL" }].compactMap { $0 }
        return ActivityBubble(kind: "step", label: "TOP UP · SOLANA", title: landed.first ?? "USDC or SOL",
                              lines: [landed.isEmpty ? "watching for a deposit to land" : "landed on your Solana address"] + landed.dropFirst(),
                              status: landed.isEmpty ? "watching" : "passed", logo: "sol", fill: .solana)
    }
}

struct ReceiveCard: View {
    let logo: String
    let network: String
    let badge: String?
    let address: String
    let what: String
    let tint: Color
    @State private var copied = false

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
                let ends = AddressCheck.ends(address)
                HStack(spacing: 0) {
                    Text(ends.start).fontWeight(.bold)
                    Text("  …  ").foregroundStyle(.tertiary)
                    Text(ends.end).fontWeight(.bold)
                }
                .font(.system(size: 13, design: .monospaced))
                Text(address).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(what).font(.ui(10)).fixedSize(horizontal: false, vertical: true)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                    withAnimation(.snappy) { copied = true }
                    Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { copied = false } }
                } label: {
                    Label(copied ? "Copied" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.ui(12, .semibold))
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(tint))
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
    /// Money that came in from outside since the last refresh — not during or right after LALA's own moves.
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
