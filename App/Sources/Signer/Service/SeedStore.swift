import Foundation
import LocalAuthentication
import Security
import SignerAPI
import WalletCore

/// The seed in the data-protection Keychain: this device only, never synced, readable only by the signer's own
/// access group. Since 2026-09-28 it is sealed to a Secure Enclave key: the Keychain holds only ciphertext, and
/// opening it takes the Enclave, which asks for Touch ID or the login password. Code that manages to read the
/// Keychain item — a re-signed copy of the signer — gets bytes it cannot open without the user.
/// A wallet saved before then sits unsealed under «default» until it is replaced.
/// After each signature the opened seed and the key derived from it are overwritten (`wipe`, see `Signer.withKey`).
/// ponytail: copies made inside the derivation and the secp256k1 library aren't reachable from here, so the guard
/// against reading them is still that no debugger can attach to a Release signer (no get-task-allow).
enum SeedStore {
    /// Overwrites key bytes in place before they're released; memset_s is never optimized away. Call it on the last
    /// reference: a Data shared with another copy is duplicated first, and only the duplicate would be cleared.
    static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { b in if let p = b.baseAddress { _ = memset_s(p, b.count, 0, b.count) } }
    }

    static func item(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.lala.seed",
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static let sealedAccount = "sealed", legacyAccount = "default"
    /// Wallet «1» keeps the item it had before there were several wallets; the others get their own.
    static func account(_ id: String) -> String { id == SignerWallet.firstID ? sealedAccount : "wallet-\(id)" }
    static let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    /// Each sealing makes its own Enclave key; the sealed item names it (kSecAttrGeneric), so a new wallet is
    /// written before the old one and its key are removed — a failure halfway never leaves no wallet at all.
    static func keyQuery(_ tag: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// The sealed seed and the tag of the key that opens it.
    private static func sealed(_ account: String) -> (data: Data, tag: Data)? {
        var q = item(account)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let found = out as? [String: Any],
              let data = found[kSecValueData as String] as? Data, let tag = found[kSecAttrGeneric as String] as? Data else { return nil }
        return (data, tag)
    }

    /// The one seed LALA held before several wallets, sealed or from before sealing: what wallet «1» migrates from.
    static var firstPresent: Bool { present(sealedAccount) || present(legacyAccount) }

    private static func present(_ account: String) -> Bool {
        var q = item(account)
        q[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Seals the seed to a new Enclave key. Release builds ask for Touch ID or the password to open it, except for a
    /// test wallet (made fresh in the app, for small amounts); Debug builds may skip it for the automated self-test
    /// with the public test phrase.
    static func save(_ seed: Data, requirePresence: Bool, id: String, test: Bool = false) throws {
        let account = account(id)
        #if DEBUG
        let presence = requirePresence
        #else
        let presence = requirePresence || !test
        #endif
        var error: Unmanaged<CFError>?
        func fail(_ what: String) -> WalletError { WalletError("\(what): \(error.map { "\($0.takeRetainedValue())" } ?? "?")") }
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           presence ? [.privateKeyUsage, .userPresence] : [.privateKeyUsage], &error) else {
            throw fail("Couldn't set access to the key")
        }
        let tag = Data("app.lala.seed.key.\(UUID().uuidString)".utf8)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: access,
            ] as [String: Any],
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw fail("The Secure Enclave didn't make a key") }
        guard let publicKey = SecKeyCopyPublicKey(key),
              let ciphertext = SecKeyCreateEncryptedData(publicKey, algorithm, seed as CFData, &error) as Data? else {
            SecItemDelete(keyQuery(tag) as CFDictionary)
            throw fail("Couldn't seal the key")
        }
        // Written over the same wallet's old seal in one step; only then is the old key removed.
        let old = sealed(account)?.tag
        let values: [String: Any] = [kSecValueData as String: ciphertext, kSecAttrGeneric as String: tag]
        var status = SecItemUpdate(item(account) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var q = item(account).merging(values) { $1 }
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            SecItemDelete(keyQuery(tag) as CFDictionary)
            throw WalletError("Keychain didn't save the key: \(status) \(SecCopyErrorMessageString(status, nil) as String? ?? "")")
        }
        endSession()
        if let old { SecItemDelete(keyQuery(old) as CFDictionary) }
        if id == SignerWallet.firstID { SecItemDelete(item(legacyAccount) as CFDictionary) }
    }

    /// One Touch ID per move, not per signature: a context that already authenticated opens the key again
    /// without a prompt, for at most `sessionLength` (1 minute unless the user picked 5, 15 or 30). With the standard
    /// minute the app ends it as soon as the move is done (`endSession`). Every signature still passes the guard;
    /// a locked screen or sleep ends the session.
    nonisolated(unsafe) private static var session: (context: LAContext, since: Date)?

    static var sessionLength: Int {
        let chosen = Signer.defaults.integer(forKey: "sessionLength")
        return SignerSession.choices.contains(chosen) ? chosen : SignerSession.standard
    }
    private static let lock = NSLock()

    /// `session: false` — a key sealed without Touch ID (the automation wallet's) opens on a context of its own: it
    /// neither reuses the Touch ID session nor leaves its reason on it for the next prompt.
    static func load(reason: String, id: String, session useSession: Bool = true) throws -> Data {
        let context: LAContext = lock.withLock {
            let fresh = LAContext()
            fresh.localizedReason = reason
            guard useSession else { return fresh }
            if let s = session, Date().timeIntervalSince(s.since) < TimeInterval(sessionLength) { return s.context }
            session = (fresh, Date())
            return fresh
        }
        do {
            if let sealed = sealed(account(id)) {
                var q = keyQuery(sealed.tag)
                q[kSecReturnRef as String] = true
                q[kSecUseAuthenticationContext as String] = context
                var ref: CFTypeRef?
                guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess, let ref else { throw WalletError("The Secure Enclave key is missing.") }
                var error: Unmanaged<CFError>?
                // The Enclave asks for Touch ID or the password here, unless this context already did.
                guard let opened = SecKeyCreateDecryptedData(ref as! SecKey, algorithm, sealed.data as CFData, &error) else {
                    throw WalletError("Touch ID was cancelled or didn't match: nothing was signed.")
                }
                // Our own copy, which the caller wipes; the Security framework's buffer is cleared before it's released.
                let bytes = CFDataGetBytePtr(opened), count = CFDataGetLength(opened)
                let seed = Data(bytes: bytes!, count: count)
                _ = memset_s(UnsafeMutableRawPointer(mutating: bytes!), count, 0, count)
                return seed
            }
            guard id == SignerWallet.firstID, let seed = read(legacyAccount, context: context) else { throw WalletError("No wallet imported.") }
            return seed
        } catch {
            if useSession { lock.withLock { session = nil } } // a cancelled or failed prompt must not be reused
            throw error
        }
    }

    private static func read(_ account: String, context: LAContext?) -> Data? {
        var q = item(account)
        q[kSecReturnData as String] = true
        if let context { q[kSecUseAuthenticationContext as String] = context }
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    /// The user in person — Touch ID or the login password — with `reason` on the system prompt, always a fresh
    /// prompt. The authenticated context then serves the signature that follows, so there is one prompt, not two.
    static func confirm(_ reason: String) throws {
        let context = LAContext()
        context.localizedReason = reason
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Error?
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            if !ok { outcome = error ?? WalletError("Not confirmed.") }
            done.signal()
        }
        done.wait()
        if let outcome { throw WalletError("Not confirmed (\(outcome.localizedDescription)): nothing was changed.") }
        lock.withLock { session = (context, Date()) }
    }

    static func delete(id: String) {
        endSession()
        if let tag = sealed(account(id))?.tag { SecItemDelete(keyQuery(tag) as CFDictionary) }
        SecItemDelete(item(account(id)) as CFDictionary)
        if id == SignerWallet.firstID { SecItemDelete(item(legacyAccount) as CFDictionary) }
    }

    /// The next load asks for Touch ID again.
    static func endSession() {
        lock.withLock {
            session?.context.invalidate()
            session = nil
        }
    }
}

