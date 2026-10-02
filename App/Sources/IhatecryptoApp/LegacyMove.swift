import AppKit
import Foundation
import os
import Security
import SignerAPI

/// The move from LALA (app.lala.mac) to ihatecrypto (app.ihatecrypto.mac), once, on a Mac that ran LALA. The settings,
/// Application Support/LALA and ~/.lala are copied. The model logins come along when the Keychain hands them over
/// without a prompt; otherwise the user signs in again. LALA's keep-running agent and LALA itself stop, so two copies
/// never run the same tasks. The wallets move inside the signer (`adoptWallets`). LALA's own copies stay as they were.
enum LegacyMove {
    static let oldID = "app.lala.mac"
    private static let copied = "movedFromLALA", walletsMoved = "walletsMovedFromLALA"

    /// Before anything reads the settings or Application Support (AppMain.init).
    static func copyData() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: copied) else { return }
        defer { d.set(true, forKey: copied) }
        guard let old = d.persistentDomain(forName: oldID) else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: oldID) { app.terminate() }
        for (key, value) in old where d.object(forKey: key) == nil { d.set(value, forKey: key) }
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        for (from, to) in [(URL.applicationSupportDirectory.appending(path: "LALA"), URL.applicationSupportDirectory.appending(path: "ihatecrypto")),
                           (home.appending(path: ".lala"), home.appending(path: ".ihatecrypto"))]
        where fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
            try? fm.copyItem(at: from, to: to)
        }
        copyLogins()
        let agent = home.appending(path: "Library/LaunchAgents/\(oldID).keeprunning.plist")
        if fm.fileExists(atPath: agent.path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())/\(oldID).keeprunning"]
            try? p.run()
            p.waitUntilExit()
            try? fm.removeItem(at: agent)
            try? KeepRunning.set(true)
        }
    }

    /// LALA's model logins (login Keychain, «app.lala.mac.llm»), each only if macOS gives it without asking.
    private static func copyLogins() {
        let old = oldID + ".llm"
        var out: CFTypeRef?
        let list: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: old,
                                   kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        guard SecItemCopyMatching(list as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return }
        for account in items.compactMap({ $0[kSecAttrAccount as String] as? String }) {
            var data: CFTypeRef?
            let one: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: old, kSecAttrAccount as String: account,
                                      kSecReturnData as String: true, kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip]
            guard SecItemCopyMatching(one as CFDictionary, &data) == errSecSuccess, let data = data as? Data else { continue }
            var q = Keychain.query(account)
            SecItemDelete(q as CFDictionary)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    /// Once the signer answers: LALA's wallets move inside it, Touch ID once. The old signer's list (labels, which wallet
    /// is the automation one) is read from its container, if macOS allows; the signer derives every address again
    /// itself. A Mac that never ran LALA has nothing to move, and that's recorded too.
    static func adoptWallets() async {
        let d = UserDefaults.standard
        guard SignerClient.isAvailable, !d.bool(forKey: walletsMoved), let status = try? await SignerClient().send(.status) else { return }
        guard status.hasWallet != true else { d.set(true, forKey: walletsMoved); return }
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/\(oldID).signer/Data/Library/Preferences/\(oldID).signer.plist")
        let old = (try? Data(contentsOf: container)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let registry = (old["wallets"] as? Data).flatMap { try? JSONDecoder().decode([SignerWallet].self, from: $0) } ?? []
        do {
            let reply = try await SignerClient().send(.adoptLegacy(registry: registry, active: old["activeWallet"] as? String))
            if reply.ok || reply.error?.contains("No wallets under LALA's names") == true { d.set(true, forKey: walletsMoved) }
            Logger.move.notice("LALA's wallets: \(reply.ok ? "moved \(reply.wallets?.count ?? 0)" : reply.error ?? "?", privacy: .public)")
        } catch {
            Logger.move.notice("LALA's wallets: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Logger {
    /// `log show --predicate 'subsystem == "app.ihatecrypto.mac" && category == "move"'`
    static let move = Logger(subsystem: "app.ihatecrypto.mac", category: "move")
}
