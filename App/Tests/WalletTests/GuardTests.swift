import Foundation
import HyperliquidSigning
@testable import SolanaChain
import Testing
import TxGuard
import WalletCore

private let me = "2EUrWmf5xMmWER9BtDbXbGbZjoL7R3eTDMXYR6H6cKPj"
private let deposit = "5P2eQoLncuFMjAmNNF4PspnAXYNaDSE2t1gb5os76Svw"
private let scam = "ScamXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX1"
private let unknownProgram = "DrainerProgram1111111111111111111111111111111"

/// A legacy message from readable parts, for feeding the guard hand-made attacks.
private func message(_ keys: [String], _ ixs: [(program: Int, accounts: [Int], data: [UInt8])], signers: UInt8 = 1) throws -> (SolanaMessage, [String]) {
    var m = Data([signers, 0, 0]) + SolanaTransaction.compact(keys.count)
    for key in keys { m += try Base58.decode(key).count == 32 ? try Base58.decode(key) : Data(count: 32) }
    m += Data(count: 32) + SolanaTransaction.compact(ixs.count)
    for ix in ixs {
        m += Data([UInt8(ix.program)]) + SolanaTransaction.compact(ix.accounts.count) + Data(ix.accounts.map(UInt8.init))
        m += SolanaTransaction.compact(ix.data.count) + Data(ix.data)
    }
    let parsed = try SolanaMessage.parse(message: m)
    return (parsed, keys) // keys as given, so fake-but-readable addresses survive
}

private func solTransfer(_ lamports: UInt64) -> [UInt8] { [2, 0, 0, 0] + withUnsafeBytes(of: lamports.littleEndian, Array.init) }
private let policy = SolanaPolicy(owner: me, recipients: [deposit])

@Test func guardPassesATransferToTheApprovedDeposit() throws {
    let (m, accounts) = try message([me, deposit, SolanaGuard.system], [(2, [0, 1], solTransfer(130_000_000))])
    let v = SolanaGuard.check(m, accounts: accounts, policy: policy, tokenOwners: [:])
    #expect(v.ok, "\(v.problems)")
}

@Test func guardStopsAScamRecipient() throws {
    let (m, accounts) = try message([me, scam, SolanaGuard.system], [(2, [0, 1], solTransfer(130_000_000))])
    #expect(SolanaGuard.check(m, accounts: accounts, policy: policy, tokenOwners: [:]).problems.first?.contains(scam) == true)
}

@Test func guardStopsSomeoneElsePayingOrSigning() throws {
    let (m, accounts) = try message([scam, me, SolanaGuard.system], [(2, [0, 1], solTransfer(1))])
    #expect(!SolanaGuard.check(m, accounts: accounts, policy: policy, tokenOwners: [:]).ok)
    let (two, accounts2) = try message([me, scam, SolanaGuard.system], [(2, [0, 1], solTransfer(1))], signers: 2)
    #expect(!SolanaGuard.check(two, accounts: accounts2, policy: policy, tokenOwners: [:]).ok)
}

@Test func guardStopsUnknownProgramsAndTokenApprovals() throws {
    let (drainer, a1) = try message([me, unknownProgram], [(1, [0], [0])])
    #expect(SolanaGuard.check(drainer, accounts: a1, policy: policy, tokenOwners: [:]).problems.first?.contains("not on the allowed list") == true)
    // SPL Approve (tag 4): hands spending rights to someone else.
    let myUSDC = "MyUSDCAccountXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX1"
    let (approve, a2) = try message([me, myUSDC, scam, SPL.tokenProgram], [(3, [1, 2, 0], [4] + withUnsafeBytes(of: UInt64(1).littleEndian, Array.init))])
    #expect(!SolanaGuard.check(approve, accounts: a2, policy: policy, tokenOwners: [myUSDC: me]).ok)
}

@Test func guardChecksTokenTransfersAccountCreationAndClosing() throws {
    let myUSDC = "MyUSDCAccountXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX1"
    let depositUSDC = "DepositUSDCXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX1"
    let scamUSDC = "ScamUSDCXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX1"
    let owners = [myUSDC: me, depositUSDC: deposit]
    let keys = [me, myUSDC, depositUSDC, scamUSDC, deposit, scam, SPL.tokenProgram, SPL.associatedTokenProgram]
    // TransferChecked(source, mint, dest, authority) to the deposit's account: fine; to a scam account: stopped.
    let ok = try message(keys, [(6, [1, 6, 2, 0], [12, 0, 0, 0, 0, 0, 0, 0, 0, 6])])
    #expect(SolanaGuard.check(ok.0, accounts: ok.1, policy: policy, tokenOwners: owners).ok)
    let bad = try message(keys, [(6, [1, 6, 3, 0], [12, 0, 0, 0, 0, 0, 0, 0, 0, 6])])
    #expect(!SolanaGuard.check(bad.0, accounts: bad.1, policy: policy, tokenOwners: owners).ok)
    // Creating a token account for a stranger, closing ours into a stranger's wallet: stopped.
    let create = try message(keys, [(7, [0, 3, 5, 6], [1])])
    #expect(!SolanaGuard.check(create.0, accounts: create.1, policy: policy, tokenOwners: owners).ok)
    let close = try message(keys, [(6, [1, 5, 0], [9])])
    #expect(!SolanaGuard.check(close.0, accounts: close.1, policy: policy, tokenOwners: owners).ok)
}

