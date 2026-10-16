import Foundation
import Testing
@testable import IhatecryptoCore

private let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }()
private let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 10, minute: 30))!
private func date(_ d: Int, _ h: Int, _ m: Int = 0, month: Int = 9) -> Date { cal.date(from: DateComponents(year: 2026, month: month, day: d, hour: h, minute: m))! }

@Test func scheduledTaskReadsTheRouterForms() throws {
    let week = try #require(ScheduledTask.parse("in 1 week: rebalance USDC", now: now))
    #expect(week.steps == ["rebalance USDC"] && week.every == nil && week.next == date(6, 10, 30, month: 10))
    #expect(ScheduledTask.parse("in 30 minutes: lock", now: now)?.next == now.addingTimeInterval(1800))
    // «at 09:00» already passed today: tomorrow; the colon after the time ends the head.
    let nine = try #require(ScheduledTask.parse("at 09:00: what's moving", now: now))
    #expect(nine.next == date(30, 9) && nine.steps == ["what's moving"])
    #expect(ScheduledTask.parse("at 18:15: chart ETH", now: now)?.next == date(29, 18, 15))
    #expect(ScheduledTask.parse("tomorrow at 8:05: profit and loss today", now: now)?.next == date(30, 8, 5))
    #expect(ScheduledTask.parse("on 2026-10-05 at 14:00: withdraw from HLP", now: now)?.next == date(5, 14, month: 10))
    #expect(ScheduledTask.parse("on 2026-10-05: withdraw from HLP", now: now)?.next == date(5, 9, month: 10))
    #expect(ScheduledTask.parse("on 2026-09-01: withdraw from HLP", now: now) == nil)   // in the past
    // Repeats, and several steps.
    let daily = try #require(ScheduledTask.parse("every day at 09:00: sell SOL then lend USDC", now: now))
    #expect(daily.every == .days(1) && daily.next == date(30, 9) && daily.steps == ["sell SOL", "lend USDC"])
    #expect(ScheduledTask.parse("every week: rebalance USDC max 40% per protocol", now: now)?.every == .days(7))
    #expect(ScheduledTask.parse("every 2 weeks: rebalance USDC", now: now)?.every?.words == "2 weeks")
    #expect(ScheduledTask.parse("every month: profit and loss month", now: now)?.next == date(29, 10, 30, month: 10))
    #expect(ScheduledTask.parse("every 6 hours: what's moving", now: now)?.next == date(29, 16, 30))
    // 2026-09-29 is a Tuesday: the next Monday is Oct 5.
    let monday = try #require(ScheduledTask.parse("every monday at 10:00: profit and loss week", now: now))
    #expect(monday.next == date(5, 10, month: 10) && monday.every == .days(7))
    #expect(ScheduledTask.parse("every tuesday: rebalance USDC", now: now)?.next == date(6, 9, month: 10))   // today's 09:00 passed
    // Not tasks.
    #expect(ScheduledTask.parse("rebalance USDC", now: now) == nil)
    #expect(ScheduledTask.parse("buy SOL for 10 USDC every week", now: now) == nil)   // recurring buys keep their form
    #expect(ScheduledTask.parse("alert me when ETH is above 4000", now: now) == nil)
    #expect(ScheduledTask.parse("every day: in 1 week: lock", now: now) == nil)       // no task inside a task
    #expect(ScheduledTask.parse("every 0 days: lock", now: now) == nil)
    #expect(ScheduledTask.cancelsAll("cancel scheduled tasks") && ScheduledTask.cancelsAll("Stop all scheduled tasks"))
}

@Test func scheduledTaskRunsOnceAfterALongSleep() {
    var once = ScheduledTask(steps: ["lock"], next: now, every: nil)
    let again = once.advance(now: now)
    #expect(!again)
    var daily = ScheduledTask(steps: ["what's moving"], next: date(20, 9), every: .days(1))
    let d = daily.advance(now: now)
    #expect(d && daily.next == date(30, 9))   // nine missed days: one run, then tomorrow
    var monthly = ScheduledTask(steps: ["profit and loss month"], next: date(31, 9, month: 8), every: .months(1))
    let m = monthly.advance(now: now)
    #expect(m && monthly.next == date(30, 9))   // Aug 31 → Sep 30, already after now
    _ = monthly.advance(now: monthly.next)
    #expect(monthly.next == date(30, 9, month: 10))   // ponytail: a month-end date drifts to the 30th
}

@Test func rewardSweepsParseAndScheduleHourly() throws {
    #expect(WalletCommand.parse("sweep rewards over $10 into USDC") == .sweepRewards(minUSD: 10, into: nil))
    #expect(WalletCommand.parse("sweep rewards into WETH") == .sweepRewards(minUSD: nil, into: "WETH"))
    #expect(WalletCommand.parse("sell my rewards for usdc") == .sweepRewards(minUSD: nil, into: nil))
    #expect(WalletCommand.parse("продавай награды в USDC, когда наберётся $10") == .sweepRewards(minUSD: 10, into: nil))
    #expect(WalletCommand.parse("claim rewards") == .claimRewards)   // claiming alone keeps them
    let task = try #require(ScheduledTask.parse("every hour: sweep rewards over $10 into USDC"))
    #expect(task.every == .hours(1) && task.steps == ["sweep rewards over $10 into USDC"])
}

/// The runs a budget has to cover: a daily buy seven times in the next week from an hour from now, a weekly one once,
/// a one-off once inside the window and never after it.
@Test func runsUntilADate() {
    let now = Date(), week = now.addingTimeInterval(7 * 86_400 - 1)
    #expect(ScheduledTask(steps: ["buy SOL for 5 USDC"], next: now.addingTimeInterval(3600), every: .days(1)).runs(until: week) == 7)
    #expect(ScheduledTask(steps: ["buy SOL for 5 USDC"], next: now.addingTimeInterval(3600), every: .days(7)).runs(until: week) == 1)
    #expect(ScheduledTask(steps: ["buy SOL for 5 USDC"], next: now.addingTimeInterval(3600), every: nil).runs(until: week) == 1)
    #expect(ScheduledTask(steps: ["buy SOL for 5 USDC"], next: now.addingTimeInterval(8 * 86_400), every: nil).runs(until: week) == 0)
    #expect(ScheduledTask(steps: ["buy SOL for 5 USDC"], next: now, every: .hours(1)).runs(until: now.addingTimeInterval(86_400)) == 25)
}
