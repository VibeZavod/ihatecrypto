import Foundation

/// eth_signTypedData_v4 as sites send it, parsed and hashed here rather than trusted from the page.
/// Only flat structs (what logins and Hyperliquid's own actions use); anything nested is refused, and token
/// spending permissions (Permit, Permit2 and their kin) are recognised so they can be refused outright.
public struct TypedData: Sendable {
    public let primaryType: String
    public let domainName: String
    public let chainId: String
    /// name, type and the value as shown, in the order the site declared them.
    public let fields: [(name: String, type: String, value: String)]
    public let digest: Data

    static let permitTypes: Set<String> = [
        "Permit", "PermitSingle", "PermitBatch", "PermitTransferFrom", "PermitBatchTransferFrom",
        "PermitWitnessTransferFrom", "PermitBatchWitnessTransferFrom", "PermitForAll",
    ]

    /// A signature that lets someone else spend the user's tokens: the drainers' favourite.
    public var isTokenPermission: Bool {
        if Self.permitTypes.contains(primaryType) || primaryType.lowercased().contains("permit") { return true }
        let names = Set(fields.map { $0.name.lowercased() })
        return names.contains("spender") || (names.contains("operator") && names.contains("approved"))
    }

    public static func parse(_ json: Data) throws -> TypedData {
        guard let j = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let types = j["types"] as? [String: [[String: String]]], let primary = j["primaryType"] as? String,
              let domain = j["domain"] as? [String: Any], let message = j["message"] as? [String: Any],
              let declared = types[primary] else { throw WalletError("Unreadable typed data.") }
        let domainType = types["EIP712Domain"] ?? ["name", "version", "chainId", "verifyingContract", "salt"].compactMap { key in
            domain[key].map { _ in ["name": key, "type": ["chainId": "uint256", "verifyingContract": "address", "salt": "bytes32"][key] ?? "string"] }
        }
        func fields(_ declared: [[String: String]], _ values: [String: Any]) throws -> [EIP712.Field] {
            try declared.map { d in
                guard let name = d["name"], let type = d["type"] else { throw WalletError("A field without a name or type.") }
                guard types[type] == nil, !type.hasSuffix("]") else { throw WalletError("ihatecrypto doesn't sign nested typed data (\(type)) yet.") }
                return EIP712.Field(name, type, try value(values[name], type: type))
            }
        }
        let domainFields = try fields(domainType, domain)
        let messageFields = try fields(declared, message)
        let shown = declared.map { d in (d["name"] ?? "", d["type"] ?? "", describe(message[d["name"] ?? ""])) }
        return TypedData(primaryType: primary, domainName: domain["name"] as? String ?? "", chainId: describe(domain["chainId"]),
                         fields: shown, digest: try EIP712.digest(domain: domainFields, type: primary, message: messageFields))
    }

    static func describe(_ v: Any?) -> String {
        switch v {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        case nil: "—"
        default: "\(v!)"
        }
    }

    static func value(_ v: Any?, type: String) throws -> EIP712.Value {
        switch type {
        case "string": return .string(v as? String ?? "")
        case "address":
            guard let a = v as? String else { throw WalletError("No address.") }
            return .address(a)
        case "bool": return .bool(v as? Bool ?? ((v as? String) == "true"))
        case "bytes32":
            guard let s = v as? String, let d = Data(hex: s), d.count == 32 else { throw WalletError("Invalid bytes32.") }
            return .bytes32(d)
        case "bytes":
            guard let s = v as? String, let d = Data(hex: s) else { throw WalletError("Invalid bytes.") }
            return .bytes32(Keccak.hash256(d))
        case let t where t.hasPrefix("uint"):
            return .bytes32(try word(v))
        default:
            throw WalletError("ihatecrypto doesn't sign type \(type) yet.")
        }
    }

    /// An unsigned integer as a 32-byte big-endian word, from a JSON number, decimal or 0x-hex string.
    static func word(_ v: Any?) throws -> Data {
        var text = (v as? String) ?? (v as? NSNumber)?.stringValue ?? ""
        if text.hasPrefix("0x") {
            text.removeFirst(2)
            guard let d = Data(hex: String(repeating: "0", count: text.count % 2) + text), d.count <= 32 else { throw WalletError("Number out of uint256 range.") }
            return Data(count: 32 - d.count) + d
        }
        guard !text.isEmpty, text.allSatisfy(\.isNumber) else { throw WalletError("Not a number: \(text).") }
        var bytes = [UInt8](repeating: 0, count: 32)
        for digit in text.compactMap(\.wholeNumberValue) {
            // bytes = bytes × 10 + digit, big-endian
            var carry = digit
            for i in (0..<32).reversed() {
                let x = Int(bytes[i]) * 10 + carry
                bytes[i] = UInt8(x & 0xff)
                carry = x >> 8
            }
            guard carry == 0 else { throw WalletError("Number out of uint256 range.") }
        }
        return Data(bytes)
    }
}

/// EIP-191 personal_sign: what «Sign-In with Ethereum» and most site logins ask for.
public enum PersonalMessage {
    public static func digest(_ message: Data) -> Data {
        Keccak.hash256(Data("\u{19}Ethereum Signed Message:\n\(message.count)".utf8) + message)
    }

    /// 32 raw bytes are a hash, not text: signing one blind can authorise anything.
    public static func isBlindHash(_ message: Data) -> Bool {
        message.count == 32 && String(data: message, encoding: .utf8).map { $0.unicodeScalars.contains { $0.value < 0x20 } } != false
    }
}
