import EVMChain
import Foundation
import IhatecryptoCore
import TradeExecution
import WalletCore

/// A contract call the chat wrote out («call arbitrum 0x… deposit(uint256,address) 10e6 me approving 10 USDC»), checked
/// and simulated, waiting for Confirm. The model only writes the command: ihatecrypto encodes it from the function's
/// signature, checks the contract on the network's explorer, simulates the exact approve and the call together and draws
/// the card; anything it can't decode, verify or simulate isn't offered (it fails closed). The signer reads the calldata
/// again: no unlimited approvals, nothing paid to someone else, a new spender confirmed in person.
struct CallReview {
    struct Approve { let token: String; let symbol: String; let amount: Decimal; let units: Decimal }
    let command: WalletCommand
    let call: ContractCall
    let net: EVMNetwork
    let data: Data
    /// Wei of the network's coin sent with the call.
    let value: UInt64
    let approve: Approve?
    /// What it does, read from the calldata.
    let lines: [String]
    /// The simulated change of each of this wallet's balances.
    let changes: [String]
    let trust: ContractTrust
    let warnings: [String]
    /// «FluidLending» or «0x1a99…6096».
    var contractName: String { trust.implementation ?? trust.name ?? "\(call.contract.prefix(6))…\(call.contract.suffix(4))" }
}

