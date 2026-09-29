import EVMChain
import Foundation
import Testing
@testable import TradeExecution
import WalletCore

@Test func rlpMatchesTheYellowPaperExamples() {
    #expect(RLP.bytes(Data("dog".utf8)).encoded.hex == "83646f67")
    #expect(RLP.list([.bytes(Data("cat".utf8)), .bytes(Data("dog".utf8))]).encoded.hex == "c88363617483646f67")
    #expect(RLP.bytes(Data()).encoded.hex == "80")
    #expect(RLP.list([]).encoded.hex == "c0")
    #expect(RLP.uint(0).encoded.hex == "80")
    #expect(RLP.uint(15).encoded.hex == "0f")
    #expect(RLP.uint(1024).encoded.hex == "820400")
    let lorem = "Lorem ipsum dolor sit amet, consectetur adipisicing elit"
    #expect(RLP.bytes(Data(lorem.utf8)).encoded.prefix(2).hex == "b838")
}

@Test func erc20TransferCalldata() throws {
    let data = try ERC20.transfer(to: "0x2df1c51e09aecf9cacb7bc98cb1742757f163df7", amount: 5_000_000)
    #expect(data.hex == "a9059cbb" + "0000000000000000000000002df1c51e09aecf9cacb7bc98cb1742757f163df7"
                     + "00000000000000000000000000000000000000000000000000000000004c4b40")
}

@Test func signedTransactionIsType2AndSignedByTheKey() throws {
    let key = Data(repeating: 0x46, count: 32)
    let tx = EVMTransaction(chainId: 42161, nonce: 0, maxPriorityFeePerGas: 0, maxFeePerGas: 20_000_000, gasLimit: 21_000,
                            to: "0x3535353535353535353535353535353535353535", value: 1_000_000_000_000, data: Data())
    let (raw, hash) = try tx.signed(privateKey: key)
    #expect(raw.first == 0x02)
    #expect(hash.count == 66)
    #expect(tx.maxFee == 420_000_000_000)
}

