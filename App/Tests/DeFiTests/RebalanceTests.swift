import Foundation
@testable import DeFiYields
import Testing

// «Переложи в лучшие ставки»: the rules the rebalance card shows.

@Test func rebalanceFillsTheBestRateUpToTheCap() {
    let plan = Rebalance.plan(places: [
        .init(name: "Jupiter Lend", apy: 4, amount: 1000),
        .init(name: "Kamino Lend", apy: 6, amount: 0, entryCost: Decimal(string: "0.5")!),
    ], maxShare: 50)
    #expect(plan.moves == [Rebalance.Move(from: "Jupiter Lend", to: "Kamino Lend", amount: 500, fromAPY: 4, toAPY: 6, cost: Decimal(string: "0.5")!)])
    #expect(plan.yearlyGain == 10)                     // 500 × 2% a year
    #expect(plan.moves[0].paybackDays! < 30)           // 0.5 / 10 × 365 ≈ 18 days
}

@Test func rebalanceSkipsAMoveThatDoesNotPayBack() {
    // 3 USDC two points better earns 6 cents a year; the bridges cost 6 cents: a year to pay back.
    let plan = Rebalance.plan(places: [
        .init(name: "Jupiter Lend", apy: 4, amount: 3),
        .init(name: "Aave · Base", apy: 6, amount: 0, entryCost: Decimal(string: "0.06")!),
    ], maxShare: 100)
    #expect(plan.moves.isEmpty)
    #expect(plan.skipped.count == 1)
    #expect(plan.skipped[0].reason.contains("pays back in 365 days"))
}

@Test func rebalanceLeavesALockedPlaceAlone() {
    let plan = Rebalance.plan(places: [
        .init(name: "HLP (Hyperliquid)", apy: 3, amount: 5, locked: "locked until Oct 1"),
        .init(name: "Jupiter Lend", apy: 6, amount: 0),
    ], maxShare: 100)
    #expect(plan.moves.isEmpty)
    #expect(plan.notes.contains { $0.contains("HLP (Hyperliquid) keeps 5 USDC: locked until Oct 1") })
}

@Test func rebalanceHasNothingToDoAtTheBestRates() {
    let plan = Rebalance.plan(places: [
        .init(name: "Jupiter Lend", apy: 6, amount: 50),
        .init(name: "Kamino Lend", apy: 5, amount: 50),
        .init(name: "Aave · Base", apy: 4, amount: 0),
    ], maxShare: 50)
    #expect(plan.moves.isEmpty && plan.skipped.isEmpty)
    #expect(plan.notes == ["Already at the best rates within 50% per protocol: nothing to move."])
    #expect(Rebalance.plan(places: [], maxShare: 50).notes.first?.contains("Nothing is deposited") == true)
}

@Test func rebalanceKeepsWhatTheCapCannotPlaceWhereItIs() {
    // One better place and a 50% cap: half moves, half stays in the old place instead of going anywhere worse.
    let plan = Rebalance.plan(places: [
        .init(name: "Jupiter Lend", apy: 4, amount: 100),
        .init(name: "Kamino Lend", apy: 6, amount: 0),
        .init(name: "Aave · Base", apy: 3, amount: 0, closed: "not now"),
    ], maxShare: 50)
    #expect(plan.moves.map(\.amount) == [50])
    #expect(plan.moves.first?.to == "Kamino Lend")
}

@Test func rebalanceCapsAaveAcrossNetworksTogether() {
    // 10 USDC in Jupiter Lend; two Aave markets pay more. Together they may take only half.
    let plan = Rebalance.plan(places: [
        .init(name: "Jupiter Lend", apy: 3, amount: 10),
        .init(name: "Aave · Arbitrum", apy: 9, amount: 0, protocol: "Aave"),
        .init(name: "Aave · Polygon", apy: 8, amount: 0, protocol: "Aave"),
    ], maxShare: 50)
    let intoAave = plan.moves.filter { $0.to.hasPrefix("Aave") }.reduce(Decimal(0)) { $0 + $1.amount }
    #expect(intoAave == 5)
}
