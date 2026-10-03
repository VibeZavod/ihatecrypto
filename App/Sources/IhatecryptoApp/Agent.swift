import DeFiYields
import EVMChain
import Foundation
import IhatecryptoCore
import SwiftUI
import TradeExecution

/// The ways to go on the model offered with an answer: cards on the canvas it was given on. A card runs its English
/// command through the same parsers, checks and confirmations as a typed one.
struct NextSteps {
    let options: [ChatRouter.Option]
    /// The message they answer: an address in a card must be in it, unless the card only shows something.
    let userText: String
    /// Addresses the lookups returned (a token found by name, a repaired mint).
    let found: [String]
    let canvas: UUID?

    static func icon(_ command: String) -> String {
        let c = command.lowercased()
        return c.hasPrefix("chart") ? "chart.xyaxis.line" : c.hasPrefix("watch") ? "star" : c.hasPrefix("alert") ? "bell"
            : c.hasPrefix("buy") ? "cart" : c.hasPrefix("sell") ? "arrow.down.circle" : c.hasPrefix("long") ? "arrow.up.right"
            : c.hasPrefix("short") ? "arrow.down.right" : c.hasPrefix("withdraw") || c.hasPrefix("unstake") ? "arrow.uturn.backward"
            : c.hasPrefix("move") || c.hasPrefix("send") ? "arrow.left.arrow.right" : c.hasPrefix("where") ? "percent"
            : c.contains("lend") || c.hasPrefix("deposit") || c.hasPrefix("stake") || c.hasPrefix("spread") || c.hasPrefix("rebalance") ? "building.columns"
            : c.hasPrefix("what") ? "flame" : c.hasPrefix("profit") ? "dollarsign.circle" : c.hasPrefix("pay") ? "creditcard" : "arrow.right.circle"
    }
}

extension Workspace {
    /// A command that only opens something (a chart, a token's card, the rates) or watches a token: it may use an
    /// address a lookup found. Anything that moves money needs the address in the user's own words. One line: a chain,
    /// a task or an alert is checked step by step (ChatRouter.addressesAllowed with `found`).
    nonisolated static func displays(_ command: String) -> Bool {
        switch TokenCommand.parse(command) {
        case .show?, .favorite?: return true
        default: break
        }
        if ChartCommand.parse(command) != nil || PnLCommand.parse(command) != nil { return true }
        if case .yields? = WalletCommand.parse(command) { return true }
        return false
    }

