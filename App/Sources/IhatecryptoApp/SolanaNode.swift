import SolanaChain
import SwiftUI
import WalletCore

/// The user's own Solana node: its URL carries the provider's key, so it lives in the login Keychain of this Mac only
/// (never in settings files), is put into SolanaNodes at launch, and only its host is ever shown.
nonisolated enum SolanaNodeStore {
    static let service = Bundle.main.bundleIdentifier.map { $0 + ".rpc" } ?? "app.ihatecrypto.rpc"
    static let account = "solana"

    static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() -> URL? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return URL(string: String(decoding: data, as: UTF8.self))
    }

    /// At launch: the saved node, if any, is the one asked first.
    static func activate() { SolanaNodes.custom = load() }

    /// Saves `url` (nil removes it) and puts it to use at once.
    static func save(_ url: URL?) {
        SecItemDelete(query() as CFDictionary)
        if let url {
            var q = query()
            q[kSecValueData as String] = Data(url.absoluteString.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }
        SolanaNodes.custom = url
    }
}

/// Settings › General: which Solana node the app reads and sends through, and the way to add one's own.
struct SolanaNodeSection: View {
    @State private var host = SolanaNodes.custom?.host
    @State private var adding = false

    var body: some View {
        SettingsSection(icon: "server.rack", title: "Solana node", line: "Where the app reads Solana and sends its transactions.") {
            SettingsGroup {
                SettingsRow(host.map { "Your node: \($0)" } ?? "Solana's public node", icon: "server.rack",
                            info: host == nil
                                ? "The public node is free but busy: it limits how often anyone may ask, and it's the only one there is, so at a busy moment a balance or a move can fail. A node of your own (free at Helius) takes that away."
                                : "Your node is asked first; Solana's public node takes over when yours doesn't answer or refuses its key.") {
                    HStack(spacing: 8) {
                        if host != nil {
                            Button("Remove") { SolanaNodeStore.save(nil); host = nil }
                        }
                        Button(host == nil ? "Add your own…" : "Change…") { adding = true }
                    }
                }
            }
        }
        .sheet(isPresented: $adding) { SolanaNodeSheet { host = SolanaNodes.custom?.host } }
    }
}

/// Why a node of one's own, how to get a free one at Helius, and the field: the address is checked against Solana
/// mainnet before it's kept.
struct SolanaNodeSheet: View {
    var saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your own Solana node").font(.ui(20, .bold))
            VStack(alignment: .leading, spacing: 8) {
                Text("Why").font(.ui(13, .semibold))
                Text("Every balance and every move on Solana goes through a node. Solana's public node is free but shared by everyone: it limits how often you may ask and has no backup, so at a busy moment a balance doesn't load or a move fails half-way. A node of your own gives you your own limit; the public one stays behind it as a backup.")
                Text("A node only reads the chain and passes on transactions already signed on this Mac: it never sees your keys and can't move money. It does see your addresses. Its address carries your key, so it's kept in this Mac's Keychain and shown only by its host.")
                    .foregroundStyle(.secondary)
            }
            .font(.ui(12.5)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("A free node at Helius, in two minutes").font(.ui(13, .semibold))
                step(1, "Open helius.dev and sign up — the free plan, no card.")
                step(2, "In the dashboard, open RPCs (Endpoints) and copy the Mainnet URL: https://mainnet.helius-rpc.com/?api-key=…")
                step(3, "Paste it below and press Check and save.")
                Link("Open helius.dev", destination: URL(string: "https://www.helius.dev")!).font(.ui(12.5))
                Text("Any Solana mainnet node works the same way: QuickNode, Alchemy, Triton — paste its https address.")
                    .font(.ui(11.5)).foregroundStyle(.secondary)
            }
            SecureField("https://mainnet.helius-rpc.com/?api-key=…", text: $address)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .onSubmit { Task { await check() } }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.ui(12)).foregroundStyle(Brand.loss)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Check and save") { Task { await check() } }
                    .keyboardShortcut(.defaultAction).disabled(checking || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 520)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.ui(11, .bold)).frame(width: 18, height: 18).background(Circle().fill(Brand.accent.opacity(0.18)))
            Text(text).font(.ui(12.5)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    /// Checked against Solana mainnet first (SolanaNodes.problem); kept only when it passes.
    private func check() async {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { problem = "That isn't an address."; return }
        checking = true
        defer { checking = false }
        problem = await SolanaNodes.problem(with: url)
        guard problem == nil else { return }
        SolanaNodeStore.save(url)
        saved()
        dismiss()
    }
}
