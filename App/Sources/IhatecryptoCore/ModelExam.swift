import Foundation
import LLMCore

/// A short exam of how a model reads the chat: requests people send, each with what it must lead to, read through the
/// same parsers as in the app. A model that misreads them makes the chat feel dumb — people took that for the product —
/// so a model, a local one above all, is checked before it's trusted (Settings › AI model › Check).
public enum ModelExam {
    public struct Question: Sendable {
        public let message: String
        /// What a right reading writes, for the test that the judge takes it.
        public let ideal: ChatRouter.Route
        let passes: @Sendable (ChatRouter.Route, Set<String>) -> Bool
    }

    public struct Result: Codable, Equatable, Sendable {
        public let passed: Int
        public let total: Int
        /// Seconds a reply took on average.
        public let seconds: Double
        /// The messages it misread or didn't answer.
        public let misses: [String]
        /// Good enough for the chat: 8 of 10 and more.
        public var good: Bool { passed * 10 >= total * 8 }
        public var short: String { "\(passed)/\(total) · \(String(format: "%.1f", seconds)) s" }
    }

    static let markets: Set<String> = ["BTC", "ETH", "SOL", "xyz:CL"]

    static func written(_ r: ChatRouter.Route) -> String? { if case .command(let c) = r { c } else { nil } }
    static func wallet(_ r: ChatRouter.Route) -> WalletCommand? { written(r).flatMap { WalletCommand.parse(ChatRouter.planChange($0, markets: markets) ?? $0) } }
    /// Not a move: an answer, a question back, or a read-only command.
    static func talks(_ r: ChatRouter.Route) -> Bool {
        switch r {
        case .question, .chat, .clarify: true
        case .command(let c): WalletCommand.parse(c).map { if case .yields = $0 { true } else { false } } ?? (IntentParser.apply(c, to: TradeIntent(), markets: markets) == nil)
        default: false
        }
    }

    public static let questions: [Question] = {
        let sol = SpotAsset.all[0]
        func move(_ message: String, _ ideal: String, _ want: WalletCommand) -> Question {
            Question(message: message, ideal: .command(ideal)) { r, _ in wallet(r) == want }
        }
        return [
            move("купи SOL на 5 долларов", "buy SOL for 5 USDC", .buy(sol, usdc: 5)),
            move("send 5 USDC to Mom", "send 5 USDC to Mom", .sendTo(name: "Mom", amount: 5)),
            move("положи 10 usdc в jupiter", "lend 10 USDC", .lendDeposit("USDC", 10)),
            Question(message: "покажи график эфира за неделю", ideal: .command("chart ETH week")) { r, m in
                written(r).flatMap { ChartCommand.parse($0, markets: m) } == .chart(coin: "ETH", range: .week)
            },
            // A trade may go to the plan editor instead of a command: either reads it.
            Question(message: "лонг биткоин, риск 5 долларов", ideal: .command("long BTC risk $5")) { r, m in
                if case .plan = r { return true }
                return written(r).flatMap { IntentParser.apply($0, to: TradeIntent(), markets: m) }.map { $0.asset == "BTC" && $0.side == .long } == true
            },
            Question(message: "сколько у меня денег?", ideal: .question) { r, _ in talks(r) },
            move("выведи всё из jupiter lend", "withdraw all USDC from the vault", .lendWithdraw("USDC", nil)),
            move("Jupiter DCA 100 USDC в SOL на 2 недели", "Jupiter DCA 100 USDC into SOL over 2 weeks", .jupiterDCA(sol, usdc: 100, orders: 2, every: 604_800)),
            move("закинь 3 доллара газа на base", "add gas on base for 3 USDC", .gas("base", usd: 3)),
            Question(message: "какая завтра погода в Москве?", ideal: .chat("I can't see the weather; I handle your crypto.")) { r, _ in talks(r) },
        ]
    }()

    /// The context every question is asked in: a small wallet with Mom and Bybit saved.
    static var context: ChatRouter.Context {
        var c = ChatRouter.Context()
        c.addressBook = ["Bybit", "Mom"]
        c.balances = ["Solana 120 USDC, 0.05 SOL", "Hyperliquid $10", "Base 2 USDC"]
        c.capital = "$132"
        c.replyLanguage = "Russian"
        return c
    }

    /// Asks every question; `progress` gets how many are done. A question the model can't answer counts as a miss.
    public static func run(client: any LLMClient, model: String, progress: @escaping @Sendable (Int) async -> Void = { _ in }) async -> Result {
        var passed = 0, misses: [String] = [], total = 0.0
        for (i, q) in questions.enumerated() {
            let started = Date()
            let route = try? await ChatRouter.route(q.message, context: context, client: client, model: model, markets: markets).route
            total += Date().timeIntervalSince(started)
            if let route, q.passes(route, markets) { passed += 1 } else { misses.append(q.message) }
            await progress(i + 1)
        }
        return Result(passed: passed, total: questions.count, seconds: total / Double(questions.count), misses: misses)
    }
}
