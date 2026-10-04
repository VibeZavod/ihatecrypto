@testable import EVMChain
import ExecutionCore
import Foundation
import HyperliquidSigning
import Testing
@testable import TradeExecution
import WalletCore

/// anvil's first well-known key (public test vector, never funded by ihatecrypto).
private let key = Data(hex: "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")!
private let owner = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
private let baseUSDC = EVMRPC.baseUSDC
private let router = "0x2626664c2603336e57b271c5c0b26f421741e481"
private let approve = try! ERC20.approve(spender: router, units: 1_500_000)
private let calls = [Batch7702.Call(to: baseUSDC, data: approve), Batch7702.Call(to: router, data: Data(hex: "1234567890")!)]

/// Foundry's cast built the same batch (calldata), authorization (wallet sign-auth) and type-4 transaction (mktx), byte for byte.
@Test func batchCalldataAuthorizationAndTransactionMatchCast() throws {
    #expect(try Batch7702.executeBatch(calls).hex == "34fcd5be0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000120000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000044095ea7b30000000000000000000000002626664c2603336e57b271c5c0b26f421741e481000000000000000000000000000000000000000000000000000000000016e360000000000000000000000000000000000000000000000000000000000000000000000000000000002626664c2603336e57b271c5c0b26f421741e4810000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000051234567890000000000000000000000000000000000000000000000000000000")
    let digest = Batch7702.authorizationDigest(chainId: 8453, nonce: 8)
    #expect(digest.hex == "bc6cf1a2532c5a9d49f8046500eddc3dfd84869cb6c4e3ee29dde65214be1ddb")
    let auth = try EVMSigner.sign(digest: digest, privateKey: key)
    #expect(auth.v == 28 && auth.r.hex == "2051bf111c51e7d98ef0e135f5ab9c6d9964aca8d13c6aa5dbf726eddba9cdb9"
            && auth.s.hex == "6b630c1fab85719012adc4843da6cc2d65348b61af8a052ef4f174437d1f3b48")
    // Nonce 7 for the transaction, 8 for the authorization: the sender's nonce goes up first.
    let tx = try Batch7702.signed(chainId: 8453, nonce: 7, maxPriorityFee: 1_000_000, maxFee: 2_000_000, gasLimit: 200_000, owner: owner,
                                  calls: calls, privateKey: key)
    #expect(tx.raw.hex == "04f902d182210507830f4240831e848083030d4094f39fd6e51aad88f6f4ce6ab8827279cfffb9226680b9020434fcd5be0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000120000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000044095ea7b30000000000000000000000002626664c2603336e57b271c5c0b26f421741e481000000000000000000000000000000000000000000000000000000000016e360000000000000000000000000000000000000000000000000000000000000000000000000000000002626664c2603336e57b271c5c0b26f421741e4810000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000051234567890000000000000000000000000000000000000000000000000000000c0f85ef85c822105944cd241e8d1510e30b2076397afc7508ae59c66c90801a02051bf111c51e7d98ef0e135f5ab9c6d9964aca8d13c6aa5dbf726eddba9cdb9a06b630c1fab85719012adc4843da6cc2d65348b61af8a052ef4f174437d1f3b4880a0f331a0811039069fa235f2cb9bc5cdb2b29077a43ddb57f323619dd1efc4f8dba030e48527c916ef3437c96d164b974932232dc52622ae25371872c330dc329686")
}

