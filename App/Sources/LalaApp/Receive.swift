import AppKit
import CoreImage.CIFilterBuiltins
import LalaCore
import SwiftUI
import WalletCore

/// Where to send money into LALA: the wallet's own addresses, which network each takes, and how balances update.
struct ReceiveBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.accent).font(.system(size: 18))
                Text("Top up LALA").font(.system(size: 16, weight: .bold))
                Spacer()
                Button { withAnimation(StudioView.spring) { ws.showReceive = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.hoverIcon).help("Close")
            }
            if isSolanaAddress(ws.solanaAddress) {
                ReceiveCard(logo: "sol", network: "Solana", badge: "recommended", address: ws.solanaAddress,
                            what: "USDC or SOL on the Solana network. USDC is what LALA trades with; keep ≈ 0.02 SOL for fees.",
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
                Label("Hyperliquid uses the same 0x address, but money gets there through LALA (it bridges from Solana). Never send to Hyperliquid’s old bridge contract.",
                      systemImage: "info.circle").foregroundStyle(.secondary)
            }
            .font(.caption)
            BalanceFreshness()
        }
        .padding(18)
        .frame(width: 470, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 26).fill(Brand.card).shadow(color: .black.opacity(0.08), radius: 18, y: 10))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Brand.accent.opacity(0.5), lineWidth: 1.5))
        .transition(.scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity))
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
                    .overlay(alignment: .center) { TokenLogo(name: logo, size: 22).padding(2).background(Circle().fill(.white)) }
                    .help("Scan with the exchange or wallet app")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TokenLogo(name: logo, size: 20)
                    Text(network).font(.system(size: 14, weight: .bold))
                    if let badge {
                        Text(badge.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
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
                Text(what).font(.caption).fixedSize(horizontal: false, vertical: true)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                    withAnimation(.snappy) { copied = true }
                    Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { copied = false } }
                } label: {
                    Label(copied ? "Copied" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(tint))
    }
}

/// «Updated 12 s ago · every 30 s · Refresh»: how fresh the numbers are and how they get updated.
struct BalanceFreshness: View {
    @Environment(Workspace.self) private var ws
    @State private var refreshing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(freshness(now: context.date)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 4)
            Button(refreshing ? "Refreshing…" : "Refresh now") {
                refreshing = true
                Task { await ws.refresh(); refreshing = false }
            }
            .buttonStyle(.borderless).font(.caption.weight(.semibold)).disabled(refreshing)
        }
        .help("LALA reads balances straight from Solana, Hyperliquid and Base: every 30 s, every 10 s while it guards a position or watches an alert, and right after each action. Money that arrives is announced in the chat.")
    }

    private func freshness(now: Date) -> String {
        guard let at = ws.updatedAt else { return "Balances load from the networks…" }
        let seconds = max(0, Int(now.timeIntervalSince(at)))
        let every = ws.exitRules.isEmpty && ws.alerts.isEmpty ? 30 : 10
        return "Updated \(seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min") ago · every \(every) s"
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
        var lines: [String] = []
        if let old = before.usdc, let new = solana?.usdc, new - old >= Decimal(string: "0.01")! { lines.append("+\(Fmt.num(new - old)) USDC on Solana (now \(Fmt.num(new)))") }
        if let old = before.sol, let new = solana?.sol, new - old >= Decimal(string: "0.0005")! { lines.append("+\(Fmt.num(new - old, maxFraction: 4)) SOL on Solana") }
        if let old = before.base, let new = base?.usdc, new - old >= Decimal(string: "0.01")! { lines.append("+\(Fmt.num(new - old)) USDC on Base") }
        guard !lines.isEmpty else { return }
        let text = "💸 Received " + lines.joined(separator: ", ") + "."
        notify("Money arrived", text)
        reply(text, note: "incoming")
    }
}
