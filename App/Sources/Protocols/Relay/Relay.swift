import Foundation
import SolanaChain
import WalletCore

/// Relay (relay.link): intent bridge where a solver fills on the destination within seconds and the
/// user's funds go to Relay's Depository on the origin chain. Quotes need no API key.
public enum Relay {
    static let base = "https://api.relay.link"

    public enum Chain {
        public static let solana: UInt64 = 792_703_809
        public static let hyperliquid: UInt64 = 1337
        public static let arbitrum: UInt64 = 42161
        public static let base: UInt64 = 8453
        public static let robinhood: UInt64 = 4663
        public static let ethereum: UInt64 = 1
        public static let polygon: UInt64 = 137
        public static let tempo: UInt64 = 4217
        public static let hyperevm: UInt64 = 999
        public static let optimism: UInt64 = 10
        public static let bnb: UInt64 = 56
    }

    /// Relay's depository on Hyperliquid (protocol.v2.depository in /chains, checked 2026-09-25).
    /// Callers compare it with what /chains publishes at run time; both must agree.
    public static let hyperliquidDepository = "0x66cf0aace1b4e562593bec10ec7868fba9932224"

    public enum Currency {
        public static let solanaUSDC = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
        public static let solanaSOL = "11111111111111111111111111111111"
        /// USDC on the Hyperliquid perp balance, 8 decimals.
        public static let hyperliquidUSDC = "0x00000000000000000000000000000000"
    }

    public struct Quote: Sendable {
        public let requestId: String
        public let sender: String
        public let recipient: String
        public let amountIn: String
        public let amountInFormatted: String
        public let amountOutFormatted: String
        public let feesUSD: String
        public let seconds: Int
        /// Native coin for gas that arrives with the fill («0.000037» ETH), empty without a top-up.
        public let gasTopup: String
        /// Solana steps: instructions to compile and sign. EVM steps are not handled yet.
        public let solanaInstructions: [SolanaInstruction]
        /// Hyperliquid origin: an EIP-712 "RelayNonceMapping" to sign and post, then a sendAsset to the depository.
        public let hyperliquid: HyperliquidSteps?
        /// EVM origin: transactions in order («approve», «deposit»), for the caller to check and sign.
        public var evm: [EVMStep] = []
        /// The relayer's own gas in USD. Delivering to a Hyperliquid account that doesn't exist yet makes this
        /// Hyperliquid's one-time opening fee (measured 2026-09-28: $1.20 against $0 for an existing account).
        public var relayerGasUSD = ""
        /// What arrives in the destination's smallest units, and what goes in and comes out in USD: a swap into another
        /// token is judged by value, not by count.
        public var amountOut = ""
        public var amountInUSD = ""
        public var amountOutUSD = ""
    }

    public struct EVMStep: Sendable {
        public let id: String
        public let to: String
        public let data: Data
        public let value: String
        public let chainId: UInt64
    }

    public struct HyperliquidSteps: Sendable {
        public let mappingId: String
        public let mappingNonce: UInt64
        public let wallet: String
        public let depositor: String
        /// The /authorize body as Relay returned it, without the signature.
        public let authorizeBody: Data
        public let destination: String
        public let token: String
        public let amount: String
        public let nonce: UInt64
        public let sourceDex: String
        public let destinationDex: String
    }

    /// Relay's own depository address per chain, from /chains (protocol.v2.depository).
    public static func depository(chainId: UInt64) async throws -> String? {
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/chains")!)
        let chains = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["chains"] as? [[String: Any]] ?? []
        let chain = chains.first { ($0["id"] as? NSNumber)?.uint64Value == chainId }
        return ((chain?["protocol"] as? [String: Any])?["v2"] as? [String: Any])?["depository"] as? String
    }

