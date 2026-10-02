import DeFiYields
import IhatecryptoCore
import SwiftUI

/// «Переложи в лучшие ставки» on the canvas: each move as from → to with its rates, the amount, the extra interest a
/// year and what the move costs; the moves that don't pay back in 30 days with their math; Confirm while it waits.
struct RebalanceBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if let r = ws.rebalancePlan, r.canvas == ws.canvasID {
            let waiting: Bool = { if case .rebalance? = ws.pendingAllocation { true } else { false } }()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Rebalance USDC · max \(Fmt.pct(r.maxShare)) per protocol").font(.ui(14, .semibold))
                    StatusChip(text: waiting ? "waiting for the signature" : "nothing to move", tint: waiting ? Brand.profit : .secondary).fixedSize()
                }
                if !r.plan.moves.isEmpty {
                    // The rebalance, then each move out of one place and into the next, as route cards.
                    RouteCards(steps: [ActivityBubble(kind: "step", label: "REBALANCE · USDC", title: "+\(Fmt.usd(r.plan.yearlyGain)) a year",
                                                      lines: ["max per place\t\(Fmt.pct(r.maxShare))", "costs\t≈ \(Fmt.usd(r.plan.cost))"],
                                                      logo: "usdc", fill: .check)]
                        + r.plan.moves.flatMap { m in [
                            ActivityBubble(kind: "step", label: "FROM · \(m.from.uppercased())", title: "\(Fmt.num(m.amount, maxFraction: 2)) USDC",
                                           lines: ["rate\t\(Fmt.num(m.fromAPY.rounded(2, .plain)))%"], logo: Workspace.logo(for: m.from), fill: .place(m.from)),
                            ActivityBubble(kind: "step", label: "INTO · \(m.to.uppercased())", title: "\(Fmt.num(m.amount, maxFraction: 2)) USDC",
                                           lines: ["rate\t\(Fmt.num(m.toAPY.rounded(2, .plain)))%", "a year\t+\(Fmt.usd(m.yearlyGain))", "costs\t≈ \(Fmt.usd(m.cost))"]
                                               + (m.paybackDays.map { ["pays back\t\(Fmt.num($0.rounded(0, .up))) days"] } ?? []),
                                           logo: Workspace.logo(for: m.to), fill: .place(m.to)),
                        ] }, build: true)
                }
                if !r.plan.moves.isEmpty {
                    Label("Together ≈ +\(Fmt.usd(r.plan.yearlyGain)) a year for ≈ \(Fmt.usd(r.plan.cost)). Each move goes through Solana: out of one place, into the next, checked and simulated like the single commands.",
                          systemImage: "equal.circle").font(.ui(10)).foregroundStyle(.secondary)
                }
                ForEach(Array(r.plan.skipped.enumerated()), id: \.offset) { _, skip in
                    Label("\(skip.move.from) → \(skip.move.to) not worth it: \(skip.reason).", systemImage: "minus.circle")
                        .font(.ui(10)).foregroundStyle(.secondary)
                }
                ForEach(r.plan.notes, id: \.self) { Label($0, systemImage: "info.circle").font(.ui(10)).foregroundStyle(.secondary) }
                if waiting { PendingButtons() }
            }
            .frame(minWidth: 470, alignment: .leading)
            .transition(.opacity)
        }
    }
}
