import AppKit
import SignerAPI
import SwiftUI
import WalletCore

/// Separate window, away from the chat: the phrase never passes through the model, the chat or a log.
/// Inside ihatecrypto.app the phrase can go to the signing process, which keeps the seed in the Keychain; the app
/// itself keeps only public addresses and drops the phrase as soon as it is used.
struct ImportWalletView: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var passphrase = ""
    @State private var accounts: [(evm: String, solana: String)] = []
    @State private var error: String?
    @State private var store = false
    @State private var requirePresence = true
    @State private var stored: String?
    /// A phrase the signer just made, shown once for the paper backup and dropped after «I wrote it down».
    @State private var newPhrase: [String]?
    @State private var creating = false
    /// The clipboard's change count right after the phrase was copied: it is wiped only while it still holds it.
    @State private var copiedChange: Int?
    /// A private key pasted from Phantom or MetaMask: recognized and shown as its address before anything is saved.
    @State private var privateKey = ""
    @State private var renaming: String?
    @State private var draftName = ""
    @State private var removing: SignerWallet?

    var body: some View {
        Form {
            if SignerClient.isAvailable, !ws.wallets.isEmpty { walletList }
            if SignerClient.isAvailable { create }
            Section("Import a phrase") {
                SecureField("12 or 24 words separated by spaces", text: $phrase)
                SecureField("Extra passphrase, if any", text: $passphrase)
                if SignerClient.isAvailable {
                    Toggle("Save the key in secure storage to sign", isOn: $store)
                    // A Release signer always asks: the toggle exists only for automated checks in Debug builds.
                    #if DEBUG
                    if store {
                        Toggle("Ask for Touch ID or password on every signature", isOn: $requirePresence)
                    }
                    #endif
                }
                Text(store
                     ? "The phrase goes only to the separate signer, which has no network access. It keeps the key sealed by this Mac's Secure Enclave and signs only what passes the guard, after Touch ID or your password. It is added next to your other wallets; adding one when there is a wallet already asks for Touch ID."
                     : "The phrase isn't saved or sent anywhere. The app takes only the public addresses from it to show balances. Try the test phrase first.")
                    .font(.ui(10)).foregroundStyle(.secondary)
                Button(store ? "Save and show addresses" : "Show addresses", action: derive).disabled(phrase.isEmpty)
                if let stored { Text(stored).font(.ui(10)).foregroundStyle(.green) }
                if let error { Text(error).font(.ui(10)).foregroundStyle(.red) }
            }
            if SignerClient.isAvailable { keyImport }
            if !accounts.isEmpty {
                Section("Compare with MetaMask and Phantom") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("#").foregroundStyle(.secondary)
                            Text("EVM · Hyperliquid  m/44'/60'/0'/0/i").foregroundStyle(.secondary)
                            Text("Solana  m/44'/501'/i'/0'").foregroundStyle(.secondary)
                        }
                        .font(.ui(10))
                        ForEach(accounts.indices, id: \.self) { i in
                            GridRow {
                                Text("\(i)").foregroundStyle(.secondary)
                                Text(accounts[i].evm).textSelection(.enabled)
                                Text(accounts[i].solana).textSelection(.enabled)
                            }
                            .font(.system(.caption, design: .monospaced))
                        }
                    }
                    Button("Watch balances for addresses #0") {
                        ws.hlAddress = accounts[0].evm
                        ws.solanaAddress = accounts[0].solana
                        accounts = []
                        dismiss()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 760)
        .onDisappear { phrase = ""; passphrase = ""; privateKey = ""; accounts = []; newPhrase = nil; wipeCopied() }
        // While the words are on screen, screenshots, recordings and screen sharing get a blank window.
        .onChange(of: newPhrase == nil) { _, hidden in NSApp.keyWindow?.sharingType = hidden ? .readOnly : .none }
        .onAppear {
            #if DEBUG
            // `-demoImport YES`: the public BIP-39 test phrase, for screenshots and checks only.
            if UserDefaults.standard.bool(forKey: "demoImport") {
                phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
                derive()
            }
            #endif
        }
    }

    /// «Create a new wallet»: the signer makes the phrase; the words appear once, numbered, not selectable — for paper,
    /// or copied all at once into a password manager. After that nothing can read them: the signer has no request
    /// that returns the phrase.
    @ViewBuilder private var create: some View {
        Section("New wallet") {
            if let words = newPhrase {
                Text("Write these 12 words on paper, in order. They are the only way back to this wallet if the Mac is lost or wiped; ihatecrypto won't show them again.")
                    .font(.ui(12))
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(0..<3, id: \.self) { row in
                        GridRow {
                            ForEach(0..<4, id: \.self) { column in
                                let i = row * 4 + column
                                HStack(spacing: 6) {
                                    Text("\(i + 1)").foregroundStyle(.secondary).monospacedDigit().frame(width: 20, alignment: .trailing)
                                    Text(words[i]).font(.system(.body, design: .monospaced).weight(.semibold))
                                }
                            }
                        }
                    }
                }
                .textSelection(.disabled)
                .padding(.vertical, 4)
                Text("Never type them into a website, a chat or a photo. Anyone with these words owns the money.")
                    .font(.ui(10)).foregroundStyle(.orange)
                HStack(spacing: 10) {
                    Button("I wrote them down") { newPhrase = nil; wipeCopied() }.buttonStyle(.borderedProminent)
                    Button(copiedChange == nil ? "Copy all 12 words" : "Copied", systemImage: "doc.on.doc") { copy(words) }
                }
                if copiedChange != nil {
                    Text("Paste them into your password manager now. The clipboard is wiped in 60 s or when you press «I wrote them down»; the words don't go to your other devices or to clipboard history apps.")
                        .font(.ui(10)).foregroundStyle(.secondary)
                }
            } else {
                Text("ihatecrypto makes a new 12-word recovery phrase inside the signer, from this Mac's random number generator, and keeps the key sealed by the Secure Enclave. Every signature asks for Touch ID or your password."
                     + (ws.signerWallet == nil ? "" : " It is added next to your other wallets and signs until you switch back."))
                    .font(.ui(10)).foregroundStyle(.secondary)
                HStack {
                    Button("Create a new wallet", action: createWallet).disabled(creating)
                    if creating { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    /// Every wallet in the signer: which one signs, switching (Touch ID), a name of the user's own, removal.
    @ViewBuilder private var walletList: some View {
        Section("Your wallets") {
            ForEach(ws.wallets) { w in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: w.id == ws.activeWalletID ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(w.id == ws.activeWalletID ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        if renaming == w.id {
                            TextField("Name", text: $draftName).onSubmit { rename(w) }.frame(maxWidth: 220)
                        } else {
                            Text(w.label).font(.ui(13, .semibold))
                        }
                        Text(Workspace.describe(w)).font(.ui(10)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if w.id == ws.activeWalletID {
                        Text("signs now").font(.ui(10)).foregroundStyle(.green)
                    } else {
                        Button("Use this one") { Task { await ws.switchWallet(w) } }
                    }
                    Button { renaming = w.id; draftName = w.label } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("Rename").accessibilityLabel("Rename \(w.label)")
                    Button(role: .destructive) { removing = w } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Remove this wallet").accessibilityLabel("Remove \(w.label)")
                }
            }
            Text("One wallet signs at a time; switching or removing one asks for Touch ID. Each keeps its own trading key and approved addresses. In the chat: «переключись на кошелёк \(ws.wallets.first?.label ?? "Main")».")
                .font(.ui(10)).foregroundStyle(.secondary)
        }
        .confirmationDialog("Remove «\(removing?.label ?? "")»?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove the wallet", role: .destructive) {
                guard let w = removing else { return }
                Task {
                    do {
                        let reply = try await SignerClient().send(.removeWallet(id: w.id))
                        guard reply.ok else { throw WalletError(reply.error ?? "The signer refused.") }
                        await ws.loadSigner()
                        await ws.refresh()
                    } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("Only if its recovery phrase or key is written down: without it the money on this wallet can't be reached from here again. The money itself stays where it is.")
        }
    }

    private func rename(_ w: SignerWallet) {
        let name = draftName
        renaming = nil
        Task {
            do {
                let reply = try await SignerClient().send(.renameWallet(id: w.id, label: name))
                guard reply.ok else { throw WalletError(reply.error ?? "The signer refused.") }
                await ws.loadSigner()
            } catch { self.error = error.localizedDescription }
        }
    }

    /// A single private key: Phantom's Solana key (base58, or a key file's 64 numbers) or MetaMask's EVM key (hex).
    /// Recognized here as it is pasted and shown as its address to compare; only «Save» sends it to the signer.
    @ViewBuilder private var keyImport: some View {
        Section("Import a private key") {
            SecureField("Solana key from Phantom, or EVM key from MetaMask", text: $privateKey)
            switch privateKey.isEmpty ? nil : Result(catching: { try ImportedKey.parse(privateKey) }) {
            case .success(let key)?:
                LabeledContent(key.chain, value: (try? key.address()) ?? "?")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("Compare it with \(key.chain == "Solana" ? "Phantom" : "MetaMask") before saving. This wallet signs only on \(key.chain); for the other chains, switch wallets.")
                    .font(.ui(10)).foregroundStyle(.secondary)
                Button("Save as a wallet", action: importKey).buttonStyle(.borderedProminent)
            case .failure(let e)?:
                Text(e.localizedDescription).font(.ui(10)).foregroundStyle(.red)
            case nil:
                Text("The key goes only to the separate signer, which seals it with this Mac's Secure Enclave like a phrase and never shows it again.")
                    .font(.ui(10)).foregroundStyle(.secondary)
            }
        }
    }

    private func importKey() {
        let key = privateKey
        privateKey = ""
        Task {
            do {
                let reply = try await SignerClient().send(.importPrivateKey(key: key))
                guard reply.ok else { throw WalletError(reply.error ?? "The signer refused.") }
                stored = "Key saved as a wallet: \(reply.solanaAddress ?? reply.evmAddress ?? "?"). It signs now."
                await ws.loadSigner()
                await ws.refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// All 12 words at once, for a password manager: marked concealed and transient so clipboard history apps skip
    /// them, kept on this Mac (no Universal Clipboard), and wiped after 60 s unless something else was copied since.
    private func copy(_ words: [String]) {
        let board = NSPasteboard.general
        board.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(words.joined(separator: " "), forType: .string)
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
        board.writeObjects([item])
        let change = board.changeCount
        copiedChange = change
        Task {
            try? await Task.sleep(for: .seconds(60))
            if copiedChange == change { wipeCopied() }
        }
    }

    private func wipeCopied() {
        if let change = copiedChange, NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
        copiedChange = nil
    }

    private func createWallet() {
        creating = true
        error = nil
        Task {
            defer { creating = false }
            do {
                let reply = try await SignerClient().send(.createWallet(requirePresence: true))
                guard reply.ok, let phrase = reply.phrase else { throw WalletError(reply.error ?? "The signer refused.") }
                newPhrase = phrase.split(separator: " ").map(String.init)
                stored = "New wallet: Solana \(reply.solanaAddress ?? "?"), EVM \(reply.evmAddress ?? "?")."
                await ws.loadSigner()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func derive() {
        if store {
            let request = SignerRequest.importMnemonic(phrase: phrase, passphrase: passphrase, requirePresence: requirePresence)
            Task {
                do {
                    let reply = try await SignerClient().send(request)
                    guard reply.ok else { throw WalletError(reply.error ?? "The signer refused.") }
                    stored = "Key saved. Wallet: Solana \(reply.solanaAddress ?? "?"), EVM \(reply.evmAddress ?? "?")."
                    await ws.loadSigner()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        do {
            let seed = try Mnemonic.seed(phrase, passphrase: passphrase)
            accounts = try (0..<3).map { i in
                (try EVMAccount.address(privateKey: Derivation.secp256k1(seed: seed, path: WalletPath.evm(i))),
                 try SolanaAccount.address(privateKey: Derivation.ed25519(seed: seed, path: WalletPath.solana(i))))
            }
            error = nil
        } catch {
            accounts = []
            self.error = error.localizedDescription
        }
        phrase = ""
        passphrase = ""
    }
}
