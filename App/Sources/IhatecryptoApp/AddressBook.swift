import AppKit
import EVMChain
import IhatecryptoCore
import OneClickKit
import SignerAPI
import SolanaChain
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
    /// The last transfer ihatecrypto made to it; nil means none yet (the route suggests a small test first).
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
        if let icon = entry.icon { PickedIcon(icon: icon, size: size, letter: entry.name) }
        else if let sign = Self.symbol(for: entry.label) { PickedIcon(icon: .symbol(sign), size: size, letter: entry.name) }
        else { PickedIcon.letter(entry.name, size: size) }
    }

    static func symbol(for category: String?) -> String? {
        let c = category?.lowercased() ?? ""
        if c.contains("exchange") || c.contains("бирж") { return "building.columns" }
        if c.contains("wallet") || c.contains("кошел") { return "wallet.pass" }
        if c.contains("friend") || c.contains("person") || c.contains("family") || c.contains("друз") { return "person" }
        if c.contains("defi") { return "chart.pie" }
        return nil
    }

}

/// A picture from the icon library (IconPicker): an address book entry's or a canvas's.
struct PickedIcon: View {
    let icon: AddressIcon
    var size: CGFloat = 38
    /// Shown by its first letter when the picture's file is gone.
    var letter = ""

    var body: some View {
        switch icon {
        case .logo(let name): TokenLogo(name: name, size: size)
        case .symbol(let name):
            Circle().fill(Brand.accent.opacity(0.12)).frame(width: size, height: size)
                .overlay(Image(systemName: name).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(Brand.accentInk))
        case .emoji(let e):
            Circle().fill(Brand.accent.opacity(0.1)).frame(width: size, height: size)
                .overlay(Text(e).font(.ui(size * 0.56)))
        case .image(let file):
            if let image = AddressIcons.image(file) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
            } else {
                Self.letter(letter, size: size)
            }
        }
    }

    static func letter(_ name: String, size: CGFloat) -> some View {
        Circle().fill(Brand.accent.opacity(0.12)).frame(width: size, height: size)
            .overlay(Text(name.prefix(1).uppercased()).font(.ui(size * 0.45, .bold)).foregroundStyle(Brand.accentInk))
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
        case .tempo: "tempo"
        case .polygon: "pol"
        case .hyperevm: "hyperevm"
        case .bitcoin: "btc"
        case .zcash: "zec"
        case .tron: "trx"
        case .xrp: "xrp"
        case .dogecoin: "doge"
        case .sui: "sui"
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
    @State private var confirmingAll = false
    @State private var confirmAllError: String?

    var body: some View {
        let items = filtered
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill").foregroundStyle(Color(hex: 0xF5B301)).font(.system(size: 16, weight: .semibold))
                Text("Favorites").font(.ui(16, .bold))
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
            // Ours: this is where money into ihatecrypto goes.
            let own = ownWallets
            if tab == "all", !own.isEmpty, search.isEmpty {
                HStack {
                    section("YOUR WALLETS · SEND MONEY HERE TO TOP UP")
                    Spacer()
                    Button { withAnimation(StudioView.spring) { ws.showReceive = true } } label: { Label("QR", systemImage: "qrcode") }
                        .buttonStyle(.borderless).font(.ui(10))
                }
                ForEach(own) { AddressCard(entry: $0, readOnly: true) }
            }
            section("ADDRESSES")
            let unconfirmed = ws.addressBook.filter { !ws.isConfirmed($0) }
            if !unconfirmed.isEmpty {
                HStack(spacing: 8) {
                    Label("\(unconfirmed.count) not confirmed with Touch ID: nothing is sent to them until you confirm. Delete the ones you don’t know.",
                          systemImage: "exclamationmark.shield")
                        .font(.ui(10, .semibold)).foregroundStyle(Brand.loss).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(confirmingAll ? "Confirming…" : "Confirm all…") {
                        confirmingAll = true
                        confirmAllError = nil
                        Task {
                            do { try await ws.confirmAddresses(unconfirmed) } catch { confirmAllError = "Not confirmed: " + error.localizedDescription }
                            confirmingAll = false
                        }
                    }
                    .buttonStyle(.bordered).disabled(confirmingAll)
                }
                if let confirmAllError { Text(confirmAllError).font(.ui(10)).foregroundStyle(Brand.loss).fixedSize(horizontal: false, vertical: true) }
            }
            if items.isEmpty { empty }
            ForEach(items) { entry in
                AddressCard(entry: entry, edit: { editing = $0 })
                    .transition(.opacity)
            }
            Label("Every saved address is confirmed with Touch ID, the whole address on the prompt, and money goes to a name only at that address — never to an address from a chat, a site or a model.",
                  systemImage: "lock.shield")
                .font(.ui(10)).foregroundStyle(.secondary)
        }
        .animation(.snappy, value: items)
        .frame(width: 470, alignment: .leading)
        .sheet(isPresented: $adding) { AddressEditor(entry: nil).environment(ws) }
        .sheet(item: $editing) { AddressEditor(entry: $0).environment(ws) }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary).padding(.top, 4)
    }

    private var filtered: [SavedAddress] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return ws.addressBook
            .filter { tab == "all" || $0.favorite || !q.isEmpty }
            .filter { q.isEmpty || [$0.name, $0.address, $0.note, $0.network.title, $0.label ?? ""].contains { $0.lowercased().contains(q) } }
            .sorted { ($0.favorite ? 0 : 1, $0.name.lowercased()) < ($1.favorite ? 0 : 1, $1.name.lowercased()) }
    }

    /// The addresses ihatecrypto reads balances from, shown for copying.
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
                .font(.ui(12)).foregroundStyle(.secondary)
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
    @State private var confirmDelete = false
    @State private var confirming = false
    @State private var confirmError: String?

    private static let gold = Color(hex: 0xF5B301)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    AddressIconView(entry: entry, size: 38)
                    TokenLogo(name: entry.network.logo, size: 17).offset(x: 3, y: 3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.ui(14, .bold)).lineLimit(1)
                    Text([entry.label, entry.network.title, entry.source == "chat" ? "from chat" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.ui(10)).foregroundStyle(.secondary)
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
                Label("Memo / tag: \(entry.memo)", systemImage: "number").font(.ui(10, .semibold)).foregroundStyle(Brand.jevInk)
            }
            if !entry.note.isEmpty { Text(entry.note).font(.ui(10)).foregroundStyle(.secondary) }
            // Its state in the signer's book, always on the card: confirmed (green), or not yet, with Confirm….
            if !readOnly, ws.isConfirmed(entry) {
                Label("Confirmed with Touch ID: money goes only to this address", systemImage: "checkmark.shield.fill")
                    .font(.ui(10, .semibold)).foregroundStyle(Brand.profit)
            } else if !readOnly {
                HStack(spacing: 8) {
                    Label("Not confirmed with Touch ID: nothing is sent to it", systemImage: "exclamationmark.shield")
                        .font(.ui(10, .semibold)).foregroundStyle(Brand.loss)
                    Spacer()
                    Button(confirming ? "Confirming…" : "Confirm…") {
                        confirming = true
                        confirmError = nil
                        Task {
                            do { try await ws.confirmAddresses([entry]) } catch { confirmError = "Not confirmed: " + error.localizedDescription }
                            confirming = false
                        }
                    }
                    .buttonStyle(.bordered).disabled(confirming).help("Touch ID, with the whole address on the prompt: check it against its source")
                }
                if let confirmError { Text(confirmError).font(.ui(10)).foregroundStyle(Brand.loss).fixedSize(horizontal: false, vertical: true) }
            }
            HStack(spacing: 14) {
                CopyButton(title: "Copy", text: entry.address, help: "Copy the address")
                Spacer()
                if readOnly {
                    Text("read from Settings").foregroundStyle(.tertiary)
                } else {
                    Button("Edit") { edit(entry) }
                    Button("Delete", role: .destructive) { confirmDelete = true }.foregroundStyle(Brand.loss)
                }
            }
            .buttonStyle(.borderless).font(.ui(10))
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
                Task { await ws.forgetAddress(entry) }
            }
        } message: {
            Text("Only the saved entry is removed.")
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.address, forType: .string)
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
    @State private var saving = false
    @State private var saveError: String?

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
                    Text(entry == nil ? "Add an address" : "Edit “\(entry?.name ?? "")”").font(.ui(15, .bold))
                    Text("Tap the picture to choose a logo, an emoji or your own image.").font(.ui(10)).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Bybit · USDC deposit"))
                HStack {
                    TextField("Category", text: $category, prompt: Text("optional"))
                    ForEach(Self.categories, id: \.self) { c in
                        Button(c) { category = category == c ? "" : c }
                            .buttonStyle(.plain).font(.ui(10))
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
                    .keyboardShortcut(.defaultAction).disabled(!canSave || saving)
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
                if let saveError { Label(saveError, systemImage: "xmark.octagon.fill").foregroundStyle(Brand.loss) }
                if isExchange {
                    Label("An exchange credits a deposit only on the network it shows. Sent on another network, the money can be lost.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.ui(10))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A new entry, or a changed name, address, network or memo, goes into the signer's book first (Touch ID, the whole
    /// address on the prompt); a picture, a category, a note or the star change at once.
    private func save() {
        var e = entry ?? SavedAddress(name: "", address: "", network: network)
        let previous = entry
        e.name = name.trimmingCharacters(in: .whitespaces)
        e.address = trimmed
        e.network = network
        e.kind = nil
        e.category = category.trimmingCharacters(in: .whitespaces).isEmpty ? nil : category.trimmingCharacters(in: .whitespaces)
        e.memo = memo.trimmingCharacters(in: .whitespaces)
        e.note = note.trimmingCharacters(in: .whitespaces)
        e.favorite = favorite
        let changed = previous.map { $0.name != e.name || $0.address != e.address || $0.network != e.network || $0.memo != e.memo } ?? true
        saving = true
        saveError = nil
        Task {
            do {
                if changed { try await ws.confirmAddresses([e]) }
                if let previous, changed, previous.name.lowercased() != e.name.lowercased() || previous.network != e.network { await ws.forgetAddress(previous) }
                if e.icon != icon { AddressIcons.remove(e.icon) }
                e.icon = icon
                withAnimation(.snappy) {
                    if let i = ws.addressBook.firstIndex(where: { $0.id == e.id }) { ws.addressBook[i] = e } else { ws.addressBook.append(e) }
                }
                dismiss()
            } catch {
                saveError = "Not saved: " + error.localizedDescription
                saving = false
            }
        }
    }
}

/// Logos, symbols, emoji, or a picture: from a file, the clipboard or the site's own icon.
struct IconPicker: View {
    @Binding var icon: AddressIcon?
    let name: String
    @State private var domain = ""
    @State private var fetching = false
    @State private var error: String?
    @State private var search = ""

    /// Every token and network logo in the app (Logos/, bundled flat): the library, searched by ticker.
    static let logos: [String] = Set(["png", "svg"].flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
        .map { $0.deletingPathExtension().lastPathComponent }).sorted()
    static let symbols = ["building.columns", "wallet.pass", "person.fill", "person.2.fill", "creditcard.fill", "banknote.fill", "bag.fill",
                          "cart.fill", "briefcase.fill", "gift.fill", "heart.fill", "star.fill", "house.fill", "lock.fill", "bolt.fill", "flame.fill"]
    static let emoji = ["🏦", "💼", "🐋", "🚀", "💎", "🔥", "🐸", "🦄", "🍀", "👑", "🧊", "🌙"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TOKENS AND NETWORKS").font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary)
                TextField("Search, e.g. sol, aapl", text: $search).textFieldStyle(.roundedBorder).font(.ui(11))
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 9), alignment: .leading, spacing: 6) {
                    ForEach(Self.logos.filter { search.isEmpty || $0.contains(search.lowercased()) }, id: \.self) { l in
                        pick(.logo(l)) { TokenLogo(name: l, size: 26) }.help(l.uppercased())
                    }
                }
            }
            .frame(height: 150)
            section("SYMBOLS") {
                ForEach(Self.symbols, id: \.self) { s in pick(.symbol(s)) { Image(systemName: s).font(.system(size: 15)).frame(width: 26, height: 26) } }
            }
            section("EMOJI") {
                ForEach(Self.emoji, id: \.self) { e in pick(.emoji(e)) { Text(e).font(.ui(20)).frame(width: 26, height: 26) } }
            }
            Text("PICTURE").font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary)
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
            if let error { Text(error).font(.ui(10)).foregroundStyle(Brand.loss) }
            Text("The site’s icon comes through Google’s favicon service; nothing else is sent.").font(.ui(10)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 380)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ items: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.ui(10, .semibold)).tracking(1.2).foregroundStyle(.secondary)
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
    func addressBookCommand(_ command: AddressBookCommand, note: String? = nil) async {
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
            // A name (vitalik.eth, toly.sol) is read on its own chain now, and the address it points at is what's saved:
            // the name changing hands later moves nothing. The card and Touch ID show that address, whole. Awaited, so
            // the card lands on the canvas it was asked on, after the message, while the chat shows it's busy.
            if ENS.isName(address) || SNS.isName(address) {
                do {
                    let resolved = ENS.isName(address) ? try await ENS.resolve(address) : try await SNS.resolve(address)
                    saveFromChat(resolved, name: name, net: net ?? (address.hasSuffix(".sol") ? "solana" : "ethereum"), domain: address, note: note)
                } catch {
                    reply(say("Couldn't read \(address): \(error.localizedDescription) Nothing was saved.",
                              "Не получилось прочитать \(address): \(error.localizedDescription) Ничего не сохранено."), note: note)
                }
                return
            }
            saveFromChat(address, name: name, net: net, domain: nil, note: note)
        }
    }

    /// The save's card for an address — written in the message, or what `domain` (an ENS or SNS name) resolved to.
    private func saveFromChat(_ address: String, name: String, net: String?, domain: String?, note: String?) {
        let network: AddressCheck.Network
        if let net, let n = AddressCheck.Network(rawValue: net) {
            network = n
        } else if !address.hasPrefix("0x") {
            network = .solana
        } else {
            reply("Which network is this 0x address on — Ethereum, Arbitrum, Base, Polygon, Tempo, HyperEVM or Hyperliquid? For example “save … as \(name) on Arbitrum”.", note: note)
            return
        }
        if let problem = AddressCheck.problem(address, network: network) { reply(problem, note: note); return }
        if let same = addressBook.first(where: { $0.network == network && $0.address.lowercased() == address.lowercased() }) {
            reply("Already saved as “\(same.name)”.", note: note)
            return
        }
        let site = name.split(separator: " ").first.map { $0.lowercased() }
        var entry = SavedAddress(name: name, address: address, network: network, source: "chat")
        if let domain { entry.note = "\(domain) — read on-chain \(Date().formatted(.iso8601.year().month().day()))" }
        pendingAction = .address(entry)
        pendingText = "save “\(name)”"
        let ends = AddressCheck.ends(address)
        if let domain {
            reply(say("\(domain) points at \(ends.start)…\(ends.end) on \(network.title), read on-chain just now. Check it on the canvas; Save asks for Touch ID with the whole address.",
                      "\(domain) ведёт на \(ends.start)…\(ends.end) в \(network.title) — прочитано в сети только что. Сверь на холсте; Save спросит Touch ID с полным адресом."), note: note)
        } else {
            reply(say("Check it on the canvas: \(network.title), starts \(ends.start), ends \(ends.end) — exactly as in your message. Confirm to save.",
                      "Сверь на холсте: \(network.title), начало \(ends.start), конец \(ends.end) — как в твоём сообщении. Подтверди, чтобы сохранить."), note: note)
        }
        // A logo for a known exchange name, fetched in the background; the entry works without it.
        if domain == nil, let site, site.count > 2 {
            Task {
                guard let image = await AddressIcons.logo(domain: site + ".com"), let file = AddressIcons.save(image),
                      case .address(var entry)? = pendingAction, entry.address == address else { return }
                entry.icon = .image(file)
                pendingAction = .address(entry)
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
                    Text("Save to Addresses").font(.ui(14, .semibold))
                    StatusChip(text: "waiting for your confirmation", tint: Brand.profit)
                }
                AddressCard(entry: entry, readOnly: true).frame(width: 320)
                Label(entry.note.isEmpty
                      ? "Taken from your own message and checked for \(entry.network.title). Compare it with the source: Save asks for Touch ID with the whole address on the prompt."
                      : "Resolved from \(entry.note.components(separatedBy: " — ").first ?? "") on \(entry.network.title) just now and checked. Save asks for Touch ID with the whole address on the prompt.",
                      systemImage: "checkmark.shield")
                    .font(.ui(10)).foregroundStyle(.secondary).frame(width: 470, alignment: .leading)
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
        return on.first { $0.name.lowercased() == key } ?? (network == .solana ? ownWallet(key) : nil) ?? on.first { $0.name.lowercased().contains(key) }
    }

    /// Another of the user's own wallets, by its name («send 4 USDC to Test»): its Solana address. The signer asks for
    /// Touch ID the first time money goes there, like for any new address.
    func ownWallet(_ name: String) -> SavedAddress? {
        // «my Ledger», «на леджер»: the Ledger by what it is, whatever the user named it.
        let key = name.lowercased().replacing(/^(?:my|мой|моему|мою)\s+/, with: "")
        let ledger = key.contains(/^(?:ledger|л[еэ]дж[еэ]р\w*)$/)
        return wallets.first { $0.id != activeWalletID && ($0.label.lowercased() == key || ledger && $0.kind == "ledger") }.flatMap { w in
            w.solana.map { SavedAddress(name: w.label, address: $0, network: .solana, category: "Your wallet", icon: .logo("sol")) }
        }
    }

    func markSent(_ entry: SavedAddress) {
        if let i = addressBook.firstIndex(where: { $0.id == entry.id }) { addressBook[i].lastSent = Date() }
    }

    /// Money may go to this entry: its name, address and memo are the ones confirmed with Touch ID when it was saved
    /// (the signer's book; a 0x address counts on every EVM network), or it's one of the wallets on this Mac. An entry
    /// changed in the file outside ihatecrypto doesn't pass.
    func isConfirmed(_ e: SavedAddress) -> Bool {
        if wallets.contains(where: { $0.solana == e.address || $0.evm?.lowercased() == e.address.lowercased() }) { return true }
        let evm: Set<String> = ["base", "arbitrum", "ethereum", "polygon", "robinhood", "tempo", "hyperliquid", "hyperevm"]
        return confirmedAddresses.contains { c in
            c.memo == e.memo && (evm.contains(c.network) && evm.contains(e.network.rawValue)
                ? c.same(name: e.name, network: c.network, address: e.address) : c.same(name: e.name, network: e.network.rawValue, address: e.address))
        }
    }

    func requireConfirmed(_ e: SavedAddress) throws {
        guard isConfirmed(e) else {
            throw ExecutionError("“\(e.name)” isn’t confirmed with Touch ID, so nothing goes to it. Confirm it in Favorites › All, after checking the address against its source: if you didn’t change it, it was changed outside ihatecrypto.")
        }
    }

    /// Into the signer's book: Touch ID, every whole address on the prompt.
    func confirmAddresses(_ entries: [SavedAddress]) async throws {
        let r = try await SignerClient().send(.saveAddresses(entries.map {
            SignerAddress(name: $0.name, network: $0.network.rawValue, address: $0.address, memo: $0.memo)
        }))
        guard r.ok else { throw WalletError(r.error ?? "The signer refused.") }
        confirmedAddresses = r.addresses ?? confirmedAddresses
    }

    func forgetAddress(_ e: SavedAddress) async {
        if let r = try? await SignerClient().send(.removeAddress(name: e.name, network: e.network.rawValue)), r.ok { confirmedAddresses = r.addresses ?? [] }
    }

    /// Where a token sent as it is goes: the saved address by its name, and the network — the one the message names,
    /// else where the entry is saved. A 0x address saved on one EVM network is the same address on another; Solana's
    /// and the EVM networks' don't mix, and NEAR or Hyperliquid have their own forms.
    func tokenRecipient(_ name: String, network: String?) throws -> (entry: SavedAddress, network: String) {
        let evm: Set<String> = ["base", "arbitrum", "ethereum", "polygon", "robinhood", "tempo", "hyperevm"]
        guard let entry = savedEntry(name, network: network) else {
            throw ExecutionError("There’s no “\(name)” in Addresses. Save it there first, then send by its name.")
        }
        let saved = entry.network.rawValue, net = network ?? saved
        guard net == saved || (evm.contains(net) && (evm.contains(saved) || saved == "hyperliquid")) else {
            throw ExecutionError("“\(entry.name)” is a \(entry.network.title) address: it can't receive on \(AddressCheck.Network(rawValue: net)?.title ?? net).")
        }
        guard net == "solana" || evm.contains(net) else {
            throw ExecutionError(saved == "near" ? "“\(entry.name)” is a NEAR account: send it NEAR, e.g. “send 0.1 NEAR to \(entry.name)”."
                                                 : "On \(entry.network.title) only USDC moves: “send N USDC to \(entry.name)”.")
        }
        guard entry.memo.isEmpty || net != "solana" else {
            throw ExecutionError("“\(entry.name)” needs a memo / tag, and ihatecrypto can’t add one to a Solana transfer — send it from the exchange’s app instead.")
        }
        if let off = ModuleNetwork(place: net).flatMap({ Modules.current.refusal(network: $0, ru: modulesRussian) }) { throw ExecutionError(off) }
        try requireConfirmed(entry)
        return (entry, net)
    }

    /// A saved address on a network only NEAR Intents reaches (Bitcoin, Zcash, TRON, XRP, Dogecoin, Sui), the coin it
    /// gets there and the address 1Click pays: an XRP account with a numeric memo becomes its X-address, the tag inside.
    /// nil for an address ihatecrypto sends to itself.
    func acrossRecipient(_ name: String, token: String, network: String?) throws -> (entry: SavedAddress, symbol: String, address: String)? {
        guard let entry = savedEntry(name, network: network), let assets = OneClick.Asset.across[entry.network.rawValue] else { return nil }
        guard let asset = assets.first(where: { $0.symbol == token.uppercased() }) else {
            throw ExecutionError("“\(entry.name)” is a \(entry.network.title) address: NEAR Intents pays \(assets.map(\.symbol).joined(separator: " or ")) there.")
        }
        var address = entry.address
        if !entry.memo.isEmpty {
            guard entry.network == .xrp, let tag = UInt32(entry.memo.trimmingCharacters(in: .whitespaces)), let x = AddressCheck.xAddress(entry.address, tag: tag) else {
                throw ExecutionError("“\(entry.name)” needs a memo, and NEAR Intents can't add one on \(entry.network.title) — send it from the exchange's app instead.")
            }
            address = x
        }
        if let off = Modules.current.refusal(.oneClick, ru: modulesRussian) { throw ExecutionError(off) }
        try requireConfirmed(entry)
        return (entry, asset.symbol, address)
    }

    /// The entry a name means. One name can be saved on several networks («Automation» on Solana and on Base): the one
    /// that can receive on the network named comes first; a 0x address on one EVM network is the same on another.
    func savedEntry(_ name: String, network: String?) -> SavedAddress? {
        let key = name.lowercased()
        let evm: Set<String> = ["base", "arbitrum", "ethereum", "polygon", "robinhood", "tempo", "hyperevm"]
        func fits(_ e: SavedAddress) -> Bool {
            guard let network else { return true }
            return e.network.rawValue == network || (evm.contains(network) && (evm.contains(e.network.rawValue) || e.network == .hyperliquid))
        }
        let named = addressBook.filter { $0.name.lowercased() == key }, near = addressBook.filter { $0.name.lowercased().contains(key) }
        return named.first(where: fits) ?? named.first ?? ownWallet(key) ?? near.first(where: fits) ?? near.first
    }

    /// `quiet`: a step of a chain — its card shows, and a confirmed chain signs it at once: no «Sign it» line.
    func prepareTransfer(_ amount: Decimal, to name: String, network: String? = nil, note: String? = nil, quiet: Bool = false) {
        let key = name.lowercased()
        // «test wallet» saved on Base and on Solana, «send 3 USDC to test wallet on Solana»: the Solana entry, not the first.
        guard var entry = savedEntry(name, network: network) else {
            reply("There’s no “\(name)” in Addresses. Add it there first (the book button in the rail), then send by its name."
                  + (key.contains("solana") || key.contains("солан") ? " To bring money to your own Solana wallet, say “withdraw \(Fmt.num(amount)) USDC to Solana”." : ""), note: note)
            return
        }
        guard entry.network != .near else {
            reply("“\(entry.name)” is a NEAR account: ihatecrypto sends it NEAR, not USDC — e.g. “send 0.1 NEAR to \(entry.name)”.", note: note)
            return
        }
        // Bitcoin, TRON, Sui…: NEAR Intents pays out there, in the coin named.
        if let assets = OneClick.Asset.across[entry.network.rawValue] {
            let usdc = assets.contains { $0.symbol == "USDC" }
            reply(say("“\(entry.name)” is a \(entry.network.title) address: NEAR Intents delivers there — say “send \(usdc ? "\(Fmt.num(amount)) USDC on \(entry.network.rawValue)" : "<amount> \(assets[0].symbol)") to \(entry.name)”.",
                      "«\(entry.name)» — адрес в \(entry.network.title): туда доставляет NEAR Intents — скажи «send \(usdc ? "\(Fmt.num(amount)) USDC on \(entry.network.rawValue)" : "<сумма> \(assets[0].symbol)") to \(entry.name)»."), note: note)
            return
        }
        do { try requireConfirmed(entry) } catch { reply(error.localizedDescription, note: note); return }
        // The network the message names wins, Ethereum mainnet too (the user's call, 2026-10-01: «мне пофиг что дорого»).
        // A 0x address saved on one EVM network is the same address on another; the card says it was saved elsewhere.
        if let net = network.flatMap(AddressCheck.Network.init(rawValue:)), net != entry.network {
            let evm: Set<AddressCheck.Network> = [.base, .arbitrum, .ethereum, .polygon, .robinhood, .tempo, .hyperliquid, .hyperevm]
            guard evm.contains(net), evm.contains(entry.network) else {
                reply(say("“\(entry.name)” is a \(entry.network.title) address: it can't receive on \(net.title).",
                          "«\(entry.name)» — адрес в \(entry.network.title), в \(net.title) он получить не может."), note: note)
                return
            }
            entry.network = net
        }
        if !entry.memo.isEmpty, entry.network == .solana {
            reply("“\(entry.name)” needs a memo / tag, and ihatecrypto can’t add one to a Solana transfer yet — send it from the exchange’s app instead.", note: note)
            return
        }
        if let off = transferRefusal(entry) { reply(off, note: note); return }
        pendingAction = .transfer(entry, amount)
        pendingText = "send \(Fmt.num(amount)) USDC to \(entry.name)"
        let ends = AddressCheck.ends(entry.address)
        if quiet { return }
        reply(say("The transfer is on the canvas: \(Fmt.num(amount)) USDC to “\(entry.name)” on \(entry.network.title), \(ends.start) … \(ends.end). Sign it",
                  "Перевод на холсте: \(Fmt.num(amount)) USDC на «\(entry.name)» в \(entry.network.title), \(ends.start) … \(ends.end). Подпиши",
                  "La transferencia está en el lienzo: \(Fmt.num(amount)) USDC a «\(entry.name)» en \(entry.network.title), \(ends.start) … \(ends.end). Fírmala")
              + orCancel(say(", or say anything else to cancel.", " или напиши что-нибудь другое, чтобы отменить.", ", o di otra cosa para cancelar.")), note: note)
    }

    func transfer(_ amount: Decimal, to entry: SavedAddress) async {
        guard let wallet = signerWallet else { reply("Transfers work in the app once the key is in secure storage."); return }
        if let off = transferRefusal(entry) { reply(off); return }
        do { try requireConfirmed(entry) } catch { reply(error.localizedDescription); return }
        executing = true
        defer { executing = false; runningAction = nil }
        let title = "Send \(Fmt.num(amount)) USDC to \(entry.name)"
        let bubble = ActivityBubble(kind: "deposit", label: "Send · \(entry.network.title)", title: entry.name, lines: ["\(Fmt.num(amount)) USDC"], logo: entry.network.logo)
        updateActivity { a in
            a.title = title
            a.bubbles = [bubble]
        }
        // The card stays on the canvas while it's signed and sent; Done or Failed takes its place in the same frame.
        runningAction = (title, [bubble], [], Date())
        do {
            let destination: TradeExecution.Executor.Destination = switch entry.network {
            case .solana: .solana(entry.address)
            case .arbitrum: .arbitrum(entry.address)
            case .hyperliquid: .hyperliquid(entry.address)
            case .robinhood: .robinhood(entry.address)
            case .tempo: .tempo(entry.address)
            case .ethereum: .ethereum(entry.address)
            case .polygon: .polygon(entry.address)
            case .base: .base(entry.address)
            case .hyperevm: .hyperevm(entry.address)
            case .near: throw ExecutionError("USDC doesn't go to a NEAR account.")
            case .bitcoin, .zcash, .tron, .xrp, .dogecoin, .sui: throw ExecutionError("\(entry.network.title) is reached through NEAR Intents: “send <amount> <coin> to \(entry.name)”.")
            }
            let text = try await executor(wallet).sendUSDC(amount, to: destination, label: entry.name)
            if let i = addressBook.firstIndex(where: { $0.id == entry.id }) { addressBook[i].lastSent = Date() }
            runningAction = nil
            finishedAction = (title, CanvasOutcome(at: Date(), ok: true), [bubble])
            recordFlow(-amount, "sent to \(entry.name)")
            reply(text, note: "transfer")
        } catch {
            runningAction = nil
            finishedAction = (title, CanvasOutcome(at: Date(), ok: false), [bubble])
            reply("Failed: \(error.localizedDescription)")
        }
        // The outcome board comes from the saved canvas: now, not after the refresh (a repeated reply doesn't save).
        saveCanvas()
        await refresh()
    }
}

