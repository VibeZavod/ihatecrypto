import EVMChain
import ExecutionCore
import Foundation
import HyperliquidSigning
import Testing
@testable import TradeExecution
import WalletCore

/// Reads Robinhood Chain (no signing): run with IHATECRYPTO_NET=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func v4FindsTheAIPoolAndQuotesIt() async throws {
    let ai = "0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18", usdg = EVMRPC.robinhoodUSDG
    // Among AI/USDG's hookless pools, the one checked on-chain on 2026-10-01 (fee 2300, spacing 23).
    let keys = await Executor.v4Pools(usdg, ai)
    #expect(keys.allSatisfy { !$0.hasHooks } && !keys.isEmpty)
    let key = try #require(keys.first { $0.id == "0x7aebd80541bfaaf23dbb6e99ce13d4d31c1a84c91414f971eadbff7db5f85995" })
    #expect(key.fee == 2300 && key.tickSpacing == 23)
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

/// Each network's fallback node alone serves what the executor asks (IHATECRYPTO_NET=1): the primary is a dead port, so
/// every call goes to the fallbacks — the chain id, fees, a nonce, an estimate with the 7702 state override, a balance.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func everyFallbackNodeServesTheExecutor() async throws {
    // An empty address: 0x…dEaD holds more ETH than balance()'s 64 bits.
    let me = "0x00000000000000000000000000000000000f0a11"
    for rpc in [EVMRPC.base, .arbitrum, .robinhood, .polygon, .ethereum] {
        #expect(!rpc.fallbacks.isEmpty, "\(rpc.chainId) has no fallback")
        let alone = EVMRPC(url: URL(string: "http://127.0.0.1:9")!, chainId: rpc.chainId, fallbacks: rpc.fallbacks)
        #expect(try await alone.quantity("eth_chainId", []) == rpc.chainId)
        let fees = try await alone.fees()
        #expect(fees.maxFee > 0)
        _ = try await alone.nonce(me)
        _ = try await alone.balance(me)
        // The batch account's code runs under the override: a plain transfer to itself costs more than 21,000.
        #expect(try await alone.estimateGas(from: me, to: me, value: 0, data: Data(), runningCodeOf: Batch7702.delegate) >= 21_000)
    }
}

/// Ethereum's transactions go to MEV Blocker, the rest to their own node (IHATECRYPTO_NET=1): a malformed one comes back
/// with MEV Blocker's own error, so it went there and nowhere public.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func ethereumTransactionsGoThroughMEVBlocker() async throws {
    #expect(EVMRPC.ethereum.sendURL?.host == "rpc.mevblocker.io")
    #expect([EVMRPC.base, .arbitrum, .polygon, .robinhood].allSatisfy { $0.sendURL == nil })
    do {
        _ = try await EVMRPC.ethereum.send(Data([0x02, 0xf8]))
        Issue.record("a malformed transaction was taken")
    } catch {
        #expect("\(error)".contains("Request of eth_sendRawTransaction failed"), "\(error)")
    }
}

/// Uniswap v4 found and quoted beyond Robinhood (IHATECRYPTO_NET=1, reads only): cbBTC/USDC on Base and WBTC/USDC on
/// Ethereum through their PoolManager's log and V4Quoter, and the better of v3 and v4 picked for each.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func v4FindsAndQuotesPoolsOnBaseAndEthereum() async throws {
    let e = Executor(wallet: TradeWallet(solana: "", evm: "0x00000000000000000000000000000000000f0a11"), signer: NoSigner(),
                     journal: Journal(url: FileManager.default.temporaryDirectory.appendingPathComponent("v4live-\(UUID().uuidString).jsonl"))) { _ in }
    for (net, token) in [(EVMNetwork.base, "0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf"), (.ethereum, "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599")] {
        let route = try #require(await e.v4Route(net.usdc, token, amountIn: 100_000_000, rpc: net.rpc), "no v4 pool on \(net.name)")
        #expect(!route.key.hasHooks && route.out > 0)
        let uni = try #require(UniswapV3.on(net.rpc.chainId))
        // The two are quoted again inside: the better of that moment's v3 and v4 (a block apart, they may differ a little).
        let best = try #require(await e.bestUniswap(on: net, uni, from: net.usdc, to: token, amountIn: 100_000_000))
        print("\(net.name): 100 USDC → v4 \(route.out) · best \(best.title) \(best.out)")
        #expect(best.out > route.out * Decimal(string: "0.99")!)
    }
}

private struct NoSigner: TradeSigner {
    func signSolana(_ wire: Data, accounts: [String], recipients: [String], tokenOwners: [String: String]) async throws -> Data { throw ExecutionError("no") }
    func signHyperliquid(_ action: MsgPack, nonce: UInt64) async throws -> EVMSignature { throw ExecutionError("no") }
    func signHyperliquidUser(_ action: MsgPack, recipients: [String]) async throws -> EVMSignature { throw ExecutionError("no") }
    func signRelayMapping(wallet: String, depositor: String, id: Data, nonce: UInt64) async throws -> EVMSignature { throw ExecutionError("no") }
    func signEVM(chainId: UInt64, nonce: UInt64, maxPriorityFee: UInt64, maxFee: UInt64, gasLimit: UInt64, to: String, data: Data,
                 recipients: [String]) async throws -> Data { throw ExecutionError("no") }
    func signNearIntentDeposit(amount: UInt128, depositAddress: String, nonce: UInt64, blockHash: Data) async throws -> Data { throw ExecutionError("no") }
}

/// Price impact grows with the amount (IHATECRYPTO_NET=1, reads only): 100 USDC into cbBTC on Base barely moves the pool,
/// two million moves it by percents, and the floor under the swap widens with it.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func uniswapPriceImpactGrowsWithTheAmount() async throws {
    let e = Executor(wallet: TradeWallet(solana: "", evm: "0x00000000000000000000000000000000000f0a11"), signer: NoSigner(),
                     journal: Journal(url: FileManager.default.temporaryDirectory.appendingPathComponent("impact-\(UUID().uuidString).jsonl"))) { _ in }
    let uni = try #require(UniswapV3.on(8453)), cbBTC = "0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf"
    let small = try #require(await e.bestUniswap(on: .base, uni, from: EVMNetwork.base.usdc, to: cbBTC, amountIn: 100_000_000))
    let big = try #require(await e.bestUniswap(on: .base, uni, from: EVMNetwork.base.usdc, to: cbBTC, amountIn: 2_000_000_000_000))
    print("impact: 100 USDC \(small.impact ?? -1) (\(small.title)), 2M USDC \(big.impact ?? -1) (\(big.title))\(big.impactText)")
    #expect((small.impact ?? 1) < Decimal(string: "0.005")! && small.tolerance == Decimal(string: "0.005")!)
    #expect((big.impact ?? 0) > (small.impact ?? 1) && big.tolerance > small.tolerance)
}
