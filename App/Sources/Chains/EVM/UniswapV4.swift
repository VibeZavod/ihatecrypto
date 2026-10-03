import Foundation
import WalletCore

/// Uniswap v4 on Robinhood Chain (developers.uniswap.org v4 deployments, checked 2026-10-01): one PoolManager holds every
/// pool; a swap goes through the Universal Router's V4_SWAP command, which pulls the input through Permit2. The formats are
/// the deployed router's own (its verified source on Blockscout): ExactInputSingleParams carries `minHopPriceX36`, which
/// older docs don't have.
public enum UniswapV4 {
    public static let robinhoodPoolManager = "0x8366a39cc670b4001a1121b8f6a443a643e40951"
    public static let robinhoodQuoter = "0x8dc178efb8111bb0973dd9d722ebeff267c98f94"
    public static let robinhoodRouter = "0x8876789976decbfcbbbe364623c63652db8c0904"
    public static let permit2 = "0x000000000022d473030f116ddee9f6b43ac78ba3"
    /// keccak256("Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)"): the PoolManager's event that
    /// names a pool's key once, when it is made.
    public static let initializeTopic = "0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438"

    /// A pool's identity: its two currencies (the lower address first), fee, tick spacing and hooks contract.
    public struct PoolKey: Equatable, Sendable {
        public let currency0: String
        public let currency1: String
        public let fee: UInt32
        public let tickSpacing: Int32
        public let hooks: String

        public init(currency0: String, currency1: String, fee: UInt32, tickSpacing: Int32, hooks: String) {
            self.currency0 = currency0.lowercased(); self.currency1 = currency1.lowercased()
            self.fee = fee; self.tickSpacing = tickSpacing; self.hooks = hooks.lowercased()
        }

        /// abi.encode(currency0, currency1, fee, tickSpacing, hooks): five words, tick spacing sign-extended.
        public func encoded() throws -> Data {
            let spacing = tickSpacing >= 0 ? ABI.uint(UInt64(tickSpacing)) : Data(repeating: 0xff, count: 24) + withUnsafeBytes(of: Int64(tickSpacing).bigEndian) { Data($0) }
            return try ABI.address(currency0) + ABI.address(currency1) + ABI.uint(UInt64(fee)) + spacing + ABI.address(hooks)
        }

        /// keccak256(abi.encode(key)): the id DexScreener and the PoolManager's events know the pool by.
        public var id: String? { (try? encoded()).map { "0x" + Keccak.hash256($0).hex } }
        public var hasHooks: Bool { hooks != "0x" + String(repeating: "0", count: 40) }
    }

    /// One exact-input swap in one pool, as the app sends it and as the signer reads it back.
    public struct Swap: Equatable, Sendable {
        public let key: PoolKey
        public let zeroForOne: Bool
        public let amountIn: Decimal
        public let amountOutMinimum: Decimal
        /// SETTLE_ALL: what is paid and at most how much; TAKE_ALL: what comes out and at least how much.
        public let settleCurrency: String
        public let settleMax: Decimal
        public let takeCurrency: String
        public let takeMin: Decimal
        public let deadline: UInt64
        public var currencyIn: String { zeroForOne ? key.currency0 : key.currency1 }
        public var currencyOut: String { zeroForOne ? key.currency1 : key.currency0 }
    }

    /// V4Quoter.quoteExactInputSingle((key, zeroForOne, exactAmount, hookData)): word 0 of the answer is amountOut.
    public static func quoteExactInputSingle(_ key: PoolKey, zeroForOne: Bool, amount: Decimal) throws -> Data {
        // The struct has a dynamic member: an offset to it, then key (5), zeroForOne, amount, hookData's offset, its length 0.
        Data([0xaa, 0x9d, 0x21, 0xcb]) + ABI.uint(0x20) + (try key.encoded()) + ABI.uint(zeroForOne ? 1 : 0) + (try ABI.word(amount))
            + ABI.uint(0x100) + ABI.uint(0)
    }

    /// The Universal Router's commands and the v4 actions this app sends, nothing else.
    static let v4SwapCommand: UInt8 = 0x10
    static let actions = Data([0x06, 0x0c, 0x0f])   // SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL

