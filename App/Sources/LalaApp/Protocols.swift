import DeFiKamino
import Foundation
import LalaCore
import SwiftUI

/// Money in protocols ihatecrypto doesn't move itself, so a deposit made on a site in the browser still shows: Kamino's
/// vaults (Earn) from Kamino, and Jupiter's other platforms (staked JUP, perps, predictions…) from Jupiter's portfolio.
/// Shown on the portfolio, counted in the total, told to the chat.
struct ProtocolPosition: Equatable, Identifiable {
    var id: String { "\(platform) · \(name)" }
    /// «Kamino», «Jupiter».
    let platform: String
    /// «Allez USDC», «Staked JUP».
    let name: String
    let logo: String
    let usd: Decimal
    /// «5.00 USDC» when the protocol says in what.
    let amount: String?
    /// % a year.
    let apy: Decimal?
    /// Where it's managed, for the chat and the row's help.
    let site: String
}

extension Workspace {
    var protocolUSD: Decimal { protocolPositions.reduce(0) { $0 + $1.usd } }

    /// Read at most every two minutes with the balances; `force` after a site's transaction was signed. A source that
    /// doesn't answer keeps its last reading.
    func loadProtocols(force: Bool = false) async {
        guard force || Date().timeIntervalSince(protocolsReadAt ?? .distantPast) > 120, isSolanaAddress(solanaAddress) else { return }
        protocolsReadAt = Date()
        let wallet = solanaAddress
        async let kamino = try? Kamino.vaultPositions(wallet: wallet)
        async let jupiter = Self.jupiterPositions(wallet)
        let vaults = (await kamino)?.map { v in
            ProtocolPosition(platform: "Kamino", name: v.name, logo: "kamino", usd: v.valueUSD, amount: "\(Fmt.num(v.tokens)) \(v.symbol)",
                             apy: v.apy, site: "kamino.com")
        } ?? protocolPositions.filter { $0.platform == "Kamino" }
        let jup = await jupiter ?? protocolPositions.filter { $0.platform != "Kamino" }
        let found = (vaults + jup).filter { $0.usd >= Decimal(string: "0.01")! }
        if found != protocolPositions { protocolPositions = found }
    }

    /// Jupiter's portfolio API (its own platforms only): every element but Earn, which `lend` already reads. nil when it
    /// doesn't answer.
    static func jupiterPositions(_ wallet: String) async -> [ProtocolPosition]? {
        guard let url = URL(string: "https://api.jup.ag/portfolio/v1/positions/\(wallet)"),
              let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let elements = json["elements"] as? [[String: Any]] else { return nil }
        return elements.compactMap { e in
            guard e["fetcherId"] as? String != "jupiter-exchange-earn", let value = (e["value"] as? NSNumber)?.decimalValue else { return nil }
            let name = [e["name"] as? String, e["label"] as? String].compactMap { $0 }.joined(separator: " · ")
            let apy = (e["netApy"] as? NSNumber)?.decimalValue
            return ProtocolPosition(platform: "Jupiter", name: name.isEmpty ? (e["platformId"] as? String ?? "position") : name, logo: "jup",
                                    usd: value, amount: nil, apy: apy.flatMap { $0 > 0 ? $0 * 100 : nil }, site: "jup.ag")
        }
    }
}
