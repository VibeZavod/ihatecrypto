import EVMChain
import ExecutionCore
import Foundation
import LalaCore
import RelayBridge
import SolanaChain
import TxGuard
import WalletCore

/// An EVM network LALA moves USDC on: where to read it, where Relay reaches it, how much gas to keep there.
public struct EVMNetwork: Sendable {
    public let name: String
    /// The journal's chain name.
    public let key: String
    public let rpc: EVMRPC
    public let usdc: String
    public let relayChain: UInt64
    public let explorer: String
    /// ETH to keep for several transactions; below it a bridge brings a top-up along.
    public let gasFloor: UInt64
    /// What the top-up is worth in USD (it must land above the floor).
    public let topupUSD: Decimal
    /// The coin gas is paid in.
    public var gasCoin = "ETH"
    /// A network with no coin of its own (Tempo): fees come out of this stablecoin, so there's no gas to bring.
    public var feeToken: String?

    public static let base = EVMNetwork(name: "Base", key: "base", rpc: .base, usdc: EVMRPC.baseUSDC, relayChain: Relay.Chain.base,
                                        explorer: "https://basescan.org", gasFloor: 5_000_000_000_000, topupUSD: Decimal(string: "0.03")!)
    /// Gas on Arbitrum costs a few times Base's (its L1 data share): a larger floor and top-up.
    public static let arbitrum = EVMNetwork(name: "Arbitrum", key: "arbitrum", rpc: .arbitrum, usdc: EVMRPC.arbitrumUSDC, relayChain: Relay.Chain.arbitrum,
                                            explorer: "https://arbiscan.io", gasFloor: 10_000_000_000_000, topupUSD: Decimal(string: "0.05")!)

    /// Robinhood Chain: its dollar is USDG (Relay delivers it; Stock Tokens trade against it on Uniswap).
    public static let robinhood = EVMNetwork(name: "Robinhood Chain", key: "robinhood", rpc: .robinhood, usdc: EVMRPC.robinhoodUSDG,
                                             relayChain: Relay.Chain.robinhood, explorer: "https://robinhoodchain.blockscout.com",
                                             gasFloor: 15_000_000_000_000, topupUSD: Decimal(string: "0.08")!)

    /// Polygon's gas is POL at ≈ $0.12: 0.3 POL covers several calls at today's 274 gwei, and a $0.06 top-up lands above it.
    public static let polygon = EVMNetwork(name: "Polygon", key: "polygon", rpc: .polygon, usdc: EVMRPC.polygonUSDC, relayChain: Relay.Chain.polygon,
                                           explorer: "https://polygonscan.com", gasFloor: 300_000_000_000_000_000,
                                           topupUSD: Decimal(string: "0.06")!, gasCoin: "POL")
    /// Ethereum: an Aave supply is ≈ 250k gas, $0.50 at 0.74 gwei (2026-09-29); the floor covers a supply and a
    /// withdraw at twice that, and a $2.50 top-up lands above it.
    // ponytail: fixed floor; derive it from eth_gasPrice if mainnet fees jump past ≈ 2 gwei.
    public static let ethereum = EVMNetwork(name: "Ethereum", key: "ethereum", rpc: .ethereum, usdc: EVMRPC.ethereumUSDC, relayChain: Relay.Chain.ethereum,
                                            explorer: "https://etherscan.io", gasFloor: 800_000_000_000_000, topupUSD: Decimal(string: "2.5")!)

    /// Tempo: fees in USDC itself (≈ $0.001 a call at 0.6 gwei-attodollars, 2026-09-30); a transfer is the only thing
    /// ihatecrypto does there besides the bridge — to a saved address, or to pay a service (MPP).
    public static let tempo = EVMNetwork(name: "Tempo", key: "tempo", rpc: .tempo, usdc: EVMRPC.tempoUSDC, relayChain: Relay.Chain.tempo,
                                         explorer: "https://explore.tempo.xyz", gasFloor: 0, topupUSD: 0, gasCoin: "USDC",
                                         feeToken: EVMRPC.tempoUSDC)

    public static let all = [base, arbitrum, robinhood, polygon, ethereum, tempo]

    /// What to leave for fees when everything goes: a cent pays ten Tempo calls.
    // ponytail: fixed cent; read the base fee if Tempo's fees ever pass $0.001 a call.
    var feeReserve: UInt64 { feeToken == nil ? 0 : 10_000 }

