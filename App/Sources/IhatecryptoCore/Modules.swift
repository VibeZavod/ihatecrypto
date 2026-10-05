import Foundation

/// What the assistant may use: networks, kinds of moves and protocols, each switched in Settings › Modules (networks
/// also from the chat). A protocol works only while it, its kind and every network it needs are on. Off means the
/// assistant never plans a move through it; money already there still shows.
public enum ModuleNetwork: String, CaseIterable, Sendable {
    case solana, hyperliquid, base, near, arbitrum, robinhood, polygon, ethereum, tempo

    public var name: String {
        switch self {
        case .solana: "Solana"
        case .hyperliquid: "Hyperliquid"
        case .base: "Base"
        case .near: "NEAR"
        case .arbitrum: "Arbitrum"
        case .robinhood: "Robinhood"
        case .polygon: "Polygon"
        case .ethereum: "Ethereum"
        case .tempo: "Tempo"
        }
    }

    /// A place as commands and the address book name it: «base», «arbitrum», «robinhood», «solana», «hyperliquid», «near», «tempo».
    public init?(place: String) {
        let p = place.lowercased()
        guard let n = Self.allCases.first(where: { p.hasPrefix($0.rawValue) }) ?? (p.hasPrefix("hl") ? .hyperliquid : nil) else { return nil }
        self = n
    }

    /// The line under the network in the chat's menu: what the assistant does there.
    public var uses: String {
        switch self {
        case .solana: "Jupiter swaps · Jupiter Lend · Kamino · JitoSOL"
        case .hyperliquid: "Perps · oil and stocks (xyz) · HLP vault"
        case .base: "Aave · Morpho · USDC"
        case .near: "NEAR Intents swaps · 1Click"
        case .arbitrum: "Aave · Morpho · USDC in and out"
        case .robinhood: "Stock tokens · USDG · Uniswap"
        case .polygon: "Aave · USDC"
        case .ethereum: "Aave · Morpho · mainnet gas varies"
        case .tempo: "USDC transfers · pay for services (MPP) · fees in USDC"
        }
    }

    /// The logo's name for TokenLogo.
    public var logo: String {
        switch self {
        case .solana: "sol"
        case .hyperliquid: "hype"
        case .base: "base"
        case .near: "near"
        case .arbitrum: "arb"
        case .robinhood: "robinhood"
        case .polygon: "pol"
        case .ethereum: "eth"
        case .tempo: "tempo"
        }
    }
}

public enum ModuleKind: String, CaseIterable, Sendable {
    case swaps, earn, perps, stocks, bridges, payments

    public var name: String {
        switch self {
        case .swaps: "Swaps"
        case .earn: "Earn · DeFi"
        case .perps: "Perps"
        case .stocks: "Stocks & oil"
        case .bridges: "Bridges"
        case .payments: "Payments"
        }
    }

    public var line: String {
        switch self {
        case .swaps: "Trade one token for another"
        case .earn: "Lend and stake idle money"
        case .perps: "Long or short with leverage"
        case .stocks: "Commodities and tokenized shares"
        case .bridges: "Move money between networks"
        case .payments: "Pay for services per request"
        }
    }
}

public enum ModuleProtocol: String, CaseIterable, Sendable {
    case jupiter, jupiterDCA, uniswap, jupiterLend, kamino, jitoSOL, aave, morpho, hlp, hlPerps, xyz, robinhoodStocks, relay, oneClick, mpp

    public var kind: ModuleKind {
        switch self {
        case .jupiter, .jupiterDCA, .uniswap: .swaps
        case .jupiterLend, .kamino, .jitoSOL, .aave, .morpho, .hlp: .earn
        case .hlPerps: .perps
        case .xyz, .robinhoodStocks: .stocks
        case .relay, .oneClick: .bridges
        case .mpp: .payments
        }
    }

