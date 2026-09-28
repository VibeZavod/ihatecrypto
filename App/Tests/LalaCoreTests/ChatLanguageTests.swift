@testable import LalaCore
import Testing

@Test func chatLanguageFollowsWhatTheUserWrote() {
    #expect(ChatLanguage.auto.isRussian(recentUserMessages: ["выведи всё из Jupiter Lend"]))
    #expect(!ChatLanguage.auto.isRussian(recentUserMessages: ["withdraw all from Jupiter"]))
    // The Confirm button types «do it»: that doesn't switch a Russian conversation to English.
    #expect(ChatLanguage.auto.isRussian(recentUserMessages: ["продай весь NEAR", "do it"]))
    #expect(ChatLanguage.auto.isRussian(recentUserMessages: ["sell NEAR", "продай весь NEAR", "cancel"]))
    // Numbers or an address alone say nothing either.
    #expect(ChatLanguage.auto.isRussian(recentUserMessages: ["купи на", "2"]))
    #expect(!ChatLanguage.auto.isRussian(recentUserMessages: []))
    // A pick in Settings wins.
    #expect(ChatLanguage.ru.isRussian(recentUserMessages: ["hello"]))
    #expect(!ChatLanguage.en.isRussian(recentUserMessages: ["привет"]))
    #expect(ChatLanguage.auto.name(recentUserMessages: ["привет"]) == "Russian")
}
