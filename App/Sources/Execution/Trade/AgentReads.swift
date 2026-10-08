import EVMChain
import Foundation
import LLMCore
import SolanaChain
import WalletCore

/// The chat's reads of anything public: a contract's view function, a node's read call, Hyperliquid's info API and a
/// short list of public data APIs. Nothing here signs or sends. With them the model answers what no lookup was written
/// for («какой у меня health factor на Aave», «сколько в пуле Fluid», «какие у меня approvals») instead of waiting for
/// code. The user's own addresses go in as `me` ({evm}, {solana} in a URL) and come back out as `me`: the model never
/// sees them.
public enum AgentReads {
    public struct Me: Sendable {
        public var evm: String?
        public var solana: String?
        public init(evm: String?, solana: String?) { (self.evm, self.solana) = (evm, solana) }
    }

    public static let tools: Set<String> = ["call", "rpc", "hl", "fetch"]

    /// What one result may hold: the model rereads it with every later round.
    static let cap = 6000

    /// Read calls a node may be asked for; nothing that sends or signs.
    static let evmReads: Set<String> = ["eth_call", "eth_getBalance", "eth_getCode", "eth_getTransactionCount", "eth_getTransactionReceipt",
                                        "eth_getTransactionByHash", "eth_blockNumber", "eth_gasPrice", "eth_feeHistory", "eth_getBlockByNumber",
                                        "eth_getLogs", "eth_getStorageAt", "eth_maxPriorityFeePerGas", "eth_chainId"]
    static let solanaReads: Set<String> = ["getAccountInfo", "getBalance", "getMultipleAccounts", "getTokenAccountsByOwner", "getTokenAccountBalance",
                                           "getTokenSupply", "getTokenLargestAccounts", "getSignaturesForAddress", "getTransaction", "getSlot",
                                           "getEpochInfo", "getRecentPrioritizationFees", "getInflationRate", "getVoteAccounts"]
    /// Public data APIs `fetch` reads (GET only), plus every Blockscout explorer.
    static let hosts: Set<String> = ["api.llama.fi", "yields.llama.fi", "coins.llama.fi", "stablecoins.llama.fi", "bridges.llama.fi",
                                     "api.dexscreener.com", "api.geckoterminal.com", "api.coingecko.com", "lite-api.jup.ag",
                                     "api.kamino.finance", "api-v2.pendle.finance", "explorer.optimism.io"]

    public static func answer(_ tool: String, _ arg: String, me: Me) async -> String {
        let out: String
        do {
            switch tool {
            case "call": out = try await call(arg, me: me)
            case "rpc": out = try await rpc(arg, me: me)
            case "hl": out = try await hl(arg, me: me)
            default: out = try await fetch(arg, me: me)
            }
        } catch {
            out = "\(tool) failed: \(error.localizedDescription)"
        }
        return masked(out, me)
    }

    // MARK: call <network> <contract> <function(types)(returns)> [args…]

    static func call(_ arg: String, me: Me) async throws -> String {
        let parts = arg.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 3, let net = network(parts[0]) else {
            throw LLMError("Write it as: call <network> <contract> <function(argTypes)(returnTypes)> [args…], network one of \(EVMNetwork.all.map(\.key).joined(separator: ", ")).")
        }
        guard let m = parts[2].wholeMatch(of: /(\w+)\(([^()]*)\)(?:\(([^()]*)\))?/) else {
            throw LLMError("«\(parts[2])» isn't a function like balanceOf(address)(uint256): no spaces, no tuples.")
        }
        let types = list(m.2), returns = list(m.3 ?? "")
        let args = parts.dropFirst(3).map { $0 == "me" ? me.evm ?? "" : $0 }
        guard types.count == args.count else { throw LLMError("\(m.1) takes \(types.count) arguments; \(args.count) given.") }
        let result = try await net.rpc.read(parts[1] == "me" ? me.evm ?? "" : parts[1], try encode(String(m.1), types, args))
        guard !returns.isEmpty else { return "\(m.1) on \(net.name) returned 0x\(result.hex) (give the return types, e.g. (uint256), to read it)" }
        return "\(m.1) on \(net.name) → " + decode(returns, result).joined(separator: ", ")
            + " (numbers in the token's smallest units: divide by 10^decimals)"
    }

