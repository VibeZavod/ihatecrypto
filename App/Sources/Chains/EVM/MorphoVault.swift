import Foundation
import WalletCore

/// A Morpho vault on Base (ERC-4626): USDC in for shares, shares back for USDC with the interest. Gauntlet USDC Prime
/// was Base's largest USDC vault on 2026-09-27 ($415M, no vault fee); `verify` re-reads its asset before a run.
public enum MorphoVault {
    public static let gauntletUSDCPrime = "0xee8f4ec5672f09119b96ab6fb59c27e1b7e44b61"
    public static let name = "Gauntlet USDC Prime"

    /// deposit(uint256 assets, address receiver)
    public static func deposit(assets: UInt64, receiver: String) throws -> Data {
        Data([0x6e, 0x55, 0x3f, 0x65]) + ABI.uint(assets) + (try ABI.address(receiver))
    }

    /// withdraw(uint256 assets, address receiver, address owner): an exact amount of USDC out.
    public static func withdraw(assets: UInt64, receiver: String, owner: String) throws -> Data {
        Data([0xb4, 0x60, 0xaf, 0x94]) + ABI.uint(assets) + (try ABI.address(receiver)) + (try ABI.address(owner))
    }

    /// redeem(uint256 shares, address receiver, address owner): every share out. `shares` is the 32-byte word
    /// balanceOf returned — 18-decimal shares outgrow 64 bits past ≈ 18 USDC.
    public static func redeem(shares: Data, receiver: String, owner: String) throws -> Data {
        precondition(shares.count == 32)
        return Data([0xba, 0x08, 0x76, 0x52]) + shares + (try ABI.address(receiver)) + (try ABI.address(owner))
    }

    /// maxWithdraw(address owner): the owner's USDC in the vault, interest included (6 decimals).
    public static func maxWithdraw(_ owner: String) throws -> Data { Data([0xce, 0x96, 0xcb, 0x77]) + (try ABI.address(owner)) }

    /// asset()
    public static let asset = Data([0x38, 0xd5, 0x2e, 0x0f])

    /// The vault must hold USDC; otherwise nothing is signed.
    public static func verify(_ vault: String = gauntletUSDCPrime, rpc: EVMRPC = .base) async throws {
        let asset = ABI.address(in: try await rpc.read(vault, asset), word: 0)
        guard asset?.lowercased() == EVMRPC.baseUSDC else {
            throw WalletError("The Morpho vault on Base doesn't hold USDC (\(asset ?? "?")). Nothing was signed.")
        }
    }

    /// The owner's USDC in the vault (6 decimals).
    public static func value(_ owner: String, vault: String = gauntletUSDCPrime, rpc: EVMRPC = .base) async throws -> UInt64 {
        ABI.uint(in: try await rpc.read(vault, try maxWithdraw(owner)), word: 0) ?? 0
    }
}
