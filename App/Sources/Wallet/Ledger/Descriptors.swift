import Foundation
import WalletCore

/// Ledger's own signed descriptors, fetched the way Ledger Live fetches them: with one, the device shows a USDC transfer
/// or an approval in words («Send 25 USDC», «To AULW…») instead of asking for blind signing. The device checks Ledger's
/// signature on each, so a wrong or tampered descriptor is refused there, never trusted here. Without the network the
/// move still works, blind-signed.
public enum LedgerDescriptors {
    static let cal = "https://crypto-assets-service.api.ledger.com/v1"
    static let names = "https://nft.api.live.ledger.com/v2"

    static func json(_ url: String) async throws -> Any {
        guard let u = URL(string: url) else { throw LedgerError("Bad descriptor address.") }
        var request = URLRequest(url: u, timeoutInterval: 10)
        // Ledger's servers refuse some default user agents.
        request.setValue("ihatecrypto/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LedgerError("Ledger's descriptor service answered \(status).") }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// `descriptor.data` and its production signature from one of Ledger's entries.
    static func signed(_ entry: Any?) throws -> (data: Data, signature: Data) {
        guard let d = (entry as? [String: Any])?["descriptor"] as? [String: Any],
              let data = (d["data"] as? String).flatMap({ Data(hex: $0) }),
              let signature = ((d["signatures"] as? [String: Any])?["prod"] as? String).flatMap({ Data(hex: $0) }) else {
            throw LedgerError("Ledger's descriptor had no signed data.")
        }
        return (data, signature)
    }

    /// The Ethereum app's token payload for `contract` on `chainId`: ticker length ‖ ticker, address, decimals, chain
    /// ‖ Ledger's DER signature.
    public static func erc20(chainId: UInt64, contract: String) async throws -> Data {
        let list = try await json("\(cal)/tokens?chain_id=\(chainId)&contract_address=\(contract.lowercased())&output=ticker,decimals,descriptor") as? [Any]
        guard let entry = list?.first, let ticker = (entry as? [String: Any])?["ticker"] as? String else {
            throw LedgerError("Ledger doesn't list token \(contract) on chain \(chainId).")
        }
        let (data, signature) = try signed(entry)
        return Data([UInt8(ticker.utf8.count)]) + data + signature
    }

    /// Ledger's trusted-name certificate for this model, which the device checks against Ledger's root before it
    /// accepts name descriptors: data ‖ 0x15 ‖ length ‖ signature.
    public static func trustedNameCertificate(model: String?) async throws -> Data {
        let target = switch model {
        case "Nano S": "nanos"
        case "Nano X": "nanox"
        case "Stax": "stax"
        case "Flex": "flex"
        case "Apex": "apexp"
        default: "nanosp"
        }
        let list = try await json("\(cal)/certificates?output=id,descriptor&target_device=\(target)&latest=true&public_key_usage=trusted_name&public_key_id=domain_metadata_key") as? [Any]
        let (data, signature) = try signed(list?.first)
        return data + Data([0x15, UInt8(signature.count)]) + signature
    }

    /// Ledger's signed statement that `tokenAccount` is `owner`'s account for `mint`, bound to the device's `challenge`:
    /// the Solana app then shows the owner as the recipient. A new account (made by the same transaction) is «computed»;
    /// an existing one is looked up.
    public static func solanaTokenAccount(owner: String, mint: String, tokenAccount: String, challenge: Data) async throws -> Data {
        let c = "0x" + challenge.hex
        for url in ["\(names)/solana/computed-token-account/\(owner)/\(mint)?challenge=\(c)", "\(names)/solana/owner/\(tokenAccount)?challenge=\(c)"] {
            guard let r = try? await json(url) as? [String: Any], r["tokenAccount"] as? String == tokenAccount,
                  let tlv = (r["signedDescriptor"] as? String).flatMap({ Data(hex: $0) }) else { continue }
            return tlv
        }
        throw LedgerError("Ledger couldn't name the owner of \(tokenAccount).")
    }
}
