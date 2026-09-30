import Foundation
import Ledger
import LalaCore
import SignerAPI
import SwiftUI
import TradeExecution
import WalletCore

/// A Ledger the user connected: its public addresses only, on this Mac. It is one more wallet in the list, beside the
/// ones the signing process holds; while it is the active one, every move is signed on the device, where the person
/// reads it and presses the buttons. Nothing about it is secret, so it needs no Keychain and no signer.
struct LedgerAccount: Codable, Equatable {
    static let id = "ledger"
    var label = "Ledger"
    var model: String?
    var evm: String?
    var solana: String?
    var evmPath = LedgerDevice.evmPath
    var solanaPath = LedgerDevice.solanaPath

    var wallet: SignerWallet { SignerWallet(id: Self.id, label: label, kind: "ledger", solana: solana, evm: evm, near: nil) }

    static var saved: LedgerAccount? {
        get { UserDefaults.standard.data(forKey: "ledger").flatMap { try? JSONDecoder().decode(LedgerAccount.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "ledger") }
    }

    /// Whether the Ledger, not the signing process, signs now. Switching to it needs no Touch ID: the device asks for
    /// its buttons on every move anyway.
    static var active: Bool {
        get { saved != nil && UserDefaults.standard.bool(forKey: "ledgerActive") }
        set { UserDefaults.standard.set(newValue, forKey: "ledgerActive") }
    }
}

/// The connect flow's progress on the canvas.
struct LedgerConnect: Equatable {
    var model: String?
    var evm: String?
    var solana: String?
    /// What the person has to do now, or what just happened.
    var status = "Looking for a Ledger on USB…"
    var problem: String?
    /// Settings on the device the person should change (blind signing off, an app not installed).
    var notes: [String] = []
    var busy = true
}

extension Workspace {
    var ledgerActive: Bool { activeWallet?.kind == "ledger" }

    /// The signer a move uses while the Ledger is active; the canvas shows what the device waits for.
    func ledgerSigner(_ wallet: TradeWallet) -> LedgerSigner {
        let account = LedgerAccount.saved ?? LedgerAccount()
        return LedgerSigner(device: LedgerDevice(LedgerHID()), wallet: wallet, evmPath: account.evmPath, solanaPath: account.solanaPath) { text in
            Task { @MainActor in SignerActivity.shared.ledger = text }
        }
    }

    /// «connect ledger», «подключи леджер», «use my Ledger»: true when the message was about the Ledger.
    func ledgerCommand(_ text: String) async -> Bool {
        let lower = text.lowercased()
        guard lower.contains(/ledger|л[еэ]дж[еэ]р/) else { return false }
        if lower.wholeMatch(of: /\s*(?:use|switch\s+to|sign\s+with|используй|переключи\w*\s+на|подписывай\s+(?:с|на))\s+(?:my\s+|мой\s+|моём\s+|мо[йеё]м?\s+)?(?:ledger|л[еэ]дж[еэ]р\w*)\s*[.!]?\s*/) != nil,
           let account = LedgerAccount.saved {
            await switchWallet(account.wallet)
            return true
        }
        if lower.wholeMatch(of: /\s*(?:forget|remove|disconnect|забудь|удали|отключи)\s+(?:my\s+|мой\s+)?(?:ledger|л[еэ]дж[еэ]р\w*)\s*[.!]?\s*/) != nil {
            await forgetLedger()
            return true
        }
        if lower.wholeMatch(of: /\s*(?:(?:connect|add|pair|set\s*up|link|подключи\w*|добавь|привяжи|подсоедини)\s+(?:my\s+|a\s+|мой\s+)?)?(?:ledger|л[еэ]дж[еэ]р\w*)(?:\s+(?:nano\s*\w*|flex|stax))?\s*[.!?]?\s*/) != nil {
            // The card on the canvas follows it; the chat stays free while the person is at the device.
            Task { await connectLedger() }
            return true
        }
        return false
    }

