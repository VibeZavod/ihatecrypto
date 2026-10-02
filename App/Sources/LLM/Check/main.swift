import Foundation
import LLMCatalog
import IhatecryptoCore
import LLMCore

// Checks one provider from the terminal, without the app:
//   swift run LLMCheck                      list providers and existing logins
//   swift run LLMCheck chatgpt "hello"      reuse an existing login (Codex CLI, Claude Code)
//   IHATECRYPTO_LLM_KEY=sk-… swift run LLMCheck deepseek "hello"
//   IHATECRYPTO_LLM_MODEL=… overrides the default model.
//   swift run LLMCheck chatgpt --route "купи AI на $2" …   how the chat router reads each message

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

let credential = env["IHATECRYPTO_LLM_KEY"].map(Credential.apiKey) ?? provider.existingLogin()
let model = env["IHATECRYPTO_LLM_MODEL"] ?? provider.info.defaultModel
let prompt = args.dropFirst().first ?? "Answer in one word: working"

// `--verify "message" "command"`: the second reading alone, as the chat runs it on every command.
if prompt == "--verify", args.count >= 4 {
    var context = ChatRouter.Context()
    context.plan = env["IHATECRYPTO_ROUTE_PLAN"]
    context.recent = env["IHATECRYPTO_ROUTE_RECENT"].map { $0.components(separatedBy: "|") } ?? []
    context.replyLanguage = args[2].contains(/[а-яА-ЯёЁ]/) ? "Russian" : "English"
    let client = try provider.client(credential, save: { _ in })
    let why = try await ChatRouter.verify(args[2], command: args[3], context: context, client: client, model: model)
    print("«\(args[2])» as «\(args[3])» → " + (why.map { "✗ \($0)" } ?? "✓ matches"))
    exit(0)
}

if prompt == "--route" {
    var context = ChatRouter.Context()
    context.favorites = ["AI (Artificial Inu) = 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18 on Robinhood Chain"]
    context.addressBook = ["Bybit", "Mom"]
    context.balances = ["Solana 22.38 USDC, 0.0297 SOL", "Hyperliquid $7.47"]
    context.plan = env["IHATECRYPTO_ROUTE_PLAN"]
    context.capital = "$29.85"
    // `IHATECRYPTO_ROUTE_RECENT="user: …|ihatecrypto: …"`: the chat before the message, to check follow-ups like «да».
    context.recent = env["IHATECRYPTO_ROUTE_RECENT"].map { $0.components(separatedBy: "|") } ?? []
    // `IHATECRYPTO_SAFE_SEARCH=0`: as with Safe search off in Settings.
    context.safeSearch = env["IHATECRYPTO_SAFE_SEARCH"] != "0"
    // `IHATECRYPTO_ROUTE_CANVAS="waiting for Confirm: …|chart ETH (1 day)"` and `IHATECRYPTO_ROUTE_BALANCES="Ethereum 18,587 USDC idle|…"`:
    // the canvas and the money as the app gives them, for follow-ups about a waiting card.
    if let canvas = env["IHATECRYPTO_ROUTE_CANVAS"] { context.canvas = canvas.components(separatedBy: "|") }
    if let b = env["IHATECRYPTO_ROUTE_BALANCES"] { context.balances = b.components(separatedBy: "|") }
    let client = try provider.client(credential, save: { _ in })
    // `IHATECRYPTO_MARKETS="BTC,ETH,…,xyz:CL"`: Hyperliquid's real list, for the plans test.
    let markets: Set<String> = env["IHATECRYPTO_MARKETS"].map { Set($0.components(separatedBy: ",")) } ?? ["BTC", "ETH", "SOL", "xyz:CL", "xyz:TSLA"]
    // Real token lookups; the app's own data (portfolio, markets, rates) is what the context above says.
    let balances = context.balances.joined(separator: "; ")
    let lookup: @Sendable (ChatRouter.Lookup) async -> String = { l in
        l.tool == "token" ? await TokenResearch.report(l.arg) : l.tool == "portfolio" ? "Balances: \(balances). No open positions."
            : l.tool == "services" ? await MPP.search(l.arg) : l.tool == "service" ? await MPP.service(l.arg) : "Not available in this check."
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
        context.replyLanguage = ChatLanguage.auto.name(recentUserMessages: [m])
        let started = Date()
        do {
            let checkContext = context
            @Sendable func secondReading(_ command: String) async -> String? {
                do { return try await ChatRouter.verify(m, command: command, context: checkContext, client: client, model: model) } catch { return nil }
            }
            let reading = try await ChatRouter.route(message, context: context, client: client, model: model, markets: markets,
                                                     lookup: lookup, check: secondReading)
            // `IHATECRYPTO_ROUTE_JSON=1`: one JSON line per message with the plan it leads to, for the plans test.
            if env["IHATECRYPTO_ROUTE_JSON"] == "1" {
                let base = context.plan.flatMap { try? JSONDecoder().decode(TradeIntent.self, from: Data($0.utf8)) } ?? TradeIntent()
                var out: [String: Any] = ["message": m, "seconds": Date().timeIntervalSince(started)]
                var intent: TradeIntent?
                switch reading.route {
                case .command(let written):
                    let c = ChatRouter.planChange(written, markets: markets) ?? written
                    out["route"] = "command"; out["command"] = written; out["parses"] = ChatRouter.parses(written, markets: markets)
                    if ChatRouter.steps(c) == nil, ScheduledTask.parse(c) == nil, AlertCommand.parse(c, markets: markets) == nil,
                       WalletCommand.parse(c) == nil, TokenCommand.parse(c) == nil, ChartCommand.parse(c, markets: markets) == nil,
                       PnLCommand.parse(c, markets: markets) == nil, !c.lowercased().hasPrefix("close") {
                        intent = IntentParser.apply(c, to: base, markets: markets)?.started
                    }
                case .plan:
                    out["route"] = "plan"
                    intent = try? await ChatModel.edit(base, message: m, client: client, model: model, history: context.recent, replyLanguage: context.replyLanguage).0?.started
                case .chat(let r): out["route"] = "chat"; out["reply"] = r
                case .clarify(let r): out["route"] = "clarify"; out["reply"] = r
                case .confirm: out["route"] = "confirm"
                case .cancel: out["route"] = "cancel"
                case .question: out["route"] = "question"
                }
                if let intent, let data = try? JSONEncoder().encode(intent) { out["intent"] = try? JSONSerialization.jsonObject(with: data) }
                if let d = reading.doubt { out["doubt"] = d }
                if let c = reading.corrected { out["corrected"] = c }
                out["options"] = reading.options.map(\.command)
                print(String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), as: UTF8.self))
                continue
            }
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
