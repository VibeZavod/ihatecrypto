import Foundation
import LLMCore
import WalletCore

/// Paying for an API on Tempo — MPP, the «Payment» HTTP auth scheme (paymentauth.org, the x402 flow with receipts).
/// The service answers 402 with a challenge: this much USDC on Tempo to this payee. ihatecrypto pays it itself (push
/// mode: its own transfer, signed after Confirm) and asks again with the transaction's hash as the credential.
/// Pull mode (a signed Tempo 0x76 transaction the service sends) and sessions aren't supported: the signer signs only
/// its own EIP-1559 transfers, so a service that takes only those is refused with the reason.
public enum MPP {
    /// The one token ihatecrypto pays in: USDC on Tempo, 6 decimals.
    public static let usdc = "0x20c000000000000000000000b9537d11c60e8b50"
    public static let chainId: UInt64 = 4217

    public struct Challenge: Equatable, Sendable {
        /// The auth-params as the service sent them: the credential echoes them unchanged.
        public let params: [String: String]
        /// USDC units.
        public let amount: UInt64
        public let payee: String
        public let memo: Data?
        public let expires: Date?

        public var realm: String { params["realm"] ?? "" }
        public var purpose: String? { params["description"] }
        /// «Payment-Authorization» when the service keeps Authorization for its own login.
        public var field: String { params["header"] ?? "Authorization" }
        public var usdc: Decimal { Decimal(amount) / 1_000_000 }
    }

