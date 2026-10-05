import EVMChain
import ExecutionCore
import Foundation
import HyperliquidSigning
import OneClickKit
import SolanaChain
import Testing
import TxGuard
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

/// «buy NEAR» pays where the USDC is: Solana when it holds the amount, else Base or Arbitrum before Ethereum, never a
/// network 1Click doesn't take USDC from (Polygon, Robinhood, Tempo).
@Test func buyNearPaysFromSolanaElseANetwork1ClickTakes() {
    let held: [String: Decimal] = ["base": 50, "ethereum": 500, "polygon": 900, "robinhood": 900]
    #expect(Executor.nearSource(usdc: 10, onSolana: 10, held: { held[$0] }) == nil)
    #expect(Executor.nearSource(usdc: 10, onSolana: 2, held: { held[$0] })?.key == "base")
    #expect(Executor.nearSource(usdc: 100, onSolana: 2, held: { held[$0] })?.key == "ethereum")
    #expect(Executor.nearSource(usdc: 600, onSolana: 2, held: { held[$0] }) == nil)   // only Polygon and Robinhood hold it
}

/// 1Click takes Base's, Arbitrum's and Ethereum's USDC for NEAR (IHATECRYPTO_NET=1; no money moves): a live quote issues
/// a deposit address there, and 1Click has it bound to our NEAR account, our EVM address for a refund, that asset and
/// the amount — what DepositGuard demands before anything is sent.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func oneClickTakesEVMUSDCForNearAndBindsTheDeposit() async throws {
    let evm = "0x90F79bf6EB2c4f870365E785982E1f101E93b906", near = "8ec67b662faddd44e7d79875a4cf1e7f8c3f756a4b171ccea95a4149b8dddf2b"
    for key in ["base", "arbitrum", "ethereum"] {
        let origin = try #require(OneClick.Asset.usdc(onEVM: key))
        let quote = try await OneClick.quote(dry: false, origin: origin, destination: OneClick.Asset.near, amount: "5000000", refundTo: evm, recipient: near)
        let deposit = try #require(quote.depositAddress)
        #expect(deposit.hasPrefix("0x") && deposit.count == 42, "\(key): \(deposit)")
        let bound = try await OneClick.boundRequest(depositAddress: deposit)
        #expect(DepositGuard.check(bound: bound, recipient: near, refundTo: evm, origin: origin, destination: OneClick.Asset.near, amount: "5000000").ok, "\(key)")
        // A deposit bound to someone else's refund address is refused.
        #expect(!DepositGuard.check(bound: bound, recipient: near, refundTo: "0x1111111111111111111111111111111111111111", origin: origin,
                                    destination: OneClick.Asset.near, amount: "5000000").ok)
        print("\(key): 5 USDC → \(quote.amountOutFormatted) NEAR, deposit \(deposit.prefix(10))…, ≈ \(quote.timeEstimate ?? -1) s")
    }
    #expect(OneClick.Asset.usdc(onEVM: "polygon") == nil && OneClick.Asset.usdc(onEVM: "robinhood") == nil)
}

/// ENS's namehash (EIP-137's own example) and which names are read.
@Test func ensNamehashAndNames() {
    #expect(ENS.namehash("vitalik.eth").hex == "ee6c4522aab0003e8d14cd40a6af439055fd2577951148c14b6cea9a53475835")
    #expect(ENS.namehash("eth").hex == "93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae")
    #expect(ENS.isName("vitalik.eth") && ENS.isName("a-b.sub.eth") && !ENS.isName("vіtalik.eth") && !ENS.isName("-x.eth") && !ENS.isName("x.sol"))
    #expect(SNS.isName("toly.sol") && !SNS.isName("a.b.sol") && !SNS.isName("toly.eth"))
}

/// Names read on their own chains (IHATECRYPTO_NET=1): vitalik.eth through the registry and its resolver (as Foundry's
/// cast resolve-name gives it); a .sol name's account derived here is a Name Service account under the .sol root.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func ensAndSNSNamesResolveOnTheirChains() async throws {
    #expect(try await ENS.resolve("vitalik.eth") == "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")
    await #expect(throws: (any Error).self) { try await ENS.resolve("this-name-is-not-registered-ihatecrypto.eth") }
    let owner = try await SNS.resolve("bonfida.sol")
    print("bonfida.sol → \(owner)")
    #expect(owner.count >= 32)
    await #expect(throws: (any Error).self) { try await SNS.resolve("this-name-is-not-registered-ihatecrypto.sol") }
}

/// The user's own Solana node goes first and the public one after it; none set, only the public one.
@Test func solanaNodesPutTheUsersOwnFirst() {
    let saved = SolanaNodes.custom
    defer { SolanaNodes.custom = saved }
    SolanaNodes.custom = nil
    #expect(SolanaNodes.urls == [SolanaNodes.publicNode] && SolanaRPC().url == SolanaNodes.publicNode)
    let own = URL(string: "https://mainnet.helius-rpc.com/?api-key=x")!
    SolanaNodes.custom = own
    #expect(SolanaNodes.urls == [own, SolanaNodes.publicNode] && SolanaRPC().url == own)
}

/// IHATECRYPTO_NET=1: a node of one's own that is down, or refuses its key (Helius, 401), hands the call to the public
/// node; the check keeps only an https Solana mainnet node that answers token accounts by owner.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func solanaCallsSurviveABadOwnNodeAndTheCheckKeepsOnlyAGoodOne() async throws {
    let saved = SolanaNodes.custom
    defer { SolanaNodes.custom = saved }
    for bad in ["https://127.0.0.1:9", "https://mainnet.helius-rpc.com/?api-key=00000000-0000-0000-0000-000000000000"] {
        SolanaNodes.custom = URL(string: bad)!
        #expect(try await SolanaRPC().call("getGenesisHash", []) as? String == SolanaNodes.mainnetGenesis, "\(bad)")
    }
    #expect(await SolanaNodes.problem(with: SolanaNodes.publicNode) == nil)
    let refused = await SolanaNodes.problem(with: URL(string: "https://mainnet.helius-rpc.com/?api-key=00000000-0000-0000-0000-000000000000")!)
    #expect(refused?.contains("turned the key away") == true)
    #expect(await SolanaNodes.problem(with: URL(string: "https://api.devnet.solana.com")!)?.contains("another Solana network") == true)
    #expect(await SolanaNodes.problem(with: URL(string: "http://api.mainnet-beta.solana.com")!)?.contains("https") == true)
    #expect(await SolanaNodes.problem(with: URL(string: "https://solana-rpc.publicnode.com")!) != nil)   // no token accounts (403)
    print("invalid Helius key: \(refused ?? "")")
}
