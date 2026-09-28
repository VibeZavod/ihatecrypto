import Foundation
import LalaCore
import SignerAPI
import WalletCore

/// Several wallets in the signer, one of which signs. The signer owns that choice (switching takes Touch ID there);
/// the app follows it: its addresses, balances and positions, and what it keeps on this Mac per wallet.
extension Workspace {
    /// A per-wallet key for state kept on this Mac; wallet «1» keeps the names it had before there were several.
    static func scoped(_ base: String, _ id: String? = UserDefaults.standard.string(forKey: "activeWalletID")) -> String {
        guard let id, id != SignerWallet.firstID else { return base }
        return "\(base)-\(id)"
    }

    var activeWallet: SignerWallet? { wallets.first { $0.id == activeWalletID } }

    /// Another wallet signs now. Nothing of the last one may carry over: a card waiting for Confirm is dropped (it was
    /// built for the other wallet), its balances and positions go, and its exit rules, recurring buys and portfolio
    /// curve are put away under its id while the new wallet's come back.
    func walletChanged(to id: String?) {
        activeWalletID = id
        pendingAction = nil
        pendingText = nil
        pendingAllocation = nil
        allocationPreview = nil
        awaitingAmount = nil
        takeChoices = nil
        positions = []
        orders = []
        recentlyClosed = nil
        hl = nil
        dexBalances = [:]
        hlp = (0, nil)
        solana = nil
        lend = []
        kamino = 0
        near = 0
        base = nil
        arbitrumUSDC = nil
        robinhood = nil
        tokenBalances = [:]
        updatedAt = nil
        schedules = UserDefaults.standard.data(forKey: Self.scoped("schedules", id)).flatMap { try? JSONDecoder().decode([Schedule].self, from: $0) } ?? []
        tasks = UserDefaults.standard.data(forKey: Self.scoped("tasks", id)).flatMap { try? JSONDecoder().decode([ScheduledTask].self, from: $0) } ?? []
        taskQueue = nil
        exitRules = UserDefaults.standard.data(forKey: Self.scoped("exitRules", id)).flatMap { try? JSONDecoder().decode([String: ExitRules].self, from: $0) } ?? [:]
        equityHistory = LocalStore.load(Self.scoped("equity", id) + ".json") ?? []
    }

    /// Asks the signer to sign with `wallet` (Touch ID there), then reads everything for it.
    func switchWallet(_ wallet: SignerWallet, note: String? = nil) async {
        guard wallet.id != activeWalletID else {
            reply("«\(wallet.label)» is already the wallet ihatecrypto signs with.", note: note)
            return
        }
        do {
            let reply = try await SignerClient().send(.setActiveWallet(id: wallet.id))
            guard reply.ok else { throw WalletError(reply.error ?? "The signer refused.") }
            await loadSigner()
            self.reply("Now signing with «\(wallet.label)»: \(Self.describe(wallet)).", note: note)
            await refresh()
        } catch {
            reply("The wallet wasn't switched: \(error.localizedDescription)", note: note)
        }
    }

    /// «Main · phrase: Solana AN5b…e8cL, EVM 0x1523…F656» — what a wallet can sign for.
    static func describe(_ w: SignerWallet) -> String {
        func short(_ s: String) -> String { "\(s.prefix(4))…\(s.suffix(4))" }
        let kind = w.kind == "phrase" ? "recovery phrase" : w.kind == "solana" ? "Solana key only" : "EVM key only"
        let parts = [w.solana.map { "Solana \(short($0))" }, w.evm.map { "EVM \(short($0))" }, w.near.map { "NEAR \(short($0))" }].compactMap { $0 }
        return "\(kind) · " + parts.joined(separator: ", ")
    }

    /// «переключись на кошелёк Main», «switch to wallet Trading»: the wallet it names, by its name. An exact app
    /// command like «new canvas», read before the model so a wallet's name can't be taken for something else.
    func walletSwitch(_ text: String) -> SignerWallet?? {
        guard let m = text.firstMatch(of: /(?i)^\s*(?:переключ\w*|switch|use|используй)\s+(?:на\s+|to\s+)?(?:кошел[её]к\w*|wallet)\s+[«"“]?(.+?)[»"”]?\s*[.!]?\s*$/) else { return nil }
        let name = String(m.1).lowercased()
        return .some(wallets.first { $0.label.lowercased() == name } ?? wallets.first { $0.label.lowercased().hasPrefix(name) })
    }

    /// The key a wallet command needs that the active wallet doesn't have, said plainly. A phrase wallet has them all;
    /// a key wallet only its own chain's.
    func missingKey(for command: WalletCommand) -> String? {
        guard let wallet = activeWallet, wallet.kind != "phrase" else { return nil }
        let chains: [String] = switch command {
        case .yields, .receive, .stopSchedules: []
        case .hlp: ["evm"]
        case .withdrawToSolana, .aave, .morpho, .baseToSolana, .arbitrumToSolana, .robinhoodToSolana, .solanaTo, .buyStock, .sellStock, .buyOn, .sellOn: ["evm", "solana"]
        case .sendNear, .closeNear: ["near"]
        case .buyNear, .sellNear: ["solana", "near"]
        default: ["solana"]   // spot, vaults, staking, sends: all on Solana
        }
        return chains.lazy.compactMap { wallet.missing($0) }.first
    }

    /// Trading on Hyperliquid (plans, positions) signs with the EVM key.
    var missingTradingKey: String? { activeWallet?.missing("evm") }
}
