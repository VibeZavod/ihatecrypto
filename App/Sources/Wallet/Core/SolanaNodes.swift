import Foundation

/// The Solana nodes ihatecrypto asks, in order: the user's own (Settings › General › Solana node; its URL, key and all,
/// lives in the Keychain) first when set, then Solana's public node — rate-limited, but it answers every call. Read at
/// each call, so a node set in Settings counts at once.
public enum SolanaNodes {
    public static let publicNode = URL(string: "https://api.mainnet-beta.solana.com")!
    /// The genesis hash of Solana mainnet: a node that answers another is another network.
    public static let mainnetGenesis = "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var own: URL?

    public static var custom: URL? {
        get { lock.withLock { own } }
        set { lock.withLock { own = newValue } }
    }

    public static var urls: [URL] { [custom, publicNode].compactMap { $0 } }
}
