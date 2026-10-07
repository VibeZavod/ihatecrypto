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
        // An ENS or SNS name is saved as the address it resolves to (AddressBook's save): the name is what the message holds.
        if let address = address(in: text) ?? domain(in: text), q.contains(/\b(?:save|add|remember|store|keep)\b|сохран|запомн|добав|запиши/) {
            // «… as Bybit on Arbitrum», «… как Bybit в сети base»
            let named = text.firstMatch(of: /(?i)(?:\bas\b|\bcalled\b|\bnamed\b|\bкак\b|под\s+именем)\s+[«"“]?(.+?)[»"”]?(?=\s+(?:on|in|в|на)\s+(?:the\s+)?(?:сети\s+)?(?:solana|солан\w*|base|бейс\w*|arbitrum|арбитрум\w*|ethereum|эфир\w*|hyperliquid|хайперликвид\w*|near|неар\w*|polygon|полигон\w*|robinhood|робин[гх]уд\w*|tempo|темпо\w*|hyperevm|optimism|bnb|bsc|бнб|bitcoin|биткоин\w*|zcash|tron|трон\w*|xrp|ripple|dogecoin|doge|sui)\b|[.,!]?\s*$)/)
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
        // Sui's 0x and 64 hex before an EVM address's 40; a Bitcoin bc1…; an XRP X-address (tag inside).
        if let m = text.firstMatch(of: /\b0x[0-9a-fA-F]{64}\b/) { return String(m.0) }
        if let m = text.firstMatch(of: evm) { return String(m.0) }
        if let m = text.firstMatch(of: /(?i)\bbc1[02-9ac-hj-np-z]{8,87}\b/) { return String(m.0) }
        if let m = text.firstMatch(of: /\bX[1-9A-HJ-NP-Za-km-z]{46}\b/) { return String(m.0) }
        // Bitcoin's, Dogecoin's, TRON's, Zcash's and XRP's base58 ones are shorter than Solana's.
        if let s = text.matches(of: /\b[1-9A-HJ-NP-Za-km-z]{25,35}\b/).map({ String($0.0) }).first(where: { s in
            s.contains(where: \.isNumber) && s.contains(where: \.isUppercase) && s.contains(where: \.isLowercase) && s.first.map("13DT9Atr".contains) == true
        }) { return s }
        // NEAR: a 64-hex implicit account, or a named one ending in .near.
        if let m = text.firstMatch(of: /\b[0-9a-f]{64}\b/) { return String(m.0) }
        if let m = text.firstMatch(of: /\b[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.near\b/) { return String(m.0) }
        return text.matches(of: solana).map { String($0.0) }.first { s in
            s.contains(where: \.isNumber) && s.contains(where: \.isUppercase) && s.contains(where: \.isLowercase)
        }
    }

    /// An ENS (vitalik.eth) or SNS (toly.sol) name standing alone in the text, lowercased: the whole word must be plain
    /// ASCII letters, digits, hyphens and dots — a look-alike letter («vіtalik.eth» with a Cyrillic і) makes it no name.
    public static func domain(in text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace || "«»\"“”,;!?()".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".:")).lowercased() }
        return words.first { w in
            w.wholeMatch(of: /[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\.eth/) != nil
                || w.wholeMatch(of: /[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.sol/) != nil
        }
    }

    public static func network(_ q: String) -> String? {
        // A NEAR account can only be on NEAR; «on near» names it too.
        if q.contains(/\b[0-9a-f]{64}\b|\.near\b|\b(?:on|in|в|на)\s+(?:the\s+)?(?:сети\s+)?(?:near|неар\w*)\b/) { return "near" }
        // The networks only NEAR Intents reaches, named or by the address's shape; never for a 0x one of 40 hex.
        if !q.contains(/\b0x[0-9a-f]{40}\b/) {
            if q.contains(/\bbc1[02-9ac-hj-np-z]{8,}|\bbitcoin\b|биткоин|\bbtc\b/) { return "bitcoin" }
            if q.contains(/\bzcash\b|\bzec\b|зкеш|зкэш/) { return "zcash" }
            if q.contains(/\btron\b|трон|\btrx\b|trc-?20/) { return "tron" }
            if q.contains(/\bxrp\b|ripple|рипл/) { return "xrp" }
            if q.contains(/\bdoge\b|dogecoin|додж/) { return "dogecoin" }
            if q.contains(/\bsui\b|\b0x[0-9a-f]{64}\b/) { return "sui" }
        }
        if q.contains(/\bbase\b|бейс/) { return "base" }
        if q.contains(/arbitrum|арбитрум/) { return "arbitrum" }
        if q.contains(/hyperevm|hyper\s+evm|хайперевм|гиперевм/) { return "hyperevm" }
        if q.contains(/optimism|оптимизм/) { return "optimism" }
        if q.contains(/\bbnb\b|\bbsc\b|бнб|бсц|binance\s+smart\s+chain/) { return "bnb" }
        if q.contains(/hyperliquid|хайперликвид/) { return "hyperliquid" }
        if q.contains(/polygon|полигон/) { return "polygon" }
        if q.contains(/robinhood|робин[гх]уд/) { return "robinhood" }
        if q.contains(/\btempo\b|темпо/) { return "tempo" }
        if q.contains(/ethereum|эфир|\beth\s+mainnet/) { return "ethereum" }
        if q.contains(/solana|солан/) { return "solana" }
        // A name with no network named: an ENS name is an Ethereum address, a .sol name a Solana one.
        if let name = domain(in: q) { return name.hasSuffix(".sol") ? "solana" : "ethereum" }
        return nil
    }
}
