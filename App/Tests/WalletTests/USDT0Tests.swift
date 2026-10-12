import EVMChain
import ExecutionCore
import Foundation
import IhatecryptoCore
import Testing
@testable import TradeExecution
import WalletCore

private let me = "0x15d34aaf54267db7d7c367839aaf71a00a2c6a65"
private let stranger = "0x000000000000000000000000000000000000beef"
private let arbitrumOFT = "0x14e4a1b13bf7f943c8ff7c51fb60fa964a298d92"

/// SendParam(Optimism, `me`, 1 USDT, 1 USDT, "", "", "") as `cast calldata` wrote it, 2026-10-13.
private let param = "000000000000000000000000000000000000000000000000000000000000759f00000000000000000000000015d34aaf54267db7d7c367839aaf71a00a2c6a65"
    + "00000000000000000000000000000000000000000000000000000000000f424000000000000000000000000000000000000000000000000000000000000f4240"
    + "00000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000120"
    + String(repeating: "0", count: 3 * 64)
/// The head of send(SendParam, (280467163186, 0), `me`).
private let sendHead = "c7c7f5b30000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000414d254832"
    + String(repeating: "0", count: 64) + "00000000000000000000000015d34aaf54267db7d7c367839aaf71a00a2c6a65"

private func send(recipient: String = me, refund: String = me) throws -> Data {
    try USDT0.send(to: 30111, recipient: recipient, units: 1_000_000, min: 1_000_000, fee: 280_467_163_186, refund: refund)
}

/// The three calls byte for byte as cast encodes them.
@Test func usdt0CallsMatchCast() throws {
    #expect(try send().hex == sendHead + param)
    #expect(try USDT0.quoteSend(to: 30111, recipient: me, units: 1_000_000, min: 1_000_000).hex
            == "3b6f743b" + String(repeating: "0", count: 62) + "40" + String(repeating: "0", count: 64) + param)
    let noFloor = param.replacingOccurrences(of: "f424000000000000000000000000000000000000000000000000000000000000f4240", with: "f4240" + String(repeating: "0", count: 64))
    #expect(try USDT0.quoteOFT(to: 30111, recipient: me, units: 1_000_000).hex == "0d35b415" + String(repeating: "0", count: 62) + "20" + noFloor)
}

/// The signer reads a send for what it is: the tokens to the recipient on the other network, the unused fee to `refund`;
/// LayerZero's fee into one of USDT0's own OFTs isn't a payment to a stranger, anywhere else the contract is a payee.
@Test func oftSendPaysOnlyWhoItSays() throws {
    let call = EVMCall.decode(try send())
    #expect(call == .oftSend(recipient: me, eid: 30111, amount: ABI.uint(1_000_000), plain: true, refund: me))
    #expect(call.refusal(sender: me, chainId: 42161) == nil)
    #expect(Set(call.payees(to: arbitrumOFT, value: 280_467_163_186, chainId: 42161)) == [me])
    // The same call into some other contract, or the Arbitrum OFT's address on another network: that contract is paid.
    #expect(call.payees(to: stranger, value: 1, chainId: 42161).contains(stranger))
    #expect(call.payees(to: arbitrumOFT, value: 1, chainId: 8453).contains(arbitrumOFT))
    // Tokens or the refund to someone else: a payee to approve in person.
    #expect(EVMCall.decode(try send(recipient: stranger)).payees(to: arbitrumOFT, value: 1, chainId: 42161).contains(stranger))
    #expect(EVMCall.decode(try send(refund: stranger)).payees(to: arbitrumOFT, value: 1, chainId: 42161).contains(stranger))
    let prompt = call.summary(chainId: 42161, to: arbitrumOFT, value: 280_467_163_186)
    #expect(prompt.contains("move 1 USDT on Arbitrum") && prompt.contains("on Optimism through LayerZero") && prompt.contains("paying 0.000000280467163186 ETH"))
}

