import LalaCore
import SwiftUI

/// «Add block» at the canvas's top right: it opens the library of blocks the agent builds a request from.
struct AddBlockButton: View {
    @Binding var open: Bool

    var body: some View {
        Button { withAnimation(.snappy) { open.toggle() } } label: {
            Label("Add block", systemImage: open ? "xmark" : "plus").font(.ui(13, .semibold))
                .padding(.horizontal, 14).frame(height: 36).contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .glassEffect(.regular, in: Capsule())
        .help(open ? "Close the blocks" : "The blocks the agent builds a request from")
    }
}

/// Every block the agent builds a request from (BlockCatalog), by group, each as the small route card it becomes with
/// its form on it. A pick puts the block's example into the chat to finish and send; the ones the agent adds to every
/// trade by itself are shown, not picked.
struct BlocksPanel: View {
    @Environment(Workspace.self) private var ws
    let close: () -> Void

    static let columns = 3
    static var width: CGFloat { CGFloat(columns) * RouteCards.smallWidth + CGFloat(columns - 1) * 12 + 32 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Blocks").font(.ui(17, .bold))
                Text("What the agent builds a request from. Pick one to start it in the chat, or just write — it picks them itself.")
                    .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(BlockCatalog.groups, id: \.self) { group in
                        Text(group.uppercased()).font(.ui(10, .heavy)).tracking(0.8).foregroundStyle(.secondary).padding(.top, 8)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(RouteCards.smallWidth), spacing: 12), count: Self.columns),
                                  alignment: .leading, spacing: 12) {
                            ForEach(BlockCatalog.all.filter { $0.group == group }) { tile($0) }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Brand.cardBorder))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
        .transition(.opacity)
    }

    @ViewBuilder private func tile(_ b: BlockCatalog.Block) -> some View {
        if b.automatic {
            RouteCard(step: bubble(b), state: .plain, compact: true, hint: "The agent adds it to every trade by itself")
        } else {
            let text = example(b)
            Button {
                ws.draft = text
                close()
            } label: { RouteCard(step: bubble(b), state: .plain, compact: true, hint: "Puts “\(text)” into the chat") }
                .buttonStyle(.plain)
        }
    }

    /// The block as a route card: its label and title, the form in rows (at most four show).
    private func bubble(_ b: BlockCatalog.Block) -> ActivityBubble {
        ActivityBubble(kind: "step", label: b.label, title: b.title, lines: b.form.components(separatedBy: " · ") + (b.automatic ? ["added by the agent"] : []),
                       logo: b.logo, fill: RouteFill(rawValue: b.fill) ?? .check)
    }

    /// With a trade plan on the canvas a price alert is for that plan: 2% its way from the price now, the plan as it
    /// stands (Alerts.swift ties the two).
    private func example(_ b: BlockCatalog.Block) -> String {
        guard b.label.hasPrefix("WHEN"), ws.intent != TradeIntent(), !ws.managesPosition, let mark = ws.market?.markPx else { return b.example }
        let long = ws.intent.side == .long
        let level = mark * (long ? Decimal(string: "0.98")! : Decimal(string: "1.02")!)
        let asset = ws.intent.asset.hasPrefix("xyz:") ? String(ws.intent.asset.dropFirst(4)) : ws.intent.asset
        return "when \(asset) is \(long ? "below" : "above") \(Fmt.price(level)): \(ws.intent.command)"
    }
}