    /// Finds the Ledger, opens its Ethereum and Solana apps in turn and reads one address from each. Nothing is signed;
    /// the addresses become the «Ledger» wallet in the list.
    func connectLedger() async {
        ledgerConnect = LedgerConnect()
        reply(say("Connecting your Ledger — follow the card on the canvas.", "Подключаю Ledger — следи за карточкой на холсте."))
        let device = LedgerDevice(LedgerHID())
        var found = LedgerHID.connected()
        for _ in 0..<60 where found == nil {
            ledgerConnect?.status = "Plug your Ledger in over USB and unlock it with your PIN."
            try? await Task.sleep(for: .seconds(1))
            guard ledgerConnect != nil else { return }
            found = LedgerHID.connected()
        }
        guard let model = found else {
            ledgerConnect?.problem = "No Ledger showed up on USB in a minute. Plug it in, unlock it and press Try again."
            ledgerConnect?.busy = false
            return
        }
        ledgerConnect?.model = model
        var account = LedgerAccount.saved ?? LedgerAccount()
        account.model = model
        do {
            ledgerConnect?.status = "Open the Ethereum app on your Ledger — or allow it when the Ledger asks."
            try await device.open("Ethereum")
            account.evm = try await device.evmAddress(account.evmPath)
            ledgerConnect?.evm = account.evm
            if let blind = try? await device.evmBlindSigning(), !blind.on {
                ledgerConnect?.notes.append("Ethereum \(blind.version): turn on «Blind signing» in the app's settings for swaps, Aave, Morpho and Hyperliquid orders. Plain sends work without it.")
            }
            ledgerConnect?.status = "Now the Solana app: allow it when the Ledger asks."
            do {
                try await device.open("Solana")
                account.solana = try await device.solanaAddress(account.solanaPath)
                ledgerConnect?.solana = account.solana
                if let blind = try? await device.solanaBlindSigning(), !blind.on {
                    ledgerConnect?.notes.append("Solana \(blind.version): turn on «Blind signing» in the app's settings for USDC transfers, Jupiter swaps and lending. SOL sends work without it.")
                }
            } catch let e as LedgerError where e.status == 0x6807 {
                ledgerConnect?.notes.append("No Solana app on this Ledger: add it in Ledger Live › My Ledger, then connect again. Until then it signs EVM moves only.")
            }
            LedgerAccount.saved = account
            await loadSigner()
            ledgerConnect?.status = ledgerActive ? "Connected. It signs every move now." : "Connected. Switch to it to sign with it."
        } catch {
            if account.evm != nil { LedgerAccount.saved = account; await loadSigner() }
            ledgerConnect?.problem = error.localizedDescription
        }
        ledgerConnect?.busy = false
    }

    /// Shows one of the Ledger's addresses on its own screen, for comparing with the one in ihatecrypto: what the
    /// device says is the truth even if this Mac is not.
    func showOnLedger(solana: Bool) async {
        guard let account = LedgerAccount.saved else { return }
        let device = LedgerDevice(LedgerHID())
        ledgerConnect?.problem = nil
        ledgerConnect?.status = "Compare the address on your Ledger with the one here, then approve it there."
        do {
            if solana {
                try await device.open("Solana")
                _ = try await device.solanaAddress(account.solanaPath, show: true)
            } else {
                try await device.open("Ethereum")
                _ = try await device.evmAddress(account.evmPath, show: true)
            }
            ledgerConnect?.status = "The Ledger showed the same address."
        } catch {
            ledgerConnect?.problem = error.localizedDescription
        }
    }

