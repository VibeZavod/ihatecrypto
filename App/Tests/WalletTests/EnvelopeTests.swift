import ExecutionCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func d(_ s: String) -> Decimal { Decimal(string: s)! }

@Test func liveValuesInsideTheEnvelopePass() {
    let e = Envelope.approve(input: d("0.13"), quotedOutput: d("14.85"), now: now)
    #expect(e.minOutput == d("14.7015"))
    #expect(e.violations(input: d("0.13"), output: d("14.80"), now: now.addingTimeInterval(30)).isEmpty)
}

@Test func anythingOutsideTheEnvelopeStopsTheRoute() {
    var e = Envelope.approve(input: d("0.13"), quotedOutput: d("14.85"), now: now)
    #expect(e.violations(input: d("0.13"), output: d("14.5"), now: now).count == 1)       // price moved too far
    #expect(e.violations(input: d("0.14"), output: d("14.85"), now: now).count == 1)      // more would leave the wallet
    #expect(e.violations(input: d("0.13"), output: d("14.85"), now: now.addingTimeInterval(601)).count == 1) // expired
    e.destination = "DepositA"
    #expect(e.violations(input: d("0.13"), output: d("14.85"), destination: "DepositB", now: now).count == 1)
    #expect(e.violations(input: d("0.13"), output: d("14.85"), destination: "DepositA", now: now).isEmpty)
}
