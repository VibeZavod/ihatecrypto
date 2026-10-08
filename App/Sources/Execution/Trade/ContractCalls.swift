import EVMChain
import Foundation
import IhatecryptoCore
import LLMCore
import WalletCore

/// What the network's explorer says about a contract the chat wants to call: a contract at all, its source (and a
/// proxy's implementation) published and verified, its name and its age. Blockscout's; none for a network without one.
public struct ContractTrust: Sendable, Equatable {
    public var isContract = false
    public var verified = false
    public var name: String?
    /// The code behind a proxy, by name (Blockscout names only a verified one).
    public var implementation: String?
    public var days: Int?
    /// No explorer for this network, or it didn't answer: nothing is known.
    public var unknown = false

    static let browser = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"]

    public static func check(_ address: String, on network: String) async -> ContractTrust {
        guard let host = Holdings.blockscout[network],
              let data = try? await HTTP.get("https://\(host)/api/v2/addresses/\(address)", headers: browser, timeout: 15),
              let a = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ContractTrust(unknown: true) }
        var t = ContractTrust()
        t.isContract = a["is_contract"] as? Bool ?? false
        t.verified = a["is_verified"] as? Bool ?? false
        t.name = a["name"] as? String
        if let impl = (a["implementations"] as? [[String: Any]])?.first {
            t.implementation = impl["name"] as? String
            if t.implementation == nil { t.verified = false }
        }
        if let tx = a["creation_transaction_hash"] as? String,
           let d = try? await HTTP.get("https://\(host)/api/v2/transactions/\(tx)", headers: browser, timeout: 15),
           let stamp = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["timestamp"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) {
                t.days = Int(Date().timeIntervalSince(date) / 86_400)
            }
        }
        return t
    }

    /// «verified · FluidVault (proxy → FluidVaultT1) · 412 days»
    public var line: String {
        if unknown { return "not checked: no explorer answered for this network" }
        if !isContract { return "not a contract" }
        return (verified ? "verified source" : "unverified source") + (name.map { " · \($0)" } ?? "")
            + (implementation.map { " (proxy → \($0))" } ?? "") + (days.map { " · \($0) days old" } ?? "")
    }
}

extension Executor {
    /// A contract call the chat wrote and the user confirmed: its exact approve first when it has one (with the call as
    /// one transaction where batches are on), then the call. The contract is passed as a recipient when the approve lets
    /// it spend or coins go with the call: the signer asks for it in person, address whole, the first time.
    public func contractCall(_ net: EVMNetwork, to: String, data: Data, value: UInt64, approve: (token: String, units: Decimal)?,
                             approveNote: String, note: String) async throws -> String {
        let hash: String
        if let a = approve {
            hash = try await approveAndSend(net.rpc, token: a.token, spender: to, units: a.units, approveNote: approveNote,
                                            to: to, data: data, note: note, recipients: [to])
        } else {
            hash = try await sendEVM(net.rpc, to: to, data: data, note: note, recipients: value > 0 ? [to] : [], value: value)
        }
        return "\(note): done. \(net.explorer)/tx/\(hash)"
    }
}