    /// The chain's own coin (ETH, POL) in USD, as Relay prices it: what a gas top-up of some wei costs.
    public static func nativePrice(chainId: UInt64) async throws -> Decimal? {
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/currencies/token/price?address=0x0000000000000000000000000000000000000000&chainId=\(chainId)")!)
        return ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["price"] as? NSNumber).map { $0.decimalValue }
    }

    /// The approval proxy Relay publishes for a chain (contracts.approvalProxy in /chains): its swaps from an EVM token
    /// take an exact approve to it and then call it.
    public static func approvalProxy(chainId: UInt64) async throws -> String? {
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/chains")!)
        let chains = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["chains"] as? [[String: Any]] ?? []
        let chain = chains.first { ($0["id"] as? NSNumber)?.uint64Value == chainId }
        return (chain?["contracts"] as? [String: Any])?["approvalProxy"] as? String
    }

    /// Posts the signed nonce mapping that ties a Hyperliquid deposit to the order.
    public static func authorize(body: Data, signature: String) async throws {
        // Relay's SDK sends the step body as is and the signature as a query parameter.
        var request = URLRequest(url: URL(string: base + "/authorize?signature=\(signature)")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { throw RelayError(data) }
    }

    /// `exactOutput`: `amount` is what must arrive (destination units) instead of what is sent.
    /// `topupGasUSD`: also deliver that much of the destination's native coin for gas (EVM destinations).
    /// `units`: the amount as a decimal string, for token amounts past 64 bits (it replaces `amount`).
    public static func quote(user: String, recipient: String, originChain: UInt64, destinationChain: UInt64,
                             originCurrency: String, destinationCurrency: String, amount: UInt64, exactOutput: Bool = false,
                             topupGasUSD: Decimal? = nil, units: String? = nil) async throws -> Quote {
        var request = URLRequest(url: URL(string: base + "/quote/v2")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "user": user, "recipient": recipient, "originChainId": originChain, "destinationChainId": destinationChain,
            "originCurrency": originCurrency, "destinationCurrency": destinationCurrency, "amount": units ?? "\(amount)", "tradeType": exactOutput ? "EXACT_OUTPUT" : "EXACT_INPUT",
        ]
        if let usd = topupGasUSD {
            body["topupGas"] = true
            body["topupGasAmount"] = "\(Int((NSDecimalNumber(decimal: usd).doubleValue * 1_000_000).rounded(.up)))"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], let steps = j["steps"] as? [[String: Any]],
              let requestId = j["requestId"] as? String ?? steps.compactMap({ $0["requestId"] as? String }).first,
              let details = j["details"] as? [String: Any] else { throw RelayError(data) }
        func amounts(_ key: String) -> [String: Any] { details[key] as? [String: Any] ?? [:] }

        var instructions: [SolanaInstruction] = []
        var mapping: [String: Any]?, authorizeBody: Data?, deposit: [String: Any]?, depositNonce: UInt64?
        for step in steps {
            for item in step["items"] as? [[String: Any]] ?? [] {
                let d = item["data"] as? [String: Any] ?? [:]
                if let sign = d["sign"] as? [String: Any], let post = d["post"] as? [String: Any] {
                    mapping = sign["value"] as? [String: Any]
                    authorizeBody = try (post["body"] as? [String: Any]).map { try JSONSerialization.data(withJSONObject: $0) }
                }
                if let action = d["action"] as? [String: Any], action["type"] as? String == "sendAsset" {
                    deposit = action["parameters"] as? [String: Any]
                    depositNonce = (d["nonce"] as? NSNumber)?.uint64Value
                }
            }
        }
        var hyperliquid: HyperliquidSteps?
        if let m = mapping, let body = authorizeBody, let p = deposit, let nonce = depositNonce {
            hyperliquid = HyperliquidSteps(
                mappingId: m["id"] as? String ?? "", mappingNonce: (m["nonce"] as? NSNumber)?.uint64Value ?? 0,
                wallet: m["wallet"] as? String ?? "", depositor: m["depositor"] as? String ?? "", authorizeBody: body,
                destination: p["destination"] as? String ?? "", token: p["token"] as? String ?? "", amount: p["amount"] as? String ?? "",
                nonce: nonce, sourceDex: p["sourceDex"] as? String ?? "", destinationDex: p["destinationDex"] as? String ?? ""
            )
        }
        for step in steps {
            for item in step["items"] as? [[String: Any]] ?? [] {
                for ix in ((item["data"] as? [String: Any])?["instructions"] as? [[String: Any]]) ?? [] {
                    guard let program = ix["programId"] as? String, let hex = ix["data"] as? String, let bytes = Data(hex: hex) else { throw RelayError(data) }
                    let accounts = (ix["keys"] as? [[String: Any]] ?? []).map {
                        SolanaInstruction.Account(pubkey: $0["pubkey"] as? String ?? "", isSigner: $0["isSigner"] as? Bool ?? false,
                                                  isWritable: $0["isWritable"] as? Bool ?? false)
                    }
                    instructions.append(SolanaInstruction(program: program, accounts: accounts, data: bytes))
                }
            }
        }
        var evm: [EVMStep] = []
        for step in steps where step["kind"] as? String == "transaction" {
            for item in step["items"] as? [[String: Any]] ?? [] {
                guard let d = item["data"] as? [String: Any], let to = d["to"] as? String, let hex = d["data"] as? String, let bytes = Data(hex: hex) else { continue }
                evm.append(EVMStep(id: step["id"] as? String ?? "", to: to, data: bytes, value: "\(d["value"] ?? "0")",
                                   chainId: (d["chainId"] as? NSNumber)?.uint64Value ?? 0))
            }
        }
        let relayer = (j["fees"] as? [String: Any])?["relayer"] as? [String: Any]
        var quote = Quote(
            requestId: requestId, sender: details["sender"] as? String ?? "", recipient: details["recipient"] as? String ?? "",
            amountIn: amounts("currencyIn")["amount"] as? String ?? "",
            amountInFormatted: amounts("currencyIn")["amountFormatted"] as? String ?? "",
            amountOutFormatted: amounts("currencyOut")["amountFormatted"] as? String ?? "",
            feesUSD: relayer?["amountUsd"] as? String ?? "",
            seconds: (details["timeEstimate"] as? NSNumber)?.intValue ?? 0,
            gasTopup: (details["currencyGasTopup"] as? [String: Any])?["amountFormatted"] as? String ?? "",
            solanaInstructions: instructions, hyperliquid: hyperliquid
        )
        quote.evm = evm
        quote.relayerGasUSD = ((j["fees"] as? [String: Any])?["relayerGas"] as? [String: Any])?["amountUsd"] as? String ?? ""
        quote.amountOut = amounts("currencyOut")["amount"] as? String ?? ""
        quote.amountInUSD = amounts("currencyIn")["amountUsd"] as? String ?? ""
        quote.amountOutUSD = amounts("currencyOut")["amountUsd"] as? String ?? ""
        return quote
    }

    /// "waiting", "pending", "submitted", "success", "delayed", "refund", "failure".
    /// Asked while money is on its way: a throttle, a server error or a dropped connection is asked again (RPCRetry)
    /// rather than ending the move as failed while the order is still running.
    public static func status(requestId: String) async throws -> (status: String, destinationTxs: [String]) {
        try await RPCRetry.run { try await URLSession.shared.data(from: URL(string: "\(base)/intents/status/v3?requestId=\(requestId)")!) } answer: { data, code in
            guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let status = j["status"] as? String else {
                throw RPCRetry.Again(code == 429 || code >= 500, RelayError(data))
            }
            return (status, j["txHashes"] as? [String] ?? [])
        }
    }
}

public struct RelayError: LocalizedError {
    public let message: String
    init(_ data: Data) { message = RPCRetry.said(data) }
    public var errorDescription: String? { "Relay: \(message)" }
}
