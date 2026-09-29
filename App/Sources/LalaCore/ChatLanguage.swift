import Foundation

/// The language of LALA's own chat replies: the user's pick in Settings, or on «auto» the language of what they last
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
            let own = recentUserMessages.last { m in
                m.contains(where: \.isLetter) && !Self.appWords.contains(m.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return own?.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } ?? false
        }
    }

    /// For the model's instructions: «Russian», «Spanish» or «English». Spanish only on «auto»: the app's own lines stay
    /// English, the model's replies follow the user.
    public func name(recentUserMessages: [String]) -> String {
        if isRussian(recentUserMessages: recentUserMessages) { return "Russian" }
        guard self == .auto, let own = recentUserMessages.last(where: { m in
            m.contains(where: \.isLetter) && !Self.appWords.contains(m.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        }) else { return "English" }
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
    /// «делай», «do it», «sí», «dale» start a confirmation; «ok», «si», «vale» only on their own («si quieres…» is an «if»).
    public static func confirms(_ text: String) -> Bool {
        let q = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return q.contains(/^(?:делай|да|давай|подтверждаю|раскладывай|го|do\s+it|go|yes|confirm|sign|sí|dale|hazlo|confirmo|adelante)\b/)
            || q.wholeMatch(of: /(?:ok|okay|ок|окей|ага|угу|yep|yeah|sure|si|vale|claro|de\s+acuerdo)[.!\s]*/) != nil
    }

    /// A whole-message «no»: «нет», «cancel», «no gracias», «déjalo».
    public static func declines(_ text: String) -> Bool {
        text.lowercased().wholeMatch(of: /\s*(?:no|nope|cancel|stop|нет|не\s+надо|отмена|отмени\w*|стоп|nein|abbrechen|non|annuler|cancelar|cancela|no\s+gracias|déjalo|dejalo|olvídalo|olvidalo|detente|para|não|nao|nie|anuluj)[.!\s]*/) != nil
    }
}
