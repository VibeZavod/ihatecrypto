import Foundation
import HyperliquidSigning
import Testing
import WalletCore

private func hex(_ s: String) -> Data { Data(hex: s)! }
private let abandon = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
private let hardhat = "test test test test test test test test test test test junk"

// MARK: Primitives

@Test func keccakMatchesEthereumVectors() {
    #expect(Keccak.hash256(Data()).hex == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    #expect(Keccak.hash256(Data("abc".utf8)).hex == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
    // Crosses the 136-byte block boundary.
    #expect(Keccak.hash256(Data(repeating: 0x61, count: 200)).count == 32)
}

@Test func base58MatchesBitcoinAlphabet() {
    #expect(Base58.encode(hex("0000287fb4cd")) == "11233QC4")
    #expect(Base58.encode(Data("hello world".utf8)) == "StV1DL6CwTryKyV")
}

// MARK: BIP-39

@Test func mnemonicSeedMatchesTrezorVector() throws {
    let seed = try Mnemonic.seed(abandon, passphrase: "TREZOR")
    #expect(seed.hex == "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04")
}

@Test func mnemonicRejectsBadChecksumUnknownWordAndCount() {
    #expect(throws: WalletError.self) { try Mnemonic.validate(Array(repeating: "abandon", count: 12).joined(separator: " ")) }
    #expect(throws: WalletError.self) { try Mnemonic.validate(abandon.replacingOccurrences(of: "about", with: "abut")) }
    #expect(throws: WalletError.self) { try Mnemonic.validate("abandon about") }
    #expect((try? Mnemonic.validate("  Abandon ABANDON abandon abandon abandon abandon abandon abandon abandon abandon abandon about ")) == abandon)
}

// MARK: Addresses the user already knows

@Test func evmAddressesMatchMetaMaskAndHardhat() throws {
    let seed = try Mnemonic.seed(hardhat)
    // Hardhat's default accounts #0 and #1.
    #expect(try EVMAccount.address(privateKey: Derivation.secp256k1(seed: seed, path: WalletPath.evm(0))) == "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")
    #expect(try EVMAccount.address(privateKey: Derivation.secp256k1(seed: seed, path: WalletPath.evm(1))) == "0x70997970C51812dc3A010C7d01b50e0d17dc79C8")
}

@Test func solanaAddressesMatchPhantom() throws {
    // Expected values computed independently with Node's crypto (SLIP-0010 + ed25519).
    let seed = try Mnemonic.seed(abandon)
    #expect(try SolanaAccount.address(privateKey: Derivation.ed25519(seed: seed, path: WalletPath.solana(0))) == "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")
    #expect(try SolanaAccount.address(privateKey: Derivation.ed25519(seed: seed, path: WalletPath.solana(1))) == "Hh8QwFUA6MtVu1qAoq12ucvFHNwCcVTV7hpWjeY1Hztb")
}

@Test func slip10MatchesSpecVector() throws {
    let seed = hex("000102030405060708090a0b0c0d0e0f")
    #expect(try Derivation.ed25519(seed: seed, path: "m").hex == "2b4be7f19ee27bbf30c667b642d5f4aa69fd169872f8fc3059c08ebae2eb19e7")
    #expect(try Derivation.ed25519(seed: seed, path: "m/0'").hex == "68e0fe46dfb67e368c75379acec591dad19df3cde26e63b93a8e704f1dade7a3")
    #expect(throws: WalletError.self) { try Derivation.ed25519(seed: seed, path: "m/0") }
}

// MARK: Hyperliquid, vectors from hyperliquid-python-sdk tests/signing_test.py

private let sdkKey = hex("0x0123456789012345678901234567890123456789012345678901234567890123")

/// The SDK prints r and s as integers, so leading zeros are dropped; compare numerically.
private func same(_ sig: EVMSignature, r: String, s: String, v: Int) -> Bool {
    func trim(_ h: String) -> String { String(h.drop(while: { $0 == "0" })) }
    return trim(sig.r.hex) == trim(String(r.dropFirst(2))) && trim(sig.s.hex) == trim(String(s.dropFirst(2))) && sig.v == v
}

private func order(_ kind: HLOrder.Kind, cloid: String? = nil) throws -> MsgPack {
    try HLAction.order([HLOrder(asset: 1, isBuy: true, price: 100, size: 100, reduceOnly: false, kind: kind, cloid: cloid)])
}