    /// nil for a network LALA doesn't move money on: never guessed.
    public static func of(chainId: UInt64) -> EVMNetwork? { all.first { $0.rpc.chainId == chainId } }
    public static func named(_ key: String) -> EVMNetwork? { all.first { $0.key == key } }
}

/// Aave v3 on any network LALA knows: USDC in and out. USDC missing there comes from Solana over Relay, with a little
/// of the network's gas coin; a withdrawal goes back to Solana.
extension Executor {
    static var baseGasFloorForPlan: UInt64 { EVMNetwork.base.gasFloor }

    public func aave(deposit: Bool, usdc requested: Decimal?, market m: AaveV3.Market = AaveV3.base) async throws -> String {
        guard let net = EVMNetwork.named(m.chain) else { throw ExecutionError("ihatecrypto doesn't move money on \(m.chainName). Nothing was signed.") }
        let rpc = m.rpc
        // Pool and aToken are re-read from the market's own network before anything is signed.
        let apy = try await AaveV3.verify(m)
        let usdc = m.usdc, pool = m.pool, me = wallet.evm
        func units(_ d: Decimal) -> UInt64 { NSDecimalNumber(decimal: (d * 1_000_000).rounded(0, .down)).uint64Value }
        func show(_ u: UInt64) -> String { Fmt.num(Decimal(u) / 1_000_000, maxFraction: 6) }

        guard deposit else {
            let supplied = try await rpc.tokenBalance(m.aUSDC, owner: me)
            guard supplied > 0 else { throw ExecutionError("Nothing is supplied to Aave on \(m.chainName).") }
            // nil = everything, interest included.
            let amount = requested.map(units).flatMap { $0 < supplied ? $0 : nil }
            try await ensureEVM(net, usdc: 0)
            let before = try await rpc.tokenBalance(usdc, owner: me)
            _ = try await sendEVM(rpc, to: pool, data: try AaveV3.withdraw(asset: usdc, amount: amount, to: me),
                                  note: "Aave withdraw \(amount.map(show) ?? "all") USDC on \(m.chainName)")
            var there = try await rpc.tokenBalance(usdc, owner: me)
            for _ in 0..<10 where there <= before {
                try await Task.sleep(for: .seconds(1))
                there = try await rpc.tokenBalance(usdc, owner: me)
            }
            // Back where the money lives: Solana.
            return try await evmToSolana(net, usdc: nil)
        }

        guard let requested, requested > 0 else { throw ExecutionError("Say how much, e.g. “lend 2 USDC on Aave”.") }
        let want = units(requested)
        try await ensureEVM(net, usdc: want)
        try await approve(rpc, token: usdc, spender: pool, amount: want, note: "Approve exactly \(show(want)) USDC to Aave on \(m.chainName)")
        let before = try await rpc.tokenBalance(m.aUSDC, owner: me)
        let hash = try await sendEVM(rpc, to: pool, data: try AaveV3.supply(asset: usdc, amount: want, onBehalfOf: me),
                                     note: "Aave supply \(show(want)) USDC on \(m.chainName)")
        // A node can answer from a block before the receipt's for a moment: give it up to ten seconds.
        var after = try await rpc.tokenBalance(m.aUSDC, owner: me)
        for _ in 0..<10 where after <= before {
            try await Task.sleep(for: .seconds(1))
            after = try await rpc.tokenBalance(m.aUSDC, owner: me)
        }
        guard after > before else { throw ExecutionError("The supply went through but aUSDC didn't grow. \(net.explorer)/tx/\(hash)") }
        return "Supplied \(show(want)) USDC to Aave on \(m.chainName) at ≈ \(Fmt.num(apy.rounded(2, .plain)))% a year: \(show(after)) USDC there now. \(net.explorer)/tx/\(hash)"
    }

    func ensureBase(usdc want: UInt64) async throws { try await ensureEVM(.base, usdc: want) }

