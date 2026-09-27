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

    public static let base = EVMNetwork(name: "Base", key: "base", rpc: .base, usdc: EVMRPC.baseUSDC, relayChain: Relay.Chain.base,
                                        explorer: "https://basescan.org", gasFloor: 5_000_000_000_000, topupUSD: Decimal(string: "0.03")!)
    /// Gas on Arbitrum costs a few times Base's (its L1 data share): a larger floor and top-up.
    public static let arbitrum = EVMNetwork(name: "Arbitrum", key: "arbitrum", rpc: .arbitrum, usdc: EVMRPC.arbitrumUSDC, relayChain: Relay.Chain.arbitrum,
                                            explorer: "https://arbiscan.io", gasFloor: 10_000_000_000_000, topupUSD: Decimal(string: "0.05")!)

    /// Robinhood Chain: its dollar is USDG (Relay delivers it; Stock Tokens trade against it on Uniswap).
    public static let robinhood = EVMNetwork(name: "Robinhood Chain", key: "robinhood", rpc: .robinhood, usdc: EVMRPC.robinhoodUSDG,
                                             relayChain: Relay.Chain.robinhood, explorer: "https://robinhoodchain.blockscout.com",
                                             gasFloor: 15_000_000_000_000, topupUSD: Decimal(string: "0.08")!)

    static func of(chainId: UInt64) -> EVMNetwork {
        [arbitrum, robinhood].first { $0.rpc.chainId == chainId } ?? base
    }
}

/// Aave v3 on Base: USDC in and out. USDC missing on Base comes from Solana over Relay, with a little ETH for gas.
extension Executor {
    static var baseGasFloorForPlan: UInt64 { EVMNetwork.base.gasFloor }

    public func aave(deposit: Bool, usdc requested: Decimal?) async throws -> String {
        let base = EVMRPC.base
        // Pool and aToken are re-read from Base before anything is signed.
        let apy = try await AaveV3.verifyBase(base)
        let usdc = EVMRPC.baseUSDC, pool = AaveV3.basePool, me = wallet.evm
        func units(_ d: Decimal) -> UInt64 { NSDecimalNumber(decimal: (d * 1_000_000).rounded(0, .down)).uint64Value }
        func show(_ u: UInt64) -> String { Fmt.num(Decimal(u) / 1_000_000, maxFraction: 6) }

        guard deposit else {
            let supplied = try await base.tokenBalance(AaveV3.baseAUSDC, owner: me)
            guard supplied > 0 else { throw ExecutionError("Nothing is supplied to Aave on Base.") }
            // nil = everything, interest included.
            let amount = requested.map(units).flatMap { $0 < supplied ? $0 : nil }
            let before = try await base.tokenBalance(usdc, owner: me)
            _ = try await sendEVM(base, to: pool, data: try AaveV3.withdraw(asset: usdc, amount: amount, to: me),
                                  note: "Aave withdraw \(amount.map(show) ?? "all") USDC")
            var onBase = try await base.tokenBalance(usdc, owner: me)
            for _ in 0..<10 where onBase <= before {
                try await Task.sleep(for: .seconds(1))
                onBase = try await base.tokenBalance(usdc, owner: me)
            }
            // Back where the money lives: Solana.
            return try await baseToSolana(usdc: nil)
        }

        guard let requested, requested > 0 else { throw ExecutionError("Say how much, e.g. “lend 2 USDC on Aave”.") }
        let want = units(requested)
        try await ensureBase(usdc: want)
        try await approve(base, token: usdc, spender: pool, amount: want, note: "Approve exactly \(show(want)) USDC to Aave")
        let before = try await base.tokenBalance(AaveV3.baseAUSDC, owner: me)
        let hash = try await sendEVM(base, to: pool, data: try AaveV3.supply(asset: usdc, amount: want, onBehalfOf: me), note: "Aave supply \(show(want)) USDC")
        // A node can answer from a block before the receipt's for a moment: give it up to ten seconds.
        var after = try await base.tokenBalance(AaveV3.baseAUSDC, owner: me)
        for _ in 0..<10 where after <= before {
            try await Task.sleep(for: .seconds(1))
            after = try await base.tokenBalance(AaveV3.baseAUSDC, owner: me)
        }
        guard after > before else { throw ExecutionError("The supply went through but aUSDC didn't grow. https://basescan.org/tx/\(hash)") }
        return "Supplied \(show(want)) USDC to Aave on Base at ≈ \(Fmt.num(apy.rounded(2, .plain)))% a year: \(show(after)) USDC there now. https://basescan.org/tx/\(hash)"
    }

    func ensureBase(usdc want: UInt64) async throws { try await ensureEVM(.base, usdc: want) }