@Test func phantomAgentMatchesProduction() throws {
    let action = try HLAction.order([HLOrder(
        asset: 4, isBuy: true, price: Decimal(string: "1670.1")!, size: Decimal(string: "0.0147")!,
        reduceOnly: false, kind: .limit(tif: "Ioc")
    )])
    #expect(try HLSigner.actionHash(action, vault: nil, nonce: 1677777606040).hex == "0fcbeda5ae3c4950a548021552a4fea2226858c4453571bf3f24ba017eac2908")
}

@Test func l1SigningMatchesSDK() throws {
    let dummy = MsgPack.map([("type", .string("dummy")), ("num", .uint(100_000_000_000))])
    #expect(same(try HLSigner.signL1(dummy, privateKey: sdkKey, nonce: 0, mainnet: true),
                 r: "0x53749d5b30552aeb2fca34b530185976545bb22d0b3ce6f62e31be961a59298",
                 s: "0x755c40ba9bf05223521753995abb2f73ab3229be8ec921f350cb447e384d8ed8", v: 27))
    #expect(same(try HLSigner.signL1(dummy, privateKey: sdkKey, nonce: 0, mainnet: false),
                 r: "0x542af61ef1f429707e3c76c5293c80d01f74ef853e34b76efffcb57e574f9510",
                 s: "0x17b8b32f086e8cdede991f1e2c529f5dd5297cbe8128500e00cbaf766204a613", v: 28))
    let vault = "0x1719884eb866cb12b2287399b15f7db5e7d775ea"
    #expect(same(try HLSigner.signL1(dummy, privateKey: sdkKey, vault: vault, nonce: 0, mainnet: true),
                 r: "0x3c548db75e479f8012acf3000ca3a6b05606bc2ec0c29c50c515066a326239",
                 s: "0x4d402be7396ce74fbba3795769cda45aec00dc3125a984f2a9f23177b190da2c", v: 28))
}

@Test func orderSigningMatchesSDK() throws {
    let limit = try order(.limit(tif: "Gtc"))
    #expect(same(try HLSigner.signL1(limit, privateKey: sdkKey, nonce: 0, mainnet: true),
                 r: "0xd65369825a9df5d80099e513cce430311d7d26ddf477f5b3a33d2806b100d78e",
                 s: "0x2b54116ff64054968aa237c20ca9ff68000f977c93289157748a3162b6ea940e", v: 28))
    #expect(same(try HLSigner.signL1(limit, privateKey: sdkKey, nonce: 0, mainnet: false),
                 r: "0x82b2ba28e76b3d761093aaded1b1cdad4960b3af30212b343fb2e6cdfa4e3d54",
                 s: "0x6b53878fc99d26047f4d7e8c90eb98955a109f44209163f52d8dc4278cbbd9f5", v: 27))

    let withCloid = try order(.limit(tif: "Gtc"), cloid: "0x00000000000000000000000000000001")
    #expect(same(try HLSigner.signL1(withCloid, privateKey: sdkKey, nonce: 0, mainnet: true),
                 r: "0x41ae18e8239a56cacbc5dad94d45d0b747e5da11ad564077fcac71277a946e3",
                 s: "0x3c61f667e747404fe7eea8f90ab0e76cc12ce60270438b2058324681a00116da", v: 27))

    let stopLoss = try order(.trigger(price: 103, isMarket: true, tpsl: "sl"))
    #expect(same(try HLSigner.signL1(stopLoss, privateKey: sdkKey, nonce: 0, mainnet: true),
                 r: "0x98343f2b5ae8e26bb2587daad3863bc70d8792b09af1841b6fdd530a2065a3f9",
                 s: "0x6b5bb6bb0633b710aa22b721dd9dee6d083646a5f8e581a20b545be6c1feb405", v: 27))
    #expect(same(try HLSigner.signL1(stopLoss, privateKey: sdkKey, nonce: 0, mainnet: false),
                 r: "0x971c554d917c44e0e1b6cc45d8f9404f32172a9d3b3566262347d0302896a2e4",
                 s: "0x206257b104788f80450f8e786c329daa589aa0b32ba96948201ae556d5637eac", v: 28))
}

