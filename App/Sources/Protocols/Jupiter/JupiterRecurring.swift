import Foundation

/// Jupiter's on-chain DCA (Recurring v1, program DCA265…): the whole amount goes into an order account of the user's
/// own and Jupiter's keepers swap one part every interval; what's bought comes to the wallet after each fill, and
/// cancelling returns what wasn't used, with the accounts' rent. Keyless at api.jup.ag (0.5 requests a second).
/// Minimums, checked by Jupiter: $100 in all, $50 an order, 2 orders. Its successor (DCA in Trigger V2) keeps the money
/// in a custodial vault and needs Jupiter's co-signature, which the guard rightly refuses — so it isn't used.
public enum JupiterRecurring {
    static let base = "https://api.jup.ag/recurring/v1"
    public static let minTotalUSD: Decimal = 100
    public static let minOrderUSD: Decimal = 50

    public struct Order: Sendable, Equatable {
        public let key: String
        public let inputMint: String
        public let outputMint: String
        /// In the input token: put in, spent so far, spent per swap.
        public let deposited: Decimal
        public let used: Decimal
        public let perCycle: Decimal
        /// Seconds between swaps.
        public let every: Int
        /// In the output token, bought so far (sent to the wallet after each fill).
        public let received: Decimal
        public let createdAt: Date?
        public let fills: Int
    }

    /// Unsigned order transaction: `amount` raw input units split into `orders` swaps `every` seconds apart, the first
    /// one right away.
    public static func createOrder(user: String, input: String, output: String, amount: UInt64, orders: Int, every: Int) async throws -> (requestId: String, wire: Data) {
        try await transaction("createOrder", [
            "user": user, "inputMint": input, "outputMint": output,
            "params": ["time": ["inAmount": amount, "numberOfOrders": orders, "interval": every,
                                "minPrice": NSNull(), "maxPrice": NSNull(), "startAt": NSNull()]],
        ])
    }

    /// Unsigned transaction that closes `order`: the input not yet swapped and the rent come back to `user`.
    public static func cancelOrder(user: String, order: String) async throws -> (requestId: String, wire: Data) {
        try await transaction("cancelOrder", ["order": order, "user": user, "recurringType": "time"])
    }

    /// The user's running orders, newest first.
    public static func orders(user: String) async throws -> [Order] {
        var all: [Order] = []
        for page in 1...5 {
            let url = URL(string: "\(base)/getRecurringOrders?user=\(user)&orderStatus=active&recurringType=time&includeFailedTx=false&page=\(page)")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw JupiterError(String(decoding: data.prefix(300), as: UTF8.self))
            }
            all += (j["time"] as? [[String: Any]] ?? []).compactMap(order)
            if page >= (j["totalPages"] as? Int ?? 0) { break }
        }
        return all.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    static func order(_ o: [String: Any]) -> Order? {
        func number(_ key: String) -> Decimal {
            if let s = o[key] as? String { return Decimal(string: s) ?? 0 }
            return (o[key] as? NSNumber)?.decimalValue ?? 0
        }
        guard let key = o["orderKey"] as? String, let input = o["inputMint"] as? String, let output = o["outputMint"] as? String else { return nil }
        let created = (o["createdAt"] as? String).flatMap { s in
            (try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
                ?? (try? Date(s, strategy: .iso8601))
        }
        return Order(key: key, inputMint: input, outputMint: output, deposited: number("inDeposited"), used: number("inUsed"),
                     perCycle: number("inAmountPerCycle"), every: NSDecimalNumber(decimal: number("cycleFrequency")).intValue,
                     received: number("outReceived"), createdAt: created, fills: (o["trades"] as? [Any])?.count ?? 0)
    }

    private static func transaction(_ path: String, _ body: [String: Any]) async throws -> (requestId: String, wire: Data) {
        var request = URLRequest(url: URL(string: "\(base)/\(path)")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = j?["requestId"] as? String, let b64 = j?["transaction"] as? String, let wire = Data(base64Encoded: b64) else {
            // «Each order valued at 30.00 USDC, minimum is 50.00 USDC»: Jupiter's own words are the clearest.
            throw JupiterError(j?["error"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self))
        }
        return (id, wire)
    }
}
