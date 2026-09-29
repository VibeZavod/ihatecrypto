import LalaCore
import SwiftUI

extension Workspace {
    /// «alert me when ETH is above 2,800», «cancel alerts».
    func alertCommand(_ command: AlertCommand, note: String? = nil) {
        switch command {
        case .clear:
            let n = alerts.count
            alerts = []
            reply(n == 0 ? "There were no price alerts." : "Price alerts cleared (\(n)).", note: note)
        case .set(let coin, let price, let above):
            let name = IntentParser.pretty(coin)
            guard let mark = markets[coin]?.markPx else { reply("No price for \(name) right now — try again in a moment.", note: note); return }
            let up = above ?? (price > mark)
            if up ? mark >= price : mark <= price {
                reply("\(name) is already \(up ? "above" : "below") \(Fmt.price(price)): now \(Fmt.price(mark)).", note: note)
                return
            }
            alerts.append(PriceAlert(coin: coin, above: up, price: price))
            let away = ((price - mark) / mark * 100).rounded(1, .plain)
            reply(say("🔔 I’ll tell you when \(name) goes \(up ? "above" : "below") \(Fmt.price(price)) — now \(Fmt.price(mark)), \(Fmt.num(abs(away)))% \(up ? "higher" : "lower"). Works while ihatecrypto is open or in the menu bar.",
                      "🔔 Скажу, когда \(name) будет \(up ? "выше" : "ниже") \(Fmt.price(price)) — сейчас \(Fmt.price(mark)), на \(Fmt.num(abs(away)))% \(up ? "выше" : "ниже"). Работает, пока ihatecrypto открыт или в строке меню."), note: note)
        }
    }

    /// Runs with every refresh: an alert that fires sends one notification and is done.
    func checkAlerts() {
        for a in alerts {
            guard let mark = markets[a.coin]?.markPx, a.fires(at: mark) else { continue }
            alerts.removeAll { $0.id == a.id }
            let text = say("\(IntentParser.pretty(a.coin)) is \(a.above ? "above" : "below") \(Fmt.price(a.price)): now \(Fmt.price(mark)).",
                           "\(IntentParser.pretty(a.coin)) \(a.above ? "выше" : "ниже") \(Fmt.price(a.price)): сейчас \(Fmt.price(mark)).")
            notify(.alerts, "🔔 \(IntentParser.pretty(a.coin))", text)
            reply(text + say(" The alert is done; set another any time.", " Алерт сработал; поставь новый, когда захочешь."), note: "price alert")
        }
    }
}

/// Alerts waiting in the portfolio frame, each with its distance to the price and a way to drop it.
struct AlertsCard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if !ws.alerts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Price alerts", systemImage: "bell.badge").font(.ui(10, .semibold))
                ForEach(ws.alerts) { a in
                    HStack(spacing: 6) {
                        AssetBadge(coin: a.coin, size: 18)
                        Text("\(IntentParser.pretty(a.coin).components(separatedBy: " (").first ?? a.coin) \(a.above ? "≥" : "≤") \(Fmt.price(a.price))")
                            .font(.ui(10, .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        if let mark = ws.markets[a.coin]?.markPx {
                            Text("\(Fmt.num(((a.price - mark) / mark * 100).rounded(1, .plain)))%").font(.ui(10)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Button { withAnimation(.snappy) { ws.alerts.removeAll { $0.id == a.id } } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.hoverIcon).font(.ui(10)).help("Remove the alert")
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.cardBorder))
        }
    }
}

/// The portfolio's value over time: a point every ten minutes, kept for 30 days (equity.json).
struct EquityPoint: Codable, Equatable {
    let at: Date
    let usd: Decimal
    /// The wallet it was measured for (P/L); nil in points kept before wallets were told apart.
    var wallet: String? = nil
}

extension Workspace {
    /// Only when both main balances are in: a half-loaded portfolio would draw a false dip.
    func recordEquity() {
        guard solana != nil, hl != nil, let e = equity, e > 0 else { return }
        if let last = equityHistory.last, Date().timeIntervalSince(last.at) < 600 { return }
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        equityHistory = equityHistory.filter { $0.at > cutoff } + [EquityPoint(at: Date(), usd: e, wallet: pnlWallet)]
    }

    /// The last `days` of history plus the value now. «Now» is when the balances were read: stamped with the clock, the
    /// series was new on every pass and the sparkline redrew each time.
    func equitySeries(days: Double = 7) -> [EquityPoint] {
        let since = Date().addingTimeInterval(-days * 86_400)
        return equityHistory.filter { $0.at >= since } + (equity.map { [EquityPoint(at: updatedAt ?? Date(), usd: $0)] } ?? [])
    }
}

/// A small line of the portfolio's value; green when it grew over the period, red when it fell.
struct EquitySparkline: View {
    let points: [EquityPoint]
    var height: CGFloat = 26

    var body: some View {
        let values = points.map { NSDecimalNumber(decimal: $0.usd).doubleValue }
        let up = (values.last ?? 0) >= (values.first ?? 0)
        Canvas { context, size in
            guard values.count > 1, let lo = values.min(), let hi = values.max() else { return }
            let span = max(hi - lo, max(hi * 0.002, 0.01))
            let start = points.first!.at.timeIntervalSince1970, total = max(points.last!.at.timeIntervalSince1970 - start, 1)
            var line = Path()
            for (i, p) in points.enumerated() {
                let pt = CGPoint(x: size.width * (p.at.timeIntervalSince1970 - start) / total, y: size.height * (1 - (values[i] - lo) / span))
                i == 0 ? line.move(to: pt) : line.addLine(to: pt)
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            let color = up ? Brand.profit : Brand.loss
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.25), color.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .frame(height: height)
        .accessibilityLabel("Portfolio value over the week")
    }
}