    /// The networks it can't work without. Relay's other end is checked per move (`Modules.refusal(_:via:)`).
    public var networks: [ModuleNetwork] {
        switch self {
        case .jupiter, .jupiterDCA, .jupiterLend, .kamino, .jitoSOL, .relay: [.solana]
        // Uniswap works on Robinhood Chain, Base and Arbitrum: the network is checked per move.
        case .uniswap: []
        case .robinhoodStocks: [.robinhood]
        // Aave and Morpho work on several networks: the one a move uses is checked per move.
        case .aave, .morpho: []
        case .hlp, .hlPerps, .xyz: [.hyperliquid]
        case .oneClick: [.near]
        case .mpp: [.tempo]
        }
    }

    public var name: String {
        switch self {
        case .jupiter: "Jupiter"
        case .jupiterDCA: "Jupiter DCA"
        case .uniswap: "Uniswap"
        case .jupiterLend: "Jupiter Lend"
        case .kamino: "Kamino"
        case .jitoSOL: "JitoSOL staking"
        case .aave: "Aave v3"
        case .morpho: "Morpho"
        case .hlp: "HLP vault"
        case .hlPerps: "Hyperliquid"
        case .xyz: "Hyperliquid xyz"
        case .robinhoodStocks: "Robinhood Stock Tokens"
        case .relay: "Relay"
        case .oneClick: "NEAR Intents · 1Click"
        case .mpp: "MPP · x402"
        }
    }

    /// The line under the name in Settings.
    public var place: String {
        switch self {
        case .hlPerps: "BTC, ETH, SOL and more"
        case .jupiterDCA: "Solana · on-chain buys over time, from 100 USDC"
        case .xyz: "Oil, metals, stocks"
        case .relay: "Solana ⇄ Base · Arbitrum · Polygon · Ethereum · Robinhood · Tempo"
        case .uniswap: "Robinhood · Base · Arbitrum"
        case .aave: "Base · Arbitrum · Polygon · Ethereum"
        case .morpho: "Base · Arbitrum · Ethereum"
        case .oneClick: "NEAR ⇄ Solana"
        case .mpp: "APIs, email, calls, letters · USDC on Tempo"
        default: networks.map(\.name).joined(separator: " · ")
        }
    }

    /// The logo in Logos/.
    public var logo: String {
        switch self {
        case .jupiter, .jupiterDCA, .jupiterLend: "jup"
        case .uniswap: "uni"
        case .kamino: "kamino"
        case .jitoSOL: "jitosol"
        case .aave: "aave"
        case .morpho: "morpho"
        case .hlp, .hlPerps, .xyz: "hype"
        case .robinhoodStocks: "robinhood"
        case .relay: "relay"
        case .oneClick: "near"
        case .mpp: "tempo"
        }
    }

    /// A module added in a later version starts switched off: the user turns it on when they want it.
    public var onByDefault: Bool { true }
}

/// The switches as the user left them; anything never touched keeps its default.
public struct Modules: Equatable, Sendable {
    /// id → on, for the switches the user touched. Ids: "network.base", "kind.perps", "protocol.kamino".
    public var choices: [String: Bool]

    public init(choices: [String: Bool] = [:]) { self.choices = choices }

    /// «protocol.kamino=0,network.arbitrum=1»: the form kept in UserDefaults under `Modules.key`.
    public init(stored: String) {
        var c: [String: Bool] = [:]
        for pair in stored.split(separator: ",") {
            let kv = pair.split(separator: "=")
            if kv.count == 2 { c[String(kv[0])] = kv[1] == "1" }
        }
        choices = c
    }

    public var stored: String { choices.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value ? 1 : 0)" }.joined(separator: ",") }

    public static let key = "modules"
    /// What's switched on right now, read from UserDefaults: cheap, and never stale after a switch in Settings.
    public static var current: Modules { Modules(stored: UserDefaults.standard.string(forKey: key) ?? "") }

