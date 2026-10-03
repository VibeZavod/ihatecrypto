import Foundation
import WalletCore

/// Merkl, where most EVM protocols pay their rewards (Morpho's MORPHO, Aave's incentives, many vaults'): who is owed
/// what on each chain, and the Distributor's `claim` that pays it. The API gives each reward cumulatively, with a proof
/// against the root the Distributor holds; what claiming pays now is that amount less what was claimed before.
public enum Merkl {
    /// The Distributor: the same address on every chain Merkl pays out on.
    public static let distributor = "0x3ef3d8ba38ebe18db133cec108f4d14ce00dd9ae"
    /// The chains ihatecrypto signs on where Merkl pays out: Base, Arbitrum, Ethereum, Polygon.
    public static let chains: [UInt64] = [8453, 42161, 1, 137]

    public struct Reward: Sendable, Equatable {
        public let chainId: UInt64
        public let token: String
        public let symbol: String
        public let decimals: Int
        /// Everything ever earned, in the token's smallest units: the amount `claim` takes.
        public let amount: Decimal
        /// Already claimed, in the same units.
        public let claimed: Decimal
        public let proofs: [String]
        /// The root the proofs are for.
        public let root: String
        public let price: Decimal?

        public init(chainId: UInt64, token: String, symbol: String, decimals: Int, amount: Decimal, claimed: Decimal,
                    proofs: [String], root: String, price: Decimal?) {
            (self.chainId, self.token, self.symbol, self.decimals) = (chainId, token, symbol, decimals)
            (self.amount, self.claimed, self.proofs, self.root, self.price) = (amount, claimed, proofs, root, price)
        }

        /// What claiming pays now, in tokens.
        public var claimable: Decimal { (amount - claimed) / pow(10, decimals) }
        public var worthUSD: Decimal? { price.map { claimable * $0 } }
    }

    /// A sweep's floor: what the user said, never under $5 — below it the claim and the sale cost most of it in gas.
    public static func sweepFloor(_ asked: Decimal?) -> Decimal { max(asked ?? 5, 5) }

    /// What a sweep sells: each reward worth a dollar or more that isn't already the coin it ends in. Dust stays.
    public static func toSell(_ owed: [Reward], into: String?) -> [Reward] {
        owed.filter { ($0.worthUSD ?? 0) >= 1 && !["USDC", "USDG", into?.uppercased()].contains($0.symbol.uppercased()) }
    }

    /// What `user` can claim now on `chains`; a reward claimed in full isn't listed.
    public static func rewards(user: String, chains: [UInt64] = chains) async throws -> [Reward] {
        var out: [Reward] = []
        for chain in chains {
            var request = URLRequest(url: URL(string: "https://api.merkl.xyz/v4/users/\(user)/rewards?chainId=\(chain)")!, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw WalletError("Merkl answered \(status) for chain \(chain).") }
            out += try parse(data, user: user)
        }
        return out
    }

    /// The API's answer: `[{chain, rewards: [{root, recipient, amount, claimed, proofs, token: {chainId, address,
    /// decimals, symbol, price}}]}]`. Only rewards paid to `user` with something left to claim.
    public static func parse(_ data: Data, user: String) throws -> [Reward] {
        struct Chain: Decodable { let rewards: [Entry] }
        struct Entry: Decodable {
            let root: String, recipient: String, amount: String, claimed: String, proofs: [String], token: Token
            struct Token: Decodable { let chainId: UInt64, address: String, decimals: Int, symbol: String, price: Double? }
        }
        return try JSONDecoder().decode([Chain].self, from: data).flatMap(\.rewards).compactMap { e in
            guard e.recipient.lowercased() == user.lowercased(), let amount = Decimal(string: e.amount), let claimed = Decimal(string: e.claimed),
                  amount > claimed else { return nil }
            return Reward(chainId: e.token.chainId, token: e.token.address, symbol: e.token.symbol, decimals: e.token.decimals,
                          amount: amount, claimed: claimed, proofs: e.proofs, root: e.root, price: e.token.price.map { Decimal($0) })
        }
    }

    /// `claim(address[] users, address[] tokens, uint256[] amounts, bytes32[][] proofs)`: every reward in `rewards`
    /// paid to `user`.
    public static func claim(user: String, _ rewards: [Reward]) throws -> Data {
        func array(_ words: [Data]) -> Data { ABI.uint(UInt64(words.count)) + words.reduce(Data(), +) }
        let users = array(try rewards.map { _ in try ABI.address(user) })
        let tokens = array(try rewards.map { try ABI.address($0.token) })
        let amounts = array(try rewards.map { try ABI.word($0.amount) })
        let inner = try rewards.map { r in
            array(try r.proofs.map { p in
                guard let b = Data(hex: p), b.count == 32 else { throw WalletError("A Merkl proof isn't 32 bytes: \(p)") }
                return b
            })
        }
        // bytes32[][]: its length, an offset per proof (counted from right after the length), then each proof.
        var offsets = Data(), at = UInt64(32 * inner.count)
        for p in inner { offsets += ABI.uint(at); at += UInt64(p.count) }
        let proofs = ABI.uint(UInt64(inner.count)) + offsets + inner.reduce(Data(), +)
        // The head: where each of the four arrays starts, counted from the start of the arguments.
        var head = Data(), tail = Data(), start = UInt64(4 * 32)
        for part in [users, tokens, amounts, proofs] {
            head += ABI.uint(start)
            tail += part
            start += UInt64(part.count)
        }
        return Data([0x71, 0xee, 0x95, 0xc0]) + head + tail
    }

    /// The root the Distributor holds on this chain now (`getMerkleRoot()`): proofs for another one don't claim.
    public static func root(_ rpc: EVMRPC) async throws -> String {
        let data = try await rpc.read(distributor, Data([0x49, 0x59, 0x06, 0x57]))
        guard data.count >= 32 else { throw WalletError("The Merkl distributor gave no root on chain \(rpc.chainId).") }
        return "0x" + Data(data.prefix(32)).hex
    }

    /// The users a `claim` pays, read back from its calldata; nil when it isn't one.
    public static func recipients(_ data: Data) -> [String]? {
        guard data.count >= 4 + 32, data.prefix(4).hex == "71ee95c0" else { return nil }
        let args = Data(data.dropFirst(4))
        // A page's offset is held to the data's size before it becomes a word index (a huge one would trap).
        guard let at = ABI.uint(in: args, word: 0), at % 32 == 0, at < UInt64(args.count),
              let n = ABI.uint(in: args, word: Int(at / 32)), n <= 256 else { return nil }
        let first = Int(at / 32) + 1
        let users = (0..<Int(n)).compactMap { ABI.address(in: args, word: first + $0) }
        return users.count == Int(n) ? users : nil
    }
}
