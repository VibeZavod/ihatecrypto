import Foundation
import WalletCore

/// The user's own node per EVM network (Settings › General › Your own nodes; the URL, key and all, lives in the Keychain):
/// asked before the app's built-in ones, which take over when it fails or lacks a call. Read at each call.
public enum EVMNodes {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var own: [UInt64: URL] = [:]

    public static func custom(_ chainId: UInt64) -> URL? { lock.withLock { own[chainId] } }
    public static func set(_ url: URL?, for chainId: UInt64) { lock.withLock { own[chainId] = url } }

    /// The network's dollar, approved in the check's dry-run batch.
    static func dollar(_ chainId: UInt64) -> String? {
        [8453: EVMRPC.baseUSDC, 42161: EVMRPC.arbitrumUSDC, 1: EVMRPC.ethereumUSDC, 137: EVMRPC.polygonUSDC, 4663: EVMRPC.robinhoodUSDG][chainId]
    }

    /// Why `url` can't be the wallet's node on `chainId`, or nil: https only; that very network (eth_chainId); fees,
    /// nonces and receipts answered; and a state override really applied to a dry run — what an EIP-7702 batch's estimate
    /// stands on: an approve run through the batch account costs ≈ 60,000 gas, the same calldata to a plain address ≈ 26,000,
    /// and a node that drops the override (as drpc drops an authorizationList) would leave a batch short of gas.
    public static func problem(with url: URL, chainId: UInt64) async -> String? {
        guard url.scheme == "https", url.host != nil else { return "A node's address starts with https://." }
        let rpc = EVMRPC(url: url, chainId: chainId)
        let me = "0x00000000000000000000000000000000000f0a11"
        do {
            let id = try await rpc.quantity("eth_chainId", [])
            guard id == chainId else { return "That node is on network \(id), not \(EVMRPC.names[chainId] ?? "\(chainId)") (\(chainId))." }
            _ = try await rpc.fees()
            _ = try await rpc.nonce(me)
            guard let block = try await rpc.call("eth_getBlockByNumber", ["latest", false]) as? [String: Any] else { return "The node didn't give its latest block." }
            if let tx = (block["transactions"] as? [String])?.first {
                guard try await rpc.call("eth_getTransactionReceipt", [tx]) is [String: Any] else { return "The node doesn't give transaction receipts." }
            }
            if let dollar = dollar(chainId) {
                let batch = try Batch7702.executeBatch([.init(to: dollar, data: try ERC20.approve(spender: me, units: 1))])
                let gas = try await rpc.estimateGas(from: me, to: me, value: 0, data: batch, runningCodeOf: Batch7702.delegate)
                guard gas > 40_000 else { return "The node ignores state overrides in a dry run (\(gas) gas): batched moves would go out short of gas." }
            }
            return nil
        } catch {
            let why = error.localizedDescription
            // Alchemy answers a bad key «Must be authenticated!», others «Unauthorized» or «invalid API key».
            if why.contains("HTTP 401") || why.contains("HTTP 403") || ["unauthorized", "api key", "authenticat", "forbidden"].contains(where: why.lowercased().contains) {
                return "The node turned the key away: copy the whole address again, key included — or this plan doesn't serve these calls."
            }
            return "The node didn't answer: \(why)"
        }
    }
}
