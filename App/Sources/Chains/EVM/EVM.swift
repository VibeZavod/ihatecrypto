import Foundation
import P256K
import WalletCore

/// Recursive Length Prefix, Ethereum's serialization.
public indirect enum RLP: Sendable {
    case bytes(Data)
    case list([RLP])

    /// Integers are big-endian with no leading zeros; zero is the empty string.
    public static func uint(_ n: UInt64) -> RLP {
        var be = withUnsafeBytes(of: n.bigEndian) { Data($0) }
        while be.first == 0 { be.removeFirst() }
        return .bytes(be)
    }

    public static func uint(bigEndian bytes: Data) -> RLP {
        var b = bytes
        while b.first == 0 { b.removeFirst() }
        return .bytes(b)
    }

    public var encoded: Data {
        switch self {
        case .bytes(let d):
            if d.count == 1, d[d.startIndex] < 0x80 { return d }
            return Self.header(d.count, short: 0x80, long: 0xb7) + d
        case .list(let items):
            let body = items.reduce(Data()) { $0 + $1.encoded }
            return Self.header(body.count, short: 0xc0, long: 0xf7) + body
        }
    }

    static func header(_ length: Int, short: UInt8, long: UInt8) -> Data {
        if length < 56 { return Data([short + UInt8(length)]) }
        var be = withUnsafeBytes(of: UInt64(length).bigEndian) { Data($0) }
        while be.first == 0 { be.removeFirst() }
        return Data([long + UInt8(be.count)]) + be
    }
}

/// EIP-1559 (type 2) transaction.
/// ponytail: value in wei as UInt64 caps a single native transfer at ~18 ETH; widen when that matters.
public struct EVMTransaction: Sendable {
    public var chainId: UInt64
    public var nonce: UInt64
    public var maxPriorityFeePerGas: UInt64
    public var maxFeePerGas: UInt64
    public var gasLimit: UInt64
    public var to: String
    public var value: UInt64
    public var data: Data

    public init(chainId: UInt64, nonce: UInt64, maxPriorityFeePerGas: UInt64, maxFeePerGas: UInt64,
                gasLimit: UInt64, to: String, value: UInt64, data: Data) {
        self.chainId = chainId
        self.nonce = nonce
        self.maxPriorityFeePerGas = maxPriorityFeePerGas
        self.maxFeePerGas = maxFeePerGas
        self.gasLimit = gasLimit
        self.to = to
        self.value = value
        self.data = data
    }

    func fields() throws -> [RLP] {
        guard let to = Data(hex: to), to.count == 20 else { throw WalletError("Invalid recipient address: \(self.to)") }
        return [.uint(chainId), .uint(nonce), .uint(maxPriorityFeePerGas), .uint(maxFeePerGas), .uint(gasLimit),
                .bytes(to), .uint(value), .bytes(data), .list([])]
    }

    /// keccak256(0x02 ‖ rlp(fields)) — what the key signs.
    public func signingHash() throws -> Data {
        Keccak.hash256(Data([0x02]) + RLP.list(try fields()).encoded)
    }

    /// Raw signed transaction and its hash (the transaction id).
    public func signed(privateKey: Data) throws -> (raw: Data, hash: String) {
        let signature = try EVMSigner.sign(digest: try signingHash(), privateKey: privateKey)
        let raw = Data([0x02]) + RLP.list(try fields() + [
            .uint(UInt64(signature.v - 27)), .uint(bigEndian: signature.r), .uint(bigEndian: signature.s),
        ]).encoded
        return (raw, "0x" + Keccak.hash256(raw).hex)
    }

    /// Most this transaction can cost in fees, wei.
    public var maxFee: UInt64 { gasLimit * maxFeePerGas }
}

public enum ERC20 {
    /// transfer(address,uint256)
    public static func transfer(to: String, amount: UInt64) throws -> Data {
        guard let recipient = Data(hex: to), recipient.count == 20 else { throw WalletError("Invalid address: \(to)") }
        return Data([0xa9, 0x05, 0x9c, 0xbb]) + Data(count: 12) + recipient + Data(count: 24) + withUnsafeBytes(of: amount.bigEndian) { Data($0) }
    }

    /// balanceOf(address)
    public static func balanceOf(_ owner: String) throws -> Data {
        guard let who = Data(hex: owner), who.count == 20 else { throw WalletError("Invalid address: \(owner)") }
        return Data([0x70, 0xa0, 0x82, 0x31]) + Data(count: 12) + who
    }

