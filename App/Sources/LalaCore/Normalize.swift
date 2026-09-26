import Foundation
import LLMCore

/// Any language → one English command in the forms the deterministic parsers read. The model only rewrites
/// wording: the result goes through the same parsers, checks and signature as a typed command, and the chat shows
/// what it was understood as.
public enum CommandNormalizer {
    static let forms = """
    long|short <ASSET> [risk $N] [stop N%] [take N% | take NR] [leverage Nx] [by the book] [on a N% pullback] [limit N] [at market] [take in parts] [trailing N%]
    move stop to breakeven | stop at <PRICE> | take at <PRICE> | trail N% | close | close half | close N% | cancel orders
    withdraw N USDC to Solana
    lend [N] <USDC|SOL> (Jupiter Lend, the vault; also “Jupiter”, “jupyter”, “Джупитер”) | withdraw [N] <USDC|SOL> from the vault
    deposit N <USDC|SOL> to kamino | withdraw <USDC|SOL> from kamino
    stake N SOL | unstake N JitoSOL
    where to keep <USDC|SOL>
    deposit N USDC to HLP | withdraw from HLP
    lend N USDC on Aave | withdraw USDC from Aave | move N USDC from Base to Solana
    send N USDC to <NAME from the address book>
    save <ADDRESS> as <NAME> [on solana|base|arbitrum|ethereum|hyperliquid] | add <NAME> to favorites | remove <NAME> from favorites
    spread <USDC|SOL> across the best rates [max N% per protocol]
    buy <SOL|BTC|ETH|JUP> for N USDC | sell [N] <SOL|BTC|ETH|JUP>
    buy <SOL|BTC|ETH|JUP> for N USDC every <day|week|N days|month> | stop recurring buys
    take profit options (when the user asks how the best investors or pros take profit)
    alert me when <ASSET> is above|below <PRICE> | cancel alerts
    """

    static let system = """
    You turn a crypto trading or wallet request, written in ANY language, into ONE short English command in exactly one of these forms:
    \(forms)
    Keep every number, ticker, price, percentage, name and address exactly as the user wrote it. Never invent amounts, assets or addresses; leave out any optional part the user did not mention. Oil is written as "oil", gold as "gold". If the message is a question or anything else that fits no form, answer NONE. Answer with the command only.
    """

    /// nil when the model says the message is not a command. `context`: LALA's last message, for short follow-ups.
    public static func normalize(_ text: String, client: any LLMClient, model: String, context: String? = nil) async throws -> String? {
        let message = context.map { "LALA just said: “\($0.prefix(300))”\nThe user answers: \(text)" } ?? text
        let reply = try await client.complete(LLMRequest(model: model, messages: [LLMMessage(.system, system), LLMMessage(.user, message)]))
        let line = reply.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
        let command = line.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'«» "))
        guard !command.isEmpty, command.uppercased() != "NONE", command.count <= 160 else { return nil }
        return command
    }
}
