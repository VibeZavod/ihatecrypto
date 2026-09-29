import Foundation
import LalaCore
import SignerAPI
import SwiftUI
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
        otherTokens = []
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

/// Near the balance: which wallet signs, by its name, with a lock for a Touch ID wallet and «TEST» for a test wallet
/// (no Touch ID). A click lists the wallets: switch (Touch ID), rename, a new test wallet, the key window.
struct WalletChip: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.openWindow) private var openWindow
    var compact = false
    @State private var open = false

    var body: some View {
        if let w = ws.activeWallet {
            Button { open.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: w.isTest ? "flask.fill" : "lock.fill").font(.system(size: compact ? 8 : 9, weight: .bold))
                    Text(compact ? String(w.label.prefix(7)) : w.label).font(.ui(compact ? 9 : 11, .semibold)).lineLimit(1)
                    if !compact { Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary) }
                }
                .foregroundStyle(w.isTest ? Color.orange : Color.primary.opacity(0.75))
                .padding(.horizontal, compact ? 6 : 8).frame(height: compact ? 18 : 22)
                .background(Capsule().fill(w.isTest ? Color.orange.opacity(0.14) : Brand.glassFill))
                .overlay(Capsule().strokeBorder(open ? Brand.accent.opacity(0.8) : w.isTest ? Color.orange.opacity(0.45) : Brand.glassRim))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .modifier(HoverLift(radius: 11))
            .help(w.isTest ? "«\(w.label)» signs without Touch ID — a test wallet. Click to switch or rename." : "«\(w.label)» signs, with Touch ID. Click to switch or rename.")
            .popover(isPresented: $open, arrowEdge: compact ? .trailing : .bottom) { WalletMenu { open = false } }
        }
    }
}

private struct WalletMenu: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.openWindow) private var openWindow
    let close: () -> Void
    @State private var renaming: String?
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("WALLETS").font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 4)
            ForEach(ws.wallets) { w in row(w) }
            if let error { Text(error).font(.ui(10)).foregroundStyle(.red).padding(.horizontal, 10).fixedSize(horizontal: false, vertical: true) }
            Divider().padding(.vertical, 6)
            if !ws.wallets.contains(where: \.isTest) {
                MenuRow(title: "New test wallet…", detail: "signs without Touch ID · for a few dollars", icon: "flask") {
                    UserDefaults.standard.set(true, forKey: "newWalletTest")
                    close(); openWindow(id: "import")
                }
            }
            MenuRow(title: "Manage wallets…", detail: "create, import, remove", icon: "key") { close(); openWindow(id: "import") }
            Text("Switching asks for Touch ID. A test wallet signs its moves without it — Claude can test with it; keep only a few dollars there.")
                .font(.ui(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10).padding(.top, 4)
        }
        .padding(.vertical, 12).padding(.horizontal, 6)
        .frame(width: 300)
    }

    private func row(_ w: SignerWallet) -> some View {
        let active = w.id == ws.activeWalletID
        return HStack(spacing: 10) {
            Image(systemName: w.isTest ? "flask.fill" : "lock.fill").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(w.isTest ? Color.orange : Color.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                if renaming == w.id {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).font(.ui(12)).onSubmit { rename(w) }
                } else {
                    Text(w.label).font(.ui(13, .semibold))
                }
                Text((w.isTest ? "Test · no Touch ID · " : "Touch ID · ") + short(w)).font(.ui(10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if active { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Brand.accentInk) }
            Button { renaming = w.id; name = w.label } label: { Image(systemName: "pencil") }
                .buttonStyle(.hoverIcon).help("Rename").accessibilityLabel("Rename \(w.label)")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(active ? Brand.accent.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !active, renaming == nil else { return }
            close()
            Task { await ws.switchWallet(w) }
        }
        .pointerStyle(active ? nil : .link)
    }

    private func short(_ w: SignerWallet) -> String {
        [w.solana.map { "\($0.prefix(4))…\($0.suffix(4))" }, w.evm.map { "\($0.prefix(6))…\($0.suffix(4))" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func rename(_ w: SignerWallet) {
        let label = name
        renaming = nil
        Task {
            do {
                let reply = try await SignerClient().send(.renameWallet(id: w.id, label: label))
                guard reply.ok else { throw WalletError(reply.error ?? "The signer refused.") }
                await ws.loadSigner()
            } catch { self.error = error.localizedDescription }
        }
    }
}
