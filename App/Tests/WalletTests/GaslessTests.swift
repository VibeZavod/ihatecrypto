import CryptoKit
import EVMChain
import Foundation
@testable import RelayBridge
@testable import SolanaChain
import Testing
import TxGuard
import WalletCore

// MARK: - Relay's payment by signature (EIP-3009)

/// Hardhat's first public test key and its address.
private let hardhatKey = Data(hex: "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")!
private let hardhat = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
private let relayProxy = "0xccc88a9d1b4ed6b0eaba998850414b24f1c315be"
private let nonce = Data(hex: "1a66a6de1f9f27675cfd809e56c7d573a25922c450f6b56ced9013f360512be7")!

private func permit(chain: UInt64 = 8453, token: String = EVMRPC.baseUSDC, from: String = hardhat, to: String = relayProxy,
                    validBefore: UInt64 = 1_792_706_124) -> Permit3009 {
    Permit3009(chainId: chain, token: token, from: from, to: to, value: 3_000_000, validBefore: validBefore, nonce: nonce)
}

@Test func dollarDomainsMatchTheContracts() throws {
    // DOMAIN_SEPARATOR() read from each contract on 2026-10-23.
    let onChain: [(UInt64, String, String)] = [
        (8453, EVMRPC.baseUSDC, "02fa7265e7c5d81118673727957699e4d68f74cd74b7db77da710fe8a2c7834f"),
        (42161, EVMRPC.arbitrumUSDC, "08d11903f8419e68b1b8721bcbe2e9fc68569122a77ef18c216f10b3b5112c78"),
        (10, EVMRPC.optimismUSDC, "26d9c34bb1a1c312f69c53b2d93b8be20faafba63af2438c6811713c9b1f933f"),
        (137, EVMRPC.polygonUSDC, "caa2ce1a5703ccbe253a34eb3166df60a705c561b44b192061e28f2a985be2ca"),
        (1, EVMRPC.ethereumUSDC, "06c37168a7db5138defc7866392bb87a741f9b3d104deb5094588ce041cae335"),
        (4663, EVMRPC.robinhoodUSDG, "7a3d7400b27830f4f91c2c16a082486d67c1befecaec2f53b33f1f35d5b62036"),
    ]
    for (chain, token, separator) in onChain {
        #expect(try permit(chain: chain, token: token).typed().parts().domain.hex == separator, "\(chain)")
    }
    #expect(Permit3009.tokens.count == onChain.count)
    #expect(!Permit3009.supports(chainId: 56, token: EVMRPC.bnbUSDC) && !Permit3009.supports(chainId: 999, token: EVMRPC.hyperevmUSDC))
}

@Test func paymentBySignatureMatchesFoundry() throws {
    // `cast wallet sign --data` of the same ReceiveWithAuthorization with the same key.
    let signature = try EVMSigner.sign(digest: try permit().typed().parts().digest, privateKey: hardhatKey)
    #expect(signature.r.hex + signature.s.hex == "6e99da39fc03c5e7a931609dedf1f20b1e89827f270ca103cfff9aa1e2934dab2dabf94c0a0783ff6ecaabb2b3eff07dba71e6e4e56d71fad2c477014842e0eb")
    #expect(signature.v == 28)
}

@Test func paymentBySignatureGoesOnlyToRelayForAnHour() {
    let now: UInt64 = 1_792_705_800
    #expect(permit().refusal(owner: hardhat.lowercased(), now: now) == nil)
    #expect(permit(to: "0x5567954cd026cebfe486062cb75848e0f1c12e58").refusal(owner: hardhat, now: now) == nil)
    #expect(permit(to: "0x000000000000000000000000000000000000dead").refusal(owner: hardhat, now: now) != nil)
    #expect(permit(from: "0x9858EfFD232B4033E47d90003D41EC34EcaEda94").refusal(owner: hardhat, now: now) != nil)
    #expect(permit(chain: 56, token: EVMRPC.bnbUSDC).refusal(owner: hardhat, now: now) != nil)
    #expect(permit(token: EVMRPC.arbitrumUSDC).refusal(owner: hardhat, now: now) != nil)  // Arbitrum's USDC named on Base
    #expect(permit(validBefore: now + 3601).refusal(owner: hardhat, now: now) != nil)
    #expect(permit(validBefore: now).refusal(owner: hardhat, now: now) != nil)
}

