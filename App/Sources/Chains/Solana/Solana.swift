import CryptoKit
import Foundation
import WalletCore

/// Solana JSON-RPC: only what sending and confirming a transaction needs.
public struct SolanaRPC: Sendable {
    public let url: URL

    // ponytail: the public endpoint is rate-limited; a user-chosen RPC comes with the settings field.
    public init(url: URL = URL(string: "https://api.mainnet-beta.solana.com")!) { self.url = url }

    public func call(_ method: String, _ params: [Any]) async throws -> Any {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        // ponytail: the public RPC answers 429 under bursts; three backed-off retries, then a clear error.
        var attempt = 0
        var data = Data()
        while true {
            let (body, response) = try await URLSession.shared.data(for: request)
            data = body
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429, attempt < 3 {
                attempt += 1
                try await Task.sleep(for: .milliseconds(800 * attempt))
                continue
            }
            guard (200..<300).contains(status) else {
                throw WalletError("Solana RPC \(method): HTTP \(status) \(String(decoding: body.prefix(120), as: UTF8.self))")
            }
            break
        }
        guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WalletError("Solana RPC \(method): response isn't JSON: \(String(decoding: data.prefix(120), as: UTF8.self))")
        }
        if let error = reply["error"] as? [String: Any] {
            throw WalletError("Solana RPC \(method): \(error["message"] as? String ?? "\(error)")")
        }
        return reply["result"] ?? NSNull()
    }

    public func balance(_ address: String) async throws -> UInt64 {
        let r = try await call("getBalance", [address, ["commitment": "confirmed"]]) as? [String: Any]
        return (r?["value"] as? NSNumber)?.uint64Value ?? 0
    }

    /// Raw units of an SPL token held by `owner` across its accounts.
    public func tokenBalance(owner: String, mint: String) async throws -> UInt64 {
        let r = try await call("getTokenAccountsByOwner", [owner, ["mint": mint], ["encoding": "jsonParsed", "commitment": "confirmed"]]) as? [String: Any]
        let accounts = r?["value"] as? [[String: Any]] ?? []
        return accounts.reduce(0) { sum, account in
            let amount = (((account["account"] as? [String: Any])?["data"] as? [String: Any])?["parsed"] as? [String: Any])
                .flatMap { (($0["info"] as? [String: Any])?["tokenAmount"] as? [String: Any])?["amount"] as? String }
            return sum + (amount.flatMap { UInt64($0) } ?? 0)
        }
    }

    public func latestBlockhash() async throws -> (blockhash: String, lastValidBlockHeight: UInt64) {
        let r = try await call("getLatestBlockhash", [["commitment": "confirmed"]]) as? [String: Any]
        guard let value = r?["value"] as? [String: Any], let hash = value["blockhash"] as? String,
              let height = (value["lastValidBlockHeight"] as? NSNumber)?.uint64Value else { throw WalletError("No blockhash") }
        return (hash, height)
    }

    /// Simulates first (preflight), then broadcasts. Returns the signature, which is the transaction id.
    public func send(_ transaction: Data) async throws -> String {
        let r = try await call("sendTransaction", [transaction.base64EncodedString(), ["encoding": "base64", "preflightCommitment": "confirmed", "maxRetries": 5]])
        guard let signature = r as? String else { throw WalletError("sendTransaction returned no signature") }
        return signature
    }

    /// Runs the transaction without sending it, with signature checks on. nil error = it would succeed.
    public func simulate(_ transaction: Data) async throws -> (error: String?, logs: [String]) {
        let r = try await call("simulateTransaction", [transaction.base64EncodedString(), ["encoding": "base64", "sigVerify": true, "commitment": "confirmed"]]) as? [String: Any]
        let value = r?["value"] as? [String: Any]
        let err = value?["err"]
        return (err == nil || err is NSNull ? nil : "\(err!)", value?["logs"] as? [String] ?? [])
    }

    public enum Outcome: Equatable, Sendable { case confirmed, failed(String), expired }

    /// Waits for "confirmed". A transaction whose blockhash is past `lastValidBlockHeight` can never land:
    /// that is a definite «didn't land», not a guess, so it is safe to build a new one.
    public func waitForConfirmation(_ signature: String, lastValidBlockHeight: UInt64, timeout: TimeInterval = 120) async throws -> Outcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let r = try await call("getSignatureStatuses", [[signature], ["searchTransactionHistory": true]]) as? [String: Any]
            if let status = (r?["value"] as? [Any])?.first as? [String: Any] {
                if let err = status["err"], !(err is NSNull) { return .failed("\(err)") }
                let level = status["confirmationStatus"] as? String
                if level == "confirmed" || level == "finalized" { return .confirmed }
            } else if let height = (try await call("getBlockHeight", [["commitment": "confirmed"]]) as? NSNumber)?.uint64Value,
                      height > lastValidBlockHeight {
                return .expired
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw WalletError("Transaction status still unknown after \(Int(timeout)) s: \(signature)")
    }
}

