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
                                 note: "Key from platform.deepseek.com.", takesKey: true),
              baseURL: "https://api.deepseek.com"),
        .init(info: ProviderInfo(id: "openai", name: "OpenAI API", kind: .apiKey, defaultModel: "gpt-6.1-sol",
                                 note: "Key from platform.openai.com, billed separately from a ChatGPT subscription.", takesKey: true),
              baseURL: "https://api.openai.com/v1"),
        .init(info: ProviderInfo(id: "anthropic", name: "Anthropic API", kind: .apiKey, defaultModel: "claude-haiku-4-5",
                                 note: "Key from platform.claude.com, billed separately from a Claude subscription.", takesKey: true),
              baseURL: "https://api.anthropic.com/v1", jsonMode: false),
        .init(info: ProviderInfo(id: "xai", name: "xAI Grok API", kind: .apiKey, defaultModel: "grok-4.3",
                                 note: "Key from console.x.ai, paid with credits.", takesKey: true),
              baseURL: "https://api.x.ai/v1"),
        .init(info: ProviderInfo(id: "gemini", name: "Google Gemini API", kind: .apiKey, defaultModel: "gemini-3.8-flash",
                                 note: "Key from Google AI Studio.", takesKey: true),
              baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"),
        .init(info: ProviderInfo(id: "ollama", name: "Ollama on this Mac", kind: .local, defaultModel: "qwen3.5:9b",
                                 note: "No network or key. Download the model first: ollama pull qwen3.5:9b."),
              baseURL: "http://localhost:11434/v1"),
        .init(info: ProviderInfo(id: "lmstudio", name: "LM Studio on this Mac", kind: .local, defaultModel: "",
                                 note: "No network or key. Start the server in LM Studio and pick a model from the list."),
              baseURL: "http://localhost:1234/v1", jsonMode: false),
    ]

    public func client(_ credential: Credential?, save: @escaping SaveCredential) throws -> any LLMClient {
        try chatClient(credential)
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

    public func models() async throws -> [String] {
        struct Model: Decodable { let id: String }
        struct List: Decodable { let data: [Model] }
        let data = try await HTTP.get(baseURL + "/models", headers: headers)
        return try JSONDecoder().decode(List.self, from: data).data.map(\.id).sorted()
    }
}
