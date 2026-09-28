import Foundation
import HyperliquidSigning
import JupiterSwap
import DeFiKamino
import DeFiYields
import EVMChain
import LalaCore
import SolanaChain
import TradeExecution
import TxGuard
import WalletCore

/// The test wallet's keys in this process, behind the same guard the app's signing process runs.
struct LocalSigner: TradeSigner {
    let keys: (solana: Data, evm: Data)
    let wallet: TradeWallet

    init() throws {
        keys = try TestWallet.keys()
        let a = try TestWallet.addresses()
        wallet = TradeWallet(solana: a.solana, evm: a.evm)
    }

    func signSolana(_ wire: Data, accounts: [String], recipients: [String], tokenOwners: [String: String]) async throws -> Data {
        let verdict = SolanaGuard.check(try SolanaMessage.parse(transaction: wire), accounts: accounts,
                                        policy: SolanaPolicy(owner: wallet.solana, recipients: Set(recipients)), tokenOwners: tokenOwners)
        guard verdict.ok else { throw ExecutionError(verdict.problems.joined(separator: " ")) }
        return try SolanaTransaction.sign(wire, privateKey: keys.solana).wire
    }

    func signHyperliquid(_ action: MsgPack, nonce: UInt64) async throws -> EVMSignature {
        let verdict = HLGuard.check(action, owner: wallet.evm, recipients: [])
        guard verdict.ok else { throw ExecutionError(verdict.problems.joined(separator: " ")) }
        return try HLSigner.signL1(action, privateKey: keys.evm, nonce: nonce, mainnet: true)
    }

    func signHyperliquidUser(_ action: MsgPack, recipients: [String]) async throws -> EVMSignature {
        let verdict = HLGuard.check(action, owner: wallet.evm, recipients: Set(recipients))
        guard verdict.ok else { throw ExecutionError(verdict.problems.joined(separator: " ")) }
        guard case .map(let pairs) = action, case .string("sendAsset")? = pairs.first(where: { $0.0 == "type" })?.1 else {
            throw ExecutionError("Only sendAsset is signed here.")
        }
        let v = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
        func str(_ k: String) -> String { if case .string(let s)? = v[k] { return s }; return "" }
        guard case .uint(let nonce)? = v["nonce"] else { throw ExecutionError("No nonce.") }
        return try HLSigner.sendAsset(destination: str("destination"), sourceDex: str("sourceDex"), destinationDex: str("destinationDex"),
                                      token: str("token"), amount: str("amount"), nonce: nonce, privateKey: keys.evm, mainnet: true).1
    }

    func signRelayMapping(wallet w: String, depositor: String, id: Data, nonce: UInt64) async throws -> EVMSignature {
        guard w.lowercased() == wallet.evm.lowercased(), depositor.lowercased() == wallet.evm.lowercased() else { throw ExecutionError("Mapping is not for our wallet.") }
        return try EVMSigner.sign(digest: HLSigner.relayNonceMappingDigest(wallet: w, depositor: depositor, id: id, nonce: nonce), privateKey: keys.evm)
    }

    /// The same calldata rules as the signing process: known networks, no unlimited approvals, tokens only to us.
    func signEVM(chainId: UInt64, nonce: UInt64, maxPriorityFee: UInt64, maxFee: UInt64, gasLimit: UInt64, to: String, data: Data,
                 recipients: [String]) async throws -> Data {
        guard [1, 42161, 8453, 4663].contains(chainId) else { throw ExecutionError("Not signing for network \(chainId).") }
        let call = EVMCall.decode(data)
        if let refusal = call.refusal(sender: wallet.evm) { throw ExecutionError(refusal) }
        if case .transfer(let recipient, _) = call, !(recipients + [wallet.evm]).contains(where: { $0.lowercased() == recipient.lowercased() }) {
            throw ExecutionError("Tokens would go to \(recipient).")
        }
        return try EVMTransaction(chainId: chainId, nonce: nonce, maxPriorityFeePerGas: maxPriorityFee, maxFeePerGas: maxFee,
                                  gasLimit: gasLimit, to: to, value: 0, data: data).signed(privateKey: keys.evm).raw
    }

