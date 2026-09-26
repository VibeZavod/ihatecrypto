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
        if let near = known.first(where: { distance(base, $0) <= 2 || distance(h, $0) <= 2 }) { return .lookalike(near) }
        return .unknown
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
