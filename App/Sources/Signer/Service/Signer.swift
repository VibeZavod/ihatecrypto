import CryptoKit
import EVMChain
import Foundation
import HyperliquidSigning
import SignerAPI
import SolanaChain
import TxGuard
import WalletCore

/// Everything that needs the seed happens here, after the guard. The app is not trusted with more than it
/// must supply: approved recipients (the user approved them in the app) and lookup-table contents (the signer
/// has no network). Token-account owners it claims are re-derived here, and with presence on, the system
/// prompt shows what the signer itself parsed, so a lying app is visible to the user.
enum Signer {
    /// Public addresses live in the service's sandbox defaults so status never touches the seed.
    static var defaults: UserDefaults { .standard }

    static func handle(_ request: SignerRequest) throws -> SignerReply {
        switch request {
        case .status:
            var r = SignerReply(ok: true)
            let wallets = Wallets.all
            r.hasWallet = !wallets.isEmpty
            r.wallets = wallets
            r.activeWallet = Wallets.active?.id
            r.solanaAddress = defaults.string(forKey: "solana")
            r.evmAddress = defaults.string(forKey: "evm")
            r.nearAddress = defaults.string(forKey: "near")
            r.agentAddress = AgentStore.load().flatMap { try? EVMAccount.address(privateKey: $0) }
            r.agentActive = defaults.bool(forKey: agentActiveKey) && r.agentAddress != nil
            r.sessionLength = SeedStore.sessionLength
            return r

        case .enableAgent:
            let owner = try address("evm")
            var agentKey = AgentStore.load()
            if agentKey == nil {
                agentKey = try AgentStore.make()
                try AgentStore.save(agentKey!)
            }
            let agent = try EVMAccount.address(privateKey: agentKey!)
            guard agent.lowercased() != owner.lowercased() else { throw WalletError("The agent key matches the main key.") }
            let nonce = UInt64(Date().timeIntervalSince1970 * 1000)
            let (action, signature) = try withKey("evm", reason: "approve a trading key: orders without Touch ID; it can't withdraw money") {
                try HLSigner.approveAgent(agent: agent, name: "lala", nonce: nonce, privateKey: $0, mainnet: true)
            }
            var r = SignerReply(ok: true)
            r.agentAddress = agent
            r.action = action
            r.signature = signature
            r.nonce = nonce
            r.checks = ["Approving an agent key created inside the signer: it can trade but not withdraw."]
            return r

        case .setAgentActive(let on):
            // Resuming a paused trading key is the user's decision: it asks for Touch ID like a signature.
            if on, !defaults.bool(forKey: agentActiveKey), AgentStore.load() != nil {
                try withKey("evm", reason: "turn the Hyperliquid trading key back on") { _ in }
            }
            defaults.set(on && AgentStore.load() != nil, forKey: agentActiveKey)
            var r = SignerReply(ok: true)
            r.agentActive = defaults.bool(forKey: agentActiveKey)
            return r

        case .createWallet(let requirePresence):
            // Without Touch ID it can only be a test wallet: a phrase made here and now, never one imported with money on it.
            let phrase = Mnemonic.generate()
            try confirmInPerson(requirePresence ? "add a new wallet to ihatecrypto and sign with it"
                                                : "add a TEST wallet that signs WITHOUT Touch ID — keep only a few dollars on it")
            var r = try store(phrase: phrase, passphrase: "", requirePresence: requirePresence, test: !requirePresence)
            r.phrase = phrase
            return r

        case .createAutomationWallet:
            // Next to a Touch ID wallet only, and one: it's a budget beside the real money, never the only key.
            guard !Wallets.all.isEmpty, !Wallets.all.contains(where: \.isAutomation) else {
                throw WalletError(Wallets.all.isEmpty ? "Add your main wallet first." : "There is an automation wallet already.")
            }
            try confirmInPerson("add an AUTOMATION wallet: scheduled tasks sign with it WITHOUT Touch ID — keep only their budget on it")
            return try store(phrase: Mnemonic.generate(), passphrase: "", requirePresence: false, test: true, automation: true)

        case .asWallet(let id, let inner):
            guard let wallet = Wallets.all.first(where: { $0.id == id }), wallet.isAutomation else {
                throw WalletError("Only the automation wallet signs for a scheduled task.")
            }
            switch inner {
            case .signSolana, .signEVMTransaction, .signHyperliquidL1, .signHyperliquidUser, .signRelayNonceMapping,
                 .signNearIntentDeposit, .signNearTransfer: break
            default: throw WalletError("The automation wallet signs only a task's moves.")
            }
            return try Wallets.$signing.withValue(wallet) { try handle(inner) }

        case .importMnemonic(let phrase, let passphrase, let requirePresence):
            _ = try Mnemonic.validate(phrase) // a mistyped phrase fails before any prompt
            try confirmInPerson("add a wallet from a recovery phrase to ihatecrypto and sign with it")
            return try store(phrase: phrase, passphrase: passphrase, requirePresence: requirePresence)

        case .importPrivateKey(let text):
            let imported = try ImportedKey.parse(text) // a malformed key fails before any prompt
            let address = try imported.address()
            try confirmInPerson("add the \(imported.chain) key of \(address) to ihatecrypto and sign with it")
            return switch imported {
            case .solana(let secret): try add(secret: secret, kind: "solana", solana: address, evm: nil, near: nil, requirePresence: true)
            case .evm(let secret): try add(secret: secret, kind: "evm", solana: nil, evm: address, near: nil, requirePresence: true)
            }

        case .setActiveWallet(let id):
            guard let wallet = Wallets.all.first(where: { $0.id == id }) else { throw WalletError("No such wallet.") }
            // Which wallet signs, and whose addresses LALA shows for deposits, is the user's call in person.
            if wallet.id != Wallets.active?.id { try confirmInPerson("sign with the wallet «\(wallet.label)» from now on:\n\(addresses(wallet))") }
            Wallets.activate(wallet)
            var r = SignerReply(ok: true)
            r.wallets = Wallets.all
            r.activeWallet = wallet.id
            return r

        case .removeWallet(let id):
            guard let wallet = Wallets.all.first(where: { $0.id == id }) else { throw WalletError("No such wallet.") }
            try confirmInPerson("REMOVE the wallet «\(wallet.label)» from ihatecrypto: without its phrase or key its money can't be reached from here\n\(addresses(wallet))")
            remove(wallet)
            var r = SignerReply(ok: true)
            r.wallets = Wallets.all
            r.activeWallet = Wallets.active?.id
            return r

        case .renameWallet(let id, let label):
            let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 32 else { throw WalletError("A wallet's name is 1 to 32 characters.") }
            var list = Wallets.all
            guard let i = list.firstIndex(where: { $0.id == id }) else { throw WalletError("No such wallet.") }
            list[i].label = name
            Wallets.save(list)
            var r = SignerReply(ok: true)
            r.wallets = list
            r.activeWallet = Wallets.active?.id
            return r

        case .nearAddress:
            var r = SignerReply(ok: true)
            if let known = defaults.string(forKey: "near") {
                r.nearAddress = known
            } else {
                // A phrase wallet imported before NEAR: derive once (one unlock), then keep it with the wallet.
                let near = try withKey("near", reason: "show your NEAR address, derived from your phrase") { try NearAccount.implicit(privateKey: $0) }
                defaults.set(near, forKey: "near")
                var list = Wallets.all
                if let i = list.firstIndex(where: { $0.id == Wallets.activeID }) { list[i].near = near; Wallets.save(list) }
                r.nearAddress = near
            }
            return r

        case .ledgerAgent(let owner, let create):
            let id = try ledgerAgentID(owner)
            var key = AgentStore.load(id: id)
            if key == nil, create {
                key = try AgentStore.make()
                try AgentStore.save(key!, id: id)
            }
            var r = SignerReply(ok: true)
            r.agentAddress = key.flatMap { try? EVMAccount.address(privateKey: $0) }
            r.agentActive = r.agentAddress != nil && defaults.string(forKey: "agentActive-" + id) == "on"
            return r

        case .setLedgerAgentActive(let owner, let on):
            let id = try ledgerAgentID(owner)
            guard AgentStore.load(id: id) != nil else { throw WalletError("This Ledger has no trading key yet: approve one on the Ledger first.") }
            // Back on after a lock is the user's decision, as for a wallet's own key.
            if on, defaults.string(forKey: "agentActive-" + id) == "paused" {
                try SeedStore.confirm("turn the Hyperliquid trading key of your Ledger \(owner) back on")
            }
            defaults.set(on ? "on" : "paused", forKey: "agentActive-" + id)
            var r = SignerReply(ok: true)
            r.agentActive = on
            return r

        case .signLedgerAgentL1(let owner, let action, let nonce):
            let id = try ledgerAgentID(owner)
            guard HLSigner.isTrading(action) else {
                var v = Verdict()
                v.problems.append("The Ledger's trading key signs orders, cancels and leverage only; anything else is signed on the Ledger.")
                return refused(v)
            }
            guard defaults.string(forKey: "agentActive-" + id) == "on", var agent = AgentStore.load(id: id) else {
                throw WalletError("The Ledger's trading key is off: approve it on the Ledger, or turn it back on.")
            }
            defer { SeedStore.wipe(&agent) }
            let verdict = HLGuard.check(action, owner: owner, recipients: [])
            guard verdict.ok else { return refused(verdict) }
            var r = SignerReply(ok: true)
            r.signature = try HLSigner.signL1(action, privateKey: agent, nonce: nonce, mainnet: true)
            r.checks = verdict.checks
            return r

        case .lock:
            SeedStore.endSession()
            defaults.set(false, forKey: agentActiveKey)
            // A Ledger's trading keys pause too: turning one back on asks for Touch ID.
            for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("agentActive-ledger-") && value as? String == "on" {
                defaults.set("paused", forKey: key)
            }
            var r = SignerReply(ok: true)
            r.agentActive = false
            r.checks = ["Touch ID session ended; the trading key is paused."]
            return r

        case .setSessionLength(let seconds):
            guard SignerSession.choices.contains(seconds) else { throw WalletError("Touch ID can stay valid for 1, 5, 15 or 30 minutes.") }
            if seconds > SeedStore.sessionLength {
                try SeedStore.confirm("keep Touch ID valid for \(seconds / 60) min after each confirmation")
            }
            defaults.set(seconds, forKey: "sessionLength")
            SeedStore.endSession()
            var r = SignerReply(ok: true)
            r.sessionLength = seconds
            return r

        case .endSession:
            SeedStore.endSession()
            return SignerReply(ok: true)

        case .signNearIntentDeposit(let amount, let depositAddress, let nonce, let blockHash):
            guard let yocto = UInt128(amount), yocto > 0 else { throw WalletError("Not a NEAR amount: \(amount).") }
            guard depositAddress.wholeMatch(of: /[0-9a-f]{64}/) != nil else { throw WalletError("Not a 1Click deposit account: \(depositAddress).") }
            guard blockHash.count == 32 else { throw WalletError("A NEAR block hash is 32 bytes.") }
            try approve([depositAddress])
            var r = SignerReply(ok: true)
            r.signedRaw = try withNearKey(reason: "sell \(NearTransaction.near(yocto)) NEAR: wrapped and sent to the 1Click deposit \(depositAddress.prefix(8))…\(depositAddress.suffix(6))") { nearSecret, account in
                try NearTransaction.sign(receiver: NearTransaction.wrapContract, nonce: nonce, blockHash: blockHash,
                                         actions: NearTransaction.intentDeposit(account: account, depositAddress: depositAddress, amount: yocto),
                                         privateKey: nearSecret).signed
            }
            r.checks = ["\(NearTransaction.near(yocto)) NEAR → wNEAR → \(depositAddress) (1Click)"]
            return r

        case .signNearTransfer(let amount, let receiver, let recipients, let nonce, let blockHash):
            guard let yocto = UInt128(amount), yocto > 0 else { throw WalletError("Not a NEAR amount: \(amount).") }
            try checkNearRecipient(receiver, recipients, blockHash)
            try approve([receiver])
            var r = SignerReply(ok: true)
            r.signedRaw = try withNearKey(reason: "send \(NearTransaction.near(yocto)) NEAR to \(receiver)") { nearSecret, account in
                guard receiver != account else { throw WalletError("That is this wallet's own NEAR account.") }
                return try NearTransaction.sign(receiver: receiver, nonce: nonce, blockHash: blockHash, actions: [.transfer(deposit: yocto)], privateKey: nearSecret).signed
            }
            r.checks = ["\(NearTransaction.near(yocto)) NEAR → \(receiver)"]
            return r

        case .signNearDeleteAccount(let beneficiary, let recipients, let nonce, let blockHash):
            try checkNearRecipient(beneficiary, recipients, blockHash)
            try approve([beneficiary])
            // Always a fresh prompt, whatever Touch ID session is open: this empties and removes the account.
            try SeedStore.confirm("DELETE your NEAR account and send all the NEAR on it to \(beneficiary)")
            let (raw, account) = try withNearKey(reason: "delete your NEAR account into \(beneficiary)") { nearSecret, account in
                guard beneficiary != account else { throw WalletError("An account can't be deleted into itself.") }
                return (try NearTransaction.sign(receiver: account, nonce: nonce, blockHash: blockHash,
                                                 actions: [.deleteAccount(beneficiary: beneficiary)], privateKey: nearSecret).signed, account)
            }
            var r = SignerReply(ok: true)
            r.signedRaw = raw
            r.checks = ["NEAR account \(account.prefix(8))… deleted into \(beneficiary)"]
            return r

        case .forget:
            guard let wallet = Wallets.active else { return SignerReply(ok: true) }
            try confirmInPerson("remove the wallet «\(wallet.label)» from ihatecrypto")
            remove(wallet)
            return SignerReply(ok: true)

        case .signSolanaMessage(let message):
            // A «message» that parses as a transaction would be a signed transaction once returned.
            guard (try? SolanaMessage.parse(message: message)) == nil, let text = String(data: message, encoding: .utf8),
                  !text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else {
                var v = Verdict()
                v.problems.append("This isn't text but data that looks like a transaction: message signing refused.")
                return refused(v)
            }
            var r = SignerReply(ok: true)
            r.signatureBytes = try withKey("solana", reason: "sign text for a site:\n" + String(text.prefix(160))) {
                try Curve25519.Signing.PrivateKey(rawRepresentation: $0).signature(for: message)
            }
            r.checks = ["Only text was signed, not a transaction."]
            return r

        case .signPersonal(let message):
            guard !PersonalMessage.isBlindHash(message) else {
                var v = Verdict()
                v.problems.append("The site asks to sign a hash, not text: such a signature could authorize anything.")
                return refused(v)
            }
            let text = String(data: message, encoding: .utf8) ?? "\(message.count) bytes"
            var r = SignerReply(ok: true)
            r.signature = try withKey("evm", reason: "sign text for a site:\n" + String(text.prefix(160))) {
                try EVMSigner.sign(digest: PersonalMessage.digest(message), privateKey: $0)
            }
            r.checks = ["Text was signed, not a transaction or an approval."]
            return r

        case .signTypedData(let json):
            let typed = try TypedData.parse(json)
            guard !typed.isTokenPermission else {
                var v = Verdict()
                v.problems.append("\(typed.primaryType): this is permission to spend your tokens (Permit) — the drainers' main trick. ihatecrypto doesn't sign these.")
                return refused(v)
            }
            var r = SignerReply(ok: true)
            r.signature = try withKey("evm", reason: "sign \(typed.primaryType) for «\(typed.domainName)»") { try EVMSigner.sign(digest: typed.digest, privateKey: $0) }
            r.checks = ["Signed \(typed.primaryType) data for «\(typed.domainName)»; the hash was computed by the signer."]
            return r

        case .signEVMTransaction(let chainId, let nonce, let maxPriorityFee, let maxFee, let gasLimit, let to, let value, let data, let recipients):
            let owner = try address("evm")
            var v = Verdict()
            let call = EVMCall.decode(data)
            let approved = Set(recipients.map { $0.lowercased() } + [owner.lowercased()])
            if !EVMRPC.signable.contains(chainId) { v.problems.append("ihatecrypto doesn't sign for network \(chainId).") }
            if let refusal = call.refusal(sender: owner) { v.problems.append(refusal) }
            switch call {
            case .transfer(let recipient, _) where !approved.contains(recipient.lowercased()):
                v.problems.append("Tokens go to an unapproved address \(recipient).")
            case .plain where value > 0 && !approved.contains(to.lowercased()):
                v.problems.append("Coins go to an unapproved address \(to).")
            default: break
            }
            guard v.ok else { return refused(v) }
            try approve(recipients)
            let tx = EVMTransaction(chainId: chainId, nonce: nonce, maxPriorityFeePerGas: maxPriorityFee, maxFeePerGas: maxFee,
                                    gasLimit: gasLimit, to: to, value: value, data: data)
            var r = SignerReply(ok: true)
            r.signedRaw = try withKey("evm", reason: call.summary(chainId: chainId, to: to, value: value)) { try tx.signed(privateKey: $0).raw }
            r.checks = ["Calldata parsed by the signer: no unlimited approvals and no spending by others."]
            return r

        case .signSolana(let wire, let accounts, let recipients, let tokenOwners, let extraPrograms):
            let owner = try address("solana")
            let message = try SolanaMessage.parse(transaction: wire)
            // Lookup tables are resolved by the app; the static part must be exactly what is in the transaction,
            // and money may not go to an account named only by a lookup table (no network here to check one).
            guard accounts.count >= message.staticKeys.count, Array(accounts.prefix(message.staticKeys.count)) == message.staticKeys else {
                throw WalletError("The account list doesn't match the transaction.")
            }
            var programs = SolanaGuard.knownPrograms
            for p in extraPrograms where programs[p] == nil { programs[p] = "program \(p.prefix(6))… (approved by you)" }
            let verdict = SolanaGuard.check(message, accounts: accounts,
                                            policy: SolanaPolicy(owner: owner, recipients: Set(recipients), programs: programs, trustLookupTables: false),
                                            tokenOwners: verifiedOwners(tokenOwners, mints: accounts))
            guard verdict.ok else { return refused(verdict) }
            try approve(recipients)
            var r = SignerReply(ok: true)
            r.signedWire = try withKey("solana", reason: prompt("sign a Solana transaction", verdict)) { try SolanaTransaction.sign(wire, privateKey: $0).wire }
            r.checks = verdict.checks
            return r

        case .signHyperliquidL1(let action, let nonce, let mainnet):
            let verdict = HLGuard.check(action, owner: try address("evm"), recipients: [])
            guard verdict.ok else { return refused(verdict) }
            // Orders, cancels and leverage go through the agent when it is active: it cannot move money out,
            // so no Touch ID. Otherwise the main key signs.
            // The agent signs trading only; anything that moves money (a vault transfer) takes the main key.
            var r = SignerReply(ok: true)
            if HLSigner.isTrading(action), defaults.bool(forKey: agentActiveKey), var agent = AgentStore.load() {
                defer { SeedStore.wipe(&agent) }
                r.signature = try HLSigner.signL1(action, privateKey: agent, nonce: nonce, mainnet: mainnet)
            } else {
                r.signature = try withKey("evm", reason: prompt("sign a Hyperliquid order", verdict)) {
                    try HLSigner.signL1(action, privateKey: $0, nonce: nonce, mainnet: mainnet)
                }
            }
            r.checks = verdict.checks
            return r

        case .signRelayNonceMapping(let wallet, let depositor, let id, let nonce):
            let owner = try address("evm").lowercased()
            guard wallet.lowercased() == owner, depositor.lowercased() == owner else {
                var v = Verdict()
                v.problems.append("The deposit mapping isn't for your wallet: \(wallet), \(depositor).")
                return refused(v)
            }
            let digest = try HLSigner.relayNonceMappingDigest(wallet: wallet, depositor: depositor, id: id, nonce: nonce)
            var r = SignerReply(ok: true)
            r.signature = try withKey("evm", reason: "link a Hyperliquid withdrawal to a Relay order") { try EVMSigner.sign(digest: digest, privateKey: $0) }
            r.checks = ["Deposit mapping: the wallet and depositor are yours."]
            return r

        case .signHyperliquidUser(let action, let mainnet, let recipients):
            let verdict = HLGuard.check(action, owner: try address("evm"), recipients: Set(recipients))
            guard verdict.ok else { return refused(verdict) }
            let (type, fields) = try HLSigner.userAction(action)
            try approve(recipients)
            var r = SignerReply(ok: true)
            r.signature = try withKey("evm", reason: prompt("sign a Hyperliquid transfer", verdict)) {
                try HLSigner.signUserAction(type, fields: fields, privateKey: $0, mainnet: mainnet)
            }
            r.checks = verdict.checks
            return r
        }
    }