    /// The call's data: the function's 4-byte selector, then a word per argument.
    static func encode(_ name: String, _ types: [String], _ args: [String]) throws -> Data {
        var data = Data(Keccak.hash256(Data("\(name)(\(types.joined(separator: ",")))".utf8)).prefix(4))
        for (t, a) in zip(types, args) { data += try word(t, a) }
        return data
    }

    static func list(_ s: some StringProtocol) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func network(_ name: String) -> EVMNetwork? {
        let aliases = ["eth": "ethereum", "mainnet": "ethereum", "bsc": "bnb", "arb": "arbitrum", "op": "optimism", "matic": "polygon"]
        let key = name.lowercased()
        return EVMNetwork.named(aliases[key] ?? key)
    }

    static func word(_ type: String, _ value: String) throws -> Data {
        switch type {
        case "address": return try ABI.address(value)
        case "bool": return ABI.uint(["true", "1"].contains(value.lowercased()) ? 1 : 0)
        case let t where t.hasPrefix("uint") || t.hasPrefix("int"):
            if value.hasPrefix("0x"), let d = Data(hex: value), d.count <= 32 { return Data(count: 32 - d.count) + d }
            guard let n = Decimal(string: value), n >= 0 else { throw LLMError("«\(value)» isn't a whole number ≥ 0 for \(t).") }
            return try ABI.word(n)
        case let t where t.hasPrefix("bytes") && t.count > 5:
            guard let d = Data(hex: value), d.count <= 32 else { throw LLMError("«\(value)» isn't hex of at most 32 bytes for \(t).") }
            return d + Data(count: 32 - d.count)
        default:
            throw LLMError("Arguments of type «\(type)» aren't read here: address, bool, uint/int, bytes1–32 only.")
        }
    }

    static func decode(_ types: [String], _ data: Data) -> [String] {
        let data = Data(data)
        func slot(_ i: Int) -> Data? { data.count >= (i + 1) * 32 ? data.subdata(in: (i * 32)..<((i + 1) * 32)) : nil }
        func number(_ w: Data) -> Decimal { w.reduce(Decimal(0)) { $0 * 256 + Decimal($1) } }
        func dynamic(_ i: Int) -> Data? {
            guard let offset = ABI.uint(in: data, word: i), offset % 32 == 0, let length = ABI.uint(in: data, word: Int(offset / 32)),
                  data.count >= Int(offset) + 32 + Int(length) else { return nil }
            return data.subdata(in: (Int(offset) + 32)..<(Int(offset) + 32 + Int(length)))
        }
        return types.enumerated().map { i, t in
            switch t {
            case "string": return dynamic(i).flatMap { String(data: $0, encoding: .utf8) }.map { "«\($0)»" } ?? "?"
            case "bytes": return dynamic(i).map { "0x" + $0.hex } ?? "?"
            default: break
            }
            guard let w = slot(i) else { return "?" }
            switch t {
            case "address": return "0x" + w.suffix(20).hex
            case "bool": return w.contains { $0 != 0 } ? "true" : "false"
            case let t where t.hasPrefix("uint"):
                return w.allSatisfy { $0 == 0xff } ? "max (2^256−1, unlimited)" : "\(number(w))"
            case let t where t.hasPrefix("int"):
                // Two's complement: a set top bit is negative.
                return w.first.map { $0 >= 0x80 } == true ? "-\(number(Data(w.map { ~$0 })) + 1)" : "\(number(w))"
            default:
                return "0x" + w.hex
            }
        }
    }

    // MARK: rpc <network|solana> <method> [JSON params]

