import Foundation
import LLMCore

/// Free-form plan edits ("move the take closer") through whichever model the user connected.
public enum ChatModel {
    static let system = """
    You change a trade plan's parameters at the user's request. Return only a JSON object like
    {"intent": {"asset": "ETH", "side": "long", "riskUSD": 10, "stopPct": 3, "takePct": 6, "leverage": 2, "amountUSDC": null, "takeR": null, "autoRules": null, "entryPx": null, "pullbackPct": null}, "reply": "Take-profit: 6% → 4%."}
    asset: a Hyperliquid ticker, either a crypto ("ETH") or a market on the HIP-3 exchange xyz ("xyz:CL" is WTI oil, "xyz:BRENTOIL", "xyz:GOLD", "xyz:TSLA"); side: long or short; riskUSD: the maximum loss in dollars; stopPct and takePct: percent from the entry price;
    leverage: whole-number leverage; amountUSDC: how much USDC to send from Solana, or null; takeR: take-profit as a multiple of the stop ("take 2R", "1:3"), then takePct is null;
    autoRules: true if the user asks for it by the book, by the rules or the best way (in Russian e.g. "как учат", "по правилам"): then do not invent numbers, leave missing stopPct, takePct and riskUSD null; code computes them from volatility, 2R and 1% of capital.
    entryPx: limit entry price, or null for a market entry; pullbackPct: a limit entry on a pullback of this many % from the current price ("wait for a 2% pullback"), then entryPx is null.
    Return every intent field; change only what is asked.
    The user may write in any language, Russian included. Understand the request in whatever language it is written and still return the same JSON.
    reply: one short sentence in English about what changed.
    Handle relative requests ("take closer", "wider stop", "less risk") yourself: change the value by about a third and name the new value in reply.
    If the request is not about these parameters — deposits, vaults, lending, transfers, balances — return "intent": null and say in reply that it isn't a trade-plan change; never put a deposit amount into amountUSDC. If it is unclear what to change, return "intent": null and ask one clarifying question in English in reply.
    Do not invent addresses; do not discuss signing or executing the trade.
    """

    /// Sends only the plan parameters and the user's words. Never addresses, balances or keys.
    /// `history`: the last lines of the chat, so a follow-up like «1» or «yes» reads in context.
    public static func edit(
        _ intent: TradeIntent, message: String, client: any LLMClient, model: String, history: [String] = []
    ) async throws -> (TradeIntent?, String) {
        let current = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
        let recent = history.isEmpty ? "" : "Recent chat (oldest first):\n" + history.joined(separator: "\n") + "\n"
        let text = try await client.complete(LLMRequest(model: model, messages: [
            LLMMessage(.system, system),
            LLMMessage(.user, recent + "Current parameters (json): \(current)\nMessage: \(message)"),
        ], wantsJSON: true))
        guard let json = JSONText.object(in: text) else {
            throw LLMError("The model did not reply with JSON: \(text.prefix(120))")
        }
        struct Answer: Decodable { let intent: TradeIntent?; let reply: String? }
        let answer = try JSONDecoder().decode(Answer.self, from: json)
        return (answer.intent, answer.reply ?? "")
    }
}
