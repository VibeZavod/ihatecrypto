import EVMChain
import ExecutionCore
import Foundation
import HyperliquidSigning
@testable import OneClickKit
import RelayBridge
import Testing
@testable import TradeExecution
import WalletCore

/// The partner key goes on every 1Click request as X-API-Key, and only when there is one.
@Test func oneClickSendsThePartnerKeyOnlyWhenSet() {
    let url = URL(string: "https://1click.chaindefuser.com/v0/status?depositAddress=x")!
    OneClick.key = nil
    #expect(OneClick.request(url).value(forHTTPHeaderField: "X-API-Key") == nil)
    OneClick.key = "eyJ.test.key"
    #expect(OneClick.request(url).value(forHTTPHeaderField: "X-API-Key") == "eyJ.test.key")
    OneClick.key = ""
    #expect(OneClick.key == nil && OneClick.request(url).value(forHTTPHeaderField: "X-API-Key") == nil)
}

/// Live (IHATECRYPTO_NET=1, a dry quote, no money): 1Click turns a key it doesn't know away with 401, which Settings says in
/// words; without a key the same quote still answers.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func oneClickTurnsAnUnknownKeyAway() async throws {
    let why = await OneClick.problem(withKey: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.abc")
    print("bad key:", why ?? "accepted?")
    #expect(why?.contains("turned the key away (401)") == true)
    OneClick.key = nil
    let q = try await OneClick.quote(dry: true, origin: OneClick.Asset.solanaUSDC, destination: OneClick.Asset.near, amount: "5000000",
                                     refundTo: "7WktogJEd2wQ9eH2oWusmcoFTgeYi6rS632UviTBJ2jm", recipient: String(repeating: "ab", count: 32))   // an implicit NEAR account, as the app's
    print("5 USDC → NEAR without a key:", q.amountOutFormatted)
    #expect(Decimal(string: q.amountOutFormatted) ?? 0 > 0)
}

/// Every state 1Click reports reads in words on the running card.
@Test func oneClickStatesReadInWords() {
    for state in ["PENDING_DEPOSIT", "KNOWN_DEPOSIT_TX", "INCOMPLETE_DEPOSIT", "PROCESSING", "SUCCESS", "REFUNDED", "FAILED"] {
        #expect(!(Executor.oneClickWords[state] ?? "").isEmpty, "\(state)")
    }
}

/// Live (IHATECRYPTO_NET=1, dry, no money): 1Click quotes NEAR into USDC at an EVM address on Base, Arbitrum and Ethereum.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func oneClickPaysNearSalesOnEVMNetworks() async throws {
    for net in ["base", "arbitrum", "ethereum"] {
        let q = try await OneClick.quote(dry: true, origin: OneClick.Asset.near, destination: try #require(OneClick.Asset.usdc(onEVM: net)),
                                         amount: "1000000000000000000000000", refundTo: String(repeating: "ab", count: 32),
                                         recipient: "0x00000000000000000000000000000000000f0a11")
        print("1 NEAR → USDC on \(net): \(q.amountOutFormatted), ≈ \(q.timeEstimate ?? -1) s")
        #expect(Decimal(string: q.amountOutFormatted) ?? 0 > 0)
    }
}

/// 1Click's USDC on each place the bridges compare it on: Solana, Base, Arbitrum, Ethereum — not Polygon or Robinhood.
@Test func oneClickUSDCOnTheBridgedPlaces() {
    #expect(Executor.oneClickUSDC(nil) == OneClick.Asset.solanaUSDC)
    for net in ["base", "arbitrum", "ethereum"] { #expect(Executor.oneClickUSDC(net) == OneClick.Asset.usdc(onEVM: net)) }
    #expect(Executor.oneClickUSDC("polygon") == nil && Executor.oneClickUSDC("robinhood") == nil)
}

/// Live (IHATECRYPTO_NET=1, dry quotes, no money): Relay and 1Click quoted for the same USDC moves, the one the bridge
/// would take printed — each quotes every pair it serves.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func relayAndOneClickQuoteTheSameMoves() async throws {
    let me = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC", sol = "7WktogJEd2wQ9eH2oWusmcoFTgeYi6rS632UviTBJ2jm"
    let e = Executor(wallet: TradeWallet(solana: sol, evm: me), signer: OneClickQuoteOnly(),
                     journal: Journal(url: FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString).jsonl"))) { _ in }
    for (from, to, units) in [("base", nil, UInt64(5_000_000)), (nil, "arbitrum", 5_000_000), ("arbitrum", "base", 20_000_000), ("base", nil, 200_000_000)] as [(String?, String?, UInt64)] {
        let oc = await e.oneClickQuote(from: from, to: to, units: units)
        let fromNet = from.flatMap(EVMNetwork.named), toNet = to.flatMap(EVMNetwork.named)
        let relay = try? await Relay.quote(user: from == nil ? sol : me, recipient: to == nil ? sol : me,
                                           originChain: fromNet?.relayChain ?? Relay.Chain.solana, destinationChain: toNet?.relayChain ?? Relay.Chain.solana,
                                           originCurrency: fromNet?.usdc ?? Relay.Currency.solanaUSDC, destinationCurrency: toNet?.usdc ?? Relay.Currency.solanaUSDC, amount: units)
        print("\(Decimal(units) / 1_000_000) USDC \(from ?? "solana") → \(to ?? "solana"): Relay \(relay?.amountOutFormatted ?? "—") · 1Click \(oc?.amountOutFormatted ?? "—") (≈ \(oc?.timeEstimate ?? -1) s)")
        #expect(oc != nil && relay != nil)
    }
}

private struct OneClickQuoteOnly: TradeSigner {
    func signSolana(_ wire: Data, accounts: [String], recipients: [String], tokenOwners: [String: String]) async throws -> Data { throw ExecutionError("no") }
    func signHyperliquid(_ action: MsgPack, nonce: UInt64) async throws -> EVMSignature { throw ExecutionError("no") }
    func signHyperliquidUser(_ action: MsgPack, recipients: [String]) async throws -> EVMSignature { throw ExecutionError("no") }
    func signRelayMapping(wallet: String, depositor: String, id: Data, nonce: UInt64) async throws -> EVMSignature { throw ExecutionError("no") }
    func signEVM(chainId: UInt64, nonce: UInt64, maxPriorityFee: UInt64, maxFee: UInt64, gasLimit: UInt64, to: String, data: Data,
                 recipients: [String]) async throws -> Data { throw ExecutionError("no") }
    func signNearIntentDeposit(amount: UInt128, depositAddress: String, nonce: UInt64, blockHash: Data) async throws -> Data { throw ExecutionError("no") }
}

/// 1Click is taken over Relay only for an edge worth another Touch ID: 10 cents, or 0.05% of a bigger move.
@Test func oneClickNeedsAnEdgeOverRelay() {
    #expect(Executor.oneClickEdge(5) == Decimal(string: "0.10")!)
    #expect(Executor.oneClickEdge(200) == Decimal(string: "0.10")!)
    #expect(Executor.oneClickEdge(1000) == Decimal(string: "0.5")!)
}
