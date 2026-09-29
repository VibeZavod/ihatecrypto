import EVMChain
import GuardJev
import LalaCore
import SignerAPI
import SolanaChain
import SwiftUI
import TxGuard
import WalletCore
import WebKit

/// One request from a page, waiting for the user in the approval sheet.
struct SiteRequest: Identifiable {
    enum Kind { case connect, connectEVM, message(String), typedData(TypedData), transaction(TxReview, send: Bool), evmTransaction(EVMReview) }
    let id = UUID()
    let origin: String
    let site: SiteCheck.Verdict
    let kind: Kind
    let answer: CheckedContinuation<Bool, Never>
}

/// What a page's transaction would do, worked out before anything is signed.
struct TxReview {
    let wire: Data
    let accounts: [String]
    let tokenOwners: [String: String]
    /// Programs outside the built-in list: signed only if the user allows them here.
    let unknownPrograms: [String]
    let programNames: [String]
    let changes: [String]
    let checks: [String]
    /// Any entry: the transaction is refused, whatever the user clicks.
    let problems: [String]
    /// Jev's second opinion on the site and the transaction; it can only ask for an extra confirmation.
    var jev: JevReview?
    var jevNote: String?
}

/// An EVM transaction from a site, decoded and simulated before anything is signed.
struct EVMReview {
    let chain: UInt64
    let to: String
    let value: UInt64
    let data: Data
    /// What it does, in words: «Allow 0xabc… to spend up to 5 USDC».
    let lines: [String]
    /// Simulated change of each of our balances: «USDC (0xaf88…5831): +5».
    let changes: [String]
    /// A foreign address money goes to, which the user must confirm; nil when none.
    let recipient: String?
    let gas: UInt64
    let problems: [String]
    var jev: JevReview?
}

@Observable
final class Browser {
    let webView: WKWebView
    private let bridge = Bridge()
    var address = "https://jup.ag"
    var title = ""
    var pending: SiteRequest?
    var host = ""
    /// The last page that failed to load, shown under the address bar.
    var loadError: String?
    /// Origins the user connected in this session.
    private var connected: Set<String> = []
    private var connectedEVM: Set<String> = []
    /// EVM chain a site switched to (Arbitrum by default). Only reading goes to that chain's public RPC.
    private var evmChain: [String: UInt64] = [:]
    static let evmRPC: [UInt64: String] = [1: "https://ethereum-rpc.publicnode.com", 42161: "https://arb1.arbitrum.io/rpc", 8453: "https://mainnet.base.org"]
    /// arb1 crashes on eth_simulateV1; publicnode runs it but refuses receipts without a token (2026-09-29).
    static let evmSimulationRPC: [UInt64: String] = [42161: "https://arbitrum-one-rpc.publicnode.com"]
    static let readOnly: Set<String> = ["eth_call", "eth_blockNumber", "eth_getBalance", "eth_getCode", "eth_getTransactionCount", "eth_getTransactionReceipt",
                                        "eth_getTransactionByHash", "eth_estimateGas", "eth_gasPrice", "eth_feeHistory", "eth_getBlockByNumber",
                                        "eth_getLogs", "eth_maxPriorityFeePerGas", "eth_getStorageAt"]
    weak var workspace: Workspace?
    private let rpc = SolanaRPC()

