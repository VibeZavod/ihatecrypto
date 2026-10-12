import ExecutionCore
import Foundation
import OneClickKit
import RelayBridge

extension Executor {
    /// The bridge orders still on their way (Journal.inTransit), each older than two minutes asked of its bridge first:
    /// one that settled, refunded or failed meanwhile — the app closed before it heard — gets its end written to the
    /// journal and drops off. What's left is really in transit, the newest first.
    public func resolveTransit(now: Date = Date()) async -> [Journal.Entry] {
        guard let open = try? journal.inTransit(now: now) else { return [] }
        var left: [Journal.Entry] = []
        for entry in open {
            guard now.timeIntervalSince(entry.at) > 120 else { left.append(entry); continue }
            var end: (kind: Journal.Entry.Kind, status: String)?
            if entry.chain == "relay", let s = try? await Relay.status(requestId: entry.id).status {
                if s == "success" { end = (.settled, s) } else if ["refund", "failure"].contains(s) { end = (.failed, s) }
            } else if entry.chain == "cctp", let colon = entry.id.firstIndex(of: ":"), let source = UInt32(entry.id[..<colon]),
                      let mint = await Self.cctpForward(source: source, burn: String(entry.id[entry.id.index(after: colon)...])) {
                end = (.settled, mint)
            } else if entry.chain == "layerzero", let s = await Self.layerZeroStatus(tx: entry.id) {
                if s.status == "DELIVERED" { end = (.settled, s.delivered ?? s.status) } else if s.status == "FAILED" { end = (.failed, s.status) }
            } else if entry.chain == "1click", let s = try? await OneClick.status(depositAddress: entry.id) {
                if s.isFinal { end = (s.status == "SUCCESS" ? .settled : .failed, s.status) }
                // A receiving address nobody sent to by its hour's deadline is over.
                else if s.status == "PENDING_DEPOSIT", entry.note.hasPrefix("Receive:"), now.timeIntervalSince(entry.at) > 65 * 60 { end = (.expired, "nothing came by the deadline") }
            }
            if let end { try? journal.append(.init(chain: entry.chain, id: entry.id, kind: end.kind, note: "\(end.status) (seen later)")) }
            else { left.append(entry) }
        }
        return left
    }
}

/// Landings of the bridge legs a chain signed (Executor.landings): each leg's money lands while the next leg is signed,
/// so a chain bringing USDC from three places waits for the slowest bridge, not the three in a row. A step that spends
/// where they land waits for those first; a landing that failed throws there.
public final class Landings: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(place: String, task: Task<String, Error>)] = []
    public init() {}

    /// `wait` lands the leg and says how it went («Moved 2 USDC … arrived»).
    func add(_ place: String, _ wait: @escaping @Sendable () async throws -> String) {
        let task = Task { try await wait() }
        lock.withLock { pending.append((place, task)) }
    }

    /// How many are still out at `place` (nil: anywhere).
    public func count(at place: String?) -> Int { lock.withLock { pending.filter { place == nil || $0.place == place }.count } }

    /// Waits for the landings at `place` (nil: all of them) and gives what each said; the first that failed throws.
    @discardableResult
    public func wait(for place: String?) async throws -> [String] {
        let due = lock.withLock { () -> [Task<String, Error>] in
            let due = pending.filter { place == nil || $0.place == place }.map(\.task)
            pending.removeAll { place == nil || $0.place == place }
            return due
        }
        var said: [String] = []
        for task in due { said.append(try await task.value) }
        return said
    }
}
