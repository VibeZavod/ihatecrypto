import Foundation
import LLMCore

/// Any service with the OpenAI chat-completions format: DeepSeek, OpenAI, Anthropic, xAI, Gemini, Ollama, LM Studio.
/// A new one is a new preset, not new code.
public struct OpenAICompatible: LLMProvider {
    public let info: ProviderInfo
    public let baseURL: String
    let jsonMode: Bool

    public init(info: ProviderInfo, baseURL: String, jsonMode: Bool = true) {
        self.info = info
        self.baseURL = baseURL
        self.jsonMode = jsonMode
    }

    public static let presets: [OpenAICompatible] = [
        .init(info: ProviderInfo(id: "deepseek", name: "DeepSeek API", kind: .apiKey, defaultModel: "deepseek-flash",
                                 note: "Key from platform.deepseek.com.", takesKey: true, models: ["deepseek-flash", "deepseek-v4-pro"]),
              baseURL: "https://api.deepseek.com"),
        .init(info: ProviderInfo(id: "openai", name: "OpenAI API", kind: .apiKey, defaultModel: "gpt-6.1-sol",
                                 note: "Key from platform.openai.com, billed separately from a ChatGPT subscription.", takesKey: true,
                                 models: ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna"]),
              baseURL: "https://api.openai.com/v1"),
        .init(info: ProviderInfo(id: "anthropic", name: "Anthropic API", kind: .apiKey, defaultModel: "claude-opus-5-5",
                                 note: "Key from platform.claude.com, billed separately from a Claude subscription.", takesKey: true,
                                 models: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-haiku-4-5"]),
              baseURL: "https://api.anthropic.com/v1", jsonMode: false),
        .init(info: ProviderInfo(id: "xai", name: "xAI Grok API", kind: .apiKey, defaultModel: "grok-4.7",
                                 note: "Key from console.x.ai, paid with credits.", takesKey: true, models: ["grok-4.7", "grok-4.6"]),
              baseURL: "https://api.x.ai/v1"),
        .init(info: ProviderInfo(id: "gemini", name: "Google Gemini API", kind: .apiKey, defaultModel: "gemini-3.8-flash",
                                 note: "Key from Google AI Studio.", takesKey: true, models: ["gemini-3.8-flash"]),
              baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"),
        .init(info: ProviderInfo(id: "ollama", name: "Ollama on this Mac", kind: .local, defaultModel: "qwen3.8:27b",
                                 note: "No network or key. Download the model first: ollama pull qwen3.8:27b (or gemma4:12b for less memory).",
                                 models: ["qwen3.8:27b", "gemma4:12b"]),
              baseURL: "http://localhost:11434/v1"),
        .init(info: ProviderInfo(id: "lmstudio", name: "LM Studio on this Mac", kind: .local, defaultModel: "",
                                 note: "No network or key. Start the server in LM Studio and pick a model from the list."),
              baseURL: "http://localhost:1234/v1", jsonMode: false),
    ]

    public func client(_ credential: Credential?, save: @escaping SaveCredential) throws -> any LLMClient {
        // Ollama through its own API: the OpenAI-style one can't widen its 4096-token window, which cut the start of
        // ihatecrypto's instructions (≈ 5k tokens) and any long message (docs: faq, openai-compatibility; 2026-10-06).
        info.id == "ollama" ? OllamaChatClient(base: String(baseURL.dropLast(3))) : try chatClient(credential)
    }

    public func models(_ credential: Credential?) async throws -> [String] {
        try await chatClient(credential).models()
    }

    func chatClient(_ credential: Credential?) throws -> OpenAIChatClient {
        var key: String?
        if case .apiKey(let k) = credential { key = k }
        if info.takesKey, key == nil { throw LLMError("\(info.name): add a key in Settings.") }
        return OpenAIChatClient(baseURL: baseURL, key: key, jsonMode: jsonMode)
    }
}

/// Ollama's /api/chat with a context window that holds the instructions, the brief and a long message: `num_ctx` per
/// request, streamed as one JSON object a line.
public struct OllamaChatClient: LLMClient {
    let base: String
    // ponytail: one size for every model; a Mac short of memory for 16k on a big model would want it from /api/show.
    static let context = 16_384

    func body(_ r: LLMRequest, stream: Bool) -> [String: Any] {
        var body: [String: Any] = ["model": r.model, "stream": stream, "options": ["num_ctx": Self.context],
                                   "messages": r.messages.map { ["role": $0.role.rawValue, "content": $0.text] }]
        if r.wantsJSON { body["format"] = "json" }
        return body
    }

    public func complete(_ r: LLMRequest) async throws -> String { try await stream(r) { _ in } }

    public func stream(_ r: LLMRequest, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        let request = try HTTP.request(base + "/api/chat", method: "POST", body: try JSONSerialization.data(withJSONObject: body(r, stream: true)),
                                       contentType: "application/json", headers: [:], timeout: 300)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if !(200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) {
            var body = Data()
            for try await byte in bytes.prefix(600) { body.append(byte) }
            try HTTP.check(response, body: body)
        }
        var text = ""
        for try await line in bytes.lines {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let error = event["error"] as? String { throw LLMError("Ollama: \(error)") }
            if let words = (event["message"] as? [String: Any])?["content"] as? String, !words.isEmpty {
                text += words
                partial(text)
            }
            if event["done"] as? Bool == true { break }
        }
        guard !text.isEmpty else { throw LLMError("The model returned an empty reply.") }
        return text
    }
}

public struct OpenAIChatClient: LLMClient {
    public let baseURL: String
    let key: String?
    let jsonMode: Bool

    public init(baseURL: String, key: String?, jsonMode: Bool) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.key = key
        self.jsonMode = jsonMode
    }

    var headers: [String: String] { key.map { ["Authorization": "Bearer \($0)"] } ?? [:] }

    func body(_ r: LLMRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": r.model,
            "messages": r.messages.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        if r.wantsJSON, jsonMode { body["response_format"] = ["type": "json_object"] }
        return body
    }

    public func complete(_ r: LLMRequest) async throws -> String {
        let data = try await HTTP.post(baseURL + "/chat/completions", json: body(r), headers: headers, timeout: 90)
        struct Message: Decodable { let content: String? }
        struct Choice: Decodable { let message: Message }
        struct Completion: Decodable { let choices: [Choice] }
        guard let text = try JSONDecoder().decode(Completion.self, from: data).choices.first?.message.content, !text.isEmpty else {
            throw LLMError("The model returned an empty reply.")
        }
        return text
    }

    /// The same answer as server-sent events, `partial` told the text so far: OpenAI's, OpenRouter's, Ollama's and LM
    /// Studio's /chat/completions all speak them. A server that ignores «stream» and answers with one body still works.
    public func stream(_ r: LLMRequest, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        var b = body(r)
        b["stream"] = true
        let request = try HTTP.request(baseURL + "/chat/completions", method: "POST", body: try JSONSerialization.data(withJSONObject: b),
                                       contentType: "application/json", headers: headers.merging(["Accept": "text/event-stream"]) { mine, _ in mine }, timeout: 90)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if !(200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) {
            var body = Data()
            for try await byte in bytes.prefix(600) { body.append(byte) }
            try HTTP.check(response, body: body)
        }
        var text = "", plain = ""
        for try await line in bytes.lines {
            // «: OPENROUTER PROCESSING» keep-alives are comments; a line that isn't an event is a plain answer's.
            guard line.hasPrefix("data:") else { if !line.hasPrefix(":") { plain += line + "\n" }; continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
            if let error = event["error"] { throw LLMError("The model service: \(error)") }
            let words = ((event["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String ?? ""
            if !words.isEmpty {
                text += words
                partial(text)
            }
        }
        if text.isEmpty, let whole = (try? JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any])?["choices"] as? [[String: Any]] {
            text = (whole.first?["message"] as? [String: Any])?["content"] as? String ?? ""
            if !text.isEmpty { partial(text) }
        }
        guard !text.isEmpty else { throw LLMError("The model returned an empty reply.") }
        return text
    }

    public func models() async throws -> [String] {
        struct Model: Decodable { let id: String }
        struct List: Decodable { let data: [Model] }
        let data = try await HTTP.get(baseURL + "/models", headers: headers)
        return try JSONDecoder().decode(List.self, from: data).data.map(\.id).sorted()
    }
}