    /// One lookup the model asked for, answered from what this Mac knows and public market data.
    func agentLookup(_ l: ChatRouter.Lookup) async -> String {
        switch l.tool {
        case "portfolio":
            agentStep = say("Checking your portfolio", "Смотрю портфель")
            let stories = (try? await TradeHistory.fills(user: hlAddress)).map(TradeHistory.stories) ?? []
            return (answerFacts(stories) + (await pnlFacts())).joined(separator: "\n")
        case "market":
            guard let coin = IntentParser.namedAsset(l.arg, markets: Set(markets.keys)), markets[coin] != nil else {
                return "No Hyperliquid market for «\(l.arg)». For a token by its contract or name use the token lookup."
            }
            agentStep = say("Looking at \(IntentParser.pretty(coin))", "Смотрю \(IntentParser.pretty(coin))")
            if atr[coin] == nil, let v = try? await Hyperliquid.atrPct(coin: coin) { atr[coin] = v }
            var facts = [marketLine(coin)].compactMap { $0 }
            if let p = positions.first(where: { $0.coin == coin }) {
                facts.append("Open: \(p.size > 0 ? "long" : "short"), \(positionSummary(p)), unrealized \(signed(p.unrealizedPnl)).")
            }
            for side in [Side.long, .short] {
                guard let book = bookPlan(asset: coin, side: side) else { continue }
                facts.append("By the book, a \(side == .long ? "long" : "short") now: \(book.line).")
                facts += book.advice.map { "  rule check (\($0.level == .ok ? "ok" : $0.level == .warn ? "warning" : "blocked")): \($0.text)" }
            }
            if let candles = try? await Hyperliquid.candles(coin: coin, range: .week), let first = candles.first, let last = candles.last, first.close > 0 {
                facts.append("Week: \(Fmt.price(first.close)) → \(Fmt.price(last.close)) (\(signedPct((last.close - first.close) / first.close * 100))), "
                             + "low \(Fmt.price(candles.map(\.low).min() ?? 0)), high \(Fmt.price(candles.map(\.high).max() ?? 0)).")
            }
            return facts.joined(separator: "\n")
        case "token":
            agentStep = say("Looking the token up", "Ищу токен")
            var text = await TokenResearch.report(l.arg)
            for t in favoriteTokens where text.contains(t.address) {
                text += "\nIt is among the user's favorites" + (tokenBalances[t.id].map { "; they hold \(Fmt.num($0, maxFraction: 4))" } ?? "") + "."
            }
            return text
        case "rates":
            agentStep = say("Comparing rates", "Сравниваю ставки")
            let asset = l.arg.uppercased().contains("SOL") ? "SOL" : "USDC"
            let options = await loadYields(asset)
            let held = lend.filter { $0.usdc > 0 }.map { "Jupiter Lend \($0.vault) \(Fmt.num($0.usdc))" } + (kamino > 0 ? ["Kamino \(Fmt.usd(kamino))"] : [])
                + (base.map { [$0.aave > 0 ? "Aave · Base \(Fmt.num($0.aave)) USDC" : nil, $0.morpho > 0 ? "Morpho · Base \(Fmt.num($0.morpho)) USDC" : nil].compactMap { $0 } } ?? [])
                + lendingElsewhere.map { "\($0.place) \(Fmt.num($0.usdc)) USDC" }
            return (options.isEmpty ? ["The rate sources didn't answer."] : options.prefix(16).map { o in
                "\(o.place) (\(o.asset)): \(Fmt.num(o.apy.rounded(2, .plain)))% a year" + (o.tvlUSD.map { ", \(Fmt.usd(($0 / 1_000_000).rounded(1, .plain)))M deposited" } ?? "")
                    + (o.note.isEmpty ? "" : "; \(o.note)") + (o.how.map { "; form: \($0)" } ?? "; ihatecrypto can't deposit there")
            }) .joined(separator: "\n")
                + "\nFree on Solana: \(solana.map { "\(Fmt.num($0.usdc)) USDC, \(Fmt.num($0.sol, maxFraction: 4)) SOL" } ?? "unknown")."
                + (held.isEmpty ? " Nothing in vaults now." : " Already in vaults: " + held.joined(separator: ", ") + ".")
        case "gas":
            // «сколько газа уйдёт?»: today's gas on an EVM network and what the calls ihatecrypto makes there cost.
            agentStep = say("Checking gas", "Смотрю газ")
            let asked = EVMNetwork.named(l.arg.lowercased().trimmingCharacters(in: .whitespaces))
            var lines: [String] = []
            for net in asked.map({ [$0] }) ?? EVMNetwork.searched where net.feeToken == nil {
                guard let price = markets[net.gasCoin]?.markPx,
                      let (tip, maxFee) = try? await net.rpc.fees() else { lines.append("\(net.name): gas couldn't be read."); continue }
                let wei = (maxFee - tip) / 2 + tip   // fees() doubles the base fee for headroom
                func usd(_ units: Decimal) -> String { Fmt.usd(units * Decimal(wei) / 1_000_000_000_000_000_000 * price) }
                lines.append("\(net.name): \(Fmt.num(Decimal(wei) / 1_000_000_000, maxFraction: 3)) gwei, \(net.gasCoin) \(Fmt.price(price)) → "
                             + "an exact approve + Relay's deposit (≈ 150k gas) \(usd(150_000)); approve + Aave supply (≈ 250k) \(usd(250_000)); "
                             + "approve + Morpho deposit (≈ 500k) \(usd(500_000)); a Uniswap swap (≈ 200k) \(usd(200_000)); a transfer (≈ 65k) \(usd(65_000)).")
            }
            return (lines.isEmpty ? ["No EVM network by «\(l.arg)»."] : lines).joined(separator: "\n")
                + "\nRelay's own fee for a bridge is apart: it is on the move's card. Tempo has no gas coin: its fees come out of the USDC."
        case "movers":
            let list = moverList()
            func line(_ m: (coin: String, price: Decimal, change: Decimal)) -> String { "\(IntentParser.pretty(m.coin)) \(Fmt.price(m.price)) \(signedPct(m.change))" }
            return list.isEmpty ? "Markets aren't loaded yet."
                : "Up the most today: " + list.prefix(6).map(line).joined(separator: ", ") + ".\nDown the most: " + list.suffix(6).reversed().map(line).joined(separator: ", ") + "."
        case "services":
            agentStep = say("Looking for a service that takes payment", "Ищу сервис с оплатой")
            return await MPP.search(l.arg) + "\nUSDC on Tempo now: \(tempoUSDC.map { Fmt.num($0) } ?? "unknown"); what's short comes from Solana (\(solana.map { Fmt.num($0.usdc) } ?? "?") USDC)."
        case "service":
            agentStep = say("Reading the service's docs", "Читаю документацию сервиса")
            return await MPP.service(l.arg)
        default:
            return "There is no «\(l.tool)» lookup. Lookups: portfolio, market <ASSET>, token <ADDRESS or NAME>, rates <USDC|SOL>, gas [<NETWORK>], movers, services <WORDS>, service <ID>."
        }
    }

