import Foundation

/// NEAR Intents 1Click: cross-chain swaps and bridges as quote → deposit → status.
/// Works without a partner key (checked 2026-09-25), so there is no server of our own.
public enum OneClick {
    static let base = "https://1click.chaindefuser.com/v0"

    public enum Asset {
        public static let solanaSOL = "nep141:sol.omft.near"
        public static let solanaUSDC = "nep141:sol-5ce3bf3a31af18be40ba30f721101b4341690186.omft.near"
        /// Lands on the HyperCore spot balance (hip1 token), not directly in perp margin.
        public static let hyperCoreUSDC = "1cs_v1:hypercore:hip1:0x6d1e7cde53ba9467b783cb7c530ce054"
        /// NEAR on the NEAR chain (listed as wNEAR, 24 decimals).
        public static let near = "nep141:wrap.near"
        /// Circle's USDC on the EVM networks 1Click quotes it from (/v0/tokens; a dry quote into NEAR answered for Base,
        /// Arbitrum and Ethereum on 2026-10-05; Polygon's «Quoting for this pair is not available»), by ihatecrypto's key.
        public static func usdc(onEVM key: String) -> String? {
            switch key {
            case "base": "nep141:base-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913.omft.near"
            case "arbitrum": "nep141:arb-0xaf88d065e77c8cc2239327c5edb3a432268e5831.omft.near"
            case "ethereum": "nep141:eth-0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48.omft.near"
            default: nil
            }
        }
    }

    public struct Quote: Sendable {
        public let depositAddress: String?
        public let amountIn: String
        public let amountInFormatted: String
        /// Present for EXACT_OUTPUT: the input without the slippage reserve.
        public let minAmountIn: String?
        public let amountOutFormatted: String
        public let minAmountOut: String?
        public let deadline: String?
        public let timeEstimate: Int?
    }

    /// `dry: false` issues a deposit address. `refundTo` and `recipient` must be the user's own addresses then.
    public static func quote(
        dry: Bool, exactOutput: Bool = false, origin: String, destination: String, amount: String,
        refundTo: String, recipient: String, slippageBps: Int = 100
    ) async throws -> Quote {
        let deadline = ISO8601DateFormatter().string(from: Date().addingTimeInterval(30 * 60))
        let data = try await post("/quote", [
            "dry": dry, "swapType": exactOutput ? "EXACT_OUTPUT" : "EXACT_INPUT", "slippageTolerance": slippageBps,
            "originAsset": origin, "depositType": "ORIGIN_CHAIN", "destinationAsset": destination, "amount": amount,
            "refundTo": refundTo, "refundType": "ORIGIN_CHAIN", "recipient": recipient, "recipientType": "DESTINATION_CHAIN",
            "deadline": deadline, "quoteWaitingTimeMs": 3000,
        ])
        guard let q = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["quote"] as? [String: Any],
              let amountIn = q["amountIn"] as? String else { throw OneClickError(data) }
        return Quote(
            depositAddress: q["depositAddress"] as? String, amountIn: amountIn,
            amountInFormatted: q["amountInFormatted"] as? String ?? amountIn, minAmountIn: q["minAmountIn"] as? String,
            amountOutFormatted: q["amountOutFormatted"] as? String ?? "?", minAmountOut: q["minAmountOut"] as? String,
            deadline: q["deadline"] as? String, timeEstimate: (q["timeEstimate"] as? NSNumber)?.intValue
        )
    }

    /// What 1Click has bound to a deposit address: recipient, refundTo, originAsset, destinationAsset, amount.
    /// Read back from 1Click itself, so an address slipped in from elsewhere does not match.
    public static func boundRequest(depositAddress: String) async throws -> [String: String] {
        let url = URL(string: "\(base)/status?depositAddress=\(depositAddress)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let quote = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["quoteResponse"] as? [String: Any],
              let request = quote["quoteRequest"] as? [String: Any] else { throw OneClickError(data) }
        var out: [String: String] = [:]
        for key in ["recipient", "refundTo", "originAsset", "destinationAsset", "amount"] { out[key] = request[key] as? String }
        out["depositAddress"] = (quote["quote"] as? [String: Any])?["depositAddress"] as? String
        return out
    }

    /// Optional: tells 1Click about the deposit so it does not wait to notice it.
    public static func submitDeposit(txHash: String, depositAddress: String) async throws {
        _ = try await post("/deposit/submit", ["txHash": txHash, "depositAddress": depositAddress])
    }

    public struct Status: Sendable {
        public let status: String
        public let amountOutFormatted: String?
        public let refundedFormatted: String?
        public let destinationTxs: [String]
        public var isFinal: Bool { ["SUCCESS", "REFUNDED", "FAILED"].contains(status) }
    }

    public static func status(depositAddress: String) async throws -> Status {
        let url = URL(string: "\(base)/status?depositAddress=\(depositAddress)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], let status = j["status"] as? String else {
            throw OneClickError(data)
        }
        let details = j["swapDetails"] as? [String: Any]
        let txs = (details?["destinationChainTxHashes"] as? [[String: Any]] ?? []).compactMap { $0["hash"] as? String }
        return Status(status: status, amountOutFormatted: details?["amountOutFormatted"] as? String,
                      refundedFormatted: details?["refundedAmountFormatted"] as? String, destinationTxs: txs)
    }

    static func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: base + path)!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { throw OneClickError(data) }
        return data
    }
}

public struct OneClickError: LocalizedError {
    public let message: String
    init(_ data: Data) { message = String(decoding: data.prefix(300), as: UTF8.self) }
    public var errorDescription: String? { "1Click: \(message)" }
}