/// A transfer to a saved address waiting for «do it»: from where, to whom (picture, name, the address's ends), how much.
struct TransferBoard: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if case .transfer(let entry, let amount)? = ws.pendingAction {
            let solana = entry.network == .solana, hyper = entry.network == .hyperliquid
            let from = ws.usdc(on: entry.network.rawValue)
            let ends = AddressCheck.ends(entry.address)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Send · \(Fmt.num(amount)) USDC to \(entry.name)").font(.ui(14, .semibold))
                    StatusChip(text: "waiting for the signature", tint: Brand.profit)
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        TokenLogo(name: entry.network.logo, size: 24)
                        Text("FROM · \(entry.network.title.uppercased())").font(.ui(9, .heavy)).tracking(0.4).opacity(0.75)
                        Text(from.map { "\(Fmt.num($0)) → \(Fmt.num(max(0, $0 - amount))) USDC" } ?? "—").font(.ui(13, .bold)).monospacedDigit()
                        // Solana comes up only when the money there is short: a plain transfer is a plain transfer.
                        Text(hyper ? "perp balance · no bridge, no gas" : solana ? "your wallet"
                             : from.map { $0 < amount ? "\(Fmt.num(amount - $0)) USDC short: it comes from Solana first" : "your wallet" } ?? "your wallet")
                            .font(.ui(10)).opacity(0.8)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                    .background(ArrowCard(radius: 16, tip: 10).fill(solana ? Brand.solanaTint : hyper ? Brand.hlChip.opacity(0.35) : Color(light: 0xEAF0FF, dark: 0x14213F)))
                    VStack(alignment: .leading, spacing: 6) {
                        AddressIconView(entry: entry, size: 30)
                        Text("TO · \(entry.label?.uppercased() ?? "SAVED ADDRESS")").font(.ui(9, .heavy)).tracking(0.4).opacity(0.75)
                        Text(entry.name).font(.ui(13, .bold)).lineLimit(1)
                        Text("\(ends.start) … \(ends.end)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.accent, lineWidth: 2))
                }
                if let saved = ws.addressBook.first(where: { $0.id == entry.id }), saved.network != entry.network {
                    Label("Saved for \(saved.network.title), sent on \(entry.network.title) to the same address. Your own wallet has it there too; an exchange's deposit address may not — check that it takes \(entry.network.title).",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.ui(10)).foregroundStyle(Brand.jevInk)
                }
                if entry.network == .ethereum {
                    Label("Ethereum mainnet: the fee is in ETH and can be dollars; it's bought for you if the wallet has none there.", systemImage: "fuelpump")
                        .font(.ui(10)).foregroundStyle(.secondary)
                }
                if entry.lastSent == nil {
                    Label("First transfer to this address. Sending a small test amount first is the safe habit.", systemImage: "exclamationmark.triangle.fill")
                        .font(.ui(10)).foregroundStyle(Brand.jevInk)
                }
                Label("Only this saved address may receive the money: the guard and the signer check it, the simulation must show exactly \(Fmt.num(amount)) USDC leaving. Press Confirm.",
                      systemImage: "checkmark.shield")
                    .font(.ui(10)).foregroundStyle(.secondary)
                PendingButtons()
            }
            .frame(width: 470, alignment: .leading)
            .transition(.opacity)
        }
    }
}