    /// A phrase wallet: its seed and the public addresses derived from it.
    static func store(phrase: String, passphrase: String, requirePresence: Bool, test: Bool = false, automation: Bool = false) throws -> SignerReply {
        var seed = try Mnemonic.seed(phrase, passphrase: passphrase)
        defer { SeedStore.wipe(&seed) }
        return try add(secret: seed, kind: "phrase",
                       solana: try SolanaAccount.address(privateKey: Derivation.ed25519(seed: seed, path: WalletPath.solana(0))),
                       evm: try EVMAccount.address(privateKey: Derivation.secp256k1(seed: seed, path: WalletPath.evm(0))),
                       near: try NearAccount.implicit(privateKey: Derivation.ed25519(seed: seed, path: WalletPath.near(0))),
                       requirePresence: requirePresence, test: test, automation: automation)
    }

    /// Adds a wallet (or re-seals the same one: same kind and addresses keep its id, trading key and approved
    /// addresses) and signs with it from now on — except the automation wallet, which signs only a task's moves.
    /// `test`: sealed without Touch ID (a test or the automation wallet).
    static func add(secret: Data, kind: String, solana: String?, evm: String?, near: String?, requirePresence: Bool,
                    test: Bool = false, automation: Bool = false) throws -> SignerReply {
        var list = Wallets.all
        let same = list.first { $0.kind == kind && $0.solana == solana && $0.evm?.lowercased() == evm?.lowercased() }
        let id = same?.id ?? (list.isEmpty ? SignerWallet.firstID : String(UUID().uuidString.prefix(8)).lowercased())
        try SeedStore.save(secret, requirePresence: requirePresence, id: id, test: test)
        let tests = list.filter(\.isTest).count
        let wallet = SignerWallet(id: id, label: same?.label ?? (automation ? "Automation" : test ? (tests == 0 ? "Test" : "Test \(tests + 1)") : list.isEmpty ? "Main" : "Wallet \(list.count + 1)"),
                                  kind: kind, solana: solana, evm: evm, near: near, test: test && !automation ? true : nil, automation: automation ? true : nil)
        if let i = list.firstIndex(where: { $0.id == id }) { list[i] = wallet } else { list.append(wallet) }
        Wallets.save(list)
        if automation {
            var r = SignerReply(ok: true)
            r.hasWallet = true
            r.wallets = list
            r.activeWallet = Wallets.active?.id
            return r
        }
        Wallets.activate(wallet)
        var r = SignerReply(ok: true)
        r.hasWallet = true
        r.solanaAddress = solana
        r.evmAddress = evm
        r.nearAddress = near
        r.wallets = list
        r.activeWallet = id
        return r
    }