    /// The rates for the bubbles and the model: the vaults' own, and every Aave market and Morpho vault, read from the
    /// pools and vaults themselves (one that doesn't answer is left out).
    func loadYields(_ asset: String?) async -> [Yields.Option] {
        var options = await Yields.options(for: asset)
        guard asset != "SOL" else { return options }
        let lending = await withTaskGroup(of: Yields.Option?.self) { group in
            for m in AaveV3.markets {
                group.addTask {
                    guard let apy = try? await AaveV3.verify(m) else { return nil }
                    return Yields.Option(asset: "USDC", place: m.place, apy: apy, tvlUSD: nil,
                                         how: "lend 2 USDC on Aave" + (m.chain == "base" ? "" : " on \(m.chainName)"), note: Self.lendingNote(m.chain))
                }
            }
            for v in MorphoVault.vaults {
                group.addTask {
                    guard let apy = await MorphoRates.netAPY(v) else { return nil }
                    return Yields.Option(asset: "USDC", place: v.place, apy: apy, tvlUSD: nil,
                                         how: "deposit 2 USDC into Morpho" + (v.chain == "base" ? "" : " on \(v.chainName)"),
                                         note: "\(v.name); " + Self.lendingNote(v.chain))
                }
            }
            var out: [Yields.Option] = []
            for await o in group { if let o { out.append(o) } }
            return out
        }
        if let a = lending.first(where: { $0.place == "Aave · Base" }) { aaveAPY = a.apy }
        if let m = lending.first(where: { $0.place == "Morpho · Base" }) { morphoAPY = m.apy }
        options += lending
        options.sort { $0.apy > $1.apy }
        return options
    }

    /// What getting to a lending network takes, for the rates list.
    nonisolated static func lendingNote(_ chain: String) -> String {
        switch chain {
        case "ethereum": "on Ethereum: gas there and back runs from cents to dollars (the gas lookup says today's), so small amounts may not pay"
        case "polygon": "on Polygon: bridged from Solana with a little POL for gas"
        default: "on \(WalletCommand.placeName(chain)): bridged from Solana with a little ETH for gas"
        }
    }

    /// Opens the block the model's answer points to. Only display commands, and only addresses the user wrote or a
    /// lookup returned.
    func show(_ reading: ChatRouter.Reading, userText: String) async {
        guard let s = reading.show, Self.displays(s),
              ChatRouter.addressesAllowed(s, userText: userText, known: favoriteTokens.map(\.address) + reading.found) else { return }
        let markets = Set(markets.keys)
        if case .show(let address, let chain)? = TokenCommand.parse(s) {
            _ = await openTokenCard(address, chain: chain)
        } else if case .chart(let coin, let range)? = ChartCommand.parse(s, markets: markets) {
            await openChart(coin, range: range)
        } else if case .movers? = ChartCommand.parse(s, markets: markets) {
            withAnimation(StudioView.spring) { showMovers = true }
            UserDefaults.standard.set("plan", forKey: "canvasMode")
        } else if case .yields(let asset)? = WalletCommand.parse(s) {
            yieldOptions = await loadYields(asset)
        }
    }

    /// A token's card on the canvas, on the chain it trades on (the named one if it trades there). nil when no pool trades it.
    func openTokenCard(_ address: String, chain: String?) async -> TokenLookup.Info? {
        let infos = (try? await TokenLookup.lookup(address)) ?? []
        guard let info = infos.first(where: { chain == nil || $0.chain == chain }) ?? infos.first else { return nil }
        openToken(info.address, chain: info.chain)
        return info
    }

