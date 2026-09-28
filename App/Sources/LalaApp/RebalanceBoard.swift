import DeFiYields
import LalaCore
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
                    Text("Rebalance USDC · max \(Fmt.pct(r.maxShare)) per protocol").font(.system(size: 14, weight: .semibold))
                    StatusChip(text: waiting ? "waiting for the signature" : "nothing to move", tint: waiting ? Brand.profit : .secondary).fixedSize()
                }
                ForEach(Array(r.plan.moves.enumerated()), id: \.offset) { _, move in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            end(move.from, move.fromAPY, label: "FROM")
                            Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                            end(move.to, move.toAPY, label: "TO")
                            Spacer(minLength: 0)
                        }
                        Text("\(Fmt.num(move.amount, maxFraction: 2)) USDC · +\(Fmt.usd(move.yearlyGain)) a year · costs ≈ \(Fmt.usd(move.cost))"
                             + (move.paybackDays.map { " · pays back in \(Fmt.num($0.rounded(0, .up))) days" } ?? ""))
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Brand.card))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Brand.cardBorder))
                }
                if !r.plan.moves.isEmpty {
                    Label("Together ≈ +\(Fmt.usd(r.plan.yearlyGain)) a year for ≈ \(Fmt.usd(r.plan.cost)). Each move goes through Solana: out of one place, into the next, checked and simulated like the single commands.",
                          systemImage: "equal.circle").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(r.plan.skipped.enumerated()), id: \.offset) { _, skip in
                    Label("\(skip.move.from) → \(skip.move.to) not worth it: \(skip.reason).", systemImage: "minus.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(r.plan.notes, id: \.self) { Label($0, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                if waiting { PendingButtons() }
            }
            .frame(width: 470, alignment: .leading)
            .transition(.opacity)
        }
    }

    private func end(_ place: String, _ apy: Decimal, label: String) -> some View {
        HStack(spacing: 8) {
            TokenLogo(name: Workspace.logo(for: place), size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(label) · \(place.uppercased())").font(.system(size: 9, weight: .heavy)).tracking(0.4).foregroundStyle(.secondary).lineLimit(1)
                Text("\(Fmt.num(apy.rounded(2, .plain)))%").font(.system(size: 17, weight: .heavy)).monospacedDigit()
            }
        }
    }
}
