import Foundation

/// A cheap phishing check: the host against dApps the user is likely to mean. A host one or two letters away
/// from a known one is the classic fake («jup.ag» → «jupp.ag»).
public enum SiteCheck {
    public static let known = ["jup.ag", "raydium.io", "orca.so", "kamino.finance", "kamino.com", "drift.trade", "meteora.ag", "marginfi.com",
                        "app.hyperliquid.xyz", "hyperliquid.xyz", "relay.link", "solscan.io", "phantom.app", "pump.fun", "tensor.trade"]

    public enum Verdict: Equatable, Sendable { case known, lookalike(String), unknown, local }

    public static func check(host: String) -> Verdict {
        let h = host.lowercased()
        if h.isEmpty { return .local }
        if known.contains(where: { h == $0 || h.hasSuffix("." + $0) }) { return .known }
        let base = h.split(separator: ".").suffix(2).joined(separator: ".")
        // A known name as a part of a label anywhere else (jup.ag.claim-airdrop.com, hyperliquid-app.xyz, kamino-finance.app,
        // jup-ag.com) is the other classic fake, and so is any punycode label: letters from another alphabet that look like ours.
        let parts = Set(h.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init))
        if let named = known.first(where: { parts.contains(brand($0)) }) { return .lookalike(named) }
        if h.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) {
            return .lookalike(known.min { distance(base, $0) < distance(base, $1) } ?? known[0])
        }
        if let near = known.first(where: { distance(base, $0) <= 2 || distance(h, $0) <= 2 }) { return .lookalike(near) }
        return .unknown
    }

    /// The name a known site goes by: the label before its top-level domain («hyperliquid» of app.hyperliquid.xyz).
    static func brand(_ domain: String) -> String { String(domain.split(separator: ".").dropLast().last ?? "") }

    /// On MetaMask's phishing list (eth-phishing-detect): the host or any domain above it is blocked, unless the list's
    /// allowlist names one of them («evil.github.io» is blocked by its own entry, not by github.io).
    public static func listed(host: String, blocked: Set<String>, allowed: Set<String>) -> Bool {
        let parts = host.lowercased().split(separator: ".")
        let domains = (0..<max(parts.count - 1, 0)).map { parts[$0...].joined(separator: ".") }
        return !domains.contains(where: allowed.contains) && domains.contains(where: blocked.contains)
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var prev = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return a.isEmpty ? b.count : b.isEmpty ? a.count : row[b.count]
    }
}