@Test func userSignedTransferMatchesSDK() throws {
    let sig = try HLSigner.signUserAction("UsdSend", fields: [
        .init("destination", "string", .string("0x5e9ee1089755c3435139848e47e6635505d5a13a")),
        .init("amount", "string", .string("1")),
        .init("time", "uint64", .uint(1_687_816_341_423)),
    ], privateKey: sdkKey, mainnet: false)
    #expect(same(sig, r: "0x637b37dd731507cdd24f46532ca8ba6eec616952c56218baeff04144e4a77073",
                 s: "0x11a6a24900e6e314136d2592e2f8d502cd89b7c15b198e1bee043c9589f9fad7", v: 27))
}

@Test func wireNumbersMatchSDKFormat() throws {
    #expect(try HLAction.number(100) == "100")
    #expect(try HLAction.number(Decimal(string: "1670.1")!) == "1670.1")
    #expect(try HLAction.number(Decimal(string: "0.0147")!) == "0.0147")
    #expect(try HLAction.number(Decimal(string: "0.00001231")!) == "0.00001231")
    #expect(throws: WalletError.self) { try HLAction.number(Decimal(string: "0.000012312")!) }
}

@Test func mnemonicGenerationMatchesTrezorVectors() throws {
    #expect(Mnemonic.generate(entropy: Data(count: 16)) == abandon)
    #expect(Mnemonic.generate(entropy: hex("7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f")) == "legal winner thank year wave sausage worth useful legal winner thank yellow")
    #expect(Mnemonic.generate(entropy: hex("80808080808080808080808080808080")) == "letter advice cage absurd amount doctor acoustic avoid letter advice cage above")
    #expect(Mnemonic.generate(entropy: Data(repeating: 0xff, count: 16)) == "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong")
    let fresh = Mnemonic.generate()
    #expect(try Mnemonic.validate(fresh) == fresh)
    #expect(fresh != Mnemonic.generate())
}

@Test func pricesFollowHyperliquidTickRules() {
    #expect(HLAction.price(Decimal(string: "2712.1349")!, szDecimals: 4) == Decimal(string: "2712.1")!)
    #expect(HLAction.price(Decimal(string: "84489.7")!, szDecimals: 5) == 84490)
    #expect(HLAction.price(Decimal(string: "0.0123456789")!, szDecimals: 0) == Decimal(string: "0.012346")!)
    #expect(HLAction.size(Decimal(string: "0.00419999")!, szDecimals: 4) == Decimal(string: "0.0041")!)
}

/// Actions cross the XPC boundary as JSON; the signer must hash exactly the bytes the app built.
@Test func msgPackSurvivesJSONWithKeyOrder() throws {
    let (action, _) = try HLSigner.sendAsset(destination: "0x" + String(repeating: "ab", count: 20), sourceDex: "", destinationDex: "spot",
                                             token: "USDC:0x6d1e7cde53ba9467b783cb7c530ce054", amount: "1.5", nonce: 42,
                                             privateKey: Data(repeating: 1, count: 32), mainnet: false)
    let back = try JSONDecoder().decode(MsgPack.self, from: JSONEncoder().encode(action))
    #expect(back.packed == action.packed)
}

@Test func addressBookChecks() {
    // Real addresses: USDC's mint on Solana and a checksummed EVM address.
    #expect(AddressCheck.problem("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", network: .solana) == nil)
    #expect(AddressCheck.problem("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1O", network: .solana) != nil)   // O is not base58
    #expect(AddressCheck.problem("0x742d35Cc6634C0532925a3b844Bc454e4438f44e", network: .ethereum) == nil)
    #expect(AddressCheck.problem("0x742d35Cc6634C0532925a3b844Bc454e4438f44E", network: .ethereum) != nil)   // one letter's case flipped
    #expect(AddressCheck.problem("0x742d35cc6634c0532925a3b844bc454e4438f44e", network: .arbitrum) == nil)   // all lowercase: no checksum
    #expect(AddressCheck.problem("0x2df1c51e09aecf9cacb7bc98cb1742757f163df7", network: .hyperliquid)?.contains("old bridge") == true)
    #expect(AddressCheck.problem("0x742d35Cc6634C0532925a3b844Bc454e4438f44e", network: .solana) != nil)
    let ends = AddressCheck.ends("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
    #expect(ends.start == "EPjF Wdd5" && ends.end == "ZwyT Dt1v")
}