    /// Removes a wallet with everything kept for it; signing moves to the first one left.
    static func remove(_ wallet: SignerWallet) {
        let wasActive = Wallets.active?.id == wallet.id
        SeedStore.delete(id: wallet.id)
        AgentStore.delete(id: wallet.id)
        RecipientStore.delete(id: wallet.id)
        defaults.removeObject(forKey: Wallets.scoped("agentActive", wallet.id))
        let rest = Wallets.all.filter { $0.id != wallet.id }
        Wallets.save(rest)
        if wasActive { Wallets.activate(rest.first) }
    }

    static var agentActiveKey: String { Wallets.scoped("agentActive") }

    /// Where a Ledger's trading key is kept: by its account, which must be an EVM address.
    static func ledgerAgentID(_ owner: String) throws -> String {
        guard owner.wholeMatch(of: /0x[0-9a-fA-F]{40}/) != nil else { throw WalletError("Not an EVM address: \(owner).") }
        return "ledger-" + owner.lowercased()
    }

    /// A wallet's addresses for a Touch ID prompt: its name is the app's to set, its addresses are not.
    static func addresses(_ w: SignerWallet) -> String {
        [w.solana.map { "Solana \($0)" }, w.evm.map { "EVM \($0)" }].compactMap { $0 }.joined(separator: "\n")
    }

