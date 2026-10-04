import Foundation
import Testing
@testable import IhatecryptoCore

private let sol = SpotAsset.all[0], btc = SpotAsset.all[1], jup = SpotAsset.all[3]

@Test func jupiterDCAReadsTheRouterFormAndPlainWords() {
    #expect(WalletCommand.parse("Jupiter DCA 100 USDC into SOL in 2 orders every day") == .jupiterDCA(sol, usdc: 100, orders: 2, every: 86400))
    #expect(WalletCommand.parse("jupiter dca 300 USDC into BTC over 6 weeks") == .jupiterDCA(btc, usdc: 300, orders: 6, every: 604_800))
    // The swaps spread over the time named.
    #expect(WalletCommand.parse("jupiter dca 200 USDC into SOL in 4 orders over 2 days") == .jupiterDCA(sol, usdc: 200, orders: 4, every: 43200))
    #expect(WalletCommand.parse("jupiter dca 120 USDC into SOL in 2 orders every 3 days") == .jupiterDCA(sol, usdc: 120, orders: 2, every: 259_200))
    // «jupiter» itself is not JUP; JUP named is.
    #expect(WalletCommand.parse("Jupiter DCA 500 USDC into JUP") == .jupiterDCA(jup, usdc: 500, orders: nil, every: 86400))
    #expect(WalletCommand.parse("dca on jupiter into SOL") == .jupiterDCA(sol, usdc: nil, orders: nil, every: 86400))
    #expect(WalletCommand.parse("сделай дса через юпитер на 100 usdc в sol каждую неделю") == .jupiterDCA(sol, usdc: 100, orders: nil, every: 604_800))
    #expect(WalletCommand.parse("Jupiter DCA 100 USDC into BONK in 2 orders every day") == .jupiterDCA(.bySymbol("BONK"), usdc: 100, orders: 2, every: 86400))
    #expect(WalletCommand.parse("cancel Jupiter DCA SOL") == .jupiterDCACancel(sol))
    #expect(WalletCommand.parse("cancel Jupiter DCA") == .jupiterDCACancel(nil))
    #expect(WalletCommand.parse("show Jupiter DCA") == .jupiterDCAOrders)
    // The app's own recurring buys keep their words.
    #expect(WalletCommand.parse("buy SOL for 10 USDC every week") == .schedule(sol, usdc: 10, days: 7))
    #expect(WalletCommand.parse("stop recurring buys") == .stopSchedules)
}

@Test func jupiterDCASummaryReadsBackAndMinimumsHold() {
    for c: WalletCommand in [.jupiterDCA(sol, usdc: 100, orders: 2, every: 86400), .jupiterDCA(btc, usdc: 400, orders: 4, every: 604_800),
                             .jupiterDCA(jup, usdc: 150, orders: nil, every: 3600), .jupiterDCACancel(sol), .jupiterDCACancel(nil), .jupiterDCAOrders] {
        let back = WalletCommand.parse(c.summary)
        if case .jupiterDCA(let a, let u, nil, let e) = c { #expect(back == .jupiterDCA(a, usdc: u, orders: WalletCommand.jupiterDCAOrders(for: u!), every: e)) }
        else { #expect(back == c, "\(c.summary)") }
    }
    #expect(WalletCommand.jupiterDCAOrders(for: 100) == 2 && WalletCommand.jupiterDCAOrders(for: 175) == 3 && WalletCommand.jupiterDCAOrders(for: 5000) == 10)
    #expect(WalletCommand.jupiterDCAProblem(usdc: 100, orders: 2) == nil)
    #expect(WalletCommand.jupiterDCAProblem(usdc: 60, orders: 2)?.contains("at least 100") == true)
    #expect(WalletCommand.jupiterDCAProblem(usdc: 100, orders: 3)?.contains("2 swaps at most") == true)
    #expect(WalletCommand.jupiterDCAProblem(usdc: 200, orders: 1)?.contains("at least 2") == true)
    #expect(WalletCommand.everyText(86400) == "day" && WalletCommand.everyText(172_800) == "2 days" && WalletCommand.everyText(43200) == "12 hours")
    // On like every module until switched off; its own switch stops it.
    #expect(Modules().refusal(.jupiterDCA(sol, usdc: 100, orders: 2, every: 86400)) == nil)
    var off = Modules(); off.set(.jupiterDCA, false)
    #expect(off.refusal(.jupiterDCA(sol, usdc: 100, orders: 2, every: 86400)) != nil && off.refusal(.buy(sol, usdc: 1)) == nil)
}

/// In runCanonical's order (FormsMatrixTests' `read`): no earlier reader — tasks «every day: …», folders, tokens,
/// alerts — takes a Jupiter DCA form first.
@Test func jupiterDCAFormsReachTheWalletReaderFirst() {
    for (every, seconds) in [("day", 86400), ("week", 604_800), ("3 days", 259_200), ("hour", 3600), ("month", 2_592_000)] {
        for asset in SpotAsset.all {
            let c = "Jupiter DCA 300 USDC into \(asset.symbol) in 3 orders every \(every)"
            #expect(read(c) == .wallet(.jupiterDCA(asset, usdc: 300, orders: 3, every: seconds)), "\(c)")
        }
    }
    #expect(read("Jupiter DCA 300 USDC into SOL over 3 weeks") == .wallet(.jupiterDCA(sol, usdc: 300, orders: 3, every: 604_800)))
    #expect(read("cancel Jupiter DCA SOL") == .wallet(.jupiterDCACancel(sol)))
    #expect(read("show Jupiter DCA") == .wallet(.jupiterDCAOrders))
    // A scheduled task can still hold one.
    if case .task(let every, let steps) = read("every month: Jupiter DCA 100 USDC into SOL in 2 orders every day") {
        #expect(every != nil && steps == [.wallet(.jupiterDCA(sol, usdc: 100, orders: 2, every: 86400))])
    } else { Issue.record("not read as a task") }
}
