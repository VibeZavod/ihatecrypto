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

    /// 0x02 ‖ rlp(fields): the unsigned transaction, as a hardware wallet reads it.
    public func unsignedPayload() throws -> Data { Data([0x02]) + RLP.list(try fields()).encoded }

    /// keccak256(0x02 ‖ rlp(fields)) — what the key signs.
    public func signingHash() throws -> Data { Keccak.hash256(try unsignedPayload()) }

    /// Raw signed transaction and its hash (the transaction id).
    public func signed(privateKey: Data) throws -> (raw: Data, hash: String) {
        try signed(with: try EVMSigner.sign(digest: try signingHash(), privateKey: privateKey))
    }

    /// The transaction with a signature made elsewhere (a Ledger), v = 27 or 28.
    public func signed(with signature: EVMSignature) throws -> (raw: Data, hash: String) {
        let raw = Data([0x02]) + RLP.list(try fields() + [
            .uint(UInt64(signature.v - 27)), .uint(bigEndian: signature.r), .uint(bigEndian: signature.s),
        ]).encoded
        return (raw, "0x" + Keccak.hash256(raw).hex)
    }

    /// Most this transaction can cost in fees, wei.
    public var maxFee: UInt64 { gasLimit * maxFeePerGas }

    /// The most gas × max fee per gas may come to, per network, in its smallest unit: far above a real fee, so only a
    /// broken or hostile request reaches it. Ethereum 0.05 ETH (≈ $150; a 570k-gas Morpho deposit at a 43 gwei base fee),
    /// Arbitrum, Base and Robinhood Chain 0.01 ETH (≈ $30; their calls cost cents), Polygon 10 POL (≈ $3, ten times a call
    /// at 1000 gwei; 64 bits of wei hold 18 POL at most), Tempo $10 (its fees are counted in attodollars).
    public static let feeCap: [UInt64: UInt64] = [1: 50_000_000_000_000_000, 42161: 10_000_000_000_000_000, 8453: 10_000_000_000_000_000,
                                                  4663: 10_000_000_000_000_000, 137: 10_000_000_000_000_000_000, 4217: 10_000_000_000_000_000_000]

    /// Why the signer won't sign this fee, or nil: past the network's cap, or past 64 bits.
    public var feeProblem: String? {
        let (fee, overflow) = gasLimit.multipliedReportingOverflow(by: maxFeePerGas)
        guard let cap = Self.feeCap[chainId], !overflow, fee <= cap else {
            return "A network fee of \(feeText) is more than ihatecrypto signs on \(EVMRPC.names[chainId] ?? "network \(chainId)")."
        }
        return nil
    }

    /// «up to 0.000042 ETH»: the fee ceiling, for the Touch ID prompt.
    public var feeText: String {
        let (fee, overflow) = gasLimit.multipliedReportingOverflow(by: maxFeePerGas)
        return overflow ? "over 18 \(EVMRPC.coin(chainId))" : "up to \(NSDecimalNumber(decimal: Decimal(fee) / pow(10, 18)).stringValue) \(EVMRPC.coin(chainId))"
    }
}

public enum ERC20 {
    /// transfer(address,uint256)
    public static func transfer(to: String, amount: UInt64) throws -> Data {
        guard let recipient = Data(hex: to), recipient.count == 20 else { throw WalletError("Invalid address: \(to)") }
        return Data([0xa9, 0x05, 0x9c, 0xbb]) + Data(count: 12) + recipient + Data(count: 24) + withUnsafeBytes(of: amount.bigEndian) { Data($0) }
    }

    /// The same for amounts past 64 bits (a thousand tokens of 18 decimals), in the token's smallest units.
    public static func transfer(to: String, units: Decimal) throws -> Data {
        Data([0xa9, 0x05, 0x9c, 0xbb]) + (try ABI.address(to)) + (try ABI.word(units))
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

    /// The same for amounts past 64 bits (a thousand tokens of 18 decimals), in the token's smallest units.
    public static func approve(spender: String, units: Decimal) throws -> Data {
        Data([0x09, 0x5e, 0xa7, 0xb3]) + (try ABI.address(spender)) + (try ABI.word(units))
    }

    /// allowance(address owner, address spender)
    public static func allowance(owner: String, spender: String) throws -> Data {
        Data([0xdd, 0x62, 0xed, 0x3e]) + (try ABI.address(owner)) + (try ABI.address(spender))
    }

    /// transferWithMemo(address,uint256,bytes32): Tempo's TIP-20 transfer carrying a reference the payee asked for.
    public static func transfer(to: String, amount: UInt64, memo: Data) throws -> Data {
        guard memo.count == 32 else { throw WalletError("A memo is 32 bytes.") }
        return Data([0x95, 0x77, 0x7d, 0x59]) + (try ABI.address(to)) + ABI.uint(amount) + memo
    }
}

/// Tempo's fee rules: a plain transfer of a TIP-20 stablecoin pays its fee in that coin; any other call pays in the
/// account's chosen fee token, else pathUSD — which this wallet doesn't hold. So before its first other call (an approve,
/// Relay's deposit) the wallet picks USDC once; that call itself pays in the coin it picks.
public enum Tempo {
    /// The FeeManager precompile.
    public static let feeManager = "0xfeec000000000000000000000000000000000000"

