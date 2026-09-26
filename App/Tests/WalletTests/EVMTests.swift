import EVMChain
import Foundation
import Testing
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
    // An exact approve passes the guard's calldata check; Aave's supply is an ordinary contract call.
    #expect(EVMCall.decode(try ERC20.approve(spender: AaveV3.basePool, amount: 2_000_000)).refusal(sender: me) == nil)
    #expect(EVMCall.decode(supply).refusal(sender: me) == nil)
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
