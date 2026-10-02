import EVMChain
import Foundation
import Testing
@testable import TradeExecution

/// Reads Robinhood Chain (no signing): run with IHATECRYPTO_NET=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func v4FindsTheAIPoolAndQuotesIt() async throws {
    let ai = "0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18", usdg = EVMRPC.robinhoodUSDG
    let key = try #require(await Executor.v4Pool(usdg, ai))
    #expect(key.id == "0x7aebd80541bfaaf23dbb6e99ce13d4d31c1a84c91414f971eadbff7db5f85995" && key.fee == 2300 && key.tickSpacing == 23)
    let answer = try await EVMRPC.robinhood.read(UniswapV4.robinhoodQuoter, try UniswapV4.quoteExactInputSingle(key, zeroForOne: false, amount: 299_850_000))
    let out = try #require(ABI.decimal(in: answer, word: 0))
    print("v4 quote: 299.85 USDG →", out / Decimal(sign: .plus, exponent: 18, significand: 1), "AI")
    #expect(out > Decimal(string: "1800000000000000000000")!)
}

/// Prints the app's own calldata for a fork run: IHATECRYPTO_V4_MINOUT, IHATECRYPTO_V4_NOW.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_V4_NOW"] != nil))
func v4PrintsCalldataForAForkRun() throws {
    let env = ProcessInfo.processInfo.environment
    let now = UInt64(env["IHATECRYPTO_V4_NOW"]!)!, minOut = Decimal(string: env["IHATECRYPTO_V4_MINOUT"]!)!
    let key = UniswapV4.PoolKey(currency0: "0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18", currency1: EVMRPC.robinhoodUSDG, fee: 2300, tickSpacing: 23,
                                hooks: "0x0000000000000000000000000000000000000000")
    print("P2=0x" + (try UniswapV4.permit2Approve(token: EVMRPC.robinhoodUSDG, spender: UniswapV4.robinhoodRouter, amount: 299_850_000, expiration: now + 1800)).hex)
    print("EX=0x" + (try UniswapV4.execute(key, zeroForOne: false, amountIn: 299_850_000, amountOutMinimum: minOut, deadline: now + 600)).hex)
}
