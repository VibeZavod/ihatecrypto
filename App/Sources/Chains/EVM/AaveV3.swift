import Foundation
import WalletCore

/// Aave v3: supply and withdraw USDC on Base, Arbitrum, Polygon and Ethereum. Addresses checked on-chain (Base
/// 2026-09-26, the rest 2026-09-29: PoolAddressesProvider.getPool, Pool.getReserveData(USDC).aTokenAddress);
/// `verify` re-reads them from the market's own network before a run.
public enum AaveV3 {
    public static let baseProvider = "0xe20fcbdbffc4dd138ce8b2e6fbb6cb49777ad64d"
    public static let basePool = "0xa238dd80c259a72e81d7e4664a9801593f98d1c5"
    /// aBasUSDC: grows with the interest; its balance is what can be withdrawn.
    public static let baseAUSDC = "0x4e65fe4dba92790696d040ac24aa414708f5c0ab"

    /// One network's USDC market. Arbitrum and Polygon share the pool's address but not the aToken, so a market read
    /// on the wrong network fails `verify`.
    public struct Market: Sendable {
        /// The network's key («base», «arbitrum», «polygon», «ethereum») and name.
        public let chain: String
        public let chainName: String
        public let rpc: EVMRPC
        public let usdc: String
        public let provider: String
        public let pool: String
        public let aUSDC: String
        /// How the app names it: «Aave · Arbitrum».
        public var place: String { "Aave · \(chainName)" }
    }

    public static let base = Market(chain: "base", chainName: "Base", rpc: .base, usdc: EVMRPC.baseUSDC,
                                    provider: baseProvider, pool: basePool, aUSDC: baseAUSDC)
    public static let arbitrum = Market(chain: "arbitrum", chainName: "Arbitrum", rpc: .arbitrum, usdc: EVMRPC.arbitrumUSDC,
                                        provider: "0xa97684ead0e402dc232d5a977953df7ecbab3cdb", pool: "0x794a61358d6845594f94dc1db02a252b5b4814ad",
                                        aUSDC: "0x724dc807b04555b71ed48a6896b6f41593b8c637")
    public static let polygon = Market(chain: "polygon", chainName: "Polygon", rpc: .polygon, usdc: EVMRPC.polygonUSDC,
                                       provider: "0xa97684ead0e402dc232d5a977953df7ecbab3cdb", pool: "0x794a61358d6845594f94dc1db02a252b5b4814ad",
                                       aUSDC: "0xa4d94019934d8333ef880abffbf2fdd611c762bd")
    public static let ethereum = Market(chain: "ethereum", chainName: "Ethereum", rpc: .ethereum, usdc: EVMRPC.ethereumUSDC,
                                        provider: "0x2f39d218133afab8f2b819b1066c7e434ad94e9e", pool: "0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2",
                                        aUSDC: "0x98c23e9d8f34fefb1b7bd6a91b7ff122f4e16f5c")
    public static let markets = [base, arbitrum, polygon, ethereum]
    public static func market(place: String) -> Market? { markets.first { $0.place == place } }

    /// supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
    public static func supply(asset: String, amount: UInt64, onBehalfOf: String) throws -> Data {
        Data([0x61, 0x7b, 0xa0, 0x37]) + (try ABI.address(asset)) + ABI.uint(amount) + (try ABI.address(onBehalfOf)) + ABI.uint(0)
    }

    /// withdraw(address asset, uint256 amount, address to); nil = everything (type(uint256).max).
    public static func withdraw(asset: String, amount: UInt64?, to: String) throws -> Data {
        Data([0x69, 0x32, 0x8d, 0xec]) + (try ABI.address(asset)) + (amount.map(ABI.uint) ?? Data(repeating: 0xff, count: 32)) + (try ABI.address(to))
    }

    /// getPool()
    public static let getPool = Data([0x02, 0x6b, 0x1d, 0x5f])

    /// getReserveData(address): word 2 is the supply rate in ray (1e27), word 8 the aToken.
    public static func getReserveData(_ asset: String) throws -> Data { Data([0x35, 0xea, 0x6a, 0x75]) + (try ABI.address(asset)) }

    /// Supply APY in %: the ray rate compounded every second over a year.
    public static func apy(rateRay: Decimal) -> Decimal {
        let r = NSDecimalNumber(decimal: rateRay / Decimal(sign: .plus, exponent: 27, significand: 1)).doubleValue
        return Decimal(expm1(r) * 100)
    }

    /// Checks the pool and the aToken against what the market's own network says, and returns the USDC supply APY.
    /// Throws when either differs from the addresses above: then nothing is signed.
    public static func verify(_ m: Market) async throws -> Decimal {
        let pool = ABI.address(in: try await m.rpc.read(m.provider, getPool), word: 0)
        guard pool?.lowercased() == m.pool else {
            throw WalletError("Aave's pool on \(m.chainName) isn't where ihatecrypto expects it (\(pool ?? "?")). Nothing was signed.")
        }
        let reserve = try await m.rpc.read(m.pool, try getReserveData(m.usdc))
        guard ABI.address(in: reserve, word: 8)?.lowercased() == m.aUSDC, let rate = ABI.decimal(in: reserve, word: 2) else {
            throw WalletError("Aave's USDC reserve on \(m.chainName) doesn't match. Nothing was signed.")
        }
        return apy(rateRay: rate)
    }

    // ponytail: Base-only shim for Workspace.loadBase until it reads every market; the rpc is always Base's.
    public static func verifyBase(_ rpc: EVMRPC = .base) async throws -> Decimal { try await verify(base) }
}
