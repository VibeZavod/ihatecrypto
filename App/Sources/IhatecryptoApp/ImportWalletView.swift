import AppKit
import SignerAPI
import SwiftUI
import WalletCore

/// The old «Import wallet» window (Debug `-demoImport` opens it): the same wallet management as Settings › Wallet.
struct ImportWalletView: View {
    var body: some View {
        ScrollView { WalletManagement().padding(24) }.frame(width: 720, height: 680)
    }
}

/// Settings › Wallet: the wallets in the signer, and adding one — created here, or from a phrase or a key. The words
/// never pass through the model, the chat or a log: Settings cover the canvas and its chat while open. Inside
/// ihatecrypto.app the phrase can go to the signing process, which keeps the seed in the Keychain; the app itself keeps
/// only public addresses and drops the phrase as soon as it is used.
struct WalletManagement: View {
    @Environment(Workspace.self) private var ws
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
    /// Which way of adding a wallet is open; the others stay one line each.
    @State private var adding: Adding?
    /// «New test wallet…» in the rail's wallet menu opens Settings › Wallet with it chosen.
    @AppStorage("newWalletTest") private var newTest = false

    enum Adding { case create, phrase, key }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if SignerClient.isAvailable, !ws.wallets.isEmpty { walletList }
            SettingsSection(icon: "plus.circle", title: "Add a wallet", line: "Make a new one here, or bring a phrase or a key from another app.") {
                SettingsGroup {
                    if SignerClient.isAvailable {
                        way(.create, "Create a new wallet", "12 new words, made inside the signer", icon: "sparkles")
                        if adding == .create || newPhrase != nil { panel { create } }
                    }
                    way(.phrase, "Import a recovery phrase", "12 or 24 words from MetaMask, Phantom or another wallet", icon: "text.word.spacing")
                    if adding == .phrase { panel { importPhrase } }
                    if SignerClient.isAvailable {
                        way(.key, "Import a private key", "One key from Phantom (Solana) or MetaMask (EVM)", icon: "key")
                        if adding == .key { panel { keyImport } }
                    }
                }
                if let stored { Text(stored).font(.ui(11)).foregroundStyle(Brand.profit).fixedSize(horizontal: false, vertical: true) }
                if let error { Text(error).font(.ui(11)).foregroundStyle(Brand.loss).fixedSize(horizontal: false, vertical: true) }
            }
            if !accounts.isEmpty { compare }
        }
        .onDisappear { phrase = ""; passphrase = ""; privateKey = ""; accounts = []; newPhrase = nil; newTest = false; wipeCopied() }
        // While the words are on screen, screenshots, recordings and screen sharing get a blank window.
        .onChange(of: newPhrase == nil) { _, hidden in NSApp.keyWindow?.sharingType = hidden ? .readOnly : .none }
        .onAppear {
            if newTest { adding = .create }
            #if DEBUG
            // `-demoImport YES`: the public BIP-39 test phrase, for screenshots and checks only.
            if UserDefaults.standard.bool(forKey: "demoImport") {
                adding = .phrase
                phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
                derive()
            }
            #endif
        }
    }

    /// One way of adding a wallet as a row; a click opens it under the row and closes the others.
    private func way(_ kind: Adding, _ title: String, _ line: String, icon: String) -> some View {
        Button {
            adding = adding == kind ? nil : kind
            error = nil
            if adding != .create { newTest = false }
        } label: {
            HStack(spacing: 10) {
                SettingsIcon(icon: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(13, .semibold))
                    Text(line).font(.ui(11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: adding == kind ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 48).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Brand.cardBorder.opacity(0.65).frame(height: 0.5).padding(.leading, 50) }
        }
        .buttonStyle(.plain).accessibilityAddTraits(adding == kind ? [.isSelected] : [])
    }

    /// A switch in the accent, like the rest of Settings (a checkbox here was the system blue).
    private func option(_ title: String, _ on: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.ui(12.5))
            Spacer(minLength: 8)
            Toggle(title, isOn: on).toggleStyle(AccentSwitch())
        }
    }

    private func panel(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(.leading, 50).padding(.trailing, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Brand.cardBorder.opacity(0.65).frame(height: 0.5).padding(.leading, 50) }
    }

    @ViewBuilder private var importPhrase: some View {
        SecureField("12 or 24 words separated by spaces", text: $phrase).textFieldStyle(.roundedBorder)
        SecureField("Extra passphrase, if any", text: $passphrase).textFieldStyle(.roundedBorder)
        if SignerClient.isAvailable {
            option("Save the key in secure storage to sign", $store)
            // A Release signer always asks: the toggle exists only for automated checks in Debug builds.
            #if DEBUG
            if store {
                option("Ask for Touch ID or password on every signature", $requirePresence)
            }
            #endif
        }
        Text(store
             ? "The phrase goes only to the separate signer, which has no network access. It keeps the key sealed by this Mac's Secure Enclave and signs only what passes the guard, after Touch ID or your password. It is added next to your other wallets; adding one when there is a wallet already asks for Touch ID."
             : "The phrase isn't saved or sent anywhere. The app takes only the public addresses from it to show balances. Try the test phrase first.")
            .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Button(store ? "Save and show addresses" : "Show addresses", action: derive).disabled(phrase.isEmpty)
    }

    private var compare: some View {
        SettingsSection(icon: "list.number", title: "Compare with MetaMask and Phantom", line: "The first addresses this phrase makes.") {
            SettingsGroup {
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
                .padding(14)
                SettingsRow("Watch these balances", icon: "eye", info: "Puts address #0 into «Addresses for balances»; nothing goes to the signer.") {
                    Button("Watch #0") {
                        ws.hlAddress = accounts[0].evm
                        ws.solanaAddress = accounts[0].solana
                        accounts = []
                        stored = "Watching the balances of address #0."
                    }
                }
            }
        }
    }

    /// «Create a new wallet»: the signer makes the phrase; the words appear once, numbered, not selectable — for paper,
    /// or copied all at once into a password manager. After that nothing can read them: the signer has no request
    /// that returns the phrase.
    @ViewBuilder private var create: some View {
        if let words = newPhrase {
            Text("Write these 12 words on paper, in order. They are the only way back to this wallet if the Mac is lost or wiped; ihatecrypto won't show them again.")
                .font(.ui(12)).fixedSize(horizontal: false, vertical: true)
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
                .font(.ui(11)).foregroundStyle(Brand.jevInk)
            HStack(spacing: 10) {
                Button("I wrote them down") { newPhrase = nil; adding = nil; wipeCopied() }.buttonStyle(.borderedProminent)
                Button(copiedChange == nil ? "Copy all 12 words" : "Copied", systemImage: "doc.on.doc") { copy(words) }
            }
            if copiedChange != nil {
                Text("Paste them into your password manager now. The clipboard is wiped in 60 s or when you press «I wrote them down»; the words don't go to your other devices or to clipboard history apps.")
                    .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("ihatecrypto makes a new 12-word recovery phrase inside the signer, from this Mac's random number generator, and keeps the key sealed by the Secure Enclave. Every signature asks for Touch ID or your password."
                 + (ws.signerWallet == nil ? "" : " It is added next to your other wallets and signs until you switch back."))
                .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            option("Test wallet: signs without Touch ID", $newTest)
            if newTest {
                Text("For trying things out, and for Claude to test ihatecrypto without asking you: keep only a few dollars on it. It can't be made from an imported phrase, and adding it still asks for Touch ID once.")
                    .font(.ui(11)).foregroundStyle(Brand.jevInk).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(newTest ? "Create a test wallet" : "Create a new wallet", action: createWallet).disabled(creating)
                if creating { ProgressView().controlSize(.small) }
            }
        }
    }

    /// Every wallet in the signer: which one signs, switching (Touch ID), a name of the user's own, removal.
    private var walletList: some View {
        SettingsSection(icon: "wallet.pass", title: "Your wallets", line: "One signs at a time. Switching or removing one asks for Touch ID.") {
            SettingsGroup {
                ForEach(ws.wallets) { w in walletRow(w) }
            }
        }
        .confirmationDialog("Remove «\(removing?.label ?? "")»?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove the wallet", role: .destructive) {
                guard let w = removing else { return }
                Task {
                    do {
                        let reply = try await SignerClient().send(.removeWallet(id: w.id))
                        guard reply.ok else { throw WalletError(reply.error ?? "The signer refused.") }
                        ws.walletRemoved(w.id)
                        await ws.loadSigner()
                        await ws.refresh()
                    } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("Only if its recovery phrase or key is written down: without it the money on this wallet can't be reached from here again. The money itself stays where it is.")
        }
    }

    private func walletRow(_ w: SignerWallet) -> some View {
        let active = w.id == ws.activeWalletID
        return HStack(spacing: 10) {
            Text(w.label.prefix(1).uppercased()).font(.ui(12, .bold)).foregroundStyle(active ? Brand.accentInk : Color.secondary)
                .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                if renaming == w.id {
                    TextField("Name", text: $draftName).textFieldStyle(.roundedBorder).onSubmit { rename(w) }.frame(maxWidth: 220)
                } else {
                    Text(w.label).font(.ui(13, .semibold))
                }
                Text(Workspace.describe(w)).font(.ui(11)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
            }
            Spacer(minLength: 8)
            if active {
                SettingsPill(text: "Signs now", good: true)
            } else {
                Button("Use") { Task { await ws.switchWallet(w) } }
            }
            Button { renaming = w.id; draftName = w.label } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("Rename").accessibilityLabel("Rename \(w.label)")
            Button(role: .destructive) { removing = w } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Remove this wallet").accessibilityLabel("Remove \(w.label)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 48)
        .overlay(alignment: .bottom) { Brand.cardBorder.opacity(0.65).frame(height: 0.5).padding(.leading, 50) }
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
        SecureField("Solana key from Phantom, or EVM key from MetaMask", text: $privateKey).textFieldStyle(.roundedBorder)
        switch privateKey.isEmpty ? nil : Result(catching: { try ImportedKey.parse(privateKey) }) {
        case .success(let key)?:
            LabeledContent(key.chain, value: (try? key.address()) ?? "?")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("Compare it with \(key.chain == "Solana" ? "Phantom" : "MetaMask") before saving. This wallet signs only on \(key.chain); for the other chains, switch wallets.")
                .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Save as a wallet", action: importKey).buttonStyle(.borderedProminent)
        case .failure(let e)?:
            Text(e.localizedDescription).font(.ui(11)).foregroundStyle(Brand.loss)
        case nil:
            Text("The key goes only to the separate signer, which seals it with this Mac's Secure Enclave like a phrase and never shows it again.")
                .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                adding = nil
                await ws.loadSigner()
                await ws.refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// All 12 words at once, for a password manager (SecretPasteboard), wiped after 60 s.
    private func copy(_ words: [String]) {
        let change = SecretPasteboard.copy(words.joined(separator: " "))
        copiedChange = change
        Task {
            try? await Task.sleep(for: .seconds(60))
            if copiedChange == change { wipeCopied() }
        }
    }

    private func wipeCopied() {
        SecretPasteboard.wipe(copiedChange)
        copiedChange = nil
    }

    private func createWallet() {
        creating = true
        error = nil
        Task {
            defer { creating = false }
            do {
                let reply = try await SignerClient().send(.createWallet(requirePresence: !newTest))
                newTest = false
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

/// A secret on the clipboard (recovery words): marked concealed and transient so clipboard history apps skip it, kept
/// on this Mac (no Universal Clipboard). The caller wipes it later by the change count `copy` returns.
enum SecretPasteboard {
    static func copy(_ text: String) -> Int {
        let board = NSPasteboard.general
        board.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
        board.writeObjects([item])
        return board.changeCount
    }

    /// Clears the clipboard only if it still holds what `copy` wrote.
    static func wipe(_ change: Int?) {
        if let change, NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
    }
}
