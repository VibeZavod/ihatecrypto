import Foundation

/// Jupiter Lend Earn: deposit a token, receive jl-shares that grow with interest, withdraw any time.
/// First protocol of the DeFi module; a shared Vault type gets extracted when the second one arrives.
public enum JupiterLend {
    static let base = "https://lite-api.jup.ag/lend/v1/earn"

    public struct Vault: Sendable {
        public let symbol: String          // jlUSDC
        public let address: String         // the vault's share mint
        public let assetSymbol: String     // USDC
        public let assetMint: String
        public let decimals: Int
        /// Yearly rate in percent: supply interest plus rewards.
        public let apy: Decimal
    }

    public struct Position: Sendable {
        public let vault: String
        /// Underlying tokens the shares are worth now, raw units.
        public let assets: UInt64
        public let shares: UInt64
    }

    public static func vaults() async throws -> [Vault] {
        let data = try await get(URL(string: "\(base)/tokens")!)
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw LendError(data) }
        return list.compactMap { t in
            guard let asset = t["asset"] as? [String: Any], let mint = t["assetAddress"] as? String ?? asset["address"] as? String else { return nil }
            let rate = (t["totalRate"] as? String).flatMap { Decimal(string: $0) } ?? (t["totalRate"] as? NSNumber)?.decimalValue ?? 0
            return Vault(symbol: t["symbol"] as? String ?? "?", address: t["address"] as? String ?? "?",
                         assetSymbol: asset["symbol"] as? String ?? "?", assetMint: mint,
                         decimals: (t["decimals"] as? NSNumber)?.intValue ?? 6, apy: rate / 100)
        }
    }

    /// Unsigned transaction depositing `amount` raw units of `asset` for `user`.
    public static func depositTransaction(asset: String, user: String, amount: UInt64) async throws -> Data {
        try await transaction("/deposit", ["asset": asset, "signer": user, "amount": "\(amount)"])
    }

    /// Unsigned transaction withdrawing `amount` raw units of the underlying `asset`.
    public static func withdrawTransaction(asset: String, user: String, amount: UInt64) async throws -> Data {
        try await transaction("/withdraw", ["asset": asset, "signer": user, "amount": "\(amount)"])
    }

    public static func positions(user: String) async throws -> [Position] {
        let data = try await get(URL(string: "\(base)/positions?users=\(user)")!)
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw LendError(data) }
        return list.compactMap { p in
            let token = p["token"] as? [String: Any]
            func raw(_ key: String) -> UInt64? { (p[key] as? String).flatMap(UInt64.init) ?? (p[key] as? NSNumber)?.uint64Value }
            guard let assets = raw("underlyingAssets"), let shares = raw("shares") else { return nil }
            return Position(vault: token?["symbol"] as? String ?? "?", assets: assets, shares: shares)
        }
    }

    static func transaction(_ path: String, _ body: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: base + path)!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let b64 = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["transaction"] as? String,
              let wire = Data(base64Encoded: b64) else { throw LendError(data) }
        return wire
    }

    static func get(_ url: URL) async throws -> Data { try await URLSession.shared.data(from: url).0 }
}

public struct LendError: LocalizedError {
    public let message: String
    init(_ data: Data) { message = String(decoding: data.prefix(300), as: UTF8.self) }
    public var errorDescription: String? { "Jupiter Lend: \(message)" }
}