    /// setUserToken(address)
    public static func setUserToken(_ token: String) throws -> Data { Data([0xe7, 0x89, 0x74, 0x44]) + (try ABI.address(token)) }

    /// userTokens(address): the fee token `owner` chose; the zero address when none.
    public static func userToken(_ owner: String) throws -> Data { Data([0xed, 0x49, 0x8f, 0xa8]) + (try ABI.address(owner)) }

    /// A fee in a 6-decimal stablecoin's units from gas × price in attodollars: ceil(x / 10¹²).
    public static func feeUnits(_ attodollars: UInt64) -> UInt64 { (attodollars + 999_999_999_999) / 1_000_000_000_000 }
}

/// 32-byte ABI words.
public enum ABI {
    public static func address(_ a: String) throws -> Data {
        guard let bytes = Data(hex: a), bytes.count == 20 else { throw WalletError("Invalid address: \(a)") }
        return Data(count: 12) + bytes
    }

    public static func uint(_ n: UInt64) -> Data { Data(count: 24) + withUnsafeBytes(of: n.bigEndian) { Data($0) } }

    /// A whole, non-negative number as a 256-bit word. Decimal keeps 38 digits: exact for any token amount a wallet
    /// holds (10²⁷ units is a billion tokens of 18 decimals).
    public static func word(_ n: Decimal) throws -> Data {
        var x = n, bytes = [UInt8]()
        guard x >= 0, x == x.whole else { throw WalletError("Not a whole token amount: \(n)") }
        while x > 0 {
            let q = (x / 256).whole
            bytes.insert(UInt8(truncating: NSDecimalNumber(decimal: x - q * 256)), at: 0)
            x = q
        }
        guard bytes.count <= 32 else { throw WalletError("Amount too large for a word: \(n)") }
        return Data(count: 32 - bytes.count) + bytes
    }

    /// ERC-20 `string` return value (symbol(), name()).
    public static func string(_ data: Data) -> String? {
        let data = Data(data)
        guard data.count >= 64, let length = uint(in: data, word: 1), length <= UInt64(data.count), data.count >= 64 + Int(length) else { return nil }
        return String(data: data.subdata(in: 64..<(64 + Int(length))), encoding: .utf8)
    }

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
    /// Asked in turn when `url` throttles or drops a call: each retry goes to the next node instead of waiting on the
    /// same one. base.drpc.org answered «You reached Public endpoint rate limit» to every call for minutes, and each read
    /// sat through 15 s of retries before failing (a spread took 50 s and lost the Base vaults).
    public let fallbacks: [URL]

    public init(url: URL, chainId: UInt64, fallbacks: [URL] = []) {
        self.url = url
        self.chainId = chainId
        self.fallbacks = fallbacks
    }

