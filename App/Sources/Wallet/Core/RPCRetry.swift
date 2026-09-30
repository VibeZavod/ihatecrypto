import Foundation

/// Asking a public node again. A throttle (429), a server error, a dropped connection or a node's bad second
/// («header not found», «node is behind») gets four more tries, 1, 2, 4 and 8 s apart; any other answer is final —
/// a revert or a short balance says the same the second time.
public enum RPCRetry {
    /// What an answer's reader throws: `again` = worth asking once more.
    public struct Again: Error {
        public let again: Bool
        public let error: Error
        public init(_ again: Bool, _ error: Error) { self.again = again; self.error = error }
    }

    public static let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
    static let dropped: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet,
                                             .dnsLookupFailed, .cannotFindHost]

    public static func run<T>(delays: [Duration] = delays, _ fetch: () async throws -> (Data, URLResponse),
                              answer: (Data, Int) throws -> T) async throws -> T {
        var attempt = 0
        while true {
            let failure: Error
            do {
                let (data, response) = try await fetch()
                do { return try answer(data, (response as? HTTPURLResponse)?.statusCode ?? 0) } catch let e as Again {
                    guard e.again else { throw e.error }
                    failure = e.error
                }
            } catch let e as URLError where dropped.contains(e.code) {
                failure = e
            }
            guard attempt < delays.count else { throw failure }
            try await Task.sleep(for: delays[attempt])
            attempt += 1
        }
    }

    /// A node's error message that a second ask may not get.
    public static func transient(_ message: String) -> Bool {
        let m = message.lowercased()
        guard !m.contains("revert") else { return false }
        return ["rate limit", "too many requests", "timeout", "timed out", "temporarily", "try again", "header not found",
                "node is behind", "service unavailable", "internal error", "overloaded"].contains { m.contains($0) }
    }
}
