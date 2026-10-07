import Foundation
import WalletCore

/// Uniswap v2 (developers.uniswap.org/docs/protocols/v2/deployments; each router's factory() and WETH() read on-chain
/// 2026-10-05): many tokens trade deepest, or only, in its pools — PEPE's deepest pool is v2 on Ethereum. A swap goes
/// through Router02 with an exact approve, in its fee-on-transfer variant: a token that taxes its transfers still swaps,
/// and the router checks what arrived at `to`, at least amountOutMin.
public enum UniswapV2 {
    public struct Deployment: Sendable {
        public let router: String
        /// What the router wraps the network's coin into: WETH, WPOL on Polygon.
        public let weth: String
    }

    public static func on(_ chainId: UInt64) -> Deployment? {
        switch chainId {
        case 8453: Deployment(router: "0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24", weth: "0x4200000000000000000000000000000000000006")
        case 42161: Deployment(router: "0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24", weth: "0x82af49447d8a07e3bd95bd0d56f35241523fbab1")
        case 1: Deployment(router: "0x7a250d5630b4cf539739df2c5dacb4c659f2488d", weth: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
        case 137: Deployment(router: "0xedf6066a2b290c185783862c7f4776a2c8077ad1", weth: "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270")
        case 4663: Deployment(router: "0x89e5db8b5aa49aa85ac63f691524311aeb649eba", weth: "0x0bd7d308f8e1639fab988df18a8011f41eacad73")
        // Optimism and HyperEVM: their Router02's WETH() is WETH and WHYPE (checked 2026-10-07).
        case 10: Deployment(router: "0x4a7b5da61326a6379179b40d00f57e5bbdc962c2", weth: "0x4200000000000000000000000000000000000006")
        case 999: Deployment(router: "0x1f7d7550b1b028f7571e69a784071f0205fd2efa", weth: "0x5555555555555555555555555555555555555555")
        default: nil
        }
    }

    /// Router02.getAmountsOut(amountIn, path).
    public static func getAmountsOut(_ amountIn: Decimal, path: [String]) throws -> Data {
        Data([0xd0, 0x6c, 0xa6, 0x1f]) + (try ABI.word(amountIn)) + ABI.uint(0x40) + (try addresses(path))
    }

    /// The last of getAmountsOut's amounts (uint256[]: offset, length, amounts): what comes out, before any transfer tax.
    public static func amountOut(_ answer: Data) -> Decimal? {
        guard let n = ABI.uint(in: answer, word: 1), n >= 2, n <= 4 else { return nil }
        return ABI.decimal(in: answer, word: 1 + Int(n))
    }

    /// swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, amountOutMin, path, to, deadline); `toETH`:
    /// swapExactTokensForETHSupportingFeeOnTransferTokens, the path ending in WETH, which the router unwraps for `to`.
    public static func swapExactTokens(amountIn: Decimal, amountOutMin: Decimal, path: [String], to: String, deadline: UInt64,
                                       toETH: Bool = false) throws -> Data {
        Data(toETH ? [0x79, 0x1a, 0xc9, 0x47] : [0x5c, 0x11, 0xd7, 0x95]) + (try ABI.word(amountIn)) + (try ABI.word(amountOutMin))
            + ABI.uint(0xa0) + (try ABI.address(to)) + ABI.uint(deadline) + (try addresses(path))
    }

    /// address[]: its length, then each address.
    static func addresses(_ path: [String]) throws -> Data {
        try path.reduce(ABI.uint(UInt64(path.count))) { $0 + (try ABI.address($1)) }
    }
}