    /// The active wallet's key for one chain («solana», «evm», «near»), after Touch ID or within its session: derived
    /// from its phrase, or its one imported key. A key wallet asked for another chain says so plainly. The key lives
    /// only while `body` signs with it: then it and the seed are overwritten.
    static func withKey<T>(_ chain: String, reason: String, _ body: (Data) throws -> T) throws -> T {
        guard let wallet = Wallets.active else { throw WalletError("No wallet imported.") }
        if let missing = wallet.missing(chain) { throw WalletError(missing) }
        var secret = try SeedStore.load(reason: reason, id: wallet.id, session: Wallets.signing == nil)
        defer { SeedStore.wipe(&secret) }
        guard wallet.kind == "phrase" else { return try body(secret) } // a key wallet holds that chain's key itself
        var key = switch chain {
        case "solana": try Derivation.ed25519(seed: secret, path: WalletPath.solana(0))
        case "evm": try Derivation.secp256k1(seed: secret, path: WalletPath.evm(0))
        default: try Derivation.ed25519(seed: secret, path: WalletPath.near(0))
        }
        defer { SeedStore.wipe(&key) }
        return try body(key)
    }

    /// The public BIP-39 test phrase («abandon … about»): anyone can sign for it, so the self-test runs without prompts.
    static var holdsPublicTestWallet: Bool { (try? address("solana")) == "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk" }

