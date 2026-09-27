import SignerAPI
import SwiftUI
import WalletCore

/// Separate window, away from the chat: the phrase never passes through the model, the chat or a log.
/// Inside LALA.app the phrase can go to the signing process, which keeps the seed in the Keychain; the app
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

    var body: some View {
        Form {
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
                     ? "The phrase goes only to the separate signer, which has no network access. It keeps the key sealed by this Mac's Secure Enclave and signs only what passes the guard, after Touch ID or your password. Replacing a wallet that is already there asks for Touch ID too."
                     : "The phrase isn't saved or sent anywhere. The app takes only the public addresses from it to show balances. Try the test phrase first.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(store ? "Save and show addresses" : "Show addresses", action: derive).disabled(phrase.isEmpty)
                if let stored { Text(stored).font(.caption).foregroundStyle(.green) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            if !accounts.isEmpty {
                Section("Compare with MetaMask and Phantom") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("#").foregroundStyle(.secondary)
                            Text("EVM · Hyperliquid  m/44'/60'/0'/0/i").foregroundStyle(.secondary)
                            Text("Solana  m/44'/501'/i'/0'").foregroundStyle(.secondary)
                        }
                        .font(.caption)
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
        .onDisappear { phrase = ""; passphrase = ""; accounts = []; newPhrase = nil }
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

    /// «Create a new wallet»: the signer makes the phrase; the words appear once, numbered, not selectable — for paper.
    @ViewBuilder private var create: some View {
        Section("New wallet") {
            if let words = newPhrase {
                Text("Write these 12 words on paper, in order. They are the only way back to this wallet if the Mac is lost or wiped; LALA won't show them again.")
                    .font(.callout)
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
                    .font(.caption).foregroundStyle(.orange)
                Button("I wrote them down") { newPhrase = nil }.buttonStyle(.borderedProminent)
            } else {
                Text("LALA makes a new 12-word recovery phrase inside the signer, from this Mac's random number generator, and keeps the key sealed by the Secure Enclave. Every signature asks for Touch ID or your password."
                     + (ws.signerWallet == nil ? "" : " It replaces the wallet that is in LALA now — move the money out of it first."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Create a new wallet", action: createWallet).disabled(creating)
                    if creating { ProgressView().controlSize(.small) }
                }
            }
        }
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