    public static let arbitrum = EVMRPC(url: URL(string: "https://arb1.arbitrum.io/rpc")!, chainId: 42161)
    public static let arbitrumUSDC = "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
    public static let robinhood = EVMRPC(url: URL(string: "https://rpc.mainnet.chain.robinhood.com")!, chainId: 4663)
    /// USDG (Global Dollar), Robinhood Chain's dollar, 6 decimals — docs.robinhood.com/chain/contracts.
    public static let robinhoodUSDG = "0x5fc5360d0400a0fd4f2af552add042d716f1d168"
    /// mainnet.base.org rate-limits after a few calls and publicnode refuses receipts without a token;
    /// drpc served calls, estimates and receipts in a burst test (2026-09-26).
    /// Coinbase's own node takes over while drpc throttles (it limits too, so it isn't the first).
    public static let base = EVMRPC(url: URL(string: "https://base.drpc.org")!, chainId: 8453, fallbacks: [URL(string: "https://mainnet.base.org")!])
    /// Circle's native USDC on Base (6 decimals).
    public static let baseUSDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
    /// Polygon PoS, gas in POL; drpc serves calls, estimates and receipts (checked 2026-09-29).
    public static let polygon = EVMRPC(url: URL(string: "https://polygon.drpc.org")!, chainId: 137)
    /// Circle's native USDC on Polygon, not the bridged USDC.e.
    public static let polygonUSDC = "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359"
    /// Ethereum mainnet: a supply costs dollars of gas here, so the planners weigh it before choosing it.
    public static let ethereum = EVMRPC(url: URL(string: "https://eth.drpc.org")!, chainId: 1)
    public static let ethereumUSDC = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    /// Tempo, Stripe's payments chain: no coin of its own, fees come out of a USD stablecoin (Tempo.feeManager), and
    /// eth_getBalance answers a placeholder (4242…42) for every address, so it's never read there (checked 2026-09-30).
    public static let tempo = EVMRPC(url: URL(string: "https://rpc.mainnet.tempo.xyz")!, chainId: 4217)
    /// «Bridged USDC (Stargate)», 6 decimals: the USDC Relay delivers and MPP services charge in.
    public static let tempoUSDC = "0x20c000000000000000000000b9537d11c60e8b50"

    /// The only networks the signer signs for: the app's signing process and the CLI check the same list.
    public static let signable: Set<UInt64> = [1, 137, 42161, 8453, 4663, 4217]

    /// The networks by name, for what the signer says it signs.
    public static let names: [UInt64: String] = [1: "Ethereum", 137: "Polygon", 42161: "Arbitrum", 8453: "Base", 4663: "Robinhood Chain", 4217: "Tempo"]
    /// What a network's fees and `value` are counted in: Polygon's POL, Tempo's dollars (it has no coin), else ETH.
    public static func coin(_ chainId: UInt64) -> String { chainId == 137 ? "POL" : chainId == 4217 ? "USD" : "ETH" }
    /// The dollars ihatecrypto moves, by contract: their symbol for the Touch ID prompt; all have 6 decimals.
    public static let dollars: [String: String] = [baseUSDC: "USDC", arbitrumUSDC: "USDC", polygonUSDC: "USDC", ethereumUSDC: "USDC",
                                                   tempoUSDC: "USDC", robinhoodUSDG: "USDG"]

    /// eth_call: the raw return value.
    public func read(_ to: String, _ data: Data) async throws -> Data {
        let hex = try await call("eth_call", [["to": to, "data": "0x" + data.hex], "latest"]) as? String ?? "0x"
        return Data(hex: String(hex.dropFirst(2))) ?? Data()
    }

    public func call(_ method: String, _ params: [Any]) async throws -> Any {
        let nodes = [url] + fallbacks
        var attempt = 0
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        // Public nodes throttle bursts, drop connections and have bad seconds: wait and ask again, up to about half a
        // minute (reads and sends alike are safe to repeat — a resent raw transaction is the same transaction). What
        // the node answered on purpose (a revert, a short balance) is final at once.
        return try await RPCRetry.run {
            request.url = nodes[attempt % nodes.count]
            attempt += 1
            return try await URLSession.shared.data(for: request)
        } answer: { data, status in
            guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw RPCRetry.Again(status >= 500 || status == 429, WalletError("EVM RPC \(method): HTTP \(status), response isn't JSON: \(String(decoding: data.prefix(120), as: UTF8.self))"))
            }
            if let error = reply["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "\(error)"
                throw RPCRetry.Again(status == 429 || RPCRetry.transient(message), WalletError("EVM RPC \(method): \(message)"))
            }
            return reply["result"] ?? NSNull()
        }
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
        do {
            guard let hash = try await call("eth_sendRawTransaction", ["0x" + raw.hex]) as? String else { throw WalletError("No transaction hash") }
            return hash
        } catch let error as WalletError where error.message.lowercased().contains("already known") || error.message.lowercased().contains("known transaction") {
            // A retry after the first send got through: it's the same transaction, waiting for its block.
            return "0x" + Keccak.hash256(raw).hex
        }
    }

