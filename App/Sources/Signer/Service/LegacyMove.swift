import EVMChain
import Foundation
import LocalAuthentication
import Security
import SignerAPI
import SolanaChain
import WalletCore

/// The move from LALA's names to ihatecrypto's (2026-10), once, on a Mac that ran LALA. Its signer kept every wallet
/// under «app.lala.seed» in the group N78L833HCS.app.lala.mac.signer, each sealed to a Secure Enclave key there. Each
/// is opened (Touch ID once) and sealed again under ihatecrypto's names, in ihatecrypto's group, with a new Enclave
/// key; the trading keys and the approved addresses are copied. The old items stay as they were: the old app still
/// opens them until the user removes it.
/// `registry` is the old signer's list, which the app read from the old signer's container: it only gives the labels
/// and which wallet is the automation one. Every address is derived again from the secret here and must match, so
/// nothing the app says can add a wallet or change one.
enum LegacyMove {
    static let seedService = "app.lala.seed", agentService = "app.lala.agent", recipientService = "app.lala.recipients"

    static func adopt(_ registry: [SignerWallet], active: String?) throws -> SignerReply {
        guard Wallets.all.isEmpty else { throw WalletError("ihatecrypto's signer holds wallets already: nothing to move.") }
        let ids = Array(Set(accounts(seedService).compactMap { account -> String? in
            account == SeedStore.sealedAccount || account == SeedStore.legacyAccount ? SignerWallet.firstID
                : account.hasPrefix("wallet-") ? String(account.dropFirst("wallet-".count)) : nil
        })).sorted { a, b in a == SignerWallet.firstID || (b != SignerWallet.firstID && a < b) }
        guard !ids.isEmpty else { throw WalletError("No wallets under LALA's names on this Mac.") }
        let context = LAContext()
        context.localizedReason = "move your wallets to ihatecrypto's new names"
        var moved: [SignerWallet] = []
        for id in ids {
            var secret = try SeedStore.openLegacy(id: id, context: context)
            defer { SeedStore.wipe(&secret) }
            let listed = registry.first { $0.id == id }
            let kind = listed?.kind ?? "phrase"
            let found = try addresses(secret, kind: kind)
            if let listed, listed.solana != found.solana || listed.evm?.lowercased() != found.evm?.lowercased() || listed.near != found.near {
                throw WalletError("The wallet «\(listed.label)» doesn't match its key: nothing more was moved.")
            }
            // Sealed as before: the automation and test wallets without Touch ID, the rest with it.
            let quiet = listed?.isTest == true || listed?.isAutomation == true
            try SeedStore.save(secret, requirePresence: !quiet, id: id, test: quiet)
            moved.append(SignerWallet(id: id, label: listed?.label ?? (id == SignerWallet.firstID ? "Main" : "Wallet \(moved.count + 1)"),
                                      kind: kind, solana: found.solana, evm: found.evm, near: found.near,
                                      test: listed?.test, automation: listed?.automation))
        }
        copy(agentService, to: AgentStore.service)
        copy(recipientService, to: RecipientStore.service)
        Wallets.save(moved)
        let signing = moved.first { $0.id == active && !$0.isAutomation } ?? moved.first { !$0.isAutomation } ?? moved[0]
        Wallets.activate(signing)
        var r = SignerReply(ok: true)
        r.hasWallet = true
        r.wallets = moved
        r.activeWallet = signing.id
        r.solanaAddress = signing.solana
        r.evmAddress = signing.evm
        r.nearAddress = signing.near
        return r
    }

    /// The addresses a secret signs for, the way `Signer.store` and `.importPrivateKey` derive them.
    static func addresses(_ secret: Data, kind: String) throws -> (solana: String?, evm: String?, near: String?) {
        switch kind {
        case "phrase":
            return (try SolanaAccount.address(privateKey: Derivation.ed25519(seed: secret, path: WalletPath.solana(0))),
                    try EVMAccount.address(privateKey: Derivation.secp256k1(seed: secret, path: WalletPath.evm(0))),
                    try NearAccount.implicit(privateKey: Derivation.ed25519(seed: secret, path: WalletPath.near(0))))
        case "solana": return (try SolanaAccount.address(privateKey: secret), nil, nil)
        case "evm": return (nil, try EVMAccount.address(privateKey: secret), nil)
        default: throw WalletError("A wallet of kind «\(kind)» can't be moved.")
        }
    }

    /// The accounts of a service's items in the data-protection Keychain.
    static func accounts(_ service: String) -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecUseDataProtectionKeychain as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
                                kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Every item of an old service under the new one, as it is (this device only, no Touch ID: trading keys, approved
    /// addresses); one that's already there is kept.
    static func copy(_ old: String, to new: String) {
        for account in accounts(old) {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: old, kSecAttrAccount as String: account,
                                    kSecUseDataProtectionKeychain as String: true, kSecReturnData as String: true]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, var data = out as? Data else { continue }
            defer { SeedStore.wipe(&data) }
            SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: new, kSecAttrAccount as String: account,
                        kSecUseDataProtectionKeychain as String: true, kSecValueData as String: data,
                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary, nil)
        }
    }
}
