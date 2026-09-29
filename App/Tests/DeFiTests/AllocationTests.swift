@testable import DeFiYields
import Foundation
import Testing

@Test func bestRatesFirstUnderTheLimitCountingWhatIsAlreadyThere() {
    let places = [
        Allocation.Place(name: "Jupiter Lend", apy: Decimal(string: "5.58")!, existing: 1),
        Allocation.Place(name: "Kamino Lend", apy: Decimal(string: "4.79")!, blocked: "аренда больше 10% суммы"),
        Allocation.Place(name: "Aave", apy: 4),
    ]
    // 3 free + 1 already in Jupiter = 4 in total; 50% cap = 2 per protocol.
    let r = Allocation.plan(free: 3, places: places, maxShare: 50, minSlice: Decimal(string: "0.5")!)
    #expect(r.slices == [Allocation.Slice(place: "Jupiter Lend", amount: 1, apy: Decimal(string: "5.58")!),
                         Allocation.Slice(place: "Aave", amount: 2, apy: 4)])
    #expect(r.leftover == 0 && r.notes.contains { $0.hasPrefix("Kamino Lend") })

    // One usable protocol and a 50% cap: half stays unplaced, and the note says how to change that.
    let alone = Allocation.plan(free: 4, places: [Allocation.Place(name: "Jupiter Lend", apy: 5)], maxShare: 50, minSlice: 1)
    #expect(alone.slices.map(\.amount) == [2] && alone.leftover == 2)
    #expect(alone.yearly == Decimal(string: "0.1")!)
    // Crumbs below the minimum slice are not worth a transaction.
    #expect(Allocation.plan(free: Decimal(string: "0.3")!, places: places, maxShare: 50, minSlice: Decimal(string: "0.5")!).slices.isEmpty)
}

@Test func theLimitIsPerProtocolAcrossNetworks() {
    // Aave on two networks shares one 50% cap: 10 USDC free goes 5 to Aave (both markets together) and 5 elsewhere.
    let plan = Allocation.plan(free: 10, places: [
        .init(name: "Aave · Arbitrum", apy: 6, protocol: "Aave"),
        .init(name: "Aave · Polygon", apy: 5.5, protocol: "Aave"),
        .init(name: "Jupiter Lend", apy: 5),
    ], maxShare: 50, minSlice: Decimal(string: "0.5")!)
    let aave = plan.slices.filter { $0.place.hasPrefix("Aave") }.reduce(Decimal(0)) { $0 + $1.amount }
    #expect(aave == 5)
    #expect(plan.slices.first { $0.place == "Jupiter Lend" }?.amount == 5)
}