    /// UniversalRouter.execute(commands = [V4_SWAP], inputs = [abi.encode(actions, params)], deadline): the input is paid
    /// from this wallet through Permit2 (SETTLE_ALL, at most `amountIn`) and everything that comes out goes to the caller
    /// (TAKE_ALL pays msgSender, at least `amountOutMinimum`): there is no recipient to set.
    public static func execute(_ key: PoolKey, zeroForOne: Bool, amountIn: Decimal, amountOutMinimum: Decimal, deadline: UInt64) throws -> Data {
        let currencyIn = zeroForOne ? key.currency0 : key.currency1, currencyOut = zeroForOne ? key.currency1 : key.currency0
        // abi.encode(ExactInputSingleParams): offset to the struct; key, zeroForOne, amountIn, amountOutMinimum,
        // minHopPriceX36 (0: amountOutMinimum is the check), hookData at 10 words, empty.
        let swap = ABI.uint(0x20) + (try key.encoded()) + ABI.uint(zeroForOne ? 1 : 0) + (try ABI.word(amountIn)) + (try ABI.word(amountOutMinimum))
            + ABI.uint(0) + ABI.uint(0x140) + ABI.uint(0)
        let settle = try ABI.address(currencyIn) + ABI.word(amountIn)
        let take = try ABI.address(currencyOut) + ABI.word(amountOutMinimum)
        let input = Self.encodeBytesAndArray(actions, [swap, settle, take])
        let commands = Data([v4SwapCommand])
        return Data([0x35, 0x93, 0x56, 0x4c]) + ABI.uint(0x60) + ABI.uint(UInt64(0x60 + bytesValue(commands).count)) + ABI.uint(deadline)
            + bytesValue(commands) + dynamicArray([input])
    }

    /// Permit2.approve(token, spender, uint160 amount, uint48 expiration).
    public static func permit2Approve(token: String, spender: String, amount: Decimal, expiration: UInt64) throws -> Data {
        Data([0x87, 0x51, 0x7c, 0x45]) + (try ABI.address(token)) + (try ABI.address(spender)) + (try ABI.word(amount)) + ABI.uint(expiration)
    }

    /// Permit2.allowance(owner, token, spender) → (amount, expiration, nonce).
    public static func permit2Allowance(owner: String, token: String, spender: String) throws -> Data {
        Data([0x92, 0x7d, 0xa1, 0x05]) + (try ABI.address(owner)) + (try ABI.address(token)) + (try ABI.address(spender))
    }

    // MARK: Reading a call back (the signer)

    /// The swap in an execute call when it is exactly this app's shape — one V4_SWAP command whose actions are
    /// SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL, each well formed — else nil.
    public static func decodeExecute(_ data: Data) -> Swap? {
        let data = Data(data)
        guard data.count >= 4, data.prefix(4) == Data([0x35, 0x93, 0x56, 0x4c]) else { return nil }
        let args = Data(data.dropFirst(4))
        guard let commands = bytesAt(args, headWord: 0), commands == Data([v4SwapCommand]),
              let inputs = arrayAt(args, headWord: 1), inputs.count == 1,
              let deadline = ABI.uint(in: args, word: 2) else { return nil }
        let input = inputs[0]
        guard let actions = bytesAt(input, headWord: 0), actions == Self.actions,
              let params = arrayAt(input, headWord: 1), params.count == 3 else { return nil }
        // The swap's struct, behind its offset.
        guard let at = ABI.uint(in: params[0], word: 0), at == 0x20 else { return nil }
        let s = Data(params[0].dropFirst(0x20))
        // key (5), zeroForOne, amountIn, amountOutMinimum, minHopPriceX36, hookData's offset, its length: 11 words.
        guard s.count >= 11 * 32,
              let c0 = ABI.address(in: s, word: 0), let c1 = ABI.address(in: s, word: 1), let fee = ABI.uint(in: s, word: 2), fee < 1 << 24,
              let hooks = ABI.address(in: s, word: 4), let dir = ABI.uint(in: s, word: 5), dir <= 1,
              let amountIn = ABI.decimal(in: s, word: 6), let minOut = ABI.decimal(in: s, word: 7),
              ABI.uint(in: s, word: 9) == 0x140, ABI.uint(in: s, word: 10) == 0 else { return nil }
        let spacingWord = s.subdata(in: (3 * 32)..<(4 * 32))
        let spacing = Int32(truncatingIfNeeded: spacingWord.suffix(8).reduce(Int64(0)) { $0 << 8 | Int64($1) })
        guard params[1].count == 64, params[2].count == 64,
              let settleCurrency = ABI.address(in: params[1], word: 0), let settleMax = ABI.decimal(in: params[1], word: 1),
              let takeCurrency = ABI.address(in: params[2], word: 0), let takeMin = ABI.decimal(in: params[2], word: 1) else { return nil }
        return Swap(key: PoolKey(currency0: c0, currency1: c1, fee: UInt32(fee), tickSpacing: spacing, hooks: hooks), zeroForOne: dir == 1,
                    amountIn: amountIn, amountOutMinimum: minOut, settleCurrency: settleCurrency, settleMax: settleMax,
                    takeCurrency: takeCurrency, takeMin: takeMin, deadline: deadline)
    }

