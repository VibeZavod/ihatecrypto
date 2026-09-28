import AppKit
import LalaCore
import SwiftUI
import TradeExecution
import WalletCore

/// A saved address: an exchange's deposit address, another wallet, a person. Added by hand here, or from the user's own
/// chat message after a confirmation — never from a model, a site or a pasted instruction. Kept on this Mac
/// (addressbook.json, owner-only; pictures in icons/).
struct SavedAddress: Codable, Identifiable, Hashable {
    /// The first version's fixed types; old entries keep theirs as the category.
    enum Kind: String, Codable, CaseIterable {
        case exchange, wallet, person, other

        var title: String {
            switch self {
            case .exchange: "Exchange"
            case .wallet: "Wallet"
            case .person: "Person"
            case .other: "Other"
            }
        }

        var icon: String {
            switch self {
            case .exchange: "building.columns"
            case .wallet: "wallet.pass"
            case .person: "person"
            case .other: "bookmark"
            }
        }
    }

    var id = UUID()
    var name: String
    var address: String
    var network: AddressCheck.Network
    var kind: Kind?
    /// Optional, free text: «Exchange», «Friends», «DeFi».
    var category: String?
    var icon: AddressIcon?
    /// Some exchanges credit a deposit only with their memo or tag.
    var memo = ""
    var note = ""
    var favorite = false
    var added = Date()
    /// "chat" when it came from a chat message (confirmed on the canvas).
    var source: String?
    /// The last transfer LALA made to it; nil means none yet (the route suggests a small test first).
    var lastSent: Date?

    var label: String? { category ?? kind?.title }
}

/// A picture for an entry: a chain or token logo, an SF Symbol, an emoji or the user's own image (a file in icons/).
enum AddressIcon: Codable, Hashable {
    case logo(String), symbol(String), emoji(String), image(String)
}

/// The entry's picture, or a sign from its category, or its first letter.
struct AddressIconView: View {
    let entry: SavedAddress
    var size: CGFloat = 38

    var body: some View {
        switch entry.icon {
        case .logo(let name)?: TokenLogo(name: name, size: size)
        case .symbol(let name)?: symbol(name)
        case .emoji(let e)?:
            Circle().fill(Brand.accent.opacity(0.1)).frame(width: size, height: size)
                .overlay(Text(e).font(.system(size: size * 0.56)))
        case .image(let file)?:
            if let image = AddressIcons.image(file) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
            } else {
                letter
            }
        case nil:
            if let sign = Self.symbol(for: entry.label) { symbol(sign) } else { letter }
        }
    }

    static func symbol(for category: String?) -> String? {
        let c = category?.lowercased() ?? ""
        if c.contains("exchange") || c.contains("бирж") { return "building.columns" }
        if c.contains("wallet") || c.contains("кошел") { return "wallet.pass" }
        if c.contains("friend") || c.contains("person") || c.contains("family") || c.contains("друз") { return "person" }
        if c.contains("defi") { return "chart.pie" }
        return nil
    }

    private func symbol(_ name: String) -> some View {
        Circle().fill(Brand.accent.opacity(0.12)).frame(width: size, height: size)
            .overlay(Image(systemName: name).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(Brand.accentInk))
    }

    private var letter: some View {
        Circle().fill(Brand.accent.opacity(0.12)).frame(width: size, height: size)
            .overlay(Text(entry.name.prefix(1).uppercased()).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(Brand.accentInk))
    }
}

/// Pictures the user picked, downscaled to 128 px and kept next to the address book.
enum AddressIcons {
    static var folder: URL {
        let url = LocalStore.url("icons")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    static func image(_ file: String) -> NSImage? {
        if let hit = cache[file] { return hit }
        let image = NSImage(contentsOf: folder.appending(path: file))
        cache[file] = image
        return image
    }

    /// Square, 128 px, PNG; returns the file name.
    static func save(_ image: NSImage) -> String? {
        let side = 128
        guard image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let scale = max(CGFloat(side) / image.size.width, CGFloat(side) / image.size.height)
        let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: (CGFloat(side) - drawn.width) / 2, y: (CGFloat(side) - drawn.height) / 2, width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let file = UUID().uuidString + ".png"
        guard (try? png.write(to: folder.appending(path: file))) != nil else { return nil }
        return file
    }

    static func remove(_ icon: AddressIcon?) {
        if case .image(let file)? = icon {
            try? FileManager.default.removeItem(at: folder.appending(path: file))
            cache[file] = nil
        }
    }

    /// The site's own icon, by its domain («bybit.com»), through Google's favicon service at 128 px.
    static func logo(domain: String) async -> NSImage? {
        let host = domain.lowercased().replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
        guard host.contains("."), let url = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128"),
              let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data), image.size.width >= 32 else { return nil }
        return image
    }
}