public enum SolanaTransaction {
    static let systemProgram = Data(count: 32) // 11111111111111111111111111111111
    static let computeBudgetProgram = try! Base58.decode("ComputeBudget111111111111111111111111111111")

    /// Native SOL transfer with a small priority fee, as a signed legacy transaction.
    public static func transfer(from privateKey: Data, to recipient: String, lamports: UInt64, blockhash: String,
                                microLamportsPerCU: UInt64 = 20_000) throws -> (signature: String, wire: Data) {
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let from = signer.publicKey.rawRepresentation
        let to = try Base58.decode(recipient)
        guard to.count == 32 else { throw WalletError("Invalid Solana address: \(recipient)") }
        guard to != from else { throw WalletError("Transfer to yourself") }

        var message = Data([1, 0, 2])                         // 1 signer, 0 readonly signed, 2 readonly unsigned
        message += compact(4) + from + to + systemProgram + computeBudgetProgram
        message += try Base58.decode(blockhash)
        message += compact(2)
        // ComputeBudget.SetComputeUnitPrice
        message += Data([3]) + compact(0) + compact(9) + Data([3]) + le(microLamportsPerCU)
        // System.Transfer: u32 index 2, u64 lamports
        message += Data([2]) + compact(2) + Data([0, 1]) + compact(12) + le(UInt32(2)) + le(lamports)

        let signature = try signer.signature(for: message)
        return (Base58.encode(signature), compact(1) + signature + message)
    }

    /// Signs a transaction someone else built (Jupiter). Refuses unless our key is the fee payer, account 0.
    public static func sign(_ wire: Data, privateKey: Data) throws -> (signature: String, wire: Data) {
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        var offset = 0
        let signatureCount = try readCompact(wire, &offset)
        let signaturesStart = offset
        let messageStart = offset + signatureCount * 64
        guard signatureCount >= 1, wire.count > messageStart else { throw WalletError("Incomplete transaction") }
        let message = wire.subdata(in: messageStart..<wire.count)

        var m = message.startIndex
        if message[m] & 0x80 != 0 { m += 1 }                    // versioned (v0) prefix
        guard message[m] == 1 else { throw WalletError("The transaction needs \(message[m]) signatures; expected only ours") }
        m += 3
        var keyOffset = m - message.startIndex
        _ = try readCompact(message, &keyOffset)
        let feePayer = message.subdata(in: (message.startIndex + keyOffset)..<(message.startIndex + keyOffset + 32))
        guard feePayer == signer.publicKey.rawRepresentation else { throw WalletError("The fee payer isn't our wallet") }

        let signature = try signer.signature(for: message)
        var signed = wire
        signed.replaceSubrange((wire.startIndex + signaturesStart)..<(wire.startIndex + signaturesStart + 64), with: signature)
        return (Base58.encode(signature), signed)
    }