    /// At least `want` USDC and some ETH for gas on the network: what is missing comes from Solana over Relay.
    /// `gas`: a floor and a top-up for calls heavier than a supply (a Morpho vault deposit is ≈ 450k gas);
    /// the top-up must land above the floor, or the wait below runs out.
    func ensureEVM(_ net: EVMNetwork, usdc want: UInt64, gas heavier: (floor: UInt64, topupUSD: Decimal)? = nil) async throws {
        let me = wallet.evm
        func show(_ u: UInt64) -> String { Fmt.num(Decimal(u) / 1_000_000, maxFraction: 6) }
        let floor = max(net.gasFloor, heavier?.floor ?? 0), topupUSD = max(net.topupUSD, heavier?.topupUSD ?? 0)
        // Where fees come out of the stablecoin, the fees ride on the USDC wanted and there's no coin to read.
        let want = want + net.feeReserve
        func gasThere() async throws -> UInt64 { net.feeToken == nil ? try await net.rpc.balance(me) : floor }
        var there = try await net.rpc.tokenBalance(net.usdc, owner: me)
        var gas = try await gasThere()
        guard there < want || gas < floor else { return }
        let short = Decimal(want > there ? want - there : 0) / 1_000_000
        let needGas = gas < floor
        // Relay has minimums: a gas top-up rides on at least half a dollar of USDC.
        let arrive = max(short, needGas ? Decimal(string: "0.5")! : 0)
        let (step, changes) = try await prepareBridge(.arrive(arrive), to: net.relayChain, currency: net.usdc, decimals: 6,
                                                      topupGasUSD: needGas ? topupUSD : nil)
        let stable = net.key == "robinhood" ? "USDG" : "USDC"
        report("Bridge to \(net.name): \(Fmt.num(step.spend)) USDC from Solana → \(Fmt.num(step.arriving)) \(stable)\(needGas ? " plus \(net.gasCoin) for gas" : ""). "
               + changes.joined(separator: " "))
        try await sendBridge(step)
        let started = Date()
        while there < want || gas < floor {
            guard Date().timeIntervalSince(started) < 240 else {
                throw ExecutionError("The USDC didn't reach \(net.name) within 4 minutes. Relay order \(step.requestId) is in the journal; nothing else was signed.")
            }
            try await Task.sleep(for: .seconds(2))
            there = try await net.rpc.tokenBalance(net.usdc, owner: me)
            gas = try await gasThere()
        }
        report("On \(net.name) in \(Int(Date().timeIntervalSince(started))) s: \(show(there)) \(stable) and gas.")
    }

    /// USDC on Base → our Solana address over Relay. Relay's two transactions (an exact approve and the deposit into its
    /// depository) are checked field by field before signing: the depository is the one Relay publishes, the depositor
    /// is us, the token is USDC, the amount is the quote's, the recipient our Solana address. nil = everything on Base.
    public func baseToSolana(usdc requested: Decimal?) async throws -> String { try await evmToSolana(.base, usdc: requested) }

    /// USDC from Solana to our own address on Base, Arbitrum or Robinhood Chain (USDG there) over Relay, with a little
    /// ETH for gas when there is none. `usdc` is what arrives.
    public func solanaToEVM(_ net: EVMNetwork, usdc: Decimal) async throws -> String {
        let units = NSDecimalNumber(decimal: (usdc * 1_000_000).rounded(0, .down)).uint64Value
        guard units >= 500_000 else { throw ExecutionError("At least 0.5 USDC: less isn't worth the bridge.") }
        let stable = net.key == "robinhood" ? "USDG" : "USDC"
        let before = try await net.rpc.tokenBalance(net.usdc, owner: wallet.evm)
        try await ensureEVM(net, usdc: before + units)
        let after = try await net.rpc.tokenBalance(net.usdc, owner: wallet.evm)
        return "Moved \(Fmt.num(Decimal(after > before ? after - before : 0) / 1_000_000)) \(stable) to \(net.name): \(Fmt.num(Decimal(after) / 1_000_000)) \(stable) there now. "
            + "Say “move \(stable) from \(net.name) to Solana” to bring it back."
    }

    /// The same from any EVM network LALA knows (Base, Arbitrum).
    public func evmToSolana(_ net: EVMNetwork, usdc requested: Decimal?) async throws -> String { try await bridge(net, to: nil, usdc: requested) }