extension AddressCheck.Network {
    var logo: String {
        switch self {
        case .solana: "sol"
        case .hyperliquid: "hype"
        case .ethereum: "eth"
        case .arbitrum: "arb"
        case .base: "base"
        case .robinhood: "robinhood"
        case .near: "near"
        }
    }
}

// MARK: Favorites

/// Favorites on the canvas: watched tokens, saved addresses (starred first, «All» for the rest) and, under All, your
/// own wallets. Tokens and addresses are added and edited right here; there is no separate address book.
struct FavoritesBoard: View {
    @Environment(Workspace.self) private var ws
    @AppStorage("bookTab") private var tab = "favorites"
    @State private var search = ""
    @State private var adding = false
    @State private var editing: SavedAddress?

    var body: some View {
        let items = filtered
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill").foregroundStyle(Color(hex: 0xF5B301)).font(.system(size: 16, weight: .semibold))
                Text("Favorites").font(.system(size: 16, weight: .bold))
                Spacer()
                Button { withAnimation(StudioView.spring) { ws.showFavorites = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.hoverIcon).help("Close")
            }
            HStack(spacing: 8) {
                Picker("", selection: $tab) {
                    Label("Favorites", systemImage: "star.fill").tag("favorites")
                    Text("All").tag("all")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                AddTokenButton()
                Button { adding = true } label: { Label("Address", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            TextField("Search addresses", text: $search).textFieldStyle(.roundedBorder)
            // Watched tokens: contracts to follow, never addresses to send to.
            if !ws.favoriteTokens.isEmpty, search.isEmpty {
                section("TOKENS")
                ForEach(ws.favoriteTokens) { FavoriteTokenCard(token: $0) }
            }
            // Ours: this is where money into LALA goes.
            let own = ownWallets
            if tab == "all", !own.isEmpty, search.isEmpty {
                HStack {
                    section("YOUR WALLETS · SEND MONEY HERE TO TOP UP")
                    Spacer()
                    Button { withAnimation(StudioView.spring) { ws.showReceive = true } } label: { Label("QR", systemImage: "qrcode") }
                        .buttonStyle(.borderless).font(.caption)
                }
                ForEach(own) { AddressCard(entry: $0, readOnly: true) }
            }
            section("ADDRESSES")
            if items.isEmpty { empty }
            ForEach(items) { entry in
                AddressCard(entry: entry, edit: { editing = $0 })
                    .transition(.opacity)
            }
            Label("ihatecrypto only ever sends to your own wallets. Saved addresses are for copying and, later, for transfers you sign with Touch ID — never to an address from a chat, a site or a model.",
                  systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
        .animation(.snappy, value: items)
        .frame(width: 470, alignment: .leading)
        .sheet(isPresented: $adding) { AddressEditor(entry: nil).environment(ws) }
        .sheet(item: $editing) { AddressEditor(entry: $0).environment(ws) }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary).padding(.top, 4)
    }

    private var filtered: [SavedAddress] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return ws.addressBook
            .filter { tab == "all" || $0.favorite || !q.isEmpty }
            .filter { q.isEmpty || [$0.name, $0.address, $0.note, $0.network.title, $0.label ?? ""].contains { $0.lowercased().contains(q) } }
            .sorted { ($0.favorite ? 0 : 1, $0.name.lowercased()) < ($1.favorite ? 0 : 1, $1.name.lowercased()) }
    }

    /// The addresses LALA reads balances from, shown for copying.
    private var ownWallets: [SavedAddress] {
        var out: [SavedAddress] = []
        if isSolanaAddress(ws.solanaAddress) { out.append(SavedAddress(name: "Solana · USDC and SOL", address: ws.solanaAddress, network: .solana, category: "Your wallet", icon: .logo("sol"))) }
        if isEVMAddress(ws.hlAddress) { out.append(SavedAddress(name: "Base · USDC and ETH (same 0x as Hyperliquid)", address: ws.hlAddress, network: .base, category: "Your wallet", icon: .logo("base"))) }
        return out
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(!search.isEmpty ? "Nothing matches “\(search)”."
                 : tab == "favorites" && !ws.addressBook.isEmpty ? "No favorites yet — star an address in All to keep it here."
                 : "Save an exchange’s deposit address, another wallet or a friend’s — with a name, so you never paste a wrong one.")
                .font(.callout).foregroundStyle(.secondary)
            if ws.addressBook.isEmpty {
                Button { adding = true } label: { Label("Add the first address", systemImage: "plus") }.buttonStyle(.borderless)
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).strokeBorder(Brand.dots, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }
}

struct AddressCard: View {
    @Environment(Workspace.self) private var ws
    let entry: SavedAddress
    var readOnly = false
    var edit: (SavedAddress) -> Void = { _ in }
    @State private var copied = false
    @State private var confirmDelete = false

    private static let gold = Color(hex: 0xF5B301)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    AddressIconView(entry: entry, size: 38)
                    TokenLogo(name: entry.network.logo, size: 17).offset(x: 3, y: 3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Text([entry.label, entry.network.title, entry.source == "chat" ? "from chat" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !readOnly {
                    Button {
                        withAnimation(.snappy) { ws.toggleFavorite(entry.id) }
                    } label: {
                        Image(systemName: entry.favorite ? "star.fill" : "star").font(.system(size: 15))
                            .foregroundStyle(entry.favorite ? Self.gold : .secondary)
                            .symbolEffect(.bounce, value: entry.favorite)
                    }
                    .buttonStyle(.borderless)
                    .help(entry.favorite ? "Remove from favorites" : "Add to favorites")
                }
            }
            // The start and the end stand out: that's what to compare with the source.
            let ends = AddressCheck.ends(entry.address)
            HStack(spacing: 0) {
                Text(ends.start).fontWeight(.bold)
                Text("  …  ").foregroundStyle(.tertiary)
                Text(ends.end).fontWeight(.bold)
            }
            .font(.system(size: 13.5, design: .monospaced))
            Text(entry.address).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !entry.memo.isEmpty {
                Label("Memo / tag: \(entry.memo)", systemImage: "number").font(.caption.weight(.semibold)).foregroundStyle(Brand.jevInk)
            }
            if !entry.note.isEmpty { Text(entry.note).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 14) {
                Button(action: copy) { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                Spacer()
                if readOnly {
                    Text("read from Settings").foregroundStyle(.tertiary)
                } else {
                    Button("Edit") { edit(entry) }
                    Button("Delete", role: .destructive) { confirmDelete = true }.foregroundStyle(Brand.loss)
                }
            }
            .buttonStyle(.borderless).font(.caption)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(entry.favorite ? Self.gold.opacity(0.7) : Brand.cardBorder, lineWidth: entry.favorite ? 1.5 : 1))
        .contextMenu {
            Button("Copy address", action: copy)
            if !readOnly {
                Button(entry.favorite ? "Remove from favorites" : "Add to favorites") { ws.toggleFavorite(entry.id) }
                Button("Edit…") { edit(entry) }
                Button("Delete…", role: .destructive) { confirmDelete = true }
            }
        }
        .confirmationDialog("Delete “\(entry.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                AddressIcons.remove(entry.icon)
                withAnimation(.snappy) { ws.addressBook.removeAll { $0.id == entry.id } }
            }
        } message: {
            Text("Only the saved entry is removed.")
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.address, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}

// MARK: Editor

/// Adding or changing an entry: the address is checked for its network while typing and never corrected.
struct AddressEditor: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.dismiss) private var dismiss
    let entry: SavedAddress?
    @State private var name = ""
    @State private var address = ""
    @State private var network: AddressCheck.Network = .solana
    @State private var category = ""
    @State private var icon: AddressIcon?
    @State private var memo = ""
    @State private var note = ""
    @State private var favorite = false
    @State private var picking = false

    static let categories = ["Exchange", "Wallet", "Friend", "DeFi", "Work"]

    private var trimmed: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draft: SavedAddress {
        SavedAddress(name: name.isEmpty ? "?" : name, address: trimmed, network: network, category: category.isEmpty ? nil : category, icon: icon)
    }
    private var problem: String? {
        guard let p = AddressCheck.problem(trimmed, network: network) else { return nil }
        let evm = trimmed.hasPrefix("0x")
        if network == .solana, evm { return p + " It looks like an EVM address — pick its network." }
        if network != .solana, !evm, AddressCheck.problem(trimmed, network: .solana) == nil { return p + " It looks like a Solana address — pick Solana." }
        return p
    }
    private var duplicate: SavedAddress? {
        ws.addressBook.first { $0.id != entry?.id && $0.network == network && $0.address.lowercased() == trimmed.lowercased() }
    }
    private var isOwn: Bool {
        trimmed == ws.solanaAddress || (!ws.hlAddress.isEmpty && trimmed.lowercased() == ws.hlAddress.lowercased())
    }
    private var isExchange: Bool { category.lowercased().contains("exchange") || category.lowercased().contains("бирж") }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && problem == nil && duplicate == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { picking = true } label: {
                    AddressIconView(entry: draft, size: 52)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "pencil.circle.fill").font(.system(size: 18)).foregroundStyle(.white, Brand.accent).offset(x: 4, y: 4)
                        }
                }
                .buttonStyle(.plain)
                .help("Choose a picture")
                .popover(isPresented: $picking, arrowEdge: .bottom) { IconPicker(icon: $icon, name: name) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry == nil ? "Add an address" : "Edit “\(entry?.name ?? "")”").font(.title3.bold())
                    Text("Tap the picture to choose a logo, an emoji or your own image.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Bybit · USDC deposit"))
                HStack {
                    TextField("Category", text: $category, prompt: Text("optional"))
                    ForEach(Self.categories, id: \.self) { c in
                        Button(c) { category = category == c ? "" : c }
                            .buttonStyle(.plain).font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(category == c ? Brand.accent.opacity(0.18) : Color.primary.opacity(0.06)))
                    }
                }
                Picker("Network", selection: $network) {
                    ForEach(AddressCheck.Network.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                HStack {
                    TextField("Address", text: $address).font(.system(.body, design: .monospaced))
                    Button("Paste") { address = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                }
                TextField("Memo / tag", text: $memo, prompt: Text(isExchange ? "only if the exchange shows one" : "optional"))
                TextField("Note", text: $note, prompt: Text("optional"))
                Toggle("Favorite", isOn: $favorite)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            status
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(entry == nil ? "Save" : "Save changes", action: save).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear {
            guard let e = entry else { return }
            name = e.name; address = e.address; network = e.network; category = e.label ?? ""; icon = e.icon
            memo = e.memo; note = e.note; favorite = e.favorite
        }
    }

    @ViewBuilder private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            if trimmed.isEmpty {
                Label("Copy the address from the exchange or wallet itself, then press Paste.", systemImage: "doc.on.clipboard").foregroundStyle(.secondary)
            } else if let problem {
                Label(problem, systemImage: "xmark.octagon.fill").foregroundStyle(Brand.loss)
            } else {
                let ends = AddressCheck.ends(trimmed)
                Label("Valid \(network.title) address. Compare it with the source: starts \(ends.start), ends \(ends.end).", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Brand.profit)
                if let duplicate { Label("Already saved as “\(duplicate.name)”.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.jevInk) }
                if isOwn { Label("This is your own wallet.", systemImage: "person.crop.circle.badge.checkmark").foregroundStyle(.secondary) }
                if isExchange {
                    Label("An exchange credits a deposit only on the network it shows. Sent on another network, the money can be lost.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        var e = entry ?? SavedAddress(name: "", address: "", network: network)
        if e.icon != icon { AddressIcons.remove(e.icon) }
        e.name = name.trimmingCharacters(in: .whitespaces)
        e.address = trimmed
        e.network = network
        e.kind = nil
        e.category = category.trimmingCharacters(in: .whitespaces).isEmpty ? nil : category.trimmingCharacters(in: .whitespaces)
        e.icon = icon
        e.memo = memo.trimmingCharacters(in: .whitespaces)
        e.note = note.trimmingCharacters(in: .whitespaces)
        e.favorite = favorite
        withAnimation(.snappy) {
            if let i = ws.addressBook.firstIndex(where: { $0.id == e.id }) { ws.addressBook[i] = e } else { ws.addressBook.append(e) }
        }
        dismiss()
    }
}

/// Logos, symbols, emoji, or a picture: from a file, the clipboard or the site's own icon.
struct IconPicker: View {
    @Binding var icon: AddressIcon?
    let name: String
    @State private var domain = ""
    @State private var fetching = false
    @State private var error: String?

    static let logos = ["sol", "usdc", "eth", "base", "arb", "hype", "btc", "jup", "kamino", "jitosol", "relay", "aave", "robinhood"]
    static let symbols = ["building.columns", "wallet.pass", "person.fill", "person.2.fill", "creditcard.fill", "banknote.fill", "bag.fill",
                          "cart.fill", "briefcase.fill", "gift.fill", "heart.fill", "star.fill", "house.fill", "lock.fill", "bolt.fill", "flame.fill"]
    static let emoji = ["🏦", "💼", "🐋", "🚀", "💎", "🔥", "🐸", "🦄", "🍀", "👑", "🧊", "🌙"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("LOGOS") {
                ForEach(Self.logos, id: \.self) { l in pick(.logo(l)) { TokenLogo(name: l, size: 26) } }
            }
            section("SYMBOLS") {
                ForEach(Self.symbols, id: \.self) { s in pick(.symbol(s)) { Image(systemName: s).font(.system(size: 15)).frame(width: 26, height: 26) } }
            }
            section("EMOJI") {
                ForEach(Self.emoji, id: \.self) { e in pick(.emoji(e)) { Text(e).font(.system(size: 20)).frame(width: 26, height: 26) } }
            }
            Text("PICTURE").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            HStack {
                Button("Choose image…", action: choose)
                Button("Paste image") {
                    guard let image = NSImage(pasteboard: .general) else { error = "No image on the clipboard."; return }
                    store(image)
                }
                Spacer()
                Button("Default") { icon = nil }.buttonStyle(.borderless)
            }
            HStack {
                TextField("website, e.g. bybit.com", text: $domain).textFieldStyle(.roundedBorder)
                    .onAppear { if domain.isEmpty, let word = name.split(separator: " ").first, word.count > 2 { domain = word.lowercased() + ".com" } }
                Button(fetching ? "…" : "Get logo") {
                    fetching = true
                    Task {
                        if let image = await AddressIcons.logo(domain: domain) { store(image) } else { error = "No icon found for \(domain)." }
                        fetching = false
                    }
                }
                .disabled(fetching || !domain.contains("."))
            }
            if let error { Text(error).font(.caption).foregroundStyle(Brand.loss) }
            Text("The site’s icon comes through Google’s favicon service; nothing else is sent.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 380)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ items: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 9), alignment: .leading, spacing: 6) { items() }
        }
    }

    private func pick<Label: View>(_ value: AddressIcon, @ViewBuilder _ label: () -> Label) -> some View {
        Button { icon = value; error = nil } label: {
            label().frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(icon == value ? Brand.accent.opacity(0.18) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        store(image)
    }

    private func store(_ image: NSImage) {
        guard let file = AddressIcons.save(image) else { error = "Couldn’t read that image."; return }
        icon = .image(file)
        error = nil
    }
}

// MARK: Rail

extension Workspace {
    func toggleFavorite(_ id: UUID) {
        guard let i = addressBook.firstIndex(where: { $0.id == id }) else { return }
        addressBook[i].favorite.toggle()
    }
}

extension Workspace {
    /// «save <address> as Bybit on Arbitrum» waits for a confirmation on the canvas; favorites change at once.
    func addressBookCommand(_ command: AddressBookCommand, note: String? = nil) {
        switch command {
        case .favorite(let name, let on):
            let key = name.lowercased()
            guard let i = addressBook.firstIndex(where: { $0.name.lowercased() == key }) ?? addressBook.firstIndex(where: { $0.name.lowercased().contains(key) }) else {
                reply("There’s no “\(name)” in Addresses. Save it first, e.g. “save <address> as \(name) on Base”.", note: note)
                return
            }
            addressBook[i].favorite = on
            reply(on ? "⭐ “\(addressBook[i].name)” is in your favorites." : "“\(addressBook[i].name)” is no longer a favorite.", note: note)
        case .save(let address, let name, let net):
            let network: AddressCheck.Network
            if let net, let n = AddressCheck.Network(rawValue: net) {
                network = n
            } else if !address.hasPrefix("0x") {
                network = .solana
            } else {
                reply("Which network is this 0x address on — Ethereum, Arbitrum, Base or Hyperliquid? For example “save … as \(name) on Arbitrum”.", note: note)
                return
            }
            if let problem = AddressCheck.problem(address, network: network) { reply(problem, note: note); return }
            if let same = addressBook.first(where: { $0.network == network && $0.address.lowercased() == address.lowercased() }) {
                reply("Already saved as “\(same.name)”.", note: note)
                return
            }
            let domain = name.split(separator: " ").first.map { $0.lowercased() }
            pendingAction = .address(SavedAddress(name: name, address: address, network: network, source: "chat"))
            pendingText = "save “\(name)”"
            let ends = AddressCheck.ends(address)
            reply("Check it on the canvas: \(network.title), starts \(ends.start), ends \(ends.end) — exactly as in your message. Confirm to save.", note: note)
            // A logo for a known exchange name, fetched in the background; the entry works without it.
            if let domain, domain.count > 2 {
                Task {
                    guard let image = await AddressIcons.logo(domain: domain + ".com"), let file = AddressIcons.save(image),
                          case .address(var entry)? = pendingAction, entry.address == address else { return }
                    entry.icon = .image(file)
                    pendingAction = .address(entry)
                }
            }
        }
    }
}

/// «save <address> as …» from the chat, waiting for the confirmation.
struct PendingAddressBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if case .address(let entry)? = ws.pendingAction {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Save to Addresses").font(.system(size: 14, weight: .semibold))
                    StatusChip(text: "waiting for your confirmation", tint: Brand.profit)
                }
                AddressCard(entry: entry, readOnly: true).frame(width: 320)
                Label("Taken from your own message and checked for \(entry.network.title). Compare the start and the end with the source before you confirm.",
                      systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 470, alignment: .leading)
                PendingButtons(confirm: "Save")
            }
            .transition(.opacity)
        }
    }
}

extension Workspace {
    /// «send 5 USDC to Bybit»: the recipient comes from the address book by name, is drawn on the canvas and moves
    /// nothing until «do it».
    /// A saved address on this network by its name: the exact name first, then one that contains it.
    func savedAddress(_ name: String, on network: AddressCheck.Network) -> SavedAddress? {
        let key = name.lowercased(), on = addressBook.filter { $0.network == network }
        return on.first { $0.name.lowercased() == key } ?? on.first { $0.name.lowercased().contains(key) }
    }

    func markSent(_ entry: SavedAddress) {
        if let i = addressBook.firstIndex(where: { $0.id == entry.id }) { addressBook[i].lastSent = Date() }
    }

    func prepareTransfer(_ amount: Decimal, to name: String, note: String? = nil) {
        let key = name.lowercased()
        guard let entry = addressBook.first(where: { $0.name.lowercased() == key }) ?? addressBook.first(where: { $0.name.lowercased().contains(key) }) else {
            reply("There’s no “\(name)” in Addresses. Add it there first (the book button in the rail), then send by its name."
                  + (key.contains("solana") || key.contains("солан") ? " To bring money to your own Solana wallet, say “withdraw \(Fmt.num(amount)) USDC to Solana”." : ""), note: note)
            return
        }
        guard entry.network != .near else {
            reply("“\(entry.name)” is a NEAR account: ihatecrypto sends it NEAR, not USDC — e.g. “send 0.1 NEAR to \(entry.name)”.", note: note)
            return
        }
        guard entry.network != .ethereum else {
            reply("“\(entry.name)” is on Ethereum mainnet, where one transfer costs dollars in gas; ihatecrypto sends USDC on Solana, Base, Arbitrum and Hyperliquid.", note: note)
            return
        }
        if !entry.memo.isEmpty, entry.network == .solana {
            reply("“\(entry.name)” needs a memo / tag, and ihatecrypto can’t add one to a Solana transfer yet — send it from the exchange’s app instead.", note: note)
            return
        }
        pendingAction = .transfer(entry, amount)
        pendingText = "send \(Fmt.num(amount)) USDC to \(entry.name)"
        let ends = AddressCheck.ends(entry.address)
        reply("The transfer is on the canvas: \(Fmt.num(amount)) USDC to “\(entry.name)” on \(entry.network.title), \(ends.start) … \(ends.end). Sign it, or say anything else to cancel.", note: note)
    }

    func transfer(_ amount: Decimal, to entry: SavedAddress) async {
        guard let wallet = signerWallet else { reply("Transfers work in the app once the key is in secure storage."); return }
        executing = true
        defer { executing = false }
        let title = "Send \(Fmt.num(amount)) USDC to \(entry.name)"
        let bubble = ActivityBubble(kind: "deposit", label: "Send · \(entry.network.title)", title: entry.name, lines: ["\(Fmt.num(amount)) USDC"], logo: entry.network.logo)
        updateActivity { a in
            a.title = title
            a.bubbles = [bubble]
        }
        do {
            let destination: TradeExecution.Executor.Destination = switch entry.network {
            case .solana: .solana(entry.address)
            case .arbitrum: .arbitrum(entry.address)
            case .hyperliquid: .hyperliquid(entry.address)
            case .robinhood: .robinhood(entry.address)
            default: .base(entry.address)
            }
            let text = try await executor(wallet).sendUSDC(amount, to: destination, label: entry.name)
            if let i = addressBook.firstIndex(where: { $0.id == entry.id }) { addressBook[i].lastSent = Date() }
            finishedAction = (title, CanvasOutcome(at: Date(), ok: true), [bubble])
            recordFlow(-amount, "sent to \(entry.name)")
            reply(text, note: "transfer")
        } catch {
            finishedAction = (title, CanvasOutcome(at: Date(), ok: false), [bubble])
            reply("Failed: \(error.localizedDescription)")
        }
        await refresh()
    }
}

/// A transfer to a saved address waiting for «do it»: from where, to whom (picture, name, the address's ends), how much.
struct TransferBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if case .transfer(let entry, let amount)? = ws.pendingAction {
            let solana = entry.network == .solana, hyper = entry.network == .hyperliquid
            let from = solana ? ws.solana?.usdc : hyper ? ws.hl?.withdrawable : entry.network == .arbitrum ? ws.arbitrumUSDC : ws.base?.usdc
            let ends = AddressCheck.ends(entry.address)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Send · \(Fmt.num(amount)) USDC to \(entry.name)").font(.system(size: 14, weight: .semibold))
                    StatusChip(text: "waiting for the signature", tint: Brand.profit)
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        TokenLogo(name: entry.network.logo, size: 24)
                        Text("FROM · \(entry.network.title.uppercased())").font(.system(size: 9, weight: .heavy)).tracking(0.4).opacity(0.75)
                        Text(from.map { "\(Fmt.num($0)) → \(Fmt.num(max(0, $0 - amount))) USDC" } ?? "—").font(.system(size: 13, weight: .bold)).monospacedDigit()
                        Text(hyper ? "perp balance · no bridge, no gas" : !solana && (from ?? 0) < amount ? "the rest comes from Solana first" : "your wallet").font(.caption2).opacity(0.8)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                    .background(ArrowCard(radius: 16, tip: 10).fill(solana ? Brand.solanaTint : hyper ? Brand.hlChip.opacity(0.35) : Color(light: 0xEAF0FF, dark: 0x14213F)))
                    VStack(alignment: .leading, spacing: 6) {
                        AddressIconView(entry: entry, size: 30)
                        Text("TO · \(entry.label?.uppercased() ?? "SAVED ADDRESS")").font(.system(size: 9, weight: .heavy)).tracking(0.4).opacity(0.75)
                        Text(entry.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
                        Text("\(ends.start) … \(ends.end)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.accent, lineWidth: 2))
                }
                if entry.lastSent == nil {
                    Label("First transfer to this address. Sending a small test amount first is the safe habit.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Brand.jevInk)
                }
                Label("Only this saved address may receive the money: the guard and the signer check it, the simulation must show exactly \(Fmt.num(amount)) USDC leaving. Say “do it” or press Confirm.",
                      systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
                PendingButtons()
            }
            .frame(width: 470, alignment: .leading)
            .transition(.opacity)
        }
    }
}