@Test func batchRulesRefuseWhatOneCallWouldBeRefusedAndMore() throws {
    let swap = try UniswapV3.exactInput(path: try UniswapV3.path([baseUSDC, "0x4200000000000000000000000000000000000006"], fees: [500]),
                                        recipient: owner, amountIn: 1_500_000, amountOutMinimum: 1)
    let good = [Batch7702.Call(to: baseUSDC, data: approve), Batch7702.Call(to: router, data: swap)]
    #expect(Batch7702.problems(good, owner: owner, chainId: 8453).isEmpty)
    for chain: UInt64 in [1, 137, 42161, 8453, 4663] { #expect(Batch7702.problems(good, owner: owner, chainId: chain).isEmpty) }
    // Networks without the audited account or Prague: Tempo, Optimism, and chain 0 (an authorization good on every network).
    for chain: UInt64 in [4217, 10, 0] { #expect(!Batch7702.problems(good, owner: owner, chainId: chain).isEmpty) }
    // A call into the wallet itself would run the batch account's executeBatch with calls nobody read.
    #expect(!Batch7702.problems(good + [.init(to: owner.lowercased(), data: Data([1, 2, 3, 4]))], owner: owner, chainId: 8453).isEmpty)
    // The one-call rules hold inside: an unlimited approve, a swap paying someone else.
    let unlimited = try ERC20.approve(spender: router, units: Decimal(string: "1000000000000000000000000000000")!)
    #expect(!Batch7702.problems([.init(to: baseUSDC, data: unlimited)] + good.suffix(1), owner: owner, chainId: 8453).isEmpty)
    let thief = "0x1111111111111111111111111111111111111111"
    let stolen = try UniswapV3.exactInput(path: try UniswapV3.path([baseUSDC, "0x4200000000000000000000000000000000000006"], fees: [500]),
                                          recipient: thief, amountIn: 1_500_000, amountOutMinimum: 1)
    #expect(!Batch7702.problems(good.prefix(1) + [.init(to: router, data: stolen)], owner: owner, chainId: 8453).isEmpty)
    // Empty, or more calls than any move makes.
    #expect(!Batch7702.problems([], owner: owner, chainId: 8453).isEmpty)
    #expect(!Batch7702.problems(Array(repeating: good[0], count: Batch7702.maxCalls + 1), owner: owner, chainId: 8453).isEmpty)
    // A plain transaction into the wallet's own address with calldata is refused too; a plain coin transfer to itself isn't.
    #expect(Batch7702.selfCall(to: owner.lowercased(), data: Data([0x34, 0xfc, 0xd5, 0xbe]), owner: owner) != nil)
    #expect(Batch7702.selfCall(to: owner, data: Data(), owner: owner) == nil)
    #expect(Batch7702.selfCall(to: router, data: swap, owner: owner) == nil)
}

/// A user operation for ERC-4337's EntryPoint: once delegated, the account runs whatever it says, so it's never signed,
/// whatever the site names its domain or type.
@Test func userOperationsAreNeverSigned() throws {
    func typed(_ name: String, _ primary: String, _ contract: String) throws -> TypedData {
        try TypedData.parse(Data(#"""
        {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],
         "\#(primary)":[{"name":"sender","type":"address"},{"name":"nonce","type":"uint256"},{"name":"initCode","type":"bytes"},{"name":"callData","type":"bytes"},{"name":"accountGasLimits","type":"bytes32"},{"name":"preVerificationGas","type":"uint256"},{"name":"gasFees","type":"bytes32"},{"name":"paymasterAndData","type":"bytes"}]},
         "primaryType":"\#(primary)",
         "domain":{"name":"\#(name)","version":"1","chainId":8453,"verifyingContract":"\#(contract)"},
         "message":{"sender":"\#(owner)","nonce":"0","initCode":"0x","callData":"0x34fcd5be","accountGasLimits":"0x0000000000000000000000000000000000000000000000000000000000000000","preVerificationGas":"0","gasFees":"0x0000000000000000000000000000000000000000000000000000000000000000","paymasterAndData":"0x"}}
        """#.utf8))
    }
    #expect(try typed("ERC4337", "PackedUserOperation", "0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108").refusal != nil)
    #expect(try typed("Totally Legit Login", "Login", "0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108").refusal != nil)
    #expect(try typed("ERC4337", "Login", "0x1111111111111111111111111111111111111111").refusal != nil)
    #expect(try typed("Some App", "PackedUserOperation", "0x1111111111111111111111111111111111111111").refusal != nil)
}

// MARK: - Fork run

/// Signs with a throwaway key under the same rules as the signing process (Signer.swift), for the fork run.
private struct ForkSigner: TradeSigner {
    let key: Data
    let address: String
    var batches = true
    var signsBatches: Bool { batches }

    func signSolana(_ wire: Data, accounts: [String], recipients: [String], tokenOwners: [String: String]) async throws -> Data { throw ExecutionError("no") }
    func signHyperliquid(_ action: MsgPack, nonce: UInt64) async throws -> EVMSignature { throw ExecutionError("no") }
    func signHyperliquidUser(_ action: MsgPack, recipients: [String]) async throws -> EVMSignature { throw ExecutionError("no") }
    func signRelayMapping(wallet: String, depositor: String, id: Data, nonce: UInt64) async throws -> EVMSignature { throw ExecutionError("no") }
    func signNearIntentDeposit(amount: UInt128, depositAddress: String, nonce: UInt64, blockHash: Data) async throws -> Data { throw ExecutionError("no") }

    func signEVM(chainId: UInt64, nonce: UInt64, maxPriorityFee: UInt64, maxFee: UInt64, gasLimit: UInt64, to: String, data: Data,
                 recipients: [String]) async throws -> Data {
        let call = EVMCall.decode(data)
        if let why = call.refusal(sender: address) ?? Batch7702.selfCall(to: to, data: data, owner: address) { throw ExecutionError(why) }
        if let payee = call.payees(to: to, value: 0, chainId: chainId).first(where: { $0.lowercased() != address.lowercased() }) { throw ExecutionError("pays \(payee)") }
        return try EVMTransaction(chainId: chainId, nonce: nonce, maxPriorityFeePerGas: maxPriorityFee, maxFeePerGas: maxFee, gasLimit: gasLimit,
                                  to: to, value: 0, data: data).signed(privateKey: key).raw
    }

    func signEVMBatch(chainId: UInt64, nonce: UInt64, maxPriorityFee: UInt64, maxFee: UInt64, gasLimit: UInt64,
                      calls: [Batch7702.Call], recipients: [String]) async throws -> Data {
        if let why = Batch7702.problems(calls, owner: address, chainId: chainId).first { throw ExecutionError(why) }
        for c in calls {
            if let payee = EVMCall.decode(c.data).payees(to: c.to, value: 0, chainId: chainId).first(where: { $0.lowercased() != address.lowercased() }) {
                throw ExecutionError("pays \(payee)")
            }
        }
        return try Batch7702.signed(chainId: chainId, nonce: nonce, maxPriorityFee: maxPriorityFee, maxFee: maxFee, gasLimit: gasLimit,
                                    owner: address, calls: calls, privateKey: key).raw
    }
}

/// The executor's own approve + Uniswap swap on an anvil fork of Base (App/Tools/fork7702.sh starts it and funds a fresh
/// key): one type-4 transaction, the wallet delegated to the audited account, the allowance spent to zero; a second buy
/// is one transaction again; a signer that doesn't batch still works on the now-delegated wallet, in two.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_ANVIL"] != nil))
func forkApproveAndSwapGoAsOneTransaction() async throws {
    let env = ProcessInfo.processInfo.environment
    let chain = UInt64(env["IHATECRYPTO_ANVIL_CHAIN"] ?? "8453")!
    let rpc = EVMRPC(url: URL(string: env["IHATECRYPTO_ANVIL"]!)!, chainId: chain)
    let key = Data(hex: env["IHATECRYPTO_ANVIL_KEY"]!)!
    let me = try EVMAccount.address(privateKey: key)
    let uni = try #require(UniswapV3.on(chain)), weth = uni.weth
    let baseUSDC = try #require(EVMNetwork.of(chainId: chain)).usdc
    let journal = Journal(url: FileManager.default.temporaryDirectory.appendingPathComponent("fork7702-\(UUID().uuidString).jsonl"))
    func executor(batches: Bool) -> Executor {
        Executor(wallet: TradeWallet(solana: "", evm: me), signer: ForkSigner(key: key, address: me, batches: batches), journal: journal) { print("·", $0) }
    }
    func buy(_ units: UInt64, with e: Executor) async throws -> String {
        let best = try #require(await e.bestPath(on: rpc, uni, from: baseUSDC, to: weth, amountIn: Decimal(units)))
        return try await e.approveAndSend(rpc, token: baseUSDC, spender: uni.router, units: Decimal(units), approveNote: "Approve exactly USDC to Uniswap",
                                          to: uni.router, data: try UniswapV3.exactInput(path: best.path, recipient: me, amountIn: Decimal(units),
                                                                                          amountOutMinimum: (best.out * Decimal(string: "0.99")!).whole),
                                          note: "Buy WETH on Uniswap")
    }
    func allowance() async throws -> Decimal { ABI.decimal(in: try await rpc.read(baseUSDC, try ERC20.allowance(owner: me, spender: uni.router)), word: 0) ?? -1 }
    func receiptType(_ hash: String) async throws -> String { ((try await rpc.call("eth_getTransactionReceipt", [hash])) as? [String: Any])?["type"] as? String ?? "?" }

    // The wrapped coin as a Decimal: 3 USDC buys ~20 WPOL on Polygon, past tokenBalance's 64 bits.
    let usdc0 = try await rpc.tokenBalance(baseUSDC, owner: me), weth0 = try await executor(batches: true).balance(weth, on: rpc)
    let nonce0 = try await rpc.nonce(me)
    // 1. The first buy: approve + swap as one type-4 transaction. The nonce goes up by two: the transaction's, then the
    // authorization's (EIP-7702 bumps the authority's nonce when it applies one) — which shows the delegation took.
    let first = try await buy(3_000_000, with: executor(batches: true))
    #expect(try await rpc.nonce(me) == nonce0 + 2)
    #expect(try await receiptType(first) == "0x4")
    #expect(try await rpc.tokenBalance(baseUSDC, owner: me) == usdc0 - 3_000_000)
    #expect(try await executor(batches: true).balance(weth, on: rpc) > weth0)
    #expect(try await allowance() == 0)
    let code = (try await rpc.call("eth_getCode", [me, "latest"])) as? String
    #expect(code?.lowercased() == "0xef0100" + Batch7702.delegate.dropFirst(2))
    // 2. A second buy: one transaction again, the delegation kept.
    let second = try await buy(2_000_000, with: executor(batches: true))
    #expect(try await rpc.nonce(me) == nonce0 + 4)
    #expect(try await receiptType(second) == "0x4")
    #expect(try await rpc.tokenBalance(baseUSDC, owner: me) == usdc0 - 5_000_000)
    #expect(try await allowance() == 0)
    // 3. A signer that doesn't batch (a Ledger): approve, then swap, two type-2 transactions from the delegated wallet.
    let third = try await buy(1_000_000, with: executor(batches: false))
    #expect(try await rpc.nonce(me) == nonce0 + 6)
    #expect(try await receiptType(third) == "0x2")
    #expect(try await rpc.tokenBalance(baseUSDC, owner: me) == usdc0 - 6_000_000)
    // 4. A swap that would fail (more USDC than the wallet has) stops at the dry run: nothing signed, nonce unchanged.
    let held = try await rpc.tokenBalance(baseUSDC, owner: me)
    await #expect(throws: (any Error).self) { try await buy(held + 1_000_000, with: executor(batches: true)) }
    #expect(try await rpc.nonce(me) == nonce0 + 6)
    // 5. The delegated wallet takes coins as before (a gas top-up, a withdrawal): the batch account's receive().
    let friend = "0x00000000000000000000000000000000000f0a11"
    _ = try await rpc.call("anvil_setBalance", [friend, "0xde0b6b3a7640000"])
    _ = try await rpc.call("anvil_impersonateAccount", [friend])
    let eth0 = try await rpc.balance(me)
    let sent = try #require(try await rpc.call("eth_sendTransaction", [["from": friend, "to": me, "value": "0x38d7ea4c68000"]]) as? String)
    #expect(try await rpc.waitForReceipt(sent))
    #expect(try await rpc.balance(me) == eth0 + 1_000_000_000_000_000)
    // 6. The signer refuses an unlimited approve inside a batch.
    let unlimited = try ERC20.approve(spender: uni.router, units: Decimal(string: "1000000000000000000000000000000")!)
    await #expect(throws: (any Error).self) {
        try await ForkSigner(key: key, address: me).signEVMBatch(chainId: chain, nonce: 0, maxPriorityFee: 1, maxFee: 1, gasLimit: 100_000,
                                                                 calls: [.init(to: baseUSDC, data: unlimited), .init(to: uni.router, data: Data([1]))], recipients: [])
    }
}

/// Robinhood Chain's Uniswap v4 buy on an anvil fork (NET=robinhood Tools/fork7702.sh): the approve to Permit2,
/// Permit2's approve to the router and the swap go as one type-4 transaction; a second buy within Permit2's half hour is
/// the swap alone when nothing needs approving.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_ANVIL_CHAIN"] == "4663"))
func forkRobinhoodV4SwapIsOneTransaction() async throws {
    let env = ProcessInfo.processInfo.environment
    let rpc = EVMRPC(url: URL(string: env["IHATECRYPTO_ANVIL"]!)!, chainId: 4663)
    let key = Data(hex: env["IHATECRYPTO_ANVIL_KEY"]!)!
    let me = try EVMAccount.address(privateKey: key)
    let usdg = EVMRPC.robinhoodUSDG, ai = "0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18"
    let key4 = UniswapV4.PoolKey(currency0: ai, currency1: usdg, fee: 2300, tickSpacing: 23, hooks: "0x0000000000000000000000000000000000000000")
    let journal = Journal(url: FileManager.default.temporaryDirectory.appendingPathComponent("fork7702-\(UUID().uuidString).jsonl"))
    let e = Executor(wallet: TradeWallet(solana: "", evm: me), signer: ForkSigner(key: key, address: me), journal: journal) { print("·", $0) }
    func buy(_ units: Decimal) async throws -> String {
        let quote = try await rpc.read(UniswapV4.robinhoodQuoter, try UniswapV4.quoteExactInputSingle(key4, zeroForOne: false, amount: units))
        let out = try #require(ABI.decimal(in: quote, word: 0))
        return try await e.v4Swap((key4, false, out), tokenIn: usdg, units: units, minOut: (out * 99 / 100).rounded(0, .down), what: "USDG",
                                  note: "Buy AI on Uniswap v4", rpc: rpc)
    }
    func receiptType(_ hash: String) async throws -> String { ((try await rpc.call("eth_getTransactionReceipt", [hash])) as? [String: Any])?["type"] as? String ?? "?" }
    // AI has 18 decimals: its balance doesn't fit tokenBalance's 64 bits, so it's read as a Decimal.
    let usdg0 = try await rpc.tokenBalance(usdg, owner: me), ai0 = try await e.balance(ai, on: rpc), nonce0 = try await rpc.nonce(me)
    let first = try await buy(5_000_000)
    #expect(try await receiptType(first) == "0x4")
    #expect(try await rpc.nonce(me) == nonce0 + 2)   // the transaction and the authorization
    #expect(try await rpc.tokenBalance(usdg, owner: me) == usdg0 - 5_000_000)
    #expect(try await e.balance(ai, on: rpc) > ai0)
    let toPermit2 = ABI.decimal(in: try await rpc.read(usdg, try ERC20.allowance(owner: me, spender: UniswapV4.permit2)), word: 0)
    #expect(toPermit2 == 0)   // the exact approve, spent by the swap
    let code = (try await rpc.call("eth_getCode", [me, "latest"])) as? String
    #expect(code?.lowercased() == "0xef0100" + Batch7702.delegate.dropFirst(2))
    // Again: the approve to Permit2 and Permit2's own are needed again (both spent), so one batch again.
    let second = try await buy(3_000_000)
    #expect(try await receiptType(second) == "0x4")
    #expect(try await rpc.nonce(me) == nonce0 + 4)
    #expect(try await rpc.tokenBalance(usdg, owner: me) == usdg0 - 8_000_000)
}
