@testable import IhatecryptoCore
import Testing

@Test func everythingIsOnUntilSwitchedOff() {
    let m = Modules()
    #expect(ModuleProtocol.allCases.allSatisfy(m.allows))
    #expect(m.offSummary.isEmpty)
    #expect(m.refusal(.kamino(deposit: true, symbol: "USDC", amount: 1)) == nil)
}

@Test func aSwitchOffStopsItsMovesAndSurvivesStorage() {
    var m = Modules()
    m.set(.kamino, false)
    m.set(.base, false)
    m = Modules(stored: m.stored)
    #expect(m.refusal(.kamino(deposit: true, symbol: "USDC", amount: 1)) == "Kamino is off in Settings › Modules.")
    // Aave needs Base; Jupiter Lend doesn't.
    #expect(m.refusal(.aave(deposit: true, amount: 1)) == "Base is off in Settings › Modules.")
    #expect(m.refusal(.lendDeposit("USDC", 1)) == nil)
    #expect(m.refusal(.solanaTo("base", 1)) != nil)
    #expect(m.refusal(.solanaTo("arbitrum", 1)) == nil)
    #expect(m.refusal(vault: "Kamino Lend") != nil)
    #expect(m.refusal(vault: "Jupiter Lend") == nil)
}

@Test func aKindOffTakesItsProtocolsWithIt() {
    var m = Modules()
    m.set(.perps, false)
    #expect(m.refusal(trade: false, bridges: false) == "Perps is off in Settings › Modules, so Hyperliquid is too.")
    #expect(m.refusal(trade: true, bridges: false) == nil)   // oil and stocks are their own kind
    m.set(.earn, false)
    #expect(m.refusal(.allocate("USDC", maxShare: nil)) != nil)
    #expect(m.refusal(.stake(1)) != nil)
    #expect(m.refusal(.buy(.usdc, usdc: 1)) == nil)
    // A Russian reply for a Russian chat.
    #expect(m.refusal(.stake(1), ru: true)?.contains("выключены") == true)
}

@Test func vaultsOnEveryNetworkFollowTheirNetworksSwitch() {
    var m = Modules()
    #expect(m.refusal(vault: "Aave · Polygon") == nil)
    #expect(m.refusal(vault: "Morpho · Ethereum") == nil)
    m.set(.polygon, false)
    #expect(m.refusal(vault: "Aave · Polygon") != nil)
    #expect(m.refusal(vault: "Aave · Arbitrum") == nil)
    m.set(.aave, false)
    #expect(m.refusal(vault: "Aave · Arbitrum") != nil)
    // A place no switch covers is refused, not waved through.
    #expect(Modules().refusal(vault: "Aave · BNB") != nil)
    #expect(Modules().refusal(vault: "Somewhere") != nil)
    #expect(ModuleNetwork(place: "polygon") == .polygon && ModuleNetwork(place: "ethereum") == .ethereum)
}