@Test func guardStopsAnInflatedPriorityFee() throws {
    let limit: [UInt8] = [2] + withUnsafeBytes(of: UInt32(1_400_000).littleEndian, Array.init)
    let price: [UInt8] = [3] + withUnsafeBytes(of: UInt64(50_000_000).littleEndian, Array.init) // 0.07 SOL at the limit
    let (m, accounts) = try message([me, SolanaGuard.computeBudget], [(1, [], limit), (1, [], price)])
    #expect(SolanaGuard.check(m, accounts: accounts, policy: policy, tokenOwners: [:]).problems.first?.contains("Priority fee") == true)
}

@Test func simulatedBalancesCatchARouteThatPaysSomeoneElse() {
    let rule = SolanaGuard.BalanceRule(label: "USDC", before: 1_000_000, after: 1_000_000, atLeast: 2_300_000)
    #expect(!SolanaGuard.balances([rule]).ok)
    #expect(SolanaGuard.balances([.init(label: "USDC", before: 0, after: 2_335_542, atLeast: 2_323_865)]).ok)
}

@Test func hyperliquidGuardAllowsTradingAndOnlyApprovedWithdrawals() {
    let owner = "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955"
    let quoteDeposit = "0xBcd4042DE499D14e55001CcbB24a551F3b954096"
    func action(_ type: String, _ extra: [(String, MsgPack)] = []) -> MsgPack { .map([("type", .string(type))] + extra) }
    #expect(HLGuard.check(action("order"), owner: owner, recipients: []).ok)
    #expect(HLGuard.check(action("spotSend", [("destination", .string(quoteDeposit))]), owner: owner, recipients: [quoteDeposit]).ok)
    #expect(!HLGuard.check(action("spotSend", [("destination", .string("0x000000000000000000000000000000000000dEaD"))]), owner: owner, recipients: [quoteDeposit]).ok)
    #expect(!HLGuard.check(action("vaultTransfer"), owner: owner, recipients: []).ok)
    #expect(!HLGuard.check(action("approveAgent", [("agentAddress", .string("0xBAD"))]), owner: owner, recipients: [], agent: "0xGOOD").ok)
}

@Test func depositGuardRejectsAnAddressBoundToSomeoneElse() {
    let bound = ["recipient": "0xAttacker", "refundTo": me, "originAsset": "nep141:sol.omft.near",
                 "destinationAsset": "hc", "amount": "130000000"]
    let v = DepositGuard.check(bound: bound, recipient: "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955", refundTo: me,
                               origin: "nep141:sol.omft.near", destination: "hc", amount: "130000000")
    #expect(v.problems.count == 1)
    var good = bound
    good["recipient"] = "0x14dc79964da2c08b23698b3d3cc7ca32193d9955"
    #expect(DepositGuard.check(bound: good, recipient: "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955", refundTo: me,
                               origin: "nep141:sol.omft.near", destination: "hc", amount: "130000000").ok)
}

@Test func relayOnlyAcceptsDepositsFromOurWallet() throws {
    let relay = SolanaGuard.relayDepository
    let depositToken: [UInt8] = [0x0b, 0x9c, 0x60, 0xda, 0x27, 0xa3, 0xb4, 0x13] + withUnsafeBytes(of: UInt64(2_000_000).littleEndian, Array.init) + Array(repeating: 1, count: 32)
    let withdraw: [UInt8] = [0xde, 0xad, 0xbe, 0xef, 0, 0, 0, 0] + Array(repeating: 0, count: 8)
    let ok = try message([me, relay], [(1, [0], depositToken)])
    #expect(SolanaGuard.check(ok.0, accounts: ok.1, policy: policy, tokenOwners: [:]).ok)
    let other = try message([me, relay], [(1, [0], withdraw)])
    #expect(!SolanaGuard.check(other.0, accounts: other.1, policy: policy, tokenOwners: [:]).ok)
    let notOurs = try message([me, scam, relay], [(2, [1], depositToken)])
    #expect(!SolanaGuard.check(notOurs.0, accounts: notOurs.1, policy: policy, tokenOwners: [:]).ok)
}

/// The signer has no network, so a lookup table's contents are the app's word: money may not go to an
/// account that only a table names, even an approved one.
@Test func signerRefusesMoneyToAnAccountOnlyALookupTableNames() throws {
    let (m, keys) = try message([me, SolanaGuard.system], [(1, [0, 2], solTransfer(1000))])
    let accounts = keys + [deposit] // index 2 would come from a lookup table
    #expect(SolanaGuard.check(m, accounts: accounts, policy: policy, tokenOwners: [:]).ok)
    var strict = policy
    strict.trustLookupTables = false
    #expect(!SolanaGuard.check(m, accounts: accounts, policy: strict, tokenOwners: [:]).ok)
}

@Test func vaultTransfersGoOnlyToHLP() {
    let me = "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955"
    func transfer(_ vault: String) -> MsgPack {
        .map([("type", .string("vaultTransfer")), ("vaultAddress", .string(vault)), ("isDeposit", .bool(true)), ("usd", .uint(5_000_000))])
    }
    #expect(HLGuard.check(transfer(HLGuard.hlpVault), owner: me, recipients: []).ok)
    #expect(!HLGuard.check(transfer("0x" + String(repeating: "5c", count: 20)), owner: me, recipients: []).ok)
}
