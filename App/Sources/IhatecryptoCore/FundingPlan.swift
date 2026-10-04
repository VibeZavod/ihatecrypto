import Foundation

/// Where the USDC a move needs comes from when the place it's spent on hasn't it and the user named no source: the free
/// money across the portfolio, one leg a place, best first — Solana, the EVM networks (in the order given, Ethereum
/// last), Hyperliquid's withdrawable, NEAR sold for USDC. Hyperliquid's and NEAR's money lands on Solana and crosses to
/// an EVM target in one leg with Solana's own. Each leg takes a dollar more for Relay's or 1Click's fee. The legs are the
/// chat's own command forms, run as a chain that waits for each arrival (Workspace.runSteps).
public enum FundingPlan {
    public struct Place: Sendable {
        public let key: String
        public let name: String
        public let usdc: Decimal
        public init(key: String, name: String, usdc: Decimal) { (self.key, self.name, self.usdc) = (key, name, usdc) }
    }

    static let fee: Decimal = 1
    /// Less than this isn't worth a leg: Relay's minimum and its fee would eat it.
    static let floor: Decimal = 2
    /// NEAR left on the account for its storage and fees.
    static let nearReserve = Decimal(string: "0.05")!

    /// The legs bringing `short` USDC to `target` («solana» or an EVM network's key); nil when all the free money together
    /// isn't enough — the move's own check says what's missing.
    public static func legs(short: Decimal, target: String, targetName: String, solana: Decimal, evm: [Place],
                            hyperliquid: Decimal, near: Decimal, nearPrice: Decimal?) -> [String]? {
        guard short > 0 else { return [] }
        let toSolana = target == "solana"
        var direct: [String] = [], intoSolana: [String] = []
        var own: Decimal = 0, landed: Decimal = 0, delivered: Decimal = 0
        func amount(_ d: Decimal) -> String { NSDecimalNumber(decimal: d).stringValue }
        func need() -> Decimal { short - delivered - (toSolana ? landed : max(own + landed - fee, 0)) }
        // A first leg into the Solana pool also pays the one Solana → target leg's fee.
        func poolFee() -> Decimal { !toSolana && own + landed == 0 ? fee : 0 }
        // What a place gives: the cents wanted rounded up, or all it has (to the cent below) when that's less — rounding
        // every leg down left a buy a cent short and no plan at all.
        func take(_ have: Decimal, _ want: Decimal) -> Decimal { let w = want.rounded(2, .up); return w <= have ? w : have.rounded(2, .down) }

        if !toSolana, solana >= Decimal(string: "0.5")!, need() > 0 { own = take(solana, need() + fee) }
        for p in evm where p.key != target && need() > 0 && p.usdc >= floor {
            let x = take(p.usdc, need() + fee)
            if toSolana {
                intoSolana.append("move \(amount(x)) USDC from \(p.name) to Solana")
                landed += x - fee
            } else {
                direct.append("move \(amount(x)) USDC from \(p.name) to \(targetName)")
                delivered += x - fee
            }
        }
        if need() > 0, hyperliquid >= floor {
            let x = take(hyperliquid, need() + fee + poolFee())
            intoSolana.append("withdraw \(amount(x)) USDC to Solana")
            landed += x - fee
        }
        if need() > 0, let price = nearPrice, price > 0, near - nearReserve > 0, (near - nearReserve) * price >= floor {
            let usd = need() + fee + poolFee()
            let coins = min(near - nearReserve, (usd / price * Decimal(string: "1.02")!).rounded(4, .up))
            intoSolana.append("sell \(NSDecimalNumber(decimal: coins).stringValue) NEAR")
            landed += coins * price - fee
        }
        guard need() <= 0 else { return nil }
        let crossing = own + landed
        return direct + intoSolana + (toSolana || crossing <= 0 ? [] : ["move \(amount(crossing)) USDC from Solana to \(targetName)"])
    }
}
