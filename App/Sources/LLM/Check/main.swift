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
    let client = try provider.client(credential, save: { _ in })
    for message in args.dropFirst(2) {
        let started = Date()
        do {
            let route = try await ChatRouter.route(message, context: context, client: client, model: model)
            var line = "\(route)"
            if case .command(let c) = route {
                let parsed = WalletCommand.parse(c) != nil || TokenCommand.parse(c) != nil || PositionCommand.parse(c) != nil
                    || ChartCommand.parse(c) != nil || AlertCommand.parse(c) != nil || AddressBookCommand.parse(c) != nil
                    || IntentParser.apply(c, to: TradeIntent(), markets: ["BTC", "ETH", "SOL", "xyz:CL", "xyz:TSLA"]) != nil
                let safe = ChatRouter.addressesAllowed(c, userText: message, known: ["0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18"])
                line += parsed ? "  ✓ parses" : "  ✗ NO PARSER"
                if !safe { line += "  ✗ FOREIGN ADDRESS" }
            }
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
