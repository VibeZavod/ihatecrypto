import EVMChain
import Foundation
import IhatecryptoCore

/// A USDC place on an EVM network, for the planners: its rate, what is in it, and what a round trip there costs.
public struct EVMPlace: Sendable {
    /// «Aave · Arbitrum», «Morpho · Ethereum».
    public let name: String
    /// «Aave» or «Morpho»: the allocation limit is counted per protocol.
    public let protocolName: String
    public let apy: Decimal
    /// USDC in it now.
    public let supplied: Decimal
    /// Getting there and back: Relay both ways, the calls' gas at today's fee, and the delivery of a gas top-up when the
    /// network has none yet.
    public let roundTripUSD: Decimal

    /// Why a slice worth `yearly` in interest isn't worth the trip, or nil: the trip must cost less than half a year of it.
    public func tooCostly(yearly: Decimal) -> String? {
        roundTripUSD > yearly / 2
            ? "the bridges and gas there and back (≈ \(Fmt.usd(roundTripUSD))) cost more than half a year of this slice's interest (≈ \(Fmt.usd(yearly)) a year)"
            : nil
    }
}

extension Executor {
    /// Gas a round trip takes: Aave's approve and supply, then its withdraw and Relay's approve and deposit back.
    /// A Morpho vault call is ≈ 450k gas each way.
    static let aaveTripGas: UInt64 = 250_000 + 330_000
    static let morphoTripGas: UInt64 = 500_000 + 580_000

    /// Relay's fee each way: ≈ $0.03 to and from the L2s (measured on Base), more for Ethereum where the solver pays
    /// mainnet gas. The executors cap every bridge's cost on their own before signing.
    // ponytail: fixed estimates; quote Relay per slice if the planners need them exact.
    static func bridgeUSD(_ net: EVMNetwork) -> Decimal { net.key == "ethereum" ? Decimal(string: "0.5")! : Decimal(string: "0.03")! }

    /// Every Aave market and Morpho vault ihatecrypto knows, read at once. One whose rate, balance or gas can't be read is
    /// left out: nothing is planned into a place that wasn't checked.
    public func evmPlaces() async -> [EVMPlace] {
        let marks = (try? await Hyperliquid.markets()) ?? [:]
        let prices = ["ETH": marks["ETH"]?.markPx, "POL": marks["POL"]?.markPx]
        let me = wallet.evm
        return await withTaskGroup(of: EVMPlace?.self) { group in
            for m in AaveV3.markets {
                group.addTask {
                    guard let net = EVMNetwork.named(m.chain), let apy = try? await AaveV3.verify(m),
                          let supplied = try? await m.rpc.tokenBalance(m.aUSDC, owner: me),
                          let trip = await Self.roundTrip(net, owner: me, gas: Self.aaveTripGas, price: prices[net.gasCoin] ?? nil) else { return nil }
                    return EVMPlace(name: m.place, protocolName: "Aave", apy: apy, supplied: Decimal(supplied) / 1_000_000, roundTripUSD: trip)
                }
            }
            for v in MorphoVault.vaults {
                group.addTask {
                    guard let net = EVMNetwork.named(v.chain), (try? await MorphoVault.verify(v)) != nil, let apy = await MorphoRates.netAPY(v),
                          let supplied = try? await MorphoVault.value(me, v),
                          let trip = await Self.roundTrip(net, owner: me, gas: Self.morphoTripGas, price: prices[net.gasCoin] ?? nil) else { return nil }
                    return EVMPlace(name: v.place, protocolName: "Morpho", apy: apy, supplied: Decimal(supplied) / 1_000_000, roundTripUSD: trip)
                }
            }
            var out: [EVMPlace] = []
            for await p in group { if let p { out.append(p) } }
            return out.sorted { $0.name < $1.name }
        }
    }

    /// USDC (USDG on Robinhood Chain) lying unused on each EVM network Settings › Modules allows, from half a dollar
    /// (a bridge's minimum); Ethereum last, so the cheaper networks are pulled from first. A network that can't be read
    /// counts as empty.
    public func idleUSDC() async -> [(net: EVMNetwork, usdc: Decimal)] {
        let me = wallet.evm
        guard Modules.current.isOn(ModuleKind.bridges) else { return [] }
        var out: [(net: EVMNetwork, usdc: Decimal)] = []
        for net in EVMNetwork.searched {
            guard let have = try? await net.usdcBalance(me), have > net.feeReserve else { continue }
            let usdc = Decimal(have - net.feeReserve) / 1_000_000
            if usdc >= Decimal(string: "0.5")! { out.append((net, usdc)) }
        }
        return out
    }

    /// What a round trip to `net` costs today, in USD; nil when the fee or the gas coin's price can't be read.
    static func roundTrip(_ net: EVMNetwork, owner: String, gas units: UInt64, price: Decimal?) async -> Decimal? {
        guard let price, price > 0, let (tip, maxFee) = try? await net.rpc.fees(), let have = try? await net.rpc.balance(owner) else { return nil }
        // fees() doubles the base fee for headroom; what a call pays today is the base fee plus the tip.
        let gasPrice = (maxFee - tip) / 2 + tip
        let gasUSD = Decimal(units) * Decimal(gasPrice) / Decimal(sign: .plus, exponent: 18, significand: 1) * price
        // Without gas there yet, the first bridge carries a top-up: its delivery costs ≈ $0.08 on top (measured on Base).
        let topup = have < net.gasFloor ? Decimal(string: "0.08")! : 0
        return 2 * bridgeUSD(net) + gasUSD + topup
    }
}
