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

    var body: some View {
        Form {
            Section {
                SecureField("12 or 24 words separated by spaces", text: $phrase)
                SecureField("Extra passphrase, if any", text: $passphrase)
                if SignerClient.isAvailable {
                    Toggle("Save the key in secure storage to sign", isOn: $store)
                    if store {
                        Toggle("Ask for Touch ID or password on every signature", isOn: $requirePresence)
                    }
                }
                Text(store
                     ? "The phrase goes only to the separate signer, which has no network access. It keeps the key in this Mac's Keychain and signs only what passes the guard. The app never sees the key."
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
        .onDisappear { phrase = ""; passphrase = ""; accounts = [] }
        .onAppear {
            // `-demoImport YES`: the public BIP-39 test phrase, for screenshots and checks only.
            if UserDefaults.standard.bool(forKey: "demoImport") {
                phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
                derive()
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
