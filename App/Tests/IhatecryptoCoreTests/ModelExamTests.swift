import Testing
@testable import IhatecryptoCore

/// The judge takes a right reading of every question and refuses a wrong one.
@Test func theModelExamJudgesRightAndWrongReadings() {
    for q in ModelExam.questions {
        #expect(q.passes(q.ideal, ModelExam.markets), "\(q.message) → \(q.ideal)")
        #expect(!q.passes(.command("sell all SOL"), ModelExam.markets) || q.message.contains("сколько") == false, "\(q.message)")
    }
    // A move read for a question, a chat for a move: both wrong.
    let money = ModelExam.questions.first { $0.message.hasPrefix("сколько") }!
    #expect(!money.passes(.command("send 5 USDC to Mom"), ModelExam.markets))
    let buy = ModelExam.questions[0]
    #expect(!buy.passes(.chat("Sure!"), ModelExam.markets) && !buy.passes(.command("buy SOL for 50 USDC"), ModelExam.markets))
    #expect(ModelExam.Result(passed: 8, total: 10, seconds: 2, misses: []).good && !ModelExam.Result(passed: 7, total: 10, seconds: 2, misses: []).good)
}
