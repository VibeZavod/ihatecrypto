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
            r.hasWallet = SeedStore.exists
            r.solanaAddress = defaults.string(forKey: "solana")
            r.evmAddress = defaults.string(forKey: "evm")
            r.agentAddress = AgentStore.load().flatMap { try? EVMAccount.address(privateKey: $0) }
            r.agentActive = defaults.bool(forKey: "agentActive") && r.agentAddress != nil
            return r

        case .enableAgent:
            let owner = try address("evm")
            var key = AgentStore.load()
            if key == nil {
                // 32 random bytes; retried in the vanishing case they are not a valid secp256k1 key.
                for _ in 0..<4 where key == nil {
                    var bytes = Data(count: 32)
                    guard bytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else { continue }
                    if (try? EVMAccount.address(privateKey: bytes)) != nil { key = bytes }
                }
                guard let key else { throw WalletError("Couldn't create the agent key.") }
                try AgentStore.save(key)
            }
            let agent = try EVMAccount.address(privateKey: key!)
            guard agent.lowercased() != owner.lowercased() else { throw WalletError("The agent key matches the main key.") }
            let seed = try SeedStore.load(reason: "approve a trading key: orders without Touch ID; it can't withdraw money")
            let nonce = UInt64(Date().timeIntervalSince1970 * 1000)
            let (action, signature) = try HLSigner.approveAgent(agent: agent, name: "lala", nonce: nonce,
                                                                privateKey: Derivation.secp256k1(seed: seed, path: WalletPath.evm(0)), mainnet: true)
            var r = SignerReply(ok: true)
            r.agentAddress = agent
            r.action = action
            r.signature = signature
            r.nonce = nonce
            r.checks = ["Approving an agent key created inside the signer: it can trade but not withdraw."]
            return r

        case .setAgentActive(let on):
            // Resuming a paused trading key is the user's decision: it asks for Touch ID like a signature.
            if on, !defaults.bool(forKey: "agentActive"), AgentStore.load() != nil {
                _ = try SeedStore.load(reason: "turn the Hyperliquid trading key back on")
            }
            defaults.set(on && AgentStore.load() != nil, forKey: "agentActive")
            var r = SignerReply(ok: true)
            r.agentActive = defaults.bool(forKey: "agentActive")
            return r

        case .importMnemonic(let phrase, let passphrase, let requirePresence):
            let seed = try Mnemonic.seed(phrase, passphrase: passphrase)
            let solana = try SolanaAccount.address(privateKey: Derivation.ed25519(seed: seed, path: WalletPath.solana(0)))
            let evm = try EVMAccount.address(privateKey: Derivation.secp256k1(seed: seed, path: WalletPath.evm(0)))
            try SeedStore.save(seed, requirePresence: requirePresence)
            defaults.set(solana, forKey: "solana")
            defaults.set(evm, forKey: "evm")
            var r = SignerReply(ok: true)
            r.hasWallet = true
            r.solanaAddress = solana
            r.evmAddress = evm
            return r

        case .lock:
            SeedStore.endSession()
            defaults.set(false, forKey: "agentActive")
            var r = SignerReply(ok: true)
            r.agentActive = false
            r.checks = ["Touch ID session ended; the trading key is paused."]
            return r

        case .forget:
            SeedStore.delete()
            AgentStore.delete()
            defaults.removeObject(forKey: "agentActive")
            defaults.removeObject(forKey: "solana")
            defaults.removeObject(forKey: "evm")
            return SignerReply(ok: true)

        case .signSolanaMessage(let message):
            // A «message» that parses as a transaction would be a signed transaction once returned.
            guard (try? SolanaMessage.parse(message: message)) == nil, let text = String(data: message, encoding: .utf8),
                  !text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else {
                var v = Verdict()
                v.problems.append("This isn't text but data that looks like a transaction: message signing refused.")
                return refused(v)
            }
            let seed = try SeedStore.load(reason: "sign text for a site:\n" + String(text.prefix(160)))
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Derivation.ed25519(seed: seed, path: WalletPath.solana(0)))
            var r = SignerReply(ok: true)
            r.signatureBytes = try key.signature(for: message)
            r.checks = ["Only text was signed, not a transaction."]
            return r

        case .signPersonal(let message):
            guard !PersonalMessage.isBlindHash(message) else {
                var v = Verdict()
                v.problems.append("The site asks to sign a hash, not text: such a signature could authorize anything.")
                return refused(v)
            }
            let text = String(data: message, encoding: .utf8) ?? "\(message.count) bytes"
            let seed = try SeedStore.load(reason: "sign text for a site:\n" + String(text.prefix(160)))
            var r = SignerReply(ok: true)
            r.signature = try EVMSigner.sign(digest: PersonalMessage.digest(message), privateKey: Derivation.secp256k1(seed: seed, path: WalletPath.evm(0)))
            r.checks = ["Text was signed, not a transaction or an approval."]
            return r

        case .signTypedData(let json):
            let typed = try TypedData.parse(json)
            guard !typed.isTokenPermission else {
                var v = Verdict()
                v.problems.append("\(typed.primaryType): this is permission to spend your tokens (Permit) — the drainers' main trick. LALA doesn't sign these.")
                return refused(v)
            }
            let seed = try SeedStore.load(reason: "sign \(typed.primaryType) for «\(typed.domainName)»")
            var r = SignerReply(ok: true)
            r.signature = try EVMSigner.sign(digest: typed.digest, privateKey: Derivation.secp256k1(seed: seed, path: WalletPath.evm(0)))
            r.checks = ["Signed \(typed.primaryType) data for «\(typed.domainName)»; the hash was computed by the signer."]
            return r

        case .signEVMTransaction(let chainId, let nonce, let maxPriorityFee, let maxFee, let gasLimit, let to, let value, let data, let recipients):
            let owner = try address("evm")
            var v = Verdict()
            let call = EVMCall.decode(data)
            let approved = Set(recipients.map { $0.lowercased() } + [owner.lowercased()])
            if ![1, 42161, 8453, 4663].contains(chainId) { v.problems.append("LALA doesn't sign for network \(chainId).") }
            if let refusal = call.refusal(sender: owner) { v.problems.append(refusal) }
            switch call {
            case .transfer(let recipient, _) where !approved.contains(recipient.lowercased()):
                v.problems.append("Tokens go to an unapproved address \(recipient).")
            case .plain where value > 0 && !approved.contains(to.lowercased()):
                v.problems.append("Coins go to an unapproved address \(to).")
            default: break
            }
            guard v.ok else { return refused(v) }
            let seed = try SeedStore.load(reason: "sign an EVM transaction for a site: \(to.prefix(10))…, network \(chainId)")
            let tx = EVMTransaction(chainId: chainId, nonce: nonce, maxPriorityFeePerGas: maxPriorityFee, maxFeePerGas: maxFee,
                                    gasLimit: gasLimit, to: to, value: value, data: data)
            var r = SignerReply(ok: true)
            r.signedRaw = try tx.signed(privateKey: Derivation.secp256k1(seed: seed, path: WalletPath.evm(0))).raw
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
            let seed = try SeedStore.load(reason: prompt("sign a Solana transaction", verdict))
            var r = SignerReply(ok: true)
            r.signedWire = try SolanaTransaction.sign(wire, privateKey: Derivation.ed25519(seed: seed, path: WalletPath.solana(0))).wire
            r.checks = verdict.checks
            return r

        case .signHyperliquidL1(let action, let nonce, let mainnet):
            let verdict = HLGuard.check(action, owner: try address("evm"), recipients: [])
            guard verdict.ok else { return refused(verdict) }
            // Orders, cancels and leverage go through the agent when it is active: it cannot move money out,
            // so no Touch ID. Otherwise the main key signs.
            let key: Data
            // The agent signs trading only; anything that moves money (a vault transfer) takes the main key.
            let trading: Bool = if case .map(let pairs) = action, case .string(let t)? = pairs.first(where: { $0.0 == "type" })?.1 {
                ["order", "cancel", "updateLeverage", "batchModify", "modify"].contains(t)
            } else { false }
            if trading, defaults.bool(forKey: "agentActive"), let agent = AgentStore.load() {
                key = agent
            } else {
                let seed = try SeedStore.load(reason: prompt("sign a Hyperliquid order", verdict))
                key = try Derivation.secp256k1(seed: seed, path: WalletPath.evm(0))
            }
            var r = SignerReply(ok: true)
            r.signature = try HLSigner.signL1(action, privateKey: key, nonce: nonce, mainnet: mainnet)
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
            let seed = try SeedStore.load(reason: "link a Hyperliquid withdrawal to a Relay order")
            var r = SignerReply(ok: true)
            r.signature = try EVMSigner.sign(digest: digest, privateKey: Derivation.secp256k1(seed: seed, path: WalletPath.evm(0)))
            r.checks = ["Deposit mapping: the wallet and depositor are yours."]
            return r

        case .signHyperliquidUser(let action, let mainnet, let recipients):
            let verdict = HLGuard.check(action, owner: try address("evm"), recipients: Set(recipients))
            guard verdict.ok else { return refused(verdict) }
            let (type, fields) = try userAction(action)
            let seed = try SeedStore.load(reason: prompt("sign a Hyperliquid transfer", verdict))
            let key = try Derivation.secp256k1(seed: seed, path: WalletPath.evm(0))
            var r = SignerReply(ok: true)
            r.signature = try HLSigner.signUserAction(type, fields: fields, privateKey: key, mainnet: mainnet)
            r.checks = verdict.checks
            return r
        }
    }

    static func address(_ key: String) throws -> String {
        guard let a = defaults.string(forKey: key) else { throw WalletError("No wallet imported.") }
        return a
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