    /// Adding, switching or removing a wallet once there is one is the user's act, in person: Touch ID or the password.
    /// A program that talks to the signer as LALA can't slip in its own wallet and wait for the user's deposits.
    static func confirmInPerson(_ reason: String) throws {
        guard !Wallets.all.isEmpty, !holdsPublicTestWallet else { return }
        try SeedStore.confirm(reason)
    }

    /// Money to an address outside the wallet: each new address is confirmed in person once, with the address on
    /// the prompt, and remembered in the signer's own Keychain. The app saying «the user approved it» isn't enough.
    static func approve(_ recipients: [String]) throws {
        guard !holdsPublicTestWallet else { return }
        let own = Set([try? address("solana"), (try? address("evm"))?.lowercased()].compactMap { $0 })
        let known = RecipientStore.all()
        let new = Array(Set(recipients.map(RecipientStore.key).filter { !known.contains($0) && !own.contains($0) })).sorted()
        guard !new.isEmpty else { return }
        try SeedStore.confirm("allow ihatecrypto to send money to a new address:\n" + new.joined(separator: "\n"))
        try RecipientStore.add(new)
    }

    /// A NEAR receiver LALA may pay: a valid account, among the saved addresses the app passed, with a real block hash.
    static func checkNearRecipient(_ receiver: String, _ recipients: [String], _ blockHash: Data) throws {
        guard AddressCheck.problem(receiver, network: .near) == nil else { throw WalletError("Not a NEAR account: \(receiver).") }
        guard recipients.contains(receiver) else { throw WalletError("\(receiver) isn't a saved address: NEAR goes only to one.") }
        guard blockHash.count == 32 else { throw WalletError("A NEAR block hash is 32 bytes.") }
    }

