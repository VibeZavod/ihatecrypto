import Foundation
import WalletCore

/// Circle's CCTP v2 for USDC between EVM networks: USDC burned on one network and minted on another, no pool and no
/// bridge in the middle. With the Forwarding Service (the «cctp-forward» hook) Circle broadcasts the mint itself, so the
/// move is one signature and needs no gas on the destination. The fee comes out of the amount: the fast transfer's basis
/// points plus the forward's gas, both capped by `maxFee` (Circle's addresses and domains: developers.circle.com/cctp/
/// references/contract-addresses, the same on Ethereum, Arbitrum, Base and Polygon; checked on-chain 2026-10-06).
public enum CCTP {
    public static let tokenMessenger = "0x28b5a0e9c621a5badaa536219b3a228c8168cf5d"
    public static let messageTransmitter = "0x81d40f21f12a8f0e3252bccb954d722d4c464b64"
    public static let iris = "https://iris-api.circle.com"
    /// «cctp-forward», version 0, no more data: Circle mints on the destination.
    public static let forwardHook = Data(hex: "636374702d666f72776172640000000000000000000000000000000000000000")!
    /// Fast transfer: attested once the burn is in a block, seconds; 2000 would wait for finality, minutes.
    public static let fast: UInt32 = 1000

    /// CCTP's domain for an EVM chain id; nil where ihatecrypto doesn't use it.
    public static func domain(_ chainId: UInt64) -> UInt32? { [1: 0, 10: 2, 42161: 3, 8453: 6, 137: 7][chainId] }
    public static func chainName(_ domain: UInt32) -> String { [0: "Ethereum", 2: "Optimism", 3: "Arbitrum", 6: "Base", 7: "Polygon", 5: "Solana"][domain] ?? "domain \(domain)" }

    /// depositForBurnWithHook(amount, destinationDomain, mintRecipient, burnToken, destinationCaller 0, maxFee, fast, hook).
    public static func burn(units: UInt64, to domain: UInt32, recipient: String, usdc: String, maxFee: UInt64) throws -> Data {
        let head = try ABI.uint(units) + ABI.uint(UInt64(domain)) + ABI.address(recipient) + ABI.address(usdc) + Data(count: 32)
            + ABI.uint(maxFee) + ABI.uint(UInt64(fast)) + ABI.uint(8 * 32)
        return Data([0x77, 0x9b, 0x43, 0x2d]) + head + ABI.uint(UInt64(forwardHook.count)) + forwardHook
    }

    /// Who a burn's mint pays and on which domain, read from depositForBurn or depositForBurnWithHook; the recipient is
    /// nil when its bytes32 isn't an EVM address (a Solana account).
    public static func readBurn(_ data: Data) -> (recipient: String?, domain: UInt32, amount: Data)? {
        guard ["8e0250ee", "779b432d"].contains(data.prefix(4).hex) else { return nil }
        let args = Data(data.dropFirst(4))
        guard args.count >= 7 * 32, let domain = ABI.uint(in: args, word: 1), domain <= UInt64(UInt32.max) else { return nil }
        let word = args[64..<96]
        return (word.prefix(12).allSatisfy { $0 == 0 } ? "0x" + word.suffix(20).hex : nil, UInt32(domain), Data(args[0..<32]))
    }
}
