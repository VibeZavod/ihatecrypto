import IhatecryptoCore
import SwiftUI
import TradeExecution
import WalletCore

// The automation wallet where the money is counted (the owner, 2026-10-15: «надо в сайдбар и в портфолио добавить
// сколько на automation, иначе не понятно»; from the design canvas he picked the split total for the sidebar and the
// card for the portfolio). Money sent to it had left the balance with nothing saying where.

extension Workspace {
    /// What the automation wallet holds, in dollars: its USDC everywhere, its other Solana tokens at their price, its SOL.
    /// nil without the wallet or before it's read.
    var automationUSD: Decimal? {
        guard automationWallet != nil, let b = automationBudget else { return nil }
        return b.total + b.tokens.reduce(0) { $0 + ($1.usd ?? 0) } + (b.sol ?? 0) * (markets["SOL"]?.markPx ?? 0)
    }

    /// The automation wallet's money, read every minute while the sidebar shows the balance.
    func watchAutomation() async {
        while automationWallet != nil, !Task.isCancelled {
            await loadAutomationBudget()
            try? await Task.sleep(for: .seconds(60))
        }
    }
}

/// Under the sidebar's balance, once the automation wallet holds something: the total splits into the main wallet and
/// Automation, a bar and the two amounts. A click opens the Schedule, whose wallet it is.
struct AutomationSplit: View {
    @Environment(Workspace.self) private var ws
    let main: Decimal
    let automation: Decimal

    var body: some View {
        let share = CGFloat(truncating: (automation / max(main + automation, Decimal(string: "0.01")!)) as NSNumber)
        Button { withAnimation(StudioView.spring) { ws.showSchedule = true } } label: {
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { g in
                    HStack(spacing: 2) {
                        Capsule().fill(Color.primary).frame(width: max(4, (g.size.width - 2) * (1 - share)))
                        Capsule().fill(Brand.accent)
                    }
                }
                .frame(height: 5)
                HStack(spacing: 5) {
                    Circle().fill(Color.primary).frame(width: 7, height: 7)
                    Text("Main")
                    Text(masked(Fmt.usd(main))).fontWeight(.bold)
                    Spacer(minLength: 4)
                    Circle().fill(Brand.accent).frame(width: 7, height: 7)
                    Text("Automation")
                    Text(masked(Fmt.usd(automation))).fontWeight(.bold)
                }
                .font(.ui(10.5)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(.top, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("The balance is both wallets: Main signs with \(Presence.name), Automation signs the Schedule’s tasks by itself. Click to open the Schedule.")
        .accessibilityLabel(masked("Main \(Fmt.usd(main)), Automation \(Fmt.usd(automation))"))
    }
}

/// The automation wallet beside the networks in the portfolio: what it holds, and whether it can spend it.
struct AutomationPortfolioCard: View {
    @Environment(Workspace.self) private var ws

    private struct Coin: Identifiable {
        let logo: String, symbol: String, amount: Decimal, place: String, usd: Decimal?
        var id: String { symbol + place }
    }

    var body: some View {
        if let w = ws.automationWallet, let b = ws.automationBudget, let usd = ws.automationUSD {
            let sol = b.sol ?? 0
            let coins = ([Coin(logo: "usdc", symbol: "USDC", amount: b.solana ?? 0, place: "Solana", usd: b.solana)]
                + b.tokens.map { Coin(logo: $0.symbol.lowercased(), symbol: $0.symbol, amount: $0.amount, place: "Solana", usd: $0.usd) }
                + b.evm.sorted { $0.key < $1.key }.map { key, v in
                    Coin(logo: "usdc", symbol: key == "robinhood" ? "USDG" : "USDC", amount: v, place: EVMNetwork.named(key)?.name ?? key, usd: v)
                }
                + [Coin(logo: "usdc", symbol: "USDC", amount: b.near ?? 0, place: "NEAR", usd: b.near)]).filter { $0.amount > 0 }
            VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(StudioView.spring) { ws.showSchedule = true } } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.accentInk)
                            .frame(width: 34, height: 34).background(Circle().fill(Brand.accent.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.label).font(.ui(14, .semibold)).lineLimit(1)
                            // Short: the portfolio's column is narrow, and «…tasks · n…» was cut at two lines.
                            Text("your Schedule wallet · not in this total").font(.ui(10)).foregroundStyle(.secondary)
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Text(masked(Fmt.usd(usd))).font(.ui(13, .bold)).monospacedDigit().lineLimit(1).fixedSize()
                    }
                    ForEach(coins) { row($0) }
                    row(Coin(logo: "sol", symbol: "SOL", amount: sol, place: "gas", usd: sol * (ws.markets["SOL"]?.markPx ?? 0)), dim: sol == 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Your automation wallet: the Schedule’s tasks spend from it without \(Presence.name). Click to open the Schedule.")
            // Money on Solana and no SOL: every task there fails on its fee. The fix is one chat message away.
            if sol < TaskRun.solFloor, !coins.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No SOL for fees: it can’t send yet", systemImage: "exclamationmark.triangle.fill")
                        .font(.ui(10.5, .semibold)).foregroundStyle(Brand.jevInk)
                    Button { ws.suggestGas() } label: {
                        Label("Top up gas", systemImage: "fuelpump.fill").font(.ui(11, .bold))
                    }
                    .buttonStyle(.bordered).controlSize(.small).pointerStyle(.link)
                    .help("Puts the send to «\(w.label)» in the chat; nothing goes until you send it, then Confirm and \(Presence.name)")
                }
                .padding(.horizontal, 9).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Brand.jevInk.opacity(0.1)))
            }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
    }

    private func row(_ c: Coin, dim: Bool = false) -> some View {
        HStack(spacing: 8) {
            TokenLogo(name: c.logo, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(c.symbol).font(.ui(12, .semibold))
                Text(masked(Fmt.num(c.amount, maxFraction: c.symbol == "SOL" ? 4 : 2)) + (c.place == "gas" ? "" : " · on \(c.place)")).font(.ui(10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(masked(c.usd.map(Fmt.usd) ?? "—")).font(.ui(12, .semibold)).monospacedDigit()
        }
        .opacity(dim ? 0.55 : 1)
    }
}