    static func compact(_ n: Int) -> Data {
        var value = n, out = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value > 0 { byte |= 0x80 }
            out.append(byte)
        } while value > 0
        return out
    }

    static func readCompact(_ data: Data, _ offset: inout Int) throws -> Int {
        var value = 0, shift = 0
        while true {
            guard data.startIndex + offset < data.endIndex else { throw WalletError("Truncated length") }
            let byte = data[data.startIndex + offset]
            offset += 1
            value |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    static func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}

/// An instruction as protocols hand it over (Relay's quote steps, for example).
public struct SolanaInstruction: Sendable {
    public struct Account: Sendable {
        public let pubkey: String
        public let isSigner: Bool
        public let isWritable: Bool
        public init(pubkey: String, isSigner: Bool, isWritable: Bool) {
            self.pubkey = pubkey
            self.isSigner = isSigner
            self.isWritable = isWritable
        }
    }

    public let program: String
    public let accounts: [Account]
    public let data: Data

    public init(program: String, accounts: [Account], data: Data) {
        self.program = program
        self.accounts = accounts
        self.data = data
    }
}

extension SolanaTransaction {
    /// Compiles instructions into a signed legacy transaction, fee payer first, with a priority fee.
    public static func compile(_ instructions: [SolanaInstruction], privateKey: Data, blockhash: String,
                               microLamportsPerCU: UInt64 = 20_000) throws -> (signature: String, wire: Data) {
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let message = try compileMessage(instructions, payer: Base58.encode(signer.publicKey.rawRepresentation),
                                         blockhash: blockhash, microLamportsPerCU: microLamportsPerCU)
        let signature = try signer.signature(for: message)
        return (Base58.encode(signature), compact(1) + signature + message)
    }

    /// A one-signer transaction with an empty signature slot, for a signer in another process.
    public static func unsigned(_ message: Data) -> Data { compact(1) + Data(count: 64) + message }

    /// The legacy message for `instructions`, fee payer first, with a priority fee.
    /// ponytail: no lookup tables, so every account is static; fine up to ~30 accounts (1232-byte limit).
    public static func compileMessage(_ instructions: [SolanaInstruction], payer: String, blockhash: String,
                                      microLamportsPerCU: UInt64 = 20_000) throws -> Data {
        let budget = SolanaInstruction(program: Base58.encode(computeBudgetProgram), accounts: [],
                                       data: Data([3]) + le(microLamportsPerCU))
        let all = [budget] + instructions

        // Merge every account's flags; programs are readonly non-signers.
        var flags: [String: (signer: Bool, writable: Bool)] = [payer: (true, true)]
        var order = [payer]
        func add(_ key: String, signer: Bool, writable: Bool) {
            if let f = flags[key] { flags[key] = (f.signer || signer, f.writable || writable) }
            else { flags[key] = (signer, writable); order.append(key) }
        }
        for ix in all {
            for a in ix.accounts { add(a.pubkey, signer: a.isSigner, writable: a.isWritable) }
            add(ix.program, signer: false, writable: false)
        }
        let signers = order.filter { flags[$0]!.signer }
        guard signers == [payer] else { throw WalletError("The instructions need other signers: \(signers.filter { $0 != payer })") }
        let keys = [payer]
            + order.filter { $0 != payer && flags[$0]!.writable }
            + order.filter { $0 != payer && !flags[$0]!.writable }
        let readonlyUnsigned = keys.filter { !flags[$0]!.writable }.count
        let index = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })

        var message = Data([1, 0, UInt8(readonlyUnsigned)]) + compact(keys.count)
        for key in keys { message += try Base58.decode(key) }
        message += try Base58.decode(blockhash)
        message += compact(all.count)
        for ix in all {
            message += Data([UInt8(index[ix.program]!)]) + compact(ix.accounts.count) + Data(ix.accounts.map { UInt8(index[$0.pubkey]!) })
            message += compact(ix.data.count) + ix.data
        }
        guard message.count + 65 <= 1232 else { throw WalletError("The transaction is over 1232 bytes") }
        return message
    }
}