/// Hyperliquid's «Enable trading» as its site sends it: the digest from the site's JSON must be the one our own
/// signer computes for the same approveAgent, and a Permit must be recognised as a spending permission.
@Test func typedDataFromASiteMatchesOurOwnSigner() throws {
    let key = Data(repeating: 1, count: 32)
    let agent = "0x" + String(repeating: "ab", count: 20)
    let json = #"""
    {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],
      "HyperliquidTransaction:ApproveAgent":[{"name":"hyperliquidChain","type":"string"},{"name":"agentAddress","type":"address"},{"name":"agentName","type":"string"},{"name":"nonce","type":"uint64"}]},
     "primaryType":"HyperliquidTransaction:ApproveAgent",
     "domain":{"name":"HyperliquidSignTransaction","version":"1","chainId":421614,"verifyingContract":"0x0000000000000000000000000000000000000000"},
     "message":{"hyperliquidChain":"Mainnet","agentAddress":"\#(agent)","agentName":"web","nonce":1700000000000}}
    """#
    let parsed = try TypedData.parse(Data(json.utf8))
    #expect(!parsed.isTokenPermission && parsed.fields.count == 4)
    // Same fields through our own EIP-712 path, domain chainId 421614 as the site sent it.
    let reference = try EIP712.digest(
        domain: [.init("name", "string", .string("HyperliquidSignTransaction")), .init("version", "string", .string("1")),
                 .init("chainId", "uint256", .uint(421614)), .init("verifyingContract", "address", .address("0x0000000000000000000000000000000000000000"))],
        type: "HyperliquidTransaction:ApproveAgent",
        message: [.init("hyperliquidChain", "string", .string("Mainnet")), .init("agentAddress", "address", .address(agent)),
                  .init("agentName", "string", .string("web")), .init("nonce", "uint64", .uint(1_700_000_000_000))])
    #expect(parsed.digest == reference)
    #expect(try EVMSigner.sign(digest: parsed.digest, privateKey: key) == EVMSigner.sign(digest: reference, privateKey: key))

    let permit = #"""
    {"types":{"Permit":[{"name":"owner","type":"address"},{"name":"spender","type":"address"},{"name":"value","type":"uint256"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}]},
     "primaryType":"Permit","domain":{"name":"USD Coin","version":"2","chainId":1,"verifyingContract":"0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"},
     "message":{"owner":"\#(agent)","spender":"0x000000000000000000000000000000000000dEaD","value":"115792089237316195423570985008687907853269984665640564039457584007913129639935","nonce":0,"deadline":"99999999999"}}
    """#
    #expect(try TypedData.parse(Data(permit.utf8)).isTokenPermission)   // max uint256 parsed, and refused as a permission
    #expect(PersonalMessage.isBlindHash(Data(repeating: 0xaa, count: 32)))
    #expect(!PersonalMessage.isBlindHash(Data("Sign in to example.com at 2026-09-25".utf8)))
}

@Test func calldataDecodingRefusesTheDrainersTools() throws {
    let me = "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955"
    let spender = String(repeating: "5c", count: 20)
    func word(_ hex: String) -> String { String(repeating: "0", count: 64 - hex.count) + hex }
    let exact = try #require(Data(hex: "095ea7b3" + word(spender) + word("f4240")))
    #expect(EVMCall.decode(exact) == .approve(spender: "0x" + spender, amount: Data(hex: word("f4240"))!))
    #expect(EVMCall.decode(exact).refusal(sender: me) == nil)
    let unlimited = try #require(Data(hex: "095ea7b3" + word(spender) + String(repeating: "f", count: 64)))
    #expect(EVMCall.decode(unlimited).refusal(sender: me) != nil)
    #expect(EVMCall.decode(Data(hex: "a22cb465" + word(spender) + word("1"))!).refusal(sender: me) != nil)
    #expect(EVMCall.decode(Data(hex: "a22cb465" + word(spender) + word("0"))!).refusal(sender: me) == nil)   // revoking is fine
    #expect(EVMCall.decode(Data(hex: "23b872dd" + word(String(me.dropFirst(2)).lowercased()) + word(spender) + word("1"))!).refusal(sender: me) != nil)
    #expect(EVMCall.decode(Data(hex: "d505accf" + word("0"))!).refusal(sender: me) != nil)
    #expect(EVMCall.decode(Data()) == .plain)
}

@Test func aaveCalldata() throws {
    func selector(_ signature: String) -> String { Keccak.hash256(Data(signature.utf8)).prefix(4).hex }
    let me = "0x1523000000000000000000000000000000000001"
    let supply = try AaveV3.supply(asset: EVMRPC.baseUSDC, amount: 2_000_000, onBehalfOf: me)
    #expect(supply.prefix(4).hex == selector("supply(address,uint256,address,uint16)"))
    #expect(supply.count == 4 + 4 * 32)
    #expect(ABI.uint(in: supply.dropFirst(4), word: 1) == 2_000_000)
    #expect(ABI.address(in: Data(supply.dropFirst(4)), word: 2) == me)
    let all = try AaveV3.withdraw(asset: EVMRPC.baseUSDC, amount: nil, to: me)
    #expect(all.prefix(4).hex == selector("withdraw(address,uint256,address)"))
    #expect(Data(all.dropFirst(4)).subdata(in: 32..<64).allSatisfy { $0 == 0xff })
    #expect(AaveV3.getPool.hex == selector("getPool()"))
    #expect(try AaveV3.getReserveData(EVMRPC.baseUSDC).prefix(4).hex == selector("getReserveData(address)"))
    #expect(try ERC20.approve(spender: AaveV3.basePool, amount: 5).prefix(4).hex == selector("approve(address,uint256)"))
    #expect(try ERC20.allowance(owner: me, spender: AaveV3.basePool).prefix(4).hex == selector("allowance(address,address)"))
    // An exact approve passes the guard's calldata check; a supply or withdraw to this wallet passes too.
    #expect(EVMCall.decode(try ERC20.approve(spender: AaveV3.basePool, amount: 2_000_000)).refusal(sender: me) == nil)
    #expect(EVMCall.decode(supply) == .lending(beneficiary: me))
    #expect(EVMCall.decode(supply).refusal(sender: me) == nil)
    #expect(EVMCall.decode(all).refusal(sender: me) == nil)
    // The signer checks whom Aave credits: aTokens or USDC for anyone else are refused.
    let thief = "0x9999999999999999999999999999999999999999"
    #expect(EVMCall.decode(try AaveV3.supply(asset: EVMRPC.baseUSDC, amount: 2_000_000, onBehalfOf: thief)).refusal(sender: me) != nil)
    #expect(EVMCall.decode(try AaveV3.withdraw(asset: EVMRPC.baseUSDC, amount: nil, to: thief)).refusal(sender: me) != nil)
    // 3.8946% APR in ray → ≈ 3.97% APY.
    let apy = AaveV3.apy(rateRay: Decimal(string: "38946000000000000000000000")!)
    #expect(apy > Decimal(string: "3.96")! && apy < Decimal(string: "3.98")!)
}

@Test func relayDepositorySelector() {
    // Relay's v2 depository on EVM chains: the selector LALA checks before signing a Base → Solana deposit.
    #expect(Keccak.hash256(Data("depositErc20(address,address,uint256,bytes32)".utf8)).prefix(4).hex == "e8017952")
}

@Test func uniswapCalldataAndSwapGuard() throws {
    func selector(_ signature: String) -> String { Keccak.hash256(Data(signature.utf8)).prefix(4).hex }
    let me = "0x14dc79964da2c08b23698b3d3cc7ca32193d9955", spcx = "0x4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea"
    #expect(try UniswapV3.getPool(EVMRPC.robinhoodUSDG, spcx, fee: 500).prefix(4).hex == selector("getPool(address,address,uint24)"))
    #expect(try UniswapV3.quoteExactInputSingle(tokenIn: EVMRPC.robinhoodUSDG, tokenOut: spcx, amountIn: 1_000_000, fee: 500).prefix(4).hex
            == selector("quoteExactInputSingle((address,address,uint256,uint24,uint160))"))
    let swap = try UniswapV3.exactInputSingle(tokenIn: EVMRPC.robinhoodUSDG, tokenOut: spcx, fee: 500, recipient: me, amountIn: 1_000_000, amountOutMinimum: 6_600_000_000_000_000)
    #expect(swap.prefix(4).hex == selector("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))"))
    #expect(swap.count == 4 + 7 * 32)
    // The signer's calldata check: a swap that pays this wallet passes, one that pays anyone else is refused.
    #expect(EVMCall.decode(swap).refusal(sender: me) == nil)
    let other = try UniswapV3.exactInputSingle(tokenIn: EVMRPC.robinhoodUSDG, tokenOut: spcx, fee: 500, recipient: "0x0000000000000000000000000000000000000bad", amountIn: 1, amountOutMinimum: 0)
    #expect(EVMCall.decode(other).refusal(sender: me) != nil)
    #expect(AddressCheck.problem(spcx, network: .robinhood) == nil)
}

@Test func morphoVaultCallsUseTheERC4626SelectorsAndPayOnlyUs() throws {
    let me = "0x" + String(repeating: "a", count: 40), other = "0x" + String(repeating: "b", count: 40)
    func selector(_ signature: String) -> Data { Keccak.hash256(Data(signature.utf8)).prefix(4) }
    #expect(try MorphoVault.deposit(assets: 1, receiver: me).prefix(4) == selector("deposit(uint256,address)"))
    #expect(try MorphoVault.withdraw(assets: 1, receiver: me, owner: me).prefix(4) == selector("withdraw(uint256,address,address)"))
    #expect(try MorphoVault.redeem(shares: Data(count: 32), receiver: me, owner: me).prefix(4) == selector("redeem(uint256,address,address)"))
    #expect(try MorphoVault.maxWithdraw(me).prefix(4) == selector("maxWithdraw(address)"))
    #expect(MorphoVault.asset == selector("asset()"))

    #expect(EVMCall.decode(try MorphoVault.deposit(assets: 2_000_000, receiver: me)).refusal(sender: me) == nil)
    #expect(EVMCall.decode(try MorphoVault.deposit(assets: 2_000_000, receiver: other)).refusal(sender: me) != nil)
    #expect(EVMCall.decode(try MorphoVault.redeem(shares: Data(count: 32), receiver: me, owner: me)).refusal(sender: me) == nil)
    #expect(EVMCall.decode(try MorphoVault.redeem(shares: Data(count: 32), receiver: other, owner: me)).refusal(sender: me) != nil)
    #expect(EVMCall.decode(try MorphoVault.withdraw(assets: 1, receiver: me, owner: other)).refusal(sender: me) != nil)
}

@Test func simulationReadsOurBalanceChangesFromTheLogs() throws {
    let me = "0xd8da6bf26964af9d7eed9e03e53415d37aa96045", pad = "0x000000000000000000000000"
    let usdc = "0xaf88d065e77c8cc2239327c5edb3a432268e5831", weth = "0x4200000000000000000000000000000000000006"
    func log(_ address: String, _ topics: [String], _ amount: UInt64 = 0) -> [String: Any] {
        ["address": address, "topics": topics, "data": "0x" + ABI.uint(amount).hex]
    }
    let t = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
    let other = pad + "1111111111111111111111111111111111111111", mine = pad + me.dropFirst(2)
    let logs: [[String: Any]] = [
        log(EVMSimulation.native, [t, mine, other], 3_000),                       // coin out
        log(usdc, [t, other, mine], 5_000_000), log(usdc, [t, mine, other], 1_000_000),
        log(usdc, [t, other, other], 9),                                          // not ours
        log(weth, ["0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c", mine], 7),
        log("0x3333333333333333333333333333333333333333", [t, mine, other, pad + "0000000000000000000000000000000000000001"]),
        log(usdc, ["0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c", mine], 99), // Deposit counts only from WETH9
    ]
    let ok = try EVMSimulation([["calls": [["status": "0x1", "logs": logs]]]], owner: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")
    #expect(ok.revert == nil)
    #expect(ok.changes == [EVMSimulation.native: -3_000, usdc: 4_000_000, weth: 7, "0x3333333333333333333333333333333333333333": -1])
    #expect(ok.nfts == ["0x3333333333333333333333333333333333333333"])
    let reverted = try EVMSimulation([["calls": [["status": "0x0", "logs": [], "error": ["message": "execution reverted: ERC20: transfer amount exceeds balance"]]]]], owner: me)
    #expect(reverted.revert == "execution reverted: ERC20: transfer amount exceeds balance")
    #expect(throws: (any Error).self) { try EVMSimulation(["nope"], owner: me) }
}

@Test func bigTokenAmountsAndUniswapPaths() throws {
    // 256-bit words: a thousand tokens of 18 decimals doesn't fit 64 bits.
    #expect(try ABI.word(0).hex == String(repeating: "0", count: 64))
    #expect(try ABI.word(255).hex.suffix(4) == "00ff")
    #expect(try ABI.word(Decimal(string: "1600000000000000000000")!).hex == "000000000000000000000000000000000000000000000056bc75e2d631000000")
    #expect(ABI.decimal(in: try ABI.word(Decimal(string: "1600000000000000000000")!), word: 0) == Decimal(string: "1600000000000000000000")!)
    #expect(throws: (any Error).self) { try ABI.word(Decimal(string: "1.5")!) }
    #expect(try ERC20.approve(spender: "0x2626664c2603336e57b271c5c0b26f421741e481", units: 5_000_000) == (try ERC20.approve(spender: "0x2626664c2603336e57b271c5c0b26f421741e481", amount: 5_000_000)))
    // USDC → 0.05% → WETH → 0.3% → AERO on Base: 20 + 3 + 20 + 3 + 20 bytes.
    let usdc = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", weth = "0x4200000000000000000000000000000000000006", aero = "0x940181a94a35a4569e4529a3cdfb74e38fd98631"
    let path = try UniswapV3.path([usdc, weth, aero], fees: [500, 3000])
    #expect(path.count == 66 && path.hex == usdc.dropFirst(2) + "0001f4" + weth.dropFirst(2) + "000bb8" + aero.dropFirst(2))
    // exactInput pays whoever the tuple names: the signer's decoder finds that recipient behind the offset.
    let me = "0x2df1c51e09aecf9cacb7bc98cb1742757f163df7", thief = "0x000000000000000000000000000000000000dead"
    let mine = try UniswapV3.exactInput(path: path, recipient: me, amountIn: 5_000_000, amountOutMinimum: Decimal(string: "6000000000000000000")!)
    #expect(mine.prefix(4).hex == "b858183f" && EVMCall.decode(mine) == .swap(recipient: me))
    #expect(EVMCall.decode(mine).refusal(sender: me) == nil)
    let theirs = try UniswapV3.exactInput(path: path, recipient: thief, amountIn: 5_000_000, amountOutMinimum: 1)
    #expect(EVMCall.decode(theirs).refusal(sender: me) != nil)
    // The quote call: selector, offset 0x40, amount, then the path's length and bytes padded to a word.
    let quote = try UniswapV3.quoteExactInput(path: path, amountIn: 5_000_000)
    #expect(quote.prefix(4).hex == "cdca1753" && quote.count == 4 + 32 * 3 + 96)
    #expect(UniswapV3.on(8453)?.router == "0x2626664c2603336e57b271c5c0b26f421741e481" && UniswapV3.on(42161) != nil && UniswapV3.on(1) == nil)
}

@Test func signableNetworks() {
    // Polygon, Ethereum and Tempo join Base, Arbitrum and Robinhood Chain; nothing else is signed.
    #expect(EVMRPC.signable == [1, 137, 42161, 8453, 4663, 4217])
    #expect(EVMRPC.polygon.chainId == 137 && EVMRPC.ethereum.chainId == 1)
}

@Test func aaveMarketsAndMorphoVaults() {
    #expect(AaveV3.market(place: "Aave · Polygon")?.rpc.chainId == 137)
    #expect(AaveV3.market(place: "Aave · BNB") == nil)
    // Arbitrum and Polygon share the pool's address; their aTokens differ, so a market verified on the wrong network fails.
    #expect(AaveV3.arbitrum.pool == AaveV3.polygon.pool && AaveV3.arbitrum.aUSDC != AaveV3.polygon.aUSDC)
    // Each market and vault holds its own network's USDC.
    #expect(AaveV3.markets.allSatisfy { m in m.usdc == [1: EVMRPC.ethereumUSDC, 137: EVMRPC.polygonUSDC, 42161: EVMRPC.arbitrumUSDC, 8453: EVMRPC.baseUSDC][m.rpc.chainId] })
    #expect(MorphoVault.vaults.allSatisfy { v in v.usdc == [1: EVMRPC.ethereumUSDC, 42161: EVMRPC.arbitrumUSDC, 8453: EVMRPC.baseUSDC][v.rpc.chainId] })
    #expect(MorphoVault.vault(place: "Morpho · Ethereum")?.rpc.chainId == 1)
}

@Test func aRoundTripMustPayForItselfWithinHalfAYear() {
    // Ethereum: ≈ $1.90 there and back is more than half a year of 4.3% on 15 USDC (≈ $0.65 a year).
    let ethereum = EVMPlace(name: "Morpho · Ethereum", protocolName: "Morpho", apy: Decimal(string: "4.3")!, supplied: 0, roundTripUSD: Decimal(string: "1.9")!)
    #expect(ethereum.tooCostly(yearly: 15 * Decimal(string: "4.3")! / 100) != nil)
    // Arbitrum: ≈ $0.08 is well under it.
    let arbitrum = EVMPlace(name: "Aave · Arbitrum", protocolName: "Aave", apy: 3, supplied: 0, roundTripUSD: Decimal(string: "0.08")!)
    #expect(arbitrum.tooCostly(yearly: 15 * 3 / 100) == nil)
}

// Tempo: a payment with a memo is checked like any transfer (its payee must be approved), and fees are in USDC units.
@Test func tempoTransferWithMemoAndFees() throws {
    let payee = "0x060b0fb0be9d90557577b3aee480711067149ff0"
    let data = try ERC20.transfer(to: payee, amount: 60_000, memo: Data(repeating: 0xab, count: 32))
    #expect(data.count == 4 + 96 && data.prefix(4).hex == "95777d59")
    #expect(EVMCall.decode(data) == .transfer(to: payee, amount: ABI.uint(60_000)))
    #expect(throws: (any Error).self) { try ERC20.transfer(to: payee, amount: 1, memo: Data([1])) }
    #expect(try Tempo.setUserToken(EVMRPC.tempoUSDC).hex == "e7897444" + String(repeating: "0", count: 24) + EVMRPC.tempoUSDC.dropFirst(2))
    #expect(Tempo.feeUnits(1_000_000_000_000) == 1 && Tempo.feeUnits(1_000_000_000_001) == 2 && Tempo.feeUnits(0) == 0)
    #expect(EVMRPC.signable.contains(EVMRPC.tempo.chainId))
}

/// Merkl's claim: the calldata matches Foundry's `cast calldata` for the same arguments (two rewards, proofs of two
/// lengths), the signer reads back whom it pays and refuses a claim for anyone else, and the API's answer keeps only
/// what is left to claim for this wallet.
@Test func merklClaim() throws {
    let me = "0x14dc79964da2c08b23698b3d3cc7ca32193d9955", other = "0x" + String(repeating: "5c", count: 20)
    func reward(_ token: String, _ amount: String, _ proofs: [String]) -> Merkl.Reward {
        Merkl.Reward(chainId: 8453, token: token, symbol: "T", decimals: 18, amount: Decimal(string: amount)!, claimed: 0, proofs: proofs, root: "0x", price: nil)
    }
    let a = "0x" + String(repeating: "aa", count: 32), b = "0x" + String(repeating: "bb", count: 32), c = "0x" + String(repeating: "cc", count: 32)
    let rewards = [reward("0xbaa5cc21fd487b8fcc2f632f3f4e8d37262a0842", "4920135994870910511487", [a, b]),
                   reward(EVMRPC.baseUSDC, "1500000", [c])]
    let data = try Merkl.claim(user: me, rewards)
    // cast calldata "claim(address[],address[],uint256[],bytes32[][])" "[me,me]" "[MORPHO,USDC]" "[4920135994870910511487,1500000]" "[[a,b],[c]]"
    let cast = "71ee95c0" + [
        "80", "e0", "140", "1a0",
        "2", String(me.dropFirst(2)), String(me.dropFirst(2)),
        "2", "baa5cc21fd487b8fcc2f632f3f4e8d37262a0842", String(EVMRPC.baseUSDC.dropFirst(2)),
        "2", "10ab89a73565dc5697f", "16e360",
        "2", "40", "a0", "2", String(a.dropFirst(2)), String(b.dropFirst(2)), "1", String(c.dropFirst(2)),
    ].map { String(repeating: "0", count: 64 - $0.count) + $0 }.joined()
    #expect(data.hex == cast)
    #expect(data.prefix(4).hex == Keccak.hash256(Data("claim(address[],address[],uint256[],bytes32[][])".utf8)).prefix(4).hex)
    #expect(EVMCall.decode(data) == .claim(recipients: [me, me]))
    #expect(EVMCall.decode(data).refusal(sender: me) == nil)
    #expect(EVMCall.decode(try Merkl.claim(user: other, rewards)).refusal(sender: me) != nil)
    #expect(Keccak.hash256(Data("getMerkleRoot()".utf8)).prefix(4).hex == "49590657")

    let json = """
    [{"chain": {"id": 8453}, "rewards": [
      {"root": "0x1f", "recipient": "\(me.uppercased().replacingOccurrences(of: "0X", with: "0x"))", "amount": "4920135994870910511487", "claimed": "4502475146340745774208",
       "pending": "0", "proofs": ["\(a)"], "token": {"chainId": 8453, "address": "0xbaa5", "decimals": 18, "symbol": "MORPHO", "price": 2.5}},
      {"root": "0x1f", "recipient": "\(me)", "amount": "7", "claimed": "7", "pending": "0", "proofs": [],
       "token": {"chainId": 8453, "address": "0xusdc", "decimals": 6, "symbol": "USDC", "price": 1}},
      {"root": "0x1f", "recipient": "\(other)", "amount": "9", "claimed": "0", "pending": "0", "proofs": [],
       "token": {"chainId": 8453, "address": "0xusdc", "decimals": 6, "symbol": "USDC", "price": 1}}
    ]}]
    """
    let owed = try Merkl.parse(Data(json.utf8), user: me)
    #expect(owed.count == 1)
    #expect(owed.first?.symbol == "MORPHO")
    #expect(owed.first?.claimable == Decimal(string: "417.660848530164737279"))
}
