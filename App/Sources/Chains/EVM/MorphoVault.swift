import Foundation
import WalletCore

/// Morpho vaults (ERC-4626): USDC in for shares, shares back for USDC with the interest. `verify` re-reads the vault's
/// asset on its own network before a run.
public enum MorphoVault {
    public static let gauntletUSDCPrime = "0xee8f4ec5672f09119b96ab6fb59c27e1b7e44b61"
    public static let name = "Gauntlet USDC Prime"

    /// One vault on one network.
    public struct Vault: Sendable {
        public let chain: String
        public let chainName: String
        public let rpc: EVMRPC
        public let usdc: String
        public let address: String
        public let name: String
        /// How the app names it: «Morpho · Ethereum».
        public var place: String { "Morpho · \(chainName)" }
    }

    /// Base: Gauntlet USDC Prime, the largest USDC vault there on 2026-09-27 ($415M, no vault fee).
    public static let base = Vault(chain: "base", chainName: "Base", rpc: .base, usdc: EVMRPC.baseUSDC, address: gauntletUSDCPrime, name: name)
    /// Ethereum: the same curator's Prime vault ($23M, 5% fee, 2026-09-29).
    public static let ethereum = Vault(chain: "ethereum", chainName: "Ethereum", rpc: .ethereum, usdc: EVMRPC.ethereumUSDC,
                                       address: "0xdd0f28e19c1780eb6396170735d45153d261490d", name: "Gauntlet USDC Prime")
    /// Arbitrum: Arbitrum's vaults are small; Gauntlet's Core one lends against blue-chip collateral only ($1M, 2026-09-29).
    public static let arbitrum = Vault(chain: "arbitrum", chainName: "Arbitrum", rpc: .arbitrum, usdc: EVMRPC.arbitrumUSDC,
                                       address: "0x7e97fa6893871a2751b5fe961978dccb2c201e65", name: "Gauntlet USDC Core")
    public static let vaults = [base, ethereum, arbitrum]
    public static func vault(place: String) -> Vault? { vaults.first { $0.place == place } }

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

    /// The vault must hold its network's USDC; otherwise nothing is signed.
    public static func verify(_ v: Vault) async throws {
        let asset = ABI.address(in: try await v.rpc.read(v.address, asset), word: 0)
        guard asset?.lowercased() == v.usdc else {
            throw WalletError("The Morpho vault on \(v.chainName) doesn't hold USDC (\(asset ?? "?")). Nothing was signed.")
        }
    }

    /// The owner's USDC in the vault (6 decimals).
    public static func value(_ owner: String, _ v: Vault) async throws -> UInt64 {
        ABI.uint(in: try await v.rpc.read(v.address, try maxWithdraw(owner)), word: 0) ?? 0
    }

    // ponytail: Base-only shim for Workspace.loadBase until it reads every vault; the rpc is always Base's.
    public static func value(_ owner: String, rpc: EVMRPC) async throws -> UInt64 { try await value(owner, base) }
}
