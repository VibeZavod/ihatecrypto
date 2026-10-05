@testable import EVMChain
import ExecutionCore
import Foundation
import HyperliquidSigning
import Testing
@testable import TradeExecution
import WalletCore

private let me = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
private let baseWETH = "0x4200000000000000000000000000000000000006", aero = "0x940181a94a35a4569e4529a3cdfb74e38fd98631"
private let baseUSDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

/// Uniswap v2's calls byte for byte as Foundry's `cast calldata` writes them (2026-10-05).
@Test func v2CalldataMatchesCast() throws {
    #expect(try UniswapV2.getAmountsOut(1_000_000, path: [baseUSDC, baseWETH, aero]).hex
        == "d06ca61f00000000000000000000000000000000000000000000000000000000000f424000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000003000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda029130000000000000000000000004200000000000000000000000000000000000006000000000000000000000000940181a94a35a4569e4529a3cdfb74e38fd98631")
    #expect(try UniswapV2.swapExactTokens(amountIn: 1_000_000, amountOutMin: Decimal(string: "1234567890123456789")!, path: [baseUSDC, aero],
                                          to: me, deadline: 1_791_200_000).hex
        == "5c11d79500000000000000000000000000000000000000000000000000000000000f4240000000000000000000000000000000000000000000000000112210f47de9811500000000000000000000000000000000000000000000000000000000000000a00000000000000000000000009858effd232b4033e47d90003d41ec34ecaeda94000000000000000000000000000000000000000000000000000000006ac38b000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913000000000000000000000000940181a94a35a4569e4529a3cdfb74e38fd98631")
    #expect(try UniswapV2.swapExactTokens(amountIn: Decimal(string: "5000000000000000000")!, amountOutMin: 1, path: [aero, baseWETH],
                                          to: me, deadline: 1_791_200_000, toETH: true).hex
        == "791ac9470000000000000000000000000000000000000000000000004563918244f40000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a00000000000000000000000009858effd232b4033e47d90003d41ec34ecaeda94000000000000000000000000000000000000000000000000000000006ac38b000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000940181a94a35a4569e4529a3cdfb74e38fd98631000000000000000000000000" + "4200000000000000000000000000000000000006")
    // getAmountsOut's answer: offset, three amounts; the last is what comes out.
    let answer = ABI.uint(0x20) + ABI.uint(3) + ABI.uint(1_000_000) + ABI.uint(400_000_000_000_000) + ABI.uint(777)
    #expect(UniswapV2.amountOut(answer) == 777)
    #expect(UniswapV2.amountOut(ABI.uint(0x20) + ABI.uint(9)) == nil)
}

/// The signer reads every v2 swap form: only this wallet may get what comes out, the router is a spender ihatecrypto knows
/// on each network, and no other contract becomes one.
@Test func signerReadsV2SwapsAndKnowsItsRouters() throws {
    for chain: UInt64 in [8453, 42161, 1, 137, 4663] {
        let v2 = try #require(UniswapV2.on(chain))
        #expect(EVMCall.knownSpenders(chainId: chain).contains(v2.router))
        for toETH in [false, true] {
            let mine = try UniswapV2.swapExactTokens(amountIn: 1, amountOutMin: 1, path: [baseUSDC, aero], to: me, deadline: 1, toETH: toETH)
            #expect(EVMCall.decode(mine) == .swap(recipient: me))
            #expect(EVMCall.decode(mine).refusal(sender: me) == nil)
            let theirs = try UniswapV2.swapExactTokens(amountIn: 1, amountOutMin: 1, path: [baseUSDC, aero], to: baseWETH, deadline: 1, toETH: toETH)
            #expect(EVMCall.decode(theirs).refusal(sender: me) != nil)
        }
    }
    // The plain forms (no fee-on-transfer) share the layout: the recipient is still read and checked.
    var plain = try UniswapV2.swapExactTokens(amountIn: 1, amountOutMin: 1, path: [baseUSDC, aero], to: baseWETH, deadline: 1)
    plain.replaceSubrange(0..<4, with: Data([0x38, 0xed, 0x17, 0x39]))
    #expect(EVMCall.decode(plain) == .swap(recipient: baseWETH) && EVMCall.decode(plain).refusal(sender: me) != nil)
    #expect(!EVMCall.knownSpenders(chainId: 8453).contains(baseWETH))
}

/// Live (IHATECRYPTO_NET=1, reads only): PEPE's deepest pool is Uniswap v2 on Ethereum, so 0.1 WETH of PEPE takes v2's
/// pair, which gives more than v3's; AERO for USDC on Base still finds a route, whichever version wins.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func v2IsQuotedBesideV3AndV4() async throws {
    let e = Executor(wallet: TradeWallet(solana: "", evm: "0x00000000000000000000000000000000000f0a11"), signer: QuoteOnly(),
                     journal: Journal(url: FileManager.default.temporaryDirectory.appendingPathComponent("v2live-\(UUID().uuidString).jsonl"))) { _ in }
    let pepe = "0x6982508145454ce325ddbe47a25d4ec3d2311933", weth = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
    let uni = try #require(UniswapV3.on(1)), tenth = Decimal(string: "100000000000000000")!
    let v2 = try #require(await e.bestV2(on: .ethereum, from: weth, to: pepe, amountIn: tenth))
    let v3 = await e.bestPath(on: EVMNetwork.ethereum.rpc, uni, from: weth, to: pepe, amountIn: tenth)
    let best = try #require(await e.bestUniswap(on: .ethereum, uni, from: weth, to: pepe, amountIn: tenth))
    print("0.1 WETH → PEPE: v2 \(v2.out) via \(v2.path.count) · v3 \(v3?.out ?? 0) · best \(best.title) \(best.out)\(best.impactText)")
    #expect(v2.path == [weth, pepe] && v2.out > (v3?.out ?? 0))
    #expect(best.v2 == [weth, pepe] && best.title == "Uniswap v2" && best.impact != nil)
    let baseUni = try #require(UniswapV3.on(8453))
    let aeroRoute = try #require(await e.bestUniswap(on: .base, baseUni, from: baseUSDC, to: aero, amountIn: 5_000_000))
    print("5 USDC → AERO on Base: \(aeroRoute.title) \(aeroRoute.out)")
    #expect(aeroRoute.out > 0)
}

