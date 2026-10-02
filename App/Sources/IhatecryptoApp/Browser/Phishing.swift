import Foundation
import IhatecryptoCore

/// MetaMask's list of phishing sites (eth-phishing-detect, about 100,000 domains), read once a day into Application
/// Support/ihatecrypto/phishing.json. A page on it doesn't open in the browser, and it gets no wallet (Browser.swift).
/// Until the first download the list is empty; the lookalike check (SiteCheck.check) runs either way.
final class PhishingList {
    static let shared = PhishingList()
    static let source = URL(string: "https://raw.githubusercontent.com/MetaMask/eth-phishing-detect/main/src/config.json")!
    private var blocked: Set<String> = []
    private var allowed: Set<String> = []
    private var loading = false

    private var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "ihatecrypto/phishing.json")
    }

    func contains(_ host: String) -> Bool { SiteCheck.listed(host: host, blocked: blocked, allowed: allowed) }

    /// The saved copy at once; a new one when it's a day old.
    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let file = file
        if blocked.isEmpty, let lists = await Self.parse(try? Data(contentsOf: file)) { (blocked, allowed) = lists }
        let saved = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard saved.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true,
              let (data, response) = try? await URLSession.shared.data(from: Self.source), (response as? HTTPURLResponse)?.statusCode == 200,
              let lists = await Self.parse(data) else { return }
        try? data.write(to: file, options: .atomic)
        (blocked, allowed) = lists
    }

    /// Off the main thread: 100,000 entries take a moment.
    private static func parse(_ data: Data?) async -> (Set<String>, Set<String>)? {
        guard let data else { return nil }
        return await Task.detached {
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let b = j["blacklist"] as? [String] else { return nil }
            return (Set(b), Set(j["whitelist"] as? [String] ?? []))
        }.value
    }
}
