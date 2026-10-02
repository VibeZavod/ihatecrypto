import Testing
@testable import IhatecryptoCore

// Folders from the chat: saving the open canvas there, or writing a note into one.
@Test func folderCommandsParse() {
    #expect(FolderCommand.parse("save this canvas to folder Research") == .save(folder: "Research"))
    #expect(FolderCommand.parse("сохрани этот холст в папку Ресерч") == .save(folder: "Ресерч"))
    #expect(FolderCommand.parse("положи в папку «Токены на Robinhood»") == .save(folder: "Токены на Robinhood"))
    #expect(FolderCommand.parse("write to folder Ideas: buy MOO if it holds $0.006") == .note(folder: "Ideas", text: "buy MOO if it holds $0.006"))
    #expect(FolderCommand.parse("запиши в папку Идеи: проверить SHROOM завтра\nи продать половину") == .note(folder: "Идеи", text: "проверить SHROOM завтра\nи продать половину"))
    #expect(FolderCommand.parse("send 5 USDC to Mom") == nil)
    #expect(FolderCommand.parse("save 0x060b0fB0Be9d90557577B3AEE480711067149Ff0 as Shop on tempo") == nil)
    #expect(ChatRouter.parses("save this canvas to folder Research", markets: []) && ChatRouter.parses("write to folder Ideas: hello", markets: []))
}

// The chat's answer shows while its JSON is still being written: only a chat or clarify reply, never a command's.
@Test func partialReplyReadsUnfinishedJSON() {
    #expect(ChatRouter.partialReply(#"{"route": "chat", "reply": "Bitcoin is at $83,5"#) == "Bitcoin is at $83,5")
    #expect(ChatRouter.partialReply(#"{"route":"clarify","reply":"Which \"MOO\"?\nThe one on Robinhood","options":[]}"#) == "Which \"MOO\"?\nThe one on Robinhood")
    #expect(ChatRouter.partialReply(#"{"route": "chat", "reply": "При"#) == "При")
    #expect(ChatRouter.partialReply(#"{"route": "command", "command": "buy SOL for 2 USDC", "reply": "Buying"#) == nil)
    #expect(ChatRouter.partialReply(#"{"route": "lookup", "lookups": [{"tool": "portfolio"#) == nil)
    #expect(ChatRouter.partialReply(#"{"route": "chat", "rep"#) == nil)
}
