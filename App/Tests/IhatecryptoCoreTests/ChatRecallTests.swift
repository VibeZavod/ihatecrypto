@testable import IhatecryptoCore
import LLMCore
import Testing

@Test func aShortChatGoesWholeAndALongOneKeepsItsNewestLines() {
    let lines = (1...40).map { "user: buy SOL for \($0) USDC" }
    #expect(ChatRecall.fitting(lines, budget: 4_000) == lines)
    // 7 tokens a line: 70 hold the last ten, oldest first.
    let kept = ChatRecall.fitting(lines, budget: 70)
    #expect(kept == Array(lines.suffix(10)))
    // The question a follow-up answers always goes, whatever its size.
    let long = ["user: " + String(repeating: "я", count: 3_000), "ihatecrypto: How much?"]
    #expect(ChatRecall.fitting(lines + long, budget: 10) == long)
    #expect(ChatRecall.fitting([], budget: 10).isEmpty)
}

@Test func aWideWindowGetsTheWholeChatAndASmallOneNeverMoreThanBefore() {
    let lines = (1...40).map { "user: buy SOL for \($0) USDC" }
    // A cloud model's window, or one its service didn't tell: the whole chat, up to the cap (7 tokens a line).
    #expect(ChatRecall.sent(lines, window: 1_000_000, small: false, instructions: 10_000) == lines)
    #expect(ChatRecall.sent(lines, window: nil, small: false, instructions: 10_000) == lines)
    #expect(ChatRecall.sent(lines, window: 1_000_000, small: false, instructions: 10_000, most: 70) == Array(lines.suffix(10)))
    // Ollama's 16,384, or a local server that doesn't say (LM Studio): the last 12 lines, as before the whole chat was sent.
    #expect(ChatRecall.sent(lines, window: 16_384, small: true, instructions: 10_000) == Array(lines.suffix(12)))
    #expect(ChatRecall.sent(lines, window: nil, small: true, instructions: 10_000) == Array(lines.suffix(12)))
    #expect(ChatRecall.sent(lines, window: 32_000, small: false, instructions: 10_000) == Array(lines.suffix(12)))
    // …and fewer when they're long: 3,384 tokens are left beside 10k of instructions, the brief and the answer.
    let pasted = (1...12).map { "user: \($0) " + String(repeating: "x", count: 2_990) }
    #expect(ChatRecall.sent(pasted, window: 16_384, small: true, instructions: 10_000) == Array(pasted.suffix(4)))
    // Instructions that nearly fill the window still leave the question a follow-up answers.
    #expect(ChatRecall.sent(pasted, window: 8_192, small: true, instructions: 10_000) == Array(pasted.suffix(2)))
    // Cyrillic costs about twice a Latin letter.
    #expect(ChatRecall.tokens("купи") == 2 && ChatRecall.tokens("buy!") == 1)
}

@Test func onlyTheChatsOwnReadingCountsAsItsContext() {
    #expect(ChatRouter.reads(LLMRequest(model: "m", messages: [LLMMessage(.system, ChatRouter.system), LLMMessage(.user, "hi")])))
    #expect(!ChatRouter.reads(LLMRequest(model: "m", messages: [LLMMessage(.user, "Reply with one word: works")])))
    #expect(ChatRouter.instructionTokens > 1_000)
}