    init() {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: ProviderScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "lala")
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        bridge.browser = self
    }

    func open(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if !t.contains("://") { t = "https://" + t }
        guard let url = URL(string: t) else { return }
        address = url.absoluteString
        if url.isFileURL { webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        else { webView.load(URLRequest(url: url)) }
    }

    func pageChanged() {
        title = webView.title ?? ""
        if let url = webView.url { address = url.absoluteString; host = url.host ?? "" }
    }

    // MARK: Requests from the page

    /// Every call from a page. `origin` comes from WebKit, not from the page, so a page cannot claim another's.
    func handle(_ method: String, _ params: [String: Any], origin: String, host: String) async throws -> Any {
        guard let owner = workspace?.signerWallet?.solana else {
            throw SiteError("The ihatecrypto wallet isn't in secure storage: save the key via “Addresses from phrase…”.")
        }
        let site = SiteCheck.check(host: host)
        // A site's signature is a move of its own: its Touch ID doesn't carry over to the next request.
        let signs = ["signMessage", "signTransaction", "signAndSendTransaction"].contains(method)
            || (method == "eth" && ["personal_sign", "eth_signTypedData_v4", "eth_sendTransaction"].contains(params["method"] as? String ?? ""))
        defer { if signs { workspace?.endSigningSession() } }
        switch method {
        case "eth":
            return try await ethereum(params["method"] as? String ?? "", params["params"] as? String ?? "[]", origin: origin, site: site)
        case "connect":
            if !connected.contains(origin) {
                if params["silent"] as? Bool == true { return NSNull() }
                guard await ask(.connect, origin: origin, site: site) else { throw SiteError("The user declined.") }
                connected.insert(origin)
            }
            return ["address": owner, "publicKey": try Base58.decode(owner).base64EncodedString()]
        case "disconnect":
            connected.remove(origin)
            return NSNull()
        case "signMessage":
            guard connected.contains(origin), let b64 = params["message"] as? String, let bytes = Data(base64Encoded: b64) else { throw SiteError("Connect the site first.") }
            let text = String(data: bytes, encoding: .utf8) ?? "(not text: \(bytes.count) bytes)"
            guard await ask(.message(text), origin: origin, site: site) else { throw SiteError("The user declined.") }
            let reply = try await SignerClient().send(.signSolanaMessage(message: bytes))
            guard reply.ok, let signature = reply.signatureBytes else { throw SiteError(XPCTradeSigner.reason(reply)) }
            return ["signature": signature.base64EncodedString()]
        case "signTransaction", "signAndSendTransaction":
            guard connected.contains(origin), let b64 = params["transaction"] as? String, let wire = Data(base64Encoded: b64) else { throw SiteError("Connect the site first.") }
            let send = method == "signAndSendTransaction"
            var review = try await review(wire, owner: owner)
            if let ws = workspace, ws.jevScreening, let key = ws.openRouterKey {
                review.jev = try? await JevReviewer.site(host: host.isEmpty ? origin : host, title: title, programs: review.programNames, changes: review.changes, apiKey: key)
                if review.jev == nil { review.jevNote = "Jev is unavailable — code checks decide." }
            } else {
                review.jevNote = "Jev isn't connected: sign in to OpenRouter in Settings. Code checks decide."
            }
            guard await ask(.transaction(review, send: send), origin: origin, site: site), review.problems.isEmpty else { throw SiteError("Transaction declined.") }
            let reply = try await SignerClient().send(.signSolana(wire: wire, accounts: review.accounts, recipients: [], tokenOwners: review.tokenOwners,
                                                                  extraPrograms: review.unknownPrograms))
            guard reply.ok, let signed = reply.signedWire else { throw SiteError(XPCTradeSigner.reason(reply)) }
            // The signer must return the page's transaction with only our signature added.
            let prefix = 1 + 64
            guard signed.count == wire.count, signed.subdata(in: prefix..<signed.count) == wire.subdata(in: prefix..<wire.count) else {
                throw SiteError("What was signed isn't what was checked.")
            }
            let signature = signed.subdata(in: 1..<65)
            workspace?.reply("Site \(origin): transaction signed\(send ? " and sent" : "") — \(Base58.encode(signature).prefix(12))…", note: "browser")
            if send {
                _ = try await rpc.send(signed)
                return ["signature": signature.base64EncodedString()]
            }
            return ["signed": signed.base64EncodedString()]
        default:
            throw SiteError("ihatecrypto doesn't support \(method).")
        }
    }

    /// EIP-1193 requests. Answers are JSON text; errors are "code|message".
    private func ethereum(_ method: String, _ paramsJSON: String, origin: String, site: SiteCheck.Verdict) async throws -> String {
        guard let address = workspace?.signerWallet?.evm else { throw SiteError("4100|The ihatecrypto wallet isn't in secure storage.") }
        let args = (try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8))) as? [Any] ?? []
        let chain = evmChain[origin] ?? 42161
        func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), as: UTF8.self) }
        func hex(_ s: EVMSignature) -> String { "0x" + s.r.hex + s.s.hex + String(format: "%02x", s.v) }
        switch method {
        case "eth_chainId": return try json("0x" + String(chain, radix: 16))
        case "net_version": return try json("\(chain)")
        case "eth_accounts": return try json(connectedEVM.contains(origin) ? [address] : [])
        case "eth_requestAccounts":
            if !connectedEVM.contains(origin) {
                guard await ask(.connectEVM, origin: origin, site: site) else { throw SiteError("4001|The user declined.") }
                connectedEVM.insert(origin)
            }
            return try json([address])
        case "wallet_switchEthereumChain":
            guard let id = (args.first as? [String: Any])?["chainId"] as? String, let n = UInt64(id.dropFirst(2), radix: 16), Self.evmRPC[n] != nil else {
                throw SiteError("4902|ihatecrypto works with Ethereum, Arbitrum and Base.")
            }
            evmChain[origin] = n
            return "null"
        case "personal_sign":
            guard connectedEVM.contains(origin), let raw = args.first as? String else { throw SiteError("4100|Connect the site first.") }
            let message = raw.hasPrefix("0x") ? (Data(hex: raw) ?? Data(raw.utf8)) : Data(raw.utf8)
            guard !PersonalMessage.isBlindHash(message) else { throw SiteError("4001|The site asks to sign a hash, not text: ihatecrypto doesn't sign that.") }
            guard await ask(.message(String(data: message, encoding: .utf8) ?? "\(message.count) bytes"), origin: origin, site: site) else { throw SiteError("4001|The user declined.") }
            let reply = try await SignerClient().send(.signPersonal(message: message))
            guard reply.ok, let s = reply.signature else { throw SiteError("4001|" + XPCTradeSigner.reason(reply)) }
            return try json(hex(s))
        case "eth_signTypedData_v4":
            guard connectedEVM.contains(origin), args.count >= 2 else { throw SiteError("4100|Connect the site first.") }
            let body: Data = if let s = args[1] as? String { Data(s.utf8) } else { try JSONSerialization.data(withJSONObject: args[1]) }
            let typed: TypedData
            do { typed = try TypedData.parse(body) } catch { throw SiteError("4200|\(error.localizedDescription)") }
            if typed.isTokenPermission {
                workspace?.reply("Site \(origin) asked for a “\(typed.primaryType)” signature — permission to spend your tokens. Declined: that's how drainers work.", note: "browser")
                throw SiteError("4001|Permission to spend tokens (Permit) — ihatecrypto doesn't sign that.")
            }
            guard await ask(.typedData(typed), origin: origin, site: site) else { throw SiteError("4001|The user declined.") }
            let reply = try await SignerClient().send(.signTypedData(json: body))
            guard reply.ok, let s = reply.signature else { throw SiteError("4001|" + XPCTradeSigner.reason(reply)) }
            return try json(hex(s))
        case "eth_sign":
            throw SiteError("4200|eth_sign signs a hash blindly — ihatecrypto doesn't support it.")
        case "eth_signTransaction":
            throw SiteError("4200|ihatecrypto signs EVM transactions only when it also sends them (eth_sendTransaction).")
        case "eth_sendTransaction":
            guard connectedEVM.contains(origin), let p = args.first as? [String: Any] else { throw SiteError("4100|Connect the site first.") }
            guard let to = p["to"] as? String, Data(hex: to)?.count == 20 else { throw SiteError("4200|ihatecrypto doesn't sign contract creation.") }
            guard (p["from"] as? String)?.lowercased() ?? address.lowercased() == address.lowercased() else { throw SiteError("4100|The sender isn't your address.") }
            let data = Data(hex: (p["data"] ?? p["input"]) as? String ?? "0x") ?? Data()
            guard let value = Self.quantity(p["value"]) else { throw SiteError("4200|The amount is larger than ihatecrypto will sign.") }
            guard let url = Self.evmRPC[chain].flatMap(URL.init(string:)) else { throw SiteError("4901|No RPC for chain \(chain).") }
            let rpc = EVMRPC(url: url, chainId: chain)
            var review = await evmReview(to: to, value: value, data: data, from: address, rpc: rpc)
            if let ws = workspace, ws.jevScreening, let key = ws.openRouterKey {
                review.jev = try? await JevReviewer.site(host: host(origin), title: title, programs: ["EVM \(chain): \(to)"], changes: review.lines + review.changes, apiKey: key)
            }
            guard await ask(.evmTransaction(review), origin: origin, site: site), review.problems.isEmpty else {
                if let refusal = review.problems.first { workspace?.reply("Site \(origin): EVM transaction declined — \(refusal)", note: "browser") }
                throw SiteError("4001|" + (review.problems.first ?? "The user declined."))
            }
            let nonce = try await rpc.nonce(address)
            let fees = try await rpc.fees()
            let reply = try await SignerClient().send(.signEVMTransaction(chainId: chain, nonce: nonce, maxPriorityFee: fees.maxPriority, maxFee: fees.maxFee,
                                                                         gasLimit: review.gas, to: to, value: value, data: data,
                                                                         recipients: review.recipient.map { [$0] } ?? []))
            guard reply.ok, let raw = reply.signedRaw else { throw SiteError("4001|" + XPCTradeSigner.reason(reply)) }
            do {
                let hash = try await rpc.send(raw)
                workspace?.reply("Site \(origin): EVM transaction sent on chain \(chain) — \(hash.prefix(14))…", note: "browser")
                return try json(hash)
            } catch {
                throw SiteError("-32000|The network rejected the transaction: \(error.localizedDescription)")
            }
        case let m where Self.readOnly.contains(m):
            guard let url = Self.evmRPC[chain].flatMap(URL.init(string:)) else { throw SiteError("4901|No RPC for chain \(chain).") }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": m, "params": args])
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SiteError("4900|The RPC didn't respond.") }
            if let e = j["error"] as? [String: Any] { throw SiteError("-32000|\(e["message"] ?? "RPC error")") }
            return try json(j["result"] ?? NSNull())
        default:
            throw SiteError("4200|ihatecrypto doesn't support \(method).")
        }
    }

    private func host(_ origin: String) -> String { URL(string: origin)?.host ?? origin }

    /// A JSON-RPC quantity ("0x…") as UInt64; nil when it does not fit.
    static func quantity(_ v: Any?) -> UInt64? {
        guard let s = v as? String, s.hasPrefix("0x") else { return v == nil ? 0 : (v as? NSNumber)?.uint64Value }
        return s == "0x" ? 0 : UInt64(s.dropFirst(2), radix: 16)
    }

    /// Decodes, names the token, simulates the balance changes and estimates gas. Problems mean «do not sign».
    func evmReview(to: String, value: UInt64, data: Data, from: String, rpc: EVMRPC) async -> EVMReview {
        let call = EVMCall.decode(data)
        var problems = call.refusal(sender: from).map { [$0] } ?? []
        var lines: [String] = []
        var recipient: String?
        let native = rpc.chainId == 42161 || rpc.chainId == 1 || rpc.chainId == 8453 ? "ETH" : "coins"
        func token(_ to: String) async -> (symbol: String, decimals: Int) {
            let symbol = (try? await rpc.call("eth_call", [["to": to, "data": "0x95d89b41"], "latest"]) as? String).flatMap { hex -> String? in
                guard let d = Data(hex: hex), d.count >= 96 else { return nil }
                let length = Int(d[d.startIndex + 63])
                return String(data: d.dropFirst(64).prefix(length), encoding: .utf8)
            } ?? "token \(to.prefix(8))…"
            let decimals = (try? await rpc.call("eth_call", [["to": to, "data": "0x313ce567"], "latest"]) as? String).flatMap { UInt64($0.dropFirst(2), radix: 16) } ?? 18
            return (symbol, Int(decimals))
        }
        func amount(_ word: Data, _ decimals: Int) -> String {
            let n = word.reduce(Decimal(0)) { $0 * 256 + Decimal($1) }
            return Fmt.num(n / Decimal(sign: .plus, exponent: decimals, significand: 1), maxFraction: 6)
        }
        switch call {
        case .plain:
            lines.append("Transfer \(Fmt.num(Decimal(value) / 1_000_000_000_000_000_000, maxFraction: 8)) \(native) to \(to).")
            if to.lowercased() != from.lowercased() { recipient = to }
        case .approve(let spender, let a), .increaseAllowance(let spender, let a):
            let t = await token(to)
            lines.append("Allow \(spender) to spend up to \(amount(a, t.decimals)) \(t.symbol).")
        case .transfer(let r, let a):
            let t = await token(to)
            lines.append("Transfer \(amount(a, t.decimals)) \(t.symbol) to \(r).")
            if r.lowercased() != from.lowercased() { recipient = r }
        case .transferFrom(let f, let r, let a):
            let t = await token(to)
            lines.append("Move \(amount(a, t.decimals)) \(t.symbol) from \(f) to \(r).")
        case .setApprovalForAll(let op, let on):
            lines.append("\(on ? "Rights to all NFTs" : "Revoke NFT rights") for \(op).")
        case .permit:
            lines.append("Call to permit (permission to spend).")
        case .swap(let r):
            lines.append("Uniswap swap paying \(r.lowercased() == from.lowercased() ? "this wallet" : r).")
        case .vault(let r, let owner):
            lines.append("Vault \(owner == nil ? "deposit" : "withdrawal") crediting \(r.lowercased() == from.lowercased() ? "this wallet" : r).")
        case .lending(let b):
            lines.append("Lending pool call (Aave supply or withdraw) crediting \(b.lowercased() == from.lowercased() ? "this wallet" : b).")
        case .contract(let selector):
            lines.append("Contract call \(to), function \(selector)\(value > 0 ? ", with \(Fmt.num(Decimal(value) / 1_000_000_000_000_000_000, maxFraction: 8)) \(native)" : "").")
        }
        var changes: [String] = []
        let simulator = Self.evmSimulationRPC[rpc.chainId].flatMap(URL.init(string:)).map { EVMRPC(url: $0, chainId: rpc.chainId) } ?? rpc
        do {
            let sim = try await simulator.simulate(from: from, to: to, value: value, data: data)
            if let revert = sim.revert { problems.append("Simulation: the call would revert — \(revert)") }
            for (asset, delta) in sim.changes.sorted(by: { $0.key < $1.key }) {
                if asset == EVMSimulation.native { changes.insert("\(native): \(signed(delta / 1_000_000_000_000_000_000))", at: 0); continue }
                let t = await token(asset)
                let name = "\(t.symbol)\(sim.nfts.contains(asset) ? " NFT" : "") (\(asset.prefix(6))…\(asset.suffix(4)))"
                changes.append("\(name): \(signed(sim.nfts.contains(asset) ? delta : delta / Decimal(sign: .plus, exponent: t.decimals, significand: 1)))")
            }
            if sim.revert == nil, changes.isEmpty { changes.append("None of your balances change.") }
        } catch {
            // The node can't simulate: at least check that the call doesn't revert.
            changes.append("Unavailable: \(error.localizedDescription)")
            let tx: [String: Any] = ["from": from, "to": to, "value": "0x" + String(value, radix: 16), "data": "0x" + data.hex]
            do { _ = try await rpc.call("eth_call", [tx, "latest"]) } catch {
                problems.append("Simulation: the call would revert — \(error.localizedDescription)")
            }
        }
        var gas: UInt64 = 0
        if problems.isEmpty {
            do {
                gas = try await rpc.estimateGas(from: from, to: to, value: value, data: data) * 12 / 10
                if let fees = try? await rpc.fees() {
                    lines.append("Network fee up to \(Fmt.num(Decimal(gas) * Decimal(fees.maxFee) / 1_000_000_000_000_000_000, maxFraction: 8)) \(native).")
                }
            } catch {
                problems.append("Couldn't estimate gas: \(error.localizedDescription)")
            }
        }
        return EVMReview(chain: rpc.chainId, to: to, value: value, data: data, lines: lines, changes: changes, recipient: recipient, gas: gas, problems: problems)
    }

    private func ask(_ kind: SiteRequest.Kind, origin: String, site: SiteCheck.Verdict) async -> Bool {
        #if DEBUG
        // `-browserAutoApprove YES` (Debug builds): only for local test pages, and never over a refusal.
        if UserDefaults.standard.bool(forKey: "browserAutoApprove"), origin.hasPrefix("file://") {
            if case .transaction(let r, _) = kind { return r.problems.isEmpty }
            if case .evmTransaction(let r) = kind { return r.problems.isEmpty }
            return true
        }
        // `-browserAutoConnect YES`: local test pages only, connect and text only — transactions still ask.
        if UserDefaults.standard.bool(forKey: "browserAutoConnect"), origin.hasPrefix("file://") {
            if case .transaction = kind {} else { return true }
        }
        #endif
        return await withCheckedContinuation { continuation in
            pending = SiteRequest(origin: origin, site: site, kind: kind, answer: continuation)
        }
    }

    func answer(_ yes: Bool) {
        let request = pending
        pending = nil
        request?.answer.resume(returning: yes)
    }

    // MARK: Transaction review

    /// Programs, the guard's verdict and the simulated change of every balance of ours the transaction touches.
    func review(_ wire: Data, owner: String) async throws -> TxReview {
        let message = try SolanaMessage.parse(transaction: wire)
        let accounts = try await rpc.resolveAccounts(message)
        let programs = Set(message.instructions.compactMap { $0.programIndex < accounts.count ? accounts[$0.programIndex] : nil })
        let unknown = programs.filter { SolanaGuard.knownPrograms[$0] == nil }.sorted()
        var allowed = SolanaGuard.knownPrograms
        for p in unknown { allowed[p] = "unknown program \(p.prefix(6))…" }
        let tokens = try await tokenAccounts(owner)
        let touched = tokens.filter { accounts.contains($0.key) }
        let owners = touched.mapValues { _ in owner }
        let verdict = SolanaGuard.check(message, accounts: accounts,
                                        policy: SolanaPolicy(owner: owner, programs: allowed, trustLookupTables: false), tokenOwners: owners)
        let solBefore = try await rpc.balance(owner)
        let simulation = try await rpc.simulate(wire, watch: [owner] + touched.keys, sigVerify: false)
        var problems = verdict.problems
        var changes: [String] = []
        if let error = simulation.error {
            problems.append("Simulation failed: \(error).")
        } else {
            let solAfter = simulation.after[owner]?.lamports ?? solBefore
            changes.append("SOL: \(signed(Decimal(Int64(solAfter) - Int64(solBefore)) / 1_000_000_000))")
            for (address, t) in touched.sorted(by: { $0.key < $1.key }) {
                let after = simulation.after[address]?.token ?? t.amount
                let scale = Decimal(sign: .plus, exponent: t.decimals, significand: 1)
                let delta = Decimal(Int64(after) - Int64(t.amount)) / scale
                if delta != 0 { changes.append("\(symbol(t.mint)): \(signed(delta))") }
            }
        }
        let names = programs.sorted().map { SolanaGuard.knownPrograms[$0] ?? "unknown \($0.prefix(8))…" }
        return TxReview(wire: wire, accounts: accounts, tokenOwners: owners, unknownPrograms: unknown, programNames: names,
                        changes: changes, checks: verdict.checks, problems: problems)
    }

    private func signed(_ d: Decimal) -> String { (d > 0 ? "+" : d < 0 ? "−" : "") + Fmt.num(abs(d), maxFraction: 9) }

    private func symbol(_ mint: String) -> String {
        if mint == "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v" { return "USDC" }
        if let a = SpotAsset.all.first(where: { $0.mint == mint }) { return a.symbol }
        return "token \(mint.prefix(6))…"
    }

    /// Our SPL token accounts: address → mint, raw amount, decimals.
    private func tokenAccounts(_ owner: String) async throws -> [String: (mint: String, amount: UInt64, decimals: Int)] {
        let r = try await rpc.call("getTokenAccountsByOwner", [owner, ["programId": SPL.tokenProgram], ["encoding": "jsonParsed", "commitment": "confirmed"]]) as? [String: Any]
        var out: [String: (String, UInt64, Int)] = [:]
        for item in r?["value"] as? [[String: Any]] ?? [] {
            guard let address = item["pubkey"] as? String,
                  let info = ((((item["account"] as? [String: Any])?["data"] as? [String: Any])?["parsed"] as? [String: Any])?["info"] as? [String: Any]),
                  let mint = info["mint"] as? String, let amount = info["tokenAmount"] as? [String: Any] else { continue }
            out[address] = (mint, UInt64(amount["amount"] as? String ?? "0") ?? 0, (amount["decimals"] as? NSNumber)?.intValue ?? 0)
        }
        return out
    }

    /// WebKit's side: page messages in, answers out as the promise's value or error.
    final class Bridge: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        weak var browser: Browser?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            guard let browser, message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let method = body["method"] as? String else {
                return (nil, "Request not accepted.")
            }
            let o = message.frameInfo.securityOrigin
            let origin = o.host.isEmpty ? "\(o.protocol)://" : "\(o.protocol)://\(o.host)\(o.port > 0 ? ":\(o.port)" : "")"
            do {
                return (try await browser.handle(method, body["params"] as? [String: Any] ?? [:], origin: origin, host: o.host), nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { browser?.loadError = nil; browser?.pageChanged() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            browser?.loadError = "The page process crashed; press Reload."
            FileHandle.standardError.write(Data("LALA browser: web content process terminated\n".utf8))
        }

        private func failed(_ error: Error) {
            let e = error as NSError
            // Cancelled loads (a redirect replaced them) are not failures.
            guard e.code != NSURLErrorCancelled else { return }
            browser?.loadError = "The page didn't load: \(e.localizedDescription) (\(e.domain) \(e.code))"
            FileHandle.standardError.write(Data("LALA browser: \(browser?.loadError ?? "")\n".utf8))
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { browser?.pageChanged() }
    }

    func attachDelegate() { webView.navigationDelegate = bridge }
}

struct SiteError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Window

struct BrowserView: View {
    @Environment(Workspace.self) private var ws
    @State private var typed = ""

    var body: some View {
        let browser = ws.browser
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }.buttonStyle(.hoverIcon)
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.hoverIcon)
                siteBadge(SiteCheck.check(host: browser.host))
                TextField("Site address", text: $typed)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.fill.tertiary))
                    .onSubmit { browser.open(typed) }
                Text(ws.signerWallet.map { "wallet \($0.solana.prefix(4))…\($0.solana.suffix(4))" } ?? "no key")
                    .font(.ui(10)).foregroundStyle(.secondary)
            }
            .padding(10)
            if let error = browser.loadError {
                Text(error).font(.ui(10)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 6)
            }
            WebViewHost(webView: browser.webView)
        }
        .frame(minWidth: 900, minHeight: 700)
        .onAppear {
            browser.workspace = ws
            browser.attachDelegate()
            if browser.webView.url == nil { browser.open(UserDefaults.standard.string(forKey: "openBrowser") ?? browser.address) }
            typed = browser.address
        }
        .onChange(of: browser.address) { typed = browser.address }
        .sheet(item: Binding(get: { browser.pending }, set: { if $0 == nil, browser.pending != nil { browser.answer(false) } })) { request in
            ApprovalSheet(request: request) { browser.answer($0) }
        }
    }

    @ViewBuilder private func siteBadge(_ verdict: SiteCheck.Verdict) -> some View {
        switch verdict {
        case .known: Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("Known site")
        case .lookalike(let real): Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red).help("Looks like \(real), but it's a different address")
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.orange).help("Unfamiliar site: check the address")
        case .local: Image(systemName: "doc").foregroundStyle(.secondary)
        }
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// What the site asks for, in words, with the simulated effect of a transaction. Refusals cannot be overridden.
struct ApprovalSheet: View {
    let request: SiteRequest
    let decide: (Bool) -> Void
    @State private var allowUnknown = false
    @State private var trustLookalike = false
    @State private var acknowledgeJev = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(heading).font(.ui(20, .semibold))
            Text(request.origin).font(.system(.body, design: .monospaced))
            switch request.site {
            case .known: Label("Known site", systemImage: "checkmark.seal").foregroundStyle(.green)
            case .lookalike(let real):
                Label("The address looks like \(real), but it's a different site — a common phishing trick.", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                Toggle("I understand this isn't \(real)", isOn: $trustLookalike)
            case .unknown: Label("Unfamiliar site: make sure the address is right.", systemImage: "questionmark.circle").foregroundStyle(.orange)
            case .local: EmptyView()
            }
            switch request.kind {
            case .connect:
                Text("The site will see your Solana address. It can't get anything signed without a separate confirmation.")
            case .connectEVM:
                Text("The site will see your EVM address (also your Hyperliquid address). ihatecrypto never signs token spending permissions (Permit).")
            case .evmTransaction(let r):
                Text("Network \(["1": "Ethereum", "42161": "Arbitrum", "8453": "Base"]["\(r.chain)"] ?? "\(r.chain)")").font(.ui(12, .semibold))
                section("What it does") { ForEach(r.lines, id: \.self) { Text("· " + $0) } }
                section("What changes (simulation)") { ForEach(r.changes, id: \.self) { Text("· " + $0) } }
                if let jev = r.jev {
                    Label(jev.text, systemImage: jev.concern ? "exclamationmark.triangle.fill" : "checkmark.seal")
                        .foregroundStyle(jev.concern ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    if jev.concern { Toggle("I understand Jev's warning", isOn: $acknowledgeJev) }
                }
                if !r.problems.isEmpty {
                    section("Refused") { ForEach(r.problems, id: \.self) { Label($0, systemImage: "xmark.octagon").foregroundStyle(.red) } }
                } else if let to = r.recipient {
                    Toggle("Send to \(to.prefix(10))…\(to.suffix(6))", isOn: $allowUnknown)
                }
                Text("Changes are simulated on the latest block, before the network fee. A token names itself — check its address. The signer decodes the calldata again.").font(.ui(10)).foregroundStyle(.secondary)
            case .typedData(let t):
                Text("\(t.primaryType) for “\(t.domainName)”, chain \(t.chainId)").font(.ui(12, .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(t.fields.indices, id: \.self) { i in
                            Text("\(t.fields[i].name): \(t.fields[i].value)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160)
                Text("The signer computes the hash to sign from this same data. It rejects nested structures and token permissions.").font(.ui(10)).foregroundStyle(.secondary)
            case .message(let text):
                Text("Text to sign").font(.ui(10, .semibold)).foregroundStyle(.secondary)
                ScrollView { Text(text).font(.system(.callout, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 140)
                Text("Signing text doesn't move money. The signer rejects the “text” if it's a hidden transaction.").font(.ui(10)).foregroundStyle(.secondary)
            case .transaction(let r, let send):
                section("What changes (simulation)") { ForEach(r.changes, id: \.self) { Text("· " + $0) } }
                section("Programs") { ForEach(r.programNames, id: \.self) { Text("· " + $0) } }
                if !r.checks.isEmpty { section("Checks") { ForEach(r.checks, id: \.self) { Label($0, systemImage: "checkmark") } } }
                if let jev = r.jev {
                    Label(jev.text, systemImage: jev.concern ? "exclamationmark.triangle.fill" : "checkmark.seal")
                        .foregroundStyle(jev.concern ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    if jev.concern { Toggle("I understand Jev's warning", isOn: $acknowledgeJev) }
                } else if let note = r.jevNote {
                    Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
                }
                if !r.problems.isEmpty {
                    section("Refused") { ForEach(r.problems, id: \.self) { Label($0, systemImage: "xmark.octagon").foregroundStyle(.red) } }
                } else if !r.unknownPrograms.isEmpty {
                    Toggle("Allow \(r.unknownPrograms.count == 1 ? "an unknown program" : "unknown programs") for this transaction", isOn: $allowUnknown)
                }
                Text(send ? "After signing, ihatecrypto sends the transaction to the network." : "The site gets the signed transaction and sends it itself.").font(.ui(10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Decline") { decide(false) }.keyboardShortcut(.cancelAction)
                Button(approveTitle) { decide(true) }.keyboardShortcut(.defaultAction).disabled(!canApprove)
            }
        }
        .font(.ui(13))
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: 320)
    }

    private var heading: String {
        switch request.kind {
        case .connect, .connectEVM: "Connect site"
        case .message: "Sign text"
        case .typedData: "Sign data"
        case .evmTransaction: "Sign EVM transaction"
        case .transaction: "Sign transaction"
        }
    }

    private var approveTitle: String {
        if case .connect = request.kind { return "Connect" }
        if case .connectEVM = request.kind { return "Connect" }
        return "Sign"
    }

    private var canApprove: Bool {
        if case .lookalike = request.site, !trustLookalike { return false }
        if case .transaction(let r, _) = request.kind {
            return r.problems.isEmpty && (r.unknownPrograms.isEmpty || allowUnknown) && (r.jev?.concern != true || acknowledgeJev)
        }
        if case .evmTransaction(let r) = request.kind {
            return r.problems.isEmpty && (r.recipient == nil || allowUnknown) && (r.jev?.concern != true || acknowledgeJev)
        }
        return true
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(10, .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
