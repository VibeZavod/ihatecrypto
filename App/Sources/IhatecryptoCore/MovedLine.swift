import Foundation

/// A line of the history that says money moved: the sentence ihatecrypto writes when a move is done — «Sent 5 USDT to
/// Automation on Solana. https://…», «Swapped 3 USDC → USDT +2.997906.», «💸 Received +55.09 USDC on Solana (now 55.09).».
/// The History board's rows and the chat's account of where money went both read them, so they say the same.
// ponytail: read from the executor's own sentences by their first word; a new kind of move shows once its verb is listed here.
public struct MovedLine: Equatable, Sendable {
    public enum Kind: String, Sendable { case sent, received, swapped, moved, bought, sold, deposited, withdrew, closed }

    public let kind: Kind
    /// Its first sentence, without the link, the emoji or what follows a colon: what the row says.
    public let text: String
    /// The first amount it names, and its coin.
    public let amount: Decimal?
    public let symbol: String?
    /// Who a send went to: «Automation».
    public let to: String?
    public let link: URL?

    private static let verbs: [(String, Kind)] = [
        ("Sent ", .sent), ("💸 Received ", .received), ("💸 Пришло ", .received), ("Swapped ", .swapped), ("Moved ", .moved),
        ("Bought ", .bought), ("Sold ", .sold), ("Deposited ", .deposited), ("Supplied ", .deposited), ("Withdrew ", .withdrew),
        ("Closed ", .closed),
    ]

    public init?(_ line: String) {
        guard var kind = Self.verbs.first(where: { line.hasPrefix($0.0) })?.1 else { return nil }
        link = line.firstMatch(of: /https?:\/\/[^\s]+[^\s.,)]/).flatMap { URL(string: String($0.output)) }
        var s = line.replacing(/\s*https?:\/\/\S+/, with: "")
        if s.hasPrefix("💸 ") { s = String(s.dropFirst(2)) }
        // The first clause: a period ending a sentence (not one inside a number), a colon, a bracket or a semicolon.
        if let end = s.firstMatch(of: /\.(\s|$)|: |; | \(/) { s = String(s[..<end.range.lowerBound]) }
        // «Sent 5 USDT from Arbitrum to Optimism over USDT0»: the wallet's own money between its networks.
        if kind == .sent, s.contains(" from "), !s.contains("from the multisig") { kind = .moved }
        self.kind = kind
        text = s
        let first = s.firstMatch(of: /(\d[\d,]*(?:\.\d+)?)\s+([A-Z][A-Z0-9]{1,9})\b/)
        amount = first.flatMap { Decimal(string: String($0.output.1).replacing(",", with: "")) }
        symbol = first.map { String($0.output.2) }
        to = kind == .sent ? s.firstMatch(of: /\sto (.+?)(?: on [A-Z][\w ]*)?$/).map { String($0.output.1) } : nil
    }

    /// What left the wallet and what came in, by coin and by whom, then the swaps and moves: «25 USDT to Automation · 5
    /// sends». Oldest to newest or the other way, the same.
    public static func summary(_ lines: [MovedLine]) -> [String] {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        var out: [String] = []
        let sent = Dictionary(grouping: lines.filter { $0.kind == .sent && $0.amount != nil }) { "\($0.symbol ?? "")\u{1}\($0.to ?? "")" }
        for (_, group) in sent.sorted(by: { $0.value.count > $1.value.count }) {
            let total = group.compactMap(\.amount).reduce(0, +)
            out.append("−\(Fmt.num(total, maxFraction: 6)) \(group[0].symbol ?? "") sent\(group[0].to.map { " to \($0)" } ?? "") · \(plural(group.count, "send"))")
        }
        let came = Dictionary(grouping: lines.filter { $0.kind == .received && $0.amount != nil }, by: { $0.symbol ?? "" })
        for (symbol, group) in came.sorted(by: { $0.key < $1.key }) {
            out.append("+\(Fmt.num(group.compactMap(\.amount).reduce(0, +), maxFraction: 6)) \(symbol) came in")
        }
        let swaps = lines.filter { $0.kind == .swapped || $0.kind == .bought || $0.kind == .sold }.count
        if swaps > 0 { out.append("\(plural(swaps, "swap")), the money stays in the wallet") }
        let moves = lines.filter { $0.kind == .moved || $0.kind == .deposited || $0.kind == .withdrew }.count
        if moves > 0 { out.append("\(plural(moves, "move")) between its own places") }
        return out
    }
}