/// Options ride with the fee and can pay a stranger on the other side: such a send is no longer the bridge's plain
/// call, and its contract is a payee like any other. One that can't be read, or pays a non-EVM account, is refused.
@Test func oftSendWithOptionsOrUnreadableIsNotPlain() throws {
    // cast's encoding of the same send with executor options 0x0003010011010000000000000000000000000000ea60.
    let options = Data(hex: sendHead + "000000000000000000000000000000000000000000000000000000000000759f00000000000000000000000015d34aaf54267db7d7c367839aaf71a00a2c6a65"
        + "00000000000000000000000000000000000000000000000000000000000f424000000000000000000000000000000000000000000000000000000000000f4240"
        + "00000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000140"
        + "00000000000000000000000000000000000000000000000000000000000000160003010011010000000000000000000000000000ea6000000000000000000000"
        + String(repeating: "0", count: 2 * 64))!
    let call = EVMCall.decode(options)
    #expect(call == .oftSend(recipient: me, eid: 30111, amount: ABI.uint(1_000_000), plain: false, refund: me))
    #expect(call.payees(to: arbitrumOFT, value: 1, chainId: 42161).contains(arbitrumOFT))

    var solana = try send()
    solana[4 + 5 * 32] = 0x9a   // the recipient's first byte: 32 bytes, not an EVM address
    #expect(EVMCall.decode(solana).refusal(sender: me, chainId: 42161) != nil)
    #expect(EVMCall.decode(try send().prefix(4 + 6 * 32)).refusal(sender: me, chainId: 42161) != nil)
    var astray = try send()
    astray[4 + 31] = 0xa0   // the tuple's offset moved past where it is
    #expect(EVMCall.decode(astray).refusal(sender: me, chainId: 42161) != nil)
}

/// The bridge's networks are the ones the chat form names, each with the USDT the app knows there; only Ethereum's
/// adapter is let spend it.
@Test func usdt0NetworksAreTheAppsOwn() {
    let keys = USDT0.deployments.keys.compactMap { id in EVMNetwork.all.first { $0.rpc.chainId == id }?.key }
    #expect(Set(keys) == Stablecoins.usdt0Networks && keys.count == USDT0.deployments.count)
    for (id, d) in USDT0.deployments {
        let key = EVMNetwork.all.first { $0.rpc.chainId == id }!.key
        #expect(Stablecoins.find("USDT0", on: key)?.address == d.token || Stablecoins.find("USDT", on: key)?.address == d.token)
        #expect(EVMCall.knownSpenders(chainId: id).contains(d.oft) == d.approves)
    }
    #expect(Set(USDT0.deployments.values.map(\.eid)).count == USDT0.deployments.count)
}