    /// Runs the transaction on the latest block without sending it (eth_simulateV1): what `from` gains and loses.
    public func simulate(from: String, to: String, value: UInt64, data: Data) async throws -> EVMSimulation {
        let tx: [String: Any] = ["from": from, "to": to, "value": "0x" + String(value, radix: 16), "data": "0x" + data.hex]
        return try EVMSimulation(try await call("eth_simulateV1", [["blockStateCalls": [["calls": [tx]]], "traceTransfers": true], "latest"]), owner: from)
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

extension Decimal {
    /// Rounded down to a whole number.
    public var whole: Decimal {
        var x = self, out = Decimal()
        NSDecimalRound(&out, &x, 0, .down)
        return out
    }
}

/// One eth_simulateV1 result, read as one address's balance changes. With traceTransfers the node reports native
/// coin moves as Transfer logs of 0xeeee…eeee, which no contract can emit. Token moves are their contracts' own Transfer
/// logs (plus WETH9's Deposit/Withdrawal, which emit none) — a contract can log anything, so a token is shown by its address.
public struct EVMSimulation: Equatable, Sendable {
    public static let native = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    /// WETH9 on Ethereum and Base; Arbitrum's WETH logs a Transfer on wrap.
    static let weth9: Set<String> = ["0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", "0x4200000000000000000000000000000000000006"]
    static let transfer = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
    static let deposit = "0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c"
    static let withdrawal = "0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65"

    /// Why the call reverts; nil when it succeeds.
    public var revert: String?
    /// Net change per asset contract (`native` for the coin), in raw units; an NFT collection counts items. No zeros.
    public var changes: [String: Decimal] = [:]
    /// ERC-721 collections among `changes`.
    public var nfts: Set<String> = []

    public init(_ result: Any, owner: String) throws {
        guard let call = ((result as? [[String: Any]])?.first?["calls"] as? [[String: Any]])?.first else {
            throw WalletError("eth_simulateV1: unexpected reply")
        }
        if call["status"] as? String != "0x1" {
            revert = (call["error"] as? [String: Any])?["message"] as? String ?? "reverted"
            return
        }
        let me = owner.lowercased().dropFirst(2)
        for log in call["logs"] as? [[String: Any]] ?? [] {
            guard let asset = (log["address"] as? String)?.lowercased(), let topics = log["topics"] as? [String], let event = topics.first else { continue }
            let amount = Data(hex: log["data"] as? String ?? "0x").flatMap { ABI.decimal(in: $0, word: 0) } ?? 0
            var from = "", to = "", n = amount
            switch (event, topics.count) {
            case (Self.transfer, 3): (from, to) = (topics[1], topics[2])
            case (Self.transfer, 4): (from, to, n) = (topics[1], topics[2], 1); nfts.insert(asset)
            case (Self.deposit, 2) where Self.weth9.contains(asset): to = topics[1]
            case (Self.withdrawal, 2) where Self.weth9.contains(asset): from = topics[1]
            default: continue
            }
            if from.lowercased().hasSuffix(me) { changes[asset, default: 0] -= n }
            if to.lowercased().hasSuffix(me) { changes[asset, default: 0] += n }
        }
        changes = changes.filter { $0.value != 0 }
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
    /// A Uniswap swap (SwapRouter02.exactInputSingle): who gets what comes out.
    case swap(recipient: String)
    /// An ERC-4626 vault (Morpho): who gets the shares or the assets, and whose shares are spent (nil for a deposit).
    case vault(receiver: String, owner: String?)
    /// A lending pool (Aave's supply, deposit or withdraw): who gets the aTokens or the withdrawn asset.
    case lending(beneficiary: String)
    /// Merkl's Distributor.claim: whom each reward is paid to.
    case claim(recipients: [String])
    /// Permit2.approve: lets `spender` pull up to `amount` of `token` until `expiration` (unix seconds).
    case permit2Approve(token: String, spender: String, amount: Data, expiration: UInt64)
    /// The Universal Router's v4 swap in exactly this app's shape (UniswapV4.decodeExecute): it pays the caller.
    case v4Swap(UniswapV4.Swap)
    /// ERC-721 or ERC-1155 safeTransferFrom / safeBatchTransferFrom: NFTs (or game items) from `from` to `to`.
    case nftTransfer(from: String, to: String)
    /// Aave's approveDelegation or Morpho Blue's setAuthorization: `to` may borrow against, or manage, this wallet's positions.
    case delegation(to: String, granted: Bool)
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
        // Tempo's transferWithMemo pays like transfer: the same recipient check applies.
        case "a9059cbb", "95777d59": if let t = address(0), let a = word(1) { return .transfer(to: t, amount: a) }
        case "23b872dd": if let f = address(0), let t = address(1), let a = word(2) { return .transferFrom(from: f, to: t, amount: a) }
        case "a22cb465": if let o = address(0), let b = word(1) { return .setApprovalForAll(operator: o, approved: b.last == 1) }
        case "d505accf", "8fcbaf0c": return .permit
        case "04e45aaf": if let r = address(3) { return .swap(recipient: r) }
        // SwapRouter02.exactInput((bytes path, address recipient, uint256, uint256)): the tuple sits behind an offset.
        case "b858183f": if let r = address(2) { return .swap(recipient: r) }
        case "6e553f65": if let r = address(1) { return .vault(receiver: r, owner: nil) }
        case "b460af94", "ba087652": if let r = address(1), let o = address(2) { return .vault(receiver: r, owner: o) }
        // Aave: supply/deposit(asset, amount, onBehalfOf, referral) and withdraw(asset, amount, to): the third word.
        case "617ba037", "e8eda9df", "69328dec": if let b = address(2) { return .lending(beneficiary: b) }
        case "71ee95c0": if let r = Merkl.recipients(data) { return .claim(recipients: r) }
        case "87517c45": if let t = address(0), let s = address(1), let a = word(2), let e = ABI.uint(in: Data(args), word: 3) { return .permit2Approve(token: t, spender: s, amount: a, expiration: e) }
        // Any other Universal Router call stays a plain contract call (a site's own swap), read as before.
        case "3593564c": if let swap = UniswapV4.decodeExecute(data) { return .v4Swap(swap) }
        case "42842e0e", "b88d4fde", "f242432a", "2eb2c2d6": if let f = address(0), let t = address(1) { return .nftTransfer(from: f, to: t) }
        case "c04a8a10": if let d = address(0), let a = word(1) { return .delegation(to: d, granted: a.contains { $0 != 0 }) }
        case "eecea000": if let d = address(0), let b = word(1) { return .delegation(to: d, granted: b.contains { $0 != 0 }) }
        default: break
        }
        return .contract(selector: "0x" + selector)
    }

    /// What the transaction does, in words for the Touch ID prompt, which reads «ihatecrypto is trying to <this>»:
    /// «send 0.185357 USDC to 0x060b…9Ff0 on Tempo». Read from the calldata by the signer itself, never from the app's
    /// description of it; a token or contract it doesn't know is named by its address.
    public func summary(chainId: UInt64, to: String, value: UInt64) -> String {
        let net = "on " + (EVMRPC.names[chainId] ?? "network \(chainId)")
        func short(_ a: String) -> String { a.count > 12 ? "\(a.prefix(6))…\(a.suffix(4))" : a }
        func units(_ word: Data, _ decimals: Int16) -> String {
            let whole = word.reduce(Decimal(0)) { $0 * 256 + Decimal($1) }
            return NSDecimalNumber(decimal: whole / pow(10, Int(decimals))).stringValue
        }
        let coins = "\(units(ABI.uint(value), 18)) \(EVMRPC.coin(chainId))"
        if case .plain = self { return "send \(coins) to \(short(to)) \(net)" }
        // A token the signer can't name shows its raw units: an amount on the prompt, never none.
        func amount(_ word: Data, of token: String) -> String {
            EVMRPC.dollars[token.lowercased()].map { "\(units(word, 6)) \($0)" } ?? "\(units(word, 0)) units of the token \(short(token))"
        }
        let what = switch self {
        case .transfer(let recipient, let a): "send \(amount(a, of: to)) to \(short(recipient)) \(net)"
        case .approve(let spender, let a): "let \(short(spender)) spend exactly \(amount(a, of: to)) \(net)"
        case .increaseAllowance(let spender, let a): "let \(short(spender)) spend \(amount(a, of: to)) more \(net)"
        case .swap: "swap on Uniswap \(net), paying this wallet"
        case .v4Swap: "swap on Uniswap v4 \(net), paying this wallet"
        case .permit2Approve(let token, let spender, let a, _): "let \(short(spender)) spend exactly \(amount(a, of: token)) through Permit2 \(net)"
        case .vault(_, let owner): "\(owner == nil ? "deposit into" : "withdraw from") the vault \(short(to)) \(net)"
        case .lending: "use the lending pool \(short(to)) \(net), for this wallet"
        case .nftTransfer(_, let recipient): "send NFTs of \(short(to)) to \(short(recipient)) \(net)"
        case .contract where to.lowercased() == Tempo.feeManager: "pay Tempo's fees in USDC from now on"
        default: "call the contract \(short(to)) \(net)"
        }
        return value > 0 ? what + ", paying \(coins)" : what
    }

    /// An allowance none of ihatecrypto's own approvals reaches: ≥ 2⁹⁶ units (79 billion tokens of 18 decimals). Drainers
    /// ask for the maximum, 2¹²⁸ − 1 or 10³⁰ — past any balance; the old ≥ 2¹²⁸ line let the last two through.
    /// ponytail: more than 79 billion of an 18-decimal token can't be approved in one go; compare with the balance if that matters.
    static func unlimited(_ amount: Data) -> Bool { amount.prefix(20).contains { $0 != 0 } }

    /// Contracts ihatecrypto itself lets spend its tokens on a network: Uniswap's routers (and Permit2 on Robinhood Chain),
    /// Aave's pools, Morpho's vaults, Relay's depository and approval proxy (one address on every network, api.relay.link/chains
    /// 2026-10-03). An approve to any other spender needs it approved in person, like a recipient.
    public static func knownSpenders(chainId: UInt64) -> Set<String> {
        var s = ["0x4cd00e387622c35bddb9b4c962c136462338bc31", "0xccc88a9d1b4ed6b0eaba998850414b24f1c315be"]
        s += AaveV3.markets.filter { $0.rpc.chainId == chainId }.map(\.pool) + MorphoVault.vaults.filter { $0.rpc.chainId == chainId }.map(\.address)
        if let uni = UniswapV3.on(chainId) { s.append(uni.router) }
        if chainId == EVMRPC.robinhood.chainId { s += [UniswapV3.robinhoodRouter, UniswapV4.robinhoodRouter, UniswapV4.permit2] }
        return Set(s.map { $0.lowercased() })
    }

    /// Who gets money, or the right to spend it, from this call: `to` when it carries coins, a token's or NFT's recipient, and
    /// a spender that isn't one of `knownSpenders`. The signer signs only when each is the wallet's own or approved in person.
    public func payees(to: String, value: UInt64, chainId: UInt64) -> [String] {
        var out = value > 0 ? [to] : []
        switch self {
        case .transfer(let r, _), .nftTransfer(_, let r): out.append(r)
        case .approve(let s, _), .increaseAllowance(let s, _), .permit2Approve(_, let s, _, _):
            if !Self.knownSpenders(chainId: chainId).contains(s.lowercased()) { out.append(s) }
        default: break
        }
        return out
    }

    /// Why this must not be signed, or nil. `sender` is the user's own address.
    public func refusal(sender: String) -> String? {
        if case .swap(let recipient) = self, recipient.lowercased() != sender.lowercased() {
            return "The swap would pay \(recipient), not this wallet."
        }
        if case .lending(let beneficiary) = self, beneficiary.lowercased() != sender.lowercased() {
            return "The lending pool would credit \(beneficiary), not this wallet."
        }
        if case .v4Swap(let swap) = self, let why = UniswapV4.refusal(swap) { return why }
        if case .permit2Approve(_, _, let amount, let expiration) = self {
            if Self.unlimited(amount) { return "Unlimited spending through Permit2 — the drainers' main trick. ihatecrypto only approves exact amounts." }
            if expiration > UInt64(Date().timeIntervalSince1970) + 86_400 { return "A Permit2 approval for longer than a day. ihatecrypto approves for the one swap only." }
        }
        if case .claim(let recipients) = self, let other = recipients.first(where: { $0.lowercased() != sender.lowercased() }) ?? (recipients.isEmpty ? "nobody" : nil) {
            return "The rewards claim would pay \(other), not this wallet."
        }
        if case .vault(let receiver, let owner) = self {
            if receiver.lowercased() != sender.lowercased() { return "The vault would credit \(receiver), not this wallet." }
            if let owner, owner.lowercased() != sender.lowercased() { return "The vault call spends shares of \(owner), not this wallet's." }
        }
        return switch self {
        case .approve(_, let a) where Self.unlimited(a), .increaseAllowance(_, let a) where Self.unlimited(a):
            "Unlimited token spending approval — the drainers' main trick. ihatecrypto only approves exact amounts."
        case .setApprovalForAll(_, true):
            "Rights to all your NFTs in this contract (setApprovalForAll) — an NFT drainer trick. Refused."
        case .delegation(let to, true):
            "Lets \(to) borrow against or manage your lending positions (Aave credit delegation, Morpho authorization). Refused."
        case .permit:
            "A permit call grants approval to spend your tokens. Refused."
        case .transferFrom(let from, _, _) where from.lowercased() == sender.lowercased():
            "transferFrom from your address in your name — this is how tokens are pulled through an existing approval. Refused."
        default:
            nil
        }
    }
}