    /// Puts the model's cards on the canvas: only commands ihatecrypto parses, with addresses it may use.
    func offer(_ reading: ChatRouter.Reading, userText: String) {
        let markets = Set(markets.keys)
        let options = reading.options.filter { o in
            o.command != reading.show && ChatRouter.parses(o.command, markets: markets)
                && ChatRouter.addressesAllowed(o.command, userText: userText, known: favoriteTokens.map(\.address), found: reading.found,
                                               displays: Self.displays, markets: markets)
        }
        guard !options.isEmpty else { return }
        withAnimation(StudioView.spring) { nextSteps = NextSteps(options: options, userText: userText, found: reading.found, canvas: canvasID) }
    }

    /// A card picked on the canvas: said in the chat by its title and carried out like a typed command. Like any new
    /// message it drops a card that waited for Confirm.
    func pick(_ option: ChatRouter.Option) async {
        guard !busy, let steps = nextSteps else { return }
        heldAnswer = (nextSteps, yieldOptions, takeChoices)
        defer { heldAnswer = nil }
        nextSteps = nil
        pendingAction = nil
        pendingText = nil
        pendingAllocation = nil
        awaitingAmount = nil
        taskQueue = nil
        takeChoices = nil
        yieldOptions = nil
        allocationPreview = nil
        rebalancePlan = nil
        finishedAction = nil
        messages.append(Message(fromUser: true, text: option.title))
        thinking = true
        defer { thinking = false }
        beginActivity(.request, request: option.title)
        defer { snapshotCanvas(); saveCanvas() }
        if await !runCanonical(option.command, userText: steps.userText, before: intent) {
            reply(say("ihatecrypto can’t do “\(option.command)” yet — nothing moved.", "ihatecrypto пока не умеет «\(option.command)» — ничего не ушло."))
        }
    }
}

/// The ways to go on, as cards, one list per canvas: under a plan the rules stop, first what the code found that
/// fits, then the model's ideas, then raising the limit when the limit is what stops it; one of them Recommended.
struct NextStepsBoard: View {
    @Environment(Workspace.self) private var ws
    let steps: NextSteps?
    /// A plan the rules stop: what the code checked fits (the risk that passes every rule and the money).
    var fit: ChatRouter.Option?
    /// The risk limit is what stops the plan: Settings can raise it, at the user's own risk.
    var overLimit = false

    var body: some View {
        // The code's fix is checked against the rules, so it's the one recommended when there is one.
        let ideas = (steps?.options ?? []).filter { $0.command != fit?.command }.map { o in
            fit == nil ? o : ChatRouter.Option(title: o.title, comment: o.comment, command: o.command)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT NEXT").font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary)
            if let fit {
                button(fit, help: fit.command) { Task { await ws.send(fit.command) } }
            }
            ForEach(Array(ideas.enumerated()), id: \.offset) { _, option in
                button(option, help: option.command) { Task { await ws.pick(option) } }
            }
            if overLimit {
                button(ChatRouter.Option(title: ws.say("Raise the limit", "Поднять лимит"),
                                         comment: ws.say("Now at most \(Fmt.pct(ws.policy.maxRiskPct)) per trade, in Settings — at your own risk.",
                                                         "Сейчас не больше \(Fmt.pct(ws.policy.maxRiskPct)) на сделку, в настройках — на свой риск."), command: ""),
                       icon: "slider.horizontal.3", help: "Settings › General") { ws.openSettings(.general) }
            }
            Text(ws.say("Or write your own in the chat.", "Или напиши свой вариант в чат.")).font(.ui(10)).foregroundStyle(.secondary)
        }
        .frame(width: 470, alignment: .leading)
        .transition(.opacity)
    }

    private func button(_ o: ChatRouter.Option, icon: String? = nil, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { card(o, icon: icon) }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .modifier(HoverLift(radius: 18))
            .disabled(ws.busy)
            .help(help)
    }

    private func card(_ o: ChatRouter.Option, icon: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon ?? NextSteps.icon(o.command))
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.accentInk)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Brand.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(o.title).font(.ui(14, .heavy)).fixedSize(horizontal: false, vertical: true)
                    if o.recommended {
                        Text("Recommended").font(.ui(10, .bold)).foregroundStyle(Brand.onAccent).lineLimit(1).fixedSize()
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Brand.accent))
                    }
                }
                if !o.comment.isEmpty {
                    Text(o.comment).font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(o.recommended ? Brand.accent : Brand.cardBorder, lineWidth: o.recommended ? 2 : 1))
        .contentShape(Rectangle())
    }
}
