import Foundation
import LLMCatalog
import LLMCore

// Checks one provider from the terminal, without the app:
//   swift run LalaLLMCheck                      list providers and existing logins
//   swift run LalaLLMCheck chatgpt "hello"      reuse an existing login (Codex CLI, Claude Code)
//   LALA_LLM_KEY=sk-… swift run LalaLLMCheck deepseek "hello"
//   LALA_LLM_MODEL=… overrides the default model.

let args = Array(CommandLine.arguments.dropFirst())
let env = ProcessInfo.processInfo.environment

guard let id = args.first else {
    for p in LLMCatalog.all {
        let status = p.info.unavailable != nil ? "unavailable" : p.existingLogin() != nil ? "signed in on this Mac" : ""
        print("\(p.info.id.padding(toLength: 20, withPad: " ", startingAt: 0)) \(p.info.name)  \(status)")
    }
    exit(0)
}
guard let provider = LLMCatalog.provider(id: id) else {
    fputs("No provider \(id)\n", stderr)
    exit(2)
}

let credential = env["LALA_LLM_KEY"].map(Credential.apiKey) ?? provider.existingLogin()
let model = env["LALA_LLM_MODEL"] ?? provider.info.defaultModel
let prompt = args.dropFirst().first ?? "Answer in one word: working"

do {
    let started = Date()
    let client = try provider.client(credential, save: { _ in })
    let reply = try await client.complete(LLMRequest(model: model, messages: [LLMMessage(.user, prompt)]))
    print("\(provider.info.name) · \(model) · \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
    print(reply)
} catch {
    fputs("\(provider.info.name) · \(model): \(error.localizedDescription)\n", stderr)
    exit(1)
}
