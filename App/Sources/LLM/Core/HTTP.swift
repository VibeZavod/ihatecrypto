import Foundation

public struct NetError: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum HTTP {
    public static func post(_ url: String, json body: [String: Any], headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await send(request(url, method: "POST", body: data, contentType: "application/json", headers: headers, timeout: timeout))
    }

    public static func post(_ url: String, form: [String: String], timeout: TimeInterval = 15) async throws -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        return try await send(request(url, method: "POST", body: Data(body.utf8), contentType: "application/x-www-form-urlencoded", headers: [:], timeout: timeout))
    }

    public static func get(_ url: String, headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> Data {
        try await send(request(url, method: "GET", body: nil, contentType: nil, headers: headers, timeout: timeout))
    }

    public static func request(
        _ url: String, method: String, body: Data?, contentType: String?, headers: [String: String], timeout: TimeInterval
    ) throws -> URLRequest {
        guard let u = URL(string: url) else { throw NetError(message: "Invalid URL: \(url)") }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = method
        r.httpBody = body
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (key, value) in headers { r.setValue(value, forHTTPHeaderField: key) }
        return r
    }

    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, body: data)
        return data
    }

    public static func check(_ response: URLResponse, body: Data) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw NetError(message: "HTTP \(code): \(String(decoding: body.prefix(300), as: UTF8.self))")
        }
    }
}