    /// Why the signer must not sign this swap, or nil: it pays from and to this wallet by construction (SETTLE_ALL and
    /// TAKE_ALL use the caller), so what's left is that it pays and takes the pool's own currencies, the most it may take
    /// is what goes in, something must come out, and no hooks contract runs in the middle.
    public static func refusal(_ s: Swap) -> String? {
        if s.key.hasHooks { return "The Uniswap v4 pool runs a hooks contract (\(s.key.hooks)): ihatecrypto swaps only in pools without one." }
        if s.settleCurrency.lowercased() != s.currencyIn { return "The swap would pay in \(s.settleCurrency), not the pool's \(s.currencyIn)." }
        if s.takeCurrency.lowercased() != s.currencyOut { return "The swap would take \(s.takeCurrency), not the pool's \(s.currencyOut)." }
        if s.settleMax != s.amountIn { return "The swap may take more than it swaps (\(s.settleMax) vs \(s.amountIn))." }
        if s.amountOutMinimum <= 0 || s.takeMin <= 0 { return "The swap has no minimum out: it could pay nothing back." }
        return nil
    }

    // MARK: ABI pieces

    static func bytesValue(_ d: Data) -> Data { ABI.uint(UInt64(d.count)) + d + Data(count: (32 - d.count % 32) % 32) }

    /// bytes[]: its length, an offset to each element (from after the length), the elements.
    static func dynamicArray(_ items: [Data]) -> Data {
        var head = Data(), tail = Data()
        for item in items {
            head += ABI.uint(UInt64(items.count * 32 + tail.count))
            tail += bytesValue(item)
        }
        return ABI.uint(UInt64(items.count)) + head + tail
    }

    /// abi.encode(bytes a, bytes[] b).
    static func encodeBytesAndArray(_ a: Data, _ b: [Data]) -> Data {
        ABI.uint(0x40) + ABI.uint(UInt64(0x40 + bytesValue(a).count)) + bytesValue(a) + dynamicArray(b)
    }

    /// The `bytes` whose offset is head word `i` of `d`. Offsets and lengths are the caller's numbers: each is held to the
    /// data's size before it becomes an Int, so 2⁶⁴ − 1 is refused instead of trapping.
    static func bytesAt(_ d: Data, headWord i: Int) -> Data? {
        guard let at = ABI.uint(in: d, word: i), at % 32 == 0, at < UInt64(d.count), Int(at) + 32 <= d.count,
              let length = ABI.uint(in: d.subdata(in: Int(at)..<d.count), word: 0), length <= UInt64(d.count),
              Int(at) + 32 + Int(length) <= d.count else { return nil }
        return d.subdata(in: (Int(at) + 32)..<(Int(at) + 32 + Int(length)))
    }

    /// The `bytes[]` whose offset is head word `i` of `d`.
    static func arrayAt(_ d: Data, headWord i: Int) -> [Data]? {
        guard let at = ABI.uint(in: d, word: i), at % 32 == 0, at < UInt64(d.count), Int(at) + 32 <= d.count else { return nil }
        let array = d.subdata(in: Int(at)..<d.count)
        guard let count = ABI.uint(in: array, word: 0), count <= 16 else { return nil }
        let body = array.dropFirst(32)
        var out: [Data] = []
        for k in 0..<Int(count) {
            guard let item = bytesAt(Data(body), headWord: k) else { return nil }
            out.append(item)
        }
        return out
    }
}