    /// The same fixed wrap.near transaction the signing process builds.
    func signNearIntentDeposit(amount: UInt128, depositAddress: String, nonce: UInt64, blockHash: Data) async throws -> Data {
        guard amount > 0, depositAddress.wholeMatch(of: /[0-9a-f]{64}/) != nil, blockHash.count == 32 else { throw ExecutionError("Not a 1Click NEAR deposit.") }
        let key = try TestWallet.nearKey()
        return try NearTransaction.sign(receiver: NearTransaction.wrapContract, nonce: nonce, blockHash: blockHash,
                                        actions: NearTransaction.intentDeposit(account: try NearAccount.implicit(privateKey: key), depositAddress: depositAddress, amount: amount),
                                        privateKey: key).signed
    }
}

/// `execute "<phrase>"`: builds the plan from the phrase, prepares and prints what would be signed; `--yes` runs it.
func executePlan(_ phrase: String) async throws {
    let signer = try LocalSigner()
    let markets = try await Hyperliquid.markets()
    guard let intent = IntentParser.apply(phrase, to: TradeIntent(), markets: Set(markets.keys)) else { throw WalletError("Could not parse the phrase.") }
    let executor = Executor(wallet: signer.wallet, signer: signer, journal: journal, rpc: rpc) { print("[\(stamp())] \($0)") }
    // The test wallet holds about $15: under the usual 2% nothing clears Hyperliquid's $10 minimum.
    var policy = RiskPolicy()
    policy.maxRiskPct = 10
    let prepared = try await executor.prepare(intent, policy: policy)
    print("Will sign:")
    for (n, s) in prepared.steps.enumerated() { print("  \(n + 1). \(s)") }
    print("What changes:")
    for c in prepared.changes { print("  · \(c)") }
    guard send else { print("Add --yes to execute."); return }
    let opened = try await executor.execute(prepared)
    print("\(opened.pending ? "Limit pending" : "Opened"): \(opened.size) \(opened.asset) at \(opened.entry), stop \(opened.stop), take-profit \(opened.take.map { "\($0)" } ?? "none")")
    try await printPosition()
}

func closePosition(_ asset: String) async throws {
    let signer = try LocalSigner()
    guard send else { print("Close \(asset): add --yes."); return }
    let executor = Executor(wallet: signer.wallet, signer: signer, journal: journal, rpc: rpc) { print("[\(stamp())] \($0)") }
    print(try await executor.close(asset: asset))
    try await printPosition()
}