    /// The wallet's NEAR key (m/44'/397'/0') after Touch ID, and its implicit account, which must be the one stored.
    static func withNearKey<T>(reason: String, _ body: (Data, String) throws -> T) throws -> T {
        try withKey("near", reason: reason) { secret in
            let account = try NearAccount.implicit(privateKey: secret)
            if let known = try? address("near"), known != account { throw WalletError("The NEAR key doesn't match this wallet's NEAR account.") }
            return try body(secret, account)
        }
    }

    /// The signing wallet's own address on `chain`: the active wallet's (mirrored in defaults), or the automation
    /// wallet's while it signs a task's move.
    static func address(_ chain: String) throws -> String {
        if let w = Wallets.signing {
            if let a = chain == "solana" ? w.solana : chain == "evm" ? w.evm : w.near { return a }
            throw WalletError(w.missing(chain) ?? "No \(chain) address.")
        }
        if let a = defaults.string(forKey: chain) { return a }
        if let missing = Wallets.active?.missing(chain) { throw WalletError(missing) }
        throw WalletError("No wallet imported.")
    }

    static func refused(_ verdict: Verdict) -> SignerReply {
        var r = SignerReply(ok: false, error: "The guard refused to sign.")
        r.checks = verdict.checks
        r.problems = verdict.problems
        return r
    }

    /// The Touch ID / password prompt text: the money lines the signer parsed itself.
    static func prompt(_ what: String, _ verdict: Verdict) -> String {
        ([what] + verdict.checks.filter { $0.contains("→") }).joined(separator: "\n")
    }

    /// Keeps only claims the signer can prove: the account is the associated token account of that owner for
    /// one of the transaction's own accounts as the mint. A made-up "this is your account" is dropped.
    static func verifiedOwners(_ claimed: [String: String], mints: [String]) -> [String: String] {
        claimed.filter { account, owner in
            mints.contains { (try? SPL.associatedAccount(owner: owner, mint: $0)) == account }
        }
    }
}
