import Foundation
import P256K

/// EIP-712 typed-data hashing for flat structs, which is all Hyperliquid and a deposit need.
/// ponytail: no nested structs or arrays; add them when a protocol needs them.
public enum EIP712 {
    public enum Value: Sendable {
        case string(String)
        case address(String)
        case uint(UInt64)
        case bool(Bool)
        case bytes32(Data)
    }

    public struct Field: Sendable {
        public let name: String
        public let type: String
        public let value: Value

        public init(_ name: String, _ type: String, _ value: Value) {
            self.name = name
            self.type = type
            self.value = value
        }
    }

    public static func hashStruct(_ type: String, _ fields: [Field]) throws -> Data {
        let typeString = "\(type)(\(fields.map { "\($0.type) \($0.name)" }.joined(separator: ",")))"
        var encoded = Keccak.hash256(Data(typeString.utf8))
        for field in fields { encoded += try encode(field.value) }
        return Keccak.hash256(encoded)
    }

    /// The domain separator and the message's struct hash: what a hardware wallet takes to sign typed data by hash.
    public struct Parts: Sendable, Equatable {
        public let domain: Data
        public let message: Data
        /// keccak256(0x19 0x01 ‖ domainSeparator ‖ hashStruct(message)) — the digest a wallet signs.
        public var digest: Data { Keccak.hash256(Data([0x19, 0x01]) + domain + message) }
    }

    public static func parts(domain: [Field], type: String, message: [Field]) throws -> Parts {
        Parts(domain: try hashStruct("EIP712Domain", domain), message: try hashStruct(type, message))
    }

    public static func digest(domain: [Field], type: String, message: [Field]) throws -> Data {
        try parts(domain: domain, type: type, message: message).digest
    }

    static func encode(_ value: Value) throws -> Data {
        switch value {
        case .string(let s): return Keccak.hash256(Data(s.utf8))
        case .address(let a):
            guard let bytes = Data(hex: a), bytes.count == 20 else { throw WalletError("Invalid address: \(a)") }
            return Data(count: 12) + bytes
        case .uint(let n): return Data(count: 24) + withUnsafeBytes(of: n.bigEndian) { Data($0) }
        case .bool(let b): return try encode(.uint(b ? 1 : 0))
        case .bytes32(let d):
            guard d.count == 32 else { throw WalletError("bytes32 must be 32 bytes.") }
            return d
        }
    }
}

public struct EVMSignature: Sendable, Equatable, Codable {
    public let r: Data
    public let s: Data
    /// 27 or 28, as eth_account and Hyperliquid expect.
    public let v: Int

    public init(r: Data, s: Data, v: Int) { (self.r, self.s, self.v) = (r, s, v) }
}

public enum EVMSigner {
    /// Recoverable ECDSA over a 32-byte digest, RFC 6979 nonces and low-s from libsecp256k1:
    /// the same signature eth_account produces for the same key and digest.
    public static func sign(digest: Data, privateKey: Data) throws -> EVMSignature {
        guard digest.count == 32 else { throw WalletError("Only a 32-byte hash can be signed.") }
        let key = try P256K.Recovery.PrivateKey(dataRepresentation: privateKey)
        let compact = key.signature(for: HashDigest(Array(digest))).compactRepresentation
        return EVMSignature(r: compact.signature.prefix(32), s: compact.signature.suffix(32), v: Int(compact.recoveryId) + 27)
    }

    /// The EIP-55 address that made `signature` over `digest`: how a signature from a device is checked before use.
    public static func recover(digest: Data, signature: EVMSignature) throws -> String {
        guard digest.count == 32, signature.r.count == 32, signature.s.count == 32, [27, 28].contains(signature.v) else {
            throw WalletError("Not a signature over a 32-byte hash.")
        }
        let recoverable = try P256K.Recovery.ECDSASignature(compactRepresentation: signature.r + signature.s, recoveryId: Int32(signature.v - 27))
        let key = P256K.Recovery.PublicKey(HashDigest(Array(digest)), signature: recoverable, format: .uncompressed)
        return EVMAccount.checksum(Keccak.hash256(key.dataRepresentation.dropFirst()).suffix(20).hex)
    }
}