extension Workspace {
    func prepareContractCall(_ command: WalletCommand, note: String? = nil) async {
        guard case .contractCall(let c) = command, let net = EVMNetwork.named(c.network) else { return }
        guard let me = signerWallet?.evm, isEVMAddress(me) else {
            reply(say("Contract calls need this wallet's EVM key in secure storage.", "Для вызова контракта нужен EVM-ключ этого кошелька в защищённом хранилище."), note: note)
            return
        }
        func refuse(_ en: String, _ ru: String) {
            reply(say("I won't make this call: " + en + " Nothing was signed.", "Этот вызов делать не буду: " + ru + " Ничего не подписано."), note: note)
        }
        // Addresses the user gave: in their own last message (never a chain's or a task's command text, which the model
        // wrote), their favorites or their address book.
        let theirs = Set(([me] + favoriteTokens.map(\.address) + addressBook.map(\.address)).map { $0.lowercased() })
        let said = (messages.last(where: \.fromUser)?.text ?? "").lowercased()
        func usersOwn(_ a: String) -> Bool { theirs.contains(a.lowercased()) || said.contains(a.lowercased()) }

        agentStep = say("Encoding the call", "Собираю вызов")
        let data: Data
        do { data = try AgentReads.calldata(c.function, c.args, me: me) } catch {
            refuse(error.localizedDescription, error.localizedDescription)
            return
        }
        // The contract, and every other address among the arguments, is the user's own or verified code on the explorer.
        agentStep = say("Checking the contract on the explorer", "Проверяю контракт в обозревателе")
        let trust = await ContractTrust.check(c.contract, on: net.key)
        if !trust.unknown, !trust.isContract { refuse("\(c.contract) isn't a contract on \(net.name).", "\(c.contract) — не контракт в сети \(net.name)."); return }
        guard trust.verified || usersOwn(c.contract) else {
            refuse("\(c.contract) on \(net.name) has no verified source on the explorer (\(trust.line)). If you trust it, paste its address yourself.",
                   "у \(c.contract) в \(net.name) нет проверенного исходника в обозревателе (\(trust.line)). Если доверяешь ему — вставь адрес сам.")
            return
        }
        // The zero address («no referrer», «none») gives nobody anything; anything else is checked.
        for a in c.args where a.wholeMatch(of: /0x[0-9a-fA-F]{40}/) != nil && !usersOwn(a) && a.lowercased() != c.contract.lowercased()
            && a.dropFirst(2).contains(where: { $0 != "0" }) {
            let t = await ContractTrust.check(a, on: net.key)
            guard t.isContract, t.verified else {
                refuse("the argument \(a) is neither yours nor a verified contract — money could go there.",
                       "аргумент \(a) — не твой адрес и не проверенный контракт: туда могут уйти деньги.")
                return
            }
        }
        // Coins sent with it, in wei.
        var value: UInt64 = 0
        if let v = c.value, v > 0 {
            let wei = (v * 1_000_000_000_000_000_000).rounded(0, .down)
            guard wei <= Decimal(UInt64.max) else { refuse("that's more \(net.gasCoin) than one call takes.", "это больше \(net.gasCoin), чем берёт один вызов."); return }
            value = NSDecimalNumber(decimal: wei).uint64Value
        }
        // The exact approve: the network's USDC or a big stablecoin by ticker, else a token contract.
        var approve: CallReview.Approve?
        if let a = c.approve {
            let up = a.token.uppercased()
            guard let token = a.token.hasPrefix("0x") ? a.token : up == "USDC" ? net.usdc : Stablecoins.find(a.token, on: net.key)?.address,
                  token.wholeMatch(of: /0x[0-9a-fA-F]{40}/) != nil else {
                refuse("I don't know the token «\(a.token)» on \(net.name): write its contract.", "не знаю токен «\(a.token)» в \(net.name): напиши его контракт.")
                return
            }
            let meta = await tokenMeta(token, net)
            approve = .init(token: token, symbol: meta.symbol, amount: a.amount, units: (a.amount * pow(10, meta.decimals)).rounded(0, .down))
        }
        // What the calldata does, and what the signer would refuse anyway.
        let decoded = EVMCall.decode(data)
        if let why = decoded.refusal(sender: me, chainId: net.rpc.chainId) { refuse(why, why); return }
        let foreign = decoded.payees(to: c.contract, value: value, chainId: net.rpc.chainId).filter { ![me.lowercased(), c.contract.lowercased()].contains($0.lowercased()) }
        if let other = foreign.first { refuse("money or the right to spend it would go to \(other).", "деньги или право их тратить ушли бы на \(other)."); return }
        // Both simulated together: the approve, then the call that spends it. No simulation, no card.
        agentStep = say("Simulating it on \(net.name)", "Симулирую в \(net.name)")
        var calls: [(to: String, value: UInt64, data: Data)] = []
        if let a = approve { calls.append((a.token, 0, (try? ERC20.approve(spender: c.contract, units: a.units)) ?? Data())) }
        calls.append((c.contract, value, data))
        let sim: EVMSimulation
        do { sim = try await Self.simulator(net).simulate(from: me, calls: calls) } catch {
            refuse("\(net.name)'s node couldn't simulate it (\(error.localizedDescription)), and ihatecrypto signs nothing it hasn't simulated.",
                   "нода \(net.name) не смогла это просимулировать (\(error.localizedDescription)), а без симуляции ihatecrypto ничего не подписывает.")
            return
        }
        if let revert = sim.revert { refuse("the simulation says it would fail — \(revert).", "симуляция говорит, что он не пройдёт — \(revert)."); return }
        var changes: [String] = []
        for (asset, delta) in sim.changes.sorted(by: { $0.key < $1.key }) {
            if asset == EVMSimulation.native { changes.insert("\(net.gasCoin): \(Self.delta(delta / 1_000_000_000_000_000_000))", at: 0); continue }
            let t = await tokenMeta(asset, net)
            changes.append("\(t.symbol): \(Self.delta(sim.nfts.contains(asset) ? delta : delta / pow(10, t.decimals)))")
        }
        var warnings: [String] = []
        if !sim.changes.isEmpty, sim.changes.values.allSatisfy({ $0 < 0 }) {
            warnings.append(say("Nothing comes back to this wallet in this transaction.", "В этой транзакции на кошелёк ничего не возвращается."))
        }
        if !trust.verified { warnings.append(say("Unverified source: the address is from your own words.", "Исходник не проверен: адрес — из твоих слов.")) }
        if let d = trust.days, d < 30 { warnings.append(say("A new contract: \(d) days old.", "Новый контракт: ему \(d) дн.")) }
        let review = CallReview(command: command, call: c, net: net, data: data, value: value, approve: approve,
                                lines: [decoded.summary(chainId: net.rpc.chainId, to: c.contract, value: value)], changes: changes.isEmpty ? [say("None of your balances change.", "Балансы не меняются.")] : changes,
                                trust: trust, warnings: warnings)
        callReview = review
        pendingAction = .wallet(command)
        pendingText = c.text
        reply(say("\(c.name) on \(review.contractName) (\(net.name)) is checked and simulated: \(review.changes.joined(separator: ", ")). The card is on the canvas — press Confirm.",
                  "\(c.name) на \(review.contractName) (\(net.name)) проверен и просимулирован: \(review.changes.joined(separator: ", ")). Карточка на холсте — нажми Confirm.")
              + (warnings.isEmpty ? "" : " ⚠ " + warnings.joined(separator: " ")), note: note)
    }

