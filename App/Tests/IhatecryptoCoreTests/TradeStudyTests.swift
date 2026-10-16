import Foundation
@testable import IhatecryptoCore
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }
private func fill(_ coin: String, _ side: String, _ sz: Decimal, at px: Decimal, start: Decimal, pnl: Decimal = 0, _ hours: Double, dir: String = "") -> TradeHistory.Fill {
    TradeHistory.Fill(coin: coin, px: px, sz: sz, side: side, time: at(hours), startPosition: start, dir: dir, closedPnl: pnl, fee: 1)
}

// A HYPE long that wins 50 (two fees), an ETH short added to as it went against it that loses 30 and paid 2 of funding,
// a BTC long that wins 10, and a SOL long still open.
private let fills = [
    fill("HYPE", "B", 10, at: 20, start: 0, 0), fill("HYPE", "A", 10, at: 25, start: 10, pnl: 50, 5),
    fill("ETH", "A", 1, at: 3000, start: 0, 10), fill("ETH", "A", 1, at: 3100, start: -1, 12),
    fill("ETH", "B", 2, at: 3065, start: -2, pnl: -30, 40),
    fill("BTC", "B", 0.1, at: 60000, start: 0, 50), fill("BTC", "A", 0.1, at: 60100, start: 0.1, pnl: 10, 51),
    fill("SOL", "B", 1, at: 150, start: 0, 60),
]
private let funding = [PnL.Funding(time: at(20), coin: "ETH", usdc: -2), PnL.Funding(time: at(70), coin: "ETH", usdc: -5)]

@Test func tradesAreMeasuredAfterFeesAndFunding() {
    let trades = TradeStudy.trades(TradeHistory.stories(fills), funding: funding)
    #expect(trades.map(\.coin) == ["HYPE", "ETH", "BTC"])   // closed only, oldest first
    #expect(trades.map(\.net) == [48, -35, 8])               // fees 2, 3, 2; ETH's funding while open only
    let eth = trades[1]
    #expect(!eth.long && eth.adds == 1 && eth.addsLosing == 1)   // a short added above its entry: adding to a loser
    #expect(eth.entry == 3050 && eth.peakUSD == 6100)
    let s = TradeStudy.stats(trades)
    #expect(s.count == 3 && s.wins == 2 && s.total == 21)
    #expect(s.profitFactor == Decimal(56) / 35)
    #expect(s.maxDrawdown == 35)
    #expect(TradeStudy.concentration(trades) == nil)   // two winners say nothing about luck
    let report = TradeStudy.report(trades, open: 1, timeZone: TimeZone(identifier: "UTC")!)
    #expect(report.contains("All: 3 trades, won 67%, net $21.00"))
    #expect(report.contains("Added to a loser: 1 trade, won 0%"))
    // A position the history begins inside of has no entry: left out, and said.
    let cutShort = [fill("BTC", "A", 1, at: 60000, start: 1, pnl: 5, 1)] + fills
    #expect(TradeStudy.trades(TradeHistory.stories(cutShort), funding: []).count == 3)
    #expect(TradeStudy.cut(TradeHistory.stories(cutShort)) == 1)
    #expect(report.contains("1 still open, not counted"))
    #expect(TradeStudy.report([], open: 0) == "No closed Hyperliquid positions in this history.")
}

@Test func mostOfTheProfitFromAFewTrades() {
    func trade(_ net: Decimal) -> TradeStudy.Trade {
        TradeStudy.Trade(coin: "BTC", long: true, opened: t0, closed: at(1), net: net, fees: 0, funding: 0, peakUSD: 100, entry: 1,
                         adds: 0, addsLosing: 0, liquidated: false)
    }
    let trades = [100, 10, 10, 10, -20].map { trade(Decimal($0)) }
    #expect(TradeStudy.concentration(trades)! == (1, Decimal(100) / 130 * 100))
    #expect(TradeStudy.report(trades, open: 0).contains("77% of the profit came from 1 trade."))
    #expect(TradeStudy.report(trades, open: 0).contains("Without the best 1: 4 trades, won 75%, net $10.00"))
}

@Test func aFlipClosesOneTradeAndOpensTheNext() {
    let flip = [fill("ETH", "B", 1, at: 3000, start: 0, 0), fill("ETH", "A", 3, at: 3100, start: 1, pnl: 100, 2, dir: "Long > Short"),
                fill("ETH", "B", 2, at: 3050, start: -2, pnl: 100, 4)]
    let trades = TradeStudy.trades(TradeHistory.stories(flip), funding: [])
    #expect(trades.count == 2)
    #expect(trades[0].long && trades[0].adds == 0 && trades[0].peakUSD == 3000)
    #expect(!trades[1].long && trades[1].entry == 3100)
}

@Test func journalAndStudyCommandsParse() {
    #expect(JournalCommand.parse("journal HYPE: лонг тут, фандинг норм") == JournalCommand(asset: "HYPE", words: "лонг тут, фандинг норм"))
    #expect(JournalCommand.parse("journal xyz:GOLD: short, dollar ripping")?.asset == "xyz:GOLD")
    #expect(JournalCommand.parse("journal: no asset") == nil)
    #expect(StudyNote.parse("study hypotheses: strong alts in BTC chop") == StudyNote(file: "HYPOTHESES", text: "strong alts in BTC chop"))
    #expect(StudyNote.parse("study TRADING_PLAYBOOK: v2")?.file == "TRADING_PLAYBOOK")
    #expect(StudyNote.parse("study diary: x") == nil)
    #expect(ChatRouter.parses("journal HYPE: long here then add", markets: []))   // «then» inside their words is no chain
    #expect(ChatRouter.forms.contains("journal <ASSET>: <THEIR OWN WORDS>"))
}

@Test func aJournalEntryReviewsWhatThePriceDidSince() {
    var e = JournalEntry(at: t0, asset: "HYPE", words: "long here")
    e.price = 20; e.funding = Decimal(string: "0.0000125"); e.market = ["BTC $60,000 (24h +1%)"]
    var big = e
    big.openInterestUSD = 1_638_197_533; big.volume24h = 585_323_002
    #expect(big.snapshot.contains("open interest $1.64B, 24h volume $585.3M"))
    #expect(e.review(now: 25, at: at(30)).hasSuffix("[price 20, funding 0.0013% an hour; BTC $60,000 (24h +1%)] → since: 20 → 25 (+25%) in 30 h"))
}

@Test func aSkillFileReadsItsNameAndPurpose() {
    let md = Skill.parse("---\nname: Swing review\ndescription: \"Reviews swing trades\"\n---\n# Steps\nDo this.", fileName: "SKILL.md")
    #expect(md.name == "Swing review" && md.about == "Reviews swing trades" && md.id == "swing-review" && md.text == "# Steps\nDo this.")
    let txt = Skill.parse("You are my trading researcher.\n\nMore.", fileName: "codex_trading_study_prompt.txt")
    #expect(txt.name == "Codex trading study prompt" && txt.about == "You are my trading researcher." && !txt.builtIn)
    #expect(Skill.tradingStudy.text.contains("## HOW THIS STUDY RUNS IN IHATECRYPTO") && Skill.tradingStudy.id == "trading-study")
}
