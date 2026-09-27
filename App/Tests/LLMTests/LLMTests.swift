import Foundation
@testable import LLMAPIKey
@testable import LLMCatalog
@testable import LLMChatGPT
@testable import LLMClaudeCode
import LLMCore
import Testing

// MARK: Core

@Test func pkceMatchesRFC7636Vector() {
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(PKCE.make().verifier.count == 43)
}

@Test func jsonTextFindsObjectInFencesAndProse() throws {
    for reply in ["{\"a\":1}", "```json\n{\"a\": 1}\n```", "Вот ответ: {\"a\": 1}. Готово"] {
        let data = try #require(JSONText.object(in: reply))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(object["a"] == 1)
    }
    #expect(JSONText.object(in: "нет json") == nil)
}

@Test func loopbackServerReturnsCallbackQuery() async throws {
    let server = try await LoopbackServer.start(path: "/callback")
    #expect(server.port > 0)
    async let query = server.waitForCallback(timeout: 10)
    let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(server.port)/callback?code=abc&state=xyz")!)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("Signed in"))
    #expect(try await query == ["code": "abc", "state": "xyz"])
}

// MARK: ChatGPT subscription

private func jwt(_ claims: [String: Any]) -> String {
    let payload = PKCE.base64url(try! JSONSerialization.data(withJSONObject: claims))
    return "eyJhbGciOiJub25lIn0.\(payload).sig"
}

@Test func chatGPTTokensReadAccountAndExpiry() throws {
    let id = jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acc-1"]])
    let access = jwt(["exp": 2_000_000_000])
    let data = try JSONSerialization.data(withJSONObject: ["access_token": access, "refresh_token": "r1", "id_token": id])
    let tokens = try ChatGPTSubscription.tokens(from: data, previous: nil)
    #expect(tokens.accountID == "acc-1")
    #expect(tokens.refresh == "r1")
    #expect(tokens.expires == Date(timeIntervalSince1970: 2_000_000_000))

    // A refresh response without a new refresh token or id_token keeps the old ones.
    let refreshed = try ChatGPTSubscription.tokens(
        from: try JSONSerialization.data(withJSONObject: ["access_token": access]), previous: tokens)
    #expect(refreshed.refresh == "r1")
    #expect(refreshed.accountID == "acc-1")
}

@Test func codexBodyPutsSystemIntoInstructions() throws {
    let body = ChatGPTClient.body(LLMRequest(model: "gpt-6-sol", messages: [
        LLMMessage(.system, "Отвечай JSON."), LLMMessage(.user, "привет"), LLMMessage(.assistant, "{}"),
    ]))
    #expect(body["instructions"] as? String == "Отвечай JSON.")
    #expect(body["stream"] as? Bool == true)
    #expect(body["store"] as? Bool == false)
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.count == 2)
    let assistantPart = try #require((input[1]["content"] as? [[String: String]])?.first)
    #expect(assistantPart["type"] == "output_text")
}

@Test func codexStreamCollectsDeltasAndStopsOnCompleted() throws {
    var stream = CodexStream()
    #expect(try !stream.feed("event: response.output_text.delta"))
    #expect(try !stream.feed(#"data: {"type":"response.output_text.delta","delta":"{\"ok\""}"#))
    #expect(try !stream.feed(#"data: {"type":"response.output_text.delta","delta":":true}"}"#))
    #expect(try stream.feed(#"data: {"type":"response.completed","response":{}}"#))
    #expect(stream.text == #"{"ok":true}"#)

    var failing = CodexStream()
    #expect(throws: LLMError.self) {
        try failing.feed(#"data: {"type":"response.failed","response":{"error":{"message":"usage limit"}}}"#)
    }
}

// MARK: Claude Code, API keys, catalog

@Test func claudeCodeRunsWithoutToolsAndKeepsPromptOffTheCommandLine() {
    let args = ClaudeCodeClient.arguments(LLMRequest(model: "claude-haiku-4-5", messages: [
        LLMMessage(.system, "Отвечай JSON."), LLMMessage(.user, "секретный текст"),
    ]))
    #expect(args.contains("--restricted"))
    #expect(args[args.firstIndex(of: "--tools")! + 1] == "")
    // `--tools` takes several values; the next argument must be a flag so nothing is swallowed.
    #expect(args[args.firstIndex(of: "--tools")! + 2].hasPrefix("--"))
    #expect(!args.contains("секретный текст"))
    #expect(args[args.firstIndex(of: "--system-prompt")! + 1] == "Отвечай JSON.")
    #expect(ClaudeCodeClient.arguments(LLMRequest(model: "m", messages: [LLMMessage(.user, "x")])).contains("--system-prompt"))
}

@Test func jsonModeOnlyWhereTheAPISupportsIt() {
    let request = LLMRequest(model: "m", messages: [LLMMessage(.user, "x")], wantsJSON: true)
    #expect(OpenAIChatClient(baseURL: "https://api.deepseek.com/", key: "k", jsonMode: true).body(request)["response_format"] != nil)
    #expect(OpenAIChatClient(baseURL: "https://api.anthropic.com/v1", key: "k", jsonMode: false).body(request)["response_format"] == nil)
    #expect(OpenAIChatClient(baseURL: "https://api.deepseek.com/", key: nil, jsonMode: true).baseURL == "https://api.deepseek.com")
}

@Test func apiKeyProviderRefusesToRunWithoutKey() {
    let deepseek = OpenAICompatible.presets.first { $0.info.id == "deepseek" }!
    #expect(throws: LLMError.self) { try deepseek.client(nil, save: { _ in }) }
    let ollama = OpenAICompatible.presets.first { $0.info.id == "ollama" }!
    #expect((try? ollama.client(nil, save: { _ in })) != nil)
}

@Test func catalogIDsAreUniqueAndUsableEntriesHaveAModelOrAreLocal() {
    let ids = LLMCatalog.all.map(\.info.id)
    #expect(Set(ids).count == ids.count)
    for p in LLMCatalog.all where p.info.unavailable == nil && p.info.kind != .local {
        #expect(!p.info.defaultModel.isEmpty, "\(p.info.id)")
    }
    #expect(LLMCatalog.provider(id: "grok-subscription")?.info.unavailable != nil)
    #expect(LLMCatalog.all.filter { $0.info.kind == .subscription }.count == 4)
}

@Test func modelIdsReadAsNames() {
    let names = [
        "gpt-6-sol": "GPT 6 SOL", "claude-haiku-4-5": "Claude Haiku 4.5", "deepseek-flash": "DeepSeek Flash",
        "deepseek/deepseek-v4.1-flash": "DeepSeek V4.1 Flash", "gemini-3.8-flash": "Gemini 3.8 Flash",
        "grok-4.3": "Grok 4.3", "qwen3.5:9b": "Qwen3.5 9B", "gpt-6-pro": "GPT 6 Pro",
    ]
    for (id, name) in names { #expect(LLMCatalog.displayName(model: id) == name) }
}
