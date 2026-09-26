import ExecutionCore
import Foundation
import Testing

@Test func journalKeepsOrderAndFindsUnresolvedSends() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let journal = Journal(url: url)
    try journal.append(.init(chain: "solana", id: "sigA", kind: .signed, note: "swap"))
    try journal.append(.init(chain: "solana", id: "sigB", kind: .signed, note: "bridge deposit"))
    try journal.append(.init(chain: "solana", id: "sigA", kind: .confirmed))
    try journal.append(.init(chain: "1click", id: "depositX", kind: .signed))

    #expect(try journal.entries().count == 4)
    #expect(try journal.unresolved().map(\.id) == ["sigB", "depositX"])
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
}
