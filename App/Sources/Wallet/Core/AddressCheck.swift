import Foundation

/// Checks an address the user saves: the right shape for its network, the checksum when there is one, and known traps.
/// An address is never guessed or corrected — a wrong one is refused with the reason.
public enum AddressCheck {
    public enum Network: String, Codable, CaseIterable, Sendable {
        case solana, hyperliquid, ethereum, arbitrum, base, robinhood

        public var title: String {
            switch self {
            case .solana: "Solana"
            case .hyperliquid: "Hyperliquid"
            case .ethereum: "Ethereum"
            case .arbitrum: "Arbitrum"
            case .base: "Base"
            case .robinhood: "Robinhood Chain"
            }
        }
    }

    /// Addresses that swallow money sent the usual way.
    static let traps: [String: String] = [
        "0x2df1c51e09aecf9cacb7bc98cb1742757f163df7": "This is Hyperliquid’s old bridge (Bridge2): USDC sent here the wrong way is lost. Deposit through the Hyperliquid app instead.",
    ]

    /// nil when the address can be saved for this network; otherwise why not.
    public static func problem(_ address: String, network: Network) -> String? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return "Paste the address." }
        switch network {
        case .solana:
            guard (32...44).contains(a.count), let bytes = try? Base58.decode(a), bytes.count == 32 else {
                return "Not a Solana address: 32–44 letters and digits in base58."
            }
            return nil
        case .hyperliquid, .ethereum, .arbitrum, .base, .robinhood:
            guard a.wholeMatch(of: /0x[0-9a-fA-F]{40}/) != nil else { return "Not an \(network.title) address: 0x and 40 hex characters." }
            let hex = a.dropFirst(2)
            // Mixed case carries an EIP-55 checksum: one wrong character breaks it.
            if hex != hex.lowercased(), hex != hex.uppercased(), EVMAccount.checksum(a) != a {
                return "The checksum doesn’t match, so a character is wrong. Copy the address again from the source."
            }
            return traps[a.lowercased()]
        }
    }

    /// «7xKX 9fQm … 3kPq 2Wd1»: the start and the end in groups of four, the way to compare an address by eye.
    public static func ends(_ address: String) -> (start: String, end: String) {
        func groups(_ s: Substring) -> String { stride(from: 0, to: s.count, by: 4).map { i in String(s.dropFirst(i).prefix(4)) }.joined(separator: " ") }
        return (groups(address.prefix(8)), groups(address.suffix(8)))
    }
}
