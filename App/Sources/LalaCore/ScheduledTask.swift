import Foundation

/// A command the app runs later, once or on repeat: «in 1 week: rebalance USDC», «every day at 09:00: sell SOL then
/// lend USDC». Each step is one of the router's English forms and runs as if typed, on a canvas of its own; a money
/// move among them stops at its Confirm card, and the steps after it wait for that move to finish.
public struct ScheduledTask: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var steps: [String]
    public var next: Date
    /// nil: once.
    public var every: Every?
    /// What started it when the clock didn't: «ETH went below 2,680» for a price alert's steps.
    public var because: String?

    public enum Every: Codable, Equatable, Sendable {
        case hours(Int), days(Int), months(Int)

        public var words: String {
            switch self {
            case .hours(1): "hour"
            case .hours(let n): "\(n) hours"
            case .days(1): "day"
            case .days(7): "week"
            case .days(let n) where n % 7 == 0: "\(n / 7) weeks"
            case .days(let n): "\(n) days"
            case .months(1): "month"
            case .months(let n): "\(n) months"
            }
        }

        func after(_ d: Date, _ cal: Calendar) -> Date {
            switch self {
            case .hours(let n): d.addingTimeInterval(TimeInterval(n) * 3600)
            case .days(let n): cal.date(byAdding: .day, value: n, to: d) ?? d.addingTimeInterval(TimeInterval(n) * 86_400)
            case .months(let n): cal.date(byAdding: .month, value: n, to: d) ?? d.addingTimeInterval(TimeInterval(n) * 30 * 86_400)
            }
        }
    }

    public init(steps: [String], next: Date, every: Every?, because: String? = nil) {
        (self.steps, self.next, self.every, self.because) = (steps, next, every, because)
    }

    /// Dates are Gregorian whatever the Mac's calendar is (this one is set to Buddhist years).
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }

    /// «cancel scheduled tasks» and its wordings: every task goes.
    public static func cancelsAll(_ text: String) -> Bool {
        text.lowercased().contains(/(?:cancel|stop|remove|delete|clear)\s+(?:all\s+)?(?:the\s+)?scheduled\s+tasks?/)
    }

    /// The router's forms: `in N <minutes|hours|days|weeks|months>: …`, `at HH:MM: …`, `tomorrow [at HH:MM]: …`,
    /// `on YYYY-MM-DD [at HH:MM]: …`, `every <hour|day|week|month|N hours|N days|N weeks|N months> [at HH:MM]: …`,
    /// `every month on the <1st…28th> [at HH:MM]: …`,
    /// `every <monday…sunday> [at HH:MM]: …` (09:00 when no time is said),
    /// steps joined by « then ». nil for anything else.
    public static func parse(_ text: String, now: Date = Date()) -> ScheduledTask? {
        guard let colon = text.firstIndex(of: ":").flatMap({ i in
            // The colon that ends «… at 09:00:» is the one after the time.
            text[i...].prefixMatch(of: /:\d\d:/) != nil ? text.index(i, offsetBy: 3) : i
        }) else { return nil }
        let head = text[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
        let steps = text[text.index(after: colon)...].split(separator: /\s+then\s+|\s*;\s*/)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !steps.isEmpty, steps.allSatisfy({ parse($0) == nil }) else { return nil }   // no task inside a task
        let cal = calendar
        let clock = head.firstMatch(of: /\bat\s+(\d{1,2}):(\d\d)$/).flatMap { m -> (Int, Int)? in
            guard let h = Int(m.1), let mi = Int(m.2), h < 24, mi < 60 else { return nil }
            return (h, mi)
        }
        /// The first time at that clock on or after `day`'s date, and after now.
        func at(_ day: Date, _ c: (Int, Int)) -> Date? {
            var d = cal.date(bySettingHour: c.0, minute: c.1, second: 0, of: day)
            if let x = d, x <= now { d = cal.date(byAdding: .day, value: 1, to: x) }
            return d
        }
        if let m = head.wholeMatch(of: /in\s+(\d+)\s+(minute|hour|day|week|month)s?/), let n = Int(m.1), n > 0 {
            let next: Date = switch m.2 {
            case "minute": now.addingTimeInterval(TimeInterval(n) * 60)
            case "hour": Every.hours(n).after(now, cal)
            case "day": Every.days(n).after(now, cal)
            case "week": Every.days(7 * n).after(now, cal)
            default: Every.months(n).after(now, cal)
            }
            return ScheduledTask(steps: steps, next: next, every: nil)
        }
        if let c = clock, head.wholeMatch(of: /at\s+\d{1,2}:\d\d/) != nil, let next = at(now, c) {
            return ScheduledTask(steps: steps, next: next, every: nil)
        }
        if head.wholeMatch(of: /tomorrow(?:\s+at\s+\d{1,2}:\d\d)?/) != nil, let tomorrow = cal.date(byAdding: .day, value: 1, to: now) {
            let next = clock.flatMap { cal.date(bySettingHour: $0.0, minute: $0.1, second: 0, of: tomorrow) } ?? tomorrow
            return ScheduledTask(steps: steps, next: next, every: nil)
        }
        if let m = head.wholeMatch(of: /on\s+(\d{4})-(\d\d)-(\d\d)(?:\s+at\s+\d{1,2}:\d\d)?/),
           let day = cal.date(from: DateComponents(year: Int(m.1), month: Int(m.2), day: Int(m.3), hour: clock?.0 ?? 9, minute: clock?.1 ?? 0)), day > now {
            return ScheduledTask(steps: steps, next: day, every: nil)
        }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let m = head.wholeMatch(of: /every\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)(?:\s+at\s+\d{1,2}:\d\d)?/),
           let w = weekdays.firstIndex(of: String(m.1)),
           let next = cal.nextDate(after: now, matching: DateComponents(hour: clock?.0 ?? 9, minute: clock?.1 ?? 0, weekday: w + 1), matchingPolicy: .nextTime) {
            return ScheduledTask(steps: steps, next: next, every: .days(7))
        }
        // «every month on the 1st at 10:00»: that day of each month, 1–28 so every month has it; 09:00 when no time is said.
        if let m = head.wholeMatch(of: /every\s+month\s+on\s+(?:the\s+|day\s+)?(\d{1,2})(?:st|nd|rd|th)?(?:\s+at\s+\d{1,2}:\d\d)?/),
           let day = Int(m.1), (1...28).contains(day),
           let next = cal.nextDate(after: now, matching: DateComponents(day: day, hour: clock?.0 ?? 9, minute: clock?.1 ?? 0), matchingPolicy: .nextTime) {
            return ScheduledTask(steps: steps, next: next, every: .months(1))
        }
        if let m = head.wholeMatch(of: /every\s+(?:(\d+)\s+)?(hour|day|week|month)s?(?:\s+at\s+\d{1,2}:\d\d)?/) {
            let n = m.1.flatMap { Int($0) } ?? 1
            guard n > 0 else { return nil }
            let every: Every = switch m.2 { case "hour": .hours(n); case "day": .days(n); case "week": .days(7 * n); default: .months(n) }
            // «every day at 09:00»: the next 09:00; without a time, one period from now.
            let next = clock.flatMap { at(now, $0) } ?? every.after(now, cal)
            return ScheduledTask(steps: steps, next: next, every: every)
        }
        return nil
    }

    /// After a run: false when it was the only one; else the next date strictly in the future, so a Mac asleep for a
    /// week runs a daily task once, not seven times.
    public mutating func advance(now: Date = Date()) -> Bool {
        guard let every else { return false }
        repeat { next = every.after(next, Self.calendar) } while next <= now
        return true
    }

    /// «every week · next Oct 6, 9:00 AM» / «once · Oct 6, 9:00 AM»
    public var when: String { (every.map { "every \($0.words) · next " } ?? "once · ") + Fmt.date(next) }
}