    /// approve(address,uint256) — always an exact amount; the guard refuses unlimited ones anyway.
    public static func approve(spender: String, amount: UInt64) throws -> Data {
        Data([0x09, 0x5e, 0xa7, 0xb3]) + (try ABI.address(spender)) + ABI.uint(amount)
    }

    /// allowance(address owner, address spender)
    public static func allowance(owner: String, spender: String) throws -> Data {
        Data([0xdd, 0x62, 0xed, 0x3e]) + (try ABI.address(owner)) + (try ABI.address(spender))
    }
}

/// 32-byte ABI words.
public enum ABI {
    public static func address(_ a: String) throws -> Data {
        guard let bytes = Data(hex: a), bytes.count == 20 else { throw WalletError("Invalid address: \(a)") }
        return Data(count: 12) + bytes
    }

    public static func uint(_ n: UInt64) -> Data { Data(count: 24) + withUnsafeBytes(of: n.bigEndian) { Data($0) } }

    /// Word `i` of a return value as an address.
    public static func address(in data: Data, word i: Int) -> String? {
        let data = Data(data)   // a slice keeps its parent's indices
        return data.count >= (i + 1) * 32 ? "0x" + data.subdata(in: (i * 32 + 12)..<((i + 1) * 32)).hex : nil
    }

