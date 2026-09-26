import Foundation
import LocalAuthentication
import Security
import WalletCore

/// The seed in the data-protection Keychain: this device only, never synced, readable only by the signer's
/// own access group. With `requirePresence`, every read asks for Touch ID or the login password.
/// ponytail: the seed is ordinary Swift memory while signing and is not zeroed afterwards.
enum SeedStore {
    static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.lala.seed",
            kSecAttrAccount as String: "default",
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static var exists: Bool {
        var q = base
        q[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func save(_ seed: Data, requirePresence: Bool) throws {
        SecItemDelete(base as CFDictionary)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           requirePresence ? .userPresence : [], &error) else {
            throw WalletError("Couldn't set access to the key: \(error.map { "\($0.takeRetainedValue())" } ?? "?")")
        }
        var q = base
        q[kSecValueData as String] = seed
        q[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw WalletError("Keychain didn't save the key: \(status) \(SecCopyErrorMessageString(status, nil) as String? ?? "")") }
    }

    /// One Touch ID per trade, not per signature: a context that already authenticated opens the item again
    /// without a prompt, so it is reused for a minute. Every signature still passes the guard.
    nonisolated(unsafe) private static var session: (context: LAContext, since: Date)?
    private static let lock = NSLock()

    static func load(reason: String) throws -> Data {
        var q = base
        q[kSecReturnData as String] = true
        let context: LAContext = lock.withLock {
            if let s = session, Date().timeIntervalSince(s.since) < 60 { return s.context }
            let fresh = LAContext()
            fresh.localizedReason = reason
            session = (fresh, Date())
            return fresh
        }
        q[kSecUseAuthenticationContext as String] = context
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let seed = out as? Data else {
            lock.withLock { session = nil } // a cancelled or failed prompt must not be reused
            throw WalletError(status == errSecItemNotFound ? "No wallet imported." : "Couldn't access the key: \(status)")
        }
        return seed
    }

    static func delete() {
        endSession()
        SecItemDelete(base as CFDictionary)
    }

    /// The next load asks for Touch ID again.
    static func endSession() {
        lock.withLock {
            session?.context.invalidate()
            session = nil
        }
    }
}

/// The Hyperliquid agent key: data-protection Keychain, this device, no Touch ID — it cannot withdraw.
enum AgentStore {
    static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.lala.agent",
            kSecAttrAccount as String: "hyperliquid",
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func load() -> Data? {
        var q = base
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func save(_ key: Data) throws {
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = key
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw WalletError("Keychain didn't save the agent key: \(status)") }
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}
