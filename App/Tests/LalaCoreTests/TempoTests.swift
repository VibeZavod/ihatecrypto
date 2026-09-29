import Foundation
import Testing
@testable import LalaCore

// A real 402 from CoinGecko's MPP endpoint (2026-09-30): 0.06 USDC on Tempo to Locus's payee.
private let locus = #"Payment id="tLKZnNB4zPmwhEVLFG0tAcnqy81pCHQugJpTRw_w9vk", realm="coingecko.mpp.paywithlocus.com", method="tempo", intent="charge", request="eyJhbW91bnQiOiI2MDAwMCIsImN1cnJlbmN5IjoiMHgyMGMwMDAwMDAwMDAwMDAwMDAwMDAwMDBiOTUzN2QxMWM2MGU4YjUwIiwibWV0aG9kRGV0YWlscyI6eyJjaGFpbklkIjo0MjE3fSwicmVjaXBpZW50IjoiMHgwNjBiMGZCMEJlOWQ5MDU1NzU3N0IzQUVFNDgwNzExMDY3MTQ5RmYwIn0", description="Locus MPP: coingecko/simple-price", expires="2026-09-29T19:32:58.380Z""#
private let before = ISO8601DateFormatter().date(from: "2026-09-29T19:30:00Z")!

/// A challenge with `request` built from this JSON.
private func challenge(_ request: String, extra: String = "") -> String {
    let b64 = Data(request.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return #"Bearer realm="x", Payment id="a1", realm="svc", method="tempo", intent="charge", request="\#(b64)""# + extra
}

@Test func payAndTempoCommandsParse() {
    #expect(WalletCommand.parse(#"pay POST https://a.example/v1/search {"q": "flights MOW"}"#)
            == .pay(method: "POST", url: "https://a.example/v1/search", body: #"{"q": "flights MOW"}"#))
    #expect(WalletCommand.parse("pay https://a.example/price") == .pay(method: "GET", url: "https://a.example/price", body: nil))
    #expect(WalletCommand.parse(#"pay https://a.example/x {"a":1}"#) == .pay(method: "POST", url: "https://a.example/x", body: #"{"a":1}"#))
    #expect(WalletCommand.parse("pay http://a.example/x") == nil)   // https only
    #expect(WalletCommand.parse("move 2 USDC from Solana to Tempo") == .solanaTo("tempo", 2))
    #expect(WalletCommand.parse("переведи 3 USDC из соланы в темпо") == .solanaTo("tempo", 3))
    #expect(WalletCommand.parse("move 2 USDC from Tempo to Solana") == .evmToSolana("tempo", 2))
    #expect(WalletCommand.parse("send 5 USDC to Mom") == .sendTo(name: "Mom", amount: 5))
    let pay = #"pay POST https://coingecko.mpp.paywithlocus.com/coingecko/simple-price {"ids":"bitcoin","vs_currencies":"usd"}"#
    #expect(ChatRouter.planChange(pay, markets: ["BTC"]) == nil && ChatRouter.steps(pay) == nil && ScheduledTask.parse(pay) == nil)
    #expect(ChatRouter.parses(pay, markets: ["BTC"]))
    #expect(WalletCommand.placeName("tempo") == "Tempo")
}

@Test func mppChallengeReadsWhatThePayeeAsks() throws {
    let c = try MPP.challenge(locus, now: before).get()
    #expect(c.amount == 60_000 && c.usdc == Decimal(string: "0.06"))
    #expect(c.payee == "0x060b0fB0Be9d90557577B3AEE480711067149Ff0" && c.memo == nil)
    #expect(c.realm == "coingecko.mpp.paywithlocus.com" && c.purpose == "Locus MPP: coingecko/simple-price" && c.field == "Authorization")
    // An expired quote is never paid.
    #expect((try? MPP.challenge(locus, now: before.addingTimeInterval(600)).get()) == nil)

    // The credential echoes the challenge as sent, with the hash and the payer.
    let header = MPP.credential(c, hash: "0xabc", payer: "0x90f79bf6eb2c4f870365e785982e1f101e93b906")
    #expect(header.hasPrefix("Payment ") && !header.contains("=") && !header.contains("+") && !header.contains("/"))
    let json = try #require(MPP.base64url(String(header.dropFirst(8))).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    let echoed = try #require(json["challenge"] as? [String: String])
    #expect(echoed == ["id": "tLKZnNB4zPmwhEVLFG0tAcnqy81pCHQugJpTRw_w9vk", "realm": "coingecko.mpp.paywithlocus.com", "method": "tempo", "intent": "charge",
                       "request": c.params["request"]!, "description": "Locus MPP: coingecko/simple-price", "expires": "2026-09-29T19:32:58.380Z"])
    #expect(json["payload"] as? [String: String] == ["type": "hash", "hash": "0xabc"])
    #expect(json["source"] as? String == "did:pkh:eip155:4217:0x90f79bf6eb2c4f870365e785982e1f101e93b906")
}

