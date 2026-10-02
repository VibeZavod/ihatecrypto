import Foundation

/// Screening of text that came from outside (a pasted message, a web page, token metadata, an API reply)
/// before any model sees it. This is where prompt injection lives. Local rules run always; a classifier
/// such as Jev can add problems but can never clear one, and nothing here approves a transaction:
/// the transaction guard still checks every signature on its own.
public enum InjectionHeuristics {
    static let commandPatterns = [
        #"ignore\s+(all\s+|any\s+|the\s+)?(previous|prior|above|earlier)\s+(instructions|rules|messages|prompts)"#,
        #"disregard\s+(all\s+|the\s+|any\s+)?(previous|prior|above|earlier)"#,
        // A prompt is named as a header or a tag that opens new orders («SYSTEM PROMPT: …», «[system]», «new system prompt»);
        // a question about it («what's the system prompt size?») is not a command.
        #"(system|developer)\s+(prompt|message)\s*[:>\]]|[\[<]\s*/?\s*(system|developer)\s*[\]>]|(new|override|updated)\s+(system|developer)\s+(prompt|message)|developer\s+mode"#,
        #"(you\s+are\s+now|new\s+instructions|do\s+not\s+tell\s+the\s+user|don't\s+tell\s+the\s+user)"#,
        #"(игнорируй|забудь|отмени)\s+(все\s+|всё\s+|предыдущие\s+|прежние\s+)*(инструкции|правила|указания)"#,
        #"(системн\w+\s+(промпт\w*|сообщени\w+)\s*:|нов\w+\s+системн\w+\s+промпт|новые\s+инструкции|ты\s+теперь|не\s+(говори|сообщай)\s+пользователю)"#,
    ]
    static let transferVerbs = #"(send|transfer|withdraw|bridge|deposit|approve|pay|отправ\w*|перевед\w*|перевест\w*|переведи|выведи|вывест\w*|скинь|пополн\w*|оплат\w*)"#
    static let evmAddress = #"0x[0-9a-fA-F]{40}"#
    static let solanaAddress = #"[1-9A-HJ-NP-Za-km-z]{32,44}"#

    static func all(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? Regex(pattern) else { return [] }
        return text.matches(of: regex).map { String(text[$0.range]) }
    }

    public struct Findings: Sendable, Equatable {
        public var commands: [String] = []
        public var addresses: [String] = []
        public var transferVerb = false
    }

    public static func findings(_ text: String) -> Findings {
        var f = Findings()
        let lower = text.lowercased()
        for pattern in commandPatterns { f.commands += all(pattern, in: lower).prefix(1) }
        f.addresses = all(evmAddress, in: text)
        // A Solana address mixes digits, upper and lower case; plain words of that length do not.
        let evm = f.addresses
        f.addresses += all(solanaAddress, in: text).filter { s in
            s.contains(where: \.isNumber) && s.contains(where: \.isUppercase) && s.contains(where: \.isLowercase)
                && !evm.contains(where: { $0.contains(s) })
        }
        f.transferVerb = !all(transferVerbs, in: lower).isEmpty
        return f
    }
}

public protocol TextClassifier: Sendable {
    var name: String { get }
    /// label: "data", "instructions" or "payment_redirect"; confidence 0…1.
    func classify(_ text: String, source: String) async throws -> (label: String, confidence: Double)
}

public enum InjectionGuard {
    public static let threshold = 0.7

    /// `redirects: false` when an address in the text can't become a recipient anyway (the chat): the classifier's
    /// payment-redirect label is then a note, not a stop.
    public static func screen(_ text: String, source: String, classifier: (any TextClassifier)?, redirects: Bool = true) async -> Verdict {
        var v = Verdict()
        let f = InjectionHeuristics.findings(text)
        if !f.commands.isEmpty {
            v.problems.append("The text has commands for the assistant: “\(f.commands.joined(separator: "”, “"))”.")
        }
        if !f.addresses.isEmpty {
            if f.transferVerb {
                v.problems.append("The text asks to send funds to \(f.addresses[0]). Addresses from text never become recipients.")
            } else {
                v.checks.append("The text has an address; it will not become a payment recipient.")
            }
        }
        guard let classifier else {
            v.checks.append("Checked by local rules.")
            return v
        }
        do {
            let (label, confidence) = try await classifier.classify(text, source: source)
            let percent = Int(confidence * 100)
            switch label {
            case "data":
                v.checks.append("\(classifier.name): looks like ordinary data (\(percent)%).")
            case "instructions" where confidence >= threshold:
                v.problems.append("\(classifier.name): the text tries to steer the assistant (\(percent)%).")
            case "payment_redirect" where confidence >= threshold && redirects:
                v.problems.append("\(classifier.name): the text tries to redirect funds to its own address (\(percent)%).")
            default:
                v.checks.append("\(classifier.name) is unsure: \(label) (\(percent)%). Local rules decide.")
            }
        } catch {
            v.checks.append("\(classifier.name) is unavailable (\(error.localizedDescription)); local rules apply.")
        }
        return v
    }
}
