import Foundation

/// Append-only log of everything signed. An entry is written and flushed to disk before the transaction
/// is broadcast, keyed by an id known in advance (Solana signature, Hyperliquid nonce, 1Click deposit
/// address). After a crash, `unresolved()` lists what must be checked on chain instead of being resent.
/// ponytail: one JSON line per event in a file; move to SQLite when the app needs queries over history.
public struct Journal: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case signed, confirmed, failed, expired, settled }

        public let at: Date
        public let chain: String
        public let id: String
        public let kind: Kind
        public let note: String

        public init(at: Date = Date(), chain: String, id: String, kind: Kind, note: String = "") {
            self.at = at
            self.chain = chain
            self.id = id
            self.kind = kind
            self.note = note
        }
    }

    public let url: URL

    public init(url: URL) { self.url = url }

    public func append(_ entry: Entry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(entry)
        line.append(0x0a)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    public func entries() throws -> [Entry] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: 0x0a).map { try decoder.decode(Entry.self, from: Data($0)) }
    }

    /// Signed, but no later confirmed/failed/expired/settled entry for the same chain and id. In file order.
    public func unresolved() throws -> [Entry] {
        var latest: [String: Entry] = [:]
        var order: [String] = []
        for entry in try entries() {
            let key = "\(entry.chain)|\(entry.id)"
            if latest[key] == nil { order.append(key) }
            latest[key] = entry
        }
        return order.compactMap { latest[$0] }.filter { $0.kind == .signed }
    }

    /// Money on its way between networks: a bridge order (Relay's, 1Click's, a CCTP burn, a USDT0 send on LayerZero)
    /// signed within `within` and not yet settled, refunded or failed. The newest first.
    public func inTransit(within: TimeInterval = 86_400, now: Date = Date()) throws -> [Entry] {
        try unresolved().filter { ["relay", "1click", "cctp", "layerzero"].contains($0.chain) && now.timeIntervalSince($0.at) < within }.reversed()
    }
}