    /// USDC from one EVM network straight to another at our own address (Base → Robinhood Chain arrives as USDG there),
    /// or to Solana when `dest` is nil — over Relay, the same two checked transactions either way. A destination with a
    /// gas coin and none of it gets a little along. nil `usdc` = everything on `net`.
    public func bridge(_ net: EVMNetwork, to dest: EVMNetwork?, usdc requested: Decimal?) async throws -> String {
        let base = net.rpc, usdc = net.usdc, me = wallet.evm, chain = net.relayChain
        func show(_ u: UInt64) -> String { Fmt.num(Decimal(u) / 1_000_000, maxFraction: 6) }
        guard dest?.key != net.key else { throw ExecutionError("The money is already on \(net.name).") }
        let there = dest?.name ?? "Solana", stable = dest?.key == "robinhood" ? "USDG" : "USDC"
        let have = try await base.tokenBalance(usdc, owner: me)
        // On Tempo the fees come out of this USDC: a cent of it stays.
        let spendable = have > net.feeReserve ? have - net.feeReserve : 0
        let amount = requested.map { min(NSDecimalNumber(decimal: ($0 * 1_000_000).rounded(0, .down)).uint64Value, spendable) } ?? spendable
        guard amount >= 500_000 else { throw ExecutionError("\(show(have)) USDC on \(net.name) — below the half-dollar a bridge is worth.") }
        // Gas for what comes next there (a buy on Robinhood Chain), when the destination has a gas coin and too little of it.
        var topup: Decimal?
        if let dest, dest.feeToken == nil, try await dest.rpc.balance(me) < dest.gasFloor { topup = dest.topupUSD }

        let recipient = dest == nil ? wallet.solana : me
        let quote = try await Relay.quote(user: me, recipient: recipient, originChain: chain, destinationChain: dest?.relayChain ?? Relay.Chain.solana,
                                          originCurrency: usdc, destinationCurrency: dest?.usdc ?? Relay.Currency.solanaUSDC, amount: amount,
                                          topupGasUSD: topup)
        let binding = BindingGuard.check(["sender": quote.sender.lowercased(), "recipient": dest == nil ? quote.recipient : quote.recipient.lowercased()],
                                         expected: ["sender": me.lowercased(), "recipient": dest == nil ? recipient : recipient.lowercased()], subject: "Relay quote")
        guard binding.ok else { throw ExecutionError(binding.problems.joined(separator: " ")) }
        guard let depository = try await Relay.depository(chainId: chain)?.lowercased(),
              let deposit = quote.evm.first(where: { $0.id == "deposit" }), deposit.to.lowercased() == depository, deposit.chainId == chain,
              deposit.value == "0" || deposit.value == "<null>" else {
            throw ExecutionError("Relay's deposit isn't to its published depository on \(net.name). Nothing was signed.")
        }
        // depositErc20(address depositor, address token, uint256 amount, bytes32 id)
        let args = Data(deposit.data.dropFirst(4))
        guard deposit.data.prefix(4).hex == "e8017952", args.count == 4 * 32,
              ABI.address(in: args, word: 0)?.lowercased() == me.lowercased(),
              ABI.address(in: args, word: 1)?.lowercased() == usdc,
              ABI.uint(in: args, word: 2) == amount else {
            throw ExecutionError("Relay's deposit asks for something else than \(show(amount)) USDC from this wallet. Nothing was signed.")
        }
        let arriving = Decimal(string: quote.amountOutFormatted) ?? 0
        let spend = Decimal(amount) / 1_000_000
        guard spend - arriving - (topup ?? 0) <= min(max(arriving * Decimal(string: "0.03")!, Decimal(string: "0.15")!), 1) else {
            throw ExecutionError("Relay wants \(Fmt.num(spend)) USDC for \(Fmt.num(arriving)) on \(there): more than allowed.")
        }
        let mint = Relay.Currency.solanaUSDC
        func landed() async throws -> UInt64 {
            if let dest { return try await dest.rpc.tokenBalance(dest.usdc, owner: me) }
            return try await rpc.tokenBalance(owner: wallet.solana, mint: mint)
        }
        let before = try await landed()
        try await approve(base, token: usdc, spender: depository, amount: amount, note: "Approve exactly \(show(amount)) USDC to Relay")
        let hash = try await sendEVM(base, to: deposit.to, data: deposit.data, note: "Relay deposit \(show(amount)) USDC on \(net.name)")
        try journal.append(.init(chain: "relay", id: quote.requestId, kind: .signed, note: "\(net.name) USDC→\(there) \(show(amount)), tx \(hash)"))
        let started = Date()
        while Date().timeIntervalSince(started) < 180 {
            let status = try await Relay.status(requestId: quote.requestId).status
            if status == "success" { try journal.append(.init(chain: "relay", id: quote.requestId, kind: .settled, note: status)); break }
            if ["refund", "failure"].contains(status) {
                try journal.append(.init(chain: "relay", id: quote.requestId, kind: .failed, note: status))
                throw ExecutionError("Relay returned \(status). Check USDC on \(net.name). \(net.explorer)/tx/\(hash)")
            }
            try await Task.sleep(for: .seconds(2))
        }
        let target = before + NSDecimalNumber(decimal: arriving * 990_000).uint64Value
        while Date().timeIntervalSince(started) < 240 {
            let now = try await landed()
            if now >= target {
                return "Moved \(show(amount)) USDC from \(net.name) to \(there) in \(Int(Date().timeIntervalSince(started))) s: \(Fmt.num(arriving)) \(stable) arrived, "
                    + "\(show(now)) \(stable) on \(there) now." + (topup != nil ? " A little gas came along." : "")
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw ExecutionError("Relay didn't credit \(there) within 4 minutes. Order \(quote.requestId) is in the journal. \(net.explorer)/tx/\(hash)")
    }

    /// An exact approve when the allowance is short, then a wait until the chain shows it: the next call's dry run
    /// on a node that hasn't seen the approve yet would revert.
    func approve(_ rpc: EVMRPC, token: String, spender: String, amount: UInt64, note: String) async throws {
        try await approve(rpc, token: token, spender: spender, units: Decimal(amount), note: note)
    }

    /// The same for any amount (256-bit words): a thousand tokens of 18 decimals don't fit 64 bits.
    func approve(_ rpc: EVMRPC, token: String, spender: String, units amount: Decimal, note: String) async throws {
        func allowance() async throws -> Decimal {
            ABI.decimal(in: try await rpc.read(token, try ERC20.allowance(owner: wallet.evm, spender: spender)), word: 0) ?? 0
        }
        guard try await allowance() < amount else { return }
        _ = try await sendEVM(rpc, to: token, data: try ERC20.approve(spender: spender, units: amount), note: note)
        for _ in 0..<15 {
            if try await allowance() >= amount { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw ExecutionError("The approve went through but the network doesn't show it yet. Try again in a minute; nothing else was signed.")
    }

    /// One EVM transaction: dry run by eth_estimateGas (a call that would revert stops here), the fee within the ETH
    /// there, the journal written before sending.
    func sendEVM(_ rpc: EVMRPC, to: String, data: Data, note: String, recipients: [String] = []) async throws -> String {
        guard let net = EVMNetwork.of(chainId: rpc.chainId) else { throw ExecutionError("ihatecrypto doesn't move money on network \(rpc.chainId). Nothing was signed.") }
        if let token = net.feeToken, to.lowercased() != Tempo.feeManager {
            // Only a plain transfer of the fee coin pays its fee in that coin by itself.
            let paysInToken = if case .transfer = EVMCall.decode(data) { to.lowercased() == token } else { false }
            if !paysInToken { try await chooseFeeToken(net, token) }
        }
        let estimate = try await rpc.estimateGas(from: wallet.evm, to: to, value: 0, data: data)
        let (tip, maxFee) = try await rpc.fees()
        let gasLimit = estimate + estimate / 4
        if let token = net.feeToken {
            guard Tempo.feeUnits(gasLimit * maxFee) <= (try await rpc.tokenBalance(token, owner: wallet.evm)) else {
                throw ExecutionError("Not enough \(net.gasCoin) on \(net.name) for the fee: \(note).")
            }
        } else {
            guard gasLimit * maxFee <= (try await rpc.balance(wallet.evm)) else { throw ExecutionError("Not enough \(net.gasCoin) on \(net.name) for gas: \(note).") }
        }
        let nonce = try await rpc.nonce(wallet.evm)
        let raw = try await signer.signEVM(chainId: rpc.chainId, nonce: nonce, maxPriorityFee: tip, maxFee: maxFee, gasLimit: gasLimit, to: to, data: data,
                                           recipients: recipients)
        let hash = "0x" + Keccak.hash256(raw).hex
        try journal.append(.init(chain: net.key, id: hash, kind: .signed, note: note))
        _ = try await rpc.send(raw)
        guard try await rpc.waitForReceipt(hash) else {
            try journal.append(.init(chain: net.key, id: hash, kind: .failed, note: note))
            throw ExecutionError("\(note) failed on \(net.name): \(net.explorer)/tx/\(hash)")
        }
        try journal.append(.init(chain: net.key, id: hash, kind: .confirmed))
        report("\(note): done. \(net.explorer)/tx/\(hash)")
        return hash
    }

    /// Tempo: the wallet's fee token set to `token` once, before a call that isn't a plain transfer of it.
    private func chooseFeeToken(_ net: EVMNetwork, _ token: String) async throws {
        guard ABI.address(in: try await net.rpc.read(Tempo.feeManager, try Tempo.userToken(wallet.evm)), word: 0)?.lowercased() != token else { return }
        _ = try await sendEVM(net.rpc, to: Tempo.feeManager, data: try Tempo.setUserToken(token), note: "Pay \(net.name) fees in \(net.gasCoin) from now on")
    }
}
