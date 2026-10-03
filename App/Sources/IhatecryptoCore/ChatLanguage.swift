import Foundation

/// The language of ihatecrypto's own chat replies: the user's pick in Settings, or on «auto» the language of what they last
/// wrote themselves. The model is told the same language, so its replies match.
public enum ChatLanguage: String, CaseIterable, Sendable {
    case auto, en, ru

    /// What the app types for the user (the Confirm and Cancel buttons) says nothing about their language.
    static let appWords: Set<String> = ["do it", "cancel"]

    public func isRussian(recentUserMessages: [String]) -> Bool {
        switch self {
        case .ru: return true
        case .en: return false
        case .auto:
            return Self.own(recentUserMessages)?.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } ?? false
        }
    }

    /// The last message that tells the user's language: not the app's own button words, and not a bare amount
    /// («1 sol», «10 usdc», «0.5 BONK»), which reads the same in any language (a Russian chat answered «1 sol» went English).
    static func own(_ messages: [String]) -> String? {
        messages.last { m in
            m.contains(where: \.isLetter) && !appWords.contains(m.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
                && !(m.contains(where: \.isNumber) && m.split { !$0.isLetter }.allSatisfy { w in
                    units.contains(w.lowercased()) || (w.count <= 6 && w.allSatisfy { $0.isASCII && $0.isUppercase })
                })
        }
    }
    static let units: Set<String> = ["usdc", "usdt", "usdg", "usd", "sol", "eth", "btc", "jup", "near", "jitosol", "dollar", "dollars", "bucks", "k", "x"]

    /// For the model's instructions: «Russian», «Spanish» or «English». Spanish only on «auto»: the app's own lines stay
    /// English, the model's replies follow the user.
    public func name(recentUserMessages: [String]) -> String {
        if isRussian(recentUserMessages: recentUserMessages) { return "Russian" }
        guard self == .auto, let own = Self.own(recentUserMessages) else { return "English" }
        return Self.looksSpanish(own) ? "Spanish" : "English"
    }

    /// «compra sol por 3 dólares», «¿cuánto gané?»: Spanish letters or words English doesn't use.
    public static func looksSpanish(_ text: String) -> Bool {
        let q = text.lowercased()
        return q.contains(/[ñ¿¡áéíóú]/) || q.contains(/\b(?:hola|quiero|compra|comprar|vende|vender|largo|corto|cuanto|dolares|por\s+favor|porfa|apalancamiento|riesgo|abre|abrir|cierra|cerrar|retira|deposita|mueve|gracias|precio|ganancias?|perdidas?|dame|haz|muestrame|avisame|cuando|reglas|semana|guardar|presta|pon|sube|baja|borra|cambialo|ahora|mis|tengo|dale|hazlo|vale|cancela)\b/)
    }
}

/// Short replies read without the model: a «yes» to a card waiting for Confirm, a «no» that drops it.
public enum ChatWords {
    /// A confirmation is the whole message: «делай», «да, давай», «yes, do it», «sí, hazlo», «ok». Anything more is a
    /// change or a question the model reads: «давай на 30» signed the waiting 20 when a confirmation only had to start
    /// with «давай»; «si quieres…» is an «if».
    /// A «?» asks and a «не / don't / not» refuses («ok?», «да?», «да не»); «да ну (его)» and «let it go» brush the card
    /// off: all of them are for the model.
    public static func confirms(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }.map(String.init)
        let line = " " + words.joined(separator: " ") + " "
        if text.contains(where: { $0 == "?" || $0 == "¿" }) || words.contains(where: negations.contains) || line.contains(" да ну ") || line.contains(" let it go ") {
            return false
        }
        return !words.isEmpty && words.allSatisfy { yes.contains($0) || filler.contains($0) } && words.contains(where: yes.contains)
    }
    static let yes: Set<String> = [
        "делай", "делаем", "да", "давай", "подтверждаю", "подтверди", "раскладывай", "го", "гоу", "погнали", "поехали", "жми",
        "подписывай", "подписываю", "запускай", "ок", "окей", "ага", "угу", "согласен", "согласна",
        "do", "go", "yes", "confirm", "confirmed", "sign", "ok", "okay", "yep", "yeah", "sure", "proceed",
        "sí", "si", "dale", "hazlo", "confirmo", "adelante", "vale", "claro", "acuerdo",
    ]
    static let negations: Set<String> = ["не", "нет", "ни", "no", "not", "never", "nope", "nah", "don't", "don’t", "dont"]
    /// Words that can go with a «yes» without changing it: «да, давай, сделай это», «yes please, do it now».
    static let filler: Set<String> = [
        "это", "его", "её", "ее", "сделай", "сейчас", "теперь", "пожалуйста", "плиз", "так", "ну", "и", "вперёд", "вперед", "конечно", "хорошо",
        "it", "this", "that", "now", "please", "pls", "ahead", "let's", "let’s", "lets", "let", "us", "and", "then", "just", "right",
        "de", "por", "favor", "ya", "lo",
    ]

    /// A whole-message «no»: «нет», «cancel», «no gracias», «déjalo», «стоп, передумал», «nevermind, forget it».
    /// Like a confirmation, only no-words and fillers: «не на арбитруме» is a change the model reads.
    /// «отменить?» asks; «не отменяй», «don't cancel» keep the card («не, передумал», with its comma, still drops it).
    public static func declines(_ text: String) -> Bool {
        let q = text.lowercased()
        if q.contains(where: { $0 == "?" || $0 == "¿" })
            || q.matches(of: /(?:^|[^\p{L}'’])(?:не|not|never|don['’]?t|dont)\s+([\p{L}'’]+)/).contains(where: { no.contains(String($0.1)) }) {
            return false
        }
        if q.wholeMatch(of: /\s*(?:no|nope|cancel|stop|нет|не\s+надо|отмена|отмени\w*|стоп|nein|abbrechen|non|annuler|cancelar|cancela|no\s+gracias|déjalo|dejalo|olvídalo|olvidalo|detente|para|não|nao|nie|anuluj)[.!\s]*/) != nil {
            return true
        }
        let words = q.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }.map(String.init)
        return !words.isEmpty && words.allSatisfy { no.contains($0) || noFiller.contains($0) } && words.contains(where: no.contains)
    }
    static let no: Set<String> = [
        "нет", "неа", "отмена", "отмени", "отменяй", "отменить", "стоп", "передумал", "передумала", "забей", "забудь", "cancel", "stop",
        "nevermind", "never", "forget", "nvm", "no", "nope", "abort", "cancela", "cancelar", "olvídalo", "olvidalo", "déjalo", "dejalo",
    ]
    static let noFiller: Set<String> = [
        "не", "надо", "нужно", "ну", "всё", "все", "это", "его", "её", "ее", "пожалуйста", "я", "давай", "лучше", "пока", "так",
        "it", "that", "this", "please", "mind", "i", "changed", "my", "actually", "lo", "mejor", "no",
    ]
}