/// Addresses outside the wallet that the user allowed money to go to, each confirmed in person once. Kept in the
/// signer's own Keychain group, so the app — or anything posing as it — can't add one silently.
enum RecipientStore {
    /// Per wallet: an address approved for one wallet isn't approved for another.
    static func query(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.lala.recipients",
            kSecAttrAccount as String: Wallets.scoped("approved", id),
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
    static var base: [String: Any] { query(Wallets.activeID) }

    static func all() -> Set<String> {
        var q = base
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    static func add(_ addresses: [String]) throws {
        let list = Array(all().union(addresses.map(key))).sorted()
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = try JSONEncoder().encode(list)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw WalletError("Keychain didn't save the approved address: \(status)") }
    }

    /// EVM addresses compare without case; Solana's base58 is case-sensitive.
    static func key(_ address: String) -> String { address.hasPrefix("0x") ? address.lowercased() : address }

    static func delete(id: String) { SecItemDelete(query(id) as CFDictionary) }
}

/// The Hyperliquid agent key: data-protection Keychain, this device, no Touch ID — it cannot withdraw.
enum AgentStore {
    /// Per wallet: each wallet's Hyperliquid account approves its own trading key.
    static func query(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.lala.agent",
            kSecAttrAccount as String: Wallets.scoped("hyperliquid", id),
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
    /// `id`: a wallet's, or «ledger-0x…» for the key a Ledger approved for its own account.
    static func load(id: String = Wallets.activeID) -> Data? {
        var q = query(id)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    /// 32 random bytes that make a valid secp256k1 key; retried in the vanishing case they don't.
    static func make() throws -> Data {
        for _ in 0..<4 {
            var bytes = Data(count: 32)
            guard bytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else { continue }
            if (try? EVMAccount.address(privateKey: bytes)) != nil { return bytes }
        }
        throw WalletError("Couldn't create the agent key.")
    }

    static func save(_ key: Data, id: String = Wallets.activeID) throws {
        SecItemDelete(query(id) as CFDictionary)
        var q = query(id)
        q[kSecValueData as String] = key
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw WalletError("Keychain didn't save the agent key: \(status)") }
    }

    static func delete(id: String) { SecItemDelete(query(id) as CFDictionary) }
}