    /// After Confirm: the approve and the call exactly as simulated (the executor dry-runs the call again before signing it).
    func runContractCall(_ command: WalletCommand, _ e: Executor) async throws -> String {
        guard let r = callReview, r.command == command else { throw ExecutionError("The call's check is gone; ask for it again.") }
        callReview = nil
        return try await e.contractCall(r.net, to: r.call.contract, data: r.data, value: r.value, approve: r.approve.map { ($0.token, $0.units) },
                                        approveNote: "Approve exactly \(Fmt.num(r.approve?.amount ?? 0, maxFraction: 6)) \(r.approve?.symbol ?? "") to \(r.contractName)",
                                        note: "\(r.call.name) on \(r.contractName) on \(r.net.name)")
    }

    /// The card: the exact approve, the call with what the explorer says of the contract, and the simulated balances.
    func callRoute(_ command: WalletCommand) -> MoveRoute? {
        guard let r = callReview, r.command == command else { return nil }
        let logo = ModuleNetwork(place: r.net.key)?.logo, fill = RouteFill(rawValue: r.net.key) ?? .check
        var steps: [ActivityBubble] = []
        if let a = r.approve {
            steps.append(ActivityBubble(kind: "step", label: "APPROVE · EXACT", title: "\(Fmt.num(a.amount, maxFraction: 6)) \(a.symbol)",
                                        lines: [say("exactly this · only \(r.contractName) may take it", "ровно столько · взять может только \(r.contractName)")], logo: logo, fill: fill))
        }
        steps.append(ActivityBubble(kind: "step", label: "CALL · \(r.net.name.uppercased())", title: r.call.name, lines: r.lines + [r.trust.line], logo: logo, fill: fill))
        steps.append(ActivityBubble(kind: "step", label: "SIMULATED", title: r.changes[0], lines: Array(r.changes.dropFirst()), logo: logo, fill: .check))
        return MoveRoute(title: "\(r.call.name) · \(r.contractName)",
                         footer: "Encoded by ihatecrypto from \(r.call.function), simulated on \(r.net.name)"
                            + (r.approve == nil ? "" : " with its exact approve") + "; the signer reads it again and asks for a new spender in person. Press Confirm.",
                         steps: steps, warning: r.warnings.first)
    }

    /// The node that runs eth_simulateV1 for a network: Arbitrum's own crashes on it (Browser.evmSimulationRPC).
    static func simulator(_ net: EVMNetwork) -> EVMRPC {
        Browser.evmSimulationRPC[net.rpc.chainId].flatMap(URL.init(string:)).map { EVMRPC(url: $0, chainId: net.rpc.chainId) } ?? net.rpc
    }

    nonisolated static func delta(_ d: Decimal) -> String { (d > 0 ? "+" : d < 0 ? "−" : "") + Fmt.num(abs(d), maxFraction: 8) }

    /// A token's symbol and decimals, read from it.
    func tokenMeta(_ token: String, _ net: EVMNetwork) async -> (symbol: String, decimals: Int) {
        let symbol = (try? await net.rpc.read(token, Data([0x95, 0xd8, 0x9b, 0x41]))).flatMap(ABI.string) ?? "\(token.prefix(6))…"
        let decimals = (try? await net.rpc.read(token, Data([0x31, 0x3c, 0xe5, 0x67]))).flatMap { ABI.uint(in: $0, word: 0) } ?? 18
        return (symbol, Int(decimals))
    }
}