/// Relay's authorize1 step for 3 USDC from Base, as /quote/v2 gave it with usePermit (2026-10-23, the public test address).
private func relayStep(items: Int = 1) -> [[String: Any]] {
    let item: [String: Any] = ["status": "incomplete", "data": [
        "sign": ["signatureKind": "eip712", "primaryType": "ReceiveWithAuthorization",
                 "domain": ["name": "USD Coin", "version": "2", "chainId": 8453, "verifyingContract": "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"],
                 "value": ["from": "0x9858EfFD232B4033E47d90003D41EC34EcaEda94", "to": relayProxy, "value": "3000000", "validAfter": 0,
                           "validBefore": 1_792_706_124, "nonce": "0x" + nonce.hex]],
        "post": ["endpoint": "/execute/permits", "method": "POST",
                 "body": ["kind": "eip3009", "requestId": "0x1792705524576d6b75c5353aa74b090990ce6143da4bf85d9c2661c7481d4793", "api": "swap"]],
    ]]
    return [["id": "authorize1", "kind": "signature", "items": Array(repeating: item, count: items)]]
}

@Test func relaysPermitStepIsReadAndAnythingMoreIsNot() throws {
    let p = try #require(Relay.permit(in: relayStep()))
    #expect(p.chainId == 8453 && p.token == EVMRPC.baseUSDC && p.to == relayProxy && p.value == "3000000")
    #expect(p.validAfter == 0 && p.validBefore == 1_792_706_124 && p.nonce == nonce && p.endpoint == "/execute/permits")
    #expect(p.domainName == "USD Coin" && p.domainVersion == "2")
    #expect((try JSONSerialization.jsonObject(with: p.body) as? [String: Any])?["kind"] as? String == "eip3009")
    // Two items (v3.2's MulticallAuthorization first), or an approval step before it: not a payment by signature alone.
    #expect(Relay.permit(in: relayStep(items: 2)) == nil)
    #expect(Relay.permit(in: [["id": "approve", "kind": "transaction", "items": [[String: Any]]()]] + relayStep()) == nil)
}

// MARK: - Jupiter paying a Solana fee

private let ownerKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
private let sponsorKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
private let owner = Base58.encode(ownerKey.publicKey.rawRepresentation)
private let sponsor = Base58.encode(sponsorKey.publicKey.rawRepresentation)
private let stranger = "5P2eQoLncuFMjAmNNF4PspnAXYNaDSE2t1gb5os76Svw"
private let blockhash = "7WktogJEd2wQ9eH2oWusmcoFTgeYi6rS632UviTBJ2jm"

/// A legacy message from readable parts: `signers` keys first (the sponsor, then us), the rest read-only, then System.
private func sponsored(signers: [String], others: [String] = [], _ transfers: [(from: Int, to: Int)], lamports: UInt64 = 1000) throws -> (wire: Data, message: SolanaMessage) {
    let keys = signers + others + [SolanaGuard.system]
    var m = Data([UInt8(signers.count), 0, 1]) + SolanaTransaction.compact(keys.count)
    for key in keys { m += try Base58.decode(key) }
    m += try Base58.decode(blockhash) + SolanaTransaction.compact(transfers.count)
    for t in transfers {
        m += Data([UInt8(keys.count - 1)]) + SolanaTransaction.compact(2) + Data([UInt8(t.from), UInt8(t.to)])
        m += SolanaTransaction.compact(12) + Data([2, 0, 0, 0]) + withUnsafeBytes(of: lamports.littleEndian) { Data($0) }
    }
    return (SolanaTransaction.compact(signers.count) + Data(count: 64 * signers.count) + m, try SolanaMessage.parse(message: m))
}