    /// Takes the Ledger off the list (its addresses only; nothing is on this Mac to wipe). The signing process's
    /// wallet signs again.
    func forgetLedger() async {
        guard LedgerAccount.saved != nil else { reply("No Ledger is connected."); return }
        LedgerAccount.active = false
        LedgerAccount.saved = nil
        ledgerConnect = nil
        await loadSigner()
        reply("Ledger removed from the wallet list. The money on it stays on it; connect it again any time.")
        await refresh()
    }
}

/// A Ledger drawn plainly: the Nano's body with its screen and swivel ring, in the app's ink.
struct LedgerGlyph: View {
    var size: CGFloat = 28
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: size * 0.16).fill(Color.primary)
                .frame(width: size, height: size * 0.42)
            RoundedRectangle(cornerRadius: size * 0.05).fill(Brand.accent)
                .frame(width: size * 0.42, height: size * 0.2).offset(x: size * 0.1)
            Circle().strokeBorder(Color.primary.opacity(0.5), lineWidth: size * 0.05)
                .frame(width: size * 0.34).offset(x: size * 0.62)
        }
        .frame(width: size, height: size * 0.5)
        .accessibilityHidden(true)
    }
}

/// «Connect your Ledger» on the canvas: the device, each app's address as it is read, what to do on the device now.
struct LedgerBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if let c = ws.ledgerConnect {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    LedgerGlyph(size: 30)
                    Text("Ledger" + (c.model.map { " · \($0)" } ?? "")).font(.ui(16, .bold))
                    if c.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button { ws.ledgerConnect = nil } label: { Image(systemName: "xmark") }.buttonStyle(.hoverIcon).help("Close")
                }
                row("USB", c.model.map { "\($0) found" }, done: c.model != nil)
                row("ETHEREUM APP · EVM", c.evm.map { "\($0.prefix(6))…\($0.suffix(4))" }, done: c.evm != nil, solana: false)
                row("SOLANA APP", c.solana.map { "\($0.prefix(4))…\($0.suffix(4))" }, done: c.solana != nil, solana: true)
                Label(c.status, systemImage: c.busy ? "hand.point.up.left.fill" : "checkmark.seal.fill")
                    .font(.ui(12, .semibold)).foregroundStyle(c.busy ? Brand.accentInk : Brand.profit)
                if let problem = c.problem {
                    HStack(alignment: .top) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").font(.ui(11)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Try again") { Task { await ws.connectLedger() } }.controlSize(.small)
                    }
                }
                ForEach(c.notes, id: \.self) { note in
                    Label(note, systemImage: "gearshape").font(.ui(10.5)).foregroundStyle(Brand.jevInk).fixedSize(horizontal: false, vertical: true)
                }
                if !c.busy, let account = LedgerAccount.saved {
                    HStack(spacing: 8) {
                        if !ws.ledgerActive {
                            Button { Task { await ws.switchWallet(account.wallet) } } label: {
                                Label("Sign with Ledger", systemImage: "signature").font(.ui(13, .semibold)).padding(.horizontal, 6)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                        Button("Forget") { Task { await ws.forgetLedger() } }.controlSize(.large)
                    }
                }
                Text("The keys never leave the Ledger. ihatecrypto checks every move first — only your own addresses, no unlimited approvals — then the Ledger shows it, and nothing is signed until you approve it on the device.")
                    .font(.ui(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(width: 470, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 26).fill(Brand.card).shadow(color: .black.opacity(0.08), radius: 18, y: 10))
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Brand.accent.opacity(0.5), lineWidth: 1.5))
            .transition(.opacity)
        }
    }

    private func row(_ label: String, _ value: String?, done: Bool, solana: Bool? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(done ? Brand.profit : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.ui(9, .heavy)).tracking(0.4).opacity(0.7)
                Text(value ?? "—").font(value == nil ? .ui(13) : .system(size: 13, weight: .semibold, design: .monospaced))
            }
            Spacer()
            if done, let solana, ws.ledgerConnect?.busy == false {
                Button("Show on Ledger") { Task { await ws.showOnLedger(solana: solana) } }.controlSize(.small)
                    .help("The Ledger shows this address on its own screen, to compare")
            }
        }
    }
}
