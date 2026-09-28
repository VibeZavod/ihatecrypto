import Foundation
@testable import LalaCore
import LLMCore
import Testing

// The chat as an agent: the model looks things up, then answers with a block to show and cards to go on.

@Test func agentStepsReadLeniently() throws {
    #expect(try ChatRouter.step(Data(#"{"route":"lookup","lookups":[{"tool":"Token","arg":" B5AN "},{"tool":"portfolio"}]}"#.utf8))
            == .lookups([.init("token", "B5AN"), .init("portfolio")]))
    let done = try ChatRouter.step(Data(#"""
    {"route":"chat","reply":"Горячий мемкоин.","show":"chart token B5AN on solana",
     "options":[{"title":"Следить","comment":"цена в избранном","command":"watch token B5AN on solana","recommended":"true"},
                {"title":"","command":"chart ETH"},{"title":"No command"},{"title":"Rates","command":"where to keep USDC"}]}
    """#.utf8))
    guard case .done(let r) = done else { Issue.record("not an answer"); return }
    #expect(r.route == .chat("Горячий мемкоин."))
    #expect(r.show == "chart token B5AN on solana")
    #expect(r.options == [.init(title: "Следить", comment: "цена в избранном", command: "watch token B5AN on solana", recommended: true),
                          .init(title: "Rates", comment: "", command: "where to keep USDC")])
    #expect(throws: (any Error).self) { try ChatRouter.step(Data(#"{"route":"lookup","lookups":[]}"#.utf8)) }
    // A chart offered as a card opens with the answer.
    let promoted = try ChatRouter.step(Data(#"{"route":"chat","reply":"Hot.","options":[{"title":"Watch","command":"watch token B5AN"},{"title":"Chart","command":"chart token B5AN on solana"}]}"#.utf8))
    #expect(promoted == .done(ChatRouter.Reading(route: .chat("Hot."), show: "chart token B5AN on solana",
                                                 options: [.init(title: "Watch", comment: "", command: "watch token B5AN")])))
}

@Test func onlyTheFirstObjectOfAReplyCounts() {
    let reply = #"{"route":"lookup","lookups":[{"tool":"token","arg":"a{b}"}]}{"route":"chat","reply":"a guess"}"#
    #expect(ChatRouter.firstObject(in: "ok: " + reply) == #"{"route":"lookup","lookups":[{"tool":"token","arg":"a{b}"}]}"#)
    #expect(ChatRouter.firstObject(in: "no json") == nil)
}

/// A scripted model: its replies in order, and what it was sent.
private final class Script: LLMClient, @unchecked Sendable {
    var replies: [String]
    var sent: [[LLMMessage]] = []
    init(_ replies: [String]) { self.replies = replies }
    func complete(_ request: LLMRequest) async throws -> String {
        sent.append(request.messages)
        return replies.removeFirst()
    }
}

@Test func theAgentLooksUpThenAnswers() async throws {
    let model = Script([
        #"{"route":"lookup","lookups":[{"tool":"token","arg":"2FB5"}]}"#,
        #"{"route":"chat","reply":"POKEMON, hot.","show":"chart token B5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6 on solana"}"#,
    ])
    let reading = try await ChatRouter.route("расскажи про токен 2FB5", context: .init(), client: model, model: "m") { l in
        "Result for \(l.tool): mint B5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6"
    }
    #expect(reading.route == .chat("POKEMON, hot."))
    #expect(reading.lookups == [.init("token", "2FB5")])
    #expect(reading.found == ["B5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6"])
    // The second call carries the model's lookup and its result.
    #expect(model.sent[1].count == 4)
    #expect(model.sent[1][3].text.contains("mint B5AN"))
}

@Test func theAgentStopsLookingAfterItsRounds() async {
    let model = Script(Array(repeating: #"{"route":"lookup","lookups":[{"tool":"portfolio"}]}"#, count: ChatRouter.rounds + 1))
    await #expect(throws: (any Error).self) { try await ChatRouter.route("?", context: .init(), client: model, model: "m") }
    #expect(model.sent.last?.last?.text.contains("No more lookups") == true)
}

@Test func tokenCardsAndWatchingParse() {
    let mint = "B5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6"
    #expect(TokenCommand.parse("chart token \(mint) on solana") == .show(address: mint, chain: "solana"))
    #expect(TokenCommand.parse("show token 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18 on robinhood")
            == .show(address: "0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18", chain: "robinhood"))
    #expect(TokenCommand.parse("watch token \(mint) on solana") == .favorite(address: mint, chain: "solana"))
    #expect(ChatRouter.forms.contains("chart token <CONTRACT or MINT> on"))
    #expect(ChatRouter.parses("chart token \(mint) on solana", markets: []))
    #expect(ChatRouter.parses("lend 5 USDC", markets: []))
    #expect(!ChatRouter.parses("write me a trading bot", markets: []))
}

@Test func aMintCopiedFromALinkIsRepaired() {
    // «%2F» of a link copied along with the mint.
    #expect(TokenResearch.repairs("2FB5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6").first == "B5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6")
    #expect(TokenResearch.repairs("B5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6") == ["B5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6"])
    #expect(TokenResearch.repairs("tooshort").isEmpty)
}

@Test func jupiterFactsSayWhatMatters() throws {
    let mint = "B5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6"
    let json = """
    [{"id": "\(mint)", "name": "POKÉMON CARDS", "symbol": "POKEMON", "usdPrice": 0.00036, "mcap": 360198, "fdv": 360198, "liquidity": 43138,
      "holderCount": 1359, "launchpad": "stonkfun", "createdAt": "2026-09-06T04:36:17Z", "graduatedAt": "2026-09-06T04:46:19Z",
      "stats1h": {"priceChange": 158.9}, "stats24h": {"priceChange": 88.2, "buyVolume": 101421, "sellVolume": 89812, "buyOrganicVolume": 7626,
      "sellOrganicVolume": 11995, "numBuys": 681, "numSells": 460, "numTraders": 266},
      "audit": {"mintAuthorityDisabled": true, "freezeAuthorityDisabled": false, "topHoldersPercentage": 21.19, "devBalancePercentage": 1.5},
      "organicScoreLabel": "low", "tags": ["unknown", "token-2022"]}]
    """
    let now = ISO8601DateFormatter().date(from: "2026-09-29T04:36:17Z")!
    let facts = try #require(TokenResearch.jupiterFacts(Data(json.utf8), mint: mint, now: now))
    #expect(facts.contains("POKÉMON CARDS (POKEMON), mint \(mint), chain id solana"))
    #expect(facts.contains("not verified"))
    #expect(facts.contains("1h +158.9%"))
    #expect(facts.contains("organic (real users, not bots) $19.6K"))
    #expect(facts.contains("Created 23 days ago on the stonkfun launchpad"))
    #expect(facts.contains("mint authority off"))
    #expect(facts.contains("FREEZE AUTHORITY ON"))
    #expect(TokenResearch.jupiterFacts(Data(json.utf8), mint: "other", now: now) == nil)
}

@Test func aSearchPutsTheDeepestPoolFirst() throws {
    let json = """
    {"pairs": [
      {"chainId": "base", "baseToken": {"address": "0xfake", "symbol": "BONK", "name": "Bonk"}, "priceUsd": "0.1", "liquidity": {"usd": 5000}},
      {"chainId": "solana", "baseToken": {"address": "DezX", "symbol": "Bonk", "name": "Bonk"}, "priceUsd": "0.00002", "liquidity": {"usd": 400000},
       "priceChange": {"h24": -3.2}},
      {"chainId": "solana", "baseToken": {"address": "DezX", "symbol": "Bonk", "name": "Bonk"}, "priceUsd": "0.00002", "liquidity": {"usd": 90000}}
    ]}
    """
    let (facts, top) = try #require(TokenResearch.searchFacts(Data(json.utf8), query: "BONK"))
    #expect(top == "DezX")
    let lines = facts.components(separatedBy: "\n")
    #expect(lines.count == 3)
    #expect(lines[1].hasPrefix("Bonk (Bonk) on chain id solana, contract DezX"))
    #expect(lines[1].contains("liquidity $400K, 24h -3.2%"))
    #expect(lines[2].contains("0xfake"))
}

@Test func anySolanaTokenByItsMint() {
    let mint = "B5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6"
    #expect(WalletCommand.parse("buy token \(mint) for 2 USDC") == .buy(.byMint(mint), usdc: 2))
    #expect(WalletCommand.parse("купи \(mint) на $3") == .buy(.byMint(mint), usdc: 3))
    #expect(WalletCommand.parse("sell 1500 tokens \(mint)") == .sell(.byMint(mint), amount: 1500))
    #expect(WalletCommand.parse("sell tokens \(mint)") == .sell(.byMint(mint), amount: nil))
    #expect(!SpotAsset.byMint(mint).resolved && !SpotAsset.byMint(mint).verified)
    // The fixed coins stay what they were.
    #expect(WalletCommand.parse("buy SOL for 2 USDC") == .buy(SpotAsset.all[0], usdc: 2))
    #expect(WalletCommand.parse("buy token \(SpotAsset.all[3].mint) for 2 USDC") != .buy(.byMint(SpotAsset.all[3].mint), usdc: 2))
    #expect(ChatRouter.forms.contains("buy token <MINT> for N USDC"))
}

@Test func buyingByMintKnowsItsRisks() throws {
    let mint = "B5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6"
    let json = """
    [{"id": "\(mint)", "name": "POKÉMON CARDS", "symbol": "POKEMON", "decimals": 6, "tokenProgram": "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",
      "liquidity": 43138, "audit": {"mintAuthorityDisabled": true, "freezeAuthorityDisabled": false}, "tags": ["unknown"]}]
    """
    let t = try #require(TokenResearch.solanaToken(Data(json.utf8), mint: mint))
    #expect(t.decimals == 6 && t.token2022 && !t.verified)
    #expect(t.warnings().first?.contains("freeze") == true)
    #expect(t.warnings().contains { $0.contains("thin") })
    #expect(!t.warnings().contains { $0.contains("print") })
    #expect(t.warnings(russian: true).first?.hasPrefix("создатель может заморозить") == true)
    #expect(t.warnings(russian: true).count == t.warnings().count)
}

@Test func aPastedAddressIsLookedUpBeforeTheModelReads() async throws {
    #expect(ChatRouter.pastedAddress("расскажи про 2FB5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6") == "2FB5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6")
    #expect(ChatRouter.pastedAddress("купи 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18 на $2") == "0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18")
    #expect(ChatRouter.pastedAddress("what is the difference between staking and lending") == nil)
    let model = Script([#"{"route":"chat","reply":"POKEMON, hot."}"#])
    let reading = try await ChatRouter.route("что за токен B5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6", context: .init(), client: model, model: "m") { l in
        "facts about \(l.arg)"
    }
    #expect(reading.lookups == [.init("token", "B5ANwoWkptDv1QszdPHXjCF2gTWdo27FGLffdfXzzoe6")])
    #expect(model.sent.count == 1)
    #expect(model.sent[0][1].text.contains("Already looked up for you — token B5AN"))
}
