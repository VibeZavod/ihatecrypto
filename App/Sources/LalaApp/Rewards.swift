import EVMChain
import Foundation
import LalaCore
import TradeExecution
import WalletCore

/// «claim rewards»: what Merkl owes this wallet (Morpho's, Aave's and other protocols' rewards) is asked for first; the
/// card shows each reward and where it lands, and Confirm claims it on each chain (Rewards.swift in TradeExecution).
extension Workspace {
    func prepareClaim(_ command: WalletCommand, note: String? = nil) async {
        guard let me = signerWallet?.evm ?? (isEVMAddress(hlAddress) ? hlAddress : nil) else {
            reply(say("This wallet has no EVM address to claim rewards to.", "У этого кошелька нет EVM-адреса, куда забрать награды."), note: note)
            return
        }
        agentStep = say("Asking Merkl what this wallet is owed", "Спрашиваю Merkl, что причитается кошельку")
        do {
            let owed = try await Merkl.rewards(user: me)
            guard !owed.isEmpty else {
                reply(say("Nothing to claim: Merkl owes \(AddressCheck.ends(me).start) … \(AddressCheck.ends(me).end) nothing on Base, Arbitrum, Ethereum or Polygon right now. Rewards show up there after a few hours in a vault that pays them (Morpho's, some of Aave's).",
                          "Забирать нечего: Merkl ничего не должен \(AddressCheck.ends(me).start) … \(AddressCheck.ends(me).end) ни на Base, ни на Arbitrum, Ethereum или Polygon. Награды появляются через несколько часов в хранилище, которое их платит (у Morpho, у части Aave)."), note: note)
                return
            }
            rewards = owed
            pendingAction = .wallet(command)
            let worth = owed.compactMap(\.worthUSD).reduce(0, +)
            reply(say("Merkl owes this wallet \(owed.map(Self.shown).joined(separator: ", "))\(worth > 0 ? ", ≈ \(Fmt.usd(worth))" : ""). The card is on the canvas — Confirm claims it.",
                      "Merkl должен кошельку \(owed.map(Self.shown).joined(separator: ", "))\(worth > 0 ? ", ≈ \(Fmt.usd(worth))" : ""). Карточка на холсте — Confirm заберёт."), note: note)
        } catch {
            reply(say("Couldn't ask Merkl: ", "Не достучался до Merkl: ") + error.localizedDescription, note: note)
        }
    }

    private static func shown(_ r: Merkl.Reward) -> String { "\(Fmt.num(r.claimable, maxFraction: 6)) \(r.symbol)" }

    /// The card: each reward to claim, gas that comes along where there's none, and the wallet it lands in.
    func claimRoute() -> MoveRoute? {
        guard let owed = rewards, !owed.isEmpty else { return nil }
        let chains = Merkl.chains.filter { c in owed.contains { $0.chainId == c } }
        let names = chains.compactMap { EVMNetwork.of(chainId: $0)?.name }
        var steps: [ActivityBubble] = []
        for chain in chains {
            let net = EVMNetwork.of(chainId: chain)
            let name = net?.name ?? "chain \(chain)"
            let fill = RouteFill.place(name), logo = ModuleNetwork(place: net?.key ?? "")?.logo ?? "eth"
            for r in owed where r.chainId == chain {
                steps.append(ActivityBubble(kind: "step", label: "CLAIM · MERKL ON \(name.uppercased())", title: Self.shown(r),
                                            lines: (r.worthUSD.map { ["worth\t≈ \(Fmt.usd($0))"] } ?? []) + ["from Merkl's distributor"],
                                            logo: TokenLogo.name(forAsset: r.symbol) ?? logo, fill: fill))
            }
            steps.append(ActivityBubble(kind: "step", label: "TO · \(name.uppercased())", title: "this wallet",
                                        lines: ["the rewards stay there as tokens"], logo: logo, fill: fill))
        }
        return MoveRoute(title: "Claim rewards · \(owed.map(Self.shown).joined(separator: ", "))",
                         footer: "One \(names.joined(separator: ", ")) transaction a chain: Merkl's distributor pays each reward to this wallet — the signer refuses a claim that pays anyone else. "
                            + "The proofs are asked for again right before signing; gas missing there comes from Solana over Relay. Say “do it” or press Confirm.",
                         steps: steps)
    }
}
