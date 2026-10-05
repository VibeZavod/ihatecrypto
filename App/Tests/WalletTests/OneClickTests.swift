import Foundation
@testable import OneClickKit
import Testing

/// The partner key goes on every 1Click request as X-API-Key, and only when there is one.
@Test func oneClickSendsThePartnerKeyOnlyWhenSet() {
    let url = URL(string: "https://1click.chaindefuser.com/v0/status?depositAddress=x")!
    OneClick.key = nil
    #expect(OneClick.request(url).value(forHTTPHeaderField: "X-API-Key") == nil)
    OneClick.key = "eyJ.test.key"
    #expect(OneClick.request(url).value(forHTTPHeaderField: "X-API-Key") == "eyJ.test.key")
    OneClick.key = ""
    #expect(OneClick.key == nil && OneClick.request(url).value(forHTTPHeaderField: "X-API-Key") == nil)
}

/// Live (IHATECRYPTO_NET=1, a dry quote, no money): 1Click turns a key it doesn't know away with 401, which Settings says in
/// words; without a key the same quote still answers.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IHATECRYPTO_NET"] == "1"))
func oneClickTurnsAnUnknownKeyAway() async throws {
    let why = await OneClick.problem(withKey: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.abc")
    print("bad key:", why ?? "accepted?")
    #expect(why?.contains("turned the key away (401)") == true)
    OneClick.key = nil
    let q = try await OneClick.quote(dry: true, origin: OneClick.Asset.solanaUSDC, destination: OneClick.Asset.near, amount: "5000000",
                                     refundTo: "7WktogJEd2wQ9eH2oWusmcoFTgeYi6rS632UviTBJ2jm", recipient: String(repeating: "ab", count: 32))   // an implicit NEAR account, as the app's
    print("5 USDC → NEAR without a key:", q.amountOutFormatted)
    #expect(Decimal(string: q.amountOutFormatted) ?? 0 > 0)
}