    /// At least `want` USDC and some ETH for gas on the network: what is missing comes from Solana over Relay.
    /// `gas`: a floor and a top-up for calls heavier than a supply (a Morpho vault deposit is ≈ 450k gas);
    /// the top-up must land above the floor, or the wait below runs out.
    func ensureEVM(_ net: EVMNetwork, usdc want: UInt64, gas heavier: (floor: UInt64, topupUSD: Decimal)? = nil) async throws {
        let me = wallet.evm
        func show(_ u: UInt64) -> String { Fmt.num(Decimal(u) / 1_000_000, maxFraction: 6) }
        let floor = max(net.gasFloor, heavier?.floor ?? 0), topupUSD = max(net.topupUSD, heavier?.topupUSD ?? 0)
        var there = try await net.rpc.tokenBalance(net.usdc, owner: me)
        var gas = try await net.rpc.balance(me)
        guard there < want || gas < floor else { return }
        let short = Decimal(want > there ? want - there : 0) / 1_000_000
        let needGas = gas < floor
        // Relay has minimums: a gas top-up rides on at least half a dollar of USDC.
        let arrive = max(short, needGas ? Decimal(string: "0.5")! : 0)
        let (step, changes) = try await prepareBridge(.arrive(arrive), to: net.relayChain, currency: net.usdc, decimals: 6,
                                                      topupGasUSD: needGas ? topupUSD : nil)
        let stable = net.key == "robinhood" ? "USDG" : "USDC"
        report("Bridge to \(net.name): \(Fmt.num(step.spend)) USDC from Solana → \(Fmt.num(step.arriving)) \(stable)\(needGas ? " plus ETH for gas" : ""). "
               + changes.joined(separator: " "))
        try await sendBridge(step)
        let started = Date()
        while there < want || gas < floor {
            guard Date().timeIntervalSince(started) < 240 else {
                throw ExecutionError("The USDC didn't reach \(net.name) within 4 minutes. Relay order \(step.requestId) is in the journal; nothing else was signed.")
            }
            try await Task.sleep(for: .seconds(2))
            there = try await net.rpc.tokenBalance(net.usdc, owner: me)
            gas = try await net.rpc.balance(me)
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
    public func evmToSolana(_ net: EVMNetwork, usdc requested: Decimal?) async throws -> String {
        let base = net.rpc, usdc = net.usdc, me = wallet.evm, chain = net.relayChain
        func show(_ u: UInt64) -> String { Fmt.num(Decimal(u) / 1_000_000, maxFraction: 6) }
        let have = try await base.tokenBalance(usdc, owner: me)
        let amount = requested.map { min(NSDecimalNumber(decimal: ($0 * 1_000_000).rounded(0, .down)).uint64Value, have) } ?? have
        guard amount >= 500_000 else { throw ExecutionError("\(show(have)) USDC on \(net.name) — below the half-dollar a bridge is worth.") }

        let quote = try await Relay.quote(user: me, recipient: wallet.solana, originChain: chain, destinationChain: Relay.Chain.solana,
                                          originCurrency: usdc, destinationCurrency: Relay.Currency.solanaUSDC, amount: amount)
        let binding = BindingGuard.check(["sender": quote.sender, "recipient": quote.recipient],
                                         expected: ["sender": me, "recipient": wallet.solana], subject: "Relay quote")
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
        guard spend - arriving <= min(max(arriving * Decimal(string: "0.03")!, Decimal(string: "0.15")!), 1) else {
            throw ExecutionError("Relay wants \(Fmt.num(spend)) USDC for \(Fmt.num(arriving)) on Solana: more than allowed.")
        }
        let mint = Relay.Currency.solanaUSDC
        let solBefore = try await rpc.tokenBalance(owner: wallet.solana, mint: mint)
        try await approve(base, token: usdc, spender: depository, amount: amount, note: "Approve exactly \(show(amount)) USDC to Relay")
        let hash = try await sendEVM(base, to: deposit.to, data: deposit.data, note: "Relay deposit \(show(amount)) USDC on \(net.name)")
        try journal.append(.init(chain: "relay", id: quote.requestId, kind: .signed, note: "\(net.name) USDC→Solana \(show(amount)), tx \(hash)"))
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
        let target = solBefore + NSDecimalNumber(decimal: arriving * 990_000).uint64Value
        while Date().timeIntervalSince(started) < 240 {
            let now = try await rpc.tokenBalance(owner: wallet.solana, mint: mint)
            if now >= target {
                return "Moved \(show(amount)) USDC from \(net.name) to Solana in \(Int(Date().timeIntervalSince(started))) s: \(Fmt.num(arriving)) arrived, \(show(now)) USDC on Solana now."
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw ExecutionError("Relay didn't credit Solana within 4 minutes. Order \(quote.requestId) is in the journal. \(net.explorer)/tx/\(hash)")
    }

    /// An exact approve when the allowance is short, then a wait until the chain shows it: the next call's dry run
    /// on a node that hasn't seen the approve yet would revert.
    func approve(_ rpc: EVMRPC, token: String, spender: String, amount: UInt64, note: String) async throws {
        func allowance() async throws -> UInt64 {
            ABI.uint(in: try await rpc.read(token, try ERC20.allowance(owner: wallet.evm, spender: spender)), word: 0) ?? 0
        }
        guard try await allowance() < amount else { return }
        _ = try await sendEVM(rpc, to: token, data: try ERC20.approve(spender: spender, amount: amount), note: note)
        for _ in 0..<15 {
            if try await allowance() >= amount { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw ExecutionError("The approve went through but the network doesn't show it yet. Try again in a minute; nothing else was signed.")
    }

    /// One EVM transaction: dry run by eth_estimateGas (a call that would revert stops here), the fee within the ETH
    /// there, the journal written before sending.
    func sendEVM(_ rpc: EVMRPC, to: String, data: Data, note: String, recipients: [String] = []) async throws -> String {
        let net = EVMNetwork.of(chainId: rpc.chainId)
        let estimate = try await rpc.estimateGas(from: wallet.evm, to: to, value: 0, data: data)
        let (tip, maxFee) = try await rpc.fees()
        let gasLimit = estimate + estimate / 4
        guard gasLimit * maxFee <= (try await rpc.balance(wallet.evm)) else { throw ExecutionError("Not enough ETH on \(net.name) for gas: \(note).") }
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
}
