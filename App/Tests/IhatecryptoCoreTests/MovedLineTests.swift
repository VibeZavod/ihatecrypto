import Foundation
import Testing
@testable import IhatecryptoCore

@Test func historyLinesSayWhatMovedAndWhere() {
    let sent = MovedLine("Sent 5 USDT to Automation on Solana. https://solscan.io/tx/4uH2y76CkZcaLF6x22gY2Kqc2iiwhsGcTyGnPNUqKu1rXm7DfWkss7yHhQJfNW4TQYCQZ7qiu73GTrAEHU5MxhFX")
    #expect(sent?.kind == .sent && sent?.text == "Sent 5 USDT to Automation on Solana" && sent?.amount == 5 && sent?.symbol == "USDT")
    #expect(sent?.to == "Automation" && sent?.link?.host == "solscan.io")
    let swap = MovedLine("Swapped 3 USDC → USDT +2.997906.")
    #expect(swap?.kind == .swapped && swap?.text == "Swapped 3 USDC → USDT +2.997906" && swap?.amount == 3 && swap?.symbol == "USDC")
    let came = MovedLine("💸 Received +55.09 USDC on Solana (now 55.09).")
    #expect(came?.kind == .received && came?.text == "Received +55.09 USDC on Solana" && came?.amount == Decimal(string: "55.09"))
    #expect(MovedLine("💸 Пришло +1,250.5 USDC на Solana (сейчас 1,300).")?.amount == Decimal(string: "1250.5"))
    #expect(MovedLine("Moved 1 USDC to Arbitrum: 1 USDC there now. Say “move USDC from Arbitrum to Solana” to bring it back.")?.text == "Moved 1 USDC to Arbitrum")
    // Between the wallet's own networks it's a move, not money leaving.
    #expect(MovedLine("Sent 5 USDT from Arbitrum to Optimism over USDT0: 5 USDT lands there in 2–4 min")?.kind == .moved)
    #expect(MovedLine("Sent 0.25 SOL to Bob on Solana.")?.to == "Bob")
    // Plans, answers and cancellations aren't moves.
    for line in ["USDC → USDT via Jupiter: 3 → ≈ 3.00362, at least 2.988602.", "Cancelled — nothing moved.", "Понял: deposit 1 USDC into Jupiter Lend."] {
        #expect(MovedLine(line) == nil)
    }
    let day = ["Sent 2 USDT to Automation on Solana.", "Sent 10 USDT to Automation on Solana.", "Sent 13 USDT to Automation on Solana.",
               "Swapped 2 USDC → USDT +2.00242.", "💸 Received +1 USDC on Base (now 2.42)."].compactMap(MovedLine.init)
    #expect(MovedLine.summary(day) == ["−25 USDT sent to Automation · 3 sends", "+1 USDC came in", "1 swap, the money stays in the wallet"])
}
