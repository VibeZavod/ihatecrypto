import Foundation
import WalletCore

/// Tether's USDT0: USDT that crosses networks by itself as a LayerZero OFT — locked in the adapter on Ethereum, burned
/// and minted everywhere else, the same amount on the other side, no pool and no percent. What it costs is LayerZero's
/// message fee, sent with the call in the source network's coin (from Arbitrum on 2026-10-13: $0.0007 to Optimism,
/// $0.004 to HyperEVM, $0.02 to Polygon, $0.14 to Ethereum). It is slow where Tether waits for finality (`minutes`).
/// Addresses: docs.usdt0.to/technical-documentation/deployments; each OFT's token(), approvalRequired() and its peers()
/// on the other four read on-chain 2026-10-13.
public enum USDT0 {
    public struct Deployment: Sendable {
        /// LayerZero's endpoint id of the network.
        public let eid: UInt32
        /// The OFT `send` goes to: the adapter on Ethereum, which pulls USDT by an approve; elsewhere it burns by itself.
        public let oft: String
        public let token: String
        public let approves: Bool
        /// How long a transfer from here takes to land: the median of the last delivered ones on LayerZero Scan, 2026-10-13
        /// (Arbitrum 17–19 min, Ethereum 16–20, Polygon 1–1.5, Optimism 34, HyperEVM 11 h 48 min).
        public let minutes: Int
    }

    public static let deployments: [UInt64: Deployment] = [
        1: .init(eid: 30101, oft: "0x6c96de32cea08842dcc4058c14d3aaad7fa41dee", token: "0xdac17f958d2ee523a2206206994597c13d831ec7", approves: true, minutes: 20),
        42161: .init(eid: 30110, oft: "0x14e4a1b13bf7f943c8ff7c51fb60fa964a298d92", token: "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9", approves: false, minutes: 20),
        10: .init(eid: 30111, oft: "0xf03b4d9ac1d5d1e7c4cef54c2a313b9fe051a0ad", token: "0x01bff41798a0bcf287b996046ca68b395dbc1071", approves: false, minutes: 35),
        137: .init(eid: 30109, oft: "0x6ba10300f0dc58b7a1e4c0e41f5dabb7d7829e13", token: "0xc2132d05d31c914a87c6611c10748aeb04b58e8f", approves: false, minutes: 2),
        999: .init(eid: 30367, oft: "0x904861a24f30ec96ea7cfc3be9ea4b476d237e98", token: "0xb8ce59fc3717ada4c02eadf9682a9e934f625ebb", approves: false, minutes: 710),
    ]

    public static func on(_ chainId: UInt64) -> Deployment? { deployments[chainId] }

    /// The network an endpoint id names, for what the signer says it signs.
    public static func networkName(eid: UInt32) -> String {
        deployments.first { $0.value.eid == eid }.flatMap { EVMRPC.names[$0.key] } ?? "LayerZero's network \(eid)"
    }

    /// «≈ 20 min», «≈ 11 h 50 min».
    public static func wait(_ minutes: Int) -> String { minutes < 60 ? "≈ \(minutes) min" : "≈ \(minutes / 60) h \(minutes % 60) min" }

    /// SendParam(dstEid, to, amountLD, minAmountLD, extraOptions, composeMsg, oftCmd), the last three empty: the OFT's own
    /// enforced options deliver it, nothing is called on the other side, and no option pays anyone else there.
    static func param(to eid: UInt32, recipient: String, units: UInt64, min: UInt64) throws -> Data {
        ABI.uint(UInt64(eid)) + (try ABI.address(recipient)) + ABI.uint(units) + ABI.uint(min)
            + ABI.uint(7 * 32) + ABI.uint(8 * 32) + ABI.uint(9 * 32) + Data(count: 3 * 32)
    }

    /// quoteOFT(SendParam): the limits (words 0 and 1) and what is sent and received (words 3 and 4).
    public static func quoteOFT(to eid: UInt32, recipient: String, units: UInt64) throws -> Data {
        Data([0x0d, 0x35, 0xb4, 0x15]) + ABI.uint(32) + (try param(to: eid, recipient: recipient, units: units, min: 0))
    }

    /// quoteSend(SendParam, payInLzToken false): LayerZero's fee in the network's coin (word 0).
    public static func quoteSend(to eid: UInt32, recipient: String, units: UInt64, min: UInt64) throws -> Data {
        Data([0x3b, 0x6f, 0x74, 0x3b]) + ABI.uint(2 * 32) + ABI.uint(0) + (try param(to: eid, recipient: recipient, units: units, min: min))
    }

    /// send(SendParam, MessagingFee(nativeFee, 0), refundAddress): `fee` goes with the call as its value; what LayerZero
    /// doesn't take of it comes back to `refund`.
    public static func send(to eid: UInt32, recipient: String, units: UInt64, min: UInt64, fee: UInt64, refund: String) throws -> Data {
        Data([0xc7, 0xc7, 0xf5, 0xb3]) + ABI.uint(4 * 32) + ABI.uint(fee) + ABI.uint(0) + (try ABI.address(refund))
            + (try param(to: eid, recipient: recipient, units: units, min: min))
    }

    /// An OFT's send read back, wherever its encoder put the pieces: who gets the tokens on which network (nil: not an
    /// EVM address), how many, who gets the unused fee back, and whether it is `plain` — no options, no compose message,
    /// no OFT command, no fee in LayerZero's token. nil when it isn't a send or can't be read.
    public static func readSend(_ data: Data) -> (recipient: String?, eid: UInt32, amount: Data, plain: Bool, refund: String)? {
        guard data.prefix(4).hex == "c7c7f5b3" else { return nil }
        let args = Data(data.dropFirst(4))
        guard let at = ABI.uint(in: args, word: 0), at % 32 == 0, at <= UInt64(args.count),
              let refund = ABI.address(in: args, word: 3) else { return nil }
        let p = Data(args.dropFirst(Int(at)))
        guard p.count >= 7 * 32, let eid = ABI.uint(in: p, word: 0), eid <= UInt64(UInt32.max) else { return nil }
        func empty(_ word: Int) -> Bool? {
            guard let o = ABI.uint(in: p, word: word), o % 32 == 0, p.count >= 32, o <= UInt64(p.count - 32) else { return nil }
            return ABI.uint(in: Data(p.dropFirst(Int(o))), word: 0).map { $0 == 0 } ?? false
        }
        guard let options = empty(4), let compose = empty(5), let command = empty(6) else { return nil }
        let to = p.subdata(in: 32..<64)
        return (to.prefix(12).allSatisfy { $0 == 0 } ? "0x" + to.suffix(20).hex : nil, UInt32(eid), p.subdata(in: 64..<96),
                options && compose && command && ABI.uint(in: args, word: 2) == 0, refund)
    }
}