/// `move "выведи 2 USDC в Solana"`, `move "положи 1 USDC в хранилище"`, `move "сними из хранилища"`.
func moveMoney(_ text: String) async throws {
    guard let command = WalletCommand.parse(text) else { throw WalletError("Could not parse the command: \(text)") }
    print("Command: \(command)")
    // Read-only commands and the allocation plan run without --yes; the plan executes only with it.
    switch command {
    case .yields, .allocate: break
    default: guard send else { print("Add --yes."); return }
    }
    let signer = try LocalSigner()
    let executor = Executor(wallet: signer.wallet, signer: signer, journal: journal, rpc: rpc) { print("[\(stamp())] \($0)") }
    switch command {
    case .withdrawToSolana(let usdc): _ = try await executor.withdrawToSolana(usdc: usdc)
    case .lendDeposit(let symbol, let amount): _ = try await executor.lend(symbol, amount: amount, deposit: true)
    case .lendWithdraw(let symbol, let amount): _ = try await executor.lend(symbol, amount: amount, deposit: false)
    case .kamino(let deposit, let symbol, let amount): _ = try await executor.kamino(symbol, amount: amount, deposit: deposit)
    case .stake(let sol): _ = try await executor.convert(from: SpotAsset.all[0], to: .jitoSOL, amount: sol)
    case .unstake(let jito): _ = try await executor.convert(from: .jitoSOL, to: SpotAsset.all[0], amount: jito)
    case .hlp(let deposit, let amount): _ = try await executor.hlp(deposit: deposit, amount: amount)
    case .buyNear(let usdc):
        _ = try await executor.buyNear(usdc: usdc ?? 0, account: try TestWallet.nearAccount())
        if let b = try? await Near.balance(account: try TestWallet.nearAccount()) { print("NEAR account: \(Fmt.num(b.near, maxFraction: 6)) NEAR, \(Fmt.num(b.wrapped, maxFraction: 6)) wNEAR") }
    case .sellNear(let amount):
        print(try await executor.sellNear(amount: amount, account: try TestWallet.nearAccount()))
        if let b = try? await Near.balance(account: try TestWallet.nearAccount()) { print("NEAR account: \(Fmt.num(b.near, maxFraction: 6)) NEAR, \(Fmt.num(b.wrapped, maxFraction: 6)) wNEAR") }
    case .aave(let deposit, let amount): print(try await executor.aave(deposit: deposit, usdc: amount))
    case .morpho(let deposit, let amount): print(try await executor.morpho(deposit: deposit, usdc: amount))
    case .baseToSolana(let amount): print(try await executor.baseToSolana(usdc: amount))
    case .arbitrumToSolana(let amount): print(try await executor.evmToSolana(.arbitrum, usdc: amount))
    case .sendTo: throw ExecutionError("Sending to a saved address works in LALA.app, where the address book is.")
    case .buyStock(let symbol, let usdc): print(try await executor.buyStock(symbol, usdc: usdc ?? 1))
    case .sellStock(let symbol, let amount): print(try await executor.sellStock(symbol, amount: amount))
    case .robinhoodToSolana(let amount): print(try await executor.evmToSolana(.robinhood, usdc: amount))
    case .solanaTo(let place, let amount):
        print(try await executor.solanaToEVM(place == "base" ? .base : place == "arbitrum" ? .arbitrum : .robinhood, usdc: amount ?? 1))
    case .receive: print("Solana (USDC, SOL): \(signer.wallet.solana)\nBase / EVM (USDC, ETH): \(signer.wallet.evm)")
    case .allocate(let symbol, let share):
        let (text, ready, _) = try await executor.allocate(symbol, maxShare: share ?? 50, execute: send)
        if !send { print(text + (ready ? "\nWith --yes I'll allocate by this plan." : "")) }
    case .yields(let asset):
        for o in await Yields.options(for: asset) { print("\(o.asset) · \(o.place): \(Fmt.num(o.apy.rounded(2, .plain)))%  \(o.note)") }
        return
    case .buy(let asset, let usdc): _ = try await executor.swap(asset, buy: true, amount: usdc)
    case .sell(let asset, let amount): _ = try await executor.swap(asset, buy: false, amount: amount)
    case .schedule, .stopSchedules: print("Scheduled buys are run by the LALA app while it is open.")
    }
    try await printLendPositions()
    try await printBalances()
}

/// `manage "стоп в безубыток"` and the like, on the position of the named or ETH asset.
func managePosition(_ text: String) async throws {
    guard let command = PositionCommand.parse(text) else { throw WalletError("Could not parse the command: \(text)") }
    let signer = try LocalSigner()
    let markets = try await Hyperliquid.markets()
    let asset = text.uppercased().split(whereSeparator: { !$0.isLetter }).map(String.init).first { markets[$0] != nil } ?? "ETH"
    print("Command: \(command) for \(asset)")
    guard send else { print("Add --yes."); return }
    let executor = Executor(wallet: signer.wallet, signer: signer, journal: journal, rpc: rpc) { print("[\(stamp())] \($0)") }
    _ = try await executor.manage(command, asset: asset)
    try await printPosition()
}

