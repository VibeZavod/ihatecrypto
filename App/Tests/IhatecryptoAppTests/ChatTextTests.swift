@testable import IhatecryptoApp
import Foundation
import Testing

// The chat's reply header, its paragraphs and lists (ChatReplies.swift), and the amount the slider over the field sets
// (ComposerField.swift).

@Test func replyHeaderNamesTheModelAndHidesWhatItUnderstood() {
    let understood = ChatText.header("understood as “send 0.01 SOL to Automation” · claude-opus-5-5")
    #expect(understood == .init(label: "Claude Opus 5.5", detail: "Understood as “send 0.01 SOL to Automation”", result: false))
    #expect(ChatText.header("claude-opus-5-5 · looked at portfolio, rpc").detail == "Looked at portfolio, rpc")
    #expect(ChatText.header("claude-opus-5-5").label == "Claude Opus 5.5")
    // Where a move ran is a result's card.
    #expect(ChatText.header("Relay · Solana → Base") == .init(label: "Relay · Solana → Base", detail: nil, result: true))
    #expect(ChatText.header("transfer").label == "Transfer")
}

@Test func replyWordsSplitIntoParagraphsAndLists() {
    let blocks = ChatText.blocks("Money went two ways.\n\n- 25 USDT to Automation\n- 1 USDC to Base\n2. fees\n## Next\n−5% today stays a line")
    #expect(blocks.map(\.mark) == [nil, "•", "•", "2.", nil, nil])
    #expect(blocks[4].text == "**Next**" && blocks[5].text == "−5% today stays a line")
    #expect(ChatText.blocks("one\ntwo").count == 1)
}

@Test func draftAmountFindsTheNumberAndWritesItBack() {
    let draft = "send 0.01 $SOL to Automation on Solana"
    let found = DraftAmount.all(draft)
    #expect(found.map(\.ticker) == ["SOL"] && found[0].value == Decimal(string: "0.01"))
    #expect(DraftAmount.place(draft) == "solana")
    #expect(found[0].replacing(in: draft, with: Decimal(string: "0.05")!, scale: 2) == "send 0.05 $SOL to Automation on Solana")
    // A step is a tenth of the held amount's order; thousands carry no comma.
    #expect(DraftAmount.scale(Decimal(string: "0.1756")!) == 2 && DraftAmount.scale(Decimal(string: "45.97")!) == 0)
    #expect(DraftAmount.written(1234, scale: 0) == "1234")
    // Words after a number aren't tokens unless held: the composer checks; «2x» is too short to be one.
    #expect(DraftAmount.all("long ETH leverage 2x").isEmpty)
}

@Test func tildesStayTildesAndBlocksSayWhatWent() {
    // The model's «~87% … ~$8.1» once came out struck through.
    let s = ChatText.styled("то есть ~87%. SPX (~$8.1)")
    #expect(String(s.characters) == "то есть ~87%. SPX (~$8.1)")
    #expect(!s.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
    // A block whose numbers went isn't bare; one that went by its name is.
    #expect(!StepContext(title: "Chart · NEAR", logo: nil, about: StepContext.block("Chart · NEAR", shows: "chart NEAR 24 h …")).bare)
    #expect(StepContext(title: "Ledger", logo: nil, about: StepContext.block("Ledger", shows: nil)).bare)
}
