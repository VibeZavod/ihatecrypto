import Foundation

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
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inAmount = (j["inAmount"] as? String).flatMap(UInt64.init),
              let outAmount = (j["outAmount"] as? String).flatMap(UInt64.init),
              let minOut = (j["otherAmountThreshold"] as? String).flatMap(UInt64.init) else {
            throw JupiterError(String(decoding: data.prefix(300), as: UTF8.self))
        }
        let dexes = (j["routePlan"] as? [[String: Any]] ?? []).compactMap { ($0["swapInfo"] as? [String: Any])?["label"] as? String }
        return Quote(raw: data, inAmount: inAmount, outAmount: outAmount, minOut: minOut, route: dexes.joined(separator: " → "), dexes: dexes)
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
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = j["swapTransaction"] as? String, let wire = Data(base64Encoded: b64),
              let height = (j["lastValidBlockHeight"] as? NSNumber)?.uint64Value else {
            throw JupiterError(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return (wire, height)
    }
}

public struct JupiterError: LocalizedError {
    public let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { "Jupiter: \(message)" }
}