    public func isOn(_ n: ModuleNetwork) -> Bool { choices["network.\(n.rawValue)"] ?? true }
    public func isOn(_ k: ModuleKind) -> Bool { choices["kind.\(k.rawValue)"] ?? true }
    /// The protocol's own switch, whatever its kind and networks say.
    public func isOn(_ p: ModuleProtocol) -> Bool { choices["protocol.\(p.rawValue)"] ?? p.onByDefault }

    public mutating func set(_ n: ModuleNetwork, _ on: Bool) { choices["network.\(n.rawValue)"] = on }
    public mutating func set(_ k: ModuleKind, _ on: Bool) { choices["kind.\(k.rawValue)"] = on }
    public mutating func set(_ p: ModuleProtocol, _ on: Bool) { choices["protocol.\(p.rawValue)"] = on }

    public func allows(_ p: ModuleProtocol) -> Bool { refusal(p) == nil }

    /// Why a move through `p` (and across `via`, e.g. the other end of a bridge) can't be planned; nil when it can.
    public func refusal(_ p: ModuleProtocol, via: [ModuleNetwork] = [], ru: Bool = false) -> String? {
        if !isOn(p) { return ru ? "\(p.name) выключен в Settings › Modules." : "\(p.name) is off in Settings › Modules." }
        if !isOn(p.kind) {
            return ru ? "\(p.kind.name) выключены в Settings › Modules, а с ними и \(p.name)."
                : "\(p.kind.name) is off in Settings › Modules, so \(p.name) is too."
        }
        if let n = (p.networks + via).first(where: { !isOn($0) }) { return refusal(network: n, ru: ru) }
        return nil
    }

    /// A move on a network with no protocol of its own (a plain transfer).
    public func refusal(network n: ModuleNetwork, ru: Bool = false) -> String? {
        isOn(n) ? nil : ru ? "\(n.name) выключена в Settings › Modules." : "\(n.name) is off in Settings › Modules."
    }