@Test func guardLetsJupiterPayButChecksWhatWeSign() throws {
    // The sponsor pays a stranger from its own SOL; we send to ourselves.
    let (_, m) = try sponsored(signers: [sponsor, owner], others: [stranger], [(0, 2), (1, 1)])
    let paid = SolanaPolicy(owner: owner, sponsor: sponsor)
    #expect(m.requiredSignatures == 2)
    #expect(SolanaGuard.check(m, accounts: m.staticKeys, policy: paid, tokenOwners: [:]).ok)
    // Without the sponsor named, two signers and someone else paying are refused as before.
    #expect(!SolanaGuard.check(m, accounts: m.staticKeys, policy: SolanaPolicy(owner: owner), tokenOwners: [:]).ok)
    // Another sponsor than the one named, or our SOL to a stranger, stops it.
    #expect(!SolanaGuard.check(m, accounts: m.staticKeys, policy: SolanaPolicy(owner: owner, sponsor: stranger), tokenOwners: [:]).ok)
    let (_, ours) = try sponsored(signers: [sponsor, owner], others: [stranger], [(1, 2)])
    #expect(SolanaGuard.check(ours, accounts: ours.staticKeys, policy: paid, tokenOwners: [:]).problems.contains { $0.contains(stranger) })
    // Back to the sponsor (the rent it fronted, as Jupiter's transaction ends): allowed up to the cap, in sum.
    let (_, back) = try sponsored(signers: [sponsor, owner], [(1, 0)])
    #expect(SolanaGuard.check(back, accounts: back.staticKeys, policy: paid, tokenOwners: [:]).ok)
    #expect(!SolanaGuard.check(back, accounts: back.staticKeys, policy: SolanaPolicy(owner: owner), tokenOwners: [:]).ok)
    let (_, many) = try sponsored(signers: [sponsor, owner], Array(repeating: (1, 0), count: 6))
    #expect(SolanaGuard.check(many, accounts: many.staticKeys, policy: paid, tokenOwners: [:]).ok)  // 6 × 1000 lamports
    let (_, rent) = try sponsored(signers: [sponsor, owner], [(1, 0)], lamports: 1_488_440)  // what Jupiter's took back, 2026-10-23
    #expect(SolanaGuard.check(rent, accounts: rent.staticKeys, policy: paid, tokenOwners: [:]).ok)
    let (_, over) = try sponsored(signers: [sponsor, owner], [(1, 0), (1, 0)], lamports: 2_600_000)
    #expect(SolanaGuard.check(over, accounts: over.staticKeys, policy: paid, tokenOwners: [:]).problems.contains { $0.contains("more than the rent") })
    // Our wallet first, or a third signer, isn't allowed either.
    let (_, swapped) = try sponsored(signers: [owner, sponsor], [(0, 0)])
    #expect(!SolanaGuard.check(swapped, accounts: swapped.staticKeys, policy: paid, tokenOwners: [:]).ok)
    let (_, three) = try sponsored(signers: [sponsor, owner, stranger], [(1, 1)])
    #expect(!SolanaGuard.check(three, accounts: three.staticKeys, policy: paid, tokenOwners: [:]).ok)
}

@Test func ourSignatureGoesInTheSecondSlot() throws {
    let (wire, _) = try sponsored(signers: [sponsor, owner], [(1, 1)])
    let signed = try SolanaTransaction.sign(wire, privateKey: ownerKey.rawRepresentation, sponsor: sponsorKey.publicKey.rawRepresentation).wire
    #expect(signed.prefix(65) == wire.prefix(65) && signed.dropFirst(129) == wire.dropFirst(129))
    #expect(ownerKey.publicKey.isValidSignature(signed.subdata(in: 65..<129), for: Data(wire.dropFirst(129))))
    // Without the sponsor, or with another one, nothing is signed.
    #expect(throws: (any Error).self) { try SolanaTransaction.sign(wire, privateKey: ownerKey.rawRepresentation) }
    #expect(throws: (any Error).self) {
        try SolanaTransaction.sign(wire, privateKey: ownerKey.rawRepresentation, sponsor: try Base58.decode(stranger))
    }
    // A wire with one signature slot for a two-signer message is refused.
    #expect(throws: (any Error).self) {
        try SolanaTransaction.sign(SolanaTransaction.compact(1) + wire.dropFirst(65), privateKey: ownerKey.rawRepresentation,
                                   sponsor: sponsorKey.publicKey.rawRepresentation)
    }
}