    /// The Payment challenges in a WWW-Authenticate value, each as its auth-params (a value may list several schemes).
    static func challenges(_ header: String) -> [[String: String]] {
        var out: [[String: String]] = [], current: [String: String]?, scheme = ""
        for m in header.matches(of: /(?:([A-Za-z][\w-]*)\s+)?([A-Za-z][\w-]*)=("(?:[^"\\]|\\.)*"|[^\s,]+)/) {
            if let s = m.1 {
                if let c = current, scheme == "payment" { out.append(c) }
                scheme = s.lowercased()
                current = [:]
            }
            var value = String(m.3)
            if value.hasPrefix("\"") {
                value = String(value.dropFirst().dropLast()).replacing(/\\(.)/) { String($0.1) }
            }
            current?[String(m.2).lowercased()] = value
        }
        if let c = current, scheme == "payment" { out.append(c) }
        return out
    }

    /// The challenge ihatecrypto can pay, or why none: USDC on Tempo, a charge of more than zero, push mode allowed.
    public static func challenge(_ header: String, now: Date = Date()) -> Result<Challenge, Refusal> {
        let all = challenges(header)
        guard let p = all.first(where: { $0["method"] == "tempo" && $0["intent"] == "charge" }) else {
            let offered = all.map { "\($0["method"] ?? "?") \($0["intent"] ?? "?")" }.joined(separator: ", ")
            return .failure(Refusal(offered.isEmpty ? "The service asked for payment without an MPP challenge." :
                "The service takes \(offered); ihatecrypto pays only a one-time charge in USDC on Tempo."))
        }
        guard let id = p["id"], !id.isEmpty, p["realm"] != nil, let encoded = p["request"],
              let raw = base64url(encoded), let request = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return .failure(Refusal("The service's payment request can't be read."))
        }
        let details = request["methodDetails"] as? [String: Any] ?? [:]
        guard let amount = (request["amount"] as? String).flatMap({ UInt64($0) }), amount > 0 else {
            return .failure(Refusal("The service asks for a zero-amount proof or an amount that can't be read; ihatecrypto only pays real charges."))
        }
        guard (request["currency"] as? String)?.lowercased() == usdc else {
            return .failure(Refusal("The service charges in \(request["currency"] as? String ?? "an unknown token"); ihatecrypto pays in USDC on Tempo."))
        }
        if let chain = (details["chainId"] as? NSNumber)?.uint64Value, chain != chainId {
            return .failure(Refusal("The service wants payment on network \(chain), not Tempo mainnet."))
        }
        guard let payee = request["recipient"] as? String, payee.wholeMatch(of: /0x[0-9a-fA-F]{40}/) != nil else {
            return .failure(Refusal("The service's payee isn't an address."))
        }
        if let splits = details["splits"] as? [Any], !splits.isEmpty {
            return .failure(Refusal("The service splits the payment between several payees; ihatecrypto pays one."))
        }
        if let modes = details["supportedModes"] as? [String], !modes.contains("push") {
            return .failure(Refusal("The service takes only a transaction it sends itself (pull mode); ihatecrypto sends its own and proves it with the hash."))
        }
        if details["feePayer"] as? Bool == true {
            return .failure(Refusal("The service pays the fee itself (sponsored mode), which needs a transaction it sends; ihatecrypto sends its own."))
        }
        var memo: Data?
        if let m = details["memo"] as? String {
            guard m.wholeMatch(of: /0x[0-9a-fA-F]{64}/) != nil, let d = Data(hex: m) else {
                return .failure(Refusal("The service's memo isn't 32 bytes."))
            }
            memo = d
        }
        let expires = p["expires"].flatMap(date)
        if let expires, expires <= now { return .failure(Refusal("The service's price quote has expired; ask again.")) }
        return .success(Challenge(params: p, amount: amount, payee: payee, memo: memo, expires: expires))
    }

    public struct Refusal: LocalizedError, Equatable, Sendable {
        public let reason: String
        init(_ reason: String) { self.reason = reason }
        public var errorDescription: String? { reason }
    }

    /// The header value that proves the payment: «Payment <base64url JSON>» with the challenge echoed, the transaction's
    /// hash and the payer as a did:pkh.
    public static func credential(_ c: Challenge, hash: String, payer: String) -> String {
        let echoed = c.params.filter { ["id", "realm", "method", "intent", "request", "description", "opaque", "digest", "expires", "header"].contains($0.key) }
        let body: [String: Any] = ["challenge": echoed, "payload": ["type": "hash", "hash": hash], "source": "did:pkh:eip155:\(chainId):\(payer)"]
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return "Payment " + json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// The request as the service documents it; `credential` goes in the field its challenge named.
    public static func call(_ method: String, _ url: String, _ body: String?, credential: (field: String, value: String)? = nil) async throws -> (Int, [String: String], Data) {
        guard let u = URL(string: url), u.scheme == "https" else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: u, timeoutInterval: 60)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let credential { request.setValue(credential.value, forHTTPHeaderField: credential.field) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { $0["\($1.key)".lowercased()] = "\($1.value)" }
        return (http?.statusCode ?? 0, headers, data)
    }

    /// A service's answer for the chat: JSON indented, cut at `limit` characters.
    public static func shown(_ data: Data, limit: Int = 1500) -> String {
        let text = (try? JSONSerialization.jsonObject(with: data)).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .withoutEscapingSlashes]) }
            .map { String(decoding: $0, as: UTF8.self) } ?? String(decoding: data, as: UTF8.self)
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    // MARK: Directory

    /// The services that take MPP payments (mpp.dev's directory) matching the words, with their endpoints and prices,
    /// for the model's «services» lookup.
    public static func search(_ query: String) async -> String {
        guard let services = await directory() else { return "The MPP directory (mpp.dev) didn't answer." }
        let hits = rank(services, query)
        guard !hits.isEmpty else { return "No MPP service matches «\(query)». Try broader words (email, search, image, flights, phone, mail)." }
        return hits.map { describe($0, endpoints: 6) }.joined(separator: "\n\n")
            + "\n\nTo pay one: the form «pay <METHOD> <service URL + path> <JSON body>». For the exact body fields look up «service <id>»."
    }

    /// The six services that fit the words best.
    static func rank(_ services: [[String: Any]], _ query: String) -> [[String: Any]] {
        var words = tokens(query).filter { $0.count > 1 && !["api", "apis", "service", "services", "pay", "paid", "request", "the", "for", "via", "tempo", "mpp"].contains($0) }
        // A coin's name is the word «crypto» to the directory: «BTC price» is CoinGecko's.
        // ponytail: a short list; the model usually writes «crypto» itself.
        if words.contains(where: ["bitcoin", "btc", "ethereum", "eth", "solana", "sol", "coin", "coins", "token", "tokens"].contains) { words.append("crypto") }
        // A word in the name counts most, then in the tags, then anywhere in what it does; a word matches the start of
        // one there («price» — «prices»). Plain substrings ranked a fax service «priced per page» over CoinGecko.
        func score(_ s: [String: Any]) -> Int {
            let name = tokens("\(s["id"] ?? "") \(s["name"] ?? "")")
            let tags = tokens(((s["tags"] as? [String] ?? []) + (s["categories"] as? [String] ?? [])).joined(separator: " "))
            let rest = tokens("\(s["description"] ?? "") " + ((s["endpoints"] as? [[String: Any]])?.compactMap { $0["description"] as? String }.joined(separator: " ") ?? ""))
            return words.reduce(0) { sum, w in
                sum + (name.contains { $0.hasPrefix(w) } ? 5 : tags.contains { $0.hasPrefix(w) } ? 2 : rest.contains { $0.hasPrefix(w) } ? 1 : 0)
            }
        }
        return services.map { ($0, score($0)) }.filter { words.isEmpty || $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(6).map(\.0)
    }

    static func tokens(_ text: String) -> [String] { text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }

    /// One service in full: every endpoint and price, and the start of its docs for the request fields.
    public static func service(_ id: String) async -> String {
        guard let services = await directory() else { return "The MPP directory (mpp.dev) didn't answer." }
        guard let s = services.first(where: { ($0["id"] as? String)?.lowercased() == id.lowercased().trimmingCharacters(in: .whitespaces) }) else {
            return "No MPP service «\(id)». Search with «services <words>» first."
        }
        var text = describe(s, endpoints: 40)
        if let docs = (s["docs"] as? [String: Any])?["llmsTxt"] as? String, let data = try? await HTTP.get(docs, timeout: 10) {
            text += "\nDocs (\(docs)):\n" + String(decoding: data.prefix(2500), as: UTF8.self)
        }
        return text
    }

    static func describe(_ s: [String: Any], endpoints limit: Int) -> String {
        let base = s["serviceUrl"] as? String ?? ""
        let endpoints = (s["endpoints"] as? [[String: Any]] ?? []).prefix(limit).map { e -> String in
            let pay = e["payment"] as? [String: Any]
            let price: String = if let a = (pay?["amount"] as? String).flatMap({ Decimal(string: $0) }), a > 0 {
                "$" + Fmt.num(a / 1_000_000, maxFraction: 6)
            } else if pay?["intent"] as? String == "session" { "per use (session: ihatecrypto can't pay these yet)" } else if pay == nil { "free" } else { "price in its 402 answer" }
            return "  \(e["method"] as? String ?? "GET") \(base)\(e["path"] as? String ?? "") — \(e["description"] as? String ?? ""), \(price)"
        }
        return "\(s["name"] as? String ?? "?") (id \(s["id"] as? String ?? "?")): \(s["description"] as? String ?? "")\n" + endpoints.joined(separator: "\n")
    }

    // ponytail: the directory is read on every lookup (≈ 400 KB); cache it if lookups get frequent.
    static func directory() async -> [[String: Any]]? {
        guard let data = try? await HTTP.get("https://mpp.dev/api/services", timeout: 15),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return j["services"] as? [[String: Any]]
    }
}
