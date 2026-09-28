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

    /// For the model's instructions: «Russian» or «English».
    public func name(recentUserMessages: [String]) -> String { isRussian(recentUserMessages: recentUserMessages) ? "Russian" : "English" }
}
