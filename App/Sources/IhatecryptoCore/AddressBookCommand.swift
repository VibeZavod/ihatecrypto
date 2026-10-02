import Foundation

/// What the chat may do with the address book. The address is always taken as written in the user's own message —
/// never from a model, a site or a pasted instruction — and saving waits for a confirmation.
public enum AddressBookCommand: Equatable, Sendable {
    /// Save the address written in the message under a name. `network` nil: Solana for a base58 address; a 0x address asks.
    case save(address: String, name: String, network: String?)
    case favorite(name: String, on: Bool)

    nonisolated(unsafe) static let evm = /0x[0-9a-fA-F]{40}/
    nonisolated(unsafe) static let solana = /[1-9A-HJ-NP-Za-km-z]{32,44}/

    public static func parse(_ text: String) -> AddressBookCommand? {
        let q = text.lowercased()
        if let address = address(in: text), q.contains(/\b(?:save|add|remember|store|keep)\b|сохран|запомн|добав|запиши/) {
            // «… as Bybit on Arbitrum», «… как Bybit в сети base»
            let named = text.firstMatch(of: /(?i)(?:\bas\b|\bcalled\b|\bnamed\b|\bкак\b|под\s+именем)\s+[«"“]?(.+?)[»"”]?(?=\s+(?:on|in|в|на)\s+(?:the\s+)?(?:сети\s+)?(?:solana|солан\w*|base|бейс\w*|arbitrum|арбитрум\w*|ethereum|эфир\w*|hyperliquid|хайперликвид\w*|near|неар\w*)\b|[.,!]?\s*$)/)
            guard let name = named.map({ String($0.1).trimmingCharacters(in: .whitespaces) }), !name.isEmpty, !name.contains(address) else { return nil }
            return .save(address: address, name: name, network: network(q))
        }
        let on = text.firstMatch(of: /(?i)(?:add|put|star|mark|добавь|отметь)\s+(.+?)\s+(?:to|in|into|as|в)\s+(?:my\s+|the\s+)?(?:favou?rites?|избранн\w*)/)
        if let m = on { return .favorite(name: String(m.1).trimmingCharacters(in: .whitespaces), on: true) }
        let off = text.firstMatch(of: /(?i)(?:remove|unstar|take|убери|удали)\s+(.+?)\s+(?:from|out\s+of|из)\s+(?:my\s+|the\s+)?(?:favou?rites?|избранн\w*)/)
        if let m = off { return .favorite(name: String(m.1).trimmingCharacters(in: .whitespaces), on: false) }
        return nil
    }

    /// The address as the user wrote it: a 0x one, or a base58 one that mixes cases and digits like real Solana keys.
    public static func address(in text: String) -> String? {
        if let m = text.firstMatch(of: evm) { return String(m.0) }
        // NEAR: a 64-hex implicit account, or a named one ending in .near.
        if let m = text.firstMatch(of: /\b[0-9a-f]{64}\b/) { return String(m.0) }
        if let m = text.firstMatch(of: /\b[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.near\b/) { return String(m.0) }
        return text.matches(of: solana).map { String($0.0) }.first { s in
            s.contains(where: \.isNumber) && s.contains(where: \.isUppercase) && s.contains(where: \.isLowercase)
        }
    }

    public static func network(_ q: String) -> String? {
        // A NEAR account can only be on NEAR; «on near» names it too.
        if q.contains(/\b[0-9a-f]{64}\b|\.near\b|\b(?:on|in|в|на)\s+(?:the\s+)?(?:сети\s+)?(?:near|неар\w*)\b/) { return "near" }
        if q.contains(/\bbase\b|бейс/) { return "base" }
        if q.contains(/arbitrum|арбитрум/) { return "arbitrum" }
        if q.contains(/hyperliquid|хайперликвид/) { return "hyperliquid" }
        if q.contains(/ethereum|эфир|\beth\s+mainnet/) { return "ethereum" }
        if q.contains(/solana|солан/) { return "solana" }
        return nil
    }
}
