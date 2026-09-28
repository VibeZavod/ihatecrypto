import AppKit
import EVMChain
import LalaCore
import SwiftUI
import WalletCore

/// A token the user watches: by its contract on one chain. Name and symbol come from the chain itself where LALA can
/// read it (EVM), the icon and the price from DexScreener. Kept on this Mac (tokens.json).
struct FavoriteToken: Codable, Identifiable, Hashable {
    var id: String { chain + ":" + address.lowercased() }
    let chain: String
    let address: String
    let name: String
    let symbol: String
    var image: URL?
    var added = Date()

    var rpc: EVMRPC? { ["robinhood": EVMRPC.robinhood, "base": .base, "arbitrum": .arbitrum][chain] }
    var chainTitle: String { ["robinhood": "Robinhood Chain", "base": "Base", "arbitrum": "Arbitrum", "solana": "Solana", "ethereum": "Ethereum"][chain] ?? chain.capitalized }
    var chainLogo: String { ["robinhood": "robinhood", "base": "base", "arbitrum": "arb", "solana": "sol", "ethereum": "eth"][chain] ?? "usdc" }
    var explorer: URL? {
        switch chain {
        case "robinhood": URL(string: "https://robinhoodchain.blockscout.com/token/\(address)")
        case "base": URL(string: "https://basescan.org/token/\(address)")
        case "arbitrum": URL(string: "https://arbiscan.io/token/\(address)")
        case "solana": URL(string: "https://solscan.io/token/\(address)")
        default: URL(string: "https://etherscan.io/token/\(address)")
        }
    }
}

extension Workspace {
    /// «добавь в favorite вот этот токен на робингуде 0x…», «remove token AI from favorites».
    func tokenCommand(_ command: TokenCommand, note: String? = nil) async {
        switch command {
        case .unfavorite(let symbol):
            let before = favoriteTokens.count
            favoriteTokens.removeAll { $0.symbol.uppercased() == symbol }
            reply(favoriteTokens.count < before ? "\(symbol) is no longer in your favorite tokens." : "There’s no \(symbol) among your favorite tokens.", note: note)
        case .favorite(let address, let chain):
            guard let infos = try? await TokenLookup.lookup(address), let info = infos.first(where: { chain == nil || $0.chain == chain }) ?? infos.first else {
                reply("DexScreener doesn’t know this contract\(chain.map { " on \($0)" } ?? ""): no pool trades it, so there’s no price to watch.", note: note)
                return
            }
            var token = FavoriteToken(chain: info.chain, address: info.address, name: info.name, symbol: info.symbol, image: info.imageURL)
            // What the contract says about itself wins over any listing.
            if let rpc = token.rpc, let s = ABI.string((try? await rpc.read(address, Data([0x95, 0xd8, 0x9b, 0x41]))) ?? Data()),
               let n = ABI.string((try? await rpc.read(address, Data([0x06, 0xfd, 0xde, 0x03]))) ?? Data()) {
                token = FavoriteToken(chain: info.chain, address: info.address, name: n, symbol: s, image: info.imageURL)
            }
            if !favoriteTokens.contains(where: { $0.id == token.id }) { favoriteTokens.append(token) }
            tokenInfo[token.id] = info
            await loadTokenBalances()
            let moved = info.change24h.map { ", \(signedPct($0)) today" } ?? ""
            reply("⭐ \(token.name) (\(token.symbol)) on \(token.chainTitle) is in your favorites: \(info.priceUSD.map(tokenPrice) ?? "no price")\(moved)"
                  + (info.liquidityUSD.map { ", liquidity \(Fmt.usd(($0 / 1_000_000).rounded(1, .plain)))M" } ?? "")
                  + (chain != nil && chain != info.chain ? ". It trades on \(info.chain), not \(chain!)." : ".")
                  + " It’s a contract, not an address to send money to.", note: note)
        }
    }

    /// Prices and icons for the favorites, at most once a minute.
    func refreshTokens() async {
        guard !favoriteTokens.isEmpty, Date().timeIntervalSince(tokensCheckedAt) > 60 else { return }
        tokensCheckedAt = Date()
        // Collected first, assigned once: every assignment after an await is one more redraw of the window.
        var found: [String: TokenLookup.Info] = [:]
        for t in favoriteTokens {
            if let info = try? await TokenLookup.lookup(t.address).first(where: { $0.chain == t.chain }) { found[t.id] = info }
        }
        tokenInfo.merge(found) { $1 }
        await loadTokenBalances()
    }

