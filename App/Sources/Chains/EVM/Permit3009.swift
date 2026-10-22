import Foundation
import WalletCore

/// A dollar that Relay takes by the owner's signature (EIP-3009 ReceiveWithAuthorization) instead of a transaction: Relay's
/// approval proxy pulls it and its solver pays the network fee, so a wallet with USDC and none of the network's coin can still
/// move it to another network. The signer builds the typed data itself from these fields: a token it knows by its own domain,
/// from this wallet, only to Relay's approval proxy, valid an hour at most. The nonce is Relay's hash of the calls its proxy
/// runs with the money, so the signature can't be spent on other calls.
public struct Permit3009: Codable, Sendable, Equatable {
    public let chainId: UInt64
    public let token: String
    public let from: String
    public let to: String
    /// In the token's units (6 decimals for every token below).
    public let value: UInt64
    /// Unix seconds; validAfter is always 0.
    public let validBefore: UInt64
    public let nonce: Data

    public init(chainId: UInt64, token: String, from: String, to: String, value: UInt64, validBefore: UInt64, nonce: Data) {
        (self.chainId, self.token, self.from, self.to, self.value, self.validBefore, self.nonce) = (chainId, token, from, to, value, validBefore, nonce)
    }

    /// The dollars it's signed for, by "chain:token": their EIP-712 domain name and version, each checked against the
    /// contract's DOMAIN_SEPARATOR (2026-10-23). Not on BNB Chain (Binance-Peg USDC has no EIP-3009) or HyperEVM: Relay asks
    /// for an approval transaction there.
    public static let tokens: [String: (name: String, version: String, symbol: String)] = [
        "8453:0x833589fcd6edb6e08f4c7c32d4f71b54bda02913": ("USD Coin", "2", "USDC"),
        "42161:0xaf88d065e77c8cc2239327c5edb3a432268e5831": ("USD Coin", "2", "USDC"),
        "10:0x0b2c639c533813f4aa9d7837caf62653d097ff85": ("USD Coin", "2", "USDC"),
        "137:0x3c499c542cef5e3811e1192ce70d8cc03d5c3359": ("USD Coin", "2", "USDC"),
        "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": ("USD Coin", "2", "USDC"),
        "4663:0x5fc5360d0400a0fd4f2af552add042d716f1d168": ("Global Dollar", "1", "USDG"),
    ]
    /// Relay's approval proxies, at one address on every network: v3, and v3.2 from 2026-10-26 (both stay live a while).
    public static let relayProxies: Set<String> = ["0xccc88a9d1b4ed6b0eaba998850414b24f1c315be", "0x5567954cd026cebfe486062cb75848e0f1c12e58"]

    public static func supports(chainId: UInt64, token: String) -> Bool { tokens["\(chainId):\(token.lowercased())"] != nil }

    var known: (name: String, version: String, symbol: String)? { Self.tokens["\(chainId):\(token.lowercased())"] }

    /// Why the signer won't sign it, or nil. `now`: Unix seconds.
    public func refusal(owner: String, now: UInt64) -> String? {
        guard known != nil else { return "\(token) on network \(chainId) isn't a dollar ihatecrypto pays by signature." }
        guard from.lowercased() == owner.lowercased() else { return "The payment isn't from this wallet." }
        guard Self.relayProxies.contains(to.lowercased()) else { return "Only Relay's approval proxy may take dollars by signature, not \(to)." }
        guard value > 0, nonce.count == 32 else { return "The payment by signature is incomplete." }
        guard validBefore > now, validBefore <= now + 3600 else { return "The signature would stay valid for more than an hour, or has run out." }
        return nil
    }

    public func typed() throws -> EIP712.Typed {
        guard let known else { throw WalletError("Unknown dollar token \(token) on network \(chainId).") }
        return EIP712.Typed(domain: [.init("name", "string", .string(known.name)), .init("version", "string", .string(known.version)),
                                     .init("chainId", "uint256", .uint(chainId)), .init("verifyingContract", "address", .address(token))],
                            type: "ReceiveWithAuthorization",
                            message: [.init("from", "address", .address(from)), .init("to", "address", .address(to)),
                                      .init("value", "uint256", .uint(value)), .init("validAfter", "uint256", .uint(0)),
                                      .init("validBefore", "uint256", .uint(validBefore)), .init("nonce", "bytes32", .bytes32(nonce))])
    }

    /// What the prompt says.
    public var summary: String {
        let amount = Decimal(value) / 1_000_000
        return "pay \(amount) \(known?.symbol ?? "tokens") on \(EVMRPC.names[chainId] ?? "network \(chainId)") to Relay by signature (Relay pays the network fee)"
    }
}
