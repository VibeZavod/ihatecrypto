import LLMAPIKey
import LLMChatGPT
import LLMClaudeCode
import LLMCore
import LLMOpenRouter

/// Every way the app can reach a model. Adding a provider: a module under Sources/LLM plus one line here.
public enum LLMCatalog {
    public static let all: [any LLMProvider] = [
        ChatGPTSubscription(),
        ClaudeCodeSubscription(),
        Unavailable(info: ProviderInfo(
            id: "grok-subscription", name: "Grok (SuperGrok / X Premium+)", kind: .subscription, defaultModel: "",
            note: "", unavailable: "xAI opens subscription sign-in only to partners (Hermes, OpenClaw). For now, connect Grok with an xAI API key."
        )),
        Unavailable(info: ProviderInfo(
            id: "gemini-subscription", name: "Gemini (Google AI Pro / Ultra)", kind: .subscription, defaultModel: "",
            note: "", unavailable: "A Google AI subscription doesn't cover the API. Connect Gemini with a key from Google AI Studio."
        )),
        OpenRouter(),
    ] + OpenAICompatible.presets

    public static func provider(id: String) -> (any LLMProvider)? {
        all.first { $0.info.id == id }
    }
}

/// Listed so the user sees why an option is missing.
struct Unavailable: LLMProvider {
    let info: ProviderInfo

    func client(_ credential: Credential?, save: @escaping SaveCredential) throws -> any LLMClient {
        throw LLMError(info.unavailable ?? "\(info.name) is unavailable.")
    }
}