    /// What the wallet holds of each favorite on the EVM chains LALA reads.
    func loadTokenBalances() async {
        guard isEVMAddress(hlAddress) else { return }
        var held: [String: Decimal] = [:]
        for t in favoriteTokens {
            guard let rpc = t.rpc, let raw = try? await rpc.read(t.address, try ERC20.balanceOf(hlAddress)), let units = ABI.decimal(in: raw, word: 0),
                  let d = ABI.uint(in: (try? await rpc.read(t.address, Data([0x31, 0x3c, 0xe5, 0x67]))) ?? Data(), word: 0) else { continue }
            held[t.id] = units / Decimal(sign: .plus, exponent: Int(d), significand: 1)
        }
        tokenBalances.merge(held) { $1 }
    }
}

/// The token's icon from DexScreener, with the chain's logo as a small badge.
struct TokenIcon: View {
    let token: FavoriteToken
    var size: CGFloat = 34

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: token.image) { image in
                image.resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
            } placeholder: {
                Circle().fill(Brand.accent.opacity(0.14)).frame(width: size, height: size)
                    .overlay(Text(token.symbol.prefix(2)).font(.ui(size * 0.36, .bold)).foregroundStyle(Brand.accentInk))
            }
            TokenLogo(name: token.chainLogo, size: size * 0.42).offset(x: 3, y: 3)
        }
        .frame(width: size, height: size)
    }
}

struct FavoriteTokenCard: View {
    @Environment(Workspace.self) private var ws
    let token: FavoriteToken
    @State private var copied = false

    var body: some View {
        let info = ws.tokenInfo[token.id]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TokenIcon(token: token, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(token.name)").font(.ui(14, .bold)).lineLimit(1)
                    Text("\(token.symbol) · \(token.chainTitle)").font(.ui(10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { withAnimation(.snappy) { ws.favoriteTokens.removeAll { $0.id == token.id } } } label: { Image(systemName: "star.fill") }
                    .buttonStyle(.hoverIcon).foregroundStyle(Color(hex: 0xF5B301)).help("Remove from favorites")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(info?.priceUSD.map(tokenPrice) ?? "—").font(.ui(20, .heavy)).monospacedDigit()
                if let c = info?.change24h {
                    Text(signedPct(c)).font(.ui(10, .bold)).foregroundStyle(c < 0 ? Brand.loss : Brand.profit)
                }
                Spacer()
                if let l = info?.liquidityUSD { Text("liquidity \(Fmt.usd((l / 1_000_000).rounded(1, .plain)))M").font(.ui(10)).foregroundStyle(.secondary) }
            }
            if let held = ws.tokenBalances[token.id], held > 0 {
                Label("You hold \(Fmt.num(held, maxFraction: 4)) \(token.symbol)\(info?.priceUSD.map { " ≈ \(Fmt.usd($0 * held))" } ?? "")", systemImage: "wallet.pass")
                    .font(.ui(10, .semibold))
            }
            HStack(spacing: 14) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token.address, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: { Label(copied ? "Copied" : "Contract", systemImage: copied ? "checkmark" : "doc.on.doc") }
                if let pair = info?.pairURL { Link(destination: pair) { Label("Chart", systemImage: "chart.xyaxis.line") } }
                if let e = token.explorer { Link(destination: e) { Label("Explorer", systemImage: "arrow.up.right.square") } }
            }
            .buttonStyle(.borderless).font(.ui(10))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(hex: 0xF5B301).opacity(0.6), lineWidth: 1.5))
    }
}

/// «+ Token»: paste a contract, LALA finds its chain, name, price and icon.
struct AddTokenButton: View {
    @Environment(Workspace.self) private var ws
    @State private var open = false
    @State private var address = ""
    @State private var busy = false

    var body: some View {
        Button { open = true } label: { Label("Token", systemImage: "plus") }
            .buttonStyle(.bordered)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Watch a token").font(.ui(13, .bold))
                    HStack {
                        TextField("contract address (0x… or Solana mint)", text: $address).font(.system(.body, design: .monospaced)).frame(width: 320)
                        Button("Paste") { address = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                    }
                    Text("ihatecrypto looks it up on DexScreener: the chain it trades on, price, icon.").font(.ui(10)).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                        Button("Add to favorites") {
                            guard let a = AddressBookCommand.address(in: address) else { return }
                            busy = true
                            Task {
                                await ws.tokenCommand(.favorite(address: a, chain: a.hasPrefix("0x") ? nil : "solana"))
                                busy = false
                                open = false
                                address = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(AddressBookCommand.address(in: address) == nil || busy)
                    }
                }
                .padding(16)
            }
    }
}

/// Token prices keep their meaningful digits: $148.64, $0.2366, $0.00001234.
func tokenPrice(_ d: Decimal) -> String {
    if d >= 1 { return Fmt.usd(d) }
    var digits = 2
    var x = d
    while x < 1, x > 0, digits < 10 { x *= 10; digits += 1 }
    return "$" + Fmt.num(d, maxFraction: min(digits + 2, 12))
}