private struct QuoteOnly: TradeSigner {
    func signSolana(_ wire: Data, accounts: [String], recipients: [String], tokenOwners: [String: String]) async throws -> Data { throw ExecutionError("no") }
    func signHyperliquid(_ action: MsgPack, nonce: UInt64) async throws -> EVMSignature { throw ExecutionError("no") }
    func signHyperliquidUser(_ action: MsgPack, recipients: [String]) async throws -> EVMSignature { throw ExecutionError("no") }
    func signRelayMapping(wallet: String, depositor: String, id: Data, nonce: UInt64) async throws -> EVMSignature { throw ExecutionError("no") }
    func signEVM(chainId: UInt64, nonce: UInt64, maxPriorityFee: UInt64, maxFee: UInt64, gasLimit: UInt64, to: String, data: Data,
                 recipients: [String]) async throws -> Data { throw ExecutionError("no") }
    func signNearIntentDeposit(amount: UInt128, depositAddress: String, nonce: UInt64, blockHash: Data) async throws -> Data { throw ExecutionError("no") }
}

/// v4 hooks: a pool may run one only when Uniswap's registry vouches for it on that network (vanillaHooks), its address
/// takes no swap delta and the pool's fee isn't the hook's; the signer applies the same rule, and none at all without the
/// network.
@Test func v4HooksOnlyFromTheRegistryOnTheirOwnNetwork() throws {
    // One the registry lists on Base only: the same address on another network is another contract, maybe not a vanilla one.
    let elsewhere = UniswapV4.vanillaHooks.filter { $0.key != 8453 }.values.reduce(Set<String>()) { $0.union($1) }
    let listed = try #require(UniswapV4.vanillaHooks[8453]?.sorted().first { !elsewhere.contains($0) })
    func key(_ hooks: String, fee: UInt32 = 3000) -> UniswapV4.PoolKey {
        UniswapV4.PoolKey(currency0: baseUSDC, currency1: aero, fee: fee, tickSpacing: 60, hooks: hooks)
    }
    #expect(UniswapV4.allowsHooks(key("0x0000000000000000000000000000000000000000"), chainId: 8453))
    #expect(UniswapV4.allowsHooks(key(listed), chainId: 8453))
    #expect(!UniswapV4.allowsHooks(key(listed, fee: 0x800000), chainId: 8453))           // the hook would set the fee
    #expect(!UniswapV4.allowsHooks(key(listed), chainId: 42161) && !UniswapV4.allowsHooks(key(listed), chainId: 1))
    #expect(!UniswapV4.allowsHooks(key("0x1111111111111111111111111111111111110080"), chainId: 8453))   // not in the registry
    // The permission bits in a hook's address: bit 3 and bit 2 let it take part of a swap.
    #expect(UniswapV4.takesSwapDelta("0x00000000000000000000000000000000000000c8") && UniswapV4.takesSwapDelta("0x0000000000000000000000000000000000000044"))
    #expect(!UniswapV4.takesSwapDelta("0x0000000000000000000000000000000000000080") && UniswapV4.takesSwapDelta("0xzz"))
    // Every listed hook on every network passes the same rules the generator applied.
    for (chain, hooks) in UniswapV4.vanillaHooks {
        #expect(!hooks.isEmpty, "network \(chain)")
        for h in hooks { #expect(h.count == 42 && h == h.lowercased() && !UniswapV4.takesSwapDelta(h)) }
    }
    // The signer: the app's own swap through that pool signs on Base, not elsewhere, and not without the network.
    let swap = try UniswapV4.execute(key(listed), zeroForOne: true, amountIn: 1_000_000, amountOutMinimum: 1, deadline: 1)
    #expect(EVMCall.decode(swap).refusal(sender: me, chainId: 8453) == nil)
    #expect(EVMCall.decode(swap).refusal(sender: me, chainId: 1)?.contains("hooks") == true)
    #expect(EVMCall.decode(swap).refusal(sender: me)?.contains("hooks") == true)
    let unlisted = try UniswapV4.execute(key("0x1111111111111111111111111111111111110080"), zeroForOne: true, amountIn: 1, amountOutMinimum: 1, deadline: 1)
    #expect(EVMCall.decode(unlisted).refusal(sender: me, chainId: 8453)?.contains("hooks") == true)
    #expect(!Batch7702.problems([.init(to: UniswapV4.on(8453)!.router, data: unlisted)], owner: me, chainId: 8453).isEmpty)
}
