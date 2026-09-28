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
                // 32 random bytes; retried in the vanishing case they are not a valid secp256k1 key.
                for _ in 0..<4 where agentKey == nil {
                    var bytes = Data(count: 32)
                    guard bytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else { continue }
                    if (try? EVMAccount.address(privateKey: bytes)) != nil { agentKey = bytes }
                }
                guard let agentKey else { throw WalletError("Couldn't create the agent key.") }
                try AgentStore.save(agentKey)
            }
            let agent = try EVMAccount.address(privateKey: agentKey!)
            guard agent.lowercased() != owner.lowercased() else { throw WalletError("The agent key matches the main key.") }
            let main = try key("evm", reason: "approve a trading key: orders without Touch ID; it can't withdraw money")
            let nonce = UInt64(Date().timeIntervalSince1970 * 1000)
            let (action, signature) = try HLSigner.approveAgent(agent: agent, name: "lala", nonce: nonce, privateKey: main, mainnet: true)
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
                _ = try key("evm", reason: "turn the Hyperliquid trading key back on")
            }
            defaults.set(on && AgentStore.load() != nil, forKey: agentActiveKey)
            var r = SignerReply(ok: true)
            r.agentActive = defaults.bool(forKey: agentActiveKey)
            return r

        case .createWallet(let requirePresence):
            let phrase = Mnemonic.generate()
            try confirmInPerson("add a new wallet to ihatecrypto and sign with it")
            var r = try store(phrase: phrase, passphrase: "", requirePresence: requirePresence)
            r.phrase = phrase
            return r

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
                let near = try NearAccount.implicit(privateKey: key("near", reason: "show your NEAR address, derived from your phrase"))
                defaults.set(near, forKey: "near")
                var list = Wallets.all
                if let i = list.firstIndex(where: { $0.id == Wallets.activeID }) { list[i].near = near; Wallets.save(list) }
                r.nearAddress = near
            }
            return r

        case .lock:
            SeedStore.endSession()
            defaults.set(false, forKey: agentActiveKey)
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
            let (nearSecret, account) = try nearKey(reason: "sell \(NearTransaction.near(yocto)) NEAR: wrapped and sent to the 1Click deposit \(depositAddress.prefix(8))…\(depositAddress.suffix(6))")
            var r = SignerReply(ok: true)
            r.signedRaw = try NearTransaction.sign(receiver: NearTransaction.wrapContract, nonce: nonce, blockHash: blockHash,
                                                   actions: NearTransaction.intentDeposit(account: account, depositAddress: depositAddress, amount: yocto),
                                                   privateKey: nearSecret).signed
            r.checks = ["\(NearTransaction.near(yocto)) NEAR → wNEAR → \(depositAddress) (1Click)"]
            return r

        case .signNearTransfer(let amount, let receiver, let recipients, let nonce, let blockHash):
            guard let yocto = UInt128(amount), yocto > 0 else { throw WalletError("Not a NEAR amount: \(amount).") }
            try checkNearRecipient(receiver, recipients, blockHash)
            try approve([receiver])
            let (nearSecret, account) = try nearKey(reason: "send \(NearTransaction.near(yocto)) NEAR to \(receiver)")
            guard receiver != account else { throw WalletError("That is this wallet's own NEAR account.") }
            var r = SignerReply(ok: true)
            r.signedRaw = try NearTransaction.sign(receiver: receiver, nonce: nonce, blockHash: blockHash, actions: [.transfer(deposit: yocto)], privateKey: nearSecret).signed
            r.checks = ["\(NearTransaction.near(yocto)) NEAR → \(receiver)"]
            return r

        case .signNearDeleteAccount(let beneficiary, let recipients, let nonce, let blockHash):
            try checkNearRecipient(beneficiary, recipients, blockHash)
            try approve([beneficiary])
            // Always a fresh prompt, whatever Touch ID session is open: this empties and removes the account.
            try SeedStore.confirm("DELETE your NEAR account and send all the NEAR on it to \(beneficiary)")
            let (nearSecret, account) = try nearKey(reason: "delete your NEAR account into \(beneficiary)")
            guard beneficiary != account else { throw WalletError("An account can't be deleted into itself.") }
            var r = SignerReply(ok: true)
            r.signedRaw = try NearTransaction.sign(receiver: account, nonce: nonce, blockHash: blockHash,
                                                   actions: [.deleteAccount(beneficiary: beneficiary)], privateKey: nearSecret).signed
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
            let solanaKey = try Curve25519.Signing.PrivateKey(rawRepresentation: key("solana", reason: "sign text for a site:\n" + String(text.prefix(160))))
            var r = SignerReply(ok: true)
            r.signatureBytes = try solanaKey.signature(for: message)
            r.checks = ["Only text was signed, not a transaction."]
            return r

        case .signPersonal(let message):
            guard !PersonalMessage.isBlindHash(message) else {
                var v = Verdict()
                v.problems.append("The site asks to sign a hash, not text: such a signature could authorize anything.")
                return refused(v)
            }
            let text = String(data: message, encoding: .utf8) ?? "\(message.count) bytes"
            let evmKey = try key("evm", reason: "sign text for a site:\n" + String(text.prefix(160)))
            var r = SignerReply(ok: true)
            r.signature = try EVMSigner.sign(digest: PersonalMessage.digest(message), privateKey: evmKey)
            r.checks = ["Text was signed, not a transaction or an approval."]
            return r

        case .signTypedData(let json):
            let typed = try TypedData.parse(json)
            guard !typed.isTokenPermission else {
                var v = Verdict()
                v.problems.append("\(typed.primaryType): this is permission to spend your tokens (Permit) — the drainers' main trick. ihatecrypto doesn't sign these.")
                return refused(v)
            }
            let evmKey = try key("evm", reason: "sign \(typed.primaryType) for «\(typed.domainName)»")
            var r = SignerReply(ok: true)
            r.signature = try EVMSigner.sign(digest: typed.digest, privateKey: evmKey)
            r.checks = ["Signed \(typed.primaryType) data for «\(typed.domainName)»; the hash was computed by the signer."]
            return r

        case .signEVMTransaction(let chainId, let nonce, let maxPriorityFee, let maxFee, let gasLimit, let to, let value, let data, let recipients):
            let owner = try address("evm")
            var v = Verdict()
            let call = EVMCall.decode(data)
            let approved = Set(recipients.map { $0.lowercased() } + [owner.lowercased()])
            if ![1, 42161, 8453, 4663].contains(chainId) { v.problems.append("ihatecrypto doesn't sign for network \(chainId).") }
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
            let evmKey = try key("evm", reason: "sign an EVM transaction for a site: \(to.prefix(10))…, network \(chainId)")
            let tx = EVMTransaction(chainId: chainId, nonce: nonce, maxPriorityFeePerGas: maxPriorityFee, maxFeePerGas: maxFee,
                                    gasLimit: gasLimit, to: to, value: value, data: data)
            var r = SignerReply(ok: true)
            r.signedRaw = try tx.signed(privateKey: evmKey).raw
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
            let solanaKey = try key("solana", reason: prompt("sign a Solana transaction", verdict))
            var r = SignerReply(ok: true)
            r.signedWire = try SolanaTransaction.sign(wire, privateKey: solanaKey).wire
            r.checks = verdict.checks
            return r

        case .signHyperliquidL1(let action, let nonce, let mainnet):
            let verdict = HLGuard.check(action, owner: try address("evm"), recipients: [])
            guard verdict.ok else { return refused(verdict) }
            // Orders, cancels and leverage go through the agent when it is active: it cannot move money out,
            // so no Touch ID. Otherwise the main key signs.
            let signingKey: Data
            // The agent signs trading only; anything that moves money (a vault transfer) takes the main key.
            let trading: Bool = if case .map(let pairs) = action, case .string(let t)? = pairs.first(where: { $0.0 == "type" })?.1 {
                ["order", "cancel", "updateLeverage", "batchModify", "modify"].contains(t)
            } else { false }
            if trading, defaults.bool(forKey: agentActiveKey), let agent = AgentStore.load() {
                signingKey = agent
            } else {
                signingKey = try key("evm", reason: prompt("sign a Hyperliquid order", verdict))
            }
            var r = SignerReply(ok: true)
            r.signature = try HLSigner.signL1(action, privateKey: signingKey, nonce: nonce, mainnet: mainnet)
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
            let evmKey = try key("evm", reason: "link a Hyperliquid withdrawal to a Relay order")
            var r = SignerReply(ok: true)
            r.signature = try EVMSigner.sign(digest: digest, privateKey: evmKey)
            r.checks = ["Deposit mapping: the wallet and depositor are yours."]
            return r

        case .signHyperliquidUser(let action, let mainnet, let recipients):
            let verdict = HLGuard.check(action, owner: try address("evm"), recipients: Set(recipients))
            guard verdict.ok else { return refused(verdict) }
            let (type, fields) = try userAction(action)
            try approve(recipients)
            let evmKey = try key("evm", reason: prompt("sign a Hyperliquid transfer", verdict))
            var r = SignerReply(ok: true)
            r.signature = try HLSigner.signUserAction(type, fields: fields, privateKey: evmKey, mainnet: mainnet)
            r.checks = verdict.checks
            return r
        }
    }

    /// A phrase wallet: its seed and the public addresses derived from it.
    static func store(phrase: String, passphrase: String, requirePresence: Bool) throws -> SignerReply {
        let seed = try Mnemonic.seed(phrase, passphrase: passphrase)
        return try add(secret: seed, kind: "phrase",
                       solana: try SolanaAccount.address(privateKey: Derivation.ed25519(seed: seed, path: WalletPath.solana(0))),
                       evm: try EVMAccount.address(privateKey: Derivation.secp256k1(seed: seed, path: WalletPath.evm(0))),
                       near: try NearAccount.implicit(privateKey: Derivation.ed25519(seed: seed, path: WalletPath.near(0))),
                       requirePresence: requirePresence)
    }

    /// Adds a wallet (or re-seals the same one: same kind and addresses keep its id, trading key and approved
    /// addresses) and signs with it from now on.
    static func add(secret: Data, kind: String, solana: String?, evm: String?, near: String?, requirePresence: Bool) throws -> SignerReply {
        var list = Wallets.all
        let same = list.first { $0.kind == kind && $0.solana == solana && $0.evm?.lowercased() == evm?.lowercased() }
        let id = same?.id ?? (list.isEmpty ? SignerWallet.firstID : String(UUID().uuidString.prefix(8)).lowercased())
        try SeedStore.save(secret, requirePresence: requirePresence, id: id)
        let wallet = SignerWallet(id: id, label: same?.label ?? (list.isEmpty ? "Main" : "Wallet \(list.count + 1)"),
                                  kind: kind, solana: solana, evm: evm, near: near)
        if let i = list.firstIndex(where: { $0.id == id }) { list[i] = wallet } else { list.append(wallet) }
        Wallets.save(list)
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

    /// A wallet's addresses for a Touch ID prompt: its name is the app's to set, its addresses are not.
    static func addresses(_ w: SignerWallet) -> String {
        [w.solana.map { "Solana \($0)" }, w.evm.map { "EVM \($0)" }].compactMap { $0 }.joined(separator: "\n")
    }

    /// The active wallet's key for one chain («solana», «evm», «near»), after Touch ID or within its session: derived
    /// from its phrase, or its one imported key. A key wallet asked for another chain says so plainly.
    static func key(_ chain: String, reason: String) throws -> Data {
        guard let wallet = Wallets.active else { throw WalletError("No wallet imported.") }
        if let missing = wallet.missing(chain) { throw WalletError(missing) }
        let secret = try SeedStore.load(reason: reason, id: wallet.id)
        switch (wallet.kind, chain) {
        case ("phrase", "solana"): return try Derivation.ed25519(seed: secret, path: WalletPath.solana(0))
        case ("phrase", "evm"): return try Derivation.secp256k1(seed: secret, path: WalletPath.evm(0))
        case ("phrase", _): return try Derivation.ed25519(seed: secret, path: WalletPath.near(0))
        default: return secret // a key wallet holds that chain's key itself
        }
    }

    /// The public BIP-39 test phrase («abandon … about»): anyone can sign for it, so the self-test runs without prompts.
    static var holdsPublicTestWallet: Bool { defaults.string(forKey: "solana") == "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk" }

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
        let own = Set([defaults.string(forKey: "solana"), defaults.string(forKey: "evm")?.lowercased()].compactMap { $0 })
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
    static func nearKey(reason: String) throws -> (key: Data, account: String) {
        let secret = try key("near", reason: reason)
        let account = try NearAccount.implicit(privateKey: secret)
        if let known = defaults.string(forKey: "near"), known != account { throw WalletError("The NEAR key doesn't match this wallet's NEAR account.") }
        return (secret, account)
    }

    static func address(_ chain: String) throws -> String {
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

    /// Hyperliquid user-signed actions the signer knows, with their EIP-712 fields after hyperliquidChain.
    static let userSchemas: [String: (type: String, fields: [(String, String)])] = [
        "usdClassTransfer": ("UsdClassTransfer", [("amount", "string"), ("toPerp", "bool"), ("nonce", "uint64")]),
        "spotSend": ("SpotSend", [("destination", "string"), ("token", "string"), ("amount", "string"), ("time", "uint64")]),
        "sendAsset": ("SendAsset", [("destination", "string"), ("sourceDex", "string"), ("destinationDex", "string"),
                                    ("token", "string"), ("amount", "string"), ("fromSubAccount", "string"), ("nonce", "uint64")]),
        "withdraw3": ("Withdraw", [("destination", "string"), ("amount", "string"), ("time", "uint64")]),
        "usdSend": ("UsdSend", [("destination", "string"), ("amount", "string"), ("time", "uint64")]),
    ]

    static func userAction(_ action: MsgPack) throws -> (String, [EIP712.Field]) {
        guard case .map(let pairs) = action else { throw WalletError("Unrecognized action.") }
        let values = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
        guard case .string(let kind)? = values["type"], let schema = userSchemas[kind] else {
            throw WalletError("Signing this Hyperliquid action isn't supported.")
        }
        let fields: [EIP712.Field] = try schema.fields.map { name, type in
            switch (type, values[name]) {
            case ("string", .string(let s)?): return EIP712.Field(name, type, .string(s))
            case ("bool", .bool(let b)?): return EIP712.Field(name, type, .bool(b))
            case ("uint64", .uint(let n)?): return EIP712.Field(name, type, .uint(n))
            default: throw WalletError("The action has no \(name) field of type \(type).")
            }
        }
        return (schema.type, fields)
    }
}
