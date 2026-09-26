import Foundation
import WalletCore

/// Uniswap v3 on Robinhood Chain — addresses from developers.uniswap.org (v3-robinhood-chain-deployments), 2026-09-27.
public enum UniswapV3 {
    public static let robinhoodFactory = "0x1f7d7550b1b028f7571e69a784071f0205fd2efa"
    public static let robinhoodQuoter = "0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7"
    public static let robinhoodRouter = "0xcaf681a66d020601342297493863e78c959e5cb2"
    /// Pool fees to try, in hundredths of a basis point: 0.05%, 0.3%, 1%, 0.01%.
    public static let fees: [UInt64] = [500, 3000, 10000, 100]

    /// getPool(address,address,uint24)
    public static func getPool(_ a: String, _ b: String, fee: UInt64) throws -> Data {
        Data([0x16, 0x98, 0xee, 0x82]) + (try ABI.address(a)) + (try ABI.address(b)) + ABI.uint(fee)
    }

    /// QuoterV2.quoteExactInputSingle((tokenIn, tokenOut, amountIn, fee, sqrtPriceLimitX96)): word 0 of the answer is amountOut.
    public static func quoteExactInputSingle(tokenIn: String, tokenOut: String, amountIn: UInt64, fee: UInt64) throws -> Data {
        Data([0xc6, 0xa5, 0x02, 0x6a]) + (try ABI.address(tokenIn)) + (try ABI.address(tokenOut)) + ABI.uint(amountIn) + ABI.uint(fee) + ABI.uint(0)
    }

    /// SwapRouter02.exactInputSingle((tokenIn, tokenOut, fee, recipient, amountIn, amountOutMinimum, sqrtPriceLimitX96)).
    public static func exactInputSingle(tokenIn: String, tokenOut: String, fee: UInt64, recipient: String, amountIn: UInt64, amountOutMinimum: UInt64) throws -> Data {
        Data([0x04, 0xe4, 0x5a, 0xaf]) + (try ABI.address(tokenIn)) + (try ABI.address(tokenOut)) + ABI.uint(fee) + (try ABI.address(recipient))
            + ABI.uint(amountIn) + ABI.uint(amountOutMinimum) + ABI.uint(0)
    }
}
