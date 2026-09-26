import Foundation

/// "Spread it over the best rates": the free amount goes to the best rates first, no protocol above `maxShare` of
/// everything the asset is in (what is already deposited counts), and a protocol whose entry costs more than it is
/// worth is skipped with the reason. Pure, so the rules are tested apart from the chain.
public enum Allocation {
    public struct Place: Sendable, Equatable {
        public let name: String
        /// % a year.
        public let apy: Decimal
        /// Already there, in the asset's units.
        public let existing: Decimal
        /// Why LALA will not put money here now, or nil.
        public let blocked: String?

        public init(name: String, apy: Decimal, existing: Decimal = 0, blocked: String? = nil) {
            self.name = name
            self.apy = apy
            self.existing = existing
            self.blocked = blocked
        }
    }

    public struct Slice: Sendable, Equatable {
        public let place: String
        public let amount: Decimal
        public let apy: Decimal
    }

    public struct Result: Sendable {
        public let slices: [Slice]
        /// Not placed: nowhere left under the limit.
        public let leftover: Decimal
        public let notes: [String]
        /// Expected a year from the new slices, in the asset's units.
        public var yearly: Decimal { slices.reduce(0) { $0 + $1.amount * $1.apy / 100 } }
    }

    /// `minSlice`: smaller pieces are not worth a transaction.
    public static func plan(free: Decimal, places: [Place], maxShare: Decimal, minSlice: Decimal) -> Result {
        let total = free + places.reduce(0) { $0 + $1.existing }
        let cap = total * maxShare / 100
        var left = free
        var slices: [Slice] = []
        var notes: [String] = []
        for p in places.sorted(by: { $0.apy > $1.apy }) {
            if let reason = p.blocked { notes.append("\(p.name) (\(p.apy.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US"))))%): skipped, \(reason)."); continue }
            let room = max(0, cap - p.existing)
            let amount = min(left, room)
            guard amount >= minSlice else {
                if room < minSlice, p.existing > 0 { notes.append("\(p.name): already at the \(maxShare)% limit.") }
                continue
            }
            slices.append(Slice(place: p.name, amount: amount, apy: p.apy))
            left -= amount
            if left < minSlice { break }
        }
        if left >= minSlice, !slices.isEmpty || free >= minSlice {
            notes.append("The rest is not placed: the other protocols are at the \(maxShare)% limit or unavailable. To raise the limit, add “max 70% per protocol” to the request.")
        }
        return Result(slices: slices, leftover: left < minSlice ? 0 : left, notes: notes)
    }
}
