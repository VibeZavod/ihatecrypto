import Foundation
import WalletCore

/// A decoded Solana transaction message (legacy or v0), for checking what is about to be signed.
public struct SolanaMessage: Sendable {
    public struct Instruction: Sendable {
        public let programIndex: Int
        public let accounts: [Int]
        public let data: Data
    }

    public struct Lookup: Sendable {
        public let table: String
        public let writable: [Int]
        public let readonly: [Int]
    }

    public let version: Int?
    public let requiredSignatures: Int
    public let staticKeys: [String]
    public let instructions: [Instruction]
    public let lookups: [Lookup]

    /// Parses a full wire transaction (signatures + message).
    public static func parse(transaction wire: Data) throws -> SolanaMessage {
        var o = 0
        let signatures = try SolanaTransaction.readCompact(wire, &o)
        return try parse(message: wire.subdata(in: (wire.startIndex + o + signatures * 64)..<wire.endIndex))
    }

    public static func parse(message m: Data) throws -> SolanaMessage {
        let bytes = [UInt8](m)
        var p = 0
        func need(_ n: Int) throws { guard p + n <= bytes.count else { throw WalletError("Message truncated") } }
        func compact() throws -> Int {
            let data = Data(bytes)
            let value = try SolanaTransaction.readCompact(data, &p)
            return value
        }
        try need(1)
        var version: Int?
        if bytes[0] & 0x80 != 0 { version = Int(bytes[0] & 0x7f); p = 1 }
        try need(3)
        let required = Int(bytes[p]); p += 3
        let keyCount = try compact()
        try need(keyCount * 32 + 32)
        let keys = (0..<keyCount).map { Base58.encode(Data(bytes[(p + $0 * 32)..<(p + $0 * 32 + 32)])) }
        p += keyCount * 32 + 32 // keys, recent blockhash
        var instructions: [Instruction] = []
        for _ in 0..<(try compact()) {
            try need(1)
            let program = Int(bytes[p]); p += 1
            let n = try compact(); try need(n)
            let accounts = bytes[p..<(p + n)].map(Int.init); p += n
            let len = try compact(); try need(len)
            instructions.append(Instruction(programIndex: program, accounts: accounts, data: Data(bytes[p..<(p + len)])))
            p += len
        }
        var lookups: [Lookup] = []
        if version != nil {
            for _ in 0..<(try compact()) {
                try need(32)
                let table = Base58.encode(Data(bytes[p..<(p + 32)])); p += 32
                let w = try compact(); try need(w); let writable = bytes[p..<(p + w)].map(Int.init); p += w
                let r = try compact(); try need(r); let readonly = bytes[p..<(p + r)].map(Int.init); p += r
                lookups.append(Lookup(table: table, writable: writable, readonly: readonly))
            }
        }
        // Trailing bytes would be signed without being checked.
        guard p == bytes.count else { throw WalletError("Extra bytes after the message") }
        return SolanaMessage(version: version, requiredSignatures: required, staticKeys: keys, instructions: instructions, lookups: lookups)
    }

    /// Every account the message can touch, in Solana's order: static keys, then all writable
    /// lookup entries, then all readonly ones. `tables` maps a lookup table to its addresses.
    public func accounts(tables: [String: [String]]) throws -> [String] {
        var out = staticKeys
        for pick in [\Lookup.writable, \Lookup.readonly] {
            for lookup in lookups {
                guard let addresses = tables[lookup.table] else { throw WalletError("No address lookup table \(lookup.table)") }
                for i in lookup[keyPath: pick] {
                    guard i < addresses.count else { throw WalletError("Index outside lookup table \(lookup.table)") }
                    out.append(addresses[i])
                }
            }
        }
        return out
    }
}

extension SolanaRPC {
    /// Addresses stored in an address lookup table account (56-byte header, then 32-byte keys).
    public func lookupTable(_ address: String) async throws -> [String] {
        let r = try await call("getAccountInfo", [address, ["encoding": "base64", "commitment": "confirmed"]]) as? [String: Any]
        guard let value = r?["value"] as? [String: Any], let data = (value["data"] as? [Any])?.first as? String,
              let raw = Data(base64Encoded: data), raw.count >= 56 else { throw WalletError("Address lookup table not found: \(address)") }
        return stride(from: 56, to: raw.count - 31, by: 32).map { Base58.encode(raw.subdata(in: $0..<($0 + 32))) }
    }

    /// Full account list of a message, loading its lookup tables from the chain.
    public func resolveAccounts(_ message: SolanaMessage) async throws -> [String] {
        var tables: [String: [String]] = [:]
        for lookup in message.lookups { tables[lookup.table] = try await lookupTable(lookup.table) }
        return try message.accounts(tables: tables)
    }

    /// Simulates and returns the watched accounts' state afterwards: lamports and, for token accounts, raw amount.
    /// `sigVerify: false` simulates a transaction before it is signed.
    public func simulate(_ transaction: Data, watch: [String], sigVerify: Bool = true) async throws -> (error: String?, after: [String: (lamports: UInt64, token: UInt64?)]) {
        let r = try await call("simulateTransaction", [transaction.base64EncodedString(), [
            "encoding": "base64", "sigVerify": sigVerify, "commitment": "confirmed",
            "accounts": ["encoding": "jsonParsed", "addresses": watch],
        ]]) as? [String: Any]
        let value = r?["value"] as? [String: Any]
        let err = value?["err"]
        var after: [String: (UInt64, UInt64?)] = [:]
        for (address, account) in zip(watch, value?["accounts"] as? [Any] ?? []) {
            guard let a = account as? [String: Any] else { after[address] = (0, nil); continue }
            let lamports = (a["lamports"] as? NSNumber)?.uint64Value ?? 0
            let amount = (((a["data"] as? [String: Any])?["parsed"] as? [String: Any])?["info"] as? [String: Any])
                .flatMap { ($0["tokenAmount"] as? [String: Any])?["amount"] as? String }.flatMap(UInt64.init)
            after[address] = (lamports, amount)
        }
        return (err == nil || err is NSNull ? nil : "\(err!)", after)
    }
}
