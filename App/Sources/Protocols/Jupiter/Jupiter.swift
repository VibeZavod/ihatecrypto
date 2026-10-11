import Foundation
import WalletCore

/// Swaps inside Solana through Jupiter's free API. Jupiter builds the transaction; the wallet only checks
/// that it is the fee payer and signs (`SolanaTransaction.sign`).
public enum Jupiter {
    static let base = "https://lite-api.jup.ag/swap/v1"
    public static let solMint = "So11111111111111111111111111111111111111112"
    public static let usdcMint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

    public struct Quote: Sendable {
        /// The quote exactly as Jupiter returned it; /swap needs it back unchanged.
        public let raw: Data
        public let inAmount: UInt64
        public let outAmount: UInt64
        /// Least output after slippage: the floor the user agrees to.
        public let minOut: UInt64
        public let route: String
        /// The route's pools by Jupiter's label, e.g. ["HumidiFi", "Hadron"]: what `excludeDexes` takes.
        public let dexes: [String]
    }

    /// `excludeDexes`: labels Jupiter must route around (a route that failed before signing).
    public static func quote(input: String, output: String, amount: UInt64, slippageBps: Int = 50, excludeDexes: [String] = []) async throws -> Quote {
        var url = URL(string: "\(base)/quote?inputMint=\(input)&outputMint=\(output)&amount=\(amount)&slippageBps=\(slippageBps)")!
        if !excludeDexes.isEmpty { url.append(queryItems: [URLQueryItem(name: "excludeDexes", value: excludeDexes.joined(separator: ","))]) }
        let ask = url
        // A throttle or a gateway's 5xx is asked again (RPCRetry): one 503 here stopped a chain of moves at its swap.
        return try await RPCRetry.run({ try await URLSession.shared.data(from: ask) }) { data, status in
            guard status == 200,
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let inAmount = (j["inAmount"] as? String).flatMap(UInt64.init),
                  let outAmount = (j["outAmount"] as? String).flatMap(UInt64.init),
                  let minOut = (j["otherAmountThreshold"] as? String).flatMap(UInt64.init) else {
                throw RPCRetry.Again(status == 429 || status >= 500, JupiterError(data, status))
            }
            let dexes = (j["routePlan"] as? [[String: Any]] ?? []).compactMap { ($0["swapInfo"] as? [String: Any])?["label"] as? String }
            return Quote(raw: data, inAmount: inAmount, outAmount: outAmount, minOut: minOut, route: dexes.joined(separator: " → "), dexes: dexes)
        }
    }

    /// Unsigned versioned transaction for `quote`, paid by `user`.
    public static func swapTransaction(_ quote: Quote, user: String) async throws -> (wire: Data, lastValidBlockHeight: UInt64) {
        let quoteObject = try JSONSerialization.jsonObject(with: quote.raw)
        var request = URLRequest(url: URL(string: "\(base)/swap")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "quoteResponse": quoteObject, "userPublicKey": user,
            "wrapAndUnwrapSol": true, "dynamicComputeUnitLimit": true,
            "prioritizationFeeLamports": ["priorityLevelWithMaxLamports": ["maxLamports": 200_000, "priorityLevel": "medium"]],
        ])
        let ask = request
        // Nothing is signed yet, so this is asked again like the quote.
        return try await RPCRetry.run({ try await URLSession.shared.data(for: ask) }) { data, status in
            guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let b64 = j["swapTransaction"] as? String, let wire = Data(base64Encoded: b64),
                  let height = (j["lastValidBlockHeight"] as? NSNumber)?.uint64Value else {
                throw RPCRetry.Again(status == 429 || status >= 500, JupiterError(data, status))
            }
            return (wire, height)
        }
    }
}

public struct JupiterError: LocalizedError {
    public let message: String
    /// Jupiter's own words when it answers JSON («Each order valued at 30.00 USDC, minimum is 50.00 USDC»), else the
    /// body as text; a gateway's page is only its status (RPCRetry.said).
    init(_ body: Data, _ status: Int = 0) {
        message = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String ?? RPCRetry.said(body, status: status)
    }
    public var errorDescription: String? { "Jupiter: \(message)" }
}