    /// Why this wallet command can't be planned with the switches as they are; nil when it can. Transfers to an
    /// address-book entry are checked by the entry's network, where it's known.
    public func refusal(_ command: WalletCommand, ru: Bool = false) -> String? {
        func r(_ p: ModuleProtocol, via: [ModuleNetwork] = []) -> String? { refusal(p, via: via, ru: ru) }
        switch command {
        case .buy, .sell, .schedule: return r(.jupiter)
        case .jupiterDCA, .jupiterDCACancel, .jupiterDCAOrders: return r(.jupiterDCA)
        case .stake, .unstake: return r(.jitoSOL)
        case .lendDeposit, .lendWithdraw: return r(.jupiterLend)
        case .kamino: return r(.kamino)
        case .hlp: return r(.hlp)
        case .aave(_, _, let net): return r(.aave) ?? r(.relay, via: ModuleNetwork(place: net).map { [$0] } ?? [])
        case .morpho(_, _, let net): return r(.morpho) ?? r(.relay, via: ModuleNetwork(place: net).map { [$0] } ?? [])
        case .withdrawToSolana: return r(.relay, via: [.hyperliquid])
        case .baseToSolana: return r(.relay, via: [.base])
        case .arbitrumToSolana: return r(.relay, via: [.arbitrum])
        case .evmToSolana(let net, _): return r(.relay, via: ModuleNetwork(place: net).map { [$0] } ?? [])
        case .robinhoodToSolana: return r(.relay, via: [.robinhood])
        case .solanaTo(let place, _): return r(.relay, via: ModuleNetwork(place: place).map { [$0] } ?? [])
        case .buyStock(let symbol, _): return (symbol.hasPrefix("0x") ? r(.uniswap, via: [.robinhood]) : r(.robinhoodStocks)) ?? r(.relay, via: [.robinhood])
        case .sellStock(let symbol, _): return symbol.hasPrefix("0x") ? r(.uniswap, via: [.robinhood]) : r(.robinhoodStocks)
        // Base and Arbitrum: Relay is needed either way (its swap, or its bridge before Uniswap); with Uniswap off only
        // Relay's swap is compared.
        case .buyOn(let place, _, _, _), .sellOn(let place, _, _, _):
            return isOn(.swaps) ? r(.relay, via: ModuleNetwork(place: place).map { [$0] } ?? [])
                : ru ? "\(ModuleKind.swaps.name) выключены в Settings › Modules." : "\(ModuleKind.swaps.name) is off in Settings › Modules."
        // One token for another on the network itself: Uniswap there, no bridge.
        case .swapOn(let place, _, _, _):
            return isOn(.swaps) ? r(.uniswap, via: ModuleNetwork(place: place).map { [$0] } ?? [])
                : ru ? "\(ModuleKind.swaps.name) выключены в Settings › Modules." : "\(ModuleKind.swaps.name) is off in Settings › Modules."
        case .buyNear, .sellNear: return r(.oneClick)
        case .sendNear, .closeNear: return refusal(network: .near, ru: ru)
        case .sendSol: return refusal(network: .solana, ru: ru)
        case .sendToken(_, _, _, let net): return net.flatMap(ModuleNetwork.init(place:)).flatMap { refusal(network: $0, ru: ru) }
        case .allocate, .rebalance, .claimRewards, .sweepRewards:
            // Each vault is checked by the planner; with the whole kind off there's nothing to plan.
            return isOn(.earn) ? nil : ru ? "\(ModuleKind.earn.name) выключены в Settings › Modules." : "\(ModuleKind.earn.name) is off in Settings › Modules."
        case .pay: return r(.mpp)
        case .gas(let place, _): return r(.relay, via: ModuleNetwork(place: place).map { [$0] } ?? [])
        case .bridge(let from, let to, _): return r(.relay, via: [from, to].compactMap(ModuleNetwork.init(place:)))
        case .sendTo, .yields, .receive, .stopSchedules: return nil
        }
    }

    /// A vault by the name the yield planners give it («Kamino Lend», «Aave · Arbitrum»), with the bridge it needs.
    /// A name it doesn't know is refused: nothing goes to a place no switch covers.
    public func refusal(vault name: String) -> String? {
        switch name {
        case "Jupiter Lend": return refusal(.jupiterLend)
        case "Kamino Lend": return refusal(.kamino)
        case "JitoSOL staking": return refusal(.jitoSOL)
        case "HLP (Hyperliquid)": return refusal(.hlp) ?? refusal(.relay, via: [.hyperliquid])
        default:
            // «Aave · Polygon», «Morpho · Ethereum»: the protocol, then its network and the bridge there.
            let parts = name.components(separatedBy: " · ")
            guard parts.count == 2, let p = ["Aave": ModuleProtocol.aave, "Morpho": .morpho][parts[0]],
                  let n = ModuleNetwork.allCases.first(where: { $0.name == parts[1] }) else { return "\(name) isn't a place ihatecrypto knows." }
            return refusal(p) ?? refusal(.relay, via: [n])
        }
    }

    /// A Hyperliquid trade: perps, or an xyz market (oil, stocks); `bridges` when USDC comes over from Solana first.
    public func refusal(trade xyz: Bool, bridges: Bool, ru: Bool = false) -> String? {
        refusal(xyz ? .xyz : .hlPerps, ru: ru) ?? (bridges ? refusal(.relay, via: [.hyperliquid], ru: ru) : nil)
    }

    /// For the model's brief: what it must not offer. Empty when everything is on.
    public var offSummary: String {
        let off = ModuleNetwork.allCases.filter { !isOn($0) }.map(\.name)
            + ModuleKind.allCases.filter { !isOn($0) }.map(\.name)
            + ModuleProtocol.allCases.filter { !isOn($0) }.map(\.name)
        return off.joined(separator: ", ")
    }
}
