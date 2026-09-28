import Foundation
import LLMCatalog
import LalaCore
import LLMCore

// Checks one provider from the terminal, without the app:
//   swift run LalaLLMCheck                      list providers and existing logins
//   swift run LalaLLMCheck chatgpt "hello"      reuse an existing login (Codex CLI, Claude Code)
//   LALA_LLM_KEY=sk-… swift run LalaLLMCheck deepseek "hello"
//   LALA_LLM_MODEL=… overrides the default model.
//   swift run LalaLLMCheck chatgpt --route "купи AI на $2" …   how the chat router reads each message

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

if prompt == "--route" {
    var context = ChatRouter.Context()
    context.favorites = ["AI (Artificial Inu) = 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18 on Robinhood Chain"]
    context.addressBook = ["Bybit"]
    context.balances = ["Solana 22.38 USDC, 0.0297 SOL", "Hyperliquid $7.47"]
    context.plan = env["LALA_ROUTE_PLAN"]
    // `LALA_ROUTE_RECENT="user: …|LALA: …"`: the chat before the message, to check follow-ups like «да».
    context.recent = env["LALA_ROUTE_RECENT"].map { $0.components(separatedBy: "|") } ?? []
    // `LALA_SAFE_SEARCH=0`: as with Safe search off in Settings.
    context.safeSearch = env["LALA_SAFE_SEARCH"] != "0"
    let client = try provider.client(credential, save: { _ in })
    let markets: Set<String> = ["BTC", "ETH", "SOL", "xyz:CL", "xyz:TSLA"]
    // Real token lookups; the app's own data (portfolio, markets, rates) is what the context above says.
    let balances = context.balances.joined(separator: "; ")
    let lookup: @Sendable (ChatRouter.Lookup) async -> String = { l in
        l.tool == "token" ? await TokenResearch.report(l.arg) : l.tool == "portfolio" ? "Balances: \(balances). No open positions." : "Not available in this check."
    }
    var message = ""
    func verdict(_ c: String, found: [String] = []) -> String {
        var line = ChatRouter.parses(c, markets: markets) ? "✓ parses" : "✗ NO PARSER"
        if let task = ScheduledTask.parse(c) { line += "  [\(task.when)]" }
        if !ChatRouter.addressesAllowed(c, userText: message, known: ["0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18"] + found) { line += "  ✗ FOREIGN ADDRESS" }
        return line
    }
    for m in args.dropFirst(2) {
        message = m
        context.replyLanguage = m.contains(/[а-яА-ЯёЁ]/) ? "Russian" : "English"
        let started = Date()
        do {
            let reading = try await ChatRouter.route(message, context: context, client: client, model: model, lookup: lookup)
            var line = "\(reading.route)"
            if case .command(let c) = reading.route { line += "  " + verdict(c) }
            for l in reading.lookups { line += "\n   lookup: \(l.tool) \(l.arg)" }
            if let show = reading.show { line += "\n   show: \(show)  " + verdict(show, found: reading.found) }
            for o in reading.options { line += "\n   \(o.recommended ? "★" : "·") \(o.title) — \(o.comment)\n       \(o.command)  " + verdict(o.command, found: reading.found) }
            print("«\(message)» \(String(format: "%.1f", Date().timeIntervalSince(started))) s\n   → \(line)")
        } catch {
            print("«\(message)» → error: \(error.localizedDescription)")
        }
    }
    exit(0)
}

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
