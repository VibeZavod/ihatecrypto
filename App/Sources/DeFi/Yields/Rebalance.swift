import Foundation

/// «Переложи в лучшие ставки»: money already deposited moves toward the best rates, no protocol above `maxShare` of
/// the total, and a move is made only when its extra interest pays back the way out and in (bridges, first-deposit
/// rent, gas) within `paybackDays`. A locked place (HLP's 4 days) keeps its money. Pure, so the rules are tested apart
/// from the chain.
public enum Rebalance {
    public struct Place: Sendable, Equatable {
        public let name: String
        /// % a year.
        public let apy: Decimal
        /// USDC in it now.
        public let amount: Decimal
        /// Dollars it costs to take money out to Solana (a bridge back), and why it can't leave now (a lock), or nil.
        public let exitCost: Decimal
        public let locked: String?
        /// Dollars it costs to put money in (a bridge there, first-deposit rent, gas), and why LALA won't, or nil.
        public let entryCost: Decimal
        public let closed: String?

        public init(name: String, apy: Decimal, amount: Decimal, exitCost: Decimal = 0, locked: String? = nil,
                    entryCost: Decimal = 0, closed: String? = nil) {
            self.name = name; self.apy = apy; self.amount = amount
            self.exitCost = exitCost; self.locked = locked; self.entryCost = entryCost; self.closed = closed
        }
    }

    public struct Move: Sendable, Equatable {
        public let from: String
        public let to: String
        public let amount: Decimal
        public let fromAPY: Decimal
        public let toAPY: Decimal
        /// Dollars: leaving `from` plus entering `to`.
        public let cost: Decimal
        /// Extra interest a year on the moved amount.
        public var yearlyGain: Decimal { amount * (toAPY - fromAPY) / 100 }
        /// Days until the extra interest has paid the cost; nil when it never does.
        public var paybackDays: Decimal? { yearlyGain > 0 ? cost / yearlyGain * 365 : nil }
    }

    public struct Plan: Sendable {
        public let moves: [Move]
        /// Considered and not made, each with the reason (the math when it's the cost).
        public let skipped: [Skip]
        public let notes: [String]
        public var yearlyGain: Decimal { moves.reduce(0) { $0 + $1.yearlyGain } }
        public var cost: Decimal { moves.reduce(0) { $0 + $1.cost } }
    }

    public struct Skip: Sendable, Equatable {
        public let move: Move
        public let reason: String
    }

    /// `minMove`: smaller pieces are not worth a transaction.
    public static func plan(places: [Place], maxShare: Decimal, paybackDays: Decimal = 30, minMove: Decimal = Decimal(string: "0.5")!) -> Plan {
        let total = places.reduce(0) { $0 + $1.amount }
        guard total > 0 else { return Plan(moves: [], skipped: [], notes: ["Nothing is deposited yet: «spread USDC across the best rates» puts free USDC to work."]) }
        let cap = total * maxShare / 100
        var notes: [String] = []
        // Targets: the best rates fill up to the cap first; a locked place keeps what it has, a closed one can only shrink.
        var remaining = total - places.filter { $0.locked != nil }.reduce(0) { $0 + $1.amount }
        var target: [String: Decimal] = [:]
        for p in places.sorted(by: { $0.apy > $1.apy }) {
            if p.locked != nil { target[p.name] = p.amount; continue }
            let t = min(p.closed == nil ? cap : min(cap, p.amount), remaining)
            target[p.name] = t
            remaining -= t
        }
        // What can't be placed under the cap stays in the worst places it is in now: they give up less.
        for p in places.sorted(by: { $0.apy < $1.apy }) where remaining > 0 && p.locked == nil {
            let back = min(remaining, max(0, p.amount - (target[p.name] ?? 0)))
            target[p.name, default: 0] += back
            remaining -= back
        }
        for p in places where p.locked != nil {
            if places.contains(where: { $0.locked == nil && $0.closed == nil && $0.apy > p.apy }) {
                notes.append("\(p.name) keeps \(fmt(p.amount)) USDC: \(p.locked!).")
            }
        }
        // Worst money moves first, into the best places first.
        var excess = places.filter { $0.amount - (target[$0.name] ?? 0) >= minMove / 2 }.sorted { $0.apy < $1.apy }
            .map { ($0, $0.amount - (target[$0.name] ?? 0)) }
        let deficits = places.filter { (target[$0.name] ?? 0) - $0.amount >= minMove / 2 }.sorted { $0.apy > $1.apy }
            .map { ($0, (target[$0.name] ?? 0) - $0.amount) }
        var moves: [Move] = [], skipped: [Skip] = []
        for (to, need) in deficits {
            var left = need
            for i in excess.indices where left > 0 && excess[i].1 > 0 {
                let from = excess[i].0
                let amount = min(left, excess[i].1)
                let move = Move(from: from.name, to: to.name, amount: amount, fromAPY: from.apy, toAPY: to.apy, cost: from.exitCost + to.entryCost)
                excess[i].1 -= amount
                left -= amount
                if amount < minMove {
                    skipped.append(Skip(move: move, reason: "\(fmt(amount)) USDC is too little to move"))
                } else if let days = move.paybackDays, days <= paybackDays {
                    moves.append(move)
                } else {
                    let days = move.paybackDays.map { "\(fmt(up($0))) days" } ?? "never"
                    skipped.append(Skip(move: move, reason: "+$\(fmt(move.yearlyGain)) a year against ≈ $\(fmt(move.cost)) to move: pays back in \(days), more than \(fmt(paybackDays))"))
                }
            }
        }
        if moves.isEmpty, skipped.isEmpty, notes.isEmpty {
            notes.append("Already at the best rates within \(fmt(maxShare))% per protocol: nothing to move.")
        }
        for p in places where p.amount > cap + minMove / 2 && p.locked == nil && !moves.contains(where: { $0.from == p.name }) {
            notes.append("\(p.name) stays above \(fmt(maxShare))% (\(fmt(p.amount)) of \(fmt(total)) USDC): moving the rest out wouldn't pay for itself.")
        }
        return Plan(moves: moves, skipped: skipped, notes: notes)
    }

    static func up(_ d: Decimal) -> Decimal {
        var value = d, result = Decimal()
        NSDecimalRound(&result, &value, 0, .up)
        return result
    }

    static func fmt(_ d: Decimal) -> String {
        d.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US")).grouping(.never))
    }
}
