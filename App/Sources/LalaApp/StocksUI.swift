import EVMChain
import LalaCore
import SwiftUI
import TradeExecution
import WalletCore

/// A Stock Token held on Robinhood Chain, priced by Robinhood's own quote, or a token bought by its contract.
struct StockHolding: Identifiable, Equatable {
    var id: String { symbol }
    let symbol: String
    let name: String
    let amount: Decimal
    let price: Decimal?
    let logo: URL?
    var usd: Decimal { price.map { $0 * amount } ?? 0 }
}

extension Workspace {
    /// Symbols bought through LALA; their balances are read with every refresh.
    func rememberStock(_ symbol: String) {
        var list = UserDefaults.standard.stringArray(forKey: "stockTokens") ?? []
        if !list.contains(symbol.uppercased()) { list.append(symbol.uppercased()) }
        UserDefaults.standard.set(list, forKey: "stockTokens")
        Task { await loadRobinhood() }
    }

    /// USDG, ETH for gas, the remembered Stock Tokens and the favorite tokens held on Robinhood Chain.
    func loadRobinhood() async {
        guard isEVMAddress(hlAddress) else { return }
        let rpc = EVMRPC.robinhood, me = hlAddress
        guard let usdg = try? await rpc.tokenBalance(EVMRPC.robinhoodUSDG, owner: me), let eth = try? await rpc.balance(me) else { return }
        var holdings: [StockHolding] = []
        let symbols = UserDefaults.standard.stringArray(forKey: "stockTokens") ?? []
        if !symbols.isEmpty, let registry = try? await RobinhoodStocks.registry() {
            for symbol in symbols {
                guard let t = registry.first(where: { $0.symbol == symbol }),
                      let raw = try? await rpc.read(t.address, try ERC20.balanceOf(me)), let units = ABI.decimal(in: raw, word: 0), units > 0 else { continue }
                let amount = units / Decimal(sign: .plus, exponent: t.decimals, significand: 1)
                let price = (try? await RobinhoodStocks.quote(symbol))?.bid
                holdings.append(StockHolding(symbol: symbol, name: t.name, amount: amount, price: price, logo: t.logo))
            }
        }
        // Tokens bought by their contract (favorites on Robinhood Chain), priced by DexScreener.
        for t in favoriteTokens where t.chain == "robinhood" {
            guard let raw = try? await rpc.read(t.address, try ERC20.balanceOf(me)), let units = ABI.decimal(in: raw, word: 0), units > 0,
                  let d = ABI.uint(in: (try? await rpc.read(t.address, Data([0x31, 0x3c, 0xe5, 0x67]))) ?? Data(), word: 0) else { continue }
            let amount = units / Decimal(sign: .plus, exponent: Int(d), significand: 1)
            tokenBalances[t.id] = amount
            if tokenInfo[t.id]?.priceUSD == nil, let info = try? await TokenLookup.lookup(t.address).first(where: { $0.chain == "robinhood" }) {
                tokenInfo[t.id] = info
            }
            holdings.append(StockHolding(symbol: t.symbol, name: t.name, amount: amount, price: tokenInfo[t.id]?.priceUSD, logo: t.image))
        }
        robinhood = (Decimal(usdg) / 1_000_000, Decimal(eth) / Decimal(sign: .plus, exponent: 18, significand: 1), holdings)
    }

    var robinhoodTotal: Decimal { robinhood.map { $0.usdg + $0.stocks.reduce(0) { $0 + $1.usd } } ?? 0 }
}

/// The company's logo bundled by ticker, else the registry's (Robinhood's own) logo, or a drawn badge while it loads.
struct StockLogo: View {
    let symbol: String
    let url: URL?
    var size: CGFloat = 26

    var body: some View {
        // Robinhood's registry gives every Stock Token the same Robinhood logo, so the company's own logo, when
        // bundled by ticker (Logos/spcx.svg, tsla.png…), comes first.
        if let bundled = TokenLogo.name(forAsset: symbol) {
            TokenLogo(name: bundled, size: size)
        } else {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit().frame(width: size, height: size).clipShape(Circle())
            } placeholder: {
                AssetBadge(coin: symbol, size: size, dark: true)
            }
            .frame(width: size, height: size)
        }
    }
}

/// The portfolio's Robinhood Chain card: Stock Tokens with their value, and USDG.
struct RobinhoodCard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if let r = ws.robinhood, r.usdg > 0 || !r.stocks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    TokenLogo(name: "robinhood", size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Robinhood Chain").font(.system(size: 14, weight: .semibold))
                        Text("stock tokens · \(Fmt.usd(ws.robinhoodTotal))").font(.caption).foregroundStyle(Color(hex: 0x5A7A00))
                    }
                }
                ForEach(r.stocks) { s in
                    HStack(spacing: 8) {
                        StockLogo(symbol: s.symbol, url: s.logo, size: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.symbol).font(.system(size: 12.5, weight: .bold))
                            Text("\(Fmt.num(s.amount, maxFraction: 6)) · \(s.price.map { Fmt.usd($0) } ?? "—")").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Fmt.usd(s.usd)).font(.system(size: 12.5, weight: .bold)).monospacedDigit()
                    }
                }
                if r.usdg > 0 {
                    HStack { Text("USDG").font(.caption); Spacer(); Text(Fmt.num(r.usdg)).font(.caption.weight(.semibold)).monospacedDigit() }
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(light: 0xF3FFD6, dark: 0x1D2608)))
            .modifier(Openable(place: "robinhood"))
        }
    }
}