/// The executor sends 2 USDT over the USDT0 bridge on an anvil fork (TESTS=forkUSDT0Leaves NET=arbitrum, or
/// NET=ethereum for the adapter and its approve, Tools/fork7702.sh): the call is signed under the signer's rules and
/// goes through, the USDT leaves, and the move is in transit in the journal. The other side is LayerZero's to deliver.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_ANVIL"] != nil))
func forkUSDT0Leaves() async throws {
    let env = ProcessInfo.processInfo.environment
    let chain = UInt64(env["IHATECRYPTO_ANVIL_CHAIN"] ?? "42161")!
    let rpc = EVMRPC(url: URL(string: env["IHATECRYPTO_ANVIL"]!)!, chainId: chain)
    // Arbitrum → Optimism from Aave's aToken, which holds the pool's USDT; Ethereum → Arbitrum from an exchange's wallet.
    let (real, to, holder) = chain == 1 ? (EVMNetwork.ethereum, EVMNetwork.arbitrum, "0xf977814e90da44bfa03b6295a0616a897441acec")
        : (EVMNetwork.arbitrum, EVMNetwork.optimism, "0x6ab707aca953edaefbc4fd23ba73294241490620")
    let net = EVMNetwork(name: real.name, key: real.key, rpc: rpc, usdc: real.usdc, relayChain: real.relayChain, explorer: real.explorer,
                         gasFloor: real.gasFloor, topupUSD: real.topupUSD)
    let key = Data(hex: env["IHATECRYPTO_ANVIL_KEY"]!)!, address = try EVMAccount.address(privateKey: key).lowercased()
    let usdt0 = try #require(USDT0.on(chain))
    _ = try await rpc.call("anvil_setBalance", [holder, "0xde0b6b3a7640000"])
    _ = try await rpc.call("anvil_impersonateAccount", [holder])
    _ = try await rpc.call("eth_sendTransaction", [["from": holder, "to": usdt0.token, "data": "0x" + (try ERC20.transfer(to: address, amount: 5_000_000)).hex]])
    #expect(try await rpc.tokenBalance(usdt0.token, owner: address) == 5_000_000)

    let journal = Journal(url: FileManager.default.temporaryDirectory.appendingPathComponent("forkusdt0-\(UUID().uuidString).jsonl"))
    let e = Executor(wallet: TradeWallet(solana: "", evm: address), signer: ForkSigner(key: key, address: address, batches: false), journal: journal) { print("·", $0) }
    let quote = try #require(await Executor.usdt0Quote(from: net, to: to, units: 2_000_000, recipient: address))
    #expect(quote.arrives == 2_000_000 && quote.fee > 0 && quote.feeUSD < 1)

    let said = try await e.usdt0Bridge(from: net, to: to, usdt: 2)
    print(said)
    #expect(try await rpc.tokenBalance(usdt0.token, owner: address) == 3_000_000)
    #expect(try journal.inTransit().contains { $0.chain == "layerzero" })
    #expect(said.contains("in transit"))
}

/// Reads the bridges as a card would list them (no signing): run with IHATECRYPTO_NET=1. The wallets hold the money a
/// quote moves: Aave's USDT on Arbitrum, and an exchange's USDC on Base with gas on Arbitrum (without gas there Relay
/// is the only way: it brings the gas along).
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func bridgesQuoteWithTheirCostAndTime() async throws {
    func executor(_ holder: String) -> Executor {
        Executor(wallet: TradeWallet(solana: "", evm: holder), signer: ForkSigner(key: Data(count: 32), address: holder, batches: false),
                 journal: Journal(url: FileManager.default.temporaryDirectory.appendingPathComponent("bridges-\(UUID().uuidString).jsonl"))) { print("·", $0) }
    }
    let usdt = try await executor("0x6ab707aca953edaefbc4fd23ba73294241490620").usdtWays(from: .arbitrum, to: .optimism, usdt: 100, layerZero: true)
    print("USDT Arbitrum → Optimism:", usdt)
    #expect(usdt.first?.way == "layerzero" && usdt.contains { $0.way == "relay" })
    // Each line is «what lands · what it costs · how long»; USDT0 lands all of it, for under a cent of gas.
    #expect(usdt.allSatisfy { $0.gets.components(separatedBy: " · ").count == 3 })
    #expect(usdt[0].gets.hasPrefix("100 USDT · $0.") && usdt[0].worth > Decimal(string: "99.99")!)
    let relayFirst = try await executor("0x6ab707aca953edaefbc4fd23ba73294241490620").usdtWays(from: .arbitrum, to: .optimism, usdt: 100, layerZero: false)
    #expect(relayFirst.first?.way == "relay")

    let usdc = try await executor("0x3304e22ddaa22bcdc5fca2269b418046ae7b566a").bridgeWays(from: .base, to: .arbitrum, usdc: 100)
    print("USDC Base → Arbitrum:", usdc)
    #expect(usdc.contains { $0.way == "relay" } && usdc.contains { $0.way == "cctp" })
    #expect(usdc.allSatisfy { $0.gets.components(separatedBy: " · ").count == 3 && $0.worth > 99 })
}
