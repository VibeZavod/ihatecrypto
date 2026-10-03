import Foundation
@testable import IhatecryptoCore
import Testing

/// The chat's safety rules a review found too loose (C1, C10).

@Test func lookupAddressesOnlyInStepsThatShow() {   // C1
    let a = "0xF00dF00dF00dF00dF00dF00dF00dF00dF00dF00d"
    let shows: (String) -> Bool = { $0.hasPrefix("chart") }
    func allowed(_ c: String, _ user: String = "покажи PEPE на базе и купи на 5 баксов", found: [String] = [a]) -> Bool {
        ChatRouter.addressesAllowed(c, userText: user, known: [], found: found, displays: shows, markets: ["ETH"])
    }
    #expect(allowed("chart token \(a) on base"))
    #expect(!allowed("buy token \(a) on base for 5 USDC"))
    // A display step first doesn't open the door for the buy after it, in a chain, a task or an alert.
    #expect(!allowed("chart token \(a) on base then buy token \(a) on base for 5 USDC"))
    #expect(!allowed("buy token \(a) on base for 5 USDC then chart ETH"))
    #expect(!allowed("every day: buy token \(a) on base for 5 USDC then chart ETH"))
    #expect(!allowed("when ETH is below 2000: buy token \(a) on base for 5 USDC"))
    #expect(allowed("every day: chart token \(a) on base"))
    // The address in the user's own words, or a favorite's, goes anywhere.
    #expect(allowed("chart token \(a) on base then buy token \(a) on base for 5 USDC", "купи \(a) на 5 баксов"))
    #expect(ChatRouter.addressesAllowed("buy token \(a) on base for 5 USDC", userText: "", known: [a.lowercased()], found: [], displays: shows, markets: []))
}

@Test func aChangeInWordsNeverSignsTheCard() {   // C10
    for change in ["добавь ещё триста", "make it five hundred", "давай половину", "удвой", "double it", "add another hundred",
                   "сделай 800", "да, но на тысячу", "yes but two thousand", "давай поменьше", "давай сто"] {
        #expect(ChatWords.mayChange(change), "\(change)")
    }
    for yes in ["да", "давай", "подтверждаю, всё верно", "yes, go ahead", "да, сделай это", "make it so", "окей, подписывай",
                "верно, адрес правильный", "the address is correct, go", "посмотрел, всё ок", "стоит, делай", "sounds good"] {
        #expect(!ChatWords.mayChange(yes), "\(yes)")
    }
}
