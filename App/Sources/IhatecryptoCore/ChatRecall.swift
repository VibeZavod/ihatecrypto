import Foundation
import LLMCore

/// How much of a canvas's chat goes to the model with each message: the whole conversation while it fits, its newest
/// part once it doesn't, so a chat never ends by itself.
public enum ChatRecall {
    /// A text's size in tokens, near enough for a budget: four bytes a token (English ≈ 4 letters, Cyrillic ≈ 2).
    /// Claude Opus 5.5 counted about twice that for a chat of both languages (2026-10-13): the budgets below leave room.
    public static func tokens(_ text: String) -> Int { (text.utf8.count + 3) / 4 }

    /// The chat's lines that go with a message, oldest first.
    /// A wide window (a cloud model's): the whole chat up to `most` tokens, then its newest lines.
    /// A small one (`small`: a model on this Mac, whose window is 16k or unknown; or a window under 100k): the last 12
    /// lines, as every model got before 2026-10-13, and fewer when they're long — it holds the instructions and little
    /// else, and Ollama cuts a prompt that doesn't fit from its start, the instructions.
    public static func sent(_ lines: [String], window: Int?, small: Bool, instructions: Int, most: Int = 4_000) -> [String] {
        let small = small || (window ?? .max) < 100_000
        // 3,000: what the brief adds around the chat (canvas, balances, positions, the message) and the answer.
        let room = window.map { max(400, $0 - instructions - 3_000) } ?? most
        return fitting(small ? Array(lines.suffix(12)) : lines, budget: min(most, room))
    }

    /// The newest lines that fit `budget` tokens, oldest first. The last two go whatever their size: a follow-up
    /// («1», «да») is read by the question before it.
    public static func fitting(_ lines: [String], budget: Int) -> [String] {
        var left = budget, kept = 0
        for line in lines.reversed() {
            let size = tokens(line)
            if kept >= 2, size > left { break }
            left -= size
            kept += 1
        }
        return Array(lines.suffix(kept))
    }
}

extension ChatRouter {
    /// Whether a request is the chat reading a message (the instructions lead it): the one that carries everything
    /// the model is given, so the one that fills its window.
    public static func reads(_ request: LLMRequest) -> Bool { request.system == system }

    /// The instructions' size in tokens, near enough.
    public static var instructionTokens: Int { ChatRecall.tokens(system) }
}
