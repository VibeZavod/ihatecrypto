import Foundation

/// Keccak-256 as Ethereum uses it (original Keccak padding 0x01, not SHA3-256's 0x06).
/// Checked against the standard empty-string and "abc" vectors in WalletTests.
public enum Keccak {
    public static func hash256(_ input: some DataProtocol) -> Data {
        var state = [UInt64](repeating: 0, count: 25)
        let rate = 136
        var message = [UInt8](input)
        message.append(0x01)
        while message.count % rate != 0 { message.append(0) }
        message[message.count - 1] |= 0x80

        for block in stride(from: 0, to: message.count, by: rate) {
            for lane in 0..<(rate / 8) {
                var value: UInt64 = 0
                for byte in 0..<8 { value |= UInt64(message[block + lane * 8 + byte]) << (8 * byte) }
                state[lane] ^= value
            }
            permute(&state)
        }

        var out = Data(capacity: 32)
        for lane in 0..<4 {
            for byte in 0..<8 { out.append(UInt8(truncatingIfNeeded: state[lane] >> (8 * byte))) }
        }
        return out
    }

    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    private static let rotations = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44]
    private static let lanes = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1]

    private static func rotl(_ x: UInt64, _ n: Int) -> UInt64 { (x << UInt64(n)) | (x >> UInt64(64 - n)) }

    private static func permute(_ s: inout [UInt64]) {
        var c = [UInt64](repeating: 0, count: 5)
        for round in 0..<24 {
            for i in 0..<5 { c[i] = s[i] ^ s[i + 5] ^ s[i + 10] ^ s[i + 15] ^ s[i + 20] }
            for i in 0..<5 {
                let t = c[(i + 4) % 5] ^ rotl(c[(i + 1) % 5], 1)
                for j in stride(from: 0, to: 25, by: 5) { s[j + i] ^= t }
            }
            var t = s[1]
            for i in 0..<24 {
                let j = lanes[i]
                let next = s[j]
                s[j] = rotl(t, rotations[i])
                t = next
            }
            for j in stride(from: 0, to: 25, by: 5) {
                let row = Array(s[j..<(j + 5)])
                for i in 0..<5 { s[j + i] = row[i] ^ (~row[(i + 1) % 5] & row[(i + 2) % 5]) }
            }
            s[0] ^= roundConstants[round]
        }
    }
}

extension Data {
    /// Accepts "0x…" or bare hex; nil on odd length or a non-hex character.
    public init?(hex: String) {
        let digits = Array((hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex).utf8)
        guard digits.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let b = UInt8(String(decoding: digits[i...i + 1], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(b)
        }
        self.init(bytes)
    }

    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}