func printPosition() async throws {
    let evm = try TestWallet.addresses().evm
    let positions = try await HyperliquidAccount.positions(evm)
    if positions.isEmpty { print("No positions.") }
    for p in positions {
        print("Position \(p.coin): \(p.size) at \(p.entry), PnL \(Fmt.usd(p.unrealizedPnl)), liquidation \(p.liquidation.map { Fmt.price($0) } ?? "—")")
    }
    for o in try await HyperliquidAccount.openOrders(evm) {
        print("Order \(o.coin) #\(o.oid) \(o.side ?? "?") \(o.size.map { "\($0)" } ?? "?")\(o.isTrigger ? " trigger \(o.triggerPx.map { "\($0)" } ?? "?")" : " limit \(o.limitPx.map { "\($0)" } ?? "?")")")
    }
    try await printBalances()
}

/// `browser-test-page <path>`: a local dApp page for the in-app browser test, with fresh unsigned transactions
/// for the test wallet: a Memo (a program outside LALA's list) and a token Approve to a stranger (a drainer).
func writeBrowserTestPage(_ path: String) async throws {
    let signer = try LocalSigner()
    let owner = signer.wallet.solana
    let (hash, _) = try await rpc.latestBlockhash()
    let memo = SolanaInstruction(program: "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr",
                                 accounts: [.init(pubkey: owner, isSigner: true, isWritable: false)], data: Data("LALA browser test".utf8))
    let memoMessage = try SolanaTransaction.compileMessage([memo], payer: owner, blockhash: hash)
    let stranger = Base58.encode(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    let myUSDC = try SPL.associatedAccount(owner: owner, mint: Jupiter.usdcMint)
    let approve = SolanaInstruction(program: SPL.tokenProgram, accounts: [
        .init(pubkey: myUSDC, isSigner: false, isWritable: true), .init(pubkey: stranger, isSigner: false, isWritable: false),
        .init(pubkey: owner, isSigner: true, isWritable: false),
    ], data: Data([4]) + withUnsafeBytes(of: UInt64(1_000_000).littleEndian) { Data($0) })
    let approveWire = SolanaTransaction.unsigned(try SolanaTransaction.compileMessage([approve], payer: owner, blockhash: hash))
    // EVM: reference signatures made here with the same key, which the page compares with LALA's.
    let evm = signer.wallet.evm
    func hex(_ s: EVMSignature) -> String { "0x" + s.r.hex + s.s.hex + String(format: "%02x", s.v) }
    let login = "Sign in to the LALA test page (EVM)"
    let personal = hex(try EVMSigner.sign(digest: PersonalMessage.digest(Data(login.utf8)), privateKey: signer.keys.evm))
    let typedJSON = #"{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"HyperliquidTransaction:ApproveAgent":[{"name":"hyperliquidChain","type":"string"},{"name":"agentAddress","type":"address"},{"name":"agentName","type":"string"},{"name":"nonce","type":"uint64"}]},"primaryType":"HyperliquidTransaction:ApproveAgent","domain":{"name":"HyperliquidSignTransaction","version":"1","chainId":42161,"verifyingContract":"0x0000000000000000000000000000000000000000"},"message":{"hyperliquidChain":"Mainnet","agentAddress":"0x00000000000000000000000000000000000000aa","agentName":"test","nonce":1700000000000}}"#
    let typedSig = hex(try EVMSigner.sign(digest: TypedData.parse(Data(typedJSON.utf8)).digest, privateKey: signer.keys.evm))
    let permitJSON = #"{"types":{"Permit":[{"name":"owner","type":"address"},{"name":"spender","type":"address"},{"name":"value","type":"uint256"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}]},"primaryType":"Permit","domain":{"name":"USD Coin","version":"2","chainId":42161,"verifyingContract":"0xaf88d065e77c8cC2239327C5EDb3A432268e5831"},"message":{"owner":"\#(evm)","spender":"0x000000000000000000000000000000000000dEaD","value":"115792089237316195423570985008687907853269984665640564039457584007913129639935","nonce":0,"deadline":"99999999999"}}"#
    let html = """
    <!doctype html><meta charset="utf-8"><title>LALA test dApp</title><pre id="out">waiting</pre>
    <script>
    const MEMO_TX = "\(SolanaTransaction.unsigned(memoMessage).base64EncodedString())";
    const MEMO_MESSAGE = "\(memoMessage.base64EncodedString())";
    const APPROVE_TX = "\(approveWire.base64EncodedString())";
    const b64d = (t) => Uint8Array.from(atob(t), (c) => c.charCodeAt(0));
    const results = []; const log = (s) => { results.push(s); document.getElementById('out').textContent = results.join('\\n'); };
    let wallet;
    const api = { register: (w) => { wallet = wallet || w; return () => {}; } };
    window.addEventListener('wallet-standard:register-wallet', ({ detail }) => detail(api));
    window.dispatchEvent(new CustomEvent('wallet-standard:app-ready', { detail: api }));
    (async () => {
      if (!wallet) return log('FAIL: no wallet registered');
      log('wallet: ' + wallet.name + ', features: ' + Object.keys(wallet.features).length);
      const { accounts } = await wallet.features['standard:connect'].connect();
      const account = accounts[0];
      log('connect: ' + account.address);
      const [m] = await wallet.features['solana:signMessage'].signMessage({ account, message: new TextEncoder().encode('Sign in to the LALA test page') });
      log('signMessage: ' + m.signature.length + '-byte signature');
      try { await wallet.features['solana:signMessage'].signMessage({ account, message: b64d(MEMO_MESSAGE) }); log('FAIL: transaction signed as a message'); }
      catch (e) { log('transaction disguised as text: refused (' + e.message + ')'); }
      try {
        const [s] = await wallet.features['solana:signAndSendTransaction'].signAndSendTransaction({ account, transaction: b64d(MEMO_TX), chain: 'solana:mainnet' });
        log('memo (unknown program): signed and sent, signature ' + s.signature.length + ' bytes, ' + btoa(String.fromCharCode(...s.signature)).slice(0, 16));
      } catch (e) { log('memo: FAIL ' + e.message); }
      try { await wallet.features['solana:signTransaction'].signTransaction({ account, transaction: b64d(APPROVE_TX) }); log('FAIL: token approval signed'); }
      catch (e) { log('token approval to a stranger: refused (' + e.message + ')'); }

      // EVM through EIP-6963, the way wallet pickers discover providers.
      let eth = null;
      window.addEventListener('eip6963:announceProvider', ({ detail }) => { if (detail.info.name === 'LALA') eth = detail.provider; });
      window.dispatchEvent(new Event('eip6963:requestProvider'));
      if (!eth) { log('FAIL: no EIP-6963 provider'); log('DONE'); return; }
      const req = (method, params) => eth.request({ method, params });
      const refused = async (label, method, params) => { try { await req(method, params); log('FAIL: ' + label + ' signed'); } catch (e) { log(label + ': refused, code ' + e.code); } };
      log('EIP-6963: LALA, chain ' + await req('eth_chainId'));
      const [addr] = await req('eth_requestAccounts');
      log('evm account: ' + (addr === '\(evm)' ? 'ok ' : 'FAIL ') + addr);
      const sig = await req('personal_sign', ['0x' + [...new TextEncoder().encode('\(login)')].map(b => b.toString(16).padStart(2, '0')).join(''), addr]);
      log('personal_sign: ' + (sig === '\(personal)' ? 'matches reference' : 'FAIL ' + sig));
      const typed = await req('eth_signTypedData_v4', [addr, JSON.stringify(\(typedJSON))]);
      log('typed data (Hyperliquid ApproveAgent): ' + (typed === '\(typedSig)' ? 'matches reference' : 'FAIL ' + typed));
      await refused('Permit (unlimited USDC to a stranger)', 'eth_signTypedData_v4', [addr, JSON.stringify(\(permitJSON))]);
      await refused('blind 32-byte hash', 'personal_sign', ['0x' + 'aa'.repeat(32), addr]);
      // EVM transactions on Arbitrum; the account has no ETH, so a signed one is refused by the node for funds,
      // which names the address it recovered from the signature.
      const pad = (h) => h.replace(/^0x/, '').toLowerCase().padStart(64, '0');
      const USDC = '0xaf88d065e77c8cC2239327C5EDb3A432268e5831';
      const spender = '0x' + '5c'.repeat(20);
      try { await req('eth_sendTransaction', [{ from: addr, to: USDC, data: '0x095ea7b3' + pad(spender) + pad((1000000).toString(16)) }]); log('FAIL: exact approve sent'); }
      catch (e) { log('exact approve 1 USDC: ' + (e.message.toLowerCase().includes(addr.toLowerCase()) ? 'signed, node recovered our address' : 'not signed') + ' — ' + e.message.slice(0, 120)); }
      await refused('unlimited approve', 'eth_sendTransaction', [{ from: addr, to: USDC, data: '0x095ea7b3' + pad(spender) + 'f'.repeat(64) }]);
      await refused('setApprovalForAll', 'eth_sendTransaction', [{ from: addr, to: USDC, data: '0xa22cb465' + pad(spender) + pad('1') }]);
      try { await req('eth_sendTransaction', [{ from: addr, to: USDC, data: '0xa9059cbb' + pad(spender) + pad((1000000).toString(16)) }]); log('FAIL: transfer sent'); }
      catch (e) { log('USDC transfer without balance: refused, code ' + e.code + ' — ' + e.message.slice(0, 90)); }
      let changed = null; eth.on('chainChanged', (c) => { changed = c; });
      await req('wallet_switchEthereumChain', [{ chainId: '0x1' }]);
      log('switch to Ethereum: chainChanged ' + changed + ', balance ' + await req('eth_getBalance', [addr, 'latest']));
      log('DONE');
    })();
    </script>
    """
    try html.write(toFile: path, atomically: true, encoding: .utf8)
    print("Page: \(path)")
}

/// `plan "<phrase>"`: how a phrase is parsed and what plan the rules make of it, on live prices. Signs nothing.
func explainPlan(_ phrase: String) async throws {
    let markets = try await Hyperliquid.markets()
    guard let intent = IntentParser.apply(phrase, to: TradeIntent(), markets: Set(markets.keys)) else { throw WalletError("Could not parse the phrase.") }
    var market = markets[intent.asset]
    market?.atrPct = try? await Hyperliquid.atrPct(coin: intent.asset)
    let a = try TestWallet.addresses()
    let hl = try await Hyperliquid.balance(user: a.evm)
    let equity = hl.accountValue + Decimal(try await rpc.tokenBalance(owner: a.solana, mint: Jupiter.usdcMint)) / 1_000_000
    let (resolved, notes) = Plan.resolve(intent, market: market, equity: equity, policy: RiskPolicy())
    print("Parsed: \(intent.side) \(intent.asset), risk \(intent.riskUSD.map { "\($0)" } ?? "—"), stop \(intent.stopPct.map { "\($0)%" } ?? "—"), by the rules \(intent.autoRules == true)")
    print("Market: \(market.map { "\($0.name) mark \($0.markPx), szDecimals \($0.szDecimals), leverage up to \($0.maxLeverage)×, id \($0.index), dex \($0.dex ?? "main"), ATR 4h \($0.atrPct.map { Fmt.pct($0.rounded(2, .plain)) } ?? "—")" } ?? "none")")
    for n in notes { print("  · \(n)") }
    let e = Plan.evaluate(resolved, market: market)
    if let s = e.sizing { print("Plan: \(s.size) at \(s.entry), notional \(Fmt.usd(s.notional)), margin \(Fmt.usd(s.margin)), stop \(s.stopPrice), take-profit \(s.takePrice.map { "\($0)" } ?? "—"), at stop −\(Fmt.usd(s.lossAtStopUSD))") }
    if let p = e.problem { print("Problem: \(p)") }
    if !e.missing.isEmpty { print("Missing: \(e.missing.joined(separator: ", "))") }
}

/// `kamino <deposit|withdraw> <SYMBOL> [amount] [--yes] [--accept-rent]` — without --yes only simulates (shows rent and
/// changes); --accept-rent lets a first deposit pay Kamino's account rent even when it is over 10% of the amount.
/// `kamino reserves`, `kamino position`.
func kaminoCommand(_ args: [String]) async throws {
    let signer = try LocalSigner()
    switch args.first ?? "reserves" {
    case "reserves":
        for r in try await Kamino.reserves().prefix(12) { print("\(r.symbol)  \(Fmt.num(r.supplyAPY.rounded(2, .plain)))% APY  pool \(Fmt.usd(r.tvlUSD))  \(r.address)") }
    case "position":
        let p = try await Kamino.positions(wallet: signer.wallet.solana)
        if p.isEmpty { print("No Kamino positions.") }
        for x in p { print("\(x.symbol): \(Fmt.usd(x.valueUSD))  (shares \(x.amount))") }
    case let action where action == "deposit" || action == "withdraw":
        let symbol = args.dropFirst().first ?? "USDC"
        let amount = args.dropFirst(2).first.flatMap { Decimal(string: $0) }
        let executor = Executor(wallet: signer.wallet, signer: signer, journal: journal, rpc: rpc) { print("[\(stamp())] \($0)") }
        _ = try await executor.kamino(symbol, amount: amount, deposit: action == "deposit", dryRun: !send,
                                      acceptRent: CommandLine.arguments.contains("--accept-rent"))
        try await printBalances()
    default:
        print("kamino reserves | position | deposit USDC 1 [--yes] | withdraw USDC [amount] [--yes]")
    }
}

/// `sweep-solana <new Solana address> --yes`: the move to a new wallet, for this (old) test wallet. All USDC goes to
/// the new address through the executor's checked send; empty token accounts are closed for their rent; then all SOL
/// follows, the account left at exactly zero. Only the given address may receive anything (the guard checks it).
func sweepSolana(to destination: String) async throws {
    let signer = try LocalSigner()
    let me = signer.wallet.solana
    guard (try? Base58.decode(destination))?.count == 32, destination != me else { throw WalletError("Not a Solana address to move to: \(destination)") }
    guard send else { print("Moves everything on Solana from \(me) to \(destination). Add --yes."); return }
    let executor = Executor(wallet: signer.wallet, signer: signer, journal: journal, rpc: rpc) { print("[\(stamp())] \($0)") }
    let usdc = try await rpc.tokenBalance(owner: me, mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
    if usdc > 0 { print(try await executor.sendUSDC(Decimal(usdc) / 1_000_000, to: .solana(destination), label: "the new wallet")) }

    // Empty token accounts hold ≈ 0.002 SOL of rent each: closing them brings it back before the SOL leaves.
    let accounts = (try await rpc.call("getTokenAccountsByOwner", [me, ["programId": SPL.tokenProgram], ["encoding": "jsonParsed"]]) as? [String: Any])?["value"] as? [[String: Any]] ?? []
    let empty = accounts.compactMap { a -> String? in
        let amount = ((((a["account"] as? [String: Any])?["data"] as? [String: Any])?["parsed"] as? [String: Any])?["info"] as? [String: Any])
            .flatMap { ($0["tokenAmount"] as? [String: Any])?["amount"] as? String }
        return amount == "0" ? a["pubkey"] as? String : nil
    }
    for account in empty {
        let close = SolanaInstruction(program: SPL.tokenProgram, accounts: [
            .init(pubkey: account, isSigner: false, isWritable: true), .init(pubkey: me, isSigner: false, isWritable: true),
            .init(pubkey: me, isSigner: true, isWritable: false),
        ], data: Data([9])) // CloseAccount
        let (hash, lastValid) = try await rpc.latestBlockhash()
        let wire = SolanaTransaction.unsigned(try SolanaTransaction.compileMessage([close], payer: me, blockhash: hash))
        let signed = try await signer.signSolana(wire, accounts: try SolanaMessage.parse(transaction: wire).staticKeys, recipients: [], tokenOwners: [account: me])
        let signature = try await rpc.send(signed)
        print("Closed empty token account \(account.prefix(6))…: \(try await rpc.waitForConfirmation(signature, lastValidBlockHeight: lastValid))")
    }

    // All SOL: the fee is asked from the network for this very message, so the old account ends at exactly zero
    // (anything between zero and the rent minimum would be refused).
    let lamports = try await rpc.balance(me)
    func transfer(_ amount: UInt64, _ hash: String) throws -> Data {
        let data = Data([2, 0, 0, 0]) + withUnsafeBytes(of: amount.littleEndian) { Data($0) }
        return try SolanaTransaction.compileMessage([SolanaInstruction(program: SolanaGuard.system, accounts: [
            .init(pubkey: me, isSigner: true, isWritable: true), .init(pubkey: destination, isSigner: false, isWritable: true),
        ], data: data)], payer: me, blockhash: hash, microLamportsPerCU: 0)
    }
    let (hash, lastValid) = try await rpc.latestBlockhash()
    let feeReply = try await rpc.call("getFeeForMessage", [try transfer(lamports, hash).base64EncodedString(), ["commitment": "confirmed"]]) as? [String: Any]
    guard let fee = (feeReply?["value"] as? NSNumber)?.uint64Value, lamports > fee else { throw WalletError("No fee quote, or nothing to move (\(lamports) lamports).") }
    let wire = SolanaTransaction.unsigned(try transfer(lamports - fee, hash))
    let signed = try await signer.signSolana(wire, accounts: try SolanaMessage.parse(transaction: wire).staticKeys, recipients: [destination], tokenOwners: [:])
    let signature = try await rpc.send(signed)
    print("Sent \(Fmt.num(Decimal(lamports - fee) / 1_000_000_000, maxFraction: 9)) SOL (fee \(fee) lamports): \(try await rpc.waitForConfirmation(signature, lastValidBlockHeight: lastValid)) https://solscan.io/tx/\(signature)")
    print("Left on \(me): \(try await rpc.balance(me)) lamports, \(try await rpc.tokenBalance(owner: me, mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")) USDC units.")
}

/// `sweep-near <new NEAR implicit account> --yes`: the old test wallet's NEAR to the new wallet's account in one plain
/// transfer. It keeps what the old account's own storage needs and a margin for the fee (a transfer's gas is tiny).
func sweepNear(to destination: String) async throws {
    let key = try TestWallet.nearKey()
    let me = try TestWallet.nearAccount()
    guard destination.wholeMatch(of: /[0-9a-f]{64}/) != nil, destination != me else { throw WalletError("Not a NEAR implicit account to move to: \(destination)") }
    let context = try await Near.txContext(account: me)
    let balance = UInt128(context.balance) ?? 0
    let keep = UInt128(context.storageBytes) * 10_000_000_000_000_000_000 + 1_000_000_000_000_000_000_000   // storage + 0.001 NEAR
    guard balance > keep else { throw WalletError("Nothing to move: \(NearTransaction.near(balance)) NEAR, \(NearTransaction.near(keep)) stays for storage.") }
    let amount = (balance - keep) / 1_000_000_000_000_000_000 * 1_000_000_000_000_000_000
    guard send else { print("Moves \(NearTransaction.near(amount)) NEAR from \(me) to \(destination). Add --yes."); return }
    let signed = try NearTransaction.sign(receiver: destination, nonce: context.nonce, blockHash: context.blockHash,
                                          actions: [.transfer(deposit: amount)], privateKey: key).signed
    let hash = try await Near.send(signed)
    print("Sent \(NearTransaction.near(amount)) NEAR to \(destination.prefix(8))…: https://nearblocks.io/txns/\(hash)")
}