@Test func mppRefusesWhatItCantPay() throws {
    let usdc = #""currency":"0x20c000000000000000000000b9537d11c60e8b50","recipient":"0x060b0fB0Be9d90557577B3AEE480711067149Ff0""#
    func refused(_ request: String, extra: String = "") -> Bool { (try? MPP.challenge(challenge(request, extra: extra)).get()) == nil }
    #expect(!refused(#"{"amount":"1000",\#(usdc)}"#))   // the Bearer scheme beside it is skipped
    #expect(refused(#"{"amount":"0",\#(usdc)}"#))
    #expect(refused(#"{"amount":"1000","currency":"0x20c0000000000000000000000000000000000000","recipient":"0x060b0fB0Be9d90557577B3AEE480711067149Ff0"}"#))
    #expect(refused(#"{"amount":"1000",\#(usdc),"methodDetails":{"chainId":42431}}"#))
    #expect(refused(#"{"amount":"1000",\#(usdc),"methodDetails":{"supportedModes":["pull"]}}"#))
    #expect(!refused(#"{"amount":"1000",\#(usdc),"methodDetails":{"supportedModes":["pull","push"]}}"#))
    #expect(refused(#"{"amount":"1000",\#(usdc),"methodDetails":{"feePayer":true}}"#))
    #expect(refused(#"{"amount":"1000",\#(usdc),"methodDetails":{"splits":[{"recipient":"0x060b0fB0Be9d90557577B3AEE480711067149Ff0","amount":"10"}]}}"#))
    #expect(refused(#"{"amount":"1000",\#(usdc),"methodDetails":{"memo":"0x1234"}}"#))
    let memo = try MPP.challenge(challenge(#"{"amount":"1000",\#(usdc),"methodDetails":{"memo":"0x\#(String(repeating: "ab", count: 32))"}}"#,
                                           extra: #", header="Payment-Authorization""#)).get()
    #expect(memo.memo?.count == 32 && memo.field == "Payment-Authorization")
    #expect((try? MPP.challenge(#"Payment id="a", realm="r", method="stripe", intent="charge", request="e30""#).get()) == nil)
}

@Test func everyMonthOnTheFirst() throws {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
    let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 10, minute: 30))!
    var task = try #require(ScheduledTask.parse("every month on the 1st at 10:00: send 20 USDC to Mom", now: now))
    #expect(task.steps == ["send 20 USDC to Mom"] && task.every == .months(1))
    #expect(task.next == cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 10)))
    #expect(task.advance(now: task.next) && task.next == cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 10)))
    #expect(ScheduledTask.parse("every month on day 15: rebalance USDC", now: now)?.next == cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9)))
    #expect(ScheduledTask.parse("every month on the 31st: rebalance USDC", now: now) == nil)   // not every month has it
}

@Test func tempoIsAModule() {
    #expect(ModuleNetwork(place: "tempo") == .tempo && ModuleNetwork.tempo.logo == "tempo")
    var m = Modules()
    m.set(.tempo, false)
    #expect(m.refusal(.pay(method: "GET", url: "https://a.example", body: nil)) != nil)
    #expect(m.refusal(.solanaTo("tempo", 2)) != nil && m.refusal(.solanaTo("base", 2)) == nil)
    // Payments have their own switch: off, «pay …» is refused while Tempo transfers still go.
    var p = Modules()
    p.set(.mpp, false)
    #expect(p.refusal(.pay(method: "GET", url: "https://a.example", body: nil)) != nil && p.refusal(.solanaTo("tempo", 2)) == nil)
    #expect(ModuleProtocol.mpp.kind == .payments && ModuleProtocol.mpp.networks == [.tempo])
}

@Test func mppDirectoryRanksByName() {
    let fax: [String: Any] = ["id": "agentfax", "name": "agentfax", "description": "Send a fax, priced per page. No API key.", "tags": ["fax"], "categories": ["social"]]
    let gecko: [String: Any] = ["id": "coingecko", "name": "CoinGecko", "description": "Cryptocurrency market data — prices, charts.", "tags": ["crypto", "prices"],
                                "categories": ["data"], "endpoints": [["description": "Simple Price"]]]
    let ids = { (q: String) in MPP.rank([fax, gecko], q).map { $0["id"] as? String ?? "" } }
    #expect(ids("BTC price USD").first == "coingecko" && ids("coingecko") == ["coingecko"] && ids("fax") == ["agentfax"])
    #expect(ids("paid api service").count == 2)   // nothing but service words: everything, unranked
}

// A service's answer on the canvas: Brave's hits as rows wherever they sit, <strong> gone; plain values otherwise.
@Test func serviceAnswerReadsResultsAndValues() {
    let brave = #"{"success":true,"data":{"type":"search","query":{"original":"memorycowmoo"},"web":{"results":[{"title":"<strong>Memory</strong> cow Moo","url":"https://x.com/memorycowmoo","description":"Moo &amp; more"},{"title":"Second","url":"https://example.com/2"}]}}}"#
    let a = MPP.Answer(Data(brave.utf8))
    #expect(a.items == [.init(title: "Memory cow Moo", url: "https://x.com/memorycowmoo", detail: "Moo & more"), .init(title: "Second", url: "https://example.com/2", detail: nil)])
    let price = MPP.Answer(Data(#"{"bitcoin":{"usd":83570.5}}"#.utf8))
    #expect(price.items.isEmpty && price.facts == [.init(key: "bitcoin.usd", value: "83570.5")])
    #expect(MPP.Answer(Data("queued".utf8)).text == "queued")
    #expect(MPP.Answer(Data(#"{"images":[{"url":"https://cdn.example/a.png","width":1024}]}"#.utf8)).items.first?.isImage == true)
}
