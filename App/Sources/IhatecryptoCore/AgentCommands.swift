import Foundation

/// «remember: …», «forget: …», «what do you remember»: what the user wants the chat to keep in mind from now on. Kept
/// only in their own words (the app checks the words are in their own message, so a page or a token's name can't plant
/// one) and given to the model with every message as preferences — never as a reason to skip a check or a Confirm.
public enum MemoryCommand: Equatable, Sendable {
    case remember(String)
    /// The notes holding these words; «all» forgets every one.
    case forget(String)
    case list

    public static func parse(_ text: String) -> MemoryCommand? {
        if let m = text.wholeMatch(of: /(?is)\s*remember:\s*(.+?)\s*/) { return .remember(String(m.1)) }
        if let m = text.wholeMatch(of: /(?is)\s*forget:\s*(.+?)\s*/) { return .forget(String(m.1)) }
        if text.wholeMatch(of: /(?i)\s*what\s+do\s+you\s+remember\s*\??\s*/) != nil { return .list }
        return nil
    }

    /// Whether `note` is the user's own words: in their message, ignoring case, spacing and the quotes around it.
    public static func inTheirWords(_ note: String, _ message: String) -> Bool {
        func plain(_ s: String) -> String {
            s.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "«»\"'“”.!,: "))
        }
        let n = plain(note)
        return n.count >= 3 && plain(message).contains(n)
    }
}

/// «check: Aave health factor on Base; warn under 1.6»: a step for the schedule. When it comes due the model reads what it
/// needs itself and speaks only when the condition is met — a reply, cards and a notification; a move it suggests waits
/// for the user's Confirm, even with an automation wallet.
public struct AgentCheck: Equatable, Sendable {
    public let what: String
    public static func parse(_ text: String) -> AgentCheck? {
        text.wholeMatch(of: /(?is)\s*check:\s*(.+?)\s*/).map { AgentCheck(what: String($0.1)) }
    }
}