    /// Word `i` as a number, nil when it doesn't fit 64 bits.
    public static func uint(in data: Data, word i: Int) -> UInt64? {
        let data = Data(data)   // a slice keeps its parent's indices
        guard data.count >= (i + 1) * 32, data.subdata(in: (i * 32)..<(i * 32 + 24)).allSatisfy({ $0 == 0 }) else { return nil }
        return data.subdata(in: (i * 32 + 24)..<((i + 1) * 32)).reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Word `i` as a Decimal (for 256-bit values such as Aave's ray rates).
    public static func decimal(in data: Data, word i: Int) -> Decimal? {
        let data = Data(data)   // a slice keeps its parent's indices
        guard data.count >= (i + 1) * 32 else { return nil }
        return data.subdata(in: (i * 32)..<((i + 1) * 32)).reduce(Decimal(0)) { $0 * 256 + Decimal($1) }
    }
}

/// Ethereum JSON-RPC for one chain.
public struct EVMRPC: Sendable {
    public let url: URL
    public let chainId: UInt64

    public init(url: URL, chainId: UInt64) {
        self.url = url
        self.chainId = chainId
    }

    public static let arbitrum = EVMRPC(url: URL(string: "https://arb1.arbitrum.io/rpc")!, chainId: 42161)
    public static let arbitrumUSDC = "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
    /// mainnet.base.org rate-limits after a few calls and publicnode refuses receipts without a token;
    /// drpc served calls, estimates and receipts in a burst test (2026-09-26).
    public static let base = EVMRPC(url: URL(string: "https://base.drpc.org")!, chainId: 8453)
    /// Circle's native USDC on Base (6 decimals).
    public static let baseUSDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

    /// eth_call: the raw return value.
    public func read(_ to: String, _ data: Data) async throws -> Data {
        let hex = try await call("eth_call", [["to": to, "data": "0x" + data.hex], "latest"]) as? String ?? "0x"
        return Data(hex: String(hex.dropFirst(2))) ?? Data()
    }

    public func call(_ method: String, _ params: [Any]) async throws -> Any {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        var (data, response) = try await URLSession.shared.data(for: request)
        // Public nodes throttle bursts: wait and ask again (reads and sends alike are safe to repeat — a resent
        // raw transaction is the same transaction).
        for delay in [1, 2, 4] where (response as? HTTPURLResponse)?.statusCode == 429 || String(decoding: data.prefix(200), as: UTF8.self).contains("rate limit") {
            try await Task.sleep(for: .seconds(delay))
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WalletError("EVM RPC \(method): response isn't JSON: \(String(decoding: data.prefix(120), as: UTF8.self))")
        }
        if let error = reply["error"] as? [String: Any] { throw WalletError("EVM RPC \(method): \(error["message"] as? String ?? "\(error)")") }
        return reply["result"] ?? NSNull()
    }

    public func quantity(_ method: String, _ params: [Any]) async throws -> UInt64 {
        guard let hex = try await call(method, params) as? String, let n = UInt64(hex.dropFirst(2), radix: 16) else {
            throw WalletError("EVM RPC \(method): not a number")
        }
        return n
    }

    public func balance(_ address: String) async throws -> UInt64 { try await quantity("eth_getBalance", [address, "latest"]) }
    public func nonce(_ address: String) async throws -> UInt64 { try await quantity("eth_getTransactionCount", [address, "pending"]) }

    public func tokenBalance(_ token: String, owner: String) async throws -> UInt64 {
        let hex = try await call("eth_call", [["to": token, "data": "0x" + (try ERC20.balanceOf(owner)).hex], "latest"]) as? String ?? "0x0"
        return UInt64(String(hex.dropFirst(2).drop(while: { $0 == "0" })), radix: 16) ?? 0
    }

    /// Current fees with headroom: max fee = 2 × base fee + tip.
    public func fees() async throws -> (maxPriority: UInt64, maxFee: UInt64) {
        let base = try await quantity("eth_gasPrice", [])
        let tip = (try? await quantity("eth_maxPriorityFeePerGas", [])) ?? 0
        return (tip, base * 2 + tip)
    }

    /// eth_estimateGas as a dry run: fails if the call would revert or the balance is short.
    public func estimateGas(from: String, to: String, value: UInt64, data: Data) async throws -> UInt64 {
        try await quantity("eth_estimateGas", [["from": from, "to": to, "value": "0x" + String(value, radix: 16), "data": "0x" + data.hex]])
    }

    public func send(_ raw: Data) async throws -> String {
        guard let hash = try await call("eth_sendRawTransaction", ["0x" + raw.hex]) as? String else { throw WalletError("No transaction hash") }
        return hash
    }

    /// Waits for a receipt; true if the transaction succeeded.
    public func waitForReceipt(_ hash: String, timeout: TimeInterval = 120) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let receipt = try await call("eth_getTransactionReceipt", [hash]) as? [String: Any], let status = receipt["status"] as? String {
                return status == "0x1"
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw WalletError("No receipt after \(Int(timeout)) s: \(hash)")
    }
}

/// What an EVM transaction's calldata asks for, as far as token safety goes. The drainers' tools — unlimited
/// approvals, operator rights over all NFTs, permit calls, pulling tokens out of the sender — are refused.
public enum EVMCall: Equatable, Sendable {
    /// Empty data: a plain transfer of the native coin.
    case plain
    case approve(spender: String, amount: Data)
    case increaseAllowance(spender: String, amount: Data)
    case transfer(to: String, amount: Data)
    case transferFrom(from: String, to: String, amount: Data)
    case setApprovalForAll(operator: String, approved: Bool)
    case permit
    /// Any other contract function, by selector.
    case contract(selector: String)

    public static func decode(_ data: Data) -> EVMCall {
        guard data.count >= 4 else { return .plain }
        let selector = data.prefix(4).hex
        let args = data.dropFirst(4)
        func word(_ i: Int) -> Data? { args.count >= (i + 1) * 32 ? Data(args.dropFirst(i * 32).prefix(32)) : nil }
        func address(_ i: Int) -> String? { word(i).map { "0x" + $0.suffix(20).hex } }
        switch selector {
        case "095ea7b3": if let s = address(0), let a = word(1) { return .approve(spender: s, amount: a) }
        case "39509351": if let s = address(0), let a = word(1) { return .increaseAllowance(spender: s, amount: a) }
        case "a9059cbb": if let t = address(0), let a = word(1) { return .transfer(to: t, amount: a) }
        case "23b872dd": if let f = address(0), let t = address(1), let a = word(2) { return .transferFrom(from: f, to: t, amount: a) }
        case "a22cb465": if let o = address(0), let b = word(1) { return .setApprovalForAll(operator: o, approved: b.last == 1) }
        case "d505accf", "8fcbaf0c": return .permit
        default: break
        }
        return .contract(selector: "0x" + selector)
    }

    /// An amount no real balance reaches: the «unlimited» allowance (≥ 2¹²⁸).
    static func unlimited(_ amount: Data) -> Bool { amount.prefix(16).contains { $0 != 0 } }

    /// Why this must not be signed, or nil. `sender` is the user's own address.
    public func refusal(sender: String) -> String? {
        switch self {
        case .approve(_, let a) where Self.unlimited(a), .increaseAllowance(_, let a) where Self.unlimited(a):
            "Unlimited token spending approval — the drainers' main trick. LALA only approves exact amounts."
        case .setApprovalForAll(_, true):
            "Rights to all your NFTs in this contract (setApprovalForAll) — an NFT drainer trick. Refused."
        case .permit:
            "A permit call grants approval to spend your tokens. Refused."
        case .transferFrom(let from, _, _) where from.lowercased() == sender.lowercased():
            "transferFrom from your address in your name — this is how tokens are pulled through an existing approval. Refused."
        default:
            nil
        }
    }
}
