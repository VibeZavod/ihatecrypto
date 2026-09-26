import Foundation
import WalletCore

/// Aave v3 on Base: supply and withdraw USDC. Addresses checked on-chain 2026-09-26
/// (PoolAddressesProvider.getPool, Pool.getReserveData(USDC).aTokenAddress); `verify` re-reads them before a run.
public enum AaveV3 {
    public static let baseProvider = "0xe20fcbdbffc4dd138ce8b2e6fbb6cb49777ad64d"
    public static let basePool = "0xa238dd80c259a72e81d7e4664a9801593f98d1c5"
    /// aBasUSDC: grows with the interest; its balance is what can be withdrawn.
    public static let baseAUSDC = "0x4e65fe4dba92790696d040ac24aa414708f5c0ab"

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

    /// Checks the pool and the aToken against what Base itself says, and returns the USDC supply APY.
    /// Throws when either differs from the addresses above: then nothing is signed.
    public static func verifyBase(_ rpc: EVMRPC = .base) async throws -> Decimal {
        let pool = ABI.address(in: try await rpc.read(baseProvider, getPool), word: 0)
        guard pool?.lowercased() == basePool else { throw WalletError("Aave's pool on Base isn't where LALA expects it (\(pool ?? "?")). Nothing was signed.") }
        let reserve = try await rpc.read(basePool, try getReserveData(EVMRPC.baseUSDC))
        guard ABI.address(in: reserve, word: 8)?.lowercased() == baseAUSDC, let rate = ABI.decimal(in: reserve, word: 2) else {
            throw WalletError("Aave's USDC reserve on Base doesn't match. Nothing was signed.")
        }
        return apy(rateRay: rate)
    }
}