    static func rpc(_ arg: String, me: Me) async throws -> String {
        let parts = arg.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { throw LLMError("Write it as: rpc <network|solana> <method> [JSON params array].") }
        let solana = parts[0].lowercased() == "solana"
        let mine = (solana ? me.solana : me.evm) ?? ""
        let text = (parts.count > 2 ? parts[2] : "[]").replacingOccurrences(of: "\"me\"", with: "\"\(mine)\"")
        guard let params = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] else { throw LLMError("The params must be a JSON array.") }
        let result: Any
        if solana {
            guard solanaReads.contains(parts[1]) else { throw LLMError("Only reads on Solana: \(solanaReads.sorted().joined(separator: ", ")).") }
            result = try await SolanaRPC().call(parts[1], params)
        } else {
            guard let net = network(parts[0]) else { throw LLMError("No network «\(parts[0])»: solana or \(EVMNetwork.all.map(\.key).joined(separator: ", ")).") }
            guard evmReads.contains(parts[1]) else { throw LLMError("Only reads: \(evmReads.sorted().joined(separator: ", ")).") }
            result = try await net.rpc.call(parts[1], params)
        }
        return compact(result)
    }

    // MARK: hl <JSON body> [find <words>]

    static func hl(_ arg: String, me: Me) async throws -> String {
        let (body, find) = split(arg)
        let text = body.replacingOccurrences(of: "\"me\"", with: "\"\(me.evm ?? "")\"")
        guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], json["type"] != nil else {
            throw LLMError("Write it as: hl {\"type\": \"…\", …} — the body of a Hyperliquid info request.")
        }
        return shaped(try await HTTP.post("https://api.hyperliquid.xyz/info", json: json, timeout: 20), find: find)
    }

    // MARK: fetch <URL> [find <words>]

    static func fetch(_ arg: String, me: Me) async throws -> String {
        let (raw, find) = split(arg)
        let address = raw.replacingOccurrences(of: "{evm}", with: me.evm ?? "").replacingOccurrences(of: "{solana}", with: me.solana ?? "")
        guard let url = URL(string: address), url.scheme == "https", let host = url.host() else { throw LLMError("«\(raw)» isn't an https URL.") }
        guard hosts.contains(host) || host.hasSuffix(".blockscout.com") else {
            throw LLMError("\(host) isn't among the public APIs read here: \(hosts.sorted().joined(separator: ", ")), <chain>.blockscout.com.")
        }
        return shaped(try await HTTP.get(url.absoluteString, timeout: 20), find: find)
    }

    /// «<what> find <words>»: the words keep only the list items holding all of them.
    static func split(_ arg: String) -> (String, [String]) {
        guard let r = arg.range(of: " find ", options: .backwards) else { return (arg.trimmingCharacters(in: .whitespaces), []) }
        return (String(arg[..<r.lowerBound]).trimmingCharacters(in: .whitespaces),
                arg[r.upperBound...].lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// JSON, compact; with `find`, only the items of its longest list that hold every word.
    static func shaped(_ data: Data, find: [String]) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            let text = String(decoding: data.prefix(cap), as: UTF8.self)
            return text.lowercased().contains("<html") ? "That's a web page, not JSON: only JSON APIs are read." : text
        }
        guard !find.isEmpty else {
            let text = compact(json)
            return text.count <= cap ? text : String(text.prefix(cap)) + "… (cut at \(cap) characters: add «find <words>» to keep only the items with them)"
        }
        guard let items = longestList(json) else { return "No list in the answer to look through: " + String(compact(json).prefix(cap)) }
        let hits = items.filter { item in
            let s = compact(item).lowercased()
            return find.allSatisfy(s.contains)
        }
        var out = "\(hits.count) of \(items.count) items hold «\(find.joined(separator: " "))»:"
        for hit in hits {
            let line = compact(hit)
            guard out.count + line.count < cap else { out += "\n… (the rest cut: narrow it with more words)"; break }
            out += "\n" + line
        }
        return out
    }

    static func longestList(_ json: Any, depth: Int = 0) -> [Any]? {
        var best = json as? [Any]
        guard depth < 4 else { return best }
        let children: [Any] = (json as? [String: Any]).map { Array($0.values) } ?? []
        for child in children {
            if let found = longestList(child, depth: depth + 1), found.count > (best?.count ?? 0) { best = found }
        }
        return best
    }

    static func compact(_ json: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\(json)"
    }

    /// The user's own addresses, back as `me`.
    static func masked(_ text: String, _ me: Me) -> String {
        var out = text
        for a in [me.evm, me.solana].compactMap({ $0 }) where a.count > 20 {
            out = out.replacingOccurrences(of: a, with: "me", options: .caseInsensitive)
        }
        return out
    }
}
